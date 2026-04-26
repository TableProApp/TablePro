#![allow(dead_code)]
// Per-tab Browse sub-component. App-side wiring (instantiation, slot
// management, async fetch routing) lands in the follow-up integration;
// this file is the complete view + display-state surface so the
// integration is a pure consumer-side change.

use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::prelude::*;
use relm4::{adw, gtk};
use uuid::Uuid;

use tablepro_core::{ColumnInfo, QueryResult, Value};

use super::grid::{GridMsg, build_column_view};

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;

pub struct BrowseTabInit {
    pub tab_id: Uuid,
    pub schema: Option<String>,
    pub table: String,
    pub driver_id: String,
    pub connection_id: Option<Uuid>,
    pub read_only: bool,
    pub page_size: u64,
    pub initial_offset: u64,
    pub initial_sort: Option<(usize, bool)>,
}

pub struct BrowseTab {
    tab_id: Uuid,
    schema: Option<String>,
    table: String,
    driver_id: String,
    connection_id: Option<Uuid>,
    read_only: bool,

    current_offset: u64,
    page_size: u64,
    current_sort: Option<(usize, bool)>,
    current_columns: Vec<ColumnInfo>,
    current_result: Option<QueryResult>,
    current_selection: Option<gtk::MultiSelection>,
    current_total_rows: Option<u64>,

    inner_stack: gtk::Stack,
    grid_holder: gtk::Box,
    grid_search: gtk::SearchEntry,
    grid_search_bar: gtk::SearchBar,
    grid_search_handler: Option<glib::SignalHandlerId>,
    paginator_label: gtk::Label,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    insert_button: gtk::Button,
    edit_row_button: gtk::Button,
    delete_button: gtk::Button,
    page_size_combo: gtk::DropDown,
    page_size_handler: Rc<RefCell<Option<glib::SignalHandlerId>>>,
    grid_sender: relm4::Sender<GridMsg>,
    /// Set to true on init / refresh; flipped off after first RowsLoaded so
    /// PageSizeChanged emits don't fire while the combo is being driven by
    /// programmatic state restores.
    suppress_combo_emit: Rc<std::cell::Cell<bool>>,
}

