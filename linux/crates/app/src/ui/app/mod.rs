mod browse;
mod connection;
mod editor_tabs;
mod row_ops;
mod status_pages;

use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::gtk::{gio, glib};
use relm4::prelude::*;
use relm4::{Controller, adw, gtk};

use tablepro_core::{ColumnInfo, DriverRegistry, QueryResult, TableInfo, Value};
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::connect_dialog::ConnectDialog;
use super::connection_row::{ConnectionRow, ConnectionRowOutput};
use super::edit_dialog::EditDialog;
use super::editor::{SqlEditor, SqlEditorInit, SqlEditorOutput, build_schema_buffer};
use super::grid::GridMsg;
use super::history_dialog::HistoryDialog;
use super::insert_dialog::InsertDialog;
use super::sidebar_row::{SidebarRow, SidebarRowOutput};
use super::welcome_view::{WelcomeView, WelcomeViewInit, WelcomeViewOutput};
use crate::services::database_service;
use crate::services::database_service::ConnectionHealth;
use tablepro_core::sql_dialect::{placeholder_for, quote_ident};

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;

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
    paginator_label: gtk::Label,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    insert_button: gtk::Button,
    edit_row_button: gtk::Button,
    delete_button: gtk::Button,
    grid_holder: gtk::Box,
    grid_search: gtk::SearchEntry,
    grid_search_bar: gtk::SearchBar,
    grid_search_handler: Option<glib::SignalHandlerId>,
    grid_sender: relm4::Sender<GridMsg>,
    /// Inner stack for the Browse view-stack page: swaps between the table
    /// grid (`grid`) and status pages (`status`, `loading`). Replaces the
    /// previous full-window content swap so the ViewSwitcher tabs remain
    /// stable while the Browse content updates underneath.
    browse_inner_stack: gtk::Stack,
    /// Connected-state content: ViewSwitcher tabs for Browse + Editor.
    /// Hidden (replaced by `welcome_view`) while disconnected.
    view_stack: adw::ViewStack,
    /// Bottom-of-headerbar tab strip. Revealed when connected, hidden
    /// otherwise — keeps WindowTitle visible above for connection name
    /// rather than swapping it out (GNOME Maps pattern).
    view_switcher_bar: adw::ViewSwitcherBar,
    /// `true` once the Editor page has been added to view_stack — built
    /// eagerly on connect so the ViewSwitcher always has Browse + Editor
    /// peers (a single-tab switcher would be visual noise).
    editor_page_added: std::cell::Cell<bool>,
    dialog: Option<Controller<ConnectDialog>>,
    editor_root: Option<adw::TabOverview>,
    editor_tab_view: Option<adw::TabView>,
    editor_tabs: std::rc::Rc<std::cell::RefCell<std::collections::HashMap<Uuid, EditorTabSlot>>>,
    schema_buffer: gtk::TextBuffer,
    insert_dialog: Option<Controller<InsertDialog>>,
    edit_dialog: Option<Controller<EditDialog>>,
    history_dialog: Option<Controller<HistoryDialog>>,
    welcome_view: Controller<WelcomeView>,
    current_table: Option<String>,
    current_schema: Option<String>,
    current_offset: u64,
    current_columns: Vec<ColumnInfo>,
    current_result: Option<QueryResult>,
    current_selection: Option<gtk::MultiSelection>,
    current_driver_id: Option<String>,
    current_sort: Option<(usize, bool)>,
    current_total_rows: Option<u64>,
    page_size: u64,
    table_names: Vec<String>,
    saved_connections: Vec<SavedConnection>,
    connected: bool,
}

pub struct EditorTabSlot {
    pub id: Uuid,
    pub controller: Controller<SqlEditor>,
    pub page: adw::TabPage,
    pub query: String,
}

