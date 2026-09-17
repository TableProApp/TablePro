mod browse;
mod connection;
mod ran_statements;
mod row_ops;
mod status_pages;
mod structure;
mod workspace_tabs;

use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::gtk::{gio, glib};
use relm4::prelude::*;
use relm4::{Controller, adw, gtk};

use tablepro_core::{ColumnInfo, DriverRegistry, QueryResult, TableInfo, Value};
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::browse_tab::{BrowseTab, BrowseTabInput};
use super::connect_dialog::ConnectDialog;
use super::connection_row::{ConnectionRow, ConnectionRowOutput};
use super::editor::{SqlEditor, build_schema_buffer};
use super::history_dialog::HistoryDialog;
use super::sidebar_row::{SidebarRow, SidebarRowOutput};
use super::welcome_view::{WelcomeView, WelcomeViewInit, WelcomeViewOutput};
use crate::services::database_service::ConnectionHealth;

/// Decrement a tab's pending-save counter in the close-after-save map.
/// Returns `true` if the entry just dropped to zero (the caller should
/// fire `WorkspaceTabClosed`); returns `false` if there's still another
/// in-flight save for that tab, or if the entry was never present.
///
/// Used by both browse `SaveCompletedForTab` and structure
/// `on_structure_save_completed` so a Table tab with both kinds of
/// pending changes only closes after BOTH saves succeed.
pub(super) fn dec_close_after_save(map: &mut std::collections::HashMap<Uuid, u32>, tab_id: &Uuid) -> bool {
    if let Some(count) = map.get_mut(tab_id) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            map.remove(tab_id);
            return true;
        }
    }
    false
}

/// What `run()` hands the root component: the driver registry and the
/// settings it opened before GTK started.
pub struct AppInit {
    pub registry: Arc<DriverRegistry>,
    pub settings: std::rc::Rc<tablepro_storage::AppSettings>,
    pub storage: crate::storage::SharedStorage,
    pub tasks: tablepro_session::runtime::Tasks,
    pub history: crate::services::history_service::HistoryService,
}

pub struct App {
    registry: Arc<DriverRegistry>,
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
    connections_popover: gtk::Popover,
    health_state: Option<ConnectionHealth>,
    row_op_spinner: adw::Spinner,
    read_only_badge: gtk::Label,
    table_search: gtk::SearchEntry,
    /// Outer Stack inside `content_holder` — swaps between `"empty"`
    /// (AdwStatusPage "Select a table") and `"tabs"` (the unified
    /// AdwTabOverview hosting both Browse and Editor sub-components).
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
    dialog: Option<Controller<ConnectDialog>>,
    schema_buffer: gtk::TextBuffer,
    history_dialog: Option<Controller<HistoryDialog>>,
    saved_queries_dialog: Option<Controller<super::saved_queries_dialog::SavedQueriesDialog>>,
    welcome_view: Controller<WelcomeView>,
    /// Driver id is connection-wide, not per-tab.
    current_driver_id: Option<String>,
    /// All tables in the current connection — fed into `schema_buffer`
    /// for the editor's autocomplete; not the per-tab columns.
    table_names: Vec<String>,
    /// Read-only flag is connection-wide; fanned out to every BrowseTab
    /// when toggled.
    read_only: bool,
    /// Default page size for newly-opened browse tabs (from preferences).
    /// Per-tab page size lives on each BrowseTab.
    saved_connections: Vec<SavedConnection>,
    connected: bool,
    /// Tabs the user picked "Save" on in a close-confirmation dialog,
    /// counted by remaining saves before the close fires. A Table tab
    /// with both browse-dirty AND structure-dirty dispatches two saves
    /// (one of each kind) so its entry starts at 2 — the first
    /// completion decrements to 1 (no close yet), the second decrements
    /// to 0 and finally fires `WorkspaceTabClosed`. A `SaveFailed`
    /// removes the entry entirely (abort all close intents for that
    /// tab so the user can fix the error and retry). See
    /// `dec_close_after_save` for the decrement helper.
    close_after_save: std::rc::Rc<std::cell::RefCell<std::collections::HashMap<Uuid, u32>>>,
    /// Set when the user picked "Save" on the *window*-close dialog.
    /// While true, the last `SaveCompletedForTab` that empties
    /// `close_after_save` triggers `window.close()`. A `SaveFailed`
    /// while in this state aborts the window-close intent. `Rc<Cell>`
    /// so the close-request handler closure can mutate it from outside
    /// `App::update`.
    close_window_after_save: std::rc::Rc<std::cell::Cell<bool>>,
    /// Count of in-flight transaction commits (a tab clicked Save
    /// and is awaiting `execute_in_transaction`). Incremented by
    /// `on_execute_browse_transaction` at dispatch, decremented by
    /// `SaveCompletedForTab` and `SaveFailedForTab`. Window-close
    /// blocks while this is > 0 so an async transaction never commits
    /// after the tab / window has been torn down.
    in_flight_saves: std::rc::Rc<std::cell::Cell<usize>>,
    /// Structure tabs currently mid-DDL-transaction. A second Ctrl+S
    /// while a Save is still in flight would dispatch a parallel
    /// transaction and potentially commit twice; this set lets the
    /// dispatch path short-circuit. Cleared on
    /// `StructureSaveCompleted` / `StructureSaveFailed`.
    structure_saves_in_flight: std::rc::Rc<std::cell::RefCell<std::collections::HashSet<Uuid>>>,
    /// Coalesces `persist_workspace_state`. Tabs fire
    /// `WorkspaceTabsChanged` on every selection, drag-reorder,
    /// page-size change and state-changed event, and each one would
    /// otherwise rewrite the whole workspace file.
    persist_debouncer: crate::workspace::PersistDebouncer,
    /// LIFO stack of recently-closed tab descriptors for Ctrl+Shift+T
    /// reopen. Capped at `CLOSED_TABS_CAPACITY`; the oldest entry is
    /// dropped when a new one is pushed against a full stack. Cleared
    /// on disconnect — descriptors reference the active connection's
    /// tables, so reopening across connections would target the wrong
    /// schema. Editor descriptors round-trip the buffer text;
    /// dirty tabs lose their pending row/DDL edits because the
    /// trackers have already been cleared by the close path.
    closed_tabs_stack: std::rc::Rc<std::cell::RefCell<std::collections::VecDeque<ClosedTabDescriptor>>>,
}

