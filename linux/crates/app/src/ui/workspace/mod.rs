//! One connection session's workspace: the sidebar of its tables and
//! the tabs open on them. A workspace never changes session; a
//! disconnect drops it and the window shows the connection picker.

mod close_flow;
mod health_banner;
mod imp;
mod import;
mod row_ops;
mod saves;
mod sidebar;
mod sidebar_section_header;
mod status_pages;
mod structure;
mod window_tabs;
mod workspace_actions;
mod workspace_persistence;
mod workspace_tabs;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::{ComponentController, Controller};

use tablepro_core::{EditorSession, QueryResult};
use tablepro_session::runtime::WatchForwarder;
use tablepro_session::{ObjectListSnapshot, Session, SessionHealth, SessionKey};
use uuid::Uuid;

use super::browse_tab::{BrowseTab, BrowseTabInput};
use super::editor::SqlEditor;
use super::history_dialog::HistoryDialog;
use super::sidebar_row::SidebarRow;
use crate::application::AppServices;
use crate::runtime::{DeliverInput, InputSender};
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::session_context::SessionContext;
use crate::services::structure_tracker_registry::StructureTrackerRegistry;
use crate::workspace::{CloseGuards, WorkspaceHandle};

glib::wrapper! {
    pub struct Workspace(ObjectSubclass<imp::Workspace>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

/// What a window hands the workspace it builds for an adopted session.
pub(crate) struct WorkspaceInit {
    pub key: SessionKey,
    pub session: Arc<Session>,
    pub services: Rc<AppServices>,
    /// The window's own, whose session slot the workspace does not use.
    pub context: Rc<SessionContext>,
    pub window: adw::ApplicationWindow,
    /// The window's prompts, so a tab's close and the window's never ask
    /// at once.
    pub close_guards: Rc<CloseGuards>,
}

pub(crate) type WorkspaceSender = InputSender<WorkspaceInput>;

pub(crate) struct WorkspaceModel {
    context: Rc<SessionContext>,
    /// What the session's tabs are saved under.
    key: SessionKey,
    input: WorkspaceSender,
    this: glib::WeakRef<Workspace>,
    window: glib::WeakRef<adw::ApplicationWindow>,
    settings: Rc<tablepro_storage::AppSettings>,
    storage: crate::storage::SharedStorage,
    tasks: tablepro_session::runtime::Tasks,
    history: crate::services::history_service::HistoryService,
    drafts: Rc<crate::workspace::DraftWriter>,
    window_title: adw::WindowTitle,
    sidebar_title: adw::WindowTitle,
    /// Watches `HistoryService` and flips `win.show-history`. Aborted
    /// with the workspace, whose actions it acts on.
    history_gate: glib::JoinHandle<()>,
    /// The window's actions this workspace added, removed with it.
    actions: Vec<&'static str>,
    sidebar_factory: FactoryVecDeque<SidebarRow>,
    /// Takes the sidebar rows' output to `input`.
    sidebar_bridge: glib::JoinHandle<()>,
    sidebar_schemas: Rc<RefCell<Vec<Option<String>>>>,
    toast_overlay: adw::ToastOverlay,
    reconnect_banner: adw::Banner,
    row_op_spinner: adw::Spinner,
    read_only_badge: gtk::Label,
    table_search: gtk::SearchEntry,
    /// `"empty"` while no tab is open, `"tabs"` otherwise.
    workspace_outer_stack: gtk::Stack,
    workspace_root: Option<adw::TabOverview>,
    workspace_tab_view: Option<adw::TabView>,
    workspace_root_added: Cell<bool>,
    /// Per-tab state, by tab id. Display order is read from the tab
    /// view's pages.
    workspace_tabs: Rc<RefCell<HashMap<Uuid, WorkspaceTab>>>,
    /// Pending row edits, one tracker per Table tab.
    change_trackers: Rc<ChangeTrackerRegistry>,
    /// Pending DDL, one tracker per Structure tab.
    structure_trackers: Rc<StructureTrackerRegistry>,
    /// Starts, stops and settles the saves, and says what closing any
    /// part of the workspace would lose.
    workspace_handle: WorkspaceHandle,
    /// The tabs as the close prompts read them.
    window_tabs: Rc<window_tabs::WindowTabs>,
    close_guards: Rc<CloseGuards>,
    /// Whether the window was last told there is something to lose.
    reported_dirty: Cell<Option<bool>>,
    history_dialog: Option<Controller<HistoryDialog>>,
    saved_queries_dialog: Option<Controller<super::saved_queries_dialog::SavedQueriesDialog>>,
    import_dialog: Option<Controller<super::import_dialog::ImportCsvDialog>>,
    driver_id: String,
    read_only: bool,
    /// Writes the tab list a moment after the last change.
    workspace: Rc<workspace_persistence::WorkspacePersistence>,
    /// Recently closed tabs for Ctrl+Shift+T. Pending edits are not
    /// kept: the close has already cleared them.
    closed_tabs_stack: Rc<RefCell<VecDeque<ClosedTabDescriptor>>>,
    /// Feed the reconnect banner and the sidebar, and stop with the
    /// workspace, so nothing reads for a session it let go of.
    _health_watch: WatchForwarder,
    _catalog_watch: WatchForwarder,
}

/// Snapshot of a tab the user just closed, retained for Ctrl+Shift+T
/// reopen, so reopen routes back through the same `append_*`
/// constructors as a restore.
#[derive(Debug, Clone)]
pub enum ClosedTabDescriptor {
    Editor {
        query: String,
    },
    Table {
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
}

pub(super) const CLOSED_TABS_CAPACITY: usize = 10;

pub struct EditorTabSlot {
    pub editor: SqlEditor,
    pub page: adw::TabPage,
    /// The file this tab's text is written to. The text itself lives in
    /// the buffer, not here.
    pub draft: tablepro_storage::DraftId,
}

pub struct StructureTabSlot {
    pub id: Uuid,
    pub structure: crate::ui::structure_tab::StructureTab,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    /// Empty in `New` mode until SaveCompleted carries the canonical
    /// table name back from the driver. Edit mode populates from the
    /// sidebar click or restore record.
    pub table: String,
    pub mode: crate::ui::structure_tab::StructureMode,
}

/// A tab showing one table's rows. The table's structure opens in a
/// tab of its own: one TabPage per surface, as GNOME Files and Builder
/// do.
pub struct TableTabSlot {
    pub id: Uuid,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    pub table: String,
    pub browse: BrowseTab,
}

/// A tab in the unified workspace.
///
/// - **Table**: one (schema, table) entity in Data (Browse grid)
///   view. Default for every sidebar single-click.
/// - **Editor**: a free-form SQL workspace, orthogonal to any one
///   table.
/// - **Structure**: the DDL editor, for a new table's draft or an
///   existing table.
pub enum WorkspaceTab {
    Editor(EditorTabSlot),
    Structure(StructureTabSlot),
    Table(TableTabSlot),
}

impl WorkspaceTab {
    /// The Browse tab. Only `Table` slots carry one.
    pub fn browse_tab(&self) -> Option<&BrowseTab> {
        match self {
            WorkspaceTab::Table(s) => Some(&s.browse),
            _ => None,
        }
    }

    /// The Structure-side controller. Only `Structure` slots carry
    /// one (Table slots no longer fuse the DDL editor in).
    pub fn structure_tab(&self) -> Option<&crate::ui::structure_tab::StructureTab> {
        match self {
            WorkspaceTab::Structure(s) => Some(&s.structure),
            _ => None,
        }
    }

    /// `(schema, table)` when the slot is pinned to one. Editor
    /// returns `None`.
    pub fn schema_table(&self) -> Option<(Option<&str>, &str)> {
        match self {
            WorkspaceTab::Structure(s) => Some((s.schema.as_deref(), &s.table)),
            WorkspaceTab::Table(s) => Some((s.schema.as_deref(), &s.table)),
            WorkspaceTab::Editor(_) => None,
        }
    }

    pub fn page(&self) -> &adw::TabPage {
        match self {
            WorkspaceTab::Editor(slot) => &slot.page,
            WorkspaceTab::Structure(slot) => &slot.page,
            WorkspaceTab::Table(slot) => &slot.page,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum OpenMode {
    /// Plain sidebar click: activate the table's tab, or append one.
    SwitchOrAppend,
    /// Ctrl+click / right-click "Open in new tab": always append a
    /// new tab even when the same table is already open.
    NewTab,
}

// The page carries only the tab's id; its kind is in `workspace_tabs`.
fn workspace_tab_id_quark() -> glib::Quark {
    static QUARK: std::sync::OnceLock<glib::Quark> = std::sync::OnceLock::new();
    *QUARK.get_or_init(|| glib::Quark::from_str("tp-workspace-tab-id"))
}

pub(super) fn write_workspace_tab_id(page: &adw::TabPage, id: Uuid) {
    unsafe {
        page.set_qdata(workspace_tab_id_quark(), id);
    }
}

pub(super) fn read_workspace_tab_id(page: &adw::TabPage) -> Option<Uuid> {
    unsafe { page.qdata::<Uuid>(workspace_tab_id_quark()).map(|p| *p.as_ref()) }
}

#[derive(Debug)]
pub(crate) enum WorkspaceInput {
    HealthChanged(SessionHealth),
    /// The session's object list for the sidebar changed: a reconnect
    /// read it again, or a schema change refreshed it.
    CatalogChanged(ObjectListSnapshot),
    SelectTable {
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
    },
    NewEditorTab,
    CloseActiveWorkspaceTab,
    EditorTabRunStateChanged(Uuid, bool),
    EditorTabContentChanged(Uuid),
    /// The session's saved tabs and their editor text, read off the GTK
    /// thread.
    WorkspaceLoaded(workspace_tabs::LoadedWorkspace),
    /// The toast's Reset: move the unreadable saved tabs aside.
    ResetWorkspaceLayout,
    WorkspaceLayoutReset(Result<Option<std::path::PathBuf>, crate::workspace::WorkspaceSaveError>),
    ShowHistory,
    ShowSavedQueries,
    SaveActiveQuery,
    SaveQueryNamed {
        name: String,
        query: String,
    },
    ImportCsvRequested {
        schema: Option<String>,
        table: String,
    },
    /// The file came back with the table's columns beside it, so the
    /// mapping dialog has everything it needs.
    ImportCsvReady {
        schema: Option<String>,
        table: String,
        columns: Vec<tablepro_core::ColumnInfo>,
        bytes: Vec<u8>,
    },
    ImportCsvRun(Box<super::import_dialog::CsvImport>),
    OpenHistoryQuery(String),
    ReplaceActiveTabQuery(String),
    TabCloseDecided {
        id: Uuid,
        approved: bool,
    },
    RefreshPage,
    ExportResults {
        result: QueryResult,
        name: String,
        target: Option<super::export_dialog::SqlTarget>,
    },
    CopyToClipboard(String),
    WorkspaceTabClosed(Uuid),
    /// Each tab still asks about its own unsaved changes.
    CloseOtherWorkspaceTabs(Uuid),
    CloseWorkspaceTabsToRight(Uuid),
    /// The tab order, the selection or a tab's state changed, so the
    /// workspace is saved.
    WorkspaceTabsChanged,
    SaveTab(Uuid),
    StopSaving(Uuid),
    /// A save started or settled, or tabs' changes were dropped.
    Workspace(crate::workspace::WorkspaceEvent),
    SavesInFlightChanged(usize),
    /// An editor tab's transaction opened or ended.
    EditorTransactionChanged,
    SaveActiveTab,
    UndoActiveBrowseTab,
    RedoActiveBrowseTab,
    ShowAlert {
        title: String,
        body: String,
    },
    ShowToast(String),
    /// A browse tab's tracker moved between empty and non-empty, so its
    /// title gains or loses the "•" GNOME Text Editor puts on unsaved
    /// documents.
    BrowseTabDirtyChanged(Uuid, bool),
    NewTableTab {
        schema: Option<String>,
    },
    EditStructureTab {
        schema: Option<String>,
        table: String,
    },
    ShowCreateTableForExisting {
        schema: Option<String>,
        table: String,
    },
    ShowCreateTableLoaded(String),
    DropTablePrompt {
        schema: Option<String>,
        table: String,
    },
    DropTableConfirmed {
        schema: Option<String>,
        table: String,
    },
    /// The table is gone, so its tabs close without asking.
    DropTableSucceeded(tablepro_core::TableRef),
    StructureTabDirtyChanged(Uuid, bool),
    SchemaChanged {
        schema: Option<String>,
        table: Option<String>,
    },
    ReopenClosedTab,
    ShowFilterDialog,
}

/// Tabs in either registry with unsaved changes.
fn dirty_tabs(changes: &ChangeTrackerRegistry, structures: &StructureTrackerRegistry) -> Vec<Uuid> {
    let mut dirty = changes.dirty();
    dirty.extend(structures.dirty());
    dirty.sort_unstable();
    dirty.dedup();
    dirty
}

impl Workspace {
    pub(crate) fn new(init: WorkspaceInit) -> Self {
        let WorkspaceInit {
            key,
            session,
            services,
            context,
            window,
            close_guards,
        } = init;
        let workspace: Self = glib::Object::new();
        let imp = workspace.imp();
        let (input, receiver) = crate::runtime::input_queue::<WorkspaceInput>();
        imp.pump.replace(Some(crate::runtime::pump_inputs(
            &workspace,
            receiver,
            |workspace, message| workspace.handle_input(message),
        )));

        // The workspace's own slot: a tab reads it for the session, and
        // it empties when the workspace goes.
        let context = Rc::new(SessionContext {
            active: crate::services::active_session::ActiveSession::new(),
            ..(*context).clone()
        });
        context.active.replace(session.clone());

        let settings = services.settings.clone();
        let storage = services.storage.clone();
        let tasks = services.tasks.clone();
        let history = services.history();
        let drafts = crate::workspace::DraftWriter::new(
            tablepro_storage::DraftStore::new(storage.paths().drafts_dir()),
            tasks.clone(),
        );
        let persistence = workspace_persistence::WorkspacePersistence::new(storage.workspaces().clone());
        let change_trackers = Rc::new(ChangeTrackerRegistry::default());
        let structure_trackers = Rc::new(StructureTrackerRegistry::default());
        let workspace_tabs: workspace_persistence::WorkspaceTabs = Rc::new(RefCell::new(HashMap::new()));
        let window_tabs = Rc::new(window_tabs::WindowTabs::new(workspace_tabs.clone()));
        let events = input.clone();
        let workspace_handle = WorkspaceHandle::new(crate::workspace::WorkspaceDeps {
            session: context.active.clone(),
            tasks: context.tasks.clone(),
            hold: context.hold.clone(),
            history: Some(history.clone()),
            rows: change_trackers.clone(),
            structures: structure_trackers.clone(),
            directory: window_tabs.clone(),
            events: Rc::new(move |event| events.deliver(WorkspaceInput::Workspace(event))),
        });
        let saves = input.clone();
        workspace_handle
            .ledger()
            .on_change(move |count| saves.deliver(WorkspaceInput::SavesInFlightChanged(count)));

        let sidebar = sidebar::build(&workspace, &context, &input);
        let actions = workspace_actions::install(&window, &input);
        let history_gate = workspace_actions::spawn_history_gate(&window, history.availability());

        let health_input = input.clone();
        let health_watch = WatchForwarder::new(
            session.health(),
            move |health| health_input.deliver(WorkspaceInput::HealthChanged(health)),
            sidebar::spawn_local,
        );
        let catalog_input = input.clone();
        let catalog_watch = sidebar::catalog_watch(&session, move |snapshot| {
            catalog_input.deliver(WorkspaceInput::CatalogChanged(snapshot));
        });

        let driver_id = session.metadata().driver_id.clone();
        let model = WorkspaceModel {
            context,
            key,
            input,
            this: workspace.downgrade(),
            window: window.downgrade(),
            settings,
            storage,
            tasks,
            history,
            drafts,
            window_title: imp.window_title.get(),
            sidebar_title: imp.sidebar_title.get(),
            history_gate,
            actions,
            sidebar_factory: sidebar.factory,
            sidebar_bridge: sidebar.bridge,
            sidebar_schemas: sidebar.schemas,
            toast_overlay: imp.toast_overlay.get(),
            reconnect_banner: imp.reconnect_banner.get(),
            row_op_spinner: imp.row_op_spinner.get(),
            read_only_badge: imp.read_only_badge.get(),
            table_search: imp.table_search.get(),
            workspace_outer_stack: imp.workspace_outer_stack.get(),
            workspace_root: None,
            workspace_tab_view: None,
            workspace_root_added: Cell::new(false),
            workspace_tabs,
            change_trackers,
            structure_trackers,
            workspace_handle,
            window_tabs,
            close_guards,
            reported_dirty: Cell::new(None),
            history_dialog: None,
            saved_queries_dialog: None,
            import_dialog: None,
            driver_id,
            read_only: session.read_only(),
            workspace: persistence,
            closed_tabs_stack: Rc::new(RefCell::new(VecDeque::with_capacity(CLOSED_TABS_CAPACITY))),
            _health_watch: health_watch,
            _catalog_watch: catalog_watch,
        };
        imp.model.replace(Some(model));
        workspace
    }

    /// Show the session: its tables, the empty tab area, and the tabs
    /// saved for it. Called once the window listens for the
    /// workspace's signals, so it hears the first title.
    pub(crate) fn start(&self) {
        self.with_model(WorkspaceModel::open);
    }

    /// What the workspace's actions, tabs and background work send it.
    pub(crate) fn input(&self) -> Option<WorkspaceSender> {
        self.read(|model| model.input.clone())
    }

    /// The saves and the close prompts' view of the tabs.
    pub(crate) fn handle(&self) -> Option<WorkspaceHandle> {
        self.read(|model| model.workspace_handle.clone())
    }

    /// Write what the workspace shows: the tab list, the editor text,
    /// and the last column drag and filter change. The process is held
    /// until every write lands.
    pub(crate) fn flush(&self) {
        self.with_model(|model| model.flush());
    }

    /// Stop every editor run and take each editor tab's session, so the
    /// teardown closes them all under one hold.
    pub(crate) fn take_editor_sessions(&self) -> Vec<Arc<dyn EditorSession>> {
        self.with_model(|model| model.take_editor_sessions())
            .unwrap_or_default()
    }

    /// Stop the tabs, their reads and the watchers, take the
    /// workspace's actions off the window and drop what it holds. Any
    /// reply still on its way is dropped with the input queue.
    pub(crate) fn shutdown(&self) {
        let imp = self.imp();
        if let Some(pump) = imp.pump.take() {
            pump.abort();
        }
        let model = match imp.model.try_borrow_mut() {
            Ok(mut model) => model.take(),
            Err(_) => {
                tracing::warn!("the workspace was shut down while it was handling input");
                return;
            }
        };
        if let Some(model) = model {
            model.shutdown();
        }
    }

    pub(crate) fn connect_dirty_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "dirty-changed",
            false,
            glib::closure_local!(move |workspace: &Self, dirty: bool| f(workspace, dirty)),
        )
    }

    pub(crate) fn connect_saves_in_flight_changed<F: Fn(&Self, usize) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "saves-in-flight-changed",
            false,
            glib::closure_local!(move |workspace: &Self, count: u32| {
                f(workspace, usize::try_from(count).unwrap_or(usize::MAX));
            }),
        )
    }

    pub(crate) fn connect_title_changed<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "title-changed",
            false,
            glib::closure_local!(move |workspace: &Self, title: String| f(workspace, title)),
        )
    }

    fn handle_input(&self, message: WorkspaceInput) {
        self.with_model(|model| model.update(message));
    }

    fn with_model<R>(&self, f: impl FnOnce(&mut WorkspaceModel) -> R) -> Option<R> {
        let mut model = self.imp().model.try_borrow_mut().ok()?;
        model.as_mut().map(f)
    }

    fn read<R>(&self, f: impl FnOnce(&WorkspaceModel) -> R) -> Option<R> {
        let model = self.imp().model.try_borrow().ok()?;
        model.as_ref().map(f)
    }
}

