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
/// Bulk-delete safety net: when the user marks at least this many
/// rows pending-delete in one shot, surface a confirmation dialog
/// before tracking. The marker is reversible via Discard / Ctrl+Z,
/// but a 200-row Ctrl+A → Delete sequence is destructive enough at
/// a glance that an explicit confirmation matches GNOME Files'
/// "Delete N items?" pattern.
const BULK_DELETE_CONFIRM_THRESHOLD: usize = 10;

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
    /// Live reference to the current page's `gtk::ColumnView`. Replaced
    /// on every `RowsLoaded`. Used by the inline-Insert flow to
    /// scroll-to-and-focus the freshly-prepended draft row.
    current_column_view: Option<gtk::ColumnView>,
    /// Column count at the time `current_column_view` was last built.
    /// `render_grid_if_ready` compares this to `current_columns.len()`
    /// to decide whether the cached view can be reused or needs a
    /// full rebuild. Within a single tab the count never changes
    /// after the first ColumnsLoaded; mismatch implies cold-path.
    rendered_column_count: std::cell::Cell<usize>,
    /// Persistent-state banners (per HIG: banners for state, toasts
    /// for events). Pending-changes is communicated through the
    /// ActionBar footer + tab-title bullet, not a banner — the banner
    /// is reserved for constraint states (read-only, no-PK) the user
    /// can't dismiss by saving.
    read_only_banner: adw::Banner,
    no_pk_banner: adw::Banner,
    /// Last-emitted dirty state. PendingCountChanged fires on every
    /// tracker mutation including count-only changes (2 → 3) where the
    /// dirty flag hasn't actually flipped. Tracking the previous flag
    /// here lets us emit `BrowseTabOutput::DirtyChanged` only on real
    /// transitions and avoid redundant tab-title rewrites in App.
    was_dirty: std::cell::Cell<bool>,
    /// Row identity captured before a sort/save/refresh-driven reload
    /// so the focused row can be re-selected and re-scrolled into view
    /// once the new page lands. Persisted rows match by PK; drafts
    /// match by draft_id (for the rare case where a draft is focused
    /// when a sort happens). Cleared by `restore_focused_row`.
    pending_focus_restore: std::cell::RefCell<Option<crate::services::change_tracker::RowKey>>,
    grid_search: gtk::SearchEntry,
    grid_search_bar: gtk::SearchBar,
    grid_search_handler: Option<glib::SignalHandlerId>,
    paginator_label: gtk::Label,
    /// Live count of selected rows. Hidden when 0 or 1 rows are
    /// selected; shows "{n} selected" once the user shift-clicks
    /// or Ctrl+clicks to build a multi-row selection. Updated via
    /// the selection model's connect_selection_changed signal so it
    /// stays in sync without polling.
    selection_label: gtk::Label,
    first_button: gtk::Button,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    last_button: gtk::Button,
    insert_button: gtk::Button,
    delete_button: gtk::Button,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    pending_label: gtk::Label,
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
    /// Show an error status page.
    ShowError(String),
    /// Re-issue the fetch for this tab (F5).
    Refresh,
    /// Reveal the in-grid find bar and focus it.
    FindInResults,
    /// Restore focus to the column view. Fired after the search bar
    /// is closed via Escape so the next keystroke lands on the grid
    /// (F2 to edit, Tab to traverse, etc.) instead of the floating
    /// post-search focus state.
    FocusGrid,
    /// Clear a multi-row selection (Esc when 2+ rows are selected
    /// and no search bar / cell editor is active). Single-row
    /// selections are intentionally preserved — unselecting the
    /// only-row would strand the keyboard focus indicator.
    ClearSelection,
    /// User clicked First page (offset → 0).
    FirstPage,
    /// User clicked Prev page.
    PrevPage,
    /// User clicked Next page.
    NextPage,
    /// User clicked Last page (offset → last full page based on
    /// row count). No-op if the row count isn't known yet.
    LastPage,
    /// Sort flipped on column idx (from grid sorter).
    SortChanged {
        col_idx: usize,
        ascending: bool,
    },
    /// Page size dropdown changed.
    PageSizeChanged(u64),
    /// User clicked the Insert button on this tab's paginator bar.
    InsertRow,
    /// Self-dispatched after `InsertRow` to grab focus on the newly-
    /// inserted draft row's first editable cell. Sent through the
    /// input queue so the handler reads `self.current_column_view`
    /// fresh rather than capturing a potentially-stale reference into
    /// an `idle_add_local_once` closure.
    FocusInsertedDraft,
    /// User clicked the Delete Selected button.
    DeleteSelectedRow,
    /// Cell-edit / set-null / delete-row / copy-as-insert events from
    /// this tab's grid (forwarded from its own GridMsg channel). The
    /// table is implicit — each tab's grid only ever fires for its
    /// own table.
    GridCellEdited {
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    GridSetCellNull {
        row_position: u32,
        col_index: usize,
    },
    GridDeleteRowAt {
        row_position: u32,
    },
    GridCopyRowAsInsert {
        row_position: u32,
    },
    /// Cell context-menu "Duplicate row" — clone the cell values
    /// from `row_position` into a fresh draft row prepended to the
    /// grid. PK / generated / auto-increment columns are blanked so
    /// the duplicate doesn't inherit the source's identity.
    DuplicateRow {
        row_position: u32,
    },
    GridCopyToClipboard(String),
    /// Ctrl+Z on this tab. Pops one entry off the change tracker's
    /// undo stack AND mirrors the visual revert in the grid:
    /// CellEdit → reset the RowObject's cell + items_changed;
    /// Insert → remove the draft RowObject from the ListStore;
    /// Delete → re-bind the row so the strikethrough overlay drops.
    /// Without the mirror the chrome (counter, .tp-cell-modified
    /// class) updated correctly while the cell text stayed at the
    /// post-edit value.
    Undo,
    /// Ctrl+Shift+Z. Symmetric to Undo: re-applies the popped op
    /// and mirrors the visual change forward.
    Redo,
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
    /// Specific rows mutated in the tracker (cell edit, set NULL,
    /// insert, delete, undo, redo). Triggers a targeted re-bind of
    /// just those rows so pending-state CSS classes update without
    /// re-binding the entire visible viewport.
    ChangedRows(Vec<crate::services::change_tracker::RowKey>),
    /// Save command resolved successfully — clear tracker, refetch.
    SaveCompleted,
    /// Save command failed — surface error to the user; keep the
    /// pending changeset intact so they can retry.
    SaveFailed(String),
    /// App-side mapping resolved a `DriverError::Transaction`'s
    /// statement_index to a `StatementSource`. Find the matching row
    /// in the current grid (by draft_id for inserts, PK for updates
    /// and deletes) and scroll-and-select it. Best-effort: if the row
    /// isn't on the current page (paginated past it, sorted away),
    /// the alert dialog still tells the user which statement failed.
    FlashErrorRow(crate::services::change_tracker::StatementSource),
    /// Ctrl+C with row(s) selected: serialize each selected row as
    /// tab-separated cells and push to the system clipboard. Falls
    /// through to GTK's default Ctrl+C if no rows are selected so
    /// inline cell-text selection still copies the highlighted text.
    CopySelectedRowsAsTsv,
    /// Ctrl+V on the grid (focus not in a cell editor): show a toast
    /// telling the user multi-row paste isn't supported. Cell-level
    /// paste continues to work via the normal text-editor path.
    PasteNotSupported,
    /// Ctrl+A: select every visible row.
    SelectAllRows,
    /// Home / End: scroll-and-focus the first / last row of the
    /// current page. Cell-level Home/End within a row would conflict
    /// with the cell editor's text-edit behaviour, so we scope
    /// these to row navigation only — matches how GtkColumnView
    /// users expect Home/End to behave in a list context.
    GoToFirstRow,
    GoToLastRow,
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
    /// Show a transient toast — used for inline cell-input validation
    /// errors ("Invalid date format" etc.) where a modal alert is too
    /// heavy for the user's intent.
    ShowToast(String),
    /// Pending-changeset count crossed the empty / non-empty boundary.
    /// `true` = at least one pending edit; the App-side handler
    /// prefixes the tab title with the GNOME-Text-Editor "•" dot.
    DirtyChanged(bool),
    /// Run a sequence of pending-changeset statements inside a single
    /// DB transaction. Materialised by the per-tab change tracker on
    /// Save click. App routes this to `Connection::execute_in_transaction`
    /// and dispatches `SaveCompleted` / `SaveFailed` back via input.
    /// `sources[i]` identifies the row that produced `statements[i]`,
    /// so a `DriverError::Transaction { statement_index, .. }` can be
    /// mapped back to the offending grid row for scroll-and-select.
    ExecuteTransaction {
        statements: Vec<(String, Vec<Value>)>,
        sources: Vec<crate::services::change_tracker::StatementSource>,
    },
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
    fn build_paginator(sender: ComponentSender<Self>, page_size: u64) -> Paginator {
        // First / Last bracket the Prev / Next pair. Tables of
        // millions of rows make Last especially valuable — without
        // it the user has to spam Next to reach the bottom. Same
        // visual + interaction model as TablePlus / DataGrip /
        // DBeaver. Last stays disabled until the row count loads.
        let first_button = gtk::Button::builder()
            .icon_name("go-first-symbolic")
            .tooltip_text(crate::tr!("First page"))
            .sensitive(false)
            .build();
        let prev_button = gtk::Button::builder()
            .icon_name("go-previous-symbolic")
            .tooltip_text(crate::tr!("Previous page (Page Up)"))
            .sensitive(false)
            .build();
        let next_button = gtk::Button::builder()
            .icon_name("go-next-symbolic")
            .tooltip_text(crate::tr!("Next page (Page Down)"))
            .sensitive(false)
            .build();
        let last_button = gtk::Button::builder()
            .icon_name("go-last-symbolic")
            .tooltip_text(crate::tr!("Last page"))
            .sensitive(false)
            .build();
        let paginator_label = gtk::Label::builder().build();
        paginator_label.add_css_class("dim-label");
        paginator_label.set_accessible_role(gtk::AccessibleRole::Status);

        // Selection count badge — sits beside the paginator label.
        // Hidden when 0–1 rows selected; appears when the user
        // shift-clicks a range or ctrl-clicks to multi-select.
        // `accent` class draws the user's eye to it; AccessibleRole
        // Status is the same role we use for the paginator label so
        // a screen reader announces both as live regions.
        let selection_label = gtk::Label::builder().visible(false).build();
        selection_label.add_css_class("accent");
        selection_label.add_css_class("caption-heading");
        selection_label.set_accessible_role(gtk::AccessibleRole::Status);
        selection_label.set_margin_start(12);

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
        page_size_combo.connect_selected_notify(move |dd| {
            let idx = dd.selected() as usize;
            if let Some(&size) = PAGE_SIZE_OPTIONS.get(idx) {
                sender_for_size.input(BrowseTabInput::PageSizeChanged(size));
            }
        });
        let page_size_label = gtk::Label::builder().label(crate::tr!("Rows:")).build();
        page_size_label.add_css_class("dim-label");

        let sender_for_first = sender.clone();
        first_button.connect_clicked(move |_| sender_for_first.input(BrowseTabInput::FirstPage));
        let sender_for_prev = sender.clone();
        prev_button.connect_clicked(move |_| sender_for_prev.input(BrowseTabInput::PrevPage));
        let sender_for_next = sender.clone();
        next_button.connect_clicked(move |_| sender_for_next.input(BrowseTabInput::NextPage));
        let sender_for_last = sender;
        last_button.connect_clicked(move |_| sender_for_last.input(BrowseTabInput::LastPage));

        // Paginator lives in a native `gtk::ActionBar` to match the
        // mutations bar and the Structure tab's bottom action bar.
        // Prev/Next/label are start-packed; page-size + export are
        // end-packed — which gives the same visual as before but
        // through the toolkit's intended widget so spacing, dim-label
        // background, and high-contrast theming come for free.
        let paginator_bar = gtk::ActionBar::new();

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

        // First / Prev / Next / Last sit in a `linked` group so they
        // read as one navigation control — same pattern GNOME Files
        // uses on its back/forward toolbar buttons.
        let nav_box = gtk::Box::builder().orientation(gtk::Orientation::Horizontal).build();
        nav_box.add_css_class("linked");
        nav_box.append(&first_button);
        nav_box.append(&prev_button);
        nav_box.append(&next_button);
        nav_box.append(&last_button);

        paginator_bar.pack_start(&nav_box);
        paginator_bar.pack_start(&paginator_label);
        paginator_bar.pack_start(&selection_label);
        paginator_bar.pack_end(&export_button);
        paginator_bar.pack_end(&page_size_combo);
        paginator_bar.pack_end(&page_size_label);

        Paginator {
            bar: paginator_bar,
            first_button,
            prev_button,
            next_button,
            last_button,
            paginator_label,
            selection_label,
        }
    }

    /// Mutation actions in their own `gtk::ActionBar` (the Adwaita
    /// widget for selection-dependent toolbars). Visually separated
    /// from the paginator so a misclick on Next never lands on Delete.
    fn build_mutation_bar(sender: ComponentSender<Self>) -> Mutations {
        let insert_button = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text(crate::tr!("Insert row (Ctrl+N)"))
            .sensitive(false)
            .build();
        let delete_button = gtk::Button::builder()
            .icon_name("user-trash-symbolic")
            .tooltip_text(crate::tr!("Delete selected row (Delete)"))
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
            .tooltip_text(crate::tr!("Discard all pending edits"))
            .visible(false)
            .build();
        let sender_for_discard = sender.clone();
        discard_button.connect_clicked(move |_| sender_for_discard.input(BrowseTabInput::DiscardAll));

        let save_button = gtk::Button::builder()
            .label(crate::tr!("Save"))
            .tooltip_text(crate::tr!("Save pending edits (Ctrl+S)"))
            .visible(false)
            .build();
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

    /// Toggle visibility / label of the pending-changeset cluster in
    /// the mutation bar. Hidden when there are no pending edits; shows
    /// "{n} unsaved change(s)" with Save (.suggested-action) + Discard.
    /// The tab-title bullet (App-side) plus this footer cluster cover
    /// the dirty-state communication — no banner.
    fn refresh_pending_bar(&self, count: usize) {
        let visible = count > 0;
        self.save_button.set_visible(visible);
        self.discard_button.set_visible(visible);
        self.pending_label.set_visible(visible);
        if visible {
            let label = if count == 1 {
                crate::tr!("1 unsaved change")
            } else {
                crate::tr!("{n} unsaved changes").replace("{n}", &count.to_string())
            };
            self.pending_label.set_label(&label);
        }
        self.refresh_banner_visibility();
    }

    /// Reveal at most ONE banner at a time. Read-only takes priority
    /// over no-PK because read-only blocks every kind of edit.
    fn refresh_banner_visibility(&self) {
        let read_only = self.read_only;
        let no_pk = self.current_columns.iter().any(|c| !c.primary_key)
            && !self.current_columns.is_empty()
            && !self.current_columns.iter().any(|c| c.primary_key);
        self.read_only_banner.set_revealed(read_only);
        self.no_pk_banner.set_revealed(!read_only && no_pk);
    }

    /// Walk the selection → FilterListModel → ListStore chain to
    /// expose the underlying store for direct mutation (used by the
    /// inline-Insert path to prepend a draft row).
    fn list_store(&self) -> Option<gtk::gio::ListStore> {
        let selection = self.current_selection.as_ref()?;
        let filter_model = selection.model()?.downcast::<gtk::FilterListModel>().ok()?;
        filter_model.model()?.downcast::<gtk::gio::ListStore>().ok()
    }

    /// Notify the chain (ListStore → FilterListModel → SelectionModel
    /// → ColumnView) that the row at `filter_pos` has changed so the
    /// view rebinds its cells.
    ///
    /// Why: per GTK4 docs, `items-changed` "should never be emitted
    /// directly by users of the model" — it's a signal the *model
    /// implementation* emits when its content changes. Calling
    /// `filter_model.items_changed(...)` from the outside emits the
    /// signal but the FilterListModel's internal change-tracking
    /// state stays stale, so the downstream ColumnView sees no
    /// item-identity change and skips the bind. CSS classes
    /// (orange-tint pending state) update correctly because they're
    /// applied at bind time on every connect_bind, but the cell text
    /// won't refresh because connect_bind never re-runs.
    ///
    /// Walking through to the underlying `gio::ListStore` and
    /// emitting `items_changed` *there* propagates correctly: the
    /// ListStore is the change-emitter the chain expects, every
    /// derived model invalidates its caches, and the factory rebinds.
    fn refresh_row_at(&self, filter_pos: u32) {
        let row_obj = self.row_object_at(filter_pos);
        let store = self.list_store();
        let store_pos = match (row_obj.as_ref(), store.as_ref()) {
            (Some(r), Some(s)) => s.find(r),
            _ => None,
        };
        // ColumnView's list-item-manager keeps a per-listitem
        // cached pointer to the model item it's currently bound
        // to. When it receives items-changed for a position, it
        // re-fetches the model item at that position and
        // **compares pointers**: if same identity, it skips
        // unbind/bind because the bound item "didn't actually
        // change". Mutating cells *inside* the existing
        // RowObject (which is what set_cell does) keeps the
        // pointer constant — that's why neither plain
        // `items_changed` nor `splice(pos, 1, &[same_row_obj])`
        // forces a rebind here.
        //
        // The fix: substitute a freshly-allocated RowObject
        // carrying the post-mutation cells. Different GObject
        // identity → list-item-manager invalidates the cache,
        // unbinds the old listitem widget, rebinds with the
        // new item, connect_bind fires, label.set_text picks up
        // the reverted value. Atomic via splice: one items-
        // changed emission, no flicker, no scroll jump.
        if let (Some(store), Some(store_pos), Some(old)) = (store, store_pos, row_obj) {
            let cells = old.cells_clone();
            let replacement = match old.draft_id() {
                Some(id) => super::row_object::RowObject::new_draft(id, cells),
                None => super::row_object::RowObject::new(cells),
            };
            store.splice(store_pos, 1, &[replacement]);
        }
    }

    /// Look up the live `RowObject` at a filter-model position. Used
    /// to detect whether a row is a draft (`draft_id().is_some()`)
    /// vs a persisted row, and to mutate draft cells in place when
    /// the user types into them.
    fn row_object_at(&self, position: u32) -> Option<super::row_object::RowObject> {
        let model = self.current_selection.as_ref()?.model()?;
        model.item(position)?.downcast::<super::row_object::RowObject>().ok()
    }

    /// Locate the row in the current model that matches a given
    /// `RowKey`. Drafts match by `draft_id`; persisted rows match by
    /// recomputing the row's PK key-tuple from cell values and
    /// comparing. Returns the position in the (filtered) selection
    /// model, or `None` if the row isn't on the current page.
    fn find_row_position_by_key(&self, key: &crate::services::change_tracker::RowKey) -> Option<u32> {
        use crate::services::change_tracker::{KeyValue, RowKey};
        let selection = self.current_selection.as_ref()?;
        let model = selection.model()?;
        let pk_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        let n_items = model.n_items();
        for i in 0..n_items {
            let Some(item) = model.item(i) else { continue };
            let Ok(row) = item.downcast::<super::row_object::RowObject>() else {
                continue;
            };
            let matched = match key {
                RowKey::Draft(id) => row.draft_id() == Some(*id),
                RowKey::Persisted(target_keys) => {
                    if row.draft_id().is_some() || pk_indices.is_empty() {
                        false
                    } else {
                        let row_keys: Vec<KeyValue> = pk_indices
                            .iter()
                            .map(|&col_idx| (&row.cell_value(col_idx)).into())
                            .collect();
                        row_keys == *target_keys
                    }
                }
            };
            if matched {
                return Some(i);
            }
        }
        None
    }

    /// Locate the row that produced a failing statement and scroll-and-
    /// select it, plus apply a one-shot red flash animation. The flash
    /// state lives on `TabChangeTracker.error_row` so the grid bind
    /// callback picks it up via the existing tracker query path; a
    /// 1.8s timeout clears the state afterwards (matches the CSS
    /// animation duration). Best-effort lookup: a row that's been
    /// paginated past, sorted away, or filtered out won't be found,
    /// and we silently fall through to just the alert dialog.
    fn flash_error_row(&self, source: &crate::services::change_tracker::StatementSource) {
        use crate::services::change_tracker::{RowKey, StatementSource};
        let key = match source {
            StatementSource::Insert { draft_id } => RowKey::Draft(*draft_id),
            StatementSource::Update { row_key } | StatementSource::Delete { row_key } => row_key.clone(),
        };
        let Some(position) = self.find_row_position_by_key(&key) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(
                position,
                None,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
        }
        // Mark the row as the error row and trigger a re-bind so the
        // bind callback applies tp-row-leftmost-error-flash. Schedule
        // a timeout to clear the state once the animation has played.
        // The generation counter protects against a second flash that
        // starts inside the 1.8s window: the older timer's clear runs
        // but no-ops because gen no longer matches.
        let tab_id = self.tab_id;
        let generation =
            crate::services::change_tracker::with_tab(tab_id, |t| t.set_error_row(key.clone())).unwrap_or(0);
        self.refresh_row_at(position);
        let selection_for_clear = self.current_selection.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(1800), move || {
            let cleared = crate::services::change_tracker::with_tab(tab_id, |t| {
                let was_match = t.is_error_row_gen(generation);
                t.clear_error_row_if_gen(generation);
                was_match
            })
            .unwrap_or(false);
            if !cleared {
                // A newer flash superseded ours; don't disturb its bind.
                return;
            }
            // Inline the underlying-store hop because `self` is gone
            // from the closure scope (it's a 1.8s deferred timer);
            // the chain walk is the same as `refresh_row_at`.
            if let Some(selection) = selection_for_clear
                && let Some(model) = selection.model()
                && let Some(row_obj) = model
                    .item(position)
                    .and_then(|o| o.downcast::<super::row_object::RowObject>().ok())
                && let Some(filter_model) = model.downcast_ref::<gtk::FilterListModel>()
                && let Some(store) = filter_model
                    .model()
                    .and_then(|m| m.downcast::<gtk::gio::ListStore>().ok())
                && let Some(store_pos) = store.find(&row_obj)
            {
                store.items_changed(store_pos, 1, 1);
            }
        });
    }

    /// Snapshot the currently focused/first-selected row's identity.
    /// Called before any operation that triggers a `RowsLoaded` reload
    /// (sort flip, save, F5 refresh) so we can re-anchor the user's
    /// view to the same row after the new page renders.
    fn capture_focus_for_restore(&self) {
        use crate::services::change_tracker::RowKey;
        // If a previous capture is still pending (sort+save fire in
        // quick succession before the first reload's restore runs), keep
        // the original capture. The first user-visible focus should
        // anchor to where they were before triggering the chain — not
        // wherever focus drifted mid-rebuild.
        if self.pending_focus_restore.borrow().is_some() {
            return;
        }
        let Some(selection) = self.current_selection.as_ref() else {
            return;
        };
        let bitset = selection.selection();
        if bitset.size() == 0 {
            return;
        }
        let pos = bitset.nth(0);
        let Some(model) = selection.model() else { return };
        let Some(item) = model.item(pos) else { return };
        let Ok(row) = item.downcast::<super::row_object::RowObject>() else {
            return;
        };
        let key = if let Some(draft_id) = row.draft_id() {
            Some(RowKey::Draft(draft_id))
        } else {
            let pk_indices: Vec<usize> = self
                .current_columns
                .iter()
                .enumerate()
                .filter(|(_, c)| c.primary_key)
                .map(|(i, _)| i)
                .collect();
            if pk_indices.is_empty() {
                None
            } else {
                let pk_values: Vec<Value> = pk_indices.iter().map(|&i| row.cell_value(i)).collect();
                RowKey::from_pk_values(&pk_values)
            }
        };
        *self.pending_focus_restore.borrow_mut() = key;
    }

    /// Grab focus + start-editing on the freshly-inserted draft row's
    /// first editable cell. Called via `BrowseTabInput::FocusInsertedDraft`
    /// rather than directly so we read the current `column_view` /
    /// `selection` state rather than a captured-by-value reference that
    /// could go stale if a RowsLoaded fires between Insert and the
    /// deferred focus. The actual `start_editing` call is queued via
    /// `idle_add_local_once` so the new row finishes layout first.
    fn focus_inserted_draft(&self) {
        let Some(cv) = self.current_column_view.clone() else {
            return;
        };
        glib::idle_add_local_once(move || {
            // At idle time the column-view may already be detached
            // (rare race, e.g. user pressed F5 between InsertRow and
            // this idle). Bail silently — the row was inserted; only
            // the auto-edit affordance is missed.
            let Some(window) = cv.root().and_then(|r| r.dynamic_cast::<gtk::Window>().ok()) else {
                return;
            };
            let Some(focused) = gtk::prelude::GtkWindowExt::focus(&window) else {
                return;
            };
            if let Ok(label) = focused.dynamic_cast::<super::cell_editor::CellEditor>() {
                if label.text().as_str() == super::grid::editable_null_sentinel() {
                    label.set_text("");
                }
                label.start_editing();
            }
            // Bool draft (CheckButton focused) needs no edit-mode
            // dance; clicking / Space toggles natively.
        });
    }

    /// Re-select and scroll-to the row captured by
    /// `capture_focus_for_restore`, if it's still on the page after
    /// the reload. Silently no-ops if the row was filtered out, sorted
    /// to a different page, or removed by the commit. Always clears
    /// the captured key so it doesn't bleed into the next reload.
    fn restore_focused_row(&self) {
        let Some(key) = self.pending_focus_restore.borrow_mut().take() else {
            return;
        };
        let Some(position) = self.find_row_position_by_key(&key) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(position, None, gtk::ListScrollFlags::FOCUS, None);
        }
    }

    /// Build the `ColumnView` if we have both the schema (`current_columns`,
    /// from `ColumnsLoaded`) and the current page's data (`current_result`,
    /// from `RowsLoaded`). Until both are present the `inner_stack` stays
    /// on the "loading" status page so the user can't interact with cells
    /// whose editability map is wrong.
    fn render_grid_if_ready(&mut self, sender: ComponentSender<Self>) {
        let Some(result) = self.current_result.clone() else {
            return;
        };
        if self.current_columns.is_empty() {
            // Schema not yet loaded — keep the loading status visible.
            // ColumnsLoaded will re-invoke this when it arrives.
            return;
        }

        // Fast path: column structure hasn't changed since the last
        // render (typical for sort flips / page changes / save reloads
        // within one tab). Reuse the existing `ColumnView` and only
        // refresh the underlying `ListStore`. Saves O(N×M) factory
        // recreations and selection rebuilds per page change.
        if self.column_view_matches_current_columns()
            && let Some(store) = self.list_store()
        {
            self.refresh_grid_data(&result, &store);
            self.refresh_grid_chrome(&result);
            self.restore_focused_row();
            let _ = sender.output(BrowseTabOutput::StateChanged);
            return;
        }

        // Cold path: first render for this tab, or column structure
        // changed (rare in practice — would require schema migration
        // mid-session). Build the full column-view scaffolding.
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
        self.current_column_view = Some(column_view.clone());
        self.rendered_column_count.set(self.current_columns.len());

        // Selection-changed signal updates the count badge and the
        // Delete button's tooltip live. The new MultiSelection is a
        // fresh instance per rebuild, so the previous binding (if
        // any) drops with the old selection — no leak.
        let selection_label_for_signal = self.selection_label.clone();
        let delete_button_for_signal = self.delete_button.clone();
        if let Some(sel) = self.current_selection.as_ref() {
            sel.connect_selection_changed(move |sel, _, _| {
                let n = sel.selection().size() as u32;
                update_selection_chrome(&selection_label_for_signal, &delete_button_for_signal, n);
            });
            // Page rebuild clears MultiSelection's bitset; reset the
            // chrome explicitly so a stale "5 selected" doesn't linger.
            update_selection_chrome(&self.selection_label, &self.delete_button, 0);
        }

        // Re-prepend any pending draft rows so they survive page changes,
        // sort flips, and F5 refresh. The tracker is the canonical source
        // of truth for drafts; the grid model is rebuilt fresh on every
        // RowsLoaded so without this step the drafts vanish visually
        // while the tracker still holds them, leading to confused state.
        self.reprepend_drafts();

        let scrolled = gtk::ScrolledWindow::builder()
            .child(&column_view)
            .hexpand(true)
            .vexpand(true)
            .build();
        self.grid_holder.append(&scrolled);
        self.refresh_grid_chrome(&result);
        self.restore_focused_row();
        let _ = sender.output(BrowseTabOutput::StateChanged);
    }

    /// True when the cached `ColumnView` is structurally compatible
    /// with `current_columns` and can have its data swapped without a
    /// full rebuild. Within a single tab this is always true after
    /// the first render — `current_columns` only mutates on
    /// ColumnsLoaded, which fires once per (table, connection) open.
    fn column_view_matches_current_columns(&self) -> bool {
        self.current_column_view.is_some() && self.rendered_column_count.get() == self.current_columns.len()
    }

    /// Replace the rows in the existing `ListStore` without touching
    /// the columns / factories / selection model. Drafts are
    /// re-prepended so they survive the swap.
    fn refresh_grid_data(&self, result: &QueryResult, store: &gtk::gio::ListStore) {
        store.remove_all();
        for row in &result.rows {
            store.append(&super::row_object::RowObject::new(row.clone()));
        }
        self.reprepend_drafts();
        // Re-apply the search filter against the new data.
        self.grid_search.emit_by_name::<()>("search-changed", &[]);
    }

    /// Update paginator label, button sensitivity, and stack child —
    /// chrome that depends on the result but not the column structure.
    fn refresh_grid_chrome(&self, result: &QueryResult) {
        self.refresh_crud_buttons();
        self.update_paginator_label();
        let on_first_page = self.current_offset == 0;
        self.first_button.set_sensitive(!on_first_page);
        self.prev_button.set_sensitive(!on_first_page);
        let n_rows = result.rows.len() as u64;
        self.next_button.set_sensitive(n_rows == self.page_size);
        // Last only enables when we know the total AND we aren't
        // already there. Without a known total, the button stays
        // disabled — matches `RowCountLoaded`-gated UX everywhere
        // else.
        let last_target = self
            .current_total_rows
            .filter(|t| *t > 0)
            .map(|t| (t - 1) / self.page_size * self.page_size);
        self.last_button
            .set_sensitive(last_target.is_some_and(|target| self.current_offset != target));

        // Empty-state: zero rows on the first page with no drafts →
        // show a status page instead of an empty grid rectangle. As
        // soon as the user inserts a draft, the next ChangedRows
        // event re-binds and we flip back to "grid".
        let has_drafts =
            crate::services::change_tracker::with_tab_ref(self.tab_id, |t| !t.drafts().is_empty()).unwrap_or(false);
        if result.rows.is_empty() && self.current_offset == 0 && !has_drafts {
            self.show_empty_inner();
            self.inner_stack.set_visible_child_name("empty");
        } else {
            self.inner_stack.set_visible_child_name("grid");
        }
        self.suppress_combo_emit.set(false);
    }

    /// Walk `tracker.drafts()` and prepend each as a draft `RowObject`
    /// at the top of the grid's `ListStore`. Forward iteration with
    /// `insert(0, …)` preserves the original insertion order: newest
    /// at the top, then older drafts beneath, then persisted rows.
    fn reprepend_drafts(&self) {
        let Some(store) = self.list_store() else {
            return;
        };
        let drafts = crate::services::change_tracker::with_tab_ref(self.tab_id, |t| {
            t.drafts()
                .iter()
                .map(|d| (d.draft_id, d.values.clone()))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
        for (draft_id, values) in drafts {
            let draft_row = super::row_object::RowObject::new_draft(draft_id, values);
            store.insert(0, &draft_row);
        }
    }

    /// Force a single-row re-bind via `items_changed(pos, 1, 1)` on the
    /// FilterListModel. Used when rejecting an invalid cell edit: the
    /// `CellEditor` still holds the user's typed text after editing-
    /// notify fires, so we trigger a re-bind to restore the canonical
    /// display from `RowObject.cell_value()` (which we did NOT mutate
    /// because the parse failed).
    fn refresh_row(&self, position: u32) {
        self.refresh_row_at(position);
    }

    /// Build the (RowKey, current_values) pair for a row at the
    /// given position. `row_position` is in filter-model space (the
    /// space `GtkColumnView` activates against), which includes
    /// prepended drafts — so we resolve through the selection model
    /// rather than indexing `result.rows` directly. The earlier
    /// direct-indexing version was off by N when N drafts were
    /// prepended, silently targeting the wrong persisted row's PK
    /// from the right-click delete, Set NULL shortcut, and any
    /// cell-edit on a persisted row that sits below a draft.
    ///
    /// Returns None for drafts (caller is expected to handle the
    /// draft path before reaching here), for tables with no PK, or
    /// when the position is out of range.
    fn row_key_at(&self, row_position: u32) -> Option<(crate::services::change_tracker::RowKey, Vec<Value>)> {
        let row_obj = self.row_object_at(row_position)?;
        if row_obj.draft_id().is_some() {
            return None;
        }
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
        let cells = row_obj.cells_clone();
        let pk_values: Vec<Value> = pk_indices
            .iter()
            .map(|&i| cells.get(i).cloned())
            .collect::<Option<_>>()?;
        let key = crate::services::change_tracker::RowKey::from_pk_values(&pk_values)?;
        Some((key, cells))
    }

    /// Returns true when the loaded columns include at least one PK.
    /// Used to gate Insert / Delete and reveal the no-PK banner.
    fn has_primary_key(&self) -> bool {
        self.current_columns.iter().any(|c| c.primary_key)
    }

    fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_rows = self.current_result.is_some();
        let has_pk = self.has_primary_key();
        if self.read_only {
            self.insert_button.set_visible(false);
            self.delete_button.set_visible(false);
            return;
        }
        self.insert_button.set_visible(true);
        self.delete_button.set_visible(true);
        // No-PK tables don't get inline editing because RowKey can't be
        // formed without a PK and our materialise path would silently
        // no-op on UPDATE/DELETE. Disable instead of hide so the
        // affordance stays discoverable; tooltip explains the gate.
        let pk_tip = crate::tr!("This table has no primary key. Inline editing is disabled.");
        self.insert_button.set_sensitive(has_columns && has_pk);
        self.delete_button.set_sensitive(has_columns && has_rows && has_pk);
        if has_columns && !has_pk {
            self.insert_button.set_tooltip_text(Some(&pk_tip));
            self.delete_button.set_tooltip_text(Some(&pk_tip));
        } else {
            self.insert_button
                .set_tooltip_text(Some(&crate::tr!("Insert row (Ctrl+N)")));
            self.delete_button
                .set_tooltip_text(Some(&crate::tr!("Delete selected row (Delete)")));
        }
        self.refresh_banner_visibility();
    }

    fn update_paginator_label(&self) {
        let Some(result) = self.current_result.as_ref() else {
            self.paginator_label.set_label("");
            return;
        };
        let n_rows = result.rows.len();
        if n_rows == 0 {
            // Reachable when the user navigated past the end of a
            // table that shrank in another session, before
            // RowCountLoaded clamps the offset back. Human
            // wording — the previous "No rows at offset N" read as
            // a bug message.
            self.paginator_label.set_label(&crate::tr!("No rows on this page"));
            return;
        }
        let start = self.current_offset + 1;
        let end = self.current_offset + n_rows as u64;
        // Match the page-size dropdown's thousands grouping.
        // "Rows 10,001 – 10,100 of 5,000,000" is faster to read than
        // "Rows 10001 – 10100 of 5000000" and matches GNOME File's
        // "1,234 items" idiom.
        let start_s = format_thousands(start);
        let end_s = format_thousands(end);
        let label = match self.current_total_rows {
            Some(total) => crate::tr!("Rows {start} – {end} of {total}")
                .replace("{start}", &start_s)
                .replace("{end}", &end_s)
                .replace("{total}", &format_thousands(total)),
            None => crate::tr!("Rows {start} – {end}")
                .replace("{start}", &start_s)
                .replace("{end}", &end_s),
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
        // adw::Spinner replaces deprecated gtk::Spinner (GTK 4.12+).
        let spinner = adw::Spinner::builder()
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
        // Title pattern matches the structure tab ("Couldn't load
        // structure"). The previous terse "Failed" left the user
        // guessing what failed.
        let page = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Couldn't load rows"))
            .description(message)
            .build();
        self.replace_status_child("error", &page);
    }

    /// Empty-state placeholder for tables with no rows on offset 0 and
    /// no pending drafts. AdwStatusPage with a context-appropriate
    /// description: "Press Ctrl+N to add the first row" for editable
    /// tables, "Use the SQL editor to add rows" for read-only ones.
    fn show_empty_inner(&self) {
        let (title, description) = if self.read_only {
            (
                crate::tr!("No rows yet"),
                crate::tr!("This table is empty. Use the SQL editor to add rows."),
            )
        } else if !self.has_primary_key() {
            (
                crate::tr!("No rows yet"),
                crate::tr!("This table has no primary key. Use the SQL editor to add rows."),
            )
        } else {
            (
                crate::tr!("No rows yet"),
                crate::tr!("Press Ctrl+N to add the first row."),
            )
        };
        let page = adw::StatusPage::builder()
            .icon_name("view-grid-symbolic")
            .title(&title)
            .description(&description)
            .build();
        self.replace_status_child("empty", &page);
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
                &adw::Spinner::builder()
                    .width_request(32)
                    .height_request(32)
                    .halign(gtk::Align::Center)
                    .build(),
            )
            .build();
        inner_stack.add_named(&initial_loading, Some("loading"));
        inner_stack.set_visible_child_name("loading");

        let paginator = Self::build_paginator(sender.clone(), init.page_size);
        let mutations = Self::build_mutation_bar(sender.clone());

        // Per-HIG banner rule: banners persist hard constraints the
        // user can't fix by saving. Both reveal only when their
        // condition triggers:
        //   - read-only: connection-wide constraint (most permanent).
        //   - no-PK: table-level constraint (per browse tab, persists
        //     until the user opens a different table).
        // Pending-changes state lives in the tab-title bullet plus the
        // ActionBar footer ("N unsaved changes / Discard / Save") —
        // an additional banner would just duplicate that signal.
        let read_only_banner = adw::Banner::builder()
            .title(crate::tr!("Read-only connection. Editing disabled."))
            .revealed(init.read_only)
            .build();
        let no_pk_banner = adw::Banner::builder()
            .title(crate::tr!(
                "This table has no primary key. Use the SQL editor to modify rows."
            ))
            .revealed(false)
            .build();

        root.add_top_bar(&read_only_banner);
        root.add_top_bar(&no_pk_banner);
        root.add_top_bar(&grid_search_bar);
        root.set_content(Some(&inner_stack));
        // Mutations bar sits below the paginator (call order = stack
        // order in AdwToolbarView's add_bottom_bar) so the visual
        // hierarchy is: grid → paginator → mutations.
        root.add_bottom_bar(&paginator.bar);
        root.add_bottom_bar(&mutations.bar);
        // No `set_key_capture_widget` on the search bar: that property
        // makes any printable keystroke anywhere in the BrowseTab open
        // the search entry, even while the user is typing into a
        // cell's GtkText (the "type-to-search" pattern from GNOME
        // Files). It conflicts with inline cell editing — the first
        // keystroke after entering edit mode jumps focus to the search
        // entry instead of going into the cell. Ctrl+F still opens
        // search, which is the documented shortcut.

        // SearchBar's built-in Escape handler only fires while the
        // SearchEntry (or its close button) has focus. If the user opens
        // search and then clicks the page-size dropdown or any paginator
        // control, Esc lands outside the bar's reach. A Local-scope
        // shortcut on root catches Escape anywhere in this tab and
        // dismisses the bar — matching the GNOME Files / Text Editor
        // behaviour where Esc reliably closes search regardless of focus.
        // Per-tab GridMsg channel: events from this tab's grid (sort
        // change, cell edits, context-menu actions) flow into this tab's
        // own input queue, which then re-emits them as outputs to App
        // tagged with this tab's id (via the forward closure App sets up).
        // Created up-front so tab-local shortcuts (Ctrl+Shift+N → set
        // focused cell to NULL) can route directly to the grid sender.
        let (grid_sender, grid_receiver) = relm4::channel::<GridMsg>();

        let search_bar_for_esc = grid_search_bar.clone();
        let sender_for_esc = sender.clone();
        let esc_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Escape").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                if search_bar_for_esc.is_search_mode() {
                    search_bar_for_esc.set_search_mode(false);
                    // Restore focus to the grid — without this the
                    // SearchBar leaves focus floating and the next
                    // keystroke vanishes (or re-opens the search if
                    // it lands on something keypress-capturing).
                    sender_for_esc.input(BrowseTabInput::FocusGrid);
                    glib::Propagation::Stop
                } else {
                    // Esc on the grid (no search, no edit) clears a
                    // multi-row selection. Spreadsheet convention
                    // (Excel / LibreOffice / DataGrip): Esc cancels
                    // the in-progress selection without deleting
                    // anything. Single-row selections fall through
                    // because GtkColumnView treats single-select as
                    // "the focused row" and unselecting it would
                    // strand the focus indicator. Cell-edit Esc fires
                    // first via the editor's capture-phase handler
                    // and never reaches us.
                    sender_for_esc.input(BrowseTabInput::ClearSelection);
                    glib::Propagation::Proceed
                }
            }))
            .build();

        // Tab-local shortcuts for browse-grid keyboard model. Local
        // scope means these only fire while focus is inside this
        // BrowseTab. When the user is in another tab or in the editor,
        // these triggers fall through to whatever that context wires.
        //
        // - Delete: mark selected rows for pending deletion (matches
        //   the Delete-button toolbar action; HIG keyboard reference
        //   "Delete = Delete the selected item").
        // - Ctrl+N: insert a draft row (HIG "Ctrl+N = Create a new
        //   document"; document = row in this context).
        // - Ctrl+Shift+N: set the focused cell to SQL NULL. App-
        //   specific binding (no GNOME precedent for "set NULL");
        //   chosen because Ctrl+Backspace conflicts with delete-word
        //   in every text-edit widget.
        let sender_for_delete = sender.clone();
        let delete_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Delete").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_delete.input(BrowseTabInput::DeleteSelectedRow);
                glib::Propagation::Stop
            }))
            .build();
        let sender_for_insert = sender.clone();
        let insert_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>n").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_insert.input(BrowseTabInput::InsertRow);
                glib::Propagation::Stop
            }))
            .build();
        let grid_sender_for_null = grid_sender.clone();
        let null_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary><Shift>n").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |widget, _| {
                let Some((row_position, col_index)) = super::grid::focused_cell_coords(widget) else {
                    return glib::Propagation::Proceed;
                };
                grid_sender_for_null
                    .send(GridMsg::SetCellNull {
                        row_position,
                        col_index,
                    })
                    .ok();
                glib::Propagation::Stop
            }))
            .build();

        // Ctrl+C: when row(s) are selected and focus is NOT inside a
        // text-editor (cell edit mode, search entry, draft input), copy
        // the selection as TSV. Bubble-phase Local scope: GtkText
        // consumes Ctrl+C while editing so the cell-text-selection
        // copy still works without our handler interfering.
        let sender_for_copy = sender.clone();
        let copy_rows_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>c").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_copy.input(BrowseTabInput::CopySelectedRowsAsTsv);
                glib::Propagation::Stop
            }))
            .build();
        // Ctrl+V on the grid (focus not inside a text editor): show a
        // toast explaining multi-row paste isn't supported. Cell-level
        // paste (focus inside a CellEditor's GtkText) is consumed
        // by the entry first, so this only fires for grid-level paste
        // attempts.
        let sender_for_paste = sender.clone();
        let paste_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>v").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_paste.input(BrowseTabInput::PasteNotSupported);
                glib::Propagation::Stop
            }))
            .build();
        // Ctrl+A: select every visible row. Standard "select all"
        // affordance — gives the user a quick path into bulk-delete
        // (which then triggers the M3 confirmation dialog when the
        // count exceeds the threshold).
        let sender_for_select_all = sender.clone();
        let select_all_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>a").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_select_all.input(BrowseTabInput::SelectAllRows);
                glib::Propagation::Stop
            }))
            .build();
        // Page Up / Page Down on the BrowseTab navigate the paginator.
        // GtkColumnView's built-in scrolling normally handles these,
        // but our offset-based pagination means scrolling stops at
        // the page boundary. Mapping PgUp/PgDn to Prev/Next page
        // keeps the keyboard fluent across pages.
        let sender_for_pgup = sender.clone();
        let page_up_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Page_Up").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_pgup.input(BrowseTabInput::PrevPage);
                glib::Propagation::Stop
            }))
            .build();
        let sender_for_pgdn = sender.clone();
        let page_down_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Page_Down").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_pgdn.input(BrowseTabInput::NextPage);
                glib::Propagation::Stop
            }))
            .build();
        // Home / End scoped to row navigation: jump to the first /
        // last visible row of the current page.
        let sender_for_home = sender.clone();
        let home_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>Home").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_home.input(BrowseTabInput::GoToFirstRow);
                glib::Propagation::Stop
            }))
            .build();
        let sender_for_end = sender.clone();
        let end_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>End").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_end.input(BrowseTabInput::GoToLastRow);
                glib::Propagation::Stop
            }))
            .build();

        let esc_controller = gtk::ShortcutController::new();
        esc_controller.set_scope(gtk::ShortcutScope::Local);
        esc_controller.add_shortcut(esc_shortcut);
        esc_controller.add_shortcut(delete_shortcut);
        esc_controller.add_shortcut(insert_shortcut);
        esc_controller.add_shortcut(null_shortcut);
        esc_controller.add_shortcut(copy_rows_shortcut);
        esc_controller.add_shortcut(paste_shortcut);
        esc_controller.add_shortcut(select_all_shortcut);
        esc_controller.add_shortcut(page_up_shortcut);
        esc_controller.add_shortcut(page_down_shortcut);
        esc_controller.add_shortcut(home_shortcut);
        esc_controller.add_shortcut(end_shortcut);
        root.add_controller(esc_controller);

        // Wire the GridMsg receiver into this tab's input queue. Each
        // GridMsg becomes a BrowseTabInput tagged with the same payload
        // shape; the tab's update() then routes them to the App via
        // outputs that App's forwarder tags with this tab's id.
        let grid_input = sender.input_sender().clone();
        relm4::spawn_local(grid_receiver.forward(grid_input, |msg| match msg {
            GridMsg::SortChanged(col_idx, ascending) => BrowseTabInput::SortChanged { col_idx, ascending },
            GridMsg::CellEdited {
                row_position,
                col_index,
                new_value,
            } => BrowseTabInput::GridCellEdited {
                row_position,
                col_index,
                new_value,
            },
            GridMsg::CopyToClipboard(text) => BrowseTabInput::GridCopyToClipboard(text),
            GridMsg::CopyRowAsInsert { row_position } => BrowseTabInput::GridCopyRowAsInsert { row_position },
            GridMsg::SetCellNull {
                row_position,
                col_index,
            } => BrowseTabInput::GridSetCellNull {
                row_position,
                col_index,
            },
            GridMsg::DeleteRowAt { row_position } => BrowseTabInput::GridDeleteRowAt { row_position },
            GridMsg::InsertRow => BrowseTabInput::InsertRow,
            GridMsg::DuplicateRow { row_position } => BrowseTabInput::DuplicateRow { row_position },
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
            current_column_view: None,
            rendered_column_count: std::cell::Cell::new(0),
            read_only_banner,
            no_pk_banner,
            was_dirty: std::cell::Cell::new(false),
            pending_focus_restore: std::cell::RefCell::new(None),
            grid_search,
            grid_search_bar,
            grid_search_handler: None,
            paginator_label: paginator.paginator_label,
            selection_label: paginator.selection_label,
            first_button: paginator.first_button,
            prev_button: paginator.prev_button,
            next_button: paginator.next_button,
            last_button: paginator.last_button,
            insert_button: mutations.insert_button,
            delete_button: mutations.delete_button,
            save_button: mutations.save_button,
            discard_button: mutations.discard_button,
            pending_label: mutations.pending_label,
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
        relm4::spawn_local(tracker_receiver.forward(input_for_tracker, move |event| match event {
            crate::services::change_tracker::TrackerEvent::PendingCountChanged(n) => {
                BrowseTabInput::PendingCountChanged(n)
            }
            crate::services::change_tracker::TrackerEvent::Cleared => BrowseTabInput::PendingCountChanged(0),
            // ChangedRows drives targeted items_changed so only the
            // affected rows re-bind, not the whole visible viewport.
            // PendingCountChanged is emitted alongside by the tracker
            // (see emit_changed) so banner / dirty-flag updates still
            // run for the same mutation.
            crate::services::change_tracker::TrackerEvent::ChangedRows(keys) => BrowseTabInput::ChangedRows(keys),
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
                self.current_result = Some(result);
                // Defer rendering until columns are also loaded — the
                // QueryResult's ColumnInfo lacks `primary_key` /
                // `is_generated` / `is_auto_increment`, so rendering
                // before the schema fetch would let the user edit cells
                // (PK, generated columns) that the DB will reject on
                // save. Waiting also avoids a wasted full rebuild when
                // ColumnsLoaded fires next and triggers a re-render.
                self.render_grid_if_ready(sender);
            }
            BrowseTabInput::ColumnsLoaded(columns) => {
                let words: Vec<String> = columns.iter().map(|c| c.name.clone()).collect();
                self.current_columns = columns;
                self.refresh_crud_buttons();
                let _ = sender.output(BrowseTabOutput::SchemaWordsChanged(words));
                // If rows are already cached, render now with the proper
                // editability map. Otherwise wait for RowsLoaded.
                self.render_grid_if_ready(sender);
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
            BrowseTabInput::ShowError(message) => {
                // Clear any cached page state so a follow-up refresh
                // doesn't render against the stale snapshot before
                // RowsLoaded arrives. Paginator label is left empty
                // until next RowCountLoaded.
                self.current_result = None;
                self.current_total_rows = None;
                self.paginator_label.set_label("");
                self.first_button.set_sensitive(false);
                self.prev_button.set_sensitive(false);
                self.next_button.set_sensitive(false);
                self.last_button.set_sensitive(false);
                self.show_error_inner(&message);
                self.inner_stack.set_visible_child_name("error");
            }
            BrowseTabInput::Refresh => {
                self.capture_focus_for_restore();
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
            BrowseTabInput::FocusGrid => {
                if let Some(cv) = self.current_column_view.as_ref() {
                    cv.grab_focus();
                }
            }
            BrowseTabInput::ClearSelection => {
                let Some(sel) = self.current_selection.as_ref() else {
                    return;
                };
                // Only clear when we have a true multi-row selection.
                // Without this guard, every Esc on a single-focus row
                // would re-trigger the "0 selected" path through GTK's
                // re-focus logic and strand the focus indicator.
                if sel.selection().size() < 2 {
                    return;
                }
                sel.unselect_all();
            }
            BrowseTabInput::FirstPage => {
                if self.current_offset > 0 {
                    self.current_offset = 0;
                    let _ = sender.output(BrowseTabOutput::FetchPage);
                    let _ = sender.output(BrowseTabOutput::StateChanged);
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
            BrowseTabInput::LastPage => {
                let Some(total) = self.current_total_rows else {
                    // Total unknown — Last has no target. UI keeps the
                    // button disabled until RowCountLoaded fires, so
                    // this branch is a defensive guard.
                    return;
                };
                if total == 0 {
                    return;
                }
                let last_page_offset = (total - 1) / self.page_size * self.page_size;
                if self.current_offset != last_page_offset {
                    self.current_offset = last_page_offset;
                    let _ = sender.output(BrowseTabOutput::FetchPage);
                    let _ = sender.output(BrowseTabOutput::StateChanged);
                }
            }
            BrowseTabInput::SortChanged { col_idx, ascending } => {
                // Idempotent: GtkColumnViewSorter fires both
                // `primary-sort-column` and `primary-sort-order`
                // notifies for one logical click on a different
                // column (column changes; order resets). Each
                // notify dispatches the same post-state pair, so
                // we short-circuit when the pair already matches.
                let next = (col_idx, ascending);
                if self.current_sort == Some(next) {
                    return;
                }
                self.current_sort = Some(next);
                self.current_offset = 0;
                self.capture_focus_for_restore();
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
            BrowseTabInput::DuplicateRow { row_position } => {
                if self.current_columns.is_empty() {
                    return;
                }
                // Read the source row through the live RowObject at
                // `row_position` in the FilterListModel — NOT by
                // indexing `current_result.rows` directly. The grid's
                // row_position reflects the user's current sort + any
                // active search filter; raw `rows` is fetch order. A
                // sort or filter would otherwise hand us the wrong
                // row's cells.
                let Some(source) = self.row_object_at(row_position) else {
                    return;
                };
                let source_cells = source.cells_clone();
                // Clone source values; blank columns whose value is
                // owned by the database (PK, identity / serial,
                // generated). The duplicate is meant to be a *new*
                // row — inheriting the source's identity would either
                // collide on save or pre-fill nonsense.
                let values: Vec<Value> = self
                    .current_columns
                    .iter()
                    .enumerate()
                    .map(|(i, col)| {
                        if col.primary_key || col.is_auto_increment || col.is_generated {
                            Value::Null
                        } else {
                            source_cells.get(i).cloned().unwrap_or(Value::Null)
                        }
                    })
                    .collect();
                let key_opt =
                    crate::services::change_tracker::with_tab(self.tab_id, |t| t.track_insert(values.clone()));
                let Some(key) = key_opt else {
                    return;
                };
                let crate::services::change_tracker::RowKey::Draft(draft_id) = key else {
                    return;
                };
                if let Some(store) = self.list_store() {
                    let draft_row = super::row_object::RowObject::new_draft(draft_id, values);
                    store.insert(0, &draft_row);
                }
                if let Some(cv) = self.current_column_view.as_ref() {
                    cv.scroll_to(
                        0,
                        None,
                        gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                        None,
                    );
                }
                sender.input(BrowseTabInput::FocusInsertedDraft);
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
                // Scroll the new row into view immediately, then defer
                // the start-editing call to the next event-loop tick
                // through a self-message. Self-messaging (instead of
                // capturing column_view by value into an
                // `idle_add_local_once`) means the handler reads the
                // freshest `self.current_column_view` — if a
                // RowsLoaded fires between Insert and the deferred
                // focus, we use the rebuilt view rather than a dangling
                // reference to the old one.
                if let Some(cv) = self.current_column_view.as_ref() {
                    cv.scroll_to(
                        0,
                        None,
                        gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                        None,
                    );
                }
                sender.input(BrowseTabInput::FocusInsertedDraft);
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
                // Partition the selection into persisted rows (need a
                // PK to build a RowKey) and drafts (in-memory only,
                // discarded by id). We resolve through the selection
                // model rather than `result.rows[pos]` directly
                // because `pos` is in filter-model space, which
                // includes prepended drafts. A pure-draft selection
                // is valid (the user can bulk-discard pending
                // inserts before saving).
                let Some(model) = selection.model() else {
                    return;
                };
                let mut snapshot: Vec<(crate::services::change_tracker::RowKey, Vec<Value>)> = Vec::new();
                let mut draft_ids: Vec<u64> = Vec::new();
                let mut had_persisted_row = false;
                for pos in &positions {
                    let Some(item) = model.item(*pos) else { continue };
                    let Ok(row_obj) = item.downcast::<super::row_object::RowObject>() else {
                        continue;
                    };
                    if let Some(draft_id) = row_obj.draft_id() {
                        draft_ids.push(draft_id);
                        continue;
                    }
                    had_persisted_row = true;
                    let cells = row_obj.cells_clone();
                    if let Some(pk_values) = pk_indices
                        .iter()
                        .map(|&i| cells.get(i).cloned())
                        .collect::<Option<Vec<Value>>>()
                        && let Some(key) = crate::services::change_tracker::RowKey::from_pk_values(&pk_values)
                    {
                        snapshot.push((key, cells));
                    }
                }
                // PK gate only fires when persisted rows are involved.
                // Pure-draft selections sail through to discard.
                if had_persisted_row && pk_indices.is_empty() {
                    let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                        title: crate::tr!("Cannot delete"),
                        body: crate::tr!("This table has no primary key — editing is disabled."),
                    });
                    return;
                }
                if snapshot.is_empty() && draft_ids.is_empty() {
                    return;
                }
                let count = snapshot.len() + draft_ids.len();
                let tab_id = self.tab_id;
                let selection_for_commit = selection.clone();
                let commit_delete = move |snapshot: Vec<(crate::services::change_tracker::RowKey, Vec<Value>)>,
                                          draft_ids: Vec<u64>| {
                    crate::services::change_tracker::with_tab(tab_id, |t| {
                        for (key, row) in snapshot {
                            t.track_delete(key, row);
                        }
                        for id in draft_ids {
                            t.discard_draft(id);
                        }
                    });
                    // Clear the multi-row selection so the
                    // "{n} selected" badge disappears and the Delete
                    // button tooltip resets. Without this the bitset
                    // still contains the now-strikethrough rows
                    // (they remain in the model until Save). Spreadsheet
                    // convention: a bulk action ends the selection it
                    // operated on.
                    selection_for_commit.unselect_all();
                };
                if count >= BULK_DELETE_CONFIRM_THRESHOLD {
                    // Dialog parent is any descendant of the toplevel
                    // window — adw::AlertDialog walks up to find the
                    // window. The inner_stack is always parented to
                    // the BrowseTab's root toolbar, so it resolves
                    // correctly while the tab is visible.
                    let title = crate::tr!("Delete {n} rows?").replace("{n}", &count.to_string());
                    let body =
                        crate::tr!("These rows will be marked for deletion. They aren't removed until you click Save.");
                    let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
                    dialog.add_response("cancel", &crate::tr!("Cancel"));
                    dialog.add_response("delete", &crate::tr!("Delete"));
                    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
                    dialog.set_default_response(Some("cancel"));
                    dialog.set_close_response("cancel");
                    let pending = std::cell::RefCell::new(Some((snapshot, draft_ids)));
                    dialog.connect_response(None, move |dlg, response| {
                        dlg.close();
                        if response == "delete"
                            && let Some((s, d)) = pending.borrow_mut().take()
                        {
                            commit_delete(s, d);
                        }
                    });
                    dialog.present(Some(&self.inner_stack));
                } else {
                    commit_delete(snapshot, draft_ids);
                }
            }
            BrowseTabInput::GridCellEdited {
                row_position,
                col_index,
                new_value,
            } => {
                // Cell edits route through the per-tab change tracker
                // so the user can review / Save / Discard a batch.
                //
                // Empty input on a nullable column becomes Value::Null
                // (canonical SQL convention for "user cleared the
                // cell"). Non-empty input is parsed against the
                // column's data_type so every native type binds at
                // its declared kind instead of falling back to text.
                //
                // On parse failure the edit is rejected: a toast
                // explains why and `refresh_row` forces a re-bind so
                // the cell goes back to the canonical pre-edit
                // display. The tracker stays untouched so a single
                // bad keystroke can't sneak into the batch.
                //
                // GtkText handles multi-line clipboard paste
                // inconsistently across GTK builds — some embed
                // literal newlines, some strip them silently.
                // Collapse newlines / carriage returns to spaces
                // here so a paste-induced multi-line value never
                // reaches the SQL layer. JSON columns aren't
                // normalised: they need real newlines.
                let normalized = match self
                    .current_columns
                    .get(col_index)
                    .map(|c| classify_type(&c.data_type.to_ascii_lowercase()))
                {
                    Some(TypeKind::Json) => new_value,
                    _ => normalize_single_line_input(&new_value),
                };
                let col = self.current_columns.get(col_index);
                let new = match parse_input_for_column(&normalized, col) {
                    Ok(v) => v,
                    Err(message) => {
                        let _ = sender.output(BrowseTabOutput::ShowToast(message));
                        self.refresh_row(row_position);
                        return;
                    }
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
            BrowseTabInput::GridDeleteRowAt { row_position } => {
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
            BrowseTabInput::CopySelectedRowsAsTsv => {
                let Some(selection) = self.current_selection.as_ref() else {
                    return;
                };
                let positions = selected_positions(selection);
                if positions.is_empty() {
                    return;
                }
                let model = match selection.model() {
                    Some(m) => m,
                    None => return,
                };
                let mut rows: Vec<String> = Vec::with_capacity(positions.len());
                for pos in &positions {
                    let Some(item) = model.item(*pos) else { continue };
                    let Ok(row) = item.downcast::<super::row_object::RowObject>() else {
                        continue;
                    };
                    let cells = row.cells_clone();
                    let line: Vec<String> = cells
                        .iter()
                        .map(|v| escape_tsv_cell(&super::grid::value_to_display_text(v)))
                        .collect();
                    rows.push(line.join("\t"));
                }
                if rows.is_empty() {
                    return;
                }
                let tsv = rows.join("\n");
                let _ = sender.output(BrowseTabOutput::CopyToClipboard(tsv));
            }
            BrowseTabInput::PasteNotSupported => {
                let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                    "Pasting rows isn't supported yet"
                )));
            }
            BrowseTabInput::SelectAllRows => {
                if let Some(selection) = self.current_selection.as_ref() {
                    let n = selection.n_items();
                    if n > 0 {
                        selection.select_all();
                    }
                }
            }
            BrowseTabInput::GoToFirstRow => {
                let Some(cv) = self.current_column_view.as_ref() else {
                    return;
                };
                let n = self.current_selection.as_ref().map(|s| s.n_items()).unwrap_or(0);
                if n == 0 {
                    return;
                }
                cv.scroll_to(
                    0,
                    None,
                    gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                    None,
                );
            }
            BrowseTabInput::GoToLastRow => {
                let Some(cv) = self.current_column_view.as_ref() else {
                    return;
                };
                let n = self.current_selection.as_ref().map(|s| s.n_items()).unwrap_or(0);
                if n == 0 {
                    return;
                }
                cv.scroll_to(
                    n - 1,
                    None,
                    gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                    None,
                );
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
                    Some(Ok((statements, sources))) if !statements.is_empty() => {
                        // Disable both buttons for the duration of the
                        // in-flight transaction. SaveCompleted /
                        // SaveFailed re-enable them. This prevents a
                        // double-click firing two transactions and
                        // matches GNOME's standard "in-progress action"
                        // affordance (busy spinner + disabled control).
                        self.save_button.set_sensitive(false);
                        self.discard_button.set_sensitive(false);
                        // SaveCompleted will refetch the page; capture
                        // the focused row's PK now so it can be re-
                        // selected after the reload.
                        self.capture_focus_for_restore();
                        let _ = sender.output(BrowseTabOutput::ExecuteTransaction { statements, sources });
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
                // Tell the App so it can prefix the tab title with the
                // GNOME-Text-Editor "•" dot for dirty buffers. Only on
                // real transitions (empty ↔ non-empty) so a count
                // change like 2 → 3 doesn't re-rewrite the tab title.
                let dirty = n > 0;
                if dirty != self.was_dirty.get() {
                    self.was_dirty.set(dirty);
                    let _ = sender.output(BrowseTabOutput::DirtyChanged(dirty));
                }
                // Note: row re-binds are driven by the parallel
                // ChangedRows event, not from here. PendingCountChanged
                // fires on every tracker mutation so re-binding the
                // viewport here would be wasteful — most edits affect
                // exactly one row and ChangedRows hits only that row.
            }
            BrowseTabInput::ChangedRows(keys) => {
                // Walk the model once per key. For typical interactive
                // edits (one cell at a time) this is O(n) per keystroke
                // where n = visible row count — bounded and cheap.
                // Bulk operations (Discard) emit one ChangedRows per
                // op via undo unwind, again bounded.
                for key in &keys {
                    if let Some(pos) = self.find_row_position_by_key(key) {
                        self.refresh_row_at(pos);
                    }
                }
            }
            BrowseTabInput::SaveCompleted => {
                crate::services::change_tracker::with_tab(self.tab_id, |t| t.clear());
                self.refresh_pending_bar(0);
                self.save_button.set_sensitive(true);
                self.discard_button.set_sensitive(true);
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::FetchRowCount);
            }
            BrowseTabInput::SaveFailed(message) => {
                self.save_button.set_sensitive(true);
                self.discard_button.set_sensitive(true);
                let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::tr!("Save failed"),
                    body: message,
                });
            }
            BrowseTabInput::FlashErrorRow(source) => {
                self.flash_error_row(&source);
            }
            BrowseTabInput::FocusInsertedDraft => {
                self.focus_inserted_draft();
            }
            BrowseTabInput::Undo => {
                use crate::services::change_tracker::UndoOp;
                let op = match crate::services::change_tracker::with_tab(self.tab_id, |t| t.undo()) {
                    Some(Some(op)) => op,
                    _ => return,
                };
                match op {
                    UndoOp::CellEdit {
                        row_key,
                        col,
                        prev_value,
                        ..
                    } => {
                        // Drafts hold the post-edit value in
                        // RowObject.cells (mirrored at edit time);
                        // reverting the visible value requires
                        // mutating the cell back. Persisted rows
                        // never mutate RowObject — the tracker is
                        // the single source of truth and
                        // connect_bind queries
                        // `current_cell_value` to overlay the
                        // pending edit. set_cell on a persisted
                        // row is a harmless no-op (the cell
                        // already holds the original).
                        if let Some(pos) = self.find_row_position_by_key(&row_key)
                            && let Some(row_obj) = self.row_object_at(pos)
                        {
                            row_obj.set_cell(col, prev_value);
                        }
                    }
                    UndoOp::Insert { draft_id, .. } => {
                        // The draft RowObject is still in the
                        // ListStore (prepended by InsertRow). Walk
                        // the store, find the row whose draft_id
                        // matches, remove it. The subsequent
                        // ChangedRows event for `Draft(id)` is a
                        // no-op once the row is gone.
                        if let Some(store) = self.list_store() {
                            let n = store.n_items();
                            for i in 0..n {
                                if let Some(obj) = store.item(i)
                                    && let Ok(row) = obj.downcast::<super::row_object::RowObject>()
                                    && row.draft_id() == Some(draft_id)
                                {
                                    store.remove(i);
                                    break;
                                }
                            }
                        }
                    }
                    UndoOp::Delete { row_key, .. } => {
                        // No RowObject mutation needed — the row was
                        // never visually removed; it stayed in the
                        // ListStore with a strikethrough overlay
                        // applied at bind time. The tracker's
                        // emit_changed → items_changed re-bind drops
                        // the strikethrough automatically because
                        // `row_state` returns Clean once the deletes
                        // entry is gone.
                        let _ = row_key;
                    }
                }
            }
            BrowseTabInput::Redo => {
                use crate::services::change_tracker::UndoOp;
                let op = match crate::services::change_tracker::with_tab(self.tab_id, |t| t.redo()) {
                    Some(Some(op)) => op,
                    _ => return,
                };
                match op {
                    UndoOp::CellEdit {
                        row_key,
                        col,
                        new_value,
                        ..
                    } => {
                        if let Some(pos) = self.find_row_position_by_key(&row_key)
                            && let Some(row_obj) = self.row_object_at(pos)
                        {
                            row_obj.set_cell(col, new_value);
                        }
                    }
                    UndoOp::Insert { draft_id, values } => {
                        // Re-add the draft RowObject. Match the
                        // original insert path: prepend at position 0.
                        if let Some(store) = self.list_store() {
                            let draft_row = super::row_object::RowObject::new_draft(draft_id, values);
                            store.insert(0, &draft_row);
                        }
                    }
                    UndoOp::Delete { .. } => {}
                }
            }
        }
    }
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

/// TSV cells can't carry literal tab / newline / CR without breaking
/// the row-or-column boundary. Spreadsheet apps (LibreOffice Calc,
/// Excel) interpret these as field separators on paste, so a cell
/// containing one would silently split. Replace with a single space
/// to preserve the row structure on paste; the user can paste into
/// a plain text view to see the originals.
fn escape_tsv_cell(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '\t' | '\n' | '\r' => out.push(' '),
            other => out.push(other),
        }
    }
    out
}

/// Collapse newlines / carriage returns to spaces, then squash any
/// resulting consecutive whitespace runs to a single space. Applied
/// at cell-edit commit time for non-JSON columns so a multi-line
/// clipboard paste into a single-line cell never reaches the SQL
/// layer with embedded `\n` — driver behaviour for that case is
/// type-specific (text columns store literally; numeric / date
/// columns parse-fail) and worth normalising up front.
fn normalize_single_line_input(text: &str) -> String {
    let replaced: String = text
        .chars()
        .map(|c| if matches!(c, '\n' | '\r') { ' ' } else { c })
        .collect();
    replaced.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Update the selection-count badge + Delete button tooltip in
/// response to a `MultiSelection` change. Hidden when 0–1 rows are
/// selected (single-row state has no scaling text need); shows
/// "{n} selected" + tweaks the Delete tooltip to "Delete {n}
/// selected rows (Delete)" once the user multi-selects.
fn update_selection_chrome(label: &gtk::Label, delete_button: &gtk::Button, n: u32) {
    if n <= 1 {
        label.set_visible(false);
        delete_button.set_tooltip_text(Some(&crate::tr!("Delete selected row (Delete)")));
        return;
    }
    let count = n.to_string();
    label.set_label(&crate::tr!("{n} selected").replace("{n}", &count));
    label.set_visible(true);
    delete_button.set_tooltip_text(Some(
        &crate::tr!("Delete {n} selected rows (Delete)").replace("{n}", &count),
    ));
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

/// Parse a user-typed cell value against the column's declared data
/// type. Returns `Err(message)` when the input is unambiguously wrong
/// for the column (invalid date, malformed UUID, required field empty,
/// etc.) so the caller can show a toast and revert the cell.
///
/// Rules:
/// - Empty + nullable (or has server default) → `Value::Null`. For
///   drafts this maps to INSERT-skip-column; for UPDATEs on NOT NULL
///   the DB will surface a clearer error than we can predict here.
/// - Empty + NOT NULL + no default → reject ("Field is required") —
///   the only path to bypass is to type a value or use the explicit
///   "Set to NULL" affordance.
/// - Non-empty → routed through the per-type parser. Native types
///   (Bool / Int / Float / Decimal / Date / Time / DateTime /
///   TimestampTz / Uuid / Json) bind correctly; `Text` is the
///   fallthrough for unclassified types.
fn parse_input_for_column(text: &str, col: Option<&ColumnInfo>) -> Result<Value, String> {
    let Some(col) = col else {
        return Ok(Value::Text(text.to_string()));
    };
    if text.is_empty() {
        if col.nullable || col.default_value.is_some() {
            return Ok(Value::Null);
        }
        return Err(crate::tr!("Field is required"));
    }
    let dt = col.data_type.to_ascii_lowercase();
    let trimmed = text.trim();
    match classify_type(&dt) {
        TypeKind::Bool => parse_bool_value(trimmed),
        TypeKind::Int => parse_int_value(trimmed),
        TypeKind::Float => parse_float_value(trimmed),
        TypeKind::Decimal => parse_decimal_value(trimmed),
        TypeKind::Uuid => parse_uuid_value(trimmed),
        TypeKind::Json => parse_json_value(trimmed),
        TypeKind::TimestampTz => parse_timestamptz_value(trimmed),
        TypeKind::DateTime => parse_datetime_value(trimmed),
        TypeKind::Date => parse_date_value(trimmed),
        TypeKind::Time => parse_time_value(trimmed),
        TypeKind::Text => Ok(Value::Text(text.to_string())),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TypeKind {
    Bool,
    Int,
    Float,
    Decimal,
    Uuid,
    Json,
    TimestampTz,
    DateTime,
    Date,
    Time,
    Text,
}

/// Map a lowercased `data_type` string to a coarse `TypeKind`. Order
/// of checks matters because several SQL types share substrings — for
/// example `timestamptz` / `timestamp with time zone` must be matched
/// before bare `timestamp`, and `tinyint(1)` (MySQL bool) must be
/// matched before generic `tinyint` / `int` patterns.
fn classify_type(dt: &str) -> TypeKind {
    // Postgres `format_type()` returns "bit(1)" for length-1 BIT
    // columns (not the bare "bit" the original guard expected).
    // Both forms classify as Bool so the cell renders as a checkbox
    // rather than a text editor that rejects "true"/"false" with
    // "Invalid integer".
    if matches!(dt, "bool" | "boolean" | "bit" | "bit(1)" | "tinyint(1)") {
        return TypeKind::Bool;
    }
    if dt.contains("uuid") {
        return TypeKind::Uuid;
    }
    if dt.contains("json") {
        return TypeKind::Json;
    }
    if dt.contains("timestamptz") || dt.contains("with time zone") {
        return TypeKind::TimestampTz;
    }
    if dt.contains("timestamp") || dt.contains("datetime") {
        return TypeKind::DateTime;
    }
    if dt == "date" || (dt.starts_with("date") && !dt.contains("datetime") && !dt.contains("time")) {
        return TypeKind::Date;
    }
    if dt == "time" || dt.starts_with("time(") || dt == "time without time zone" {
        return TypeKind::Time;
    }
    if matches!(dt, "decimal" | "numeric" | "money") || dt.starts_with("decimal(") || dt.starts_with("numeric(") {
        return TypeKind::Decimal;
    }
    if matches!(dt, "float" | "double" | "real" | "double precision") || dt.starts_with("float(") {
        return TypeKind::Float;
    }
    if matches!(
        dt,
        "int"
            | "int2"
            | "int4"
            | "int8"
            | "integer"
            | "smallint"
            | "bigint"
            | "tinyint"
            | "mediumint"
            | "serial"
            | "bigserial"
            | "smallserial"
    ) || dt.starts_with("int(")
        || dt.starts_with("integer(")
        || dt.starts_with("smallint(")
        || dt.starts_with("bigint(")
        || dt.starts_with("tinyint(")
        || dt.starts_with("mediumint(")
    {
        return TypeKind::Int;
    }
    TypeKind::Text
}

fn parse_bool_value(text: &str) -> Result<Value, String> {
    match text.to_ascii_lowercase().as_str() {
        "true" | "t" | "1" | "yes" | "y" | "on" => Ok(Value::Bool(true)),
        "false" | "f" | "0" | "no" | "n" | "off" => Ok(Value::Bool(false)),
        _ => Err(crate::tr!("Invalid boolean. Use true/false, yes/no, or 1/0.")),
    }
}

fn parse_int_value(text: &str) -> Result<Value, String> {
    text.parse::<i64>()
        .map(Value::Int)
        .map_err(|_| crate::tr!("Invalid integer"))
}

fn parse_float_value(text: &str) -> Result<Value, String> {
    text.parse::<f64>()
        .map(Value::Float)
        .map_err(|_| crate::tr!("Invalid number"))
}

fn parse_decimal_value(text: &str) -> Result<Value, String> {
    text.parse::<rust_decimal::Decimal>()
        .map(Value::Decimal)
        .map_err(|_| crate::tr!("Invalid decimal"))
}

fn parse_uuid_value(text: &str) -> Result<Value, String> {
    uuid::Uuid::parse_str(text)
        .map(Value::Uuid)
        .map_err(|_| crate::tr!("Invalid UUID. Expected 8-4-4-4-12 hex digits."))
}

fn parse_json_value(text: &str) -> Result<Value, String> {
    serde_json::from_str::<serde_json::Value>(text)
        .map(Value::Json)
        .map_err(|e| crate::tr!("Invalid JSON: {error}").replace("{error}", &e.to_string()))
}

fn parse_timestamptz_value(text: &str) -> Result<Value, String> {
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(text) {
        return Ok(Value::TimestampTz(dt.with_timezone(&chrono::Utc)));
    }
    Err(crate::tr!(
        "Invalid timestamp. Use ISO 8601, e.g. 2024-01-15T14:30:00Z."
    ))
}

fn parse_datetime_value(text: &str) -> Result<Value, String> {
    let formats = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S%.f",
        "%Y-%m-%dT%H:%M:%S%.f",
    ];
    for fmt in &formats {
        if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(text, fmt) {
            return Ok(Value::DateTime(dt));
        }
    }
    Err(crate::tr!("Invalid datetime. Use YYYY-MM-DD HH:MM:SS."))
}

fn parse_date_value(text: &str) -> Result<Value, String> {
    chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d")
        .map(Value::Date)
        .map_err(|_| crate::tr!("Invalid date. Use YYYY-MM-DD."))
}

fn parse_time_value(text: &str) -> Result<Value, String> {
    let formats = ["%H:%M:%S", "%H:%M:%S%.f", "%H:%M"];
    for fmt in &formats {
        if let Ok(t) = chrono::NaiveTime::parse_from_str(text, fmt) {
            return Ok(Value::Time(t));
        }
    }
    Err(crate::tr!("Invalid time. Use HH:MM:SS."))
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
    bar: gtk::ActionBar,
    first_button: gtk::Button,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    last_button: gtk::Button,
    paginator_label: gtk::Label,
    selection_label: gtk::Label,
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
    use super::{TypeKind, classify_type, format_thousands, parse_input_for_column};
    use tablepro_core::{ColumnInfo, Value};

    fn col(data_type: &str, nullable: bool) -> ColumnInfo {
        ColumnInfo {
            name: "x".into(),
            data_type: data_type.into(),
            nullable,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        }
    }

    fn col_with_default(data_type: &str, default: &str) -> ColumnInfo {
        let mut c = col(data_type, false);
        c.default_value = Some(default.into());
        c
    }

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

    #[test]
    fn classify_disambiguates_overlapping_types() {
        assert_eq!(classify_type("tinyint(1)"), TypeKind::Bool);
        assert_eq!(classify_type("tinyint"), TypeKind::Int);
        assert_eq!(classify_type("uuid"), TypeKind::Uuid);
        assert_eq!(classify_type("jsonb"), TypeKind::Json);
        assert_eq!(classify_type("timestamptz"), TypeKind::TimestampTz);
        assert_eq!(classify_type("timestamp with time zone"), TypeKind::TimestampTz);
        assert_eq!(classify_type("timestamp without time zone"), TypeKind::DateTime);
        assert_eq!(classify_type("timestamp"), TypeKind::DateTime);
        assert_eq!(classify_type("datetime"), TypeKind::DateTime);
        assert_eq!(classify_type("date"), TypeKind::Date);
        assert_eq!(classify_type("time"), TypeKind::Time);
        assert_eq!(classify_type("integer"), TypeKind::Int);
        assert_eq!(classify_type("int4"), TypeKind::Int);
        assert_eq!(classify_type("bigint"), TypeKind::Int);
        assert_eq!(classify_type("decimal(10,2)"), TypeKind::Decimal);
        assert_eq!(classify_type("numeric"), TypeKind::Decimal);
        assert_eq!(classify_type("double precision"), TypeKind::Float);
        assert_eq!(classify_type("real"), TypeKind::Float);
        assert_eq!(classify_type("text"), TypeKind::Text);
        assert_eq!(classify_type("varchar(255)"), TypeKind::Text);
        // "interval" must NOT be classified as Int even though it
        // contains "int".
        assert_eq!(classify_type("interval"), TypeKind::Text);
    }

    #[test]
    fn empty_on_nullable_yields_null() {
        let r = parse_input_for_column("", Some(&col("text", true))).unwrap();
        assert!(matches!(r, Value::Null));
    }

    #[test]
    fn empty_on_not_null_with_default_yields_null() {
        let r = parse_input_for_column("", Some(&col_with_default("timestamp", "now()"))).unwrap();
        assert!(matches!(r, Value::Null));
    }

    #[test]
    fn empty_on_not_null_no_default_is_rejected() {
        let r = parse_input_for_column("", Some(&col("text", false)));
        assert!(r.is_err());
        assert!(r.unwrap_err().contains("required"));
    }

    #[test]
    fn parses_int_decimal_float_bool() {
        assert!(matches!(
            parse_input_for_column("42", Some(&col("integer", false))).unwrap(),
            Value::Int(42)
        ));
        assert!(matches!(
            parse_input_for_column("3.14", Some(&col("real", false))).unwrap(),
            Value::Float(_)
        ));
        assert!(matches!(
            parse_input_for_column("99.99", Some(&col("decimal(10,2)", false))).unwrap(),
            Value::Decimal(_)
        ));
        assert!(matches!(
            parse_input_for_column("yes", Some(&col("boolean", false))).unwrap(),
            Value::Bool(true)
        ));
        assert!(matches!(
            parse_input_for_column("0", Some(&col("tinyint(1)", false))).unwrap(),
            Value::Bool(false)
        ));
    }

    #[test]
    fn parses_uuid_json_date_time_datetime_timestamptz() {
        let uuid = parse_input_for_column("550e8400-e29b-41d4-a716-446655440000", Some(&col("uuid", false))).unwrap();
        assert!(matches!(uuid, Value::Uuid(_)));

        let json = parse_input_for_column(r#"{"a":1}"#, Some(&col("jsonb", false))).unwrap();
        assert!(matches!(json, Value::Json(_)));

        let date = parse_input_for_column("2024-01-15", Some(&col("date", false))).unwrap();
        assert!(matches!(date, Value::Date(_)));

        let time = parse_input_for_column("14:30:00", Some(&col("time", false))).unwrap();
        assert!(matches!(time, Value::Time(_)));
        let time_short = parse_input_for_column("14:30", Some(&col("time", false))).unwrap();
        assert!(matches!(time_short, Value::Time(_)));

        let datetime = parse_input_for_column("2024-01-15 14:30:00", Some(&col("timestamp", false))).unwrap();
        assert!(matches!(datetime, Value::DateTime(_)));
        let datetime_t = parse_input_for_column("2024-01-15T14:30:00", Some(&col("datetime", false))).unwrap();
        assert!(matches!(datetime_t, Value::DateTime(_)));

        let ts = parse_input_for_column("2024-01-15T14:30:00Z", Some(&col("timestamptz", false))).unwrap();
        assert!(matches!(ts, Value::TimestampTz(_)));
    }

    #[test]
    fn rejects_invalid_type_specific_input() {
        assert!(parse_input_for_column("not-a-number", Some(&col("integer", false))).is_err());
        assert!(parse_input_for_column("not-a-uuid", Some(&col("uuid", false))).is_err());
        assert!(parse_input_for_column("{not json", Some(&col("jsonb", false))).is_err());
        assert!(parse_input_for_column("2024/01/15", Some(&col("date", false))).is_err());
        assert!(parse_input_for_column("13:00:99", Some(&col("time", false))).is_err());
        assert!(parse_input_for_column("not-a-date", Some(&col("timestamp", false))).is_err());
        assert!(parse_input_for_column("maybe", Some(&col("boolean", false))).is_err());
    }

    #[test]
    fn unknown_type_falls_through_to_text() {
        let r = parse_input_for_column("anything goes here", Some(&col("varchar(255)", false))).unwrap();
        assert!(matches!(r, Value::Text(_)));
    }

    #[test]
    fn null_sentinel_typed_literally_is_text() {
        // Column is text + nullable; user types "<NULL>" literally. We
        // do NOT special-case the sentinel string — only an actually-
        // empty input becomes Null. The visual sentinel is cleared by
        // the grid before edit (grid.rs install_double_click_to_edit),
        // so this path is only reached if the user typed `<NULL>` on
        // purpose.
        let r = parse_input_for_column("<NULL>", Some(&col("text", true))).unwrap();
        match r {
            Value::Text(s) => assert_eq!(s, "<NULL>"),
            other => panic!("expected Text(\"<NULL>\") got {other:?}"),
        }
    }
}
