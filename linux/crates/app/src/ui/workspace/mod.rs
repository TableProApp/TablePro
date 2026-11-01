//! One connection session's workspace: the sidebar of its tables, the
//! tabs open on them in the tab view of the window's shell, which every
//! session of the window shares, its banners and its assistant. What the
//! shell shows of it while it is in front are its properties. A
//! workspace never changes session; a disconnect drops it, and the
//! window shows the connection picker once it holds no session.

mod assistant;
mod close_flow;
mod definitions;
mod diagram;
mod editor_label;
mod finished_work;
mod health_banner;
mod imp;
mod import;
mod import_ledger;
mod recent_tabs;
mod references;
mod saves;
mod session_watches;
mod sidebar;
mod status_pages;
mod structure;
mod structure_target;
mod tab_factory;
mod tab_identity;
mod tab_index;
mod tab_spec;
mod tab_title;
mod table_naming;
#[cfg(test)]
pub(crate) mod tests;
mod transaction_banner;
mod unsaved_icon;
mod window_tabs;
mod window_title;
mod workspace_actions;
mod workspace_persistence;
mod workspace_shell;
mod workspace_shell_imp;
mod workspace_tab_view;
mod workspace_tabs;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use relm4::{ComponentController, Controller};

use tablepro_core::meta::SchemaInfo;
use tablepro_core::{DataModel, EditorSession};
use tablepro_session::{ObjectListSnapshot, Session, SessionHealth, SessionKey};
use uuid::Uuid;

use self::session_watches::SessionWatches;
use self::tab_title::ConnectionLabel;
pub(crate) use self::workspace_shell::WorkspaceShell;
use super::browse_tab::BrowseTab;
use super::editor::SqlEditor;
use super::export::{ExportLedger, ExportLedgerInit, ExportOffer, ExportReporter};
use super::history_dialog::HistoryDialog;
use super::host_key_failure::HostKeyFailure;
use super::host_key_review::HostKeyReviewOutcome;
use crate::application::AppServices;
use crate::runtime::{DeliverInput, InputSender};
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::session_context::SessionContext;
use crate::services::structure_tracker_registry::StructureTrackerRegistry;
use crate::workspace::{ApplicationInhibit, CloseBlocker, CloseGuards, WindowInhibitor, WorkspaceHandle};

glib::wrapper! {
    pub struct Workspace(ObjectSubclass<imp::Workspace>)
        @extends adw::Bin, gtk::Widget,
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
    /// The window's shell, whose tab view, header bars and sidebar the
    /// workspace shares with the window's other sessions.
    pub shell: WorkspaceShell,
}

pub(crate) type WorkspaceSender = InputSender<WorkspaceInput>;

pub(crate) struct WorkspaceModel {
    context: Rc<SessionContext>,
    /// What the session's tabs are saved under.
    key: SessionKey,
    input: WorkspaceSender,
    this: glib::WeakRef<Workspace>,
    window: glib::WeakRef<adw::ApplicationWindow>,
    shell: glib::WeakRef<WorkspaceShell>,
    settings: Rc<tablepro_storage::AppSettings>,
    storage: crate::storage::SharedStorage,
    tasks: tablepro_session::runtime::Tasks,
    history: crate::services::history_service::HistoryService,
    drafts: Rc<crate::workspace::DraftWriter>,
    saved_connections: Rc<crate::services::saved_connection_list::SavedConnectionList>,
    /// The connection the tabs and the titles name.
    label: Rc<ConnectionLabel>,
    /// The session's assistant pane and what it may send.
    assistant: assistant::AssistantColumn,
    sidebar: sidebar::SidebarView,
    /// The schemas the sidebar's sections are made from, which also
    /// decide whether tab titles name their schema.
    catalog_schemas: Arc<[SchemaInfo]>,
    /// The last schema read the sidebar asked for; an older one landing
    /// late is not shown.
    sidebar_read: u64,
    definition_reads: u64,
    /// The Show Definition read in flight, which a newer one supersedes.
    definition_read: Option<definitions::DefinitionRead>,
    /// Whether every schema's list has landed once. Until then the
    /// sidebar shows the default schema's.
    all_schemas_listed: bool,
    reconnect_banner: adw::Banner,
    transaction_banner: adw::Banner,
    /// Says the sidebar's list could not be read again, until a read
    /// lands.
    catalog_banner: adw::Banner,
    /// Set when the session's engine holds keys, not tables: its sidebar
    /// lists keys, and a key opens in a key tab.
    keys: Option<sidebar::KeySidebar>,
    /// Says the saved tabs could not be read, until Reset moves them
    /// aside.
    layout_banner: adw::Banner,
    /// Removes a changed host key from known_hosts. `None` without ssh.
    ssh: Option<tablepro_ssh::SshServices>,
    file_revealer: Rc<dyn crate::ui::file_reveal::FileRevealer>,
    /// Held until a Replace's ssh-keygen finishes too, so a second
    /// Replace cannot remove the key the first one's retry wrote.
    reviewing_host_key: bool,
    tab_view: adw::TabView,
    /// Which tab each page shows.
    index: Rc<tab_index::TabIndex>,
    /// The session's hold on the shared tab view, let go of at shutdown.
    tab_view_watch: Option<workspace_tabs::TabViewWatch>,
    /// Builds every tab the workspace opens.
    factory: Rc<tab_factory::TabFactory>,
    /// Whether tab titles name the schema, from the session's schemas.
    naming: Rc<Cell<table_naming::TableNaming>>,
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
    close_guards: Rc<CloseGuards>,
    /// The exports running from this workspace's grids.
    exports: Rc<ExportLedger>,
    /// The CSV imports running into this workspace's tables.
    imports: Rc<import_ledger::ImportLedger>,
    history_dialog: Option<HistoryDialog>,
    saved_queries_dialog: Option<Controller<super::saved_queries_dialog::SavedQueriesDialog>>,
    import_dialog: Option<Controller<super::import_dialog::ImportCsvDialog>>,
    driver_id: String,
    /// The driver as the user knows it, for the header's subtitle.
    driver_name: String,
    /// Writes the tab list a moment after the last change.
    workspace: Rc<workspace_persistence::WorkspacePersistence>,
    _watches: SessionWatches,
    /// Tells the user once when editor drafts start failing to land.
    _draft_failures: tablepro_session::runtime::WatchForwarder,
}