impl WorkspaceModel {
    pub(super) fn dirty_tabs(&self) -> Vec<Uuid> {
        dirty_tabs(&self.change_trackers, &self.structure_trackers)
    }

    /// The window this workspace is in, for dialogs to sit over.
    pub(super) fn window(&self) -> Option<adw::ApplicationWindow> {
        self.window.upgrade()
    }

    /// What a dialog sits over: the window, or the workspace itself
    /// while it is not in one.
    pub(super) fn dialog_parent(&self) -> Option<gtk::Widget> {
        self.window()
            .map(Cast::upcast)
            .or_else(|| self.this.upgrade().map(Cast::upcast))
    }

    /// Show the session it was built for: the sidebar, the empty tab
    /// area, and the tabs saved for it.
    fn open(&mut self) {
        self.read_only_badge.set_visible(self.read_only);
        self.reconnect_banner.set_revealed(false);
        self.table_search.set_text("");
        self.ensure_workspace_root();
        let objects = self
            .context
            .active
            .get()
            .map(|session| {
                session
                    .subscribe_objects(tablepro_core::meta::ObjectScope::DefaultSchema)
                    .borrow()
                    .objects
                    .to_vec()
            })
            .unwrap_or_default();
        tracing::info!(driver = %self.driver_id, table_count = objects.len(), "workspace ready");
        self.show_objects(&objects);
        self.refresh_window_title();
        self.restore_workspace_tabs(self.key.clone());
        self.refresh_inhibitor();
    }

