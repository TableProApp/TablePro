mod browse;
mod connection;
mod row_ops;
mod status_pages;
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
use super::edit_dialog::EditDialog;
use super::editor::{SqlEditor, build_schema_buffer};
use super::history_dialog::HistoryDialog;
use super::insert_dialog::InsertDialog;
use super::sidebar_row::{SidebarRow, SidebarRowOutput};
use super::welcome_view::{WelcomeView, WelcomeViewInit, WelcomeViewOutput};
use crate::services::database_service;
use crate::services::database_service::ConnectionHealth;
use tablepro_core::sql_dialect::{placeholder_for, quote_ident};

pub struct App {
    registry: Arc<DriverRegistry>,
    window: adw::ApplicationWindow,
    split_view: adw::OverlaySplitView,
    window_title: adw::WindowTitle,
    disconnect_action: gio::SimpleAction,
    sidebar_factory: FactoryVecDeque<SidebarRow>,
    sidebar_schemas: std::rc::Rc<std::cell::RefCell<Vec<Option<String>>>>,
    content_holder: adw::ToolbarView,
    toast_overlay: adw::ToastOverlay,
    reconnect_banner: adw::Banner,
    connections_factory: FactoryVecDeque<ConnectionRow>,
    connections_popover: gtk::Popover,
    health_state: Option<ConnectionHealth>,
    row_op_spinner: gtk::Spinner,
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
    insert_dialog: Option<Controller<InsertDialog>>,
    edit_dialog: Option<Controller<EditDialog>>,
    history_dialog: Option<Controller<HistoryDialog>>,
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
    default_page_size: u64,
    saved_connections: Vec<SavedConnection>,
    connected: bool,
}

pub struct EditorTabSlot {
    #[allow(dead_code)]
    pub id: Uuid,
    pub controller: Controller<SqlEditor>,
    pub page: adw::TabPage,
    pub query: String,
}

pub struct BrowseTabSlot {
    #[allow(dead_code)]
    pub id: Uuid,
    pub controller: Controller<BrowseTab>,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    pub table: String,
}

/// A tab in the unified workspace — either a Browse table view or an
/// SQL editor. Stored together in a single HashMap so the user-facing
/// tab strip is one homogeneous list rather than two ViewSwitcher
/// modes.
pub enum WorkspaceTab {
    Browse(BrowseTabSlot),
    Editor(EditorTabSlot),
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
    InsertCommitted(Uuid),
    EditCommitted(Uuid),
    RowOperationCommitted(Uuid, Option<UndoBatch>),
    RowOpStarted,
    ExecuteUndo(UndoBatch),
    CellEdited {
        tab_id: Uuid,
        table: String,
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    ReloadConnections,
    ConnectionsLoaded(Vec<SavedConnection>),
    OpenSaved(SavedConnection),
    DeleteConnection(Uuid),
    /// "+ New query" button or Ctrl+T → append a new editor tab.
    NewEditorTab,
    /// Ctrl+W → close active workspace tab (browse or editor).
    CloseActiveWorkspaceTab,
    EditorTabRunStateChanged(Uuid, bool),
    EditorTabQueryChanged(Uuid, String),
    ShowHistory,
    OpenHistoryQuery(String),
    ReplaceActiveTabQuery(String),
    Disconnect,
    PollHealth,
    RefreshPage,
    ShowShortcuts,
    ShowAbout,
    ShowPreferences,
    /// Sort flipped on tab_id's grid for column idx.
    RowCountLoaded(Uuid, u64),
    FindInResults,
    ExportCsv,
    ExportJson,
    CopyToClipboard(String),
    SetCellNull {
        tab_id: Uuid,
        table: String,
        row_position: u32,
        col_index: usize,
    },
    DeleteRowAt {
        tab_id: Uuid,
        table: String,
        row_position: u32,
    },
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
    /// Drag-reorder / selection change / browse-tab-state-changed —
    /// triggers persistence (writes the current display order + each
    /// slot's state to workspace_state.json).
    WorkspaceTabsChanged,
    /// Show insert dialog scoped to a specific browse tab.
    ShowInsertDialog {
        tab_id: Uuid,
        table: String,
        columns: Vec<ColumnInfo>,
        driver_id: String,
    },
    /// Show edit dialog scoped to a specific browse tab.
    ShowEditDialog {
        tab_id: Uuid,
        table: String,
        columns: Vec<ColumnInfo>,
        driver_id: String,
        row: Vec<Value>,
    },
    /// Confirm-and-execute a multi-row delete from a specific tab.
    ConfirmDeleteSelected {
        tab_id: Uuid,
        table: String,
        columns: Vec<ColumnInfo>,
        driver_id: String,
        positions: Vec<u32>,
        rows: Vec<Vec<Value>>,
    },
    /// Show a small alert dialog; used by BrowseTab for "select exactly
    /// one row" type messages.
    ShowAlert {
        title: String,
        body: String,
    },
}

#[derive(Debug, Clone, Copy)]
enum ExportFormat {
    Csv,
    Json,
}

#[derive(Debug, Clone)]
pub struct UndoBatch {
    pub label: String,
    pub statements: Vec<(String, Vec<Value>)>,
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
            StatusKind::Info => "view-grid-symbolic",
            StatusKind::Error => "dialog-error-symbolic",
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
    type Init = Arc<DriverRegistry>;
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