/// The workspace's own slot: a tab reads it for the session, and it
/// empties when the workspace goes.
fn session_slot(window_context: &SessionContext, session: &Arc<Session>) -> Rc<SessionContext> {
    let context = Rc::new(SessionContext {
        active: crate::services::active_session::ActiveSession::new(),
        ..window_context.clone()
    });
    context.active.replace(session.clone());
    context
}

fn window_inhibitor(window: &adw::ApplicationWindow) -> WindowInhibitor {
    WindowInhibitor::new(ApplicationInhibit::new(window))
}

/// Where the session's editor tabs write their text.
fn draft_writer(
    storage: &crate::storage::SharedStorage,
    tasks: &tablepro_session::runtime::Tasks,
) -> Rc<crate::workspace::DraftWriter> {
    crate::workspace::DraftWriter::new(
        tablepro_storage::DraftStore::new(storage.paths().drafts_dir()),
        tasks.clone(),
    )
}

/// What the session's engine holds: tables, keys or collections.
fn data_model(context: &SessionContext, session: &Session) -> DataModel {
    context
        .drivers
        .get(&session.metadata().driver_id)
        .map_or(DataModel::Relational, |driver| driver.capabilities().data_model)
}

/// The driver's name, or its id when this build has no such driver.
fn driver_display_name(context: &SessionContext, driver_id: &str) -> String {
    context
        .drivers
        .get(driver_id)
        .map_or_else(|| driver_id.to_owned(), |driver| driver.display_name().to_owned())
}

/// Tells the user once each time editor drafts start failing to land.
fn draft_failure_watch(
    drafts: &crate::workspace::DraftWriter,
    input: &WorkspaceSender,
) -> tablepro_session::runtime::WatchForwarder {
    let failing = input.clone();
    tablepro_session::runtime::WatchForwarder::new(
        drafts.failing(),
        move |failed: bool| {
            if failed {
                failing.deliver(WorkspaceInput::DraftsNotSaved);
            }
        },
        sidebar::spawn_local,
    )
}

/// The connection as the session's tabs and titles name it.
fn connection_label(key: &SessionKey, services: &AppServices, context: &SessionContext) -> Rc<ConnectionLabel> {
    Rc::new(ConnectionLabel::new(
        key.clone(),
        services.saved_connections.clone(),
        context.active.clone(),
    ))
}

/// What the tab view's parts are built from.
struct TabsInit<'a> {
    key: &'a SessionKey,
    session: &'a Arc<Session>,
    services: &'a AppServices,
    context: &'a Rc<SessionContext>,
    drafts: &'a Rc<crate::workspace::DraftWriter>,
    exports: &'a Rc<ExportLedger>,
    label: &'a Rc<ConnectionLabel>,
}

struct WorkspaceTabParts {
    tab_view: adw::TabView,
    index: Rc<tab_index::TabIndex>,
    workspace_tabs: workspace_persistence::WorkspaceTabs,
    change_trackers: Rc<ChangeTrackerRegistry>,
    structure_trackers: Rc<StructureTrackerRegistry>,
    naming: Rc<Cell<table_naming::TableNaming>>,
    factory: Rc<tab_factory::TabFactory>,
    workspace_handle: WorkspaceHandle,
    /// What the session's assistant may send, which editor tabs ask.
    assistant: Rc<crate::ui::assistant::AssistantAccess>,
    tab_view_watch: workspace_tabs::TabViewWatch,
}

/// Snapshot of a tab the user just closed, which the shell keeps for
/// Ctrl+Shift+T, so a reopen builds its tab the way a restore does,
/// through a `TabSpec`. Pending edits are not kept: the close has
/// already cleared them.
#[derive(Debug, Clone)]
pub enum ClosedTabDescriptor {
    Editor {
        query: String,
        file: Option<crate::workspace::EditorFileRecord>,
        database: Option<String>,
    },
    Table {
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
        filter: tablepro_core::FilterSet,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
    Diagram {
        schema: Option<String>,
        places: Vec<crate::workspace::DiagramPlace>,
    },
    Key {
        key: String,
    },
}

pub(super) const CLOSED_TABS_CAPACITY: usize = 10;

pub struct EditorTabSlot {
    pub editor: SqlEditor,
    pub page: adw::TabPage,
    /// The file this tab's text is written to. The text itself lives in
    /// the buffer, not here.
    pub draft: tablepro_storage::DraftId,
    /// Its number among the editor tabs when it opened, which names it
    /// while it has no text.
    pub ordinal: usize,
    /// What the tab is named after, kept so titling the tabs again does
    /// not read the buffer.
    pub label: editor_label::EditorLabel,
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

/// A tab showing a schema's ER diagram.
pub struct DiagramTabSlot {
    pub page: adw::TabPage,
    pub schema: Option<String>,
    pub diagram: crate::ui::diagram::DiagramTab,
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

/// A tab showing one key of a key-value engine.
pub struct KeyTabSlot {
    pub page: adw::TabPage,
    pub tab: crate::ui::key_tab::KeyTab,
}

/// A tab in the unified workspace.
///
/// - **Table**: one (schema, table) entity in Data (Browse grid)
///   view. Default for every sidebar single-click.
/// - **Editor**: a free-form SQL workspace, orthogonal to any one
///   table.
/// - **Structure**: the DDL editor, for a new table's draft or an
///   existing table.
/// - **Diagram**: a schema's ER diagram.
pub enum WorkspaceTab {
    Editor(EditorTabSlot),
    Structure(StructureTabSlot),
    Table(TableTabSlot),
    Diagram(DiagramTabSlot),
    Key(KeyTabSlot),
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