    /// The window's title names the table in front of the user and the
    /// connection, the way GNOME apps name the document; the header
    /// names the connection and its driver. A "•" leads while any tab
    /// has unsaved changes, so it shows in the overview and Alt+Tab.
    pub(super) fn refresh_window_title(&self) {
        let metadata = self.context.active.metadata();
        let name = metadata.as_ref().map_or("", |metadata| metadata.name.as_str());
        let mut title = match self.selected_browse_slot_table() {
            Some((schema, table)) => format!("{} · {name}", qualified_label(schema.as_deref(), &table)),
            None => name.to_owned(),
        };
        if !self.dirty_tabs().is_empty() {
            title = format!("• {title}");
        }
        self.window_title.set_subtitle(&format!("{name} · {}", self.driver_id));
        self.sidebar_title.set_title(name);
        if let Some(workspace) = self.this.upgrade() {
            workspace.emit_by_name::<()>("title-changed", &[&title]);
        }
    }

    fn shutdown(mut self) {
        self.history_gate.abort();
        self.sidebar_bridge.abort();
        // Their entries name this session's tables and queries.
        if let Some(dialog) = self.history_dialog.take() {
            dialog.model().dialog().close();
        }
        if let Some(dialog) = self.saved_queries_dialog.take() {
            dialog.model().dialog().close();
        }
        if let Some(dialog) = self.import_dialog.take() {
            dialog.model().dialog().close();
        }
        if let Some(window) = self.window() {
            for action in &self.actions {
                window.remove_action(action);
            }
        }
        self.close_tabs();
        self.context.active.take();
    }

