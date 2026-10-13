mod close_flow;
mod connect_flow;
mod connection;
mod import;
mod row_ops;
mod saves;
mod sidebar_section_header;
mod status_pages;
mod structure;
mod window_tabs;
mod workspace_persistence;
mod workspace_tabs;

use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::gtk::{gio, glib};
use relm4::prelude::*;
use relm4::{Controller, adw, gtk};

use tablepro_core::QueryResult;
use tablepro_session::{ObjectListSnapshot, SessionHealth};
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::browse_tab::{BrowseTab, BrowseTabInput};
use super::connect_dialog::ConnectDialog;
use super::connection_row::{ConnectionRow, ConnectionRowOutput};
use super::editor::SqlEditor;
use super::history_dialog::HistoryDialog;
use super::sidebar_row::{SidebarRow, SidebarRowOutput};
use super::welcome_view::{WelcomeView, WelcomeViewInit, WelcomeViewOutput};
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::from_session::FromSession;
use crate::services::session_context::SessionContext;
use crate::services::structure_tracker_registry::StructureTrackerRegistry;

pub(crate) use connection::{ConnectRetry, ReadySession};

/// What `run()` hands the root component: the session services and the
/// settings it opened before GTK started.
pub struct AppInit {
    pub context: std::rc::Rc<SessionContext>,
    /// Credential prompts waiting for a window to show them in.
    pub prompts: crate::ui::credential_prompt::PromptQueue,
    pub settings: std::rc::Rc<tablepro_storage::AppSettings>,
    pub storage: crate::storage::SharedStorage,
    pub tasks: tablepro_session::runtime::Tasks,
    pub history: crate::services::history_service::HistoryService,
}

pub struct App {
    context: std::rc::Rc<SessionContext>,
    /// The adopted session's claim and watchers. Dropping it releases
    /// the registry key and stops the banner and sidebar updates.
    session_links: Option<connection::SessionLinks>,
    /// Ends the credential prompt loop with the window.
    prompt_presenter: glib::JoinHandle<()>,
    /// Which connect attempt is current, so a late result is discarded.
    /// Shared with the close handler, which stops the one in flight.
    connect_attempts: std::rc::Rc<tablepro_session::ConnectAttempts>,
    settings: std::rc::Rc<tablepro_storage::AppSettings>,
    storage: crate::storage::SharedStorage,
    tasks: tablepro_session::runtime::Tasks,
    history: crate::services::history_service::HistoryService,
    drafts: std::rc::Rc<crate::workspace::DraftWriter>,
    window: adw::ApplicationWindow,
    split_view: adw::OverlaySplitView,
    window_title: adw::WindowTitle,
    sidebar_title: adw::WindowTitle,
    disconnect_action: gio::SimpleAction,
    /// Watches `HistoryService` and flips `win.show-history`. Aborted in
    /// `shutdown` so it does not outlive the window it acts on.
    history_gate: glib::JoinHandle<()>,
    sidebar_factory: FactoryVecDeque<SidebarRow>,
    sidebar_schemas: std::rc::Rc<std::cell::RefCell<Vec<Option<String>>>>,
    content_holder: adw::ToolbarView,
    toast_overlay: adw::ToastOverlay,
    /// Persistent "Connecting…" toast handle. Held so we can dismiss it
    /// when the connect attempt resolves (success or failure). Native
    /// alternative to a fire-and-forget 2 s toast that disappeared
    /// before the connection actually completed.
    connect_progress_toast: Option<adw::Toast>,
    reconnect_banner: adw::Banner,
    connection_list_banner: adw::Banner,
    connections_factory: FactoryVecDeque<ConnectionRow>,
    /// The popover list's own list box, kept so the group headers can
    /// be reinstalled whenever the list changes.
    connections_listbox: gtk::ListBox,
    connections_popover: gtk::Popover,
    row_op_spinner: adw::Spinner,
    read_only_badge: gtk::Label,
    table_search: gtk::SearchEntry,
    /// `"empty"` while no tab is open, `"tabs"` otherwise.
    workspace_outer_stack: gtk::Stack,
    /// AdwTabOverview wrapping the unified AdwTabBar + AdwTabView.
    /// Built lazily on connect; torn down on disconnect.
    workspace_root: Option<adw::TabOverview>,
    workspace_tab_view: Option<adw::TabView>,
    /// Idempotency flag for `ensure_workspace_root`.
    workspace_root_added: std::cell::Cell<bool>,
    /// Per-tab state. Each entry is either a Browse or Editor tab.
    /// HashMap for O(1) tab_id lookup; display order is read from
    /// `tab_view.pages()` since HashMap is unordered.
    workspace_tabs: std::rc::Rc<std::cell::RefCell<std::collections::HashMap<Uuid, WorkspaceTab>>>,
    /// This window's pending row edits, one tracker per Table tab.
    change_trackers: std::rc::Rc<ChangeTrackerRegistry>,
    /// This window's pending DDL, one tracker per Structure tab.
    structure_trackers: std::rc::Rc<StructureTrackerRegistry>,
    /// Starts, stops and settles this window's saves, and says what
    /// closing any part of it would lose.
    workspace_handle: crate::workspace::WorkspaceHandle,
    /// The tabs as the close prompts read them.
    window_tabs: std::rc::Rc<window_tabs::WindowTabs>,
    /// One close prompt at a time, for a tab, the window, a disconnect
    /// or a switch.
    close_guards: std::rc::Rc<crate::workspace::CloseGuards>,
    /// What closing the window still owes its files and connections.
    window_shutdown: std::rc::Rc<close_flow::WindowShutdown>,
    /// Holds logout back while something here would be lost.
    inhibitor: crate::workspace::WindowInhibitor,
    dialog: Option<ConnectDialog>,
    history_dialog: Option<Controller<HistoryDialog>>,
    saved_queries_dialog: Option<Controller<super::saved_queries_dialog::SavedQueriesDialog>>,
    import_dialog: Option<Controller<super::import_dialog::ImportCsvDialog>>,
    welcome_view: Controller<WelcomeView>,
    /// Driver id is connection-wide, not per-tab.
    current_driver_id: Option<String>,
    /// Read-only flag is connection-wide; fanned out to every BrowseTab
    /// when toggled.
    read_only: bool,
    /// Default page size for newly-opened browse tabs (from preferences).
    /// Per-tab page size lives on each BrowseTab.
    saved_connections: Vec<SavedConnection>,
    connected: bool,
    /// Writes the tab list for the session this window shows. Tabs fire
    /// `WorkspaceTabsChanged` on every selection, drag-reorder,
    /// page-size change and state-changed event, and it writes once
    /// after a burst.
    workspace: std::rc::Rc<workspace_persistence::WorkspacePersistence>,
    /// Recently closed tabs for Ctrl+Shift+T. Cleared on disconnect,
    /// since the tables they name belong to that connection. Pending
    /// edits are not kept: the close has already cleared them.
    closed_tabs_stack: std::rc::Rc<std::cell::RefCell<std::collections::VecDeque<ClosedTabDescriptor>>>,
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
pub enum AppMsg {
    OpenConnect,
    /// A connect worked; adopt its session in this window.
    SessionReady(Box<ReadySession>),
    /// The connect dialog's Connect: connect, then save the entry.
    ConnectSubmitted(Box<super::connect_dialog::ConnectSubmission>),
    /// The same, once the user agreed to close the open workspace.
    ConnectSubmissionConfirmed(Box<super::connect_dialog::ConnectSubmission>),
    /// A connect failed. `None` when the user cancelled it, which needs
    /// no error. `edit` reopens the dialog on what was submitted.
    ConnectFailed {
        generation: tablepro_session::connect::AttemptGeneration,
        message: Option<String>,
        edit: Option<Box<ConnectRetry>>,
    },
    /// The Cancel button on the Connecting toast.
    CancelConnect,
    /// Open the connect dialog on a connection that failed to connect,
    /// with the focus on the row that fixes it.
    EditConnection(Box<ConnectRetry>),
    /// The banner's Retry: ask the monitor to reconnect now.
    RetryConnection,
    /// The adopted session's health moved.
    HealthChanged(FromSession<SessionHealth>),
    /// The session's object list for the sidebar changed: a reconnect
    /// read it again, or a schema change refreshed it.
    CatalogChanged(FromSession<ObjectListSnapshot>),
    DialogClosed,
    SelectTable {
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
    },
    ReloadConnections,
    ConnectionsLoaded(Vec<SavedConnection>),
    ConnectionListUnavailable,
    ResetConnectionList,
    SecretDeleteFailed(Uuid),
    OpenSaved(SavedConnection),
    /// Open a saved connection once the user agreed to close the open
    /// workspace.
    OpenSavedConfirmed(SavedConnection),
    DeleteConnection(Uuid),
    DuplicateConnection(SavedConnection),
    /// "+ New query" button or Ctrl+T → append a new editor tab.
    NewEditorTab,
    /// Ctrl+W → close active workspace tab (browse or editor).
    CloseActiveWorkspaceTab,
    EditorTabRunStateChanged(Uuid, bool),
    EditorTabContentChanged(Uuid),
    /// The session's saved tabs and their editor text, read off the GTK
    /// thread.
    WorkspaceLoaded(FromSession<workspace_tabs::LoadedWorkspace>),
    /// The toast's Reset: move the unreadable saved tabs aside.
    ResetWorkspaceLayout,
    WorkspaceLayoutReset(FromSession<Result<Option<std::path::PathBuf>, crate::workspace::WorkspaceSaveError>>),
    ShowHistory,
    ShowSavedQueries,
    /// Keep the active editor tab's SQL under a name the user picks.
    SaveActiveQuery,
    SaveQueryNamed {
        name: String,
        query: String,
    },
    /// A colour picked from a connection row's menu, or `None` when the
    /// user cleared it.
    SetConnectionColor(Uuid, Option<tablepro_storage::ConnectionColor>),
    /// A group picked from a connection row's menu, or `None` when the
    /// user took it out of one.
    SetConnectionGroup(Uuid, Option<String>),
    ExportConnections,
    ImportConnections,
    /// "Import CSV…" from a table's own menu: ask for a file, then
    /// open the mapping dialog against that table's columns.
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
    /// The mapping is settled, so the rows can be written.
    ImportCsvRun(Box<super::import_dialog::CsvImport>),
    /// The file the user picked, read off the GTK thread.
    ConnectionsFileRead {
        path: std::path::PathBuf,
        bytes: Vec<u8>,
    },
    OpenHistoryQuery(String),
    ReplaceActiveTabQuery(String),
    Disconnect,
    /// Tear the connection down, once nothing would be lost or the user
    /// agreed to lose it.
    ForceDisconnect,
    /// The close prompts decided about one tab's close.
    TabCloseDecided {
        id: Uuid,
        approved: bool,
    },
    RefreshPage,
    ShowAbout,
    ShowPreferences,
    ExportResults {
        result: QueryResult,
        name: String,
        target: Option<super::export_dialog::SqlTarget>,
    },
    CopyToClipboard(String),
    CopyRowAsInsert {
        tab_id: Uuid,
        row_position: u32,
    },

