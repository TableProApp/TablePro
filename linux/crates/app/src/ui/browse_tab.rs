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

use super::grid::{GridMsg, TabGridContext, build_column_view};

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
    delete_button: gtk::Button,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    pending_label: gtk::Label,
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
    /// User clicked Save — materialize tracker pending changes and
    /// emit them as a single `BrowseTabOutput::ExecuteTransaction`
    /// for atomic commit.
    CommitSave,
    /// User clicked Discard — clear all pending edits and refetch
    /// the page so the grid shows committed values again.
    DiscardAll,
    /// Pending count changed (from tracker subscription) — refresh
    /// the Save / Discard / counter visibility.
    PendingCountChanged(usize),
    /// Save command resolved successfully — clear tracker, refetch.
    SaveCompleted,
    /// Save command failed — surface error to the user; keep the
    /// pending changeset intact so they can retry.
    SaveFailed(String),
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
    /// Cell context-menu "Copy row as INSERT".
    CopyRowAsInsert { row_position: u32 },
    /// Generic clipboard-copy request from grid.
    CopyToClipboard(String),
    /// Column-name vocabulary for editor autocomplete; App merges across tabs.
    SchemaWordsChanged(Vec<String>),
    /// Show a generic info dialog for "Cannot edit / select exactly one row".
    ShowSelectionAlert { title: String, body: String },
    /// Run a sequence of pending-changeset statements inside a single
    /// DB transaction. Materialised by the per-tab change tracker on
    /// Save click. App routes this to `Connection::execute_in_transaction`
    /// and dispatches `SaveCompleted` / `SaveFailed` back via input.
    ExecuteTransaction { statements: Vec<(String, Vec<Value>)> },
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

    /// Build the navigation toolbar — Prev / Next / page label / page
    /// size dropdown / Export. Mutation actions (Insert / Edit /
    /// Delete) live in a separate `gtk::ActionBar` (see
    /// `build_mutation_bar`) so destructive controls aren't sitting
    /// next to navigation arrows in misclick range.
    fn build_paginator(
        sender: ComponentSender<Self>,
        page_size: u64,
        page_size_handler_slot: Rc<RefCell<Option<glib::SignalHandlerId>>>,
    ) -> Paginator {
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

        // Use thousands-separated labels (100 / 500 / 1,000 / 5,000 /
        // 10,000) instead of "1 K" abbreviations. With a visible
        // "Rows:" label inline (below) the dropdown's purpose is
        // obvious without needing a tooltip, matching how Evince
        // labels its zoom dropdown.
        let page_size_labels: Vec<String> = PAGE_SIZE_OPTIONS.iter().map(|n| format_thousands(*n)).collect();
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
        let sender_for_size = sender.clone();
        let id = page_size_combo.connect_selected_notify(move |dd| {
            let idx = dd.selected() as usize;
            if let Some(&size) = PAGE_SIZE_OPTIONS.get(idx) {
                sender_for_size.input(BrowseTabInput::PageSizeChanged(size));
            }
        });
        *page_size_handler_slot.borrow_mut() = Some(id);
        let page_size_label = gtk::Label::builder().label(crate::tr!("Rows:")).build();
        page_size_label.add_css_class("dim-label");

        let sender_for_prev = sender.clone();
        prev_button.connect_clicked(move |_| sender_for_prev.input(BrowseTabInput::PrevPage));
        let sender_for_next = sender;
        next_button.connect_clicked(move |_| sender_for_next.input(BrowseTabInput::NextPage));

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
        paginator_bar.append(&page_size_label);
        paginator_bar.append(&page_size_combo);
        paginator_bar.append(&export_button);

        Paginator {
            bar: paginator_bar,
            prev_button,
            next_button,
            paginator_label,
            page_size_combo,
        }
    }

    /// Mutation actions in their own `gtk::ActionBar` (the Adwaita
    /// widget for selection-dependent toolbars). Visually separated
    /// from the paginator so a misclick on Next never lands on Delete.
    fn build_mutation_bar(sender: ComponentSender<Self>) -> Mutations {
        let insert_button = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text(crate::tr!("Insert row"))
            .sensitive(false)
            .build();
        let delete_button = gtk::Button::builder()
            .icon_name("user-trash-symbolic")
            .tooltip_text(crate::tr!("Delete selected row"))
            .sensitive(false)
            .build();
        delete_button.add_css_class("destructive-action");
        let sender_for_insert = sender.clone();
        insert_button.connect_clicked(move |_| sender_for_insert.input(BrowseTabInput::InsertRow));
        let sender_for_delete = sender.clone();
        delete_button.connect_clicked(move |_| sender_for_delete.input(BrowseTabInput::DeleteSelectedRow));

        // Pending-changeset cluster on pack_end: count label, Discard,
        // Save. Hidden until any pending change exists. Subscribes
        // are wired in `init`; this builder just lays them out.
        let pending_label = gtk::Label::builder().visible(false).build();
        pending_label.add_css_class("dim-label");
        pending_label.add_css_class("caption");

        let discard_button = gtk::Button::builder()
            .label(crate::tr!("Discard"))
            .visible(false)
            .build();
        let sender_for_discard = sender.clone();
        discard_button.connect_clicked(move |_| sender_for_discard.input(BrowseTabInput::DiscardAll));

        let save_button = gtk::Button::builder().label(crate::tr!("Save")).visible(false).build();
        save_button.add_css_class("suggested-action");
        let sender_for_save = sender;
        save_button.connect_clicked(move |_| sender_for_save.input(BrowseTabInput::CommitSave));

        let bar = gtk::ActionBar::new();
        bar.pack_start(&insert_button);
        bar.pack_start(&delete_button);
        bar.pack_end(&save_button);
        bar.pack_end(&discard_button);
        bar.pack_end(&pending_label);
        Mutations {
            bar,
            insert_button,
            delete_button,
            save_button,
            discard_button,
            pending_label,
        }
    }

    /// Toggle visibility / label of the pending-changeset cluster
    /// in the mutation bar. Hidden when there are no pending edits;
    /// shows "{n} unsaved" with Save (.suggested-action) + Discard
    /// when there are. Mirrors GNOME Files' per-folder operation
    /// strip pattern.
    fn refresh_pending_bar(&self, count: usize) {
        let visible = count > 0;
        self.save_button.set_visible(visible);
        self.discard_button.set_visible(visible);
        self.pending_label.set_visible(visible);
        if visible {
            self.pending_label
                .set_label(&crate::tr!("{n} unsaved").replace("{n}", &count.to_string()));
        }
    }

    /// Walk the selection → FilterListModel → ListStore chain to
    /// expose the underlying store for direct mutation (used by the
    /// inline-Insert path to prepend a draft row).
    fn list_store(&self) -> Option<gtk::gio::ListStore> {
        let selection = self.current_selection.as_ref()?;
        let filter_model = selection.model()?.downcast::<gtk::FilterListModel>().ok()?;
        filter_model.model()?.downcast::<gtk::gio::ListStore>().ok()
    }

    /// Look up the live `RowObject` at a filter-model position. Used
    /// to detect whether a row is a draft (`draft_id().is_some()`)
    /// vs a persisted row, and to mutate draft cells in place when
    /// the user types into them.
    fn row_object_at(&self, position: u32) -> Option<super::row_object::RowObject> {
        let model = self.current_selection.as_ref()?.model()?;
        model.item(position)?.downcast::<super::row_object::RowObject>().ok()
    }

    /// Build the (RowKey, current_values) pair for a row at the
    /// given position in the current result. Returns None if the
    /// table has no PK or the position is out of range.
    fn row_key_at(&self, row_position: u32) -> Option<(crate::services::change_tracker::RowKey, Vec<Value>)> {
        let result = self.current_result.as_ref()?;
        let row = result.rows.get(row_position as usize)?;
        let pk_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        if pk_indices.is_empty() {
            return None;
        }
        let pk_values: Vec<Value> = pk_indices.iter().map(|&i| row[i].clone()).collect();
        let key = crate::services::change_tracker::RowKey::from_pk_values(&pk_values)?;
        Some((key, row.clone()))
    }

    fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_rows = self.current_result.is_some();
        if self.read_only {
            self.insert_button.set_visible(false);
            self.delete_button.set_visible(false);
            return;
        }
        self.insert_button.set_visible(true);
        self.delete_button.set_visible(true);
        self.insert_button.set_sensitive(has_columns);
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
        // Open this tab's pending-changeset tracker. Closed in
        // workspace_tabs::close_workspace_tab_by_id when the tab is
        // removed. Idempotent — calling twice is a no-op.
        crate::services::change_tracker::open_tab(init.tab_id);

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

        let paginator = Self::build_paginator(sender.clone(), init.page_size, page_size_handler_slot.clone());
        let mutations = Self::build_mutation_bar(sender.clone());

        root.add_top_bar(&grid_search_bar);
        root.set_content(Some(&inner_stack));
        // Mutations bar sits below the paginator (call order = stack
        // order in AdwToolbarView's add_bottom_bar) so the visual
        // hierarchy is: grid → paginator → mutations.
        root.add_bottom_bar(&paginator.bar);
        root.add_bottom_bar(&mutations.bar);
        grid_search_bar.set_key_capture_widget(Some(&root));

        // SearchBar's built-in Escape handler only fires while the
        // SearchEntry (or its close button) has focus. If the user opens
        // search and then clicks the page-size dropdown or any paginator
        // control, Esc lands outside the bar's reach. A Local-scope
        // shortcut on root catches Escape anywhere in this tab and
        // dismisses the bar — matching the GNOME Files / Text Editor
        // behaviour where Esc reliably closes search regardless of focus.
        let search_bar_for_esc = grid_search_bar.clone();
        let esc_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Escape").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                if search_bar_for_esc.is_search_mode() {
                    search_bar_for_esc.set_search_mode(false);
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            }))
            .build();
        let esc_controller = gtk::ShortcutController::new();
        esc_controller.set_scope(gtk::ShortcutScope::Local);
        esc_controller.add_shortcut(esc_shortcut);
        root.add_controller(esc_controller);

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
            paginator_label: paginator.paginator_label,
            prev_button: paginator.prev_button,
            next_button: paginator.next_button,
            insert_button: mutations.insert_button,
            delete_button: mutations.delete_button,
            save_button: mutations.save_button,
            discard_button: mutations.discard_button,
            pending_label: mutations.pending_label,
            page_size_combo: paginator.page_size_combo,
            page_size_handler: page_size_handler_slot,
            grid_sender,
            suppress_combo_emit,
        };
        model.refresh_crud_buttons();
        model.refresh_pending_bar(0);

        // Subscribe to the tracker so we can refresh the pending UI
        // any time the user adds / undoes / commits a change. The
        // channel is leaked into the GTK main loop via spawn_local,
        // matching how the per-tab GridMsg channel above is wired.
        let (tracker_sender, tracker_receiver) = relm4::channel::<crate::services::change_tracker::TrackerEvent>();
        crate::services::change_tracker::with_tab(init.tab_id, |t| t.subscribe(tracker_sender));
        let input_for_tracker = sender.input_sender().clone();
        let tab_id_for_tracker = init.tab_id;
        relm4::spawn_local(tracker_receiver.forward(input_for_tracker, move |event| match event {
            crate::services::change_tracker::TrackerEvent::PendingCountChanged(n) => {
                BrowseTabInput::PendingCountChanged(n)
            }
            crate::services::change_tracker::TrackerEvent::Cleared => BrowseTabInput::PendingCountChanged(0),
            // ChangedRows would drive items_changed for visual refresh —
            // wired in the next iteration when grid CSS overlay lands.
            crate::services::change_tracker::TrackerEvent::ChangedRows(_) => BrowseTabInput::PendingCountChanged(
                crate::services::change_tracker::with_tab_ref(tab_id_for_tracker, |t| t.pending_count()).unwrap_or(0),
            ),
        }));
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
                let pk_col_indices: Vec<usize> = self
                    .current_columns
                    .iter()
                    .enumerate()
                    .filter(|(_, c)| c.primary_key)
                    .map(|(i, _)| i)
                    .collect();
                let tab_ctx = TabGridContext {
                    tab_id: Some(self.tab_id),
                    pk_col_indices,
                };
                let (column_view, selection, filter_setter) = build_column_view(
                    &result,
                    &self.current_columns,
                    &self.table,
                    edit_sender,
                    self.current_sort,
                    Some(self.grid_sender.clone()),
                    self.connection_id,
                    tab_ctx,
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
                // Inline draft: track in the changeset (returns a
                // RowKey::Draft(N) handle), then prepend a fresh
                // RowObject tagged with the same draft id to the
                // grid's ListStore. The new row appears at the top
                // with a green tint and editable cells; user fills
                // them inline and clicks Save to commit.
                let default_values: Vec<Value> = self.current_columns.iter().map(|_| Value::Null).collect();
                let key_opt =
                    crate::services::change_tracker::with_tab(self.tab_id, |t| t.track_insert(default_values.clone()));
                let Some(key) = key_opt else {
                    return;
                };
                let crate::services::change_tracker::RowKey::Draft(draft_id) = key else {
                    return;
                };
                if let Some(store) = self.list_store() {
                    let draft_row = super::row_object::RowObject::new_draft(draft_id, default_values);
                    store.insert(0, &draft_row);
                }
            }
            BrowseTabInput::DeleteSelectedRow => {
                // Toolbar Delete now marks the selected rows for
                // pending deletion (red strikethrough via tracker
                // overlay). User reviews + clicks Save to commit, or
                // Discard / Ctrl+Z to revert. Replaces the previous
                // confirm-dialog-then-immediate-DELETE flow.
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
                let pk_indices: Vec<usize> = self
                    .current_columns
                    .iter()
                    .enumerate()
                    .filter(|(_, c)| c.primary_key)
                    .map(|(i, _)| i)
                    .collect();
                if pk_indices.is_empty() {
                    let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                        title: crate::tr!("Cannot delete"),
                        body: crate::tr!("This table has no primary key — editing is disabled."),
                    });
                    return;
                }
                let tab_id = self.tab_id;
                crate::services::change_tracker::with_tab(tab_id, |t| {
                    for pos in &positions {
                        let Some(row) = result.rows.get(*pos as usize) else {
                            continue;
                        };
                        let pk_values: Vec<Value> = pk_indices.iter().map(|&i| row[i].clone()).collect();
                        if let Some(key) = crate::services::change_tracker::RowKey::from_pk_values(&pk_values) {
                            t.track_delete(key, row.clone());
                        }
                    }
                });
            }
            BrowseTabInput::GridCellEdited {
                table: _,
                row_position,
                col_index,
                new_value,
            } => {
                // Cell edits no longer commit immediately to the
                // database. Route through the per-tab change tracker
                // so the user can review / Save / Discard a batch.
                let new = if new_value.is_empty() {
                    Value::Text(String::new())
                } else {
                    Value::Text(new_value)
                };
                let row_obj = self.row_object_at(row_position);
                if let Some(row_obj) = &row_obj
                    && let Some(draft_id) = row_obj.draft_id()
                {
                    // Draft row — mutate the tracker's draft buffer
                    // directly. The RowObject's own cells are also
                    // updated so the grid's display reflects the
                    // pending value without waiting for re-fetch.
                    crate::services::change_tracker::with_tab(self.tab_id, |t| {
                        t.track_draft_cell_edit(draft_id, col_index, new.clone());
                    });
                    row_obj.set_cell(col_index, new);
                    return;
                }
                let Some((key, row)) = self.row_key_at(row_position) else {
                    return;
                };
                let original = row[col_index].clone();
                crate::services::change_tracker::with_tab(self.tab_id, |t| {
                    t.track_cell_edit(key, col_index, original, new);
                });
            }
            BrowseTabInput::GridSetCellNull {
                table: _,
                row_position,
                col_index,
            } => {
                let Some((key, row)) = self.row_key_at(row_position) else {
                    return;
                };
                let original = row[col_index].clone();
                crate::services::change_tracker::with_tab(self.tab_id, |t| {
                    t.track_cell_edit(key, col_index, original, Value::Null);
                });
            }
            BrowseTabInput::GridDeleteRowAt { table: _, row_position } => {
                let Some((key, row)) = self.row_key_at(row_position) else {
                    return;
                };
                crate::services::change_tracker::with_tab(self.tab_id, |t| {
                    t.track_delete(key, row);
                });
            }
            BrowseTabInput::GridCopyRowAsInsert { row_position } => {
                let _ = sender.output(BrowseTabOutput::CopyRowAsInsert { row_position });
            }
            BrowseTabInput::GridCopyToClipboard(text) => {
                let _ = sender.output(BrowseTabOutput::CopyToClipboard(text));
            }
            BrowseTabInput::CommitSave => {
                let columns = self.current_columns.clone();
                let driver_id = self.driver_id.clone();
                let schema = self.schema.clone();
                let table = self.table.clone();
                let result = crate::services::change_tracker::with_tab_ref(self.tab_id, |t| {
                    t.materialize(&driver_id, schema.as_deref(), &table, &columns)
                });
                match result {
                    Some(Ok(statements)) if !statements.is_empty() => {
                        let _ = sender.output(BrowseTabOutput::ExecuteTransaction { statements });
                    }
                    Some(Ok(_)) => {
                        // Nothing to save (tracker empty) — refresh bar.
                        self.refresh_pending_bar(0);
                    }
                    Some(Err(e)) => {
                        let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                            title: crate::tr!("Cannot save"),
                            body: format!("{e}"),
                        });
                    }
                    None => {}
                }
            }
            BrowseTabInput::DiscardAll => {
                crate::services::change_tracker::with_tab(self.tab_id, |t| t.clear());
                let _ = sender.output(BrowseTabOutput::FetchPage);
            }
            BrowseTabInput::PendingCountChanged(n) => {
                self.refresh_pending_bar(n);
                // Force the visible cells to re-bind so CSS classes
                // for pending state reflect the latest tracker view.
                // Cheap: GTK's ColumnView only re-binds the visible
                // viewport, not every row in the store.
                if let Some(selection) = self.current_selection.as_ref()
                    && let Some(model) = selection.model()
                {
                    let n_items = model.n_items();
                    if n_items > 0 {
                        // items_changed(0, n, n) re-emits "removed and
                        // re-added" for every item — forces re-bind
                        // without altering selection or scroll.
                        if let Some(filter_model) = model.downcast_ref::<gtk::FilterListModel>() {
                            filter_model.items_changed(0, n_items, n_items);
                        }
                    }
                }
            }
            BrowseTabInput::SaveCompleted => {
                crate::services::change_tracker::with_tab(self.tab_id, |t| t.clear());
                self.refresh_pending_bar(0);
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::FetchRowCount);
            }
            BrowseTabInput::SaveFailed(message) => {
                let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::tr!("Save failed"),
                    body: message,
                });
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