    fn update(&mut self, msg: WorkspaceInput) {
        match msg {
            WorkspaceInput::HealthChanged(health) => self.refresh_health_banner(&health),
            WorkspaceInput::CatalogChanged(snapshot) => self.on_catalog_changed(&snapshot),
            WorkspaceInput::TabCloseDecided { id, approved } => self.on_tab_close_decided(id, approved),
            WorkspaceInput::SelectTable {
                schema,
                name,
                open_mode,
            } => self.dispatch_select_table(schema, name, open_mode),
            WorkspaceInput::WorkspaceTabsChanged => self.on_workspace_tabs_changed(),
            WorkspaceInput::SaveTab(id) => self.request_save(id),
            WorkspaceInput::StopSaving(id) => self.stop_saving(id),
            WorkspaceInput::Workspace(event) => self.on_workspace_event(event),
            WorkspaceInput::SavesInFlightChanged(count) => self.on_saves_in_flight_changed(count),
            WorkspaceInput::EditorTransactionChanged => self.refresh_inhibitor(),
            WorkspaceInput::SaveActiveTab => {
                if let Some(id) = self.selected_workspace_tab_id() {
                    self.request_save(id);
                }
            }
            WorkspaceInput::UndoActiveBrowseTab => {
                // Structure editing has no per-keystroke history: its
                // undo is Discard, and a field's own text undo is GTK's.
                if let Some(id) = self.selected_browse_tab_id() {
                    self.dispatch_to_tab(id, BrowseTabInput::Undo);
                }
            }
            WorkspaceInput::RedoActiveBrowseTab => {
                if let Some(id) = self.selected_browse_tab_id() {
                    self.dispatch_to_tab(id, BrowseTabInput::Redo);
                }
            }
            WorkspaceInput::WorkspaceTabClosed(id) => self.close_workspace_tab_by_id(id),
            WorkspaceInput::CloseOtherWorkspaceTabs(id) => self.close_other_workspace_tabs(id),
            WorkspaceInput::CloseWorkspaceTabsToRight(id) => self.close_workspace_tabs_to_right(id),
            WorkspaceInput::CloseActiveWorkspaceTab => self.close_active_workspace_tab(),
            WorkspaceInput::ShowAlert { title, body } => self.show_error_alert(&title, &body),
            WorkspaceInput::ShowToast(msg) => self.show_toast(&msg),
            WorkspaceInput::BrowseTabDirtyChanged(tab_id, dirty) => {
                self.refresh_browse_tab_dirty(tab_id, dirty);
                self.refresh_inhibitor();
            }
            WorkspaceInput::NewTableTab { schema } => self.on_new_table_tab(schema),
            WorkspaceInput::EditStructureTab { schema, table } => self.on_edit_structure_tab(schema, table),
            WorkspaceInput::ShowCreateTableForExisting { schema, table } => self.on_show_create_table(schema, table),
            WorkspaceInput::ShowCreateTableLoaded(sql) => self.append_editor_tab(Some(sql)),
            WorkspaceInput::DropTablePrompt { schema, table } => self.on_drop_table_prompt(schema, table),
            WorkspaceInput::DropTableConfirmed { schema, table } => self.on_drop_table_confirmed(schema, table),
            WorkspaceInput::DropTableSucceeded(table) => self.on_drop_table_succeeded(table),
            WorkspaceInput::StructureTabDirtyChanged(tab_id, dirty) => {
                self.refresh_structure_tab_dirty(tab_id, dirty);
                self.refresh_inhibitor();
            }
            WorkspaceInput::SchemaChanged { schema, table } => self.on_schema_changed(schema, table),
            WorkspaceInput::NewEditorTab => self.append_editor_tab(None),
            WorkspaceInput::EditorTabRunStateChanged(id, running) => self.on_editor_tab_run_state_changed(id, running),
            WorkspaceInput::EditorTabContentChanged(id) => self.on_editor_tab_content_changed(id),
            WorkspaceInput::WorkspaceLoaded(loaded) => self.on_workspace_loaded(loaded),
            WorkspaceInput::ResetWorkspaceLayout => self.on_reset_workspace_layout(),
            WorkspaceInput::WorkspaceLayoutReset(outcome) => self.on_workspace_layout_reset(outcome),
            WorkspaceInput::ShowHistory => self.on_show_history(),
            WorkspaceInput::ShowSavedQueries => self.on_show_saved_queries(),
            WorkspaceInput::ImportCsvRequested { schema, table } => self.on_import_csv_requested(schema, table),
            WorkspaceInput::ImportCsvReady {
                schema,
                table,
                columns,
                bytes,
            } => self.on_import_csv_ready(schema, table, columns, bytes),
            WorkspaceInput::ImportCsvRun(import) => self.on_import_csv_run(*import),
            WorkspaceInput::SaveActiveQuery => self.on_save_active_query(),
            WorkspaceInput::SaveQueryNamed { name, query } => self.on_save_query_named(name, query),
            WorkspaceInput::OpenHistoryQuery(text) => self.append_editor_tab(Some(text)),
            WorkspaceInput::ReplaceActiveTabQuery(text) => self.on_replace_active_tab_query(text),
            WorkspaceInput::RefreshPage => self.on_refresh_active_tab(),
            WorkspaceInput::ExportResults { result, name, target } => {
                if let Some(window) = self.window() {
                    let dialect = self.context.active.get().and_then(|session| session.current_dialect());
                    super::export_dialog::present(
                        &window,
                        &self.toast_overlay,
                        result,
                        name,
                        target,
                        dialect,
                        &self.settings,
                    );
                }
            }
            WorkspaceInput::CopyToClipboard(text) => self.on_copy_to_clipboard(text),
            WorkspaceInput::ReopenClosedTab => self.on_reopen_closed_tab(),
            WorkspaceInput::ShowFilterDialog => self.on_show_filter_dialog(),
        }
    }
}

fn qualified_label(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{s}.{table}"),
        None => table.to_string(),
    }
}