    /// The sidebar row the tab shows: its table, or its key.
    pub(crate) fn sidebar_object(&self) -> Option<tablepro_core::meta::TableRef> {
        match self {
            WorkspaceTab::Table(s) => Some(tablepro_core::meta::TableRef::new(s.schema.clone(), s.table.clone())),
            WorkspaceTab::Key(s) => Some(tablepro_core::meta::TableRef::unqualified(s.tab.key())),
            WorkspaceTab::Editor(_) | WorkspaceTab::Structure(_) | WorkspaceTab::Diagram(_) => None,
        }
    }

    pub fn page(&self) -> &adw::TabPage {
        match self {
            WorkspaceTab::Editor(slot) => &slot.page,
            WorkspaceTab::Structure(slot) => &slot.page,
            WorkspaceTab::Table(slot) => &slot.page,
            WorkspaceTab::Diagram(slot) => &slot.page,
            WorkspaceTab::Key(slot) => &slot.page,
        }
    }

    /// The database an editor tab moved to off the connection's.
    pub(crate) fn moved_to(&self) -> Option<String> {
        match self {
            WorkspaceTab::Editor(slot) => slot.editor.tab_database(),
            _ => None,
        }
    }

    /// What the tab's title is made from.
    pub(crate) fn identity(&self) -> tab_identity::TabIdentity {
        use tab_identity::TabIdentity;
        match self {
            WorkspaceTab::Editor(slot) => TabIdentity::Editor(slot.label.clone()),
            WorkspaceTab::Structure(slot) => TabIdentity::Structure(structure_target::StructureTarget::of(
                slot.schema.as_deref(),
                &slot.table,
            )),
            WorkspaceTab::Table(slot) => TabIdentity::Table(tablepro_core::meta::TableRef::new(
                slot.schema.clone(),
                slot.table.clone(),
            )),
            WorkspaceTab::Diagram(slot) => TabIdentity::Diagram(slot.schema.clone()),
            WorkspaceTab::Key(slot) => TabIdentity::Key(slot.tab.key().to_owned()),
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

/// A dialog the user already closed has left its window, and closing it
/// again logs a critical.
fn close_if_presented(dialog: &adw::Dialog) {
    if dialog.parent().is_some() {
        dialog.close();
    }
}

#[derive(Debug)]
pub(crate) enum WorkspaceInput {
    HealthChanged(SessionHealth),
    /// Another session's tab came into the bar, or the last one left it.
    SharesBar,
    /// The banner's Review Key, for a session parked on a host key.
    ReviewHostKey,
    HostKeyReviewed {
        failure: HostKeyFailure,
        outcome: HostKeyReviewOutcome,
    },
    /// ssh-keygen removed the changed key, or says why it could not.
    OldHostKeyForgotten {
        failure: HostKeyFailure,
        forgotten: Result<(), String>,
    },
    /// Every schema's object list landed: a reconnect read it again, or
    /// a schema change refreshed it.
    CatalogChanged(ObjectListSnapshot),
    /// A refresh of that list failed, and the list stays as it was.
    CatalogReadFailed(String),
    /// Read the session's tables again: the sidebar's Refresh, or a run
    /// in the editor that changed them.
    RefreshCatalog,
    /// The default schema's list landed, as a reconnect commits it.
    DefaultListCommitted(ObjectListSnapshot),
    /// An object list indexed for the sidebar, with the schemas its
    /// sections were made from.
    SidebarRead {
        read: u64,
        listing: sidebar::SidebarListing,
    },
    /// List a key-value engine's keys again, as the search now asks.
    ListKeys,
    /// The keys a listing found, indexed for the sidebar, or why they
    /// could not be listed.
    KeysListed(sidebar::KeysListed),
    /// A reconnect replaced the connection.
    LinkChanged,
    SelectTable {
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
    },
    NewEditorTab,
    CloseActiveWorkspaceTab,
    EditorTabRunStateChanged(Uuid, bool),
    EditorTabRunFinished(Uuid, crate::workspace::WorkOutcome),
    EditorTabContentChanged(Uuid),
    /// An editor tab was saved, opened a file, or its text came to
    /// differ from its file's or match it again.
    EditorTabFileChanged(Uuid),
    /// An editor tab moved to another database, which its record keeps
    /// and its title names.
    EditorTabDatabaseChanged(Uuid),
    /// The session's saved tabs and their editor text, read off the GTK
    /// thread.
    WorkspaceLoaded(workspace_tabs::LoadedWorkspace),
    /// The banner's Reset: move the unreadable saved tabs aside.
    ResetWorkspaceLayout,
    /// The session moved to another Safe Mode level, which the title names.
    SafeModeChanged,
    /// Completion in editor tab `tab_id` reads `session`'s catalog, its
    /// database's, or its own connection's again with `None`.
    FollowCatalog {
        tab_id: Uuid,
        session: Option<Arc<Session>>,
    },
    /// Another database of the connection opened beside it.
    DatabaseOpened(Arc<Session>),
    /// The saved connections changed, the title's icon perhaps with them.
    SavedConnectionsChanged,
    WorkspaceLayoutReset(Result<Option<std::path::PathBuf>, crate::workspace::WorkspaceSaveError>),
    /// An editor draft failed to land after the last one did.
    DraftsNotSaved,
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
        columns: Vec<tablepro_core::import::ImportColumn>,
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
        tab: Uuid,
        offer: Box<ExportOffer>,
    },
    /// An export a tab offered ended.
    ExportEnded {
        tab: Uuid,
        outcome: crate::workspace::WorkOutcome,
    },
    WorkspaceTabClosed(Uuid),
    /// Close the tab as its close button does, prompts and all.
    CloseWorkspaceTab(Uuid),
    /// The tab order, the selection or a tab's state changed, so the
    /// workspace is saved.
    WorkspaceTabsChanged,
    SaveTab(Uuid),
    StopSaving(Uuid),
    /// A save started or settled, or tabs' changes were dropped.
    Workspace(crate::workspace::WorkspaceEvent),
    SavesInFlightChanged(usize),
    /// An editor tab's transaction opened, failed or ended.
    EditorTransactionChanged,
    /// The transaction banner's Show.
    ShowTransactionTab,
    ShowAlert {
        title: String,
        body: String,
    },
    ShowToast(String),
    /// A table or structure tab gained or lost unsaved changes.
    TabDirtyChanged,
    NewTableTab {
        schema: Option<String>,
    },
    /// The schema's ER diagram: its tab, or a new one.
    ShowDiagram {
        schema: Option<String>,
    },
    ShowDefinition(tablepro_core::meta::ObjectInfo),
    DefinitionLoaded {
        read: u64,
        object: tablepro_core::meta::ObjectInfo,
        result: Result<Option<tablepro_core::meta::ObjectDefinition>, tablepro_session::OperationError>,
    },
    EditStructureTab {
        schema: Option<String>,
        table: String,
    },
    ShowCreateTableForExisting {
        schema: Option<String>,
        table: String,
    },
    /// SQL to work on in a new editor tab, moved to `database` when the
    /// text only runs there.
    OpenSqlInEditor {
        sql: String,
        database: Option<String>,
    },
    DropTablePrompt {
        schema: Option<String>,
        table: String,
    },
    /// The foreign keys on other tables that point at the table, read
    /// before the prompt asks to drop it.
    DropTableChecked {
        table: tablepro_core::TableRef,
        referencing: Vec<tablepro_core::ddl::InboundForeignKey>,
    },
    DropTableConfirmed {
        schema: Option<String>,
        table: String,
    },
    /// The table is gone, so its tabs close without asking.
    DropTableSucceeded(tablepro_core::TableRef),
    /// A table tab's grid asked to open the rows a foreign key leads to.
    FollowReference {
        tab: uuid::Uuid,
        reference: Box<tablepro_core::browse::RowReference>,
    },
    /// Whether the table a key names is in its schema, read before a
    /// tab opens on it. `None` when the list could not be read.
    ReferenceChecked {
        tab: uuid::Uuid,
        reference: Box<tablepro_core::browse::RowReference>,
        found: Option<bool>,
    },
    SchemaChanged {
        schema: Option<String>,
        table: Option<String>,
    },
    /// Ctrl+Shift+T reopens a tab this session closed last.
    ReopenClosedTab(ClosedTabDescriptor),
    /// A browse tab's F5.
    RefreshTab(Uuid),
    /// Bring the tab to the front, for a notification about it.
    FocusTab(Uuid),
    /// An editor tab asked the assistant about a statement.
    AskAssistant(Box<crate::ui::assistant::AssistantRequest>),
    /// A code block's Insert.
    InsertFromAssistant(String),
    /// The provider or a preference of the assistant changed.
    AssistantChanged,
}

/// The exports this workspace's grids start, listed in the shell's
/// operations button once the shell holds the workspace, and reported in
/// its toasts.
fn export_ledger(
    shell: &WorkspaceShell,
    window: &adw::ApplicationWindow,
    services: &AppServices,
    context: &SessionContext,
    input: &WorkspaceSender,
) -> Rc<ExportLedger> {
    let exports = ExportLedger::new(ExportLedgerInit {
        tasks: services.tasks.clone(),
        hold: context.hold.clone(),
        reporter: ExportReporter::new(window, &shell.toast_overlay(), services.file_revealer.clone()),
        inhibitor: window_inhibitor(window),
    });
    let ended = input.clone();
    exports.on_ended(move |tab, outcome| ended.deliver(WorkspaceInput::ExportEnded { tab, outcome }));
    exports
}

/// The tab view's registries, the factory that builds every tab into
/// them, and the handle that saves and settles their changes.
fn build_tabs(shell: &WorkspaceShell, init: TabsInit<'_>, input: &WorkspaceSender) -> WorkspaceTabParts {
    let TabsInit {
        key,
        session,
        services,
        context,
        drafts,
        exports,
        label,
    } = init;
    let engine = driver_display_name(context, &session.metadata().driver_id);
    let assistant = assistant::access(services, key, context.active.clone(), engine);
    let change_trackers = Rc::new(ChangeTrackerRegistry::default());
    let structure_trackers = Rc::new(StructureTrackerRegistry::default());
    let workspace_tabs: workspace_persistence::WorkspaceTabs = Rc::new(RefCell::new(HashMap::new()));
    let index = Rc::new(tab_index::TabIndex::default());
    let tab_view = shell.tab_view();
    let window_tabs = Rc::new(window_tabs::WindowTabs::new(
        workspace_tabs.clone(),
        index.clone(),
        &tab_view,
    ));
    let events = input.clone();
    let workspace_handle = WorkspaceHandle::new(crate::workspace::WorkspaceDeps {
        session: context.active.clone(),
        tasks: context.tasks.clone(),
        hold: context.hold.clone(),
        history: Some(services.history()),
        rows: change_trackers.clone(),
        structures: structure_trackers.clone(),
        directory: window_tabs,
        events: Rc::new(move |event| events.deliver(WorkspaceInput::Workspace(event))),
        engine: crate::workspace::EngineProfile::of(&context.drivers, &session.metadata().driver_id),
    });
    let saves = input.clone();
    workspace_handle
        .ledger()
        .on_change(move |count| saves.deliver(WorkspaceInput::SavesInFlightChanged(count)));

    let naming = Rc::new(Cell::new(table_naming::TableNaming::default()));
    let factory = tab_factory::TabFactory::new(tab_factory::TabFactoryParts {
        view: tab_view.clone(),
        tabs: workspace_tabs.clone(),
        index: index.clone(),
        input: input.clone(),
        shell: shell.downgrade(),
        toasts: shell.toast_overlay().downgrade(),
        context: context.clone(),
        settings: services.settings.clone(),
        storage: services.storage.clone(),
        history: Some(services.history()),
        drafts: drafts.clone(),
        draft_scope: crate::workspace::WorkspaceFileName::for_key(key).draft_scope(),
        change_trackers: change_trackers.clone(),
        structure_trackers: structure_trackers.clone(),
        exports: exports.clone(),
        read_only: session.read_only(),
        naming: naming.clone(),
        label: label.clone(),
        assistant: assistant.clone(),
        snippets: services.snippets.clone(),
    });
    let tab_view_watch = workspace_tabs::connect_tab_view(&tab_view, &index, input);
    WorkspaceTabParts {
        tab_view,
        index,
        workspace_tabs,
        change_trackers,
        structure_trackers,
        naming,
        factory,
        workspace_handle,
        assistant,
        tab_view_watch,
    }
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
            shell,
        } = init;
        let workspace: Self = glib::Object::new();
        let imp = workspace.imp();
        imp.shell.set(Some(&shell));
        let input = workspace.pump_inputs();
        let _ = imp.sender.set(input.clone());
        let _ = imp.key.set(key.clone());
        let context = session_slot(&context, &session);
        let storage = services.storage.clone();
        let tasks = services.tasks.clone();
        let drafts = draft_writer(&storage, &tasks);
        let persistence = workspace_persistence::WorkspacePersistence::new(storage.workspaces().clone());
        let exports = export_ledger(&shell, &window, &services, &context, &input);
        let imports = import_ledger::ImportLedger::new(context.hold.clone(), window_inhibitor(&window));
        let data = data_model(&context, &session);
        let _ = imp.data_model.set(data);
        let sidebar = sidebar::build(&input, &session, &tasks, data);
        let label = connection_label(&key, &services, &context);
        let tabs = build_tabs(
            &shell,
            TabsInit {
                key: &key,
                session: &session,
                services: &services,
                context: &context,
                drafts: &drafts,
                exports: &exports,
                label: &label,
            },
            &input,
        );
        let _ = imp.index.set(tabs.index.clone());
        imp.factory.replace(Some(tabs.factory.clone()));
        let assistant = assistant::install(&tabs, &input);
        let _ = imp.assistant_pane.set(assistant.pane());
        let watches = SessionWatches::new(&session, &services.saved_connections, &input);
        let draft_failures = draft_failure_watch(&drafts, &input);
        transaction_banner::connect_show(&imp.transaction_banner, &input);

        let model = WorkspaceModel {
            assistant,
            driver_name: driver_display_name(&context, &session.metadata().driver_id),
            driver_id: session.metadata().driver_id.clone(),
            context,
            key,
            input,
            this: workspace.downgrade(),
            window: window.downgrade(),
            shell: shell.downgrade(),
            settings: services.settings.clone(),
            storage,
            tasks,
            history: services.history(),
            drafts,
            saved_connections: services.saved_connections.clone(),
            label,
            sidebar,
            catalog_schemas: Arc::from([]),
            sidebar_read: 0,
            definition_reads: 0,
            definition_read: None,
            all_schemas_listed: false,
            reconnect_banner: imp.reconnect_banner.get(),
            transaction_banner: imp.transaction_banner.get(),
            catalog_banner: imp.catalog_banner.get(),
            keys: (data == DataModel::KeyValue).then(|| sidebar::KeySidebar::new(imp.key_limit_banner.get())),
            layout_banner: imp.layout_banner.get(),
            ssh: services.ssh(),
            file_revealer: services.file_revealer.clone(),
            reviewing_host_key: false,
            tab_view: tabs.tab_view,
            index: tabs.index,
            tab_view_watch: Some(tabs.tab_view_watch),
            factory: tabs.factory,
            naming: tabs.naming,
            workspace_tabs: tabs.workspace_tabs,
            change_trackers: tabs.change_trackers,
            structure_trackers: tabs.structure_trackers,
            workspace_handle: tabs.workspace_handle,
            close_guards,
            exports: exports.clone(),
            imports: imports.clone(),
            history_dialog: None,
            saved_queries_dialog: None,
            import_dialog: None,
            workspace: persistence,
            _watches: watches,
            _draft_failures: draft_failures,
        };
        workspace.hold(model, [exports, imports]);
        workspace
    }