    // ── Workspace tab routing ────────────────────────────────────────
    /// User clicked the close-X on any workspace tab.
    WorkspaceTabClosed(Uuid),
    /// Tab right-click "Close Other Tabs" → close every tab except
    /// the one whose context menu was used (per-tab close path so
    /// each tab still gets the unsaved-changes prompt if dirty).
    CloseOtherWorkspaceTabs(Uuid),
    /// Tab right-click "Close Tabs to the Right" → close every tab
    /// after the targeted one in TabView display order.
    CloseWorkspaceTabsToRight(Uuid),
    /// The tab order, the selection or a tab's state changed, so the
    /// workspace is saved.
    WorkspaceTabsChanged,
    /// A tab's own Save: write what its tracker holds.
    SaveTab(Uuid),
    /// A tab's Stop Saving.
    StopSaving(Uuid),
    /// A save started or settled, or tabs' changes were dropped.
    Workspace(crate::workspace::WorkspaceEvent),
    /// The number of saves running in this window changed.
    SavesInFlightChanged(usize),
    /// An editor tab's transaction opened or ended.
    EditorTransactionChanged,
    /// Ctrl+S, for the active tab.
    SaveActiveTab,
    /// Ctrl+Z, for the active Table tab.
    UndoActiveBrowseTab,
    /// Ctrl+Y, for the active Table tab.
    RedoActiveBrowseTab,
    /// Show a small alert dialog; used by BrowseTab for "select exactly
    /// one row" type messages.
    ShowAlert {
        title: String,
        body: String,
    },
    ShowToast(String),
    /// Tracker for a specific browse tab moved between empty / non-empty.
    /// Handler updates that tab's page title to add or remove the
    /// "•" dirty marker. Mirrors GNOME Text Editor's leading-bullet
    /// convention for unsaved buffers.
    BrowseTabDirtyChanged(Uuid, bool),
    /// Sidebar right-click → "New Table…" or schema-header "+" button.
    /// Always appends a fresh draft Structure tab; never matches an
    /// existing tab.
    NewTableTab {
        schema: Option<String>,
    },
    /// Sidebar right-click → "Edit Structure". Switches to an existing
    /// Edit-mode Structure tab for `(schema, table)` if one is open;
    /// otherwise appends a new Edit-mode Structure tab.
    EditStructureTab {
        schema: Option<String>,
        table: String,
    },
    /// Sidebar right-click → "Show CREATE TABLE". The table's
    /// definition goes through the dialect's `create_table_script`, and
    /// the SQL opens in a fresh editor tab.
    ShowCreateTableForExisting {
        schema: Option<String>,
        table: String,
    },
    /// The CREATE statement `ShowCreateTableForExisting` built, for a
    /// new editor tab.
    ShowCreateTableLoaded(FromSession<String>),
    /// Sidebar right-click → "Drop Table…", or in-tab Drop button.
    /// App shows the AdwAlertDialog confirmation; on confirm dispatches
    /// `DropTableConfirmed`.
    DropTablePrompt {
        schema: Option<String>,
        table: String,
    },
    /// The user confirmed the drop.
    DropTableConfirmed {
        schema: Option<String>,
        table: String,
    },
    /// The table is gone, so its tabs close without asking.
    DropTableSucceeded(FromSession<tablepro_core::TableRef>),
    /// Tracker for a Structure tab crossed empty / non-empty boundary.
    /// Mirrors `BrowseTabDirtyChanged` for the title prefix and the
    /// AdwTabPage::set_needs_attention background-tab indicator.
    StructureTabDirtyChanged(Uuid, bool),
    /// Schema state changed (table created / dropped / altered): the
    /// catalog reads the sidebar's list again and drops the table's
    /// columns, and the tabs open on the table read it again.
    SchemaChanged {
        schema: Option<String>,
        table: Option<String>,
    },
    /// Ctrl+Shift+T → pop the most recent closed-tab descriptor and
    /// reopen it. No-op when the stack is empty (e.g. no tabs closed
    /// yet, or just reconnected). Editor tabs come back with their
    /// buffer; Table tabs come back with their schema/table/mode and
    /// last-known pagination, sort, page size.
    ReopenClosedTab,
    /// Ctrl+F → open the filter strip for the active Browse tab.
    /// No-op when the active tab isn't a Browse / Table tab.
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

impl App {
    pub(super) fn dirty_tabs(&self) -> Vec<Uuid> {
        dirty_tabs(&self.change_trackers, &self.structure_trackers)
    }
}

#[relm4::component(pub)]
impl SimpleComponent for App {
    type Init = AppInit;
    type Input = AppMsg;
    type Output = ();