// Quark-keyed qdata avoids the type-unsafety contract of string-keyed
// `set_data`/`data` (a foreign caller could collide with the same string
// key for a different type). The Quark is interned once and cached.
fn editor_tab_id_quark() -> glib::Quark {
    static QUARK: std::sync::OnceLock<glib::Quark> = std::sync::OnceLock::new();
    *QUARK.get_or_init(|| glib::Quark::from_str("tp-editor-tab-id"))
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
    },
    ColumnsLoaded(String, Vec<ColumnInfo>),
    RowsLoaded(String, u64, QueryResult),
    LoadFailed(String),
    PrevPage,
    NextPage,
    InsertRow,
    InsertCommitted,
    EditSelectedRow,
    EditCommitted,
    DeleteSelectedRow,
    RowOperationCommitted(Option<UndoBatch>),
    RowOpStarted,
    ExecuteUndo(UndoBatch),
    CellEdited {
        table: String,
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    ReloadConnections,
    ConnectionsLoaded(Vec<SavedConnection>),
    OpenSaved(SavedConnection),
    DeleteConnection(Uuid),
    OpenEditor,
    NewEditorTab,
    CloseActiveEditorTab,
    EditorTabClosed(Uuid),
    EditorTabRunStateChanged(Uuid, bool),
    EditorTabQueryChanged(Uuid, String),
    EditorTabsChanged,
    ShowHistory,
    OpenHistoryQuery(String),
    ReplaceActiveTabQuery(String),
    Disconnect,
    PollHealth,
    RefreshPage,
    ShowShortcuts,
    ShowAbout,
    ShowPreferences,
    SortChanged(usize),
    PageSizeChanged(u64),
    RowCountLoaded(String, u64),
    FindInResults,
    ExportCsv,
    ExportJson,
    CopyToClipboard(String),
    SetCellNull {
        table: String,
        row_position: u32,
        col_index: usize,
    },
    DeleteRowAt {
        table: String,
        row_position: u32,
    },
    CopyRowAsInsert {
        row_position: u32,
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
                // SelectTable; the new-tab semantics land in the App-side
                // multi-tab integration that follows this groundwork.
                SidebarRowOutput::Selected { schema, name } => AppMsg::SelectTable { schema, name },
                SidebarRowOutput::OpenInNewTab { schema, name } => AppMsg::SelectTable { schema, name },
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

        let prev_button = gtk::Button::builder()
            .icon_name("go-previous-symbolic")
            .tooltip_text(crate::tr!("Previous page"))
            .sensitive(false)
            .build();
        let next_button = gtk::Button::builder()
            .icon_name("go-next-symbolic")
            .tooltip_text(crate::tr!("Next page"))
            .sensitive(false)
            .build();
        let paginator_label = gtk::Label::builder().build();
        paginator_label.add_css_class("dim-label");
        paginator_label.set_accessible_role(gtk::AccessibleRole::Status);

        let page_size_labels: Vec<String> = PAGE_SIZE_OPTIONS
            .iter()
            .map(|n| {
                if *n >= 1_000 {
                    format!("{} K", n / 1_000)
                } else {
                    n.to_string()
                }
            })
            .collect();
        let page_size_strs: Vec<&str> = page_size_labels.iter().map(String::as_str).collect();
        let page_size_combo = gtk::DropDown::from_strings(&page_size_strs);
        let default_idx = PAGE_SIZE_OPTIONS
            .iter()
            .position(|n| *n == DEFAULT_PAGE_SIZE)
            .unwrap_or(2) as u32;
        page_size_combo.set_selected(default_idx);
        page_size_combo.set_tooltip_text(Some(&crate::tr!("Rows per page")));
        let sender_for_size = sender.clone();
        page_size_combo.connect_selected_notify(move |dd| {
            let idx = dd.selected() as usize;
            if let Some(&size) = PAGE_SIZE_OPTIONS.get(idx) {
                sender_for_size.input(AppMsg::PageSizeChanged(size));
            }
        });

        let sender_for_prev = sender.clone();
        prev_button.connect_clicked(move |_| sender_for_prev.input(AppMsg::PrevPage));
        let sender_for_next = sender.clone();
        next_button.connect_clicked(move |_| sender_for_next.input(AppMsg::NextPage));

        let insert_button = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text(crate::tr!("Insert row"))
            .sensitive(false)
            .build();
        let edit_row_button = gtk::Button::builder()
            .icon_name("document-edit-symbolic")
            .tooltip_text(crate::tr!("Edit selected row"))
            .sensitive(false)
            .build();
        let delete_button = gtk::Button::builder()
            .icon_name("user-trash-symbolic")
            .tooltip_text(crate::tr!("Delete selected row"))
            .sensitive(false)
            .build();

        let sender_for_insert = sender.clone();
        insert_button.connect_clicked(move |_| sender_for_insert.input(AppMsg::InsertRow));
        let sender_for_edit = sender.clone();
        edit_row_button.connect_clicked(move |_| sender_for_edit.input(AppMsg::EditSelectedRow));
        let sender_for_delete = sender.clone();
        delete_button.connect_clicked(move |_| sender_for_delete.input(AppMsg::DeleteSelectedRow));

        let spacer = gtk::Box::builder().hexpand(true).build();

        let paginator_bar = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .margin_top(8)
            .margin_bottom(8)
            .margin_start(12)
            .margin_end(12)
            .build();
        let export_menu = gio::Menu::new();
        export_menu.append(Some(&crate::tr!("Export as CSV…")), Some("win.export-csv"));
        export_menu.append(Some(&crate::tr!("Export as JSON…")), Some("win.export-json"));
        let export_button = gtk::MenuButton::builder()
            .icon_name("document-save-symbolic")
            .tooltip_text(crate::tr!("Export results"))
            .menu_model(&export_menu)
            .build();
        export_button.add_css_class("flat");

        paginator_bar.append(&prev_button);
        paginator_bar.append(&next_button);
        paginator_bar.append(&paginator_label);
        paginator_bar.append(&spacer);
        paginator_bar.append(&page_size_combo);
        paginator_bar.append(&export_button);
        paginator_bar.append(&insert_button);
        paginator_bar.append(&edit_row_button);
        paginator_bar.append(&delete_button);

        let grid_holder = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .vexpand(true)
            .build();

        let grid_search = gtk::SearchEntry::builder()
            .placeholder_text(crate::tr!("Find in results"))
            .build();
        let grid_search_bar = gtk::SearchBar::builder()
            .child(&grid_search)
            .show_close_button(true)
            .search_mode_enabled(false)
            .build();
        grid_search_bar.connect_entry(&grid_search);

        let browse_view = adw::ToolbarView::new();
        browse_view.add_top_bar(&grid_search_bar);
        browse_view.set_content(Some(&grid_holder));
        browse_view.add_bottom_bar(&paginator_bar);
        grid_search_bar.set_key_capture_widget(Some(&browse_view));

        // Inner Browse stack: starts on `status` ("Select a table"),
        // switches to `grid` once on_rows_loaded populates, or `loading`
        // during fetch. Defined in code (not view!) so set_loading_page /
        // set_status_page can rebuild children dynamically.
        let browse_inner_stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .build();
        browse_inner_stack.add_named(&browse_view, Some("grid"));
        let browse_initial_status = adw::StatusPage::builder()
            .icon_name(StatusKind::Info.icon())
            .title(crate::tr!("Select a table"))
            .description(crate::tr!("Pick a table from the sidebar to load its rows."))
            .build();
        browse_inner_stack.add_named(&browse_initial_status, Some("status"));
        browse_inner_stack.set_visible_child_name("status");

        let view_stack = adw::ViewStack::new();
        let browse_page = view_stack.add_titled_with_icon(
            &browse_inner_stack,
            Some("browse"),
            &crate::tr!("Browse"),
            "view-grid-symbolic",
        );
        let _ = browse_page;

        // ViewSwitcherBar lives inside content_holder (the ToolbarView on
        // the right side of the OverlaySplitView), not on the outer
        // toolbar_view — that way it sits only above the content column,
        // not above the sidebar. Sidebar runs full-height alongside, the
        // multi-pane layout used by Files / Builder / Music.
        //
        // Keeping the WindowTitle in the headerbar's title slot preserves
        // the connection-name subtitle (C3) instead of swapping it out.
        let view_switcher_bar = adw::ViewSwitcherBar::builder().stack(&view_stack).reveal(false).build();
        widgets.content_holder.add_top_bar(&view_switcher_bar);

        let disconnect_action = install_window_actions(&widgets.window, sender.clone());
        install_window_shortcuts(&widgets.window);
        widgets.primary_menu_button.set_menu_model(Some(&primary_menu_model()));

        let (grid_sender, grid_receiver) = relm4::channel::<GridMsg>();
        let grid_input = sender.input_sender().clone();
        relm4::spawn_local(grid_receiver.forward(grid_input, |msg| match msg {
            GridMsg::SortChanged(idx) => AppMsg::SortChanged(idx),
            GridMsg::CellEdited {
                table,
                row_position,
                col_index,
                new_value,
            } => AppMsg::CellEdited {
                table,
                row_position,
                col_index,
                new_value,
            },
            GridMsg::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
            GridMsg::CopyRowAsInsert { row_position } => AppMsg::CopyRowAsInsert { row_position },
            GridMsg::SetCellNull {
                table,
                row_position,
                col_index,
            } => AppMsg::SetCellNull {
                table,
                row_position,
                col_index,
            },
            GridMsg::DeleteRowAt { table, row_position } => AppMsg::DeleteRowAt { table, row_position },
        }));

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
            paginator_label,
            prev_button,
            next_button,
            insert_button,
            edit_row_button,
            delete_button,
            grid_holder,
            grid_search,
            grid_search_bar,
            grid_search_handler: None,
            grid_sender,
            browse_inner_stack,
            view_stack,
            view_switcher_bar,
            editor_page_added: std::cell::Cell::new(false),
            dialog: None,
            editor_root: None,
            editor_tab_view: None,
            editor_tabs: std::rc::Rc::new(std::cell::RefCell::new(std::collections::HashMap::new())),
            schema_buffer: build_schema_buffer(),
            insert_dialog: None,
            edit_dialog: None,
            history_dialog: None,
            welcome_view,
            current_table: None,
            current_schema: None,
            current_offset: 0,
            current_columns: Vec::new(),
            current_result: None,
            current_selection: None,
            current_driver_id: None,
            current_sort: None,
            current_total_rows: None,
            page_size: crate::services::preferences::load().default_page_size,
            table_names: Vec::new(),
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
            AppMsg::SelectTable { schema, name } => self.on_select_table(schema, name, sender),
            AppMsg::ColumnsLoaded(table, columns) => self.on_columns_loaded(table, columns, sender),
            AppMsg::PrevPage => self.on_prev_page(sender),
            AppMsg::NextPage => self.on_next_page(sender),
            AppMsg::RowsLoaded(table, offset, result) => self.on_rows_loaded(table, offset, result),
            AppMsg::LoadFailed(msg) => self.on_load_failed(msg),
            AppMsg::InsertRow => self.on_insert_row(sender),
            AppMsg::InsertCommitted => self.on_insert_committed(sender),
            AppMsg::EditSelectedRow => self.on_edit_selected_row(sender),
            AppMsg::EditCommitted => self.on_edit_committed(sender),
            AppMsg::DeleteSelectedRow => self.on_delete_selected_row(sender),
            AppMsg::RowOperationCommitted(undo) => {
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
                self.fetch_current_page(sender);
            }
            AppMsg::RowOpStarted => self.set_row_op_in_flight(true),
            AppMsg::ExecuteUndo(batch) => {
                self.set_row_op_in_flight(true);
                self.show_toast(&crate::tr!("Undoing…"));
                run_undo_batch(sender, batch);
            }
            AppMsg::CellEdited {
                table,
                row_position,
                col_index,
                new_value,
            } => self.on_cell_edited(table, row_position, col_index, new_value, sender),
            AppMsg::ReloadConnections => self.on_reload_connections(sender),
            AppMsg::ConnectionsLoaded(connections) => {
                let conns = connections;
                self.on_connections_loaded(&conns, sender);
            }
            AppMsg::OpenEditor => self.on_open_editor(sender),
            AppMsg::NewEditorTab => self.append_editor_tab(None, sender),
            AppMsg::CloseActiveEditorTab => self.close_active_editor_tab(sender),
            AppMsg::EditorTabClosed(id) => self.close_editor_tab_by_id(id, sender),
            AppMsg::EditorTabRunStateChanged(id, running) => self.on_editor_tab_run_state_changed(id, running),
            AppMsg::EditorTabQueryChanged(id, text) => self.on_editor_tab_query_changed(id, text),
            AppMsg::EditorTabsChanged => {
                self.push_schema_words();
                self.persist_editor_state();
            }
            AppMsg::ShowHistory => self.on_show_history(sender),
            AppMsg::OpenHistoryQuery(text) => {
                self.on_open_editor(sender.clone());
                self.append_editor_tab(Some(text), sender);
            }
            AppMsg::ReplaceActiveTabQuery(text) => self.on_replace_active_tab_query(text),
            AppMsg::PollHealth => self.on_poll_health(),
            AppMsg::RefreshPage => self.fetch_current_page(sender),
            AppMsg::ShowShortcuts => self.on_show_shortcuts(),
            AppMsg::ShowAbout => self.on_show_about(),
            AppMsg::ShowPreferences => super::preferences::present(&self.window),
            AppMsg::SortChanged(col_idx) => self.on_sort_changed(col_idx, sender),
            AppMsg::PageSizeChanged(size) => self.on_page_size_changed(size, sender),
            AppMsg::RowCountLoaded(table, count) => self.on_row_count_loaded(table, count),
            AppMsg::FindInResults => self.on_find_in_results(),
            AppMsg::ExportCsv => self.on_export(ExportFormat::Csv),
            AppMsg::ExportJson => self.on_export(ExportFormat::Json),
            AppMsg::CopyToClipboard(text) => self.on_copy_to_clipboard(text),
            AppMsg::SetCellNull {
                table,
                row_position,
                col_index,
            } => self.on_set_cell_null(table, row_position, col_index, sender),
            AppMsg::DeleteRowAt { table, row_position } => self.on_delete_row_at(table, row_position, sender),
            AppMsg::CopyRowAsInsert { row_position } => self.on_copy_row_as_insert(row_position),
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

fn selected_positions(selection: &gtk::MultiSelection) -> Vec<u32> {
    let bitset = selection.selection();
    let mut out = Vec::with_capacity(bitset.size() as usize);
    for i in 0..bitset.size() {
        out.push(bitset.nth(i as u32));
    }
    out.sort_unstable();
    out
}

fn execute_many_then_refetch(
    sender: ComponentSender<App>,
    sql: String,
    batches: Vec<Vec<Value>>,
    undo: Option<UndoBatch>,
) {
    let Some(conn) = database_service::instance().active() else {
        sender.input(AppMsg::LoadFailed("no active connection".into()));
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
                            sender_clone.input(AppMsg::LoadFailed(super::error_text::driver_message(&e)));
                            return;
                        }
                    }
                }
                tracing::info!(rows = total, "multi-execute ok");
                sender_clone.input(AppMsg::RowOperationCommitted(undo));
            })
            .drop_on_shutdown()
    });
}