    /// Hold the model, and have every close of the window ask the
    /// `blockers` first. The session is named before the shell holds it,
    /// which titles its row and the header bars from these.
    fn hold(&self, model: WorkspaceModel, blockers: [Rc<dyn CloseBlocker>; 2]) {
        model.refresh_title();
        model.refresh_assistant();
        self.imp().model.replace(Some(model));
        for blocker in blockers {
            self.register_close_blocker(blocker);
        }
    }

    fn pump_inputs(&self) -> WorkspaceSender {
        let (input, receiver) = crate::runtime::input_queue::<WorkspaceInput>();
        self.imp().pump.replace(Some(crate::runtime::pump_inputs(
            self,
            receiver,
            |workspace, message| workspace.handle_input(message),
        )));
        input
    }

    /// Show the session: its tables, the empty tab area, and the tabs
    /// saved for it. Called once the window listens for the
    /// workspace's signals.
    pub(crate) fn start(&self) {
        self.with_model(WorkspaceModel::open);
    }

    /// The key the session is open under.
    pub(crate) fn key(&self) -> Option<SessionKey> {
        self.imp().key.get().cloned()
    }

    /// What the session's engine holds, which names the page with no
    /// tab open.
    pub(crate) fn data_model(&self) -> Option<DataModel> {
        self.imp().data_model.get().copied()
    }