    view! {
        #[name = "window"]
        adw::ApplicationWindow {
            set_title: Some("TablePro"),
            set_default_width: 1200,
            set_default_height: 760,

            adw::ToolbarView {
                #[name = "header_bar"]
                add_top_bar = &adw::HeaderBar {
                    #[name = "window_title"]
                    #[wrap(Some)]
                    set_title_widget = &adw::WindowTitle {
                        set_title: "TablePro",
                    },

                    // Two distinct affordances → two distinct buttons.
                    // SplitButton would imply they're variants of the
                    // same action, but "new connection" and "open
                    // saved" are semantically different (matches GNOME
                    // Files' "New" + "History" pattern, not the
                    // SplitButton-as-Save-with-format pattern).
                    #[name = "new_connection_button"]
                    pack_start = &gtk::Button {
                        set_icon_name: crate::ui::icons::LIST_ADD,
                        set_tooltip_text: Some(crate::i18n::gettext("New connection").as_str()),
                        connect_clicked => AppMsg::OpenConnect,
                    },

                    #[name = "saved_connections_button"]
                    pack_start = &gtk::MenuButton {
                        set_icon_name: crate::ui::icons::DOCUMENT_OPEN,
                        set_tooltip_text: Some(crate::i18n::gettext("Open saved connection").as_str()),

                        #[wrap(Some)]
                        #[name = "connections_popover"]
                        set_popover = &gtk::Popover {},
                    },

                    #[name = "read_only_badge"]
                    pack_end = &gtk::Label {
                        set_visible: false,
                        set_label: &crate::i18n::gettext("Read-only"),
                        set_margin_end: 6,
                        add_css_class: "warning",
                        add_css_class: "caption-heading",
                    },

                    #[name = "row_op_spinner"]
                    pack_end = &adw::Spinner {
                        set_visible: false,
                        set_margin_end: 6,
                        set_tooltip_text: Some(crate::i18n::gettext("Saving…").as_str()),
                    },

                    #[name = "primary_menu_button"]
                    pack_end = &gtk::MenuButton {
                        set_icon_name: crate::ui::icons::OPEN_MENU,
                        set_tooltip_text: Some(crate::i18n::gettext("Main menu").as_str()),
                    },
                },

                #[wrap(Some)]
                #[name = "split_view"]
                set_content = &adw::OverlaySplitView {
                    set_min_sidebar_width: 220.0,
                    set_max_sidebar_width: 280.0,
                    set_show_sidebar: false,

                    // The sidebar has its own header bar for the search
                    // toggle, as GNOME Files does; the window buttons are
                    // on the main one.
                    #[wrap(Some)]
                    #[name = "sidebar_root"]
                    set_sidebar = &adw::ToolbarView {
                        #[name = "sidebar_header"]
                        add_top_bar = &adw::HeaderBar {
                            set_show_start_title_buttons: false,
                            set_show_end_title_buttons: false,

                            #[wrap(Some)]
                            #[name = "sidebar_title"]
                            set_title_widget = &adw::WindowTitle {
                                set_title: &crate::i18n::gettext("Tables"),
                            },

                            #[name = "table_search_toggle"]
                            pack_end = &gtk::ToggleButton {
                                set_icon_name: crate::ui::icons::SYSTEM_SEARCH,
                                set_tooltip_text: Some(crate::i18n::gettext("Search tables").as_str()),
                            },
                        },

                        #[wrap(Some)]
                        set_content = &gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,

                            #[name = "table_search_bar"]
                            gtk::SearchBar {
                                set_show_close_button: true,
                                set_search_mode: false,

                                #[wrap(Some)]
                                #[name = "table_search"]
                                set_child = &gtk::SearchEntry {
                                    set_placeholder_text: Some(crate::i18n::gettext("Filter tables…").as_str()),
                                    set_hexpand: true,
                                },
                            },

                            #[name = "sidebar_scroll"]
                            gtk::ScrolledWindow {
                                set_hscrollbar_policy: gtk::PolicyType::Never,
                                set_vexpand: true,
                            },
                        },
                    },

                    #[wrap(Some)]
                    #[name = "toast_overlay"]
                    set_content = &adw::ToastOverlay {
                        #[wrap(Some)]
                        #[name = "content_holder"]
                        set_child = &adw::ToolbarView {
                            #[name = "reconnect_banner"]
                            add_top_bar = &adw::Banner {
                                set_revealed: false,
                                set_use_markup: false,
                                set_button_label: Some(crate::i18n::gettext("Retry").as_str()),
                            },

                            #[name = "connection_list_banner"]
                            add_top_bar = &adw::Banner {
                                set_revealed: false,
                                set_use_markup: false,
                            },
                            // The welcome view or the workspace goes in
                            // here once init() has run.
                        },
                    },
                },
            },
        }
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let AppInit {
            context,
            prompts,
            settings,
            storage,
            tasks,
            history,
        } = init;
        let drafts = crate::workspace::DraftWriter::new(
            tablepro_storage::DraftStore::new(storage.paths().drafts_dir()),
            tasks.clone(),
        );
        let workspace = workspace_persistence::WorkspacePersistence::new(storage.workspaces().clone());
        let widgets = view_output!();

