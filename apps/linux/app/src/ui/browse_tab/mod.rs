use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::prelude::*;
use relm4::{adw, gtk};
use uuid::Uuid;

use tablepro_core::{ColumnInfo, ForeignKeyInfo, QueryResult, Value};

use crate::ui::grid::{GridMsg, TabGridContext, build_column_view};

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;
/// Bulk-delete safety net: when the user marks at least this many
/// rows pending-delete in one shot, surface a confirmation dialog
/// before tracking. The marker is reversible via Discard / Ctrl+Z,
/// but a 200-row Ctrl+A → Delete sequence is destructive enough at
/// a glance that an explicit confirmation matches GNOME Files'
/// "Delete N items?" pattern.
const BULK_DELETE_CONFIRM_THRESHOLD: usize = 10;

/// MongoDB is schemaless: page metadata carries the collection-wide BSON kind
/// census. Use it for rendering and edits so mixed columns stay read-only.
pub(super) fn columns_for_browse_page(
    driver_id: &str,
    loaded_columns: &[ColumnInfo],
    page: Option<&QueryResult>,
) -> Vec<ColumnInfo> {
    if driver_id == "mongodb"
        && let Some(page) = page
        && !page.columns.is_empty()
    {
        return page.columns.clone();
    }
    loaded_columns.to_vec()
}

fn projection_for_loaded_page(result: &QueryResult, projection: Option<Vec<usize>>) -> Option<Vec<usize>> {
    if result.rows.is_empty() && result.columns.is_empty() {
        None
    } else {
        projection
    }
}

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
    pub persistence: crate::services::persistence_stores::PersistenceStores,
    pub database: std::sync::Arc<crate::services::database_service::DatabaseService>,
}

pub struct BrowseTab {
    tab_id: Uuid,
    schema: Option<String>,
    table: String,
    driver_id: String,
    connection_id: Option<Uuid>,
    read_only: bool,
    persistence: crate::services::persistence_stores::PersistenceStores,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,

    current_offset: u64,
    page_size: u64,
    current_sort: Option<(usize, bool)>,
    /// Server-side WHERE filter applied to every fetch. Persisted per
    /// `(connection_id, schema, table)` via `services::filter_settings`.
    /// Empty FilterSet means no WHERE clause; updates restart pagination
    /// at offset 0 since filtered counts shift.
    current_filter: tablepro_core::FilterSet,
    current_columns: Vec<ColumnInfo>,
    /// Foreign keys declared on this table, fetched alongside
    /// `current_columns`. Drives the cell value picker; empty for a
    /// driver that doesn't report foreign keys or a table with none.
    foreign_keys: Vec<ForeignKeyInfo>,
    current_result: Option<std::sync::Arc<QueryResult>>,
    current_projection: Option<Vec<usize>>,
    /// Last row's primary-key values from the most recent page. Used
    /// for keyset seek when offset exceeds `KEYSET_OFFSET_THRESHOLD`.
    keyset_cursor: Option<Vec<tablepro_core::Value>>,
    current_selection: Option<gtk::MultiSelection>,
    current_total_rows: Option<u64>,
    page_requests: PageRequestTracker,
    row_count_requests: RowCountRequestTracker,
    cell_value_requests: CellValueRequestTracker,