    /// The tab `page` shows, when it is one of this session's. Read from
    /// the index, so it answers while the workspace handles its input.
    pub(crate) fn tab_id(&self, page: &adw::TabPage) -> Option<Uuid> {
        self.imp().index.get()?.id_of(page)
    }

    /// Whether the session has a tab open.
    pub(super) fn has_tabs(&self) -> bool {
        self.imp().index.get().is_some_and(|index| !index.is_empty())
    }

    /// A page of one of the session's tabs: the one in front if it is,
    /// else the one the user left the session on, else its first.
    pub(super) fn some_page(&self) -> Option<adw::TabPage> {
        let index = self.imp().index.get()?;
        let view = self.imp().shell.upgrade()?.tab_view();
        view.selected_page()
            .filter(|page| index.id_of(page).is_some())
            .or_else(|| index.last_selected().and_then(|id| index.page_of(id)))
            .or_else(|| index.first_in(&view))
    }

    /// What builds the session's tabs, while the session is open.
    fn tab_factory(&self) -> Option<Rc<tab_factory::TabFactory>> {
        self.imp().factory.borrow().clone()
    }

    /// The session's list of tables, which the connection tree shows
    /// under the session's connection.
    pub(super) fn sidebar_view(&self) -> Option<sidebar::SidebarView> {
        self.read(|model| model.sidebar.clone())
    }