/// Snapshot of a tab the user just closed, retained for Ctrl+Shift+T
/// reopen. Mirrors the persistence variants in `workspace_state` so
/// reopen routes back through the same `append_*` constructors.
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

/// How long after the last tab change the workspace file is rewritten.
const WORKSPACE_PERSIST_DELAY: std::time::Duration = std::time::Duration::from_millis(500);

pub struct EditorTabSlot {
    pub controller: Controller<SqlEditor>,
    pub page: adw::TabPage,
    /// The file this tab's text is written to. The text itself lives in
    /// the buffer, not here.
    pub draft: tablepro_storage::DraftId,
    /// The first line or so, for the tab label and the reopen stack.
    pub query: String,
}

pub struct StructureTabSlot {
    pub id: Uuid,
    pub controller: Controller<crate::ui::structure_tab::StructureTab>,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    /// Empty in `New` mode until SaveCompleted carries the canonical
    /// table name back from the driver. Edit mode populates from the
    /// sidebar click or restore record.
    pub table: String,
    pub mode: crate::ui::structure_tab::StructureMode,
}

/// One workspace tab pinned to a single `(schema, table)` entity in
/// Data (Browse) mode. The Structure (DDL) view is no longer fused
/// into the same tab — `WorkspaceTab::Structure` is its own
/// dedicated tab opened via the sidebar right-click "Edit Structure"
/// action. This split mirrors GNOME's "one TabPage per surface"
/// idiom (Files, Builder) instead of a per-tab AdwViewSwitcher.
pub struct TableTabSlot {
    pub id: Uuid,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    pub table: String,
    pub browse: Controller<BrowseTab>,
}

/// A tab in the unified workspace.
///
/// - **Table**: one (schema, table) entity in Data (Browse grid)
///   view. Default for every sidebar single-click.
/// - **Editor**: a free-form SQL workspace, orthogonal to any one
///   table.
/// - **Structure**: the DDL editor — opens for "New Table" drafts
///   AND for "Edit Structure" against an existing table (via the
///   sidebar right-click action). Replaces the previous inline
///   AdwViewSwitcher on the Table tab.
pub enum WorkspaceTab {
    Editor(EditorTabSlot),
    Structure(StructureTabSlot),
    Table(TableTabSlot),
}

impl WorkspaceTab {
    /// The Browse-side controller. Only `Table` slots carry one.
    pub fn browse_controller(&self) -> Option<&Controller<BrowseTab>> {
        match self {
            WorkspaceTab::Table(s) => Some(&s.browse),
            _ => None,
        }
    }