#[derive(Debug)]
pub enum BrowseTabInput {
    /// Replace this tab's grid with the given page of rows.
    RowsLoaded {
        offset: u64,
        result: QueryResult,
    },
    /// Schema columns for the current table arrived (governs editability).
    ColumnsLoaded(Vec<ColumnInfo>),
    /// Total row count for paginator label.
    RowCountLoaded(u64),
    /// Show "Loading…" state in the inner stack.
    ShowLoading,
    /// Show an error status page.
    ShowError(String),
    /// Re-issue the fetch for this tab (F5).
    Refresh,
    /// Reveal the in-grid find bar and focus it.
    FindInResults,
    /// Connection-level read-only state changed (rare; for completeness).
    SetReadOnly(bool),
    /// User clicked Prev page.
    PrevPage,
    /// User clicked Next page.
    NextPage,
    /// Sort flipped on column idx (from grid sorter).
    SortChanged(usize),
    /// Page size dropdown changed.
    PageSizeChanged(u64),
    /// User clicked the Insert button on this tab's paginator bar.
    InsertRow,
    /// User clicked the Edit Selected button.
    EditSelectedRow,
    /// User clicked the Delete Selected button.
    DeleteSelectedRow,
    /// Cell-edit / set-null / delete-row / copy-as-insert events from
    /// this tab's grid (forwarded from its own GridMsg channel).
    GridCellEdited {
        table: String,
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    GridSetCellNull {
        table: String,
        row_position: u32,
        col_index: usize,
    },
    GridDeleteRowAt {
        table: String,
        row_position: u32,
    },
    GridCopyRowAsInsert {
        row_position: u32,
    },
    GridCopyToClipboard(String),
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum BrowseTabOutput {
    /// Tab needs the next page of rows fetched (state is in the slot).
    FetchPage,
    /// Tab needs schema columns fetched.
    FetchColumns,
    /// Tab needs the row count fetched.
    FetchRowCount,
    /// Display state changed in a way that should be persisted.
    StateChanged,
    /// User wants to insert a new row.
    OpenInsertDialog {
        columns: Vec<ColumnInfo>,
        table: String,
        driver_id: String,
    },
    /// User wants to edit the currently selected row.
    OpenEditDialog {
        columns: Vec<ColumnInfo>,
        row: Vec<Value>,
        table: String,
        driver_id: String,
    },
    /// User wants to delete one or more selected rows.
    DeleteSelected {
        columns: Vec<ColumnInfo>,
        table: String,
        driver_id: String,
        positions: Vec<u32>,
        rows: Vec<Vec<Value>>,
    },
    /// Cell-edit committed via in-grid editable label.
    CellEdited {
        table: String,
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    /// Cell context-menu "Set to NULL".
    SetCellNull {
        table: String,
        row_position: u32,
        col_index: usize,
    },
    /// Cell context-menu "Delete row".
    DeleteRowAt { table: String, row_position: u32 },
    /// Cell context-menu "Copy row as INSERT".
    CopyRowAsInsert { row_position: u32 },
    /// Generic clipboard-copy request from grid.
    CopyToClipboard(String),
    /// Column-name vocabulary for editor autocomplete; App merges across tabs.
    SchemaWordsChanged(Vec<String>),
    /// Show a generic info dialog for "Cannot edit / select exactly one row".
    ShowSelectionAlert { title: String, body: String },
}

impl BrowseTab {
    pub fn snapshot(&self) -> Option<QueryResult> {
        self.current_result.clone()
    }

    pub fn columns(&self) -> &[ColumnInfo] {
        &self.current_columns
    }

    pub fn table_label(&self) -> String {
        match &self.schema {
            Some(s) => format!("{s}.{}", self.table),
            None => self.table.clone(),
        }
    }

    pub fn schema(&self) -> Option<&str> {
        self.schema.as_deref()
    }

    pub fn table(&self) -> &str {
        &self.table
    }

    pub fn current_offset(&self) -> u64 {
        self.current_offset
    }

    pub fn page_size(&self) -> u64 {
        self.page_size
    }

    pub fn current_sort(&self) -> Option<(usize, bool)> {
        self.current_sort
    }

    pub fn driver_id(&self) -> &str {
        &self.driver_id
    }

    fn build_paginator(
        sender: ComponentSender<Self>,
        page_size: u64,
        page_size_handler_slot: Rc<RefCell<Option<glib::SignalHandlerId>>>,
    ) -> (
        gtk::Box,
        gtk::Button,
        gtk::Button,
        gtk::Label,
        gtk::Button,
        gtk::Button,
        gtk::Button,
        gtk::DropDown,
    ) {
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
        let initial_idx = PAGE_SIZE_OPTIONS
            .iter()
            .position(|n| *n == page_size)
            .unwrap_or_else(|| {
                PAGE_SIZE_OPTIONS
                    .iter()
                    .position(|n| *n == DEFAULT_PAGE_SIZE)
                    .unwrap_or(2)
            }) as u32;
        page_size_combo.set_selected(initial_idx);
        page_size_combo.set_tooltip_text(Some(&crate::tr!("Rows per page")));
        let sender_for_size = sender.clone();
        let id = page_size_combo.connect_selected_notify(move |dd| {
            let idx = dd.selected() as usize;
            if let Some(&size) = PAGE_SIZE_OPTIONS.get(idx) {
                sender_for_size.input(BrowseTabInput::PageSizeChanged(size));
            }
        });
        *page_size_handler_slot.borrow_mut() = Some(id);

        let sender_for_prev = sender.clone();
        prev_button.connect_clicked(move |_| sender_for_prev.input(BrowseTabInput::PrevPage));
        let sender_for_next = sender.clone();
        next_button.connect_clicked(move |_| sender_for_next.input(BrowseTabInput::NextPage));

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
        insert_button.connect_clicked(move |_| sender_for_insert.input(BrowseTabInput::InsertRow));
        let sender_for_edit = sender.clone();
        edit_row_button.connect_clicked(move |_| sender_for_edit.input(BrowseTabInput::EditSelectedRow));
        let sender_for_delete = sender;
        delete_button.connect_clicked(move |_| sender_for_delete.input(BrowseTabInput::DeleteSelectedRow));

        let spacer = gtk::Box::builder().hexpand(true).build();

        let paginator_bar = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .margin_top(8)
            .margin_bottom(8)
            .margin_start(12)
            .margin_end(12)
            .build();
        // Export menu uses win.export-csv / win.export-json (App-level
        // actions); they read the active tab's snapshot so the buttons
        // implicitly target this tab when this tab is active.
        let export_menu = gtk::gio::Menu::new();
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

        (
            paginator_bar,
            prev_button,
            next_button,
            paginator_label,
            insert_button,
            edit_row_button,
            delete_button,
            page_size_combo,
        )
    }

    fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_rows = self.current_result.is_some();
        if self.read_only {
            self.insert_button.set_visible(false);
            self.edit_row_button.set_visible(false);
            self.delete_button.set_visible(false);
            return;
        }
        self.insert_button.set_visible(true);
        self.edit_row_button.set_visible(true);
        self.delete_button.set_visible(true);
        self.insert_button.set_sensitive(has_columns);
        self.edit_row_button.set_sensitive(has_columns && has_rows);
        self.delete_button.set_sensitive(has_columns && has_rows);
    }

    fn update_paginator_label(&self) {
        let Some(result) = self.current_result.as_ref() else {
            self.paginator_label.set_label("");
            return;
        };
        let n_rows = result.rows.len();
        if n_rows == 0 {
            self.paginator_label
                .set_label(&crate::tr!("No rows at offset {n}").replace("{n}", &self.current_offset.to_string()));
            return;
        }
        let start = self.current_offset + 1;
        let end = self.current_offset + n_rows as u64;
        let label = match self.current_total_rows {
            Some(total) => crate::tr!("Rows {start} – {end} of {total}")
                .replace("{start}", &start.to_string())
                .replace("{end}", &end.to_string())
                .replace("{total}", &total.to_string()),
            None => crate::tr!("Rows {start} – {end}")
                .replace("{start}", &start.to_string())
                .replace("{end}", &end.to_string()),
        };
        self.paginator_label.set_label(&label);
    }

    fn replace_status_child(&self, name: &str, child: &impl IsA<gtk::Widget>) {
        if let Some(prev) = self.inner_stack.child_by_name(name) {
            self.inner_stack.remove(&prev);
        }
        self.inner_stack.add_named(child, Some(name));
        self.inner_stack.set_visible_child_name(name);
    }

    fn show_loading_inner(&self, title: &str, description: &str) {
        let spinner = gtk::Spinner::builder()
            .spinning(true)
            .width_request(32)
            .height_request(32)
            .halign(gtk::Align::Center)
            .build();
        let page = adw::StatusPage::builder()
            .title(title)
            .description(description)
            .child(&spinner)
            .build();
        self.replace_status_child("loading", &page);
    }

    fn show_error_inner(&self, message: &str) {
        let page = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Failed"))
            .description(message)
            .build();
        self.replace_status_child("error", &page);
    }
}

impl SimpleComponent for BrowseTab {
    type Init = BrowseTabInit;
    type Input = BrowseTabInput;
    type Output = BrowseTabOutput;
    type Root = adw::ToolbarView;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::ToolbarView::new()
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let suppress_combo_emit = Rc::new(std::cell::Cell::new(true));
        let page_size_handler_slot: Rc<RefCell<Option<glib::SignalHandlerId>>> = Rc::new(RefCell::new(None));

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

        let inner_stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .build();
        inner_stack.add_named(&grid_holder, Some("grid"));
        // Initial state: loading. The first RowsLoaded swaps to "grid".
        let initial_loading = adw::StatusPage::builder()
            .title(crate::tr!("Loading…"))
            .description(crate::tr!("Fetching rows from {table}").replace(
                "{table}",
                &match init.schema.as_deref() {
                    Some(s) => format!("{s}.{}", init.table),
                    None => init.table.clone(),
                },
            ))
            .child(
                &gtk::Spinner::builder()
                    .spinning(true)
                    .width_request(32)
                    .height_request(32)
                    .halign(gtk::Align::Center)
                    .build(),
            )
            .build();
        inner_stack.add_named(&initial_loading, Some("loading"));
        inner_stack.set_visible_child_name("loading");

        let (
            paginator_bar,
            prev_button,
            next_button,
            paginator_label,
            insert_button,
            edit_row_button,
            delete_button,
            page_size_combo,
        ) = Self::build_paginator(sender.clone(), init.page_size, page_size_handler_slot.clone());

        root.add_top_bar(&grid_search_bar);
        root.set_content(Some(&inner_stack));
        root.add_bottom_bar(&paginator_bar);
        grid_search_bar.set_key_capture_widget(Some(&root));

        // Per-tab GridMsg channel: events from this tab's grid (sort
        // change, cell edits, context-menu actions) flow into this tab's
        // own input queue, which then re-emits them as outputs to App
        // tagged with this tab's id (via the forward closure App sets up).
        let (grid_sender, grid_receiver) = relm4::channel::<GridMsg>();
        let grid_input = sender.input_sender().clone();
        relm4::spawn_local(grid_receiver.forward(grid_input, |msg| match msg {
            GridMsg::SortChanged(idx) => BrowseTabInput::SortChanged(idx),
            GridMsg::CellEdited {
                table,
                row_position,
                col_index,
                new_value,
            } => BrowseTabInput::GridCellEdited {
                table,
                row_position,
                col_index,
                new_value,
            },
            GridMsg::CopyToClipboard(text) => BrowseTabInput::GridCopyToClipboard(text),
            GridMsg::CopyRowAsInsert { row_position } => BrowseTabInput::GridCopyRowAsInsert { row_position },
            GridMsg::SetCellNull {
                table,
                row_position,
                col_index,
            } => BrowseTabInput::GridSetCellNull {
                table,
                row_position,
                col_index,
            },
            GridMsg::DeleteRowAt { table, row_position } => BrowseTabInput::GridDeleteRowAt { table, row_position },
        }));

        let model = BrowseTab {
            tab_id: init.tab_id,
            schema: init.schema,
            table: init.table,
            driver_id: init.driver_id,
            connection_id: init.connection_id,
            read_only: init.read_only,
            current_offset: init.initial_offset,
            page_size: init.page_size,
            current_sort: init.initial_sort,
            current_columns: Vec::new(),
            current_result: None,
            current_selection: None,
            current_total_rows: None,
            inner_stack,
            grid_holder,
            grid_search,
            grid_search_bar,
            grid_search_handler: None,
            paginator_label,
            prev_button,
            next_button,
            insert_button,
            edit_row_button,
            delete_button,
            page_size_combo,
            page_size_handler: page_size_handler_slot,
            grid_sender,
            suppress_combo_emit,
        };
        model.refresh_crud_buttons();
        // Trigger the initial fetches the moment the parent attaches us.
        // The parent's forward closure wraps these in AppMsg::… with tab_id.
        let _ = sender.output(BrowseTabOutput::FetchColumns);
        let _ = sender.output(BrowseTabOutput::FetchRowCount);
        let _ = sender.output(BrowseTabOutput::FetchPage);
        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            BrowseTabInput::RowsLoaded { offset, result } => {
                self.current_offset = offset;
                self.current_result = Some(result.clone());

                // Build the column view fresh — this is a hot path in
                // multi-tab because every page change rebuilds.
                clear_box(&self.grid_holder);
                let edit_sender = if self.read_only {
                    None
                } else {
                    Some(self.grid_sender.clone())
                };
                let (column_view, selection, filter_setter) = build_column_view(
                    &result,
                    &self.current_columns,
                    &self.table,
                    edit_sender,
                    self.current_sort,
                    Some(self.grid_sender.clone()),
                    self.connection_id,
                );
                if let Some(prev) = self.grid_search_handler.take() {
                    self.grid_search.disconnect(prev);
                }
                let setter = filter_setter.clone();
                let id = self.grid_search.connect_search_changed(move |entry| {
                    setter(&entry.text());
                });
                self.grid_search_handler = Some(id);
                filter_setter(&self.grid_search.text());
                self.current_selection = Some(selection);
                let scrolled = gtk::ScrolledWindow::builder()
                    .child(&column_view)
                    .hexpand(true)
                    .vexpand(true)
                    .build();
                self.grid_holder.append(&scrolled);
                self.refresh_crud_buttons();
                self.update_paginator_label();
                self.prev_button.set_sensitive(offset > 0);
                let n_rows = result.rows.len() as u64;
                self.next_button.set_sensitive(n_rows == self.page_size);
                self.inner_stack.set_visible_child_name("grid");
                self.suppress_combo_emit.set(false);
                let _ = sender.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::ColumnsLoaded(columns) => {
                let words: Vec<String> = columns.iter().map(|c| c.name.clone()).collect();
                self.current_columns = columns;
                self.refresh_crud_buttons();
                let _ = sender.output(BrowseTabOutput::SchemaWordsChanged(words));
                // If rows arrived before columns we now know the editability
                // map and need to rebuild the view with that knowledge.
                if self.current_result.is_some() {
                    let _ = sender.output(BrowseTabOutput::FetchPage);
                }
            }
            BrowseTabInput::RowCountLoaded(count) => {
                self.current_total_rows = Some(count);
                // If the saved offset is now past the end, clamp it back to
                // the last full page and refetch — guards against stale
                // persistence after rows were deleted in another session.
                if self.current_offset > 0 && count > 0 && self.current_offset >= count {
                    let last_page_offset = count.saturating_sub(1) / self.page_size * self.page_size;
                    if last_page_offset != self.current_offset {
                        self.current_offset = last_page_offset;
                        let _ = sender.output(BrowseTabOutput::FetchPage);
                        let _ = sender.output(BrowseTabOutput::StateChanged);
                    }
                }
                self.update_paginator_label();
            }
            BrowseTabInput::ShowLoading => {
                self.show_loading_inner(
                    &crate::tr!("Loading…"),
                    &crate::tr!("Fetching rows from {table}").replace("{table}", &self.table_label()),
                );
            }
            BrowseTabInput::ShowError(message) => {
                self.show_error_inner(&message);
            }
            BrowseTabInput::Refresh => {
                self.show_loading_inner(
                    &crate::tr!("Loading…"),
                    &crate::tr!("Fetching rows from {table}").replace("{table}", &self.table_label()),
                );
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::FetchRowCount);
            }
            BrowseTabInput::FindInResults => {
                if !self.grid_search_bar.is_search_mode() {
                    self.grid_search_bar.set_search_mode(true);
                }
                self.grid_search.grab_focus();
            }
            BrowseTabInput::SetReadOnly(read_only) => {
                self.read_only = read_only;
                self.refresh_crud_buttons();
                // Force a full grid rebuild so editable labels turn into
                // read-only labels (or vice versa) without waiting for the
                // user to navigate.
                if self.current_result.is_some() {
                    let _ = sender.output(BrowseTabOutput::FetchPage);
                }
            }
            BrowseTabInput::PrevPage => {
                if self.current_offset >= self.page_size {
                    self.current_offset -= self.page_size;
                    let _ = sender.output(BrowseTabOutput::FetchPage);
                    let _ = sender.output(BrowseTabOutput::StateChanged);
                }
            }
            BrowseTabInput::NextPage => {
                self.current_offset += self.page_size;
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::SortChanged(col_idx) => {
                let next = match self.current_sort {
                    Some((c, asc)) if c == col_idx => Some((c, !asc)),
                    _ => Some((col_idx, true)),
                };
                self.current_sort = next;
                self.current_offset = 0;
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::PageSizeChanged(size) => {
                if self.suppress_combo_emit.get() || self.page_size == size {
                    return;
                }
                self.page_size = size;
                self.current_offset = 0;
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::InsertRow => {
                if self.current_columns.is_empty() {
                    return;
                }
                let _ = sender.output(BrowseTabOutput::OpenInsertDialog {
                    columns: self.current_columns.clone(),
                    table: self.table.clone(),
                    driver_id: self.driver_id.clone(),
                });
            }
            BrowseTabInput::EditSelectedRow => {
                let Some(selection) = self.current_selection.as_ref() else {
                    return;
                };
                let Some(result) = self.current_result.as_ref() else {
                    return;
                };
                let positions = selected_positions(selection);
                if positions.len() != 1 {
                    let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                        title: crate::tr!("Cannot edit"),
                        body: crate::tr!("Select exactly one row to edit."),
                    });
                    return;
                }
                let position = positions[0] as usize;
                if position >= result.rows.len() {
                    return;
                }
                let row = result.rows[position].clone();
                let _ = sender.output(BrowseTabOutput::OpenEditDialog {
                    columns: self.current_columns.clone(),
                    row,
                    table: self.table.clone(),
                    driver_id: self.driver_id.clone(),
                });
            }
            BrowseTabInput::DeleteSelectedRow => {
                let Some(selection) = self.current_selection.as_ref() else {
                    return;
                };
                let Some(result) = self.current_result.as_ref() else {
                    return;
                };
                let positions = selected_positions(selection);
                if positions.is_empty() {
                    return;
                }
                let _ = sender.output(BrowseTabOutput::DeleteSelected {
                    columns: self.current_columns.clone(),
                    table: self.table.clone(),
                    driver_id: self.driver_id.clone(),
                    positions,
                    rows: result.rows.clone(),
                });
            }
            BrowseTabInput::GridCellEdited {
                table,
                row_position,
                col_index,
                new_value,
            } => {
                let _ = sender.output(BrowseTabOutput::CellEdited {
                    table,
                    row_position,
                    col_index,
                    new_value,
                });
            }
            BrowseTabInput::GridSetCellNull {
                table,
                row_position,
                col_index,
            } => {
                let _ = sender.output(BrowseTabOutput::SetCellNull {
                    table,
                    row_position,
                    col_index,
                });
            }
            BrowseTabInput::GridDeleteRowAt { table, row_position } => {
                let _ = sender.output(BrowseTabOutput::DeleteRowAt { table, row_position });
            }
            BrowseTabInput::GridCopyRowAsInsert { row_position } => {
                let _ = sender.output(BrowseTabOutput::CopyRowAsInsert { row_position });
            }
            BrowseTabInput::GridCopyToClipboard(text) => {
                let _ = sender.output(BrowseTabOutput::CopyToClipboard(text));
            }
        }
        // Quark prevents accidental cross-page lookups; tab_id used by App
        // to route inputs back here.
        let _ = self.tab_id;
    }
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
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