fn execute_then_refetch(sender: ComponentSender<App>, sql: String, params: Vec<Value>, undo: Option<UndoBatch>) {
    let Some(conn) = database_service::instance().active() else {
        sender.input(AppMsg::LoadFailed("no active connection".into()));
        return;
    };
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                match conn.execute_params(&sql, &params).await {
                    Ok(exec) => {
                        tracing::info!(rows = exec.rows_affected, "execute ok");
                        sender_clone.input(AppMsg::RowOperationCommitted(undo));
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "execute failed");
                        sender_clone.input(AppMsg::LoadFailed(super::error_text::driver_message(&e)));
                    }
                }
            })
            .drop_on_shutdown()
    });
}

fn run_undo_batch(sender: ComponentSender<App>, batch: UndoBatch) {
    let Some(conn) = database_service::instance().active() else {
        sender.input(AppMsg::LoadFailed("no active connection".into()));
        return;
    };
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                for (sql, params) in batch.statements.iter() {
                    if let Err(e) = conn.execute_params(sql, params).await {
                        tracing::warn!(error = %e, "undo failed");
                        sender_clone.input(AppMsg::LoadFailed(super::error_text::driver_message(&e)));
                        return;
                    }
                }
                tracing::info!(count = batch.statements.len(), "undo ok");
                sender_clone.input(AppMsg::RowOperationCommitted(None));
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

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

fn qualified_label(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{s}.{table}"),
        None => table.to_string(),
    }
}