        if crate::config::profile() == crate::config::Profile::Development {
            widgets.window.add_css_class("devel");
        }

        crate::ui::window_geometry::restore(&widgets.window, &settings);
        let change_trackers = std::rc::Rc::new(ChangeTrackerRegistry::default());
        let structure_trackers = std::rc::Rc::new(StructureTrackerRegistry::default());
        let connect_attempts = std::rc::Rc::new(tablepro_session::ConnectAttempts::new());
        let workspace_tabs: workspace_persistence::WorkspaceTabs =
            std::rc::Rc::new(std::cell::RefCell::new(std::collections::HashMap::new()));
        let window_tabs = std::rc::Rc::new(window_tabs::WindowTabs::new(workspace_tabs.clone()));
        let events_sender = sender.input_sender().clone();
        let workspace_handle = crate::workspace::WorkspaceHandle::new(crate::workspace::WorkspaceDeps {
            session: context.active.clone(),
            tasks: context.tasks.clone(),
            hold: context.hold.clone(),
            history: Some(history.clone()),
            rows: change_trackers.clone(),
            structures: structure_trackers.clone(),
            directory: window_tabs.clone(),
            events: std::rc::Rc::new(move |event| events_sender.emit(AppMsg::Workspace(event))),
        });
        let saves_sender = sender.input_sender().clone();
        workspace_handle
            .ledger()
            .on_change(move |count| saves_sender.emit(AppMsg::SavesInFlightChanged(count)));
        let close_guards = crate::workspace::CloseGuards::new();
        let window_shutdown = close_flow::WindowShutdown::new(close_flow::WindowShutdownParts {
            settings: settings.clone(),
            storage: storage.clone(),
            drafts: drafts.clone(),
            workspace: workspace.clone(),
            tabs: workspace_tabs.clone(),
            context: context.clone(),
            connect_attempts: connect_attempts.clone(),
        });
        let shutdown = window_shutdown.clone();
        close_guards.connect_window(&widgets.window, workspace_handle.clone(), move |window| {
            shutdown.run(Some(window));
        });
        let inhibitor =
            crate::workspace::WindowInhibitor::new(crate::workspace::ApplicationInhibit::new(&widgets.window));

        let breakpoint = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
            adw::BreakpointConditionLengthType::MaxWidth,
            600.0,
            adw::LengthUnit::Sp,
        ));
        breakpoint.add_setter(&widgets.split_view, "collapsed", Some(&true.into()));
        widgets.window.add_breakpoint(breakpoint);