                    #[name = "connection_split_button"]
                    pack_start = &adw::SplitButton {
                        set_icon_name: "list-add-symbolic",
                        set_tooltip_text: Some(crate::tr!("New connection").as_str()),
                        set_dropdown_tooltip: crate::tr!("Open saved connection").as_str(),
                        connect_clicked => AppMsg::OpenConnect,

                        #[wrap(Some)]
                        #[name = "connections_popover"]
                        set_popover = &gtk::Popover {},
                    },

                    #[name = "read_only_badge"]
                    pack_end = &gtk::Label {
                        set_visible: false,
                        set_label: &crate::tr!("Read-only"),
                        set_margin_end: 6,
                        add_css_class: "warning",
                        add_css_class: "caption-heading",
                    },

                    #[name = "row_op_spinner"]
                    pack_end = &gtk::Spinner {
                        set_visible: false,
                        set_margin_end: 6,
                        set_tooltip_text: Some(crate::tr!("Saving…").as_str()),
                    },

                    #[name = "primary_menu_button"]
                    pack_end = &gtk::MenuButton {
                        set_icon_name: "open-menu-symbolic",
                        set_tooltip_text: Some(crate::tr!("Main menu").as_str()),
                    },
                },

                #[wrap(Some)]
                #[name = "split_view"]
                set_content = &adw::OverlaySplitView {
                    set_min_sidebar_width: 220.0,
                    set_max_sidebar_width: 280.0,
                    set_show_sidebar: false,

                    #[wrap(Some)]
                    #[name = "sidebar_root"]
                    set_sidebar = &gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,

                        #[name = "table_search_bar"]
                        gtk::SearchBar {
                            set_show_close_button: true,
                            set_search_mode: false,

                            #[wrap(Some)]
                            #[name = "table_search"]
                            set_child = &gtk::SearchEntry {
                                set_placeholder_text: Some(crate::tr!("Filter tables…").as_str()),
                                set_hexpand: true,
                            },
                        },

                        #[name = "sidebar_scroll"]
                        gtk::ScrolledWindow {
                            set_hscrollbar_policy: gtk::PolicyType::Never,
                            set_vexpand: true,
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
                                set_button_label: Some(crate::tr!("Retry").as_str()),
                            },

                            #[wrap(Some)]
                            set_content = &adw::StatusPage {
                                set_icon_name: Some("network-server-symbolic"),
                                set_title: &crate::tr!("Connect to a database"),
                                set_description: Some(crate::tr!("Click the server icon for a new connection or the folder icon to open a saved one.").as_str()),
                            },
                        },
                    },
                },
            },
        }
    }

    fn init(registry: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let widgets = view_output!();

        let restored = crate::services::window_state::load();
        widgets.window.set_default_size(restored.width, restored.height);
        if restored.maximized {
            widgets.window.maximize();
        }
        widgets.window.connect_close_request(|w| {
            let (width, height) = if w.is_maximized() {
                (w.default_width(), w.default_height())
            } else {
                (w.width(), w.height())
            };
            crate::services::window_state::save(crate::services::window_state::WindowState {
                width,
                height,
                maximized: w.is_maximized(),
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
                // Both default activation and Ctrl+click currently dispatch
                // Default activation = smart-switch (Q1); Ctrl+click /
                // right-click = always new tab.
                SidebarRowOutput::Selected { schema, name } => AppMsg::SelectTable {
                    schema,
                    name,
                    open_mode: OpenMode::SwitchOrAppend,
                },
                SidebarRowOutput::OpenInNewTab { schema, name } => AppMsg::SelectTable {
                    schema,
                    name,
                    open_mode: OpenMode::NewTab,
                },
            });

        let sidebar_listbox = sidebar_factory.widget();
        widgets.sidebar_scroll.set_child(Some(sidebar_listbox));

        let search_for_filter = widgets.table_search.clone();
        sidebar_listbox.set_filter_func(move |row| {
            let query = search_for_filter.text().to_lowercase();
            if query.is_empty() {
                return true;
            }
            row.downcast_ref::<adw::ActionRow>()
                .map(|r| r.title().to_lowercase().contains(&query))
                .unwrap_or(true)
        });
        let listbox_for_invalidate = sidebar_listbox.clone();
        widgets.table_search.connect_search_changed(move |_| {
            listbox_for_invalidate.invalidate_filter();
        });
        widgets.table_search_bar.connect_entry(&widgets.table_search);
        widgets
            .table_search_bar
            .set_key_capture_widget(Some(&widgets.sidebar_root));

        let schemas_for_header = sidebar_schemas.clone();
        sidebar_listbox.set_header_func(move |row, before| {
            let schemas = schemas_for_header.borrow();
            let total_distinct: std::collections::BTreeSet<&str> =
                schemas.iter().filter_map(|s| s.as_deref()).collect();
            if total_distinct.len() < 2 {
                row.set_header(gtk::Widget::NONE);
                return;
            }
            let idx = row.index();
            let current = schemas.get(idx as usize).and_then(|s| s.as_deref());
            let prev_idx = before.map(|b| b.index());
            let prev = prev_idx
                .and_then(|i| schemas.get(i as usize))
                .and_then(|s| s.as_deref());
            let needs = match (current, prev) {
                (Some(c), Some(p)) => c != p,
                (Some(_), None) => true,
                _ => false,
            };
            if needs {
                let header = gtk::Label::builder()
                    .label(current.unwrap_or(""))
                    .xalign(0.0)
                    .margin_top(8)
                    .margin_bottom(4)
                    .margin_start(12)
                    .margin_end(12)
                    .build();
                header.add_css_class("heading");
                header.add_css_class("dim-label");
                row.set_header(Some(&header));
            } else {
                row.set_header(gtk::Widget::NONE);
            }
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
        let workspace_empty_page = adw::StatusPage::builder()
            .icon_name(StatusKind::Info.icon())
            .title(crate::tr!("Select a table"))
            .description(crate::tr!(
                "Pick a table from the sidebar, or press Ctrl+T to open a query editor."
            ))
            .build();
        workspace_outer_stack.add_named(&workspace_empty_page, Some("empty"));
        workspace_outer_stack.set_visible_child_name("empty");

        let disconnect_action = install_window_actions(&widgets.window, sender.clone());
        install_window_shortcuts(&widgets.window);
        widgets.primary_menu_button.set_menu_model(Some(&primary_menu_model()));

        let welcome_view =
            WelcomeView::builder()
                .launch(WelcomeViewInit)
                .forward(sender.input_sender(), |out| match out {
                    WelcomeViewOutput::OpenConnect => AppMsg::OpenConnect,
                    WelcomeViewOutput::OpenSaved(saved) => AppMsg::OpenSaved(saved),
                    WelcomeViewOutput::Delete(id) => AppMsg::DeleteConnection(id),
                });

        let model = App {
            registry,
            window: root.clone(),
            split_view: widgets.split_view.clone(),
            window_title: widgets.window_title.clone(),
            disconnect_action,
            sidebar_factory,
            sidebar_schemas,
            content_holder: widgets.content_holder.clone(),
            toast_overlay: widgets.toast_overlay.clone(),
            reconnect_banner: widgets.reconnect_banner.clone(),
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
            insert_dialog: None,
            edit_dialog: None,
            history_dialog: None,
            welcome_view,
            current_driver_id: None,
            table_names: Vec::new(),
            read_only: false,
            default_page_size: crate::services::preferences::load().default_page_size,
            saved_connections: Vec::new(),
            connected: false,
        };
        sender.input(AppMsg::ReloadConnections);
        model.show_welcome_page(sender.clone());

        widgets
            .connection_split_button
            .update_property(&[gtk::accessible::Property::Label("New connection")]);
        widgets
            .primary_menu_button
            .update_property(&[gtk::accessible::Property::Label("Main menu")]);

        let banner_sender = sender.clone();
        widgets.reconnect_banner.connect_button_clicked(move |_| {
            banner_sender.input(AppMsg::RefreshPage);
        });

        let poll_sender = sender.clone();
        glib::timeout_add_seconds_local(1, move || {
            poll_sender.input(AppMsg::PollHealth);
            glib::ControlFlow::Continue
        });

        glib::timeout_add_seconds_local(3600, || {
            let retention = crate::services::preferences::load().history_retention_days;
            relm4::spawn(async move {
                if let Err(e) = tablepro_storage::query_history::prune_older_than(retention).await {
                    tracing::warn!(error = %e, "history prune failed");
                }
            });
            glib::ControlFlow::Continue
        });

        ComponentParts { model, widgets }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            AppMsg::OpenConnect => self.on_open_connect(sender),
            AppMsg::Connected { tables, driver_id } => self.on_connected(tables, driver_id, sender),
            AppMsg::Disconnect => self.on_disconnect(sender),
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
            AppMsg::WorkspaceTabClosed(id) => self.close_workspace_tab_by_id(id, sender),
            AppMsg::CloseActiveWorkspaceTab => self.close_active_workspace_tab(sender),
            AppMsg::ShowAlert { title, body } => self.show_error_alert(&title, &body),
            AppMsg::ShowInsertDialog {
                tab_id,
                table,
                columns,
                driver_id,
            } => self.on_show_insert_dialog(tab_id, table, columns, driver_id, sender),
            AppMsg::ShowEditDialog {
                tab_id,
                table,
                columns,
                driver_id,
                row,
            } => self.on_show_edit_dialog(tab_id, table, columns, driver_id, row, sender),
            AppMsg::ConfirmDeleteSelected {
                tab_id,
                table,
                columns,
                driver_id,
                positions,
                rows,
            } => self.on_confirm_delete_selected(tab_id, table, columns, driver_id, positions, rows, sender),
            AppMsg::InsertCommitted(tab_id) => self.on_insert_committed(tab_id),
            AppMsg::EditCommitted(tab_id) => self.on_edit_committed(tab_id),
            AppMsg::RowOperationCommitted(tab_id, undo) => {
                self.set_row_op_in_flight(false);
                let label = undo
                    .as_ref()
                    .map(|u| u.label.clone())
                    .unwrap_or_else(|| crate::tr!("Rows updated"));
                if let Some(u) = undo {
                    self.show_undoable_toast(&label, u, sender.clone());
                } else {
                    self.show_toast(&label);
                }
                // Refetch only if the originating tab is still alive (Q10).
                self.dispatch_to_tab(tab_id, BrowseTabInput::Refresh);
            }
            AppMsg::RowOpStarted => self.set_row_op_in_flight(true),
            AppMsg::ExecuteUndo(batch) => {
                self.set_row_op_in_flight(true);
                self.show_toast(&crate::tr!("Undoing…"));
                if let Some(tab_id) = self.selected_browse_tab_id() {
                    run_undo_batch(sender, tab_id, batch);
                }
            }
            AppMsg::CellEdited {
                tab_id,
                table,
                row_position,
                col_index,
                new_value,
            } => self.on_cell_edited(tab_id, table, row_position, col_index, new_value, sender),
            AppMsg::ReloadConnections => self.on_reload_connections(sender),
            AppMsg::ConnectionsLoaded(connections) => {
                let conns = connections;
                self.on_connections_loaded(&conns, sender);
            }
            AppMsg::NewEditorTab => self.append_editor_tab(None, sender),
            AppMsg::EditorTabRunStateChanged(id, running) => self.on_editor_tab_run_state_changed(id, running),
            AppMsg::EditorTabQueryChanged(id, text) => self.on_editor_tab_query_changed(id, text),
            AppMsg::ShowHistory => self.on_show_history(sender),
            AppMsg::OpenHistoryQuery(text) => {
                if self.connected {
                    self.append_editor_tab(Some(text), sender);
                } else {
                    self.show_toast(&crate::tr!("Connect to a database first to run SQL."));
                }
            }
            AppMsg::ReplaceActiveTabQuery(text) => {
                if self.connected {
                    self.on_replace_active_tab_query(text, sender);
                } else {
                    self.show_toast(&crate::tr!("Connect to a database first to run SQL."));
                }
            }
            AppMsg::PollHealth => self.on_poll_health(),
            AppMsg::RefreshPage => self.on_refresh_active_tab(),
            AppMsg::ShowShortcuts => self.on_show_shortcuts(),
            AppMsg::ShowAbout => self.on_show_about(),
            AppMsg::ShowPreferences => super::preferences::present(&self.window),
            AppMsg::FindInResults => self.on_find_in_results(),
            AppMsg::ExportCsv => self.on_export(ExportFormat::Csv),
            AppMsg::ExportJson => self.on_export(ExportFormat::Json),
            AppMsg::CopyToClipboard(text) => self.on_copy_to_clipboard(text),
            AppMsg::SetCellNull {
                tab_id,
                table,
                row_position,
                col_index,
            } => self.on_set_cell_null(tab_id, table, row_position, col_index, sender),
            AppMsg::DeleteRowAt {
                tab_id,
                table,
                row_position,
            } => self.on_delete_row_at(tab_id, table, row_position, sender),
            AppMsg::CopyRowAsInsert { tab_id, row_position } => self.on_copy_row_as_insert(tab_id, row_position),
            AppMsg::DeleteConnection(id) => self.on_delete_connection(id, sender),
            AppMsg::OpenSaved(saved) => self.on_open_saved(saved, sender),
        }
    }
}

fn value_to_sql_literal(v: &Value) -> String {
    match v {
        Value::Null => "NULL".into(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Text(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Bytes(_) => "/* bytes omitted */ NULL".into(),
        Value::Date(d) => format!("'{}'", d.format("%Y-%m-%d")),
        Value::Time(t) => format!("'{}'", t.format("%H:%M:%S")),
        Value::DateTime(dt) => format!("'{}'", dt.format("%Y-%m-%d %H:%M:%S")),
        Value::TimestampTz(ts) => format!("'{}'", ts.to_rfc3339()),
        Value::Uuid(u) => format!("'{u}'"),
        Value::Json(j) => format!("'{}'", j.to_string().replace('\'', "''")),
    }
}

fn render_csv(result: &QueryResult) -> Vec<u8> {
    let mut out = String::new();
    let cols: Vec<&str> = result.columns.iter().map(|c| c.name.as_str()).collect();
    out.push_str(&cols.iter().map(|c| csv_escape(c)).collect::<Vec<_>>().join(","));
    out.push('\n');
    for row in &result.rows {
        let cells: Vec<String> = row
            .iter()
            .map(|v| csv_escape(&super::grid::value_to_display_text(v)))
            .collect();
        out.push_str(&cells.join(","));
        out.push('\n');
    }
    out.into_bytes()
}

fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn render_json(result: &QueryResult) -> Vec<u8> {
    let cols: Vec<&str> = result.columns.iter().map(|c| c.name.as_str()).collect();
    let rows: Vec<serde_json::Value> = result
        .rows
        .iter()
        .map(|row| {
            let mut obj = serde_json::Map::new();
            for (i, col) in cols.iter().enumerate() {
                let v = row.get(i).cloned().unwrap_or(Value::Null);
                obj.insert((*col).to_string(), value_to_json(&v));
            }
            serde_json::Value::Object(obj)
        })
        .collect();
    serde_json::to_vec_pretty(&rows).unwrap_or_default()
}

fn value_to_json(v: &Value) -> serde_json::Value {
    use serde_json::Value as J;
    match v {
        Value::Null => J::Null,
        Value::Bool(b) => J::Bool(*b),
        Value::Int(i) => J::from(*i),
        Value::Float(f) => J::from(*f),
        Value::Text(s) => J::String(s.clone()),
        Value::Bytes(b) => J::String(format!("<{} bytes>", b.len())),
        Value::Date(d) => J::String(d.to_string()),
        Value::Time(t) => J::String(t.to_string()),
        Value::DateTime(dt) => J::String(dt.to_string()),
        Value::TimestampTz(ts) => J::String(ts.to_rfc3339()),
        Value::Decimal(d) => J::String(d.to_string()),
        Value::Uuid(u) => J::String(u.to_string()),
        Value::Json(j) => j.clone(),
    }
}

pub(super) fn execute_many_then_refetch_for_tab(
    tab_id: Uuid,
    sender: ComponentSender<App>,
    sql: String,
    batches: Vec<Vec<Value>>,
    undo: Option<UndoBatch>,
) {
    let Some(conn) = database_service::instance().active() else {
        sender.input(AppMsg::LoadFailed(Some(tab_id), "no active connection".into()));
        return;
    };
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                let mut total: u64 = 0;
                for params in &batches {
                    match conn.execute_params(&sql, params).await {
                        Ok(exec) => total += exec.rows_affected,
                        Err(e) => {
                            tracing::warn!(error = %e, "execute (multi) failed");
                            sender_clone.input(AppMsg::LoadFailed(Some(tab_id), super::error_text::driver_message(&e)));
                            return;
                        }
                    }
                }
                tracing::info!(rows = total, "multi-execute ok");
                sender_clone.input(AppMsg::RowOperationCommitted(tab_id, undo));
            })
            .drop_on_shutdown()
    });
}