/// Format a positive integer with thousands separators (1000 → 1,000).
/// Used for page-size dropdown labels so they read naturally instead
/// of the abbreviated "1 K" / "5 K" form.
fn format_thousands(n: u64) -> String {
    let s = n.to_string();
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut out = String::with_capacity(len + len / 3);
    for (i, b) in bytes.iter().enumerate() {
        if i > 0 && (len - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(*b as char);
    }
    out
}

/// Bundle of widgets returned by `build_paginator` so the builder
/// signature stays narrow.
struct Paginator {
    bar: gtk::Box,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    paginator_label: gtk::Label,
    page_size_combo: gtk::DropDown,
}

/// Bundle of widgets returned by `build_mutation_bar`.
struct Mutations {
    bar: gtk::ActionBar,
    insert_button: gtk::Button,
    delete_button: gtk::Button,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    pending_label: gtk::Label,
}

#[cfg(test)]
mod tests {
    use super::format_thousands;

    #[test]
    fn format_thousands_handles_common_page_sizes() {
        assert_eq!(format_thousands(100), "100");
        assert_eq!(format_thousands(500), "500");
        assert_eq!(format_thousands(1_000), "1,000");
        assert_eq!(format_thousands(5_000), "5,000");
        assert_eq!(format_thousands(10_000), "10,000");
        assert_eq!(format_thousands(1_000_000), "1,000,000");
    }

    #[test]
    fn format_thousands_handles_edges() {
        assert_eq!(format_thousands(0), "0");
        assert_eq!(format_thousands(1), "1");
        assert_eq!(format_thousands(999), "999");
    }
}