    /// The session's assistant, which the shell shows while the session
    /// is in front.
    pub(super) fn assistant_pane(&self) -> Option<crate::ui::assistant::AssistantPane> {
        self.imp().assistant_pane.get().cloned()
    }

    /// Whether the workspace last said it has something to lose.
    pub(crate) fn is_dirty(&self) -> bool {
        self.imp().dirty.get()
    }

    /// The handle a close prompt asks, once a value still typed in a
    /// cell counts as the unsaved change it is.
    pub(crate) fn prompt_handle(&self) -> Option<WorkspaceHandle> {
        self.commit_cell_edits();
        self.handle()
    }

    /// Whether a save of the workspace's is still being written.
    pub(crate) fn is_saving(&self) -> bool {
        self.imp().saving.get()
    }

    /// What the window's actions, the shell, the tabs and background
    /// work send the workspace, whatever it is busy with.
    pub(crate) fn sender(&self) -> Option<WorkspaceSender> {
        self.imp().sender.get().cloned()
    }

    /// The saves and the close prompts' view of the tabs.
    pub(crate) fn handle(&self) -> Option<WorkspaceHandle> {
        self.read(|model| model.workspace_handle.clone())
    }

    /// Make a value typed into a cell an unsaved change, as the focus
    /// leaving the cell does, so the close prompts ask about it.
    pub(crate) fn commit_cell_edits(&self) {
        for browse in self.read(|model| model.browse_tabs(None)).unwrap_or_default() {
            browse.commit_cell_edit();
        }
    }

    /// The exports running from this workspace.
    pub(crate) fn exports(&self) -> Option<Rc<ExportLedger>> {
        self.read(|model| model.exports.clone())
    }