pub(super) fn execute_then_refetch_for_tab(
    tab_id: Uuid,
    sender: ComponentSender<App>,
    sql: String,
    params: Vec<Value>,
    undo: Option<UndoBatch>,
) {
    let Some(conn) = database_service::instance().active() else {
        sender.input(AppMsg::LoadFailed(Some(tab_id), "no active connection".into()));
        return;
    };
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                match conn.execute_params(&sql, &params).await {
                    Ok(exec) => {
                        tracing::info!(rows = exec.rows_affected, "execute ok");
                        sender_clone.input(AppMsg::RowOperationCommitted(tab_id, undo));
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "execute failed");
                        sender_clone.input(AppMsg::LoadFailed(Some(tab_id), super::error_text::driver_message(&e)));
                    }
                }
            })
            .drop_on_shutdown()
    });
}

fn run_undo_batch(sender: ComponentSender<App>, tab_id: Uuid, batch: UndoBatch) {
    let Some(conn) = database_service::instance().active() else {
        sender.input(AppMsg::LoadFailed(Some(tab_id), "no active connection".into()));
        return;
    };
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                for (sql, params) in batch.statements.iter() {
                    if let Err(e) = conn.execute_params(sql, params).await {
                        tracing::warn!(error = %e, "undo failed");
                        sender_clone.input(AppMsg::LoadFailed(Some(tab_id), super::error_text::driver_message(&e)));
                        return;
                    }
                }
                tracing::info!(count = batch.statements.len(), "undo ok");
                sender_clone.input(AppMsg::RowOperationCommitted(tab_id, None));
            })
            .drop_on_shutdown()
    });
}