        let sidebar_schemas: std::rc::Rc<std::cell::RefCell<Vec<Option<String>>>> =
            std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));

        let sidebar_factory: FactoryVecDeque<SidebarRow> = FactoryVecDeque::builder()
            .launch(
                gtk::ListBox::builder()
                    .selection_mode(gtk::SelectionMode::Single)
                    .activate_on_single_click(true)
                    .css_classes(["navigation-sidebar"])
                    .build(),
            )
            .forward(sender.input_sender(), |out| match out {
                // Plain click + Enter activation route through the parent
                // ListBox's `row-activated` signal (wired below), which is
                // the only signal that fires for both mouse and keyboard.
                // The factory only carries the Ctrl+click / right-click
                // "open in new tab" path.
                SidebarRowOutput::OpenInNewTab { schema, name } => AppMsg::SelectTable {
                    schema,
                    name,
                    open_mode: OpenMode::NewTab,
                },
                SidebarRowOutput::EditStructure { schema, name } => AppMsg::EditStructureTab { schema, table: name },
                SidebarRowOutput::ShowCreateTable { schema, name } => {
                    AppMsg::ShowCreateTableForExisting { schema, table: name }
                }
                SidebarRowOutput::ImportCsv { schema, name } => AppMsg::ImportCsvRequested { schema, table: name },
                SidebarRowOutput::DropTable { schema, name } => AppMsg::DropTablePrompt { schema, table: name },
            });

        let sidebar_listbox = sidebar_factory.widget();
        widgets.sidebar_scroll.set_child(Some(sidebar_listbox));

        // Plain click + Enter on focused row → SwitchOrAppend. This is
        // the single source of truth for sidebar activation; per-row
        // keybinding signals (gtk::ListBoxRow::activate) only fire on
        // Enter and would miss mouse clicks.
        let schemas_for_activate = sidebar_schemas.clone();
        let activate_sender = sender.clone();
        sidebar_listbox.connect_row_activated(move |_, row| {
            let name = row.widget_name().to_string();
            let idx = row.index() as usize;
            let schema = schemas_for_activate.borrow().get(idx).cloned().unwrap_or(None);
            activate_sender.input(AppMsg::SelectTable {
                schema,
                name,
                open_mode: OpenMode::SwitchOrAppend,
            });
        });

        let search_for_filter = widgets.table_search.clone();
        let schemas_for_filter = sidebar_schemas.clone();
        sidebar_listbox.set_filter_func(move |row| {
            let query = search_for_filter.text().to_lowercase();
            if query.is_empty() {
                return true;
            }
            // SidebarRow stashes its table name in widget-name; same
            // identifier is read by sync_sidebar_selection. Search
            // also matches the row's schema (when present) so a query
            // for "auth" surfaces every table in the auth schema, and
            // the qualified `schema.table` form so users with
            // multi-schema connections can disambiguate by typing the
            // dotted name they see in the tab title.
            let table_name = row.widget_name().to_lowercase();
            if table_name.contains(&query) {
                return true;
            }
            let schemas = schemas_for_filter.borrow();
            let idx = row.index() as usize;
            let Some(schema) = schemas.get(idx).and_then(|s| s.as_deref()) else {
                return false;
            };
            let schema_lc = schema.to_lowercase();
            schema_lc.contains(&query) || format!("{schema_lc}.{table_name}").contains(&query)
        });
        let listbox_for_invalidate = sidebar_listbox.clone();
        widgets.table_search.connect_search_changed(move |_| {
            listbox_for_invalidate.invalidate_filter();
        });
        widgets.table_search_bar.connect_entry(&widgets.table_search);
        widgets
            .table_search_bar
            .set_key_capture_widget(Some(&widgets.sidebar_root));

        // An empty list with no placeholder reads as broken.
        let sidebar_placeholder = adw::StatusPage::builder()
            .icon_name(crate::ui::icons::VIEW_LIST)
            .title(crate::i18n::gettext("No tables"))
            .description(crate::i18n::gettext(
                "Nothing matches the current search, or this connection has no tables yet.",
            ))
            .build();
        sidebar_placeholder.add_css_class("compact");
        sidebar_listbox.set_placeholder(Some(&sidebar_placeholder));

        // Two-way bind the sidebar header's search toggle to the SearchBar.
        // Click toggle → SearchBar reveals + entry focuses; press Esc →
        // SearchBar hides → toggle deactivates.
        widgets
            .table_search_toggle
            .bind_property("active", &widgets.table_search_bar, "search-mode-enabled")
            .bidirectional()
            .sync_create()
            .build();

        let schemas_for_header = sidebar_schemas.clone();
        let sender_for_header = sender.clone();
        let context_for_header = context.clone();
        sidebar_listbox.set_header_func(move |row, before| {
            let schemas = schemas_for_header.borrow();
            let total_distinct: std::collections::BTreeSet<&str> =
                schemas.iter().filter_map(|s| s.as_deref()).collect();
            // A connection with one schema still gets a header, for its
            // "New Table" button.
            let multi_schema = total_distinct.len() >= 2;
            let idx = row.index();
            let current = schemas.get(idx as usize).cloned().flatten();
            let prev_idx = before.map(|b| b.index());
            let prev = prev_idx.and_then(|i| schemas.get(i as usize)).cloned().flatten();
            let needs = match (&current, &prev) {
                (Some(c), Some(p)) => c != p,
                (Some(_), None) => true,
                (None, None) => before.is_none() && !multi_schema,
                (None, Some(_)) => false,
            };
            if !needs {
                row.set_header(gtk::Widget::NONE);
                return;
            }
            let can_create_table = context_for_header
                .active
                .get()
                .and_then(|session| session.current_dialect())
                .and_then(|dialect| dialect.ddl().map(|ddl| ddl.capabilities().create_table))
                .unwrap_or(false);
            let sender_for_button = sender_for_header.clone();
            let schema_for_button = current.clone();
            let header_box =
                sidebar_section_header::sidebar_section_header(current.as_deref(), can_create_table, move || {
                    sender_for_button.input(AppMsg::NewTableTab {
                        schema: schema_for_button.clone(),
                    });
                });
            row.set_header(Some(&header_box));
        });

        let connections_listbox = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        let connections_factory: FactoryVecDeque<ConnectionRow> = FactoryVecDeque::builder()
            .launch(connections_listbox.clone())
            .forward(sender.input_sender(), |out| match out {
                ConnectionRowOutput::Open(saved) => AppMsg::OpenSaved(saved),
                ConnectionRowOutput::Delete(id) => AppMsg::DeleteConnection(id),
                ConnectionRowOutput::Duplicate(saved) => AppMsg::DuplicateConnection(saved),
                ConnectionRowOutput::SetColor(id, color) => AppMsg::SetConnectionColor(id, color),
                ConnectionRowOutput::SetGroup(id, group) => AppMsg::SetConnectionGroup(id, group),
            });

        // The SplitButton's tooltip already labels the popover, so we drop
        // the in-popover "Saved Connections" header that previously sat
        // above the list. Explicit width_request prevents AdwSplitButton's
        // narrow dropdown trigger from constraining the popover width
        // (which produced mid-word hyphenation of connection names).
        let popover_content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .margin_end(6)
            .width_request(320)
            .build();

        let scroll = gtk::ScrolledWindow::builder()
            .child(connections_factory.widget())
            .min_content_width(320)
            .min_content_height(120)
            .max_content_height(400)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        popover_content.append(&scroll);
        widgets.connections_popover.set_child(Some(&popover_content));

        // Workspace outer stack: swaps between an empty StatusPage
        // ("Select a table") when no tabs are open and the unified
        // AdwTabOverview hosting both Browse and Editor tabs. The
        // tab tree itself is built lazily on connect via
        // `ensure_workspace_root` in app/workspace_tabs.rs.
        let workspace_outer_stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .build();
        // CTA button parented inside the empty-state status page so
        // the "open editor" affordance is reachable with the mouse:
        // without it the only path was the keyboard shortcut and the
        // tab-bar "+", and the tab bar is hidden in this empty state.
        let workspace_empty_cta = gtk::Button::builder()
            .label(crate::i18n::gettext("Open SQL editor"))
            .action_name("win.open-editor")
            .halign(gtk::Align::Center)
            .build();
        workspace_empty_cta.add_css_class("suggested-action");
        workspace_empty_cta.add_css_class("pill");
        let workspace_empty_page = adw::StatusPage::builder()
            .icon_name(crate::ui::icons::VIEW_GRID)
            .title(crate::i18n::gettext("Select a table"))
            .description(crate::i18n::gettext(
                "Pick a table from the sidebar, or use the button below (Ctrl+T).",
            ))
            .child(&workspace_empty_cta)
            .build();
        workspace_outer_stack.add_named(&workspace_empty_page, Some("empty"));
        workspace_outer_stack.set_visible_child_name("empty");

        let actions = install_window_actions(&widgets.window, sender.clone());
        let history_gate = spawn_history_gate(
            vec![actions.show_history.clone(), actions.show_saved_queries.clone()],
            history.availability(),
        );
        install_window_shortcuts(&widgets.window);
        widgets.primary_menu_button.set_menu_model(Some(&primary_menu_model()));

        let welcome_view =
            WelcomeView::builder()
                .launch(WelcomeViewInit)
                .forward(sender.input_sender(), |out| match out {
                    WelcomeViewOutput::OpenConnect => AppMsg::OpenConnect,
                    WelcomeViewOutput::OpenSaved(saved) => AppMsg::OpenSaved(saved),
                    WelcomeViewOutput::Delete(id) => AppMsg::DeleteConnection(id),
                    WelcomeViewOutput::Duplicate(saved) => AppMsg::DuplicateConnection(saved),
                    WelcomeViewOutput::SetColor(id, color) => AppMsg::SetConnectionColor(id, color),
                    WelcomeViewOutput::SetGroup(id, group) => AppMsg::SetConnectionGroup(id, group),
                });

        let prompt_presenter = crate::ui::credential_prompt::CredentialPromptPresenter::start(prompts, &root);
        let model = App {
            context,
            session_links: None,
            prompt_presenter,
            connect_attempts,
            settings: settings.clone(),
            storage: storage.clone(),
            tasks: tasks.clone(),
            history: history.clone(),
            drafts: drafts.clone(),
            window: root.clone(),
            split_view: widgets.split_view.clone(),
            window_title: widgets.window_title.clone(),
            sidebar_title: widgets.sidebar_title.clone(),
            disconnect_action: actions.disconnect,
            history_gate,
            sidebar_factory,
            sidebar_schemas,
            content_holder: widgets.content_holder.clone(),
            toast_overlay: widgets.toast_overlay.clone(),
            connect_progress_toast: None,
            reconnect_banner: widgets.reconnect_banner.clone(),
            connection_list_banner: widgets.connection_list_banner.clone(),
            connections_factory,
            connections_listbox,
            connections_popover: widgets.connections_popover.clone(),
            row_op_spinner: widgets.row_op_spinner.clone(),
            read_only_badge: widgets.read_only_badge.clone(),
            table_search: widgets.table_search.clone(),
            workspace_outer_stack,
            workspace_root: None,
            workspace_tab_view: None,
            workspace_root_added: std::cell::Cell::new(false),
            workspace_tabs,
            change_trackers,
            structure_trackers,
            workspace_handle,
            window_tabs,
            close_guards,
            window_shutdown,
            inhibitor,
            dialog: None,
            history_dialog: None,
            saved_queries_dialog: None,
            import_dialog: None,
            welcome_view,
            current_driver_id: None,
            read_only: false,
            saved_connections: Vec::new(),
            connected: false,
            workspace,
            closed_tabs_stack: std::rc::Rc::new(std::cell::RefCell::new(std::collections::VecDeque::with_capacity(
                CLOSED_TABS_CAPACITY,
            ))),
        };
        sender.input(AppMsg::ReloadConnections);
        model.show_welcome_page(sender.clone());

        widgets
            .new_connection_button
            .update_property(&[gtk::accessible::Property::Label("New connection")]);
        widgets
            .saved_connections_button
            .update_property(&[gtk::accessible::Property::Label("Open saved connection")]);
        widgets
            .primary_menu_button
            .update_property(&[gtk::accessible::Property::Label("Main menu")]);

        let banner_sender = sender.clone();
        widgets.reconnect_banner.connect_button_clicked(move |_| {
            banner_sender.input(AppMsg::RetryConnection);
        });

        let list_banner_sender = sender.clone();
        widgets.connection_list_banner.connect_button_clicked(move |_| {
            list_banner_sender.input(AppMsg::ResetConnectionList);
        });

        ComponentParts { model, widgets }
    }

    fn shutdown(&mut self, _widgets: &mut Self::Widgets, _output: relm4::Sender<Self::Output>) {
        // The gate holds the window's action, so it has to stop before
        // the window does.
        self.history_gate.abort();
        self.prompt_presenter.abort();
        // The close request already did this; a window destroyed
        // without one still closes its tabs' connections, then its own,
        // here. The claim on the session's key goes last, so no other
        // window adopts a connection still closing.
        self.window_shutdown.run(None);
        self.session_links = None;
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            AppMsg::OpenConnect => self.on_open_connect(sender),
            AppMsg::SessionReady(ready) => self.on_session_ready(*ready, sender),
            AppMsg::ConnectSubmitted(submission) => self.on_connect_submission(*submission, sender),
            AppMsg::ConnectSubmissionConfirmed(submission) => self.connect_submission(*submission, sender),
            AppMsg::ConnectFailed {
                generation,
                message,
                edit,
            } => self.on_connect_failed(generation, message, edit, sender),
            AppMsg::CancelConnect => self.on_cancel_connect(),
            AppMsg::EditConnection(retry) => self.on_edit_connection(*retry, sender),
            AppMsg::HealthChanged(update) => {
                if let Some(health) = update.if_current(&self.context.active) {
                    self.refresh_health_banner(&health);
                }
            }
            AppMsg::RetryConnection => self.on_retry_connection(),
            AppMsg::CatalogChanged(update) => {
                if let Some(snapshot) = update.if_current(&self.context.active) {
                    self.on_catalog_changed(&snapshot);
                }
            }
            AppMsg::Disconnect => self.on_disconnect(sender),
            AppMsg::ForceDisconnect => self.do_disconnect(sender),
            AppMsg::TabCloseDecided { id, approved } => self.on_tab_close_decided(id, approved),
            AppMsg::DialogClosed => self.dialog = None,
            AppMsg::SelectTable {
                schema,
                name,
                open_mode,
            } => self.dispatch_select_table(schema, name, open_mode, sender),
            AppMsg::WorkspaceTabsChanged => self.on_workspace_tabs_changed(),
            AppMsg::SaveTab(id) => self.request_save(id),
            AppMsg::StopSaving(id) => self.stop_saving(id),
            AppMsg::Workspace(event) => self.on_workspace_event(event, sender),
            AppMsg::SavesInFlightChanged(count) => self.on_saves_in_flight_changed(count),
            AppMsg::EditorTransactionChanged => self.refresh_inhibitor(),
            AppMsg::SaveActiveTab => {
                if let Some(id) = self.selected_workspace_tab_id() {
                    self.request_save(id);
                }
            }
            AppMsg::UndoActiveBrowseTab => {
                // Ctrl+Z routes to BrowseTab undo only. Structure
                // editing follows the snapshot+diff model: DDL undo
                // is a session-level Discard, not a per-keystroke
                // history. Inside a Structure-mode Entry, the native
                // `gtk::Text` undo handles per-field text revert.
                if let Some(id) = self.selected_browse_tab_id() {
                    self.dispatch_to_tab(id, BrowseTabInput::Undo);
                }
            }
            AppMsg::RedoActiveBrowseTab => {
                if let Some(id) = self.selected_browse_tab_id() {
                    self.dispatch_to_tab(id, BrowseTabInput::Redo);
                }
            }
            AppMsg::WorkspaceTabClosed(id) => self.close_workspace_tab_by_id(id, sender),
            AppMsg::CloseOtherWorkspaceTabs(id) => self.close_other_workspace_tabs(id, sender),
            AppMsg::CloseWorkspaceTabsToRight(id) => self.close_workspace_tabs_to_right(id, sender),
            AppMsg::CloseActiveWorkspaceTab => self.close_active_workspace_tab(sender),
            AppMsg::ShowAlert { title, body } => self.show_error_alert(&title, &body),
            AppMsg::ShowToast(msg) => self.show_toast(&msg),
            AppMsg::BrowseTabDirtyChanged(tab_id, dirty) => {
                self.refresh_browse_tab_dirty(tab_id, dirty);
                self.refresh_inhibitor();
            }
            AppMsg::NewTableTab { schema } => self.on_new_table_tab(schema, sender),
            AppMsg::EditStructureTab { schema, table } => self.on_edit_structure_tab(schema, table, sender),
            AppMsg::ShowCreateTableForExisting { schema, table } => self.on_show_create_table(schema, table, sender),
            AppMsg::ShowCreateTableLoaded(update) => {
                if let Some(sql) = update.if_current(&self.context.active) {
                    self.append_editor_tab(Some(sql), sender);
                }
            }
            AppMsg::DropTablePrompt { schema, table } => self.on_drop_table_prompt(schema, table, sender),
            AppMsg::DropTableConfirmed { schema, table } => self.on_drop_table_confirmed(schema, table, sender),
            AppMsg::DropTableSucceeded(update) => {
                if let Some(table) = update.if_current(&self.context.active) {
                    self.on_drop_table_succeeded(table, sender);
                }
            }
            AppMsg::StructureTabDirtyChanged(tab_id, dirty) => {
                self.refresh_structure_tab_dirty(tab_id, dirty);
                self.refresh_inhibitor();
            }
            AppMsg::SchemaChanged { schema, table } => self.on_schema_changed(schema, table),
            AppMsg::ReloadConnections => self.on_reload_connections(sender),
            AppMsg::ConnectionListUnavailable => self.show_connection_list_banner(),
            AppMsg::SecretDeleteFailed(id) => self.on_secret_delete_failed(id, sender),
            AppMsg::ResetConnectionList => self.on_reset_connection_list(sender),
            AppMsg::ConnectionsLoaded(connections) => {
                let conns = connections;
                self.on_connections_loaded(&conns, sender);
            }
            AppMsg::NewEditorTab => self.append_editor_tab(None, sender),
            AppMsg::EditorTabRunStateChanged(id, running) => self.on_editor_tab_run_state_changed(id, running),
            AppMsg::EditorTabContentChanged(id) => self.on_editor_tab_content_changed(id),
            AppMsg::WorkspaceLoaded(update) => {
                if let Some(loaded) = update.if_current(&self.context.active) {
                    self.on_workspace_loaded(loaded, sender);
                }
            }
            AppMsg::ResetWorkspaceLayout => self.on_reset_workspace_layout(sender),
            AppMsg::WorkspaceLayoutReset(update) => {
                if let Some(outcome) = update.if_current(&self.context.active) {
                    self.on_workspace_layout_reset(outcome);
                }
            }
            AppMsg::ShowHistory => self.on_show_history(sender),
            AppMsg::ShowSavedQueries => self.on_show_saved_queries(sender),
            AppMsg::SetConnectionColor(id, color) => self.on_set_connection_color(id, color, sender),
            AppMsg::SetConnectionGroup(id, group) => self.on_set_connection_group(id, group, sender),
            AppMsg::ExportConnections => self.on_export_connections(sender),
            AppMsg::ImportConnections => self.on_import_connections(sender),
            AppMsg::ImportCsvRequested { schema, table } => self.on_import_csv_requested(schema, table, sender),
            AppMsg::ImportCsvReady {
                schema,
                table,
                columns,
                bytes,
            } => self.on_import_csv_ready(schema, table, columns, bytes, sender),
            AppMsg::ImportCsvRun(import) => self.on_import_csv_run(*import, sender),
            AppMsg::ConnectionsFileRead { path, bytes } => self.on_connections_file_read(path, bytes, sender),
            AppMsg::SaveActiveQuery => self.on_save_active_query(sender),
            AppMsg::SaveQueryNamed { name, query } => self.on_save_query_named(name, query, sender),
            AppMsg::OpenHistoryQuery(text) => {
                if self.connected {
                    self.append_editor_tab(Some(text), sender);
                } else {
                    self.show_toast(&crate::i18n::gettext("Connect to a database first to run SQL."));
                }
            }
            AppMsg::ReplaceActiveTabQuery(text) => {
                if self.connected {
                    self.on_replace_active_tab_query(text, sender);
                } else {
                    self.show_toast(&crate::i18n::gettext("Connect to a database first to run SQL."));
                }
            }
            AppMsg::RefreshPage => self.on_refresh_active_tab(),
            AppMsg::ShowAbout => self.on_show_about(),
            AppMsg::ShowPreferences => super::preferences_dialog::PreferencesDialog::new(
                &self.settings,
                &self.storage,
                self.history.store(),
                &self.tasks,
            )
            .present(Some(&self.window)),
            AppMsg::ExportResults { result, name, target } => {
                let dialect = self.context.active.get().and_then(|session| session.current_dialect());
                super::export_dialog::present(
                    &self.window,
                    &self.toast_overlay,
                    result,
                    name,
                    target,
                    dialect,
                    &self.settings,
                )
            }
            AppMsg::CopyToClipboard(text) => self.on_copy_to_clipboard(text),
            AppMsg::CopyRowAsInsert { tab_id, row_position } => self.on_copy_row_as_insert(tab_id, row_position),
            AppMsg::DeleteConnection(id) => self.on_delete_connection(id, sender),
            AppMsg::DuplicateConnection(saved) => self.on_duplicate_connection(saved, sender),
            AppMsg::OpenSaved(saved) => self.on_open_saved(saved, sender),
            AppMsg::OpenSavedConfirmed(saved) => self.connect_saved(saved, sender),
            AppMsg::ReopenClosedTab => self.on_reopen_closed_tab(sender),
            AppMsg::ShowFilterDialog => self.on_show_filter_dialog(),
        }
    }
}