    /// The Structure-side controller. Only `Structure` slots carry
    /// one (Table slots no longer fuse the DDL editor in).
    pub fn structure_controller(&self) -> Option<&Controller<crate::ui::structure_tab::StructureTab>> {
        match self {
            WorkspaceTab::Structure(s) => Some(&s.controller),
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
    /// Plain sidebar click: if a Browse tab for the table already
    /// exists, activate it; otherwise append a new Browse tab.
    /// Never closes existing tabs — accumulates until the user dismisses.
    SwitchOrAppend,
    /// Ctrl+click / right-click "Open in new tab": always append a
    /// new tab even when the same table is already open.
    NewTab,
}

// One Quark keyed `tp-workspace-tab-id` covers all tabs in the unified
// workspace. We look up the WorkspaceTab from the HashMap to discover
// kind — qdata only carries identity.
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
    Connected {
        tables: Vec<TableInfo>,
        driver_id: String,
    },
    DialogClosed,
    SelectTable {
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
    },
    ColumnsLoaded(Uuid, Vec<ColumnInfo>),
    RowsLoaded(Uuid, u64, QueryResult),
    /// `Some(tab_id)` for tab-scoped failures; `None` for app-level
    /// failures (e.g. connect failure during open_saved).
    LoadFailed(Option<Uuid>, String),
    RowOpStarted,
    ReloadConnections,
    ConnectionsLoaded(Vec<SavedConnection>),
    ConnectionListUnavailable,
    ResetConnectionList,
    SecretDeleteFailed(Uuid),
    OpenSaved(SavedConnection),
    DeleteConnection(Uuid),
    DuplicateConnection(SavedConnection),
    /// "+ New query" button or Ctrl+T → append a new editor tab.
    NewEditorTab,
    /// Ctrl+W → close active workspace tab (browse or editor).
    CloseActiveWorkspaceTab,
    EditorTabRunStateChanged(Uuid, bool),
    EditorTabQueryChanged(Uuid, String),
    /// The saved tabs and their editor text, read off the GTK thread.
    WorkspaceTabsRead {
        saved: crate::services::workspace_state::ConnectionWorkspaceState,
        drafts: std::collections::HashMap<tablepro_storage::DraftId, String>,
    },
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
    ExportConnections,
    ImportConnections,
    /// The file the user picked, read off the GTK thread.
    ConnectionsFileRead {
        path: std::path::PathBuf,
        bytes: Vec<u8>,
    },
    OpenHistoryQuery(String),
    ReplaceActiveTabQuery(String),
    Disconnect,
    /// Skip the dirty-state confirmation and tear the connection
    /// down immediately. Fired from the disconnect-with-pending
    /// AlertDialog's "Discard and disconnect" response.
    ForceDisconnect,
    PollHealth,
    RefreshPage,
    ShowAbout,
    ShowPreferences,
    /// Sort flipped on tab_id's grid for column idx.
    RowCountLoaded(Uuid, u64),
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
    /// BrowseTab sub-component asked for its current page to be fetched.
    FetchBrowsePage(Uuid),
    /// BrowseTab needs schema columns.
    FetchBrowseColumns(Uuid),
    /// BrowseTab needs the row count.
    FetchBrowseRowCount(Uuid),
    /// Any browse tab's columns changed; rebuild editor schema buffer.
    WorkspaceSchemaWordsChanged,
    /// User clicked the close-X on any workspace tab.
    WorkspaceTabClosed(Uuid),
    /// Tab right-click "Close Other Tabs" → close every tab except
    /// the one whose context menu was used (per-tab close path so
    /// each tab still gets the unsaved-changes prompt if dirty).
    CloseOtherWorkspaceTabs(Uuid),
    /// Tab right-click "Close Tabs to the Right" → close every tab
    /// after the targeted one in TabView display order.
    CloseWorkspaceTabsToRight(Uuid),
    /// Drag-reorder / selection change / browse-tab-state-changed —
    /// triggers persistence (writes the current display order + each
    /// slot's state to workspace_state.json).
    WorkspaceTabsChanged,
    /// Run a sequence of pending-changeset statements inside a single
    /// DB transaction. Materialised by a BrowseTab's change tracker
    /// when the user clicks Save. App calls
    /// `Connection::execute_in_transaction` and dispatches
    /// `BrowseTabInput::SaveCompleted` / `SaveFailed` back via the
    /// per-tab controller.
    ExecuteBrowseTransaction {
        tab_id: Uuid,
        statements: Vec<(String, Vec<Value>)>,
        sources: Vec<crate::services::change_tracker::StatementSource>,
    },
    /// Inline-Save resolved successfully for a specific browse tab.
    /// Routes through App.update so we can reset the row-op spinner
    /// before forwarding `BrowseTabInput::SaveCompleted` to the tab.
    /// `warning` is `Some(msg)` when the transaction committed but at
    /// least one UPDATE / DELETE statement matched zero rows — typically
    /// a concurrent modification by another session. The user sees a
    /// toast so a phantom save doesn't pass silently.
    SaveCompletedForTab(Uuid, Option<String>),
    /// Inline-Save failed; transaction was already rolled back.
    SaveFailedForTab(Uuid, String),
    /// Driver reported `DriverError::Transaction { statement_index }`.
    /// Routed before SaveFailedForTab so the tab can scroll-and-select
    /// the offending row before the error alert appears.
    FlashErrorRowForTab(Uuid, crate::services::change_tracker::StatementSource),
    /// Ctrl+S — fire CommitSave on the active browse tab. No-op if
    /// the active tab is an Editor or there's no active connection.
    SaveActiveBrowseTab,
    /// Targeted variant: close-confirmation dialogs use this to commit
    /// a specific tab (which may not be the currently-active one when
    /// the user is closing a background tab via its X button).
    SaveActiveBrowseTabById(Uuid),
    /// Ctrl+Z — undo the last pending change in the active tab.
    UndoActiveBrowseTab,
    /// Ctrl+Y — redo a previously undone change in the active tab.
    RedoActiveBrowseTab,
    /// Show a small alert dialog; used by BrowseTab for "select exactly
    /// one row" type messages.
    ShowAlert {
        title: String,
        body: String,
    },
    /// Show a transient toast — used for inline-validation feedback like
    /// "Invalid date format" where a modal alert would be over-heavy.
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
    /// Sidebar right-click → "Show CREATE TABLE". App fetches
    /// columns, indexes, and FKs, synthesises a CreateTable op,
    /// materialises through `sql_ddl::materialize_ops`, and opens
    /// the resulting SQL in a fresh editor tab.
    ShowCreateTableForExisting {
        schema: Option<String>,
        table: String,
    },
    /// Async result of `ShowCreateTableForExisting` — the synthesised
    /// CREATE statement is ready, open it in a new editor tab.
    ShowCreateTableLoaded {
        sql: String,
    },
    /// Sidebar right-click → "Drop Table…", or in-tab Drop button.
    /// App shows the AdwAlertDialog confirmation; on confirm dispatches
    /// `DropTableConfirmed`.
    DropTablePrompt {
        schema: Option<String>,
        table: String,
    },
    /// Confirmed drop — App runs DROP TABLE then closes any open
    /// Browse / Structure tabs for that table and refreshes sidebar.
    DropTableConfirmed {
        schema: Option<String>,
        table: String,
    },
    /// DROP TABLE returned Ok from the driver. Now-safe to close
    /// matching tabs + refresh sidebar.
    DropTableSucceeded {
        schema: Option<String>,
        table: String,
    },
    /// Structure tab Save: run the materialised DDL statements
    /// sequentially. Postgres wraps in BEGIN / COMMIT for atomicity;
    /// MySQL / SQLite execute per-statement (DDL implicitly commits).
    ExecuteStructureTransaction {
        tab_id: Uuid,
        statements: Vec<String>,
    },
    /// Targeted save for a specific structure tab (close-with-pending
    /// dialog uses this — mirrors `SaveActiveBrowseTabById`). Looks up
    /// the slot, materialises the tracker, dispatches
    /// `ExecuteStructureTransaction`.
    SaveActiveStructureTabById(Uuid),
    /// Structure tab Save resolved successfully. `new_table_name` is
    /// `Some(name)` for `New` mode CreateTable transitions; the tab
    /// promotes to Edit mode and the slot's `table` field updates.
    StructureSaveCompleted {
        tab_id: Uuid,
        new_table_name: Option<String>,
    },
    /// Structure tab Save failed; tracker is intact for retry.
    StructureSaveFailed(Uuid, String),
    /// Structure tab Edit-mode init triggers introspection. App fans
    /// out fetch_columns / fetch_indexes / fetch_foreign_keys and
    /// dispatches the Loaded variants below.
    FetchStructureData {
        tab_id: Uuid,
    },
    /// Coalesced load result — columns + indexes + FKs together so
    /// the Structure tab rebuilds its list views once, not three times.
    StructureDataLoaded {
        tab_id: Uuid,
        columns: Vec<ColumnInfo>,
        indexes: Vec<tablepro_core::IndexInfo>,
        fks: Vec<tablepro_core::ForeignKeyInfo>,
    },
    StructureLoadFailed {
        tab_id: Uuid,
        message: String,
    },
    /// Tracker for a Structure tab crossed empty / non-empty boundary.
    /// Mirrors `BrowseTabDirtyChanged` for the title prefix and the
    /// AdwTabPage::set_needs_attention background-tab indicator.
    StructureTabDirtyChanged(Uuid, bool),
    /// Schema state changed (table created / dropped / altered) — App
    /// refreshes the sidebar and any open Browse tabs for the affected
    /// table.
    SchemaChanged {
        schema: Option<String>,
        table: Option<String>,
    },
    /// Result of `list_tables` after a SchemaChanged event. Rebuilds
    /// the sidebar factory without going through the full Connected
    /// path.
    TablesReloaded(Vec<TableInfo>),
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

/// Determines which icon and styling adw::StatusPage uses.
///
/// Replaces the previous title-string sniffing in `set_status_page`,
/// which broke the moment a translation used different vocabulary
/// for "Failed" / "Error" / "No connection".
#[derive(Debug, Clone, Copy)]
pub(super) enum StatusKind {
    Info,
    Error,
}

impl StatusKind {
    fn icon(self) -> &'static str {
        match self {
            StatusKind::Info => crate::ui::icons::VIEW_GRID,
            StatusKind::Error => crate::ui::icons::DIALOG_ERROR,
        }
    }
}

impl App {
    /// The active driver id, or "postgres" if no connection is active.
    ///
    /// Single fallback site (was duplicated at 7 call sites). The
    /// tracing::warn! makes the latent bug visible if anything ever
    /// asks for the driver id without an active connection — today
    /// that would silently corrupt SQL quoting on non-Postgres drivers.
    pub(super) fn driver_id(&self) -> &str {
        match self.current_driver_id.as_deref() {
            Some(id) => id,
            None => {
                tracing::warn!("driver_id called without active connection; falling back to postgres");
                "postgres"
            }
        }
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

                    // Sidebar wrapped in its own AdwToolbarView so it can
                    // carry a sidebar-local AdwHeaderBar with a search
                    // toggle — same structure GNOME Files uses for its
                    // Places sidebar. Window-decoration buttons live on
                    // the outer (main) header bar already, so we hide
                    // them here.
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
                            // Content is set imperatively at the end of
                            // init() — show_welcome_page swaps in the
                            // WelcomeView for the disconnected state,
                            // and on_connected swaps in the workspace
                            // tab strip on connect. The previously-
                            // inlined "Connect to a database" StatusPage
                            // here was dead UI: built once, replaced
                            // immediately, never seen.
                        },
                    },
                },
            },
        }
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let AppInit {
            registry,
            settings,
            storage,
            tasks,
            history,
        } = init;
        let drafts = crate::workspace::DraftWriter::new(
            tablepro_storage::DraftStore::new(storage.paths().drafts_dir()),
            tasks.clone(),
        );
        let widgets = view_output!();

        if crate::config::profile() == crate::config::Profile::Development {
            widgets.window.add_css_class("devel");
        }

        crate::ui::window_geometry::restore(&widgets.window, &settings);
        // Window-close handler. Three responsibilities: persist window
        // size + maximize state, intercept close when any tab has
        // unsaved edits with a Cancel | Discard | Save dialog, and
        // route Save through the same SaveCompletedForTab plumbing as
        // a per-tab close so failures abort cleanly.
        let settings_for_close = settings.clone();
        let storage_for_close = storage.clone();
        let drafts_for_close = drafts.clone();
        let force_close: std::rc::Rc<std::cell::Cell<bool>> = std::rc::Rc::new(std::cell::Cell::new(false));
        let force_close_for_close = force_close.clone();
        let close_after_save_for_close: std::rc::Rc<std::cell::RefCell<std::collections::HashMap<Uuid, u32>>> =
            std::rc::Rc::new(std::cell::RefCell::new(std::collections::HashMap::new()));
        let close_window_after_save_for_close: std::rc::Rc<std::cell::Cell<bool>> =
            std::rc::Rc::new(std::cell::Cell::new(false));
        let in_flight_saves: std::rc::Rc<std::cell::Cell<usize>> = std::rc::Rc::new(std::cell::Cell::new(0));
        let close_after_save_handle = close_after_save_for_close.clone();
        let close_window_after_save_handle = close_window_after_save_for_close.clone();
        let in_flight_saves_handle = in_flight_saves.clone();
        let in_flight_saves_for_close = in_flight_saves.clone();
        let close_request_input_sender = sender.input_sender().clone();
        widgets.window.connect_close_request(move |w| {
            // If a Save is mid-flight (async transaction running), block
            // the close until it resolves. Without this, the completion
            // handler would dispatch SaveCompleted to a tab that's
            // already gone — the transaction commits in the background
            // with no UI feedback.
            if !force_close_for_close.get() && in_flight_saves_for_close.get() > 0 {
                let dialog = adw::AlertDialog::new(
                    Some(&crate::i18n::gettext("Saving in progress")),
                    Some(&crate::i18n::gettext(
                        "Waiting for pending saves to finish before closing the window.",
                    )),
                );
                dialog.set_can_close(false);
                dialog.present(Some(w));
                let dialog_for_poll = dialog.clone();
                let window_for_poll = w.clone();
                let force_close_for_poll = force_close_for_close.clone();
                let in_flight_for_poll = in_flight_saves_for_close.clone();
                glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
                    if in_flight_for_poll.get() == 0 {
                        dialog_for_poll.close();
                        force_close_for_poll.set(true);
                        window_for_poll.close();
                        glib::ControlFlow::Break
                    } else {
                        glib::ControlFlow::Continue
                    }
                });
                return glib::Propagation::Stop;
            }
            // Already-confirmed close path (set by the dialog handler
            // below) — skip the guard, save state, allow close.
            // Browse + Structure tabs share the dirty-state guard:
            // either source of pending changes triggers the dialog.
            let has_pending = crate::services::change_tracker::any_pending_globally()
                || crate::services::structure_tracker::any_pending_globally();
            if !force_close_for_close.get() && has_pending {
                // Plural-form heading matches the per-tab dialog's
                // tone — factual GNOME HIG language rather than the
                // colloquial "throws them away" the body used to
                // carry. Per-tab dialog stays specific ("Save changes
                // to {name}"); window close groups across N tabs so
                // it stays generic.
                let dialog = adw::AlertDialog::new(None, None);
                dialog.set_heading(Some(&crate::i18n::gettext("Save changes before closing?")));
                dialog.set_body(&crate::i18n::gettext(
                    "One or more tabs have unsaved changes. They will be permanently lost if you discard them.",
                ));
                dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
                dialog.add_response("discard", &crate::i18n::gettext("Discard"));
                dialog.add_response("save", &crate::i18n::gettext("Save"));
                dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
                dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
                dialog.set_default_response(Some("save"));
                dialog.set_close_response("cancel");
                let force_close_for_resp = force_close_for_close.clone();
                let window_for_resp = w.clone();
                let close_after_save_for_resp = close_after_save_for_close.clone();
                let close_window_after_save_for_resp = close_window_after_save_for_close.clone();
                let input_sender_for_resp = close_request_input_sender.clone();
                dialog.connect_response(None, move |dlg, response| {
                    dlg.close();
                    match response {
                        "discard" => {
                            for tab_id in crate::services::change_tracker::pending_tabs() {
                                crate::services::change_tracker::with_tab(tab_id, |t| t.clear());
                            }
                            for tab_id in crate::services::structure_tracker::pending_tabs() {
                                crate::services::structure_tracker::with_tab(tab_id, |t| t.clear());
                            }
                            force_close_for_resp.set(true);
                            // Re-fire close_request — guard sees the flag,
                            // saves window state, returns Proceed.
                            window_for_resp.close();
                        }
                        "save" => {
                            // Commit each dirty tab. Browse tabs go through
                            // SaveActiveBrowseTabById; Structure tabs need
                            // ExecuteStructureTransaction with materialized
                            // statements. close_after_save tracks both kinds;
                            // the SaveCompletedForTab / StructureSaveCompleted
                            // handlers in App::update close the window once
                            // the set drains. Any SaveFailed aborts.
                            let browse_tabs: Vec<Uuid> = crate::services::change_tracker::pending_tabs();
                            let structure_tabs: Vec<Uuid> = crate::services::structure_tracker::pending_tabs();
                            // Counter increments — a Table tab listed in both
                            // sets bumps to 2 so the window close waits for
                            // BOTH the browse save and the structure save.
                            {
                                let mut map = close_after_save_for_resp.borrow_mut();
                                for id in browse_tabs.iter().copied() {
                                    *map.entry(id).or_insert(0) += 1;
                                }
                                for id in structure_tabs.iter().copied() {
                                    *map.entry(id).or_insert(0) += 1;
                                }
                            }
                            close_window_after_save_for_resp.set(true);
                            for id in browse_tabs {
                                let _ = input_sender_for_resp.send(AppMsg::SaveActiveBrowseTabById(id));
                            }
                            for id in structure_tabs {
                                let _ = input_sender_for_resp.send(AppMsg::SaveActiveStructureTabById(id));
                            }
                        }
                        _ => {} // Cancel: do nothing, stay open.
                    }
                });
                dialog.present(Some(w));
                return glib::Propagation::Stop;
            }
            crate::ui::window_geometry::persist(w, &settings_for_close);
            // The last column drag or filter change may still be on its
            // way to disk. The hold keeps the process alive until it
            // lands, so quitting does not lose it.
            let hold = w
                .application()
                .map(|app| gio::prelude::ApplicationExtManual::hold(&app));
            let column_widths = storage_for_close.column_widths().flush();
            let filter_settings = storage_for_close.filter_settings().flush();
            let editor_drafts = drafts_for_close.flush_all();
            glib::spawn_future_local(async move {
                column_widths.await;
                filter_settings.await;
                for failure in editor_drafts.await {
                    tracing::warn!(failure, "an editor draft was not saved");
                }
                drop(hold);
            });
            glib::Propagation::Proceed
        });

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

        // Empty-state placeholder. Shown by GtkListBox when no row is
        // visible — covers both "the database has zero tables" and
        // "the search filtered everything out". Without this, the
        // sidebar renders as a blank surface and reads as broken.
        // AdwStatusPage `.compact` is the documented empty-state
        // widget for narrow containers (matches GNOME Files's
        // sidebar-empty look).
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
        sidebar_listbox.set_header_func(move |row, before| {
            let schemas = schemas_for_header.borrow();
            let total_distinct: std::collections::BTreeSet<&str> =
                schemas.iter().filter_map(|s| s.as_deref()).collect();
            // Postgres-style multi-schema connections render a header
            // per schema with a "+" button for "New Table…". Single-
            // schema connections (MySQL / SQLite) get one header
            // anchored to "main" / database-name with the same "+"
            // affordance — the visual cue matters even when there's
            // only one schema in the list.
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
            let header_box = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(6)
                .margin_top(12)
                .margin_bottom(6)
                .margin_start(12)
                // Match the row body's `margin_end: 12` so the "+"
                // button sits flush with where row content ends — the
                // previous 6px pulled it inward of the row label edge
                // and read as a misaligned column.
                .margin_end(12)
                .build();
            let label_text = current
                .as_deref()
                .map(|s| s.to_string())
                .unwrap_or_else(|| crate::i18n::gettext("Tables"));
            let label = gtk::Label::builder()
                .label(&label_text)
                .xalign(0.0)
                .hexpand(true)
                .build();
            // GtkPlacesSidebar section-header typography: small + bold
            // + ~55% alpha. `.heading` (libadwaita's "emphasized body")
            // combined with `.dim-label` rendered as bold-dim at body
            // size — too loud for a section divider. `.caption-heading`
            // is the small-bold variant the toolkit ships for exactly
            // this purpose.
            label.add_css_class("caption-heading");
            label.add_css_class("dim-label");
            header_box.append(&label);
            // "+" button: emit NewTableTab carrying this schema. Flat
            // styling matches GNOME Files' inline-add buttons; the
            // tooltip clarifies the destination ("New Table in …")
            // so the user understands what the schema scoping means.
            let new_table_button = gtk::Button::builder()
                .icon_name(crate::ui::icons::LIST_ADD)
                .tooltip_text(match current.as_deref() {
                    Some(s) => crate::i18n::gettext_f("New Table in {schema}…", &[("schema", s)]),
                    None => crate::i18n::gettext("New Table…"),
                })
                .valign(gtk::Align::Center)
                .build();
            new_table_button.add_css_class("flat");
            let sender_for_button = sender_for_header.clone();
            let schema_for_button = current.clone();
            new_table_button.connect_clicked(move |_| {
                sender_for_button.input(AppMsg::NewTableTab {
                    schema: schema_for_button.clone(),
                });
            });
            header_box.append(&new_table_button);
            row.set_header(Some(&header_box));
        });

        let connections_factory: FactoryVecDeque<ConnectionRow> = FactoryVecDeque::builder()
            .launch(
                gtk::ListBox::builder()
                    .selection_mode(gtk::SelectionMode::None)
                    .css_classes(["boxed-list"])
                    .build(),
            )
            .forward(sender.input_sender(), |out| match out {
                ConnectionRowOutput::Open(saved) => AppMsg::OpenSaved(saved),
                ConnectionRowOutput::Delete(id) => AppMsg::DeleteConnection(id),
                ConnectionRowOutput::Duplicate(saved) => AppMsg::DuplicateConnection(saved),
                ConnectionRowOutput::SetColor(id, color) => AppMsg::SetConnectionColor(id, color),
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
        // the "open editor" affordance is reachable with the mouse —
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
            .icon_name(StatusKind::Info.icon())
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
                });

        let model = App {
            registry,
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
            connections_popover: widgets.connections_popover.clone(),
            health_state: None,
            row_op_spinner: widgets.row_op_spinner.clone(),
            read_only_badge: widgets.read_only_badge.clone(),
            table_search: widgets.table_search.clone(),
            workspace_outer_stack,
            workspace_root: None,
            workspace_tab_view: None,
            workspace_root_added: std::cell::Cell::new(false),
            workspace_tabs: std::rc::Rc::new(std::cell::RefCell::new(std::collections::HashMap::new())),
            dialog: None,
            schema_buffer: build_schema_buffer(),
            history_dialog: None,
            saved_queries_dialog: None,
            welcome_view,
            current_driver_id: None,
            table_names: Vec::new(),
            read_only: false,
            saved_connections: Vec::new(),
            connected: false,
            close_after_save: close_after_save_handle,
            close_window_after_save: close_window_after_save_handle,
            in_flight_saves: in_flight_saves_handle,
            structure_saves_in_flight: std::rc::Rc::new(std::cell::RefCell::new(std::collections::HashSet::new())),
            persist_debouncer: crate::workspace::PersistDebouncer::new(WORKSPACE_PERSIST_DELAY),
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
            banner_sender.input(AppMsg::RefreshPage);
        });

        let list_banner_sender = sender.clone();
        widgets.connection_list_banner.connect_button_clicked(move |_| {
            list_banner_sender.input(AppMsg::ResetConnectionList);
        });

        let poll_sender = sender.clone();
        glib::timeout_add_seconds_local(1, move || {
            poll_sender.input(AppMsg::PollHealth);
            glib::ControlFlow::Continue
        });

        ComponentParts { model, widgets }
    }

    fn shutdown(&mut self, _widgets: &mut Self::Widgets, _output: relm4::Sender<Self::Output>) {
        // The gate holds the window's action, so it has to stop before
        // the window does.
        self.history_gate.abort();
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            AppMsg::OpenConnect => self.on_open_connect(sender),
            AppMsg::Connected { tables, driver_id } => self.on_connected(tables, driver_id, sender),
            AppMsg::Disconnect => self.on_disconnect(sender),
            AppMsg::ForceDisconnect => self.do_disconnect(sender),
            AppMsg::DialogClosed => self.dialog = None,
            AppMsg::SelectTable {
                schema,
                name,
                open_mode,
            } => self.on_select_table(schema, name, open_mode, sender),
            AppMsg::ColumnsLoaded(tab_id, columns) => self.on_browse_columns_loaded(tab_id, columns),
            AppMsg::RowsLoaded(tab_id, offset, result) => self.on_browse_rows_loaded(tab_id, offset, result),
            AppMsg::LoadFailed(tab_id, msg) => self.on_browse_load_failed(tab_id, msg),
            AppMsg::RowCountLoaded(tab_id, count) => self.on_browse_row_count_loaded(tab_id, count),
            AppMsg::FetchBrowsePage(tab_id) => self.fetch_browse_page(tab_id, sender),
            AppMsg::FetchBrowseColumns(tab_id) => self.fetch_browse_columns(tab_id, sender),
            AppMsg::FetchBrowseRowCount(tab_id) => self.fetch_browse_row_count(tab_id, sender),
            AppMsg::WorkspaceTabsChanged => self.on_workspace_tabs_changed(),
            AppMsg::WorkspaceSchemaWordsChanged => self.rebuild_schema_buffer(),
            AppMsg::ExecuteBrowseTransaction {
                tab_id,
                statements,
                sources,
            } => {
                self.on_execute_browse_transaction(tab_id, statements, sources, sender);
            }
            AppMsg::SaveCompletedForTab(tab_id, warning) => {
                self.set_row_op_in_flight(false);
                self.in_flight_saves.set(self.in_flight_saves.get().saturating_sub(1));
                // GNOME HIG toast pattern: confirm one-shot events.
                // Concurrency warning takes precedence (it implicitly
                // confirms the save *and* explains the partial-match);
                // otherwise the plain "Saved" reads as a successful
                // commit. No Undo button — the transaction has already
                // committed; users have explicit Ctrl+Z before Save.
                // 4s timeout (vs the default 5) so the success toast
                // doesn't hang around long after the user has moved on.
                let msg = warning.unwrap_or_else(|| crate::i18n::gettext("Saved"));
                let toast = adw::Toast::builder().title(msg).timeout(4).build();
                self.toast_overlay.add_toast(toast);
                self.dispatch_to_tab(tab_id, BrowseTabInput::SaveCompleted);
                // If the user picked Save in a close-confirmation
                // dialog, fire the close now that the commit succeeded.
                // The counter ensures a tab with BOTH browse-dirty and
                // structure-dirty waits for both saves before closing.
                let drained = dec_close_after_save(&mut self.close_after_save.borrow_mut(), &tab_id);
                if drained {
                    sender.input(AppMsg::WorkspaceTabClosed(tab_id));
                }
                // If we're in a window-close-Save-all flow and the map
                // just drained, the window can finally close.
                if self.close_window_after_save.get() && self.close_after_save.borrow().is_empty() {
                    self.close_window_after_save.set(false);
                    self.window.close();
                }
            }
            AppMsg::SaveFailedForTab(tab_id, message) => {
                self.set_row_op_in_flight(false);
                self.in_flight_saves.set(self.in_flight_saves.get().saturating_sub(1));
                // Abort any close-after-save intent: the commit failed,
                // so we keep the tab open and let the user see the
                // error and retry. Window-close intent is also cleared.
                self.close_after_save.borrow_mut().remove(&tab_id);
                self.close_window_after_save.set(false);
                self.dispatch_to_tab(tab_id, BrowseTabInput::SaveFailed(message));
            }
            AppMsg::FlashErrorRowForTab(tab_id, source) => {
                self.dispatch_to_tab(tab_id, BrowseTabInput::FlashErrorRow(source));
            }
            AppMsg::SaveActiveBrowseTab => {
                if let Some(id) = self.selected_browse_tab_id() {
                    self.dispatch_to_tab(id, BrowseTabInput::CommitSave);
                }
            }
            AppMsg::SaveActiveBrowseTabById(id) => {
                self.dispatch_to_tab(id, BrowseTabInput::CommitSave);
            }
            AppMsg::UndoActiveBrowseTab => {
                // Ctrl+Z routes to BrowseTab undo only. Structure
                // editing follows the snapshot+diff model — DDL undo
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
            AppMsg::BrowseTabDirtyChanged(tab_id, dirty) => self.refresh_browse_tab_dirty(tab_id, dirty),
            AppMsg::NewTableTab { schema } => self.on_new_table_tab(schema, sender),
            AppMsg::EditStructureTab { schema, table } => self.on_edit_structure_tab(schema, table, sender),
            AppMsg::ShowCreateTableForExisting { schema, table } => self.on_show_create_table(schema, table, sender),
            AppMsg::ShowCreateTableLoaded { sql } => self.append_editor_tab(Some(sql), sender),
            AppMsg::DropTablePrompt { schema, table } => self.on_drop_table_prompt(schema, table, sender),
            AppMsg::DropTableConfirmed { schema, table } => self.on_drop_table_confirmed(schema, table, sender),
            AppMsg::DropTableSucceeded { schema, table } => self.on_drop_table_succeeded(schema, table, sender),
            AppMsg::ExecuteStructureTransaction { tab_id, statements } => {
                self.on_execute_structure_transaction(tab_id, statements, sender)
            }
            AppMsg::SaveActiveStructureTabById(id) => self.save_structure_tab_by_id(id, sender),
            AppMsg::StructureSaveCompleted { tab_id, new_table_name } => {
                self.on_structure_save_completed(tab_id, new_table_name, sender)
            }
            AppMsg::StructureSaveFailed(tab_id, message) => self.on_structure_save_failed(tab_id, message),
            AppMsg::FetchStructureData { tab_id } => self.on_fetch_structure_data(tab_id, sender),
            AppMsg::StructureDataLoaded {
                tab_id,
                columns,
                indexes,
                fks,
            } => self.on_structure_data_loaded(tab_id, columns, indexes, fks),
            AppMsg::StructureLoadFailed { tab_id, message } => self.on_structure_load_failed(tab_id, message),
            AppMsg::StructureTabDirtyChanged(tab_id, dirty) => self.refresh_structure_tab_dirty(tab_id, dirty),
            AppMsg::SchemaChanged { schema, table } => self.on_schema_changed(schema, table, sender),
            AppMsg::TablesReloaded(tables) => self.on_tables_reloaded(tables),
            AppMsg::RowOpStarted => self.set_row_op_in_flight(true),
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
            AppMsg::EditorTabQueryChanged(id, text) => self.on_editor_tab_query_changed(id, text),
            AppMsg::WorkspaceTabsRead { saved, drafts } => self.on_workspace_tabs_read(saved, drafts, sender),
            AppMsg::ShowHistory => self.on_show_history(sender),
            AppMsg::ShowSavedQueries => self.on_show_saved_queries(sender),
            AppMsg::SetConnectionColor(id, color) => self.on_set_connection_color(id, color, sender),
            AppMsg::ExportConnections => self.on_export_connections(sender),
            AppMsg::ImportConnections => self.on_import_connections(sender),
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
            AppMsg::PollHealth => self.on_poll_health(),
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
                super::export_dialog::present(&self.window, &self.toast_overlay, result, name, target, &self.settings)
            }
            AppMsg::CopyToClipboard(text) => self.on_copy_to_clipboard(text),
            AppMsg::CopyRowAsInsert { tab_id, row_position } => self.on_copy_row_as_insert(tab_id, row_position),
            AppMsg::DeleteConnection(id) => self.on_delete_connection(id, sender),
            AppMsg::DuplicateConnection(saved) => self.on_duplicate_connection(saved, sender),
            AppMsg::OpenSaved(saved) => self.on_open_saved(saved, sender),
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
        input_action!("save-changes", AppMsg::SaveActiveBrowseTab),
        input_action!("undo-change", AppMsg::UndoActiveBrowseTab),
        input_action!("redo-change", AppMsg::RedoActiveBrowseTab),
        input_action!("reopen-closed-tab", AppMsg::ReopenClosedTab),
        input_action!("open-filter", AppMsg::ShowFilterDialog),
        input_action!("save-query", AppMsg::SaveActiveQuery),
        input_action!("export-connections", AppMsg::ExportConnections),
        input_action!("import-connections", AppMsg::ImportConnections),
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