fn build_insert_for_row(driver_id: &str, table: &str, columns: &[ColumnInfo], row: &[Value]) -> (String, Vec<Value>) {
    let cols: Vec<String> = columns.iter().map(|c| quote_ident(driver_id, &c.name)).collect();
    let placeholders: Vec<String> = (0..columns.len()).map(|i| placeholder_for(driver_id, i)).collect();
    let sql = format!(
        "INSERT INTO {} ({}) VALUES ({})",
        quote_ident(driver_id, table),
        cols.join(", "),
        placeholders.join(", "),
    );
    (sql, row.to_vec())
}

fn preview_pk(columns: &[ColumnInfo], pk_indexes: &[usize], row: &[Value]) -> String {
    pk_indexes
        .iter()
        .map(|i| {
            let name = &columns[*i].name;
            let raw = super::grid::value_to_display_text(&row[*i]);
            let value = match &row[*i] {
                Value::Text(_) => format!("'{raw}'"),
                _ => raw,
            };
            format!("{name} = {value}")
        })
        .collect::<Vec<_>>()
        .join(" AND ")
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
    let disconnect_item = gio::MenuItem::new(Some(&crate::tr!("Disconnect")), Some("win.disconnect"));
    disconnect_item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
    connection_section.append_item(&disconnect_item);
    menu.append_section(None, &connection_section);
    let history_section = gio::Menu::new();
    history_section.append(Some(&crate::tr!("Query History")), Some("win.show-history"));
    menu.append_section(None, &history_section);
    let prefs_section = gio::Menu::new();
    prefs_section.append(Some(&crate::tr!("Preferences")), Some("win.preferences"));
    menu.append_section(None, &prefs_section);
    let app_section = gio::Menu::new();
    app_section.append(Some(&crate::tr!("Keyboard Shortcuts")), Some("win.shortcuts"));
    app_section.append(Some(&crate::tr!("About TablePro")), Some("win.about"));
    app_section.append(Some(&crate::tr!("Quit")), Some("win.quit"));
    menu.append_section(None, &app_section);
    menu
}