fn qualified_label(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{s}.{table}"),
        None => table.to_string(),
    }
}

fn primary_menu_model() -> gio::Menu {
    let menu = gio::Menu::new();
    let connection_section = gio::Menu::new();
    let disconnect_item = gio::MenuItem::new(Some(&crate::i18n::gettext("Disconnect")), Some("win.disconnect"));
    disconnect_item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
    connection_section.append_item(&disconnect_item);
    menu.append_section(None, &connection_section);
    let history_section = gio::Menu::new();
    history_section.append(Some(&crate::i18n::gettext("Query History")), Some("win.show-history"));
    history_section.append(
        Some(&crate::i18n::gettext("Saved Queries")),
        Some("win.show-saved-queries"),
    );
    menu.append_section(None, &history_section);
    let connections_section = gio::Menu::new();
    connections_section.append(
        Some(&crate::i18n::gettext("Import Connections…")),
        Some("win.import-connections"),
    );
    connections_section.append(
        Some(&crate::i18n::gettext("Export Connections…")),
        Some("win.export-connections"),
    );
    menu.append_section(None, &connections_section);
    let prefs_section = gio::Menu::new();
    prefs_section.append(Some(&crate::i18n::gettext("Preferences")), Some("win.preferences"));
    menu.append_section(None, &prefs_section);
    let app_section = gio::Menu::new();
    app_section.append(Some(&crate::i18n::gettext("Keyboard Shortcuts")), Some("app.shortcuts"));
    app_section.append(Some(&crate::i18n::gettext("About TablePro")), Some("win.about"));
    app_section.append(Some(&crate::i18n::gettext("Quit")), Some("win.quit"));
    menu.append_section(None, &app_section);
    menu
}