    /// Have every close of the window ask about `blocker`'s work first.
    pub(crate) fn register_close_blocker(&self, blocker: Rc<dyn CloseBlocker>) {
        self.with_model(|model| model.workspace_handle.register_close_blocker(blocker));
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
    /// reply still on its way is dropped with the input queue. With
    /// `close_pages` its pages leave the shared tab view too, for a
    /// window that keeps its other sessions; a window that closes whole
    /// lets the view go with its shell, so no session sees another's page
    /// come forward as it goes.
    pub(crate) fn shutdown(&self, close_pages: bool) {
        let imp = self.imp();
        imp.factory.take();
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
            model.shutdown(close_pages);
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

/// Replace `cell`'s text, saying whether it changed.
fn replace_text(cell: &RefCell<String>, text: &str) -> bool {
    if *cell.borrow() == text {
        return false;
    }
    cell.replace(text.to_owned());
    true
}

impl WorkspaceModel {
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

    /// Whether the shell has this session in front.
    pub(super) fn is_front(&self) -> bool {
        let front = self.shell.upgrade().and_then(|shell| shell.front());
        front.is_some_and(|front| Some(front) == self.this.upgrade())
    }

    /// Show the session it was built for: the sidebar, the empty tab
    /// area, and the tabs saved for it.
    fn open(&mut self) {
        self.reconnect_banner.set_revealed(false);
        tracing::info!(driver = %self.driver_id, "workspace ready");
        self.open_sidebar();
        self.refresh_title();
        self.restore_workspace_tabs(self.key.clone());
        self.refresh_unsaved();
    }

    /// Name the session after the tab it was left on and the connection,
    /// for the header bars and the window's title while it is in front.
    pub(super) fn refresh_title(&self) {
        let Some(workspace) = self.this.upgrade() else {
            return;
        };
        let imp = workspace.imp();
        let name = self.label.name();
        let active = self.index.last_selected().and_then(|id| self.tab_title(id));
        let safe_mode = self
            .context
            .active
            .get()
            .map_or_else(Default::default, |session| session.safe_mode());
        let title = window_title::resolve_window_title(active.as_ref(), &name, &self.driver_name, safe_mode);
        if replace_text(&imp.title, &title.heading) {
            workspace.notify_title();
        }
        if replace_text(&imp.subtitle, &title.subtitle) {
            workspace.notify_subtitle();
        }
        if replace_text(&imp.window_title, &title.window) {
            workspace.notify_window_title();
        }
        if replace_text(&imp.connection_name, &name) {
            workspace.notify_connection_name();
        }
        let icon = match &self.key {
            SessionKey::Saved(id) | SessionKey::SavedIn { id, .. } => {
                self.saved_connections.get(*id).and_then(|saved| saved.icon)
            }
            SessionKey::File(_) => None,
        }
        .map(|icon| crate::ui::icons::connection_icon(icon).to_owned());
        if *imp.icon_name.borrow() != icon {
            imp.icon_name.replace(icon);
            workspace.notify_icon_name();
        }
    }

    /// The title tab `id` shows.
    pub(super) fn tab_title(&self, id: Uuid) -> Option<tab_title::TabTitle> {
        let identity = self.workspace_tabs.borrow().get(&id)?.identity();
        Some(tab_title::resolve_tab_title(&identity, self.naming.get()))
    }

    /// Title tab `id` again, after what it shows changed.
    pub(super) fn retitle_tab(&self, id: Uuid) {
        let Some(title) = self.tab_title(id) else {
            return;
        };
        if let Some(tab) = self.workspace_tabs.borrow().get(&id) {
            tab_title::apply_tab_title(tab.page(), &title, &self.label, tab.moved_to().as_deref());
        }
        if self.index.last_selected() == Some(id) {
            self.refresh_title();
        }
        self.refresh_transaction_banner();
    }

    /// Title every tab again when the schemas change whether table tabs
    /// name their schema.
    pub(super) fn on_table_naming(&self, naming: table_naming::TableNaming) {
        if self.naming.replace(naming) == naming {
            return;
        }
        self.retitle_tabs();
    }

    /// Title every tab again when another session's tab comes into the
    /// bar beside this one's, or the last one leaves.
    fn on_shares_bar(&self) {
        let (Some(shell), Some(this)) = (self.shell.upgrade(), self.this.upgrade()) else {
            return;
        };
        if self.label.set_shares_bar(shell.others_have_tabs(&this)) {
            self.retitle_tabs();
        }
    }

    /// A rename, an icon or a policy changed, perhaps this connection's.
    fn on_saved_connections_changed(&self) {
        self.retitle_tabs();
        self.refresh_assistant();
    }

    fn retitle_tabs(&self) {
        let ids: Vec<Uuid> = self.workspace_tabs.borrow().keys().copied().collect();
        for id in ids {
            self.retitle_tab(id);
        }
        self.refresh_title();
    }

    fn shutdown(mut self, close_pages: bool) {
        self.assistant.shutdown();
        if let Some(keys) = self.keys.as_mut() {
            keys.stop_listing();
        }
        self.sidebar.shutdown();
        // Their entries name this session's tables and queries.
        if let Some(dialog) = self.history_dialog.take() {
            close_if_presented(dialog.upcast_ref());
        }
        if let Some(dialog) = self.saved_queries_dialog.take() {
            close_if_presented(dialog.model().dialog());
        }
        if let Some(dialog) = self.import_dialog.take() {
            close_if_presented(dialog.model().dialog());
        }
        let pages = if close_pages { self.index.pages() } else { Vec::new() };
        self.close_tabs();
        if let Some(watch) = self.tab_view_watch.take() {
            watch.release(pages);
        }
        // The close asked about them already; one started since has no
        // window left to finish in.
        self.exports.shut_down();
        self.imports.shut_down();
        self.context.active.take();
    }

    fn on_export_results(&self, tab: Uuid, offer: ExportOffer) {
        if let Some(window) = self.window() {
            let dialect = self.context.active.get().and_then(|session| session.current_dialect());
            super::export::dialog::present(super::export::dialog::ExportDialogInit {
                parent: &window,
                exports: &self.exports,
                offer,
                dialect,
                settings: &self.settings,
                tab,
            });
        }
    }

    fn update(&mut self, msg: WorkspaceInput) {
        match msg {
            WorkspaceInput::HealthChanged(health) => self.refresh_health_banner(&health),
            WorkspaceInput::ReviewHostKey => self.on_review_host_key(),
            WorkspaceInput::HostKeyReviewed { failure, outcome } => self.on_host_key_reviewed(failure, outcome),
            WorkspaceInput::OldHostKeyForgotten { failure, forgotten } => {
                self.on_old_host_key_forgotten(failure, forgotten);
            }
            WorkspaceInput::CatalogChanged(snapshot) => self.on_catalog_changed(snapshot),
            WorkspaceInput::CatalogReadFailed(message) => self.on_catalog_read_failed(&message),
            WorkspaceInput::RefreshCatalog => self.refresh_catalog(),
            WorkspaceInput::DefaultListCommitted(snapshot) => self.on_default_list_committed(snapshot),
            WorkspaceInput::SidebarRead { read, listing } => self.on_sidebar_read(read, listing),
            WorkspaceInput::ListKeys => self.list_keys(),
            WorkspaceInput::KeysListed(listed) => self.on_keys_listed(listed),
            WorkspaceInput::LinkChanged => self.on_link_changed(),
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
            WorkspaceInput::EditorTransactionChanged => {
                self.refresh_unsaved();
                self.refresh_transaction_banner();
            }
            WorkspaceInput::ShowTransactionTab => self.show_transaction_tab(),
            WorkspaceInput::WorkspaceTabClosed(id) => self.close_workspace_tab_by_id(id),
            WorkspaceInput::CloseWorkspaceTab(id) => self.close_workspace_tab(id),
            WorkspaceInput::CloseActiveWorkspaceTab => self.close_active_workspace_tab(),
            WorkspaceInput::ShowAlert { title, body } => self.show_error_alert(&title, &body),
            WorkspaceInput::ShowToast(msg) => self.show_toast(&msg),
            WorkspaceInput::TabDirtyChanged => self.refresh_unsaved(),
            WorkspaceInput::NewTableTab { schema } => self.on_new_table_tab(schema),
            WorkspaceInput::ShowDiagram { schema } => self.show_diagram(schema, Vec::new()),
            WorkspaceInput::ShowDefinition(object) => self.on_show_definition(object),
            WorkspaceInput::DefinitionLoaded { read, object, result } => self.on_definition_loaded(read, &object, result),
            WorkspaceInput::EditStructureTab { schema, table } => self.on_edit_structure_tab(schema, table),
            WorkspaceInput::ShowCreateTableForExisting { schema, table } => self.on_show_create_table(schema, table),
            WorkspaceInput::OpenSqlInEditor { sql, database } => self.open_sql_in_editor(sql, database),
            WorkspaceInput::DropTablePrompt { schema, table } => self.on_drop_table_prompt(schema, table),
            WorkspaceInput::DropTableChecked { table, referencing } => self.on_drop_table_checked(table, &referencing),
            WorkspaceInput::DropTableConfirmed { schema, table } => self.on_drop_table_confirmed(schema, table),
            WorkspaceInput::DropTableSucceeded(table) => self.on_drop_table_succeeded(table),
            WorkspaceInput::FollowReference { tab, reference } => self.on_follow_reference(tab, *reference),
            WorkspaceInput::ReferenceChecked { tab, reference, found } => {
                self.on_reference_checked(tab, *reference, found);
            }
            WorkspaceInput::SchemaChanged { schema, table } => self.on_schema_changed(schema, table),
            WorkspaceInput::NewEditorTab => self.open_editor_tab(None),
            WorkspaceInput::EditorTabRunStateChanged(id, running) => self.on_editor_tab_run_state_changed(id, running),
            WorkspaceInput::EditorTabRunFinished(id, outcome) => {
                self.report_work(id, crate::workspace::WorkKind::Query, outcome);
                self.on_editor_run_finished(id);
            }
            WorkspaceInput::EditorTabContentChanged(id) => self.on_editor_tab_content_changed(id),
            WorkspaceInput::EditorTabFileChanged(id) => self.on_editor_tab_file_changed(id),
            WorkspaceInput::EditorTabDatabaseChanged(id) => self.on_editor_tab_database_changed(id),
            WorkspaceInput::FollowCatalog { tab_id, session } => self.follow_catalog(tab_id, session),
            WorkspaceInput::DatabaseOpened(session) => self.on_database_opened(&session),
            WorkspaceInput::WorkspaceLoaded(loaded) => self.on_workspace_loaded(loaded),
            WorkspaceInput::ResetWorkspaceLayout => self.on_reset_workspace_layout(),
            WorkspaceInput::SafeModeChanged => self.refresh_title(),
            WorkspaceInput::SharesBar => self.on_shares_bar(),
            WorkspaceInput::SavedConnectionsChanged => self.on_saved_connections_changed(),
            WorkspaceInput::WorkspaceLayoutReset(outcome) => self.on_workspace_layout_reset(outcome),
            WorkspaceInput::DraftsNotSaved => self.show_toast(&crate::i18n::gettext(
                "Editor text could not be saved to disk, so it may not come back after TablePro restarts.",
            )),
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
            WorkspaceInput::OpenHistoryQuery(text) => self.open_editor_tab(Some(text)),
            WorkspaceInput::ReplaceActiveTabQuery(text) => self.on_replace_active_tab_query(text),
            WorkspaceInput::RefreshPage => self.on_refresh_active_tab(),
            WorkspaceInput::ExportResults { tab, offer } => self.on_export_results(tab, *offer),
            WorkspaceInput::ExportEnded { tab, outcome } => {
                self.report_work(tab, crate::workspace::WorkKind::Export, outcome);
            }
            WorkspaceInput::ReopenClosedTab(tab) => self.on_reopen_closed_tab(tab),
            WorkspaceInput::RefreshTab(id) => self.on_refresh_tab(id),
            WorkspaceInput::FocusTab(id) => self.focus_tab(id),
            WorkspaceInput::AskAssistant(request) => self.on_ask_assistant(*request),
            WorkspaceInput::InsertFromAssistant(code) => self.on_insert_from_assistant(code),
            WorkspaceInput::AssistantChanged => self.refresh_assistant(),
        }
    }
}