fn install_window_actions(window: &adw::ApplicationWindow, sender: ComponentSender<App>) -> gio::SimpleAction {
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
        input_action!("shortcuts", AppMsg::ShowShortcuts),
        input_action!("about", AppMsg::ShowAbout),
        quit,
        input_action!("open-editor", AppMsg::NewEditorTab),
        input_action!("disconnect", AppMsg::Disconnect),
        input_action!("close-current", AppMsg::CloseActiveWorkspaceTab),
        input_action!("preferences", AppMsg::ShowPreferences),
        input_action!("show-history", AppMsg::ShowHistory),
        input_action!("refresh-page", AppMsg::RefreshPage),
        input_action!("find-in-results", AppMsg::FindInResults),
        input_action!("export-csv", AppMsg::ExportCsv),
        input_action!("export-json", AppMsg::ExportJson),
    ]);
    window.insert_action_group("win", Some(&group));
    let disconnect_action: gio::SimpleAction = group
        .lookup_action("disconnect")
        .and_then(|a| a.downcast::<gio::SimpleAction>().ok())
        .expect("disconnect action must be a SimpleAction");
    disconnect_action.set_enabled(false);
    tracing::info!(enabled = disconnect_action.is_enabled(), "registered win.disconnect");
    disconnect_action
}