fn default_tab_label(n: usize) -> String {
    crate::tr!("Query {n}").replace("{n}", &n.to_string())
}

fn create_editor_tab_slot(
    tab_view: &adw::TabView,
    schema_buffer: &gtk::TextBuffer,
    initial_query: Option<String>,
    label: &str,
    sender: &ComponentSender<App>,
) -> EditorTabSlot {
    let query = initial_query.clone().unwrap_or_default();
    let tab_id = Uuid::new_v4();
    let editor = SqlEditor::builder()
        .launch(SqlEditorInit {
            schema_buffer: schema_buffer.clone(),
            initial_query,
        })
        .forward(sender.input_sender(), move |out| match out {
            SqlEditorOutput::RunStateChanged(running) => AppMsg::EditorTabRunStateChanged(tab_id, running),
            SqlEditorOutput::QueryChanged(text) => AppMsg::EditorTabQueryChanged(tab_id, text),
        });
    let page = tab_view.append(editor.widget());
    page.set_title(label);
    page.set_tooltip(label);
    write_tab_id(&page, tab_id);
    EditorTabSlot {
        id: tab_id,
        controller: editor,
        page,
        query,
    }
}

fn write_tab_id(page: &adw::TabPage, id: Uuid) {
    unsafe {
        page.set_qdata(editor_tab_id_quark(), id);
    }
}

fn read_tab_id(page: &adw::TabPage) -> Option<Uuid> {
    // GObject returns null (None here) for unknown qdata keys, so a foreign
    // TabPage that was never tagged simply yields None.
    unsafe { page.qdata::<Uuid>(editor_tab_id_quark()).map(|p| *p.as_ref()) }
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
        input_action!("open-editor", AppMsg::OpenEditor),
        input_action!("disconnect", AppMsg::Disconnect),
        input_action!("close-current", AppMsg::CloseActiveEditorTab),
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