    inner_stack: gtk::Stack,
    grid_holder: gtk::Box,
    /// Live reference to the current page's `gtk::ColumnView`. Replaced
    /// on every `RowsLoaded`. Used by the inline-Insert flow to
    /// scroll-to-and-focus the freshly-prepended draft row.
    current_column_view: Option<gtk::ColumnView>,
    /// Column metadata used when the live factories were last built.
    /// Type and editability changes can require a rebuild even when the
    /// number of columns stays the same (for example, MongoDB page types).
    rendered_columns: Vec<ColumnInfo>,
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
    paginator_label: gtk::Label,
    /// Live count of selected rows. Hidden when 0 or 1 rows are
    /// selected; shows "{n} selected" once the user shift-clicks
    /// or Ctrl+clicks to build a multi-row selection. Updated via
    /// the selection model's connect_selection_changed signal so it
    /// stays in sync without polling.
    selection_label: gtk::Label,
    inspector: crate::ui::row_inspector::RowInspector,
    first_button: gtk::Button,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    last_button: gtk::Button,
    /// Toolbar button that toggles the filter strip. Text-only
    /// ("Filter") because adwaita-icon-theme has no canonical
    /// symbolic icon for filtering and reusing a search/find icon
    /// would clash with the universal Ctrl+F shortcut now bound to
    /// this filter action. When the current filter has any rules, a
    /// small count badge appears next to the word; hidden otherwise.
    filter_button: gtk::Button,
    /// Count badge inside `filter_button`. Hidden when the filter
    /// is empty, otherwise reads `N` for N active rules.
    filter_badge: gtk::Label,
    /// Inline filter editor — slides in above the grid when
    /// revealed. Owned per-tab so the rules editor doesn't lose
    /// in-progress state if the user accidentally clicks outside it.
    filter_strip: Option<crate::ui::filter_strip::FilterStrip>,
    /// Insert row button — sits at the start of the paginator bar
    /// (`gtk::ActionBar` pack_start), separated from the nav arrows
    /// by the actionbar's start group. Delete affordance is gone
    /// from the toolbar — right-click "Delete row" + the Delete key
    /// shortcut cover the action surface (Files / Contacts pattern).
    insert_button: gtk::Button,
    /// Pending-changes footer (Save / Discard / count label) wrapped
    /// in a `GtkRevealer` so it slides into view only when there are
    /// unsaved edits. Lives as the BrowseTab's only bottom bar besides
    /// the paginator; reveal flips inside `refresh_pending_bar`.
    pending_revealer: gtk::Revealer,
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
        request: BrowsePageRequest,
        result: QueryResult,
        projected_columns: Option<Vec<usize>>,
    },
    /// Schema columns for the current table arrived (governs editability).
    ColumnsLoaded(Vec<ColumnInfo>),
    /// Foreign keys for the current table arrived. Drives the cell
    /// value picker; never blocks or errors the tab on its own.
    ForeignKeysLoaded(Vec<ForeignKeyInfo>),
    /// Total row count for paginator label.
    RowCountLoaded {
        request: BrowseRowCountRequest,
        count: u64,
    },
    /// The row-count query failed or returned something unparseable.
    /// Clears any previously known total instead of leaving it on
    /// screen as if it were still accurate.
    RowCountFailed(BrowseRowCountRequest),
    /// Show an error status page.
    ShowError(String),
    /// Re-issue the fetch for this tab (F5).
    Refresh,
    /// Clear a multi-row selection (Esc when 2+ rows are selected
    /// and no search bar / cell editor is active). Single-row
    /// selections are intentionally preserved — unselecting the
    /// only-row would strand the keyboard focus indicator.
    ClearSelection,
    /// Toggle the inline filter strip's reveal state. Wired to the
    /// Filter button + Ctrl+F action.
    ToggleFilterStrip,
    /// User confirmed a new filter set in the filter strip (or hit
    /// "Clear all" — that's an empty FilterSet). BrowseTab persists,
    /// resets pagination to offset 0, refreshes chrome, and
    /// re-fetches.
    FilterApplied(tablepro_core::FilterSet),
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
        row_key: Vec<Value>,
    },
    FilterByValue {
        column: String,
        value: tablepro_core::Value,
    },
    GridSetCellNull {
        row_position: u32,
        col_index: usize,
        row_key: Vec<Value>,
    },
    GridDeleteRowAt {
        row_position: u32,
        row_key: Vec<Value>,
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
    GridFetchCellValue {
        col_index: usize,
        column_name: String,
        row_key: Vec<Value>,
    },
    CellValueLoaded {
        request: BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        value: Value,
    },
    CellValueFailed(BrowseCellValueRequest, String),
    IncompleteRowData,
    ProjectionFailure,
    GridShowRowAsJson(String),
    GridExportResults(QueryResult),
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
    FetchCellValue {
        request: BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        row_key: Vec<Value>,
    },
    /// Display state changed in a way that should be persisted.
    StateChanged,
    /// Cell context-menu "Copy row as INSERT".
    CopyRowAsInsert {
        row_position: u32,
    },
    /// Generic clipboard-copy request from grid.
    CopyToClipboard(String),
    ShowRowAsJson(String),
    ExportResults {
        result: QueryResult,
        name: String,
    },
    /// Column-name vocabulary for editor autocomplete; App merges across tabs.
    SchemaWordsChanged(Vec<String>),
    /// Show a generic info dialog for "Cannot edit / select exactly one row".
    ShowSelectionAlert {
        title: String,
        body: String,
    },
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

mod chrome;
mod grid_messages;
mod grid_render;
mod requests;
mod row_ops;
mod selection;
#[cfg(test)]
mod tests;
mod value_parse;
mod value_view;

use chrome::*;
pub use requests::{BrowseCellValueRequest, BrowseLoadFailure, BrowsePageRequest, BrowseRowCountRequest};
use requests::{CellValueRequestTracker, PageRequestTracker, RowCountRequestTracker};
use selection::*;
use value_parse::*;

impl BrowseTab {
    pub fn snapshot(&self) -> Option<QueryResult> {
        let mut result = self.current_result.as_deref()?.clone();
        if self.current_projection.is_some() {
            if !result.rows.is_empty() {
                return None;
            }
            result.columns = self.current_columns.clone();
        }
        Some(result)
    }

    /// Cell values for the row at `position` in the live grid, which
    /// reflects the user's current sort and any prepended draft rows.
    /// `snapshot().rows` is fetch order only: with one pending draft,
    /// indexing it directly at a grid position off by one row -- position
    /// 1 (the first persisted row on screen) would read fetch-order row 1
    /// instead of row 0.
    pub fn row_cells_at(&self, position: u32) -> Option<Vec<Value>> {
        self.row_object_at(position)?.complete_cells()
    }

    pub fn has_unfetched_columns(&self) -> bool {
        self.current_projection.as_ref().is_some_and(|_| {
            self.current_result
                .as_ref()
                .is_some_and(|result| !result.rows.is_empty())
        })
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

    pub fn begin_page_request(&self) -> BrowsePageRequest {
        self.page_requests.begin(self.current_offset)
    }

    pub fn accepts_page_request(&self, request: BrowsePageRequest) -> bool {
        self.page_requests.accepts(request, self.current_offset)
    }

    pub fn begin_row_count_request(&self) -> BrowseRowCountRequest {
        self.row_count_requests.begin()
    }

    pub fn total_rows(&self) -> Option<u64> {
        self.current_total_rows
    }

    pub fn page_size(&self) -> u64 {
        self.page_size
    }

    pub fn current_sort(&self) -> Option<(usize, bool)> {
        self.current_sort
    }

    pub fn current_filter(&self) -> &tablepro_core::FilterSet {
        &self.current_filter
    }

    pub fn keyset_cursor(&self) -> Option<&[tablepro_core::Value]> {
        self.keyset_cursor.as_deref()
    }

    pub fn driver_id(&self) -> &str {
        &self.driver_id
    }

    fn emit_fetch_page(&self, sender: &ComponentSender<Self>) {
        let _ = sender.output(BrowseTabOutput::FetchPage);
    }

    fn emit_fetch_page_and_count(&self, sender: &ComponentSender<Self>) {
        let _ = sender.output(BrowseTabOutput::FetchPage);
        let _ = sender.output(BrowseTabOutput::FetchRowCount);
    }
}

impl SimpleComponent for BrowseTab {
    type Init = BrowseTabInit;
    type Input = BrowseTabInput;
    type Output = BrowseTabOutput;
    type Root = adw::ToolbarView;
    type Widgets = ();

    fn init_root() -> Self::Root {
        let root = adw::ToolbarView::new();
        // BrowseTab attaches directly to the workspace `AdwTabView`
        // now (no outer wrapper / view switcher), so the default
        // "raised" top-bar style draws a 1px separator above the grid
        // even when every top bar is collapsed (banners + filter
        // strip all start `revealed=false`). Flat style drops the
        // separator + the slot padding — the grid butts cleanly
        // against the bottom of the AdwTabBar.
        root.set_top_bar_style(adw::ToolbarStyle::Flat);
        root
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        // Open this tab's pending-changeset tracker. Closed in
        // workspace_tabs::close_workspace_tab_by_id when the tab is
        // removed. Idempotent — calling twice is a no-op.
        crate::services::change_tracker::open_tab(init.tab_id);

        // Restore the saved filter for this (connection, schema,
        // table) up front so both the model field and the inline
        // strip start with the same FilterSet.
        let initial_filter = init
            .connection_id
            .and_then(|id| {
                init.persistence
                    .filter_settings
                    .as_ref()
                    .map(|store| store.load(id, init.schema.as_deref(), &init.table))
            })
            .unwrap_or_default();

        let suppress_combo_emit = Rc::new(std::cell::Cell::new(true));
        let grid_holder = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .vexpand(true)
            .build();
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

        let paginator = Self::build_paginator(sender.clone(), init.page_size);
        let pending = Self::build_pending_revealer(sender.clone());

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
                "This table has no primary key. Row order is not stable; use the SQL editor to modify rows."
            ))
            .revealed(false)
            .build();

        // Filter strip — inline editor that slides down above the
        // grid when revealed. Ownership stays inside this BrowseTab
        // so the user's in-progress rule edits survive a click into
        // a cell or the SQL editor.
        let filter_set_for_strip = initial_filter.clone();
        let sender_for_strip = sender.clone();
        let on_apply_filter: std::rc::Rc<dyn Fn(tablepro_core::FilterSet)> = std::rc::Rc::new(move |set| {
            sender_for_strip.input(BrowseTabInput::FilterApplied(set));
        });
        let filter_strip = crate::ui::filter_strip::build(Vec::new(), filter_set_for_strip, on_apply_filter);

        // Banners + filter strip live in `AdwToolbarView::add_top_bar`
        // (the libadwaita-canonical placement). The default top-bar
        // slot allocates a thin strip even when every child banner is
        // collapsed; toggling `reveal-top-bars` on the slot itself
        // (based on whether ANY child is currently revealed) is the
        // idiomatic way to collapse the slot to 0px. The closure
        // re-runs on every banner / filter-strip reveal change.
        root.add_top_bar(&read_only_banner);
        root.add_top_bar(&no_pk_banner);
        root.add_top_bar(&filter_strip.widget);
        let inspector = bind_inspector(&inner_stack, &paginator.inspector_button);
        root.set_content(Some(inspector.widget()));

        let sync_top_bar_slot: std::rc::Rc<dyn Fn()> = {
            let root_for_sync = root.clone();
            let read_only_for_sync = read_only_banner.clone();
            let no_pk_for_sync = no_pk_banner.clone();
            let filter_for_sync = filter_strip.widget.clone();
            std::rc::Rc::new(move || {
                let any_revealed =
                    read_only_for_sync.is_revealed() || no_pk_for_sync.is_revealed() || filter_for_sync.reveals_child();
                root_for_sync.set_reveal_top_bars(any_revealed);
            })
        };
        sync_top_bar_slot();
        {
            let sync = sync_top_bar_slot.clone();
            read_only_banner.connect_revealed_notify(move |_| sync());
        }
        {
            let sync = sync_top_bar_slot.clone();
            no_pk_banner.connect_revealed_notify(move |_| sync());
        }
        {
            let sync = sync_top_bar_slot.clone();
            filter_strip.widget.connect_reveal_child_notify(move |_| sync());
        }
        // Bottom toolbars (stacked in `add_bottom_bar` call order):
        //   1. Paginator — always visible (nav + count + page size +
        //      Filter + Export).
        //   2. Pending revealer — slides into view only when the tab
        //      has unsaved edits (Save / Discard / "N unsaved" label).
        // Visual hierarchy: grid → paginator → pending (transient).
        root.add_bottom_bar(&paginator.bar);
        root.add_bottom_bar(&pending.widget);
        // Per-tab GridMsg channel: events from this tab's grid (sort
        // change, cell edits, context-menu actions) flow into this tab's
        // own input queue, which then re-emits them as outputs to App
        // tagged with this tab's id (via the forward closure App sets up).
        // Created up-front so tab-local shortcuts (Ctrl+Shift+N → set
        // focused cell to NULL) can route directly to the grid sender.
        let (grid_sender, grid_receiver) = relm4::channel::<GridMsg>();

        let sender_for_esc = sender.clone();
        let esc_shortcut = gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("Escape"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                // Esc on the grid (no edit in progress) clears a
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
            .trigger(&crate::ui::shortcut::parse("Delete"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_delete.input(BrowseTabInput::DeleteSelectedRow);
                glib::Propagation::Stop
            }))
            .build();
        let sender_for_insert = sender.clone();
        let insert_shortcut = gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("<Primary>n"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_insert.input(BrowseTabInput::InsertRow);
                glib::Propagation::Stop
            }))
            .build();
        let grid_sender_for_null = grid_sender.clone();
        let null_shortcut = gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("<Primary><Shift>n"))
            .action(&gtk::CallbackAction::new(move |widget, _| {
                let Some((row_position, col_index, row_key)) = crate::ui::grid::focused_cell_identity(widget) else {
                    return glib::Propagation::Proceed;
                };
                grid_sender_for_null
                    .send(GridMsg::SetCellNull {
                        row_position,
                        col_index,
                        row_key,
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
            .trigger(&crate::ui::shortcut::parse("<Primary>c"))
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
            .trigger(&crate::ui::shortcut::parse("<Primary>v"))
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
            .trigger(&crate::ui::shortcut::parse("<Primary>a"))
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
            .trigger(&crate::ui::shortcut::parse("Page_Up"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_pgup.input(BrowseTabInput::PrevPage);
                glib::Propagation::Stop
            }))
            .build();
        let sender_for_pgdn = sender.clone();
        let page_down_shortcut = gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("Page_Down"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_pgdn.input(BrowseTabInput::NextPage);
                glib::Propagation::Stop
            }))
            .build();
        // Home / End scoped to row navigation: jump to the first /
        // last visible row of the current page.
        let sender_for_home = sender.clone();
        let home_shortcut = gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("<Primary>Home"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                sender_for_home.input(BrowseTabInput::GoToFirstRow);
                glib::Propagation::Stop
            }))
            .build();
        let sender_for_end = sender.clone();
        let end_shortcut = gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("<Primary>End"))
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
        relm4::spawn_local(grid_receiver.forward(grid_input, grid_messages::to_input));

        let model = BrowseTab {
            tab_id: init.tab_id,
            schema: init.schema,
            table: init.table,
            driver_id: init.driver_id,
            connection_id: init.connection_id,
            read_only: init.read_only,
            persistence: init.persistence,
            database: init.database,
            current_offset: init.initial_offset,
            page_size: init.page_size,
            current_sort: init.initial_sort,
            current_filter: initial_filter,
            current_columns: Vec::new(),
            foreign_keys: Vec::new(),
            current_result: None,
            current_projection: None,
            keyset_cursor: None,
            current_selection: None,
            current_total_rows: None,
            page_requests: PageRequestTracker::default(),
            row_count_requests: RowCountRequestTracker::default(),
            cell_value_requests: CellValueRequestTracker::default(),
            inner_stack,
            grid_holder,
            current_column_view: None,
            rendered_columns: Vec::new(),
            read_only_banner,
            no_pk_banner,
            was_dirty: std::cell::Cell::new(false),
            pending_focus_restore: std::cell::RefCell::new(None),
            paginator_label: paginator.paginator_label,
            selection_label: paginator.selection_label,
            inspector,
            first_button: paginator.first_button,
            prev_button: paginator.prev_button,
            next_button: paginator.next_button,
            last_button: paginator.last_button,
            filter_button: paginator.filter_button,
            filter_badge: paginator.filter_badge,
            filter_strip: Some(filter_strip),
            insert_button: paginator.insert_button,
            pending_revealer: pending.widget,
            save_button: pending.save_button,
            discard_button: pending.discard_button,
            pending_label: pending.pending_label,
            grid_sender,
            suppress_combo_emit,
        };
        model.refresh_crud_buttons();
        model.refresh_pending_bar(0);
        // If the user has a saved filter on this (connection, schema,
        // table), the button picks up the .accent badge before the
        // first fetch returns so the filter state is visible from
        // the moment the tab opens.
        model.refresh_filter_chrome();

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
        // Fetch metadata first. The parent starts count + row queries only
        // after ColumnsLoaded, because deterministic ordering and typed
        // filters depend on this schema information.
        let _ = sender.output(BrowseTabOutput::FetchColumns);
        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            BrowseTabInput::RowsLoaded {
                request,
                result,
                projected_columns,
            } => {
                if !self.page_requests.accepts(request, self.current_offset) {
                    return;
                }
                // Driver fallback: every shipping driver derives the
                // `QueryResult.columns` list from the FIRST returned
                // row, so a zero-row page comes back with an empty
                // columns vector. The grid factory iterates that vector
                // to build column-view columns, which left the empty
                // table rendering as a column-less dark rectangle.
                // information_schema (via ColumnsLoaded) already gave
                // us the authoritative column list — substitute it in
                // so the headers render even when the page is empty.
                let projected_columns = projection_for_loaded_page(&result, projected_columns);
                let mut result = result;
                if result.columns.is_empty() && !self.current_columns.is_empty() {
                    result.columns = self.current_columns.clone();
                }
                self.current_columns = columns_for_browse_page(&self.driver_id, &self.current_columns, Some(&result));
                self.keyset_cursor =
                    extract_keyset_cursor(&self.current_columns, &result, projected_columns.as_deref());
                self.current_projection = projected_columns;
                self.current_result = Some(std::sync::Arc::new(result));
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
                let columns = columns_for_browse_page(&self.driver_id, &columns, self.current_result.as_deref());
                let words: Vec<String> = columns.iter().map(|c| c.name.clone()).collect();
                self.current_columns = columns.clone();
                // Late-arriving columns: if RowsLoaded already cached a
                // zero-row result with an empty `columns` vector (the
                // driver derives it from the first row), refill it now
                // so the upcoming `render_grid_if_ready` builds headers
                // against the real schema instead of an empty list.
                if let Some(result) = self.current_result.as_mut().map(std::sync::Arc::make_mut)
                    && result.columns.is_empty()
                {
                    result.columns = columns.clone();
                }
                self.refresh_crud_buttons();
                // Filter strip rebuilds against the new schema —
                // operator allowlists narrow per type, so a column
                // that switched from text to int needs its operator
                // dropdown refreshed.
                if let Some(strip) = self.filter_strip.as_ref() {
                    strip.update_columns(columns);
                }
                let _ = sender.output(BrowseTabOutput::SchemaWordsChanged(words));
                // If rows are already cached, render now with the proper
                // editability map. Otherwise wait for RowsLoaded.
                self.render_grid_if_ready(sender);
            }
            BrowseTabInput::ForeignKeysLoaded(foreign_keys) => {
                self.foreign_keys = foreign_keys;
            }
            BrowseTabInput::RowCountLoaded { request, count } => {
                if !self.row_count_requests.accepts(request) {
                    return;
                }
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
            BrowseTabInput::RowCountFailed(request) => {
                if !self.row_count_requests.accepts(request) {
                    return;
                }
                self.current_total_rows = None;
                self.last_button.set_sensitive(false);
                self.update_paginator_label();
            }
            BrowseTabInput::ShowError(message) => {
                // Clear any cached page state so a follow-up refresh
                // doesn't render against the stale snapshot before
                // RowsLoaded arrives. Paginator label is left empty
                // until next RowCountLoaded.
                self.current_result = None;
                self.current_total_rows = None;
                self.set_paginator_text("");
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
            BrowseTabInput::FilterByValue { column, value } => self.filter_by_value(&column, &value, &sender),
            BrowseTabInput::ToggleFilterStrip => {
                if let Some(strip) = self.filter_strip.as_ref() {
                    strip.toggle();
                }
            }
            BrowseTabInput::FilterApplied(set) => self.apply_filter(set, &sender),
            BrowseTabInput::FirstPage => {
                if self.current_offset > 0 {
                    self.current_offset = 0;
                    self.keyset_cursor = None;
                    let _ = sender.output(BrowseTabOutput::FetchPage);
                    let _ = sender.output(BrowseTabOutput::StateChanged);
                }
            }
            BrowseTabInput::PrevPage => {
                if self.current_offset >= self.page_size {
                    self.current_offset -= self.page_size;
                    // Reverse keyset is not implemented; clear cursor so
                    // the fetch falls back to OFFSET for this page.
                    self.keyset_cursor = None;
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
                    self.keyset_cursor = None;
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
                self.keyset_cursor = None;
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
                self.keyset_cursor = None;
                let _ = sender.output(BrowseTabOutput::FetchPage);
                let _ = sender.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::DuplicateRow { row_position } => self.handle_duplicate_row(row_position, sender),
            BrowseTabInput::InsertRow => self.handle_insert_row(sender),
            BrowseTabInput::DeleteSelectedRow => self.handle_delete_selected_row(sender),
            BrowseTabInput::GridCellEdited {
                row_position,
                col_index,
                new_value,
                row_key,
            } => self.handle_grid_cell_edited(row_position, col_index, new_value, row_key, sender),
            BrowseTabInput::GridSetCellNull {
                row_position,
                col_index,
                row_key,
            } => self.handle_grid_set_cell_null(row_position, col_index, row_key, sender),
            BrowseTabInput::GridDeleteRowAt { row_position, row_key } => {
                self.handle_grid_delete_row(row_position, row_key, sender)
            }
            BrowseTabInput::GridCopyRowAsInsert { row_position } => {
                self.handle_grid_copy_row_as_insert(row_position, sender)
            }
            BrowseTabInput::GridCopyToClipboard(text) => self.handle_grid_copy_to_clipboard(text, sender),
            BrowseTabInput::GridFetchCellValue {
                col_index,
                column_name,
                row_key,
            } => self.request_cell_value(col_index, column_name, row_key, sender),
            BrowseTabInput::CellValueLoaded {
                request,
                col_index,
                column_name,
                value,
            } => self.show_cell_value(request, col_index, column_name, value),
            BrowseTabInput::CellValueFailed(request, message) => {
                if self.cell_value_requests.accepts(request) {
                    let _ = sender.output(BrowseTabOutput::ShowToast(message));
                }
            }
            BrowseTabInput::IncompleteRowData => {
                let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                    "Some row values were not fetched. Show hidden columns and reload before copying or exporting."
                )));
            }
            BrowseTabInput::ProjectionFailure => self.show_projection_error(),
            BrowseTabInput::GridShowRowAsJson(text) => {
                let _ = sender.output(BrowseTabOutput::ShowRowAsJson(text));
            }
            BrowseTabInput::GridExportResults(result) => {
                let _ = sender.output(BrowseTabOutput::ExportResults {
                    result,
                    name: self.table_label(),
                });
            }
            BrowseTabInput::CopySelectedRowsAsTsv => self.handle_copy_selected_rows_as_tsv(sender),
            BrowseTabInput::PasteNotSupported => self.handle_paste_not_supported(sender),
            BrowseTabInput::SelectAllRows => self.handle_select_all_rows(),
            BrowseTabInput::GoToFirstRow => self.handle_go_to_first_row(),
            BrowseTabInput::GoToLastRow => self.handle_go_to_last_row(),
            BrowseTabInput::CommitSave => self.handle_commit_save(sender),
            BrowseTabInput::DiscardAll => self.handle_discard_all(sender),
            BrowseTabInput::PendingCountChanged(n) => self.handle_pending_count_changed(n, sender),
            BrowseTabInput::ChangedRows(keys) => self.handle_changed_rows(keys),
            BrowseTabInput::SaveCompleted => self.handle_save_completed(sender),
            BrowseTabInput::SaveFailed(message) => self.handle_save_failed(message, sender),
            BrowseTabInput::FlashErrorRow(source) => self.handle_flash_error_row(source),
            BrowseTabInput::FocusInsertedDraft => self.handle_focus_inserted_draft(),
            BrowseTabInput::Undo => self.handle_undo(),
            BrowseTabInput::Redo => self.handle_redo(),
        }
    }
}