fn install_window_shortcuts(window: &adw::ApplicationWindow) {
    let controller = gtk::ShortcutController::new();
    controller.set_scope(gtk::ShortcutScope::Global);
    controller.add_shortcut(make_shortcut("<Primary>question", "win.shortcuts"));
    controller.add_shortcut(make_shortcut("<Primary>slash", "win.shortcuts"));
    controller.add_shortcut(make_shortcut("<Primary>q", "win.quit"));
    controller.add_shortcut(make_shortcut("<Primary>w", "win.close-current"));
    controller.add_shortcut(make_shortcut("<Primary>e", "win.open-editor"));
    controller.add_shortcut(make_shortcut("F5", "win.refresh-page"));
    controller.add_shortcut(make_shortcut("<Primary>f", "win.find-in-results"));
    controller.add_shortcut(make_shortcut("<Primary>comma", "win.preferences"));
    controller.add_shortcut(make_shortcut("<Primary>h", "win.show-history"));
    window.add_controller(controller);
}

fn make_shortcut(trigger: &str, action: &str) -> gtk::Shortcut {
    gtk::Shortcut::builder()
        .trigger(&gtk::ShortcutTrigger::parse_string(trigger).expect("valid trigger"))
        .action(&gtk::NamedAction::new(action))
        .build()
}