/// Flip the actions that need the query database whenever
/// `HistoryService` changes state.
///
/// The watch channel is read on the GTK thread, so the actions are only
/// ever touched from the thread that owns them.
fn spawn_history_gate(
    actions: Vec<gio::SimpleAction>,
    mut availability: tokio::sync::watch::Receiver<crate::services::history_availability::HistoryAvailability>,
) -> glib::JoinHandle<()> {
    glib::spawn_future_local(async move {
        loop {
            let state = availability.borrow_and_update().clone();
            for action in &actions {
                action.set_enabled(state.is_ready());
            }
            if let Some(failure) = state.failure() {
                tracing::warn!(error = failure, "query history stays unavailable");
            }
            if availability.changed().await.is_err() {
                return;
            }
        }
    })
}

/// The actions the model keeps a handle on because their enabled
/// state changes after the window is built.
struct WindowActions {
    disconnect: gio::SimpleAction,
    show_history: gio::SimpleAction,
    show_saved_queries: gio::SimpleAction,
}

fn install_window_actions(window: &adw::ApplicationWindow, sender: ComponentSender<App>) -> WindowActions {
    let group = gio::SimpleActionGroup::new();

    // Twelve identical action wrappers were inlined here before; the macro
    // keeps the tuple-list intent obvious and removes 36 lines of boilerplate.
    macro_rules! input_action {
        ($name:expr, $msg:expr) => {{
            let s = sender.clone();
            gio::ActionEntry::builder($name)
                .activate(move |_, _, _| s.input($msg))
                .build()
        }};
    }

    let window_for_quit = window.clone();
    let quit = gio::ActionEntry::builder("quit")
        .activate(move |_, _, _| window_for_quit.close())
        .build();

    group.add_action_entries([
        input_action!("about", AppMsg::ShowAbout),
        quit,
        input_action!("open-editor", AppMsg::NewEditorTab),
        input_action!("close-current", AppMsg::CloseActiveWorkspaceTab),
        input_action!("preferences", AppMsg::ShowPreferences),
        input_action!("refresh-page", AppMsg::RefreshPage),
        input_action!("save-changes", AppMsg::SaveActiveTab),
        input_action!("undo-change", AppMsg::UndoActiveBrowseTab),
        input_action!("redo-change", AppMsg::RedoActiveBrowseTab),
        input_action!("reopen-closed-tab", AppMsg::ReopenClosedTab),
        input_action!("open-filter", AppMsg::ShowFilterDialog),
        input_action!("save-query", AppMsg::SaveActiveQuery),
        input_action!("export-connections", AppMsg::ExportConnections),
        input_action!("import-connections", AppMsg::ImportConnections),
        input_action!("reset-workspace-layout", AppMsg::ResetWorkspaceLayout),
    ]);
    let disconnect = gio::SimpleAction::new("disconnect", None);
    let sender_for_disconnect = sender.clone();
    disconnect.connect_activate(move |_, _| sender_for_disconnect.input(AppMsg::Disconnect));
    disconnect.set_enabled(false);
    group.add_action(&disconnect);

    // The history database opens on a background task, so the menu item
    // and Ctrl+H stay insensitive until `HistoryService` reports Ready.
    let show_history = gio::SimpleAction::new("show-history", None);
    let sender_for_history = sender.clone();
    show_history.connect_activate(move |_, _| sender_for_history.input(AppMsg::ShowHistory));
    show_history.set_enabled(false);
    group.add_action(&show_history);

    // Saved queries live in the same database, so they are reachable
    // exactly when it is.
    let show_saved_queries = gio::SimpleAction::new("show-saved-queries", None);
    let sender_for_saved = sender.clone();
    show_saved_queries.connect_activate(move |_, _| sender_for_saved.input(AppMsg::ShowSavedQueries));
    show_saved_queries.set_enabled(false);
    group.add_action(&show_saved_queries);

    window.insert_action_group("win", Some(&group));
    tracing::info!(enabled = disconnect.is_enabled(), "registered win.disconnect");
    WindowActions {
        disconnect,
        show_history,
        show_saved_queries,
    }
}