fn build_shortcuts_window(parent: &adw::ApplicationWindow) -> gtk::ShortcutsWindow {
    let window = gtk::ShortcutsWindow::builder()
        .modal(true)
        .transient_for(parent)
        .build();
    let section = gtk::ShortcutsSection::builder().section_name("application").build();

    let general = gtk::ShortcutsGroup::builder().title(crate::tr!("General")).build();
    general.append(&shortcut_entry("<Primary>e", &crate::tr!("Open SQL editor")));
    general.append(&shortcut_entry("<Primary>f", &crate::tr!("Find in results")));
    general.append(&shortcut_entry("F5", &crate::tr!("Refresh table")));
    general.append(&shortcut_entry("<Primary>comma", &crate::tr!("Open Preferences")));
    general.append(&shortcut_entry("<Primary>h", &crate::tr!("Open Query History")));
    general.append(&shortcut_entry(
        "<Primary>question",
        &crate::tr!("Show keyboard shortcuts"),
    ));
    general.append(&shortcut_entry("<Primary>q", &crate::tr!("Quit")));
    // Ctrl+W is documented in the SQL editor section because it's
    // context-sensitive (close current tab when in editor, close window
    // otherwise). Listing it twice with different labels confused readers.
    section.append(&general);

    let editor = gtk::ShortcutsGroup::builder().title(crate::tr!("SQL editor")).build();
    editor.append(&shortcut_entry("<Primary>Return", &crate::tr!("Run query")));
    editor.append(&shortcut_entry("Escape", &crate::tr!("Cancel running query")));
    editor.append(&shortcut_entry("<Primary>t", &crate::tr!("New editor tab")));
    editor.append(&shortcut_entry(
        "<Primary>w",
        &crate::tr!("Close current tab or window"),
    ));
    editor.append(&shortcut_entry("<Primary>Tab", &crate::tr!("Next editor tab")));
    editor.append(&shortcut_entry(
        "<Primary><Shift>Tab",
        &crate::tr!("Previous editor tab"),
    ));
    section.append(&editor);

    let dialogs = gtk::ShortcutsGroup::builder().title(crate::tr!("Dialogs")).build();
    dialogs.append(&shortcut_entry("Escape", &crate::tr!("Close dialog")));
    section.append(&dialogs);

    window.add_section(&section);
    window
}

fn shortcut_entry(accel: &str, title: &str) -> gtk::ShortcutsShortcut {
    gtk::ShortcutsShortcut::builder()
        .accelerator(accel)
        .title(title)
        .build()
}