fn install_window_shortcuts(window: &adw::ApplicationWindow) {
    use gtk::gdk::{Key, ModifierType};
    let primary = ModifierType::CONTROL_MASK;
    let primary_shift = ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK;
    let controller = gtk::ShortcutController::new();
    controller.set_scope(gtk::ShortcutScope::Global);
    controller.add_shortcut(make_shortcut(Key::q, primary, "win.quit"));
    controller.add_shortcut(make_shortcut(Key::w, primary, "win.close-current"));
    controller.add_shortcut(make_shortcut(Key::e, primary, "win.open-editor"));
    // Ctrl+T mirrors Ctrl+E for the browser/IDE muscle memory ("new
    // tab"). Both fire `win.open-editor` so the empty workspace state
    // can be exited via either shortcut without focus tricks.
    controller.add_shortcut(make_shortcut(Key::t, primary, "win.open-editor"));
    controller.add_shortcut(make_shortcut(Key::F5, ModifierType::empty(), "win.refresh-page"));
    controller.add_shortcut(make_shortcut(Key::f, primary, "win.open-filter"));
    controller.add_shortcut(make_shortcut(Key::comma, primary, "win.preferences"));
    controller.add_shortcut(make_shortcut(Key::h, primary, "win.show-history"));
    controller.add_shortcut(make_shortcut(Key::s, primary, "win.save-changes"));
    controller.add_shortcut(make_shortcut(Key::z, primary, "win.undo-change"));
    controller.add_shortcut(make_shortcut(Key::y, primary, "win.redo-change"));
    controller.add_shortcut(make_shortcut(Key::z, primary_shift, "win.redo-change"));
    controller.add_shortcut(make_shortcut(Key::t, primary_shift, "win.reopen-closed-tab"));
    controller.add_shortcut(make_shortcut(Key::s, primary_shift, "win.save-query"));
    window.add_controller(controller);
}

fn make_shortcut(key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType, action: &str) -> gtk::Shortcut {
    gtk::Shortcut::builder()
        .trigger(&gtk::KeyvalTrigger::new(key, modifiers))
        .action(&gtk::NamedAction::new(action))
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shortcut_action_names(window: &adw::ApplicationWindow) -> Vec<String> {
        let controllers = window.observe_controllers();
        let mut names = Vec::new();
        for index in 0..controllers.n_items() {
            let Some(controller) = controllers.item(index).and_downcast::<gtk::ShortcutController>() else {
                continue;
            };
            for position in 0..controller.n_items() {
                let Some(shortcut) = controller.item(position).and_downcast::<gtk::Shortcut>() else {
                    continue;
                };
                if let Some(action) = shortcut.action().and_downcast::<gtk::NamedAction>() {
                    names.push(action.action_name().to_string());
                }
            }
        }
        names
    }

    #[gtk4::test]
    fn window_actions_exclude_shortcuts() {
        let app = adw::Application::builder()
            .application_id(crate::config::APP_ID)
            .build();
        let window = adw::ApplicationWindow::new(&app);

        install_window_shortcuts(&window);
        let names = shortcut_action_names(&window);

        assert!(names.iter().any(|name| name == "win.quit"), "{names:?}");
        assert!(
            !names.iter().any(|name| name == "win.shortcuts"),
            "AdwApplication owns app.shortcuts now: {names:?}"
        );
    }

    #[gtk4::test]
    fn the_history_gate_follows_availability() {
        use crate::services::history_availability::HistoryAvailability;

        let action = gio::SimpleAction::new("show-history", None);
        action.set_enabled(false);
        let (sender, receiver) = tokio::sync::watch::channel(HistoryAvailability::Starting);
        let gate = spawn_history_gate(vec![action.clone()], receiver);

        crate::test_support::drain_main_context();
        assert!(!action.is_enabled(), "enabled while the database was still opening");

        sender.send_replace(HistoryAvailability::Ready);
        crate::test_support::drain_main_context();
        assert!(action.is_enabled(), "stayed disabled after the database opened");

        sender.send_replace(HistoryAvailability::Failed("no disk".to_owned()));
        crate::test_support::drain_main_context();
        assert!(!action.is_enabled(), "stayed enabled after the database failed");

        gate.abort();
    }
}
