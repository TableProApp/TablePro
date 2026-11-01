mod load;
mod references;
mod rows;
mod save;
mod total;

use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::filter::{FilterOp, FilterRule};
use tablepro_core::meta::{RowCountEstimate, RowIdentity, TableEstimate};
use tablepro_core::{ColumnInfo, DriverError, FilterSet, LossPhase, QueryResult, Value};
use tablepro_session::Session;
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeReply};

use super::{BrowseTab, BrowseTabInit, DataInput, GridInput, PagingInput, RowTotal, SaveInput, TableFilter};
use crate::services::change_tracker::RowKey;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{FakeSession, LogLines, MemorySettings, drain_main_context, wait_until};
use crate::ui::data_grid::{DataGrid, GridCell, GridRequest, GridRow};

pub(super) const WAIT: Duration = Duration::from_secs(10);

/// A column carrying the server's spelling and the kind it means.
#[expect(
    clippy::disallowed_methods,
    reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
)]
fn col(data_type: &str, nullable: bool) -> ColumnInfo {
    let kind = tablepro_core::column::classify_type_name(data_type);
    ColumnInfo {
        name: "x".into(),
        column_type: tablepro_core::column::ColumnType {
            name: data_type.to_owned(),
            dynamic_storage: tablepro_core::column::has_dynamic_storage(&kind),
            kind,
            catalog: Some(tablepro_core::column::CatalogType {
                declaration: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
                cast_target: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
            }),
            read_form: tablepro_core::column::ReadForm::Native,
        },
        nullable,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: tablepro_core::column::ColumnDefault::None,
        comment: None,
    }
}

#[expect(
    clippy::disallowed_methods,
    reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
)]
pub(super) fn col_with_default(data_type: &str, default: &str) -> ColumnInfo {
    let mut c = col(data_type, false);
    c.default = tablepro_core::column::ColumnDefault::Expression(
        tablepro_core::column::SqlExpression::from_catalog_text(default),
    );
    c
}

pub(super) fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

pub(super) fn rows(names: &[&str]) -> QueryResult {
    let columns = [column("id", true), column("name", false)];
    QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        names
            .iter()
            .enumerate()
            .map(|(id, name)| vec![Value::Int(i64::try_from(id).unwrap()), Value::Text((*name).to_owned())])
            .collect(),
    )
}

/// A connection that serves the table's catalog and count, with the
/// page left to the test.
pub(super) fn serving_table() -> ConnectionScript {
    let mut script = ConnectionScript::default();
    script
        .fetch_columns
        .always(FakeReply::ok(vec![column("id", true), column("name", false)]));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(2));
    script
        .table_estimate
        .always(FakeReply::ok(estimate(RowCountEstimate::Approximate(2))));
    script.probe.always(FakeReply::ok(()));
    script.fetch_outbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.fetch_inbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    script
}

pub(super) fn estimate(rows: RowCountEstimate) -> TableEstimate {
    TableEstimate {
        rows,
        heap_blocks: None,
    }
}

pub(super) struct Harness {
    pub(super) tab: Option<BrowseTab>,
    pub(super) tracker: TabTrackerHandle,
    others: Vec<BrowseTab>,
    pub(super) session: Arc<Session>,
    pub(super) connection: Arc<FakeConnection>,
    pub(super) fake: FakeSession,
    pub(super) stores: TabStores,
    runtime: Option<crate::runtime::AppRuntime>,
}

impl Harness {
    pub(super) fn open(script: ConnectionScript, reconnects: impl IntoIterator<Item = FakeEstablish>) -> Self {
        Self::open_filtered(script, reconnects, FilterSet::default())
    }

    /// The tab opens under `saved`, the filter the table was left with.
    pub(super) fn open_filtered(
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
        saved: FilterSet,
    ) -> Self {
        Self::open_with(script, reconnects, saved, TableFilter::Remembered, false)
    }

    /// The tab opens under `filter`, the table having been left with
    /// `saved`.
    pub(super) fn open_on(script: ConnectionScript, saved: FilterSet, filter: TableFilter) -> Self {
        Self::open_with(script, [], saved, filter, false)
    }

    pub(super) fn open_read_only(script: ConnectionScript) -> Self {
        Self::open_with(script, [], FilterSet::default(), TableFilter::Remembered, true)
    }

    fn open_with(
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
        saved: FilterSet,
        filter: TableFilter,
        read_only: bool,
    ) -> Self {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, reconnects, runtime.tasks());
        let stores = TabStores::new();
        let tracker = TabTrackerHandle::default();
        let tab = table_tab(
            &fake.session,
            &runtime,
            &stores,
            Opening {
                saved,
                filter,
                tracker: tracker.clone(),
                read_only,
                ..Opening::users()
            },
        );
        Self {
            tab: Some(tab),
            tracker,
            others: Vec::new(),
            session: fake.session.clone(),
            connection: fake.connection.clone(),
            fake,
            stores,
            runtime: Some(runtime),
        }
    }

    pub(super) fn tab(&self) -> &BrowseTab {
        self.tab.as_ref().expect("the tab is open")
    }

    pub(super) fn grid(&self) -> DataGrid {
        self.tab().grid()
    }

    /// Another tab on the same table and session.
    pub(super) fn open_another(&mut self) -> BrowseTab {
        let runtime = self.runtime.as_ref().expect("the runtime is running");
        let tab = users_tab(&self.session, runtime, &self.stores);
        self.others.push(tab.clone());
        tab
    }

    /// The second cell of each saved row on screen, empty while the
    /// tab shows no page.
    pub(super) fn shown(&self) -> Vec<Value> {
        self.saved_rows()
            .iter()
            .filter_map(|row| row.cells()?.get(1).cloned())
            .collect()
    }

    /// The saved rows the grid holds for the page on screen.
    pub(super) fn saved_rows(&self) -> Vec<GridRow> {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        let shows_page = self
            .tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .is_some_and(|model| model.page.is_some());
        match shows_page {
            true => self
                .grid()
                .store()
                .rows()
                .filter(|row| row.draft_id().is_none())
                .collect(),
            false => Vec::new(),
        }
    }

    pub(super) fn visible_page(&self) -> Option<String> {
        self.tab().imp_stack().visible_child_name().map(|name| name.to_string())
    }

    /// The row the grid shows at `position`, drafts included.
    pub(super) fn grid_row(&self, position: u32) -> GridRow {
        self.grid().store().row(position).expect("a row")
    }

    pub(super) fn selection(&self) -> gtk4::MultiSelection {
        self.grid().selection()
    }

    pub(super) fn store(&self) -> gtk4::gio::ListStore {
        self.grid().store().list().clone()
    }

    pub(super) fn drafts(&self) -> u32 {
        self.grid().store().draft_count()
    }

    /// What the tab does with the delta of a tracker write it made.
    pub(super) fn apply_delta(&self, delta: &TrackerDelta) {
        self.grid().apply_delta(delta);
        drain_main_context();
    }

    /// Run `grid.<name>` as the tab's buttons and menus reach it.
    pub(super) fn activate_grid(&self, name: &str) {
        self.tab()
            .activate_action(&format!("grid.{name}"), None)
            .unwrap_or_else(|_| panic!("the tab reaches no grid.{name}"));
        drain_main_context();
    }

    pub(super) fn grid_enabled(&self, name: &str) -> bool {
        self.grid()
            .actions()
            .lookup_action(name)
            .is_some_and(|action| action.is_enabled())
    }

    /// Select the rows at `positions` and nothing else.
    pub(super) fn select(&self, positions: std::ops::Range<u32>) {
        let selection = self.selection();
        let picked = gtk4::Bitset::new_range(positions.start, positions.end - positions.start);
        selection.set_selection(&picked, &gtk4::Bitset::new_range(0, selection.n_items()));
        drain_main_context();
    }
}

/// The tab in a window, so its grid draws cells.
pub(super) struct Shown(pub(super) gtk4::Window);

impl Shown {
    pub(super) fn new(tab: &BrowseTab) -> Self {
        let window = gtk4::Window::new();
        window.set_default_size(600, 400);
        window.set_child(Some(tab));
        window.present();
        Self(window)
    }
}

impl Drop for Shown {
    fn drop(&mut self) {
        crate::test_support::drop_focus(&self.0);
        self.0.set_child(None::<&gtk4::Widget>);
        self.0.destroy();
    }
}

/// The files and preferences a test tab reads.
pub(super) struct TabStores {
    root: tempfile::TempDir,
    pub(super) settings: MemorySettings,
}

impl TabStores {
    pub(super) fn new() -> Self {
        Self {
            root: tempfile::tempdir().expect("tempdir"),
            settings: MemorySettings::new(),
        }
    }
}

pub(super) fn users_tab(session: &Arc<Session>, runtime: &crate::runtime::AppRuntime, stores: &TabStores) -> BrowseTab {
    table_tab(session, runtime, stores, Opening::users())
}

/// What a test tab opens on.
pub(super) struct Opening {
    pub(super) table: &'static str,
    /// The filter the table was left with.
    pub(super) saved: FilterSet,
    pub(super) filter: TableFilter,
    pub(super) tracker: TabTrackerHandle,
    pub(super) read_only: bool,
}

impl Opening {
    pub(super) fn users() -> Self {
        Self {
            table: "users",
            saved: FilterSet::default(),
            filter: TableFilter::Remembered,
            tracker: TabTrackerHandle::default(),
            read_only: false,
        }
    }
}

pub(super) fn table_tab(
    session: &Arc<Session>,
    runtime: &crate::runtime::AppRuntime,
    stores: &TabStores,
    opening: Opening,
) -> BrowseTab {
    let Opening {
        table,
        saved,
        filter,
        tracker,
        read_only,
    } = opening;
    let tasks = runtime.tasks();
    let connection_id = uuid::Uuid::new_v4();
    let root = stores.root.path();
    let filter_settings = crate::persistence::FilterSettingsStore::load(root.join("filters.json"), &tasks);
    filter_settings.set_filters(connection_id, None, table, saved);
    BrowseTab::new(BrowseTabInit {
        tracker,
        schema: None,
        table: table.to_owned(),
        connection_id: Some(connection_id),
        read_only,
        page_size: 100,
        initial_offset: 0,
        initial_sort: None,
        filter,
        column_widths: crate::persistence::ColumnWidthStore::load(root.join("column-widths.json"), &tasks),
        filter_settings,
        session: session.clone(),
        tasks,
        deadlines: Arc::new(tablepro_session::operation::DefaultDeadlines::new(
            tablepro_core::LivenessPolicy::DESKTOP,
        )),
        settings: stores.settings.get().clone(),
        first_load: crate::ui::tab_load::FirstLoad::Now,
    })
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.tab.take();
        self.others.clear();
        drain_main_context();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

impl BrowseTab {
    fn imp_stack(&self) -> gtk4::Stack {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        self.imp().inner_stack.get()
    }
}

pub(super) fn text(values: &[&str]) -> Vec<Value> {
    values.iter().map(|value| Value::Text((*value).to_owned())).collect()
}

pub(super) fn not_null(column: &str) -> FilterSet {
    FilterSet {
        rules: vec![FilterRule {
            column: column.to_owned(),
            op: FilterOp::IsNotNull,
            value: None,
        }],
        ..FilterSet::default()
    }
}

pub(super) fn not_null_name() -> FilterSet {
    not_null("name")
}

pub(super) fn key(id: i64) -> RowKey {
    RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
}

/// `names` keyed from `first` on, as the next page of `rows` would be.
pub(super) fn rows_from(first: i64, names: &[&str]) -> QueryResult {
    let mut page = rows(names);
    for (row, id) in page.rows.iter_mut().zip(first..) {
        row[0] = Value::Int(id);
    }
    page
}

/// A browse page served first, then `next` for every page after it.
pub(super) fn paging(first: QueryResult, next: QueryResult) -> ConnectionScript {
    let mut script = serving_table();
    script.count_rows.always(FakeReply::ok(1_000));
    script
        .query_bound
        .once(FakeReply::ok(first))
        .always(FakeReply::ok(next));
    script
}

/// Rows enough for a full page, so Next has somewhere to go.
pub(super) fn full_page(first: i64) -> QueryResult {
    let names: Vec<String> = (0..100).map(|n| format!("row {n}")).collect();
    let names: Vec<&str> = names.iter().map(String::as_str).collect();
    rows_from(first, &names)
}

pub(super) fn toasts(tab: &BrowseTab) -> std::rc::Rc<std::cell::RefCell<Vec<String>>> {
    let toasts = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = toasts.clone();
    tab.connect_toast(move |_, text| sink.borrow_mut().push(text));
    toasts
}

/// The titles of the data columns on screen, without the row numbers.
pub(super) fn header_titles(tab: &BrowseTab) -> Vec<String> {
    let grid = tab.grid();
    let numbers = grid.row_numbers_column();
    let columns = grid.column_view().columns();
    (0..columns.n_items())
        .filter_map(|position| columns.item(position).and_downcast::<gtk4::ColumnViewColumn>())
        .filter(|column| Some(column) != numbers.as_ref())
        .filter_map(|column| column.title().map(|title| title.to_string()))
        .collect()
}

pub(super) fn headers_are(tab: &BrowseTab, expected: &[&str]) -> bool {
    header_titles(tab) == expected
}

pub(super) fn column_view(tab: &BrowseTab) -> gtk4::ColumnView {
    tab.grid().column_view()
}

/// The cell showing `column` of the saved row keyed `id`, once drawn.
pub(super) fn grid_cell_of(tab: &BrowseTab, id: i64, column: usize) -> GridCell {
    let key = key(id);
    let mut found = None;
    wait_until(WAIT, || {
        found = crate::test_support::descendants(&column_view(tab))
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .find(|cell| cell.column() == column && cell.row().is_some_and(|row| row.key().as_ref() == Some(&key)));
        found.is_some()
    })
    .expect("the row's cell is drawn");
    found.expect("a cell")
}

/// Focus the cell of data column `column` at `position`, as the arrow
/// keys do.
pub(super) fn focus_cell(harness: &Harness, position: u32, column: usize) -> GridCell {
    let mut focused = None;
    wait_until(WAIT, || {
        focused = harness.grid().focus_cell(position, column);
        focused.is_some()
    })
    .expect("the cell takes the focus");
    focused.expect("a focused cell")
}

/// Open `cell`'s one-line editor and type `text` over its value.
pub(super) fn type_into(harness: &Harness, cell: &GridCell, text: &str) -> gtk4::Text {
    let grid = harness.grid();
    assert!(grid.edit().edit_cell(cell), "the cell took no edit");
    let editor = grid
        .edit()
        .open_text()
        .expect("the cell did not open its one-line editor");
    editor.set_text(text);
    editor
}

pub(super) fn rename(id: i64, from: &str, to: &str) -> TrackerEdit {
    TrackerEdit::Cell {
        row_key: key(id),
        col: 1,
        original: Value::Text(from.to_owned()),
        value: tablepro_core::edit::CellInput::Value(Value::Text(to.to_owned())),
    }
}

/// What a page and the tab's own reads asked for, in order.
pub(super) fn page_queries(harness: &Harness) -> Vec<String> {
    harness
        .connection
        .observed_sql("query_bound")
        .into_iter()
        .flatten()
        .collect()
}

pub(super) fn pending_bar_shown(tab: &BrowseTab) -> bool {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    tab.imp().pending_bar.imp().revealer.reveals_child()
}

fn action_enabled(tab: &BrowseTab, name: &str) -> bool {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let model = tab.imp().model.borrow();
    let actions = &model.as_ref().expect("the tab has a model").actions;
    let action = match name {
        "save" => &actions.save,
        "undo" => &actions.undo,
        "redo" => &actions.redo,
        "count-rows" => &actions.count_rows,
        _ => panic!("browse.{name} does not follow the tab"),
    };
    action.is_enabled()
}

#[gtk4::test]
fn stale_page_reply_ignored() {
    let mut script = serving_table();
    script
        .query_bound
        .when_sql_contains("IS NOT NULL", FakeReply::ok(rows(&["filtered"])))
        .once(FakeReply::Late {
            after: Duration::from_millis(300),
            outcome: Ok(rows(&["unfiltered", "stale"])),
        });
    let harness = Harness::open(script, []);
    let counters = harness.connection.counters();
    wait_until(WAIT, || CallCounters::get(&counters.query_bound) == 1).expect("the first page was asked for");

    harness.tab().send(PagingInput::FilterApplied(not_null_name()));
    wait_until(WAIT, || harness.shown() == text(&["filtered"])).expect("the filtered page");
    std::thread::sleep(Duration::from_millis(500));
    drain_main_context();

    assert_eq!(CallCounters::get(&counters.query_bound), 2);
    assert_eq!(
        harness.shown(),
        text(&["filtered"]),
        "the reply to the page the filter replaced was shown"
    );
}

#[gtk4::test]
fn closing_tab_cancels_call_options_token() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::UntilStopped);
    let mut harness = Harness::open(script, []);
    let counters = harness.connection.counters();
    wait_until(WAIT, || CallCounters::get(&counters.query_bound) == 1).expect("the page was asked for");
    let weak = harness.tab().downgrade();

    harness.tab.take();
    drain_main_context();

    assert!(weak.upgrade().is_none(), "something kept the closed tab alive");
    wait_until(WAIT, || CallCounters::get(&counters.stopped) == 1).expect("closing the tab did not stop its page read");
}

#[gtk4::test]
fn failed_load_refetches_after_link_replace() {
    let mut first = serving_table();
    first.query_bound.always(FakeReply::err(DriverError::ConnectionLost {
        during: LossPhase::Statement,
    }));
    let mut second = serving_table();
    second.query_bound.always(FakeReply::ok(rows(&["after reconnect"])));
    let harness = Harness::open(first, [FakeEstablish::Connect(second)]);

    wait_until(WAIT, || harness.shown() == text(&["after reconnect"]))
        .expect("the page read again after the reconnect");

    let replacement = harness.fake.replacement();
    assert_eq!(harness.session.link_generation().get(), 1);
    assert_eq!(CallCounters::get(&replacement.counters().query_bound), 1);
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
}

#[gtk4::test]
fn loaded_tab_keeps_data_on_link_replace() {
    let mut first = serving_table();
    first.query_bound.always(FakeReply::ok(rows(&["kept"])));
    let harness = Harness::open(first, [FakeEstablish::Connect(serving_table())]);
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    let counters = harness.connection.counters();

    harness.connection.mark_lost();
    wait_until(WAIT, || harness.session.link_generation().get() == 1).expect("the reconnect");
    std::thread::sleep(Duration::from_millis(200));
    drain_main_context();

    let replacement = harness.fake.replacement();
    assert_eq!(CallCounters::get(&counters.query_bound), 1);
    assert_eq!(
        CallCounters::get(&replacement.counters().query_bound),
        0,
        "a tab with nothing failed read its page again"
    );
    assert_eq!(harness.shown(), text(&["kept"]));
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
}

#[gtk4::test]
fn schema_change_reads_the_columns_again_then_the_page() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["row"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["row"])).expect("the first page");
    let counters = harness.connection.counters();

    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(DataInput::SchemaChanged);
    wait_until(WAIT, || CallCounters::get(&counters.query_bound) == 2).expect("the page after the columns");

    assert_eq!(CallCounters::get(&counters.fetch_columns), 2);
}

#[gtk4::test]
fn a_renamed_column_reaches_the_grid_headers() {
    let renamed = [column("id", true), column("full_name", false)];
    let mut script = serving_table();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(renamed.to_vec()));
    script
        .query_bound
        .when_sql_contains(
            "full_name",
            FakeReply::ok(QueryResult::new(
                renamed.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
                vec![vec![Value::Int(0), Value::Text("Ada".to_owned())]],
            )),
        )
        .always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || headers_are(harness.tab(), &["id", "name"])).expect("the first grid");
    let grid = harness.grid();

    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(DataInput::SchemaChanged);

    wait_until(WAIT, || headers_are(harness.tab(), &["id", "full_name"]))
        .expect("the grid kept the old column's header");
    wait_until(WAIT, || harness.shown() == text(&["Ada"])).expect("the page under the new columns");
    assert_eq!(harness.grid(), grid, "the tab built another grid");
}

#[gtk4::test]
fn a_tab_that_opens_reads_the_columns_the_table_has_now() {
    let altered = [column("id", true), column("name", false), column("email", false)];
    let mut script = serving_table();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(altered.to_vec()));
    script
        .query_bound
        .when_sql_contains(
            "email",
            FakeReply::ok(QueryResult::new(
                altered.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
                vec![vec![
                    Value::Int(0),
                    Value::Text("Ada".to_owned()),
                    Value::Text("ada@example.com".to_owned()),
                ]],
            )),
        )
        .always(FakeReply::ok(rows(&["Ada"])));
    let mut harness = Harness::open(script, []);
    wait_until(WAIT, || header_titles(harness.tab()).contains(&"name".to_owned())).expect("the first grid");

    // The column was added by a client the catalog never hears from.
    let reopened = harness.open_another();

    wait_until(WAIT, || header_titles(&reopened).contains(&"email".to_owned()))
        .expect("the new tab was built from the columns cached when the first one opened");
    assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 2);
}

#[gtk4::test]
fn a_failed_page_under_a_new_filter_shows_the_error() {
    let mut script = serving_table();
    script
        .query_bound
        .when_sql_contains("IS NOT NULL", FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(rows(&["unfiltered"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["unfiltered"])).expect("the first page");

    harness.tab().send(PagingInput::FilterApplied(not_null_name()));

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error"))
        .expect("rows read without the filter stayed under it");
    assert_eq!(
        harness.shown(),
        text(&["unfiltered"]),
        "the error page let go of the page the paginator still points back to"
    );
}

#[gtk4::test]
fn a_saved_filter_on_a_dropped_column_shows_the_error() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["unfiltered"])));
    let harness = Harness::open_filtered(script, [], not_null("nickname"));
    let counters = harness.connection.counters();

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the tab stayed on its spinner");

    assert_eq!(CallCounters::get(&counters.query_bound), 0);
    assert_eq!(CallCounters::get(&counters.count_rows), 0);
}

#[gtk4::test]
fn a_filter_column_renamed_away_drops_the_rows_for_the_error() {
    let renamed = [column("id", true), column("full_name", false)];
    let mut script = serving_table();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(renamed.to_vec()));
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open_filtered(script, [], not_null_name());
    wait_until(WAIT, || harness.shown() == text(&["Ada"])).expect("the first page");

    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(DataInput::SchemaChanged);

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error"))
        .expect("the rows read under the old columns stayed on screen");
    assert!(harness.shown().is_empty());
    assert_eq!(
        harness.grid().row_count(),
        0,
        "the grid kept rows read under the old columns"
    );
    assert_eq!(harness.tab().columns(), renamed);
}

#[gtk4::test]
fn a_refresh_under_a_filter_that_no_longer_fits_keeps_the_rows() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["kept"])));
    let harness = Harness::open_filtered(script, [], not_null_name());
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    let toasts = toasts(harness.tab());
    let banner = {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        harness.tab().imp().stale_banner.get()
    };

    harness.tab().send(PagingInput::FilterApplied(not_null("nickname")));
    harness.tab().send(PagingInput::Refresh);
    wait_until(WAIT, || banner.is_revealed()).expect("the filter that does not fit was not reported");
    drain_main_context();

    let reason = banner.tooltip_text().map(|text| text.to_string()).unwrap_or_default();
    assert!(reason.starts_with("This filter cannot be applied"), "{reason}");
    assert!(
        toasts.borrow().is_empty(),
        "a toast that fades said it: {:?}",
        toasts.borrow()
    );
    assert_eq!(harness.shown(), text(&["kept"]));
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
}

#[gtk4::test]
fn no_dim_label_class_remains() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    let _shown = Shown::new(harness.tab());
    grid_cell_of(harness.tab(), 0, 1);
    harness.tab().send(PagingInput::ToggleFilterStrip);

    let dimmed: Vec<String> = crate::test_support::descendants(harness.tab())
        .into_iter()
        .filter(|widget| widget.has_css_class("dim-label"))
        .map(|widget| widget.type_().name().to_owned())
        .collect();

    assert!(dimmed.is_empty(), "still dim-label: {dimmed:?}");
}

#[gtk4::test]
fn export_and_save_reach_the_window_as_signals() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let exported = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let saved = std::rc::Rc::new(std::cell::Cell::new(0));
    let export_sink = exported.clone();
    harness.tab().connect_export_results(move |_, offer| {
        export_sink
            .borrow_mut()
            .push((offer.name, offer.origin.shown().row_count()));
    });
    let save_sink = saved.clone();
    harness
        .tab()
        .connect_save_requested(move |_| save_sink.set(save_sink.get() + 1));

    harness.tab().send(GridInput::Export);
    harness.activate_grid("insert-row");
    harness.tab().send(SaveInput::CommitSave);

    assert_eq!(*exported.borrow(), [("users".to_owned(), Some(2))]);
    assert_eq!(saved.get(), 1);
}

/// The grid's own Export hands over the rows as it shows them, which
/// the tab offers as the page of its table.
#[gtk4::test]
fn the_grids_export_goes_out_as_the_tabs_offer() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let offers = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = offers.clone();
    harness
        .tab()
        .connect_export_results(move |_, offer| sink.borrow_mut().push(offer));

    harness.activate_grid("export");

    let offers = offers.borrow();
    let [offer] = offers.as_slice() else {
        panic!("one export, not {}", offers.len());
    };
    assert_eq!(offer.name, "users");
    assert_eq!(offer.origin.shown().row_count(), Some(2));
    assert!(matches!(
        &offer.origin,
        crate::ui::export::ExportOrigin::Browse {
            query: crate::ui::export::ExportQuery::Table(_),
            ..
        }
    ));
}

#[gtk4::test]
fn current_page_export_includes_pending_edits() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    // The total is read after the page, on its own.
    wait_until(WAIT, || {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        harness
            .tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .is_some_and(|model| model.total != RowTotal::Unknown)
    })
    .expect("the table's total");
    harness.apply_delta(&harness.tracker.apply(rename(0, "Ada", "Ada Lovelace")));
    let offers = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = offers.clone();
    harness
        .tab()
        .connect_export_results(move |_, offer| sink.borrow_mut().push(offer));

    harness.tab().send(GridInput::Export);

    let offers = offers.borrow();
    let [offer] = offers.as_slice() else {
        panic!("one export, not {}", offers.len());
    };
    let crate::ui::export::ExportOrigin::Browse {
        page: crate::ui::export::ExportSource::Rows { rows, .. },
        query: crate::ui::export::ExportQuery::Table(table),
        total,
        has_unsaved_changes,
    } = &offer.origin
    else {
        panic!("not a browse page: {:?}", offer.origin);
    };
    let names: Vec<Value> = rows.iter().map(|row| row.to_values()[1].clone()).collect();
    assert_eq!(
        names,
        [Value::Text("Ada Lovelace".to_owned()), Value::Text("Grace".to_owned())]
    );
    assert!(*has_unsaved_changes, "the pending rename went unmentioned");
    assert_eq!(table.table.name, "users");
    assert_eq!(
        table
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        ["id", "name"]
    );
    assert_ne!(*total, RowTotal::Unknown, "the table's total was not handed over");
    assert!(offer.session.is_some(), "a read of every row has no session");
}

#[gtk4::test]
fn browse_tab_grid_and_filter_strip_freed_after_drop() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["row"])));
    let mut harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["row"])).expect("the first page");
    let strip = {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        harness
            .tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .map(|model| model.filter_strip.downgrade())
            .expect("the filter strip")
    };
    let grid = harness.grid().downgrade();
    let tab = harness.tab().downgrade();

    harness.tab.take();
    drain_main_context();

    assert!(strip.upgrade().is_none(), "the filter strip outlived its tab");
    assert!(grid.upgrade().is_none(), "the grid outlived its tab");
    assert!(tab.upgrade().is_none(), "the browse tab outlived its last reference");
}

fn named_actions(controller: &gtk4::ShortcutController) -> Vec<String> {
    crate::test_support::shortcut_keys::shortcuts(controller)
        .iter()
        .filter_map(|shortcut| shortcut.action().and_downcast::<gtk4::NamedAction>())
        .map(|action| action.action_name().to_string())
        .collect()
}

fn table_actions(owner: crate::application::ShortcutOwner) -> Vec<String> {
    use crate::application::{ACCELERATORS, AcceleratorScope};
    ACCELERATORS
        .iter()
        .filter(|entry| matches!(entry.scope, AcceleratorScope::Local { owner: of, .. } if of == owner))
        .flat_map(|entry| entry.triggers.iter().map(|_| entry.action.to_owned()))
        .collect()
}

/// The grid's keys sit on the grid, so a text field elsewhere in the tab
/// keeps Ctrl+C, Delete and Escape, and the tab holds only its own.
#[gtk4::test]
fn the_tab_holds_only_its_own_keys_and_the_grid_its_own() {
    use crate::application::ShortcutOwner;
    use crate::test_support::shortcut_keys::{owner_controller, shortcut_controllers};
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");

    let tab = owner_controller(harness.tab(), ShortcutOwner::BrowseTab).expect("the tab's shortcuts");

    assert_eq!(named_actions(&tab), table_actions(ShortcutOwner::BrowseTab));
    let on_the_tab: Vec<String> = shortcut_controllers(harness.tab())
        .iter()
        .flat_map(named_actions)
        .collect();
    assert_eq!(on_the_tab, table_actions(ShortcutOwner::BrowseTab), "{on_the_tab:?}");
    assert!(
        owner_controller(&harness.grid(), ShortcutOwner::Grid).is_some(),
        "the grid's keys are not on the grid"
    );
}

/// A bubble key on the tab reaches it only when no class on the way up
/// from the focus binds it first. Text fields keep their own keys, as
/// Ctrl+Z, by design.
#[gtk4::test]
fn browse_tab_keys_are_not_class_bindings_inside_the_tab() {
    use crate::application::{ACCELERATORS, AcceleratorScope, ShortcutOwner};
    use crate::test_support::shortcut_keys::{class_keys_on_focus_paths, keystroke};
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let _shown = Shown::new(harness.tab());

    let class_keys = class_keys_on_focus_paths(harness.tab(), |widget| {
        widget.is::<gtk4::Text>() || widget.is::<gtk4::TextView>()
    });

    assert!(
        class_keys.contains(&keystroke("Page_Up")),
        "the grid's own bindings were not found, so the check reads nothing"
    );
    for entry in ACCELERATORS {
        let AcceleratorScope::Local {
            owner: ShortcutOwner::BrowseTab,
            phase,
        } = entry.scope
        else {
            continue;
        };
        assert_eq!(phase, gtk4::PropagationPhase::Bubble, "{}", entry.action);
        for accel in entry.triggers {
            assert!(
                !class_keys.contains(&keystroke(accel)),
                "{accel} of {} never reaches the tab",
                entry.action
            );
        }
    }
}

#[gtk4::test]
fn browse_actions_follow_the_tab() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let activate = |name: &str| {
        harness
            .tab()
            .activate_action(&format!("browse.{name}"), None)
            .expect("the browse group");
        drain_main_context();
    };
    let label = harness.tab().imp().selection_label.get();

    assert!(harness.grid_enabled("insert-row"), "a keyed table refused Ctrl+N");
    assert!(!action_enabled(harness.tab(), "save"), "Save with nothing to save");
    assert!(!action_enabled(harness.tab(), "undo"));
    assert!(!harness.grid_enabled("copy"), "Ctrl+C with no rows selected");
    assert!(!label.is_visible());

    harness.selection().select_all();
    drain_main_context();
    assert!(harness.grid_enabled("copy"));
    assert!(harness.grid_enabled("clear-selection"));
    assert!(label.is_visible());
    assert_eq!(label.label(), "2 selected · press Delete to remove");
    harness.activate_grid("clear-selection");
    assert!(
        !harness.grid_enabled("clear-selection"),
        "the selection was not cleared"
    );
    assert!(!label.is_visible(), "the count outlived the selection");

    harness.activate_grid("insert-row");
    assert_eq!(harness.drafts(), 1, "the toolbar's Insert did not reach the grid");
    assert!(action_enabled(harness.tab(), "save"));
    assert!(action_enabled(harness.tab(), "undo"));
    assert!(!action_enabled(harness.tab(), "redo"));
    activate("undo");
    assert_eq!(harness.tracker.pending_count(), 0, "browse.undo did not undo");
    assert_eq!(harness.drafts(), 0, "the undone row stayed in the grid");
    assert!(action_enabled(harness.tab(), "redo"));
    assert!(!action_enabled(harness.tab(), "save"));
    activate("redo");
    assert_eq!(harness.drafts(), 1, "browse.redo did not bring the row back");
    assert!(harness.grid_row(0).draft_id().is_some(), "the redone row is not on top");
}

/// These press real keys on the X display every test shares; nextest runs
/// them with no other test beside them.
mod real_keys {
    use super::*;

    /// A real key press: the field's own undo runs before the tab's, so
    /// Ctrl+Z in a filter field takes back typing, not a row edit.
    #[gtk4::test]
    fn ctrl_z_in_filter_entry_undoes_text_not_rows() {
        use gtk4::gdk::{Key, ModifierType};
        // A key reaches a top bar only once its reveal has ended.
        if let Some(settings) = gtk4::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let mut script = serving_table();
        script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
        let harness = Harness::open(script, []);
        wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
        let shown = Shown::new(harness.tab());
        crate::test_support::KeyInjector::focus_only(&shown.0);
        wait_until(Duration::from_secs(2), || shown.0.is_active()).expect("the window to take the focus");
        harness.apply_delta(&harness.tracker.apply(rename(0, "Ada", "Ada Lovelace")));
        assert_eq!(harness.tracker.pending_count(), 1);
        let strip = {
            use gtk4::subclass::prelude::ObjectSubclassIsExt;
            let model = harness.tab().imp().model.borrow();
            model
                .as_ref()
                .map(|model| model.filter_strip.clone())
                .expect("the filter strip")
        };

        harness.tab().send(PagingInput::ToggleFilterStrip);
        let mut field = None;
        wait_until(Duration::from_secs(2), || {
            field = gtk4::prelude::GtkWindowExt::focus(&shown.0)
                .filter(|focus| focus.is_ancestor(&strip))
                .and_then(|focus| focus.downcast::<gtk4::Text>().ok());
            field.is_some()
        })
        .expect("the strip's field takes the focus");
        let field = field.expect("the focused field");
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        keys.press(Key::x, ModifierType::empty()).expect("the key press");
        wait_until(Duration::from_secs(2), || field.text() == "x").expect("the typing to land");
        keys.press(Key::z, ModifierType::CONTROL_MASK).expect("the key press");

        wait_until(Duration::from_secs(2), || field.text().is_empty()).expect("Ctrl+Z to take back the typing");
        assert_eq!(harness.tracker.pending_count(), 1, "Ctrl+Z undid the row edit");
    }
}

#[gtk4::test]
fn refresh_asks_the_window_and_filter_opens_the_strip() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let refreshes = crate::test_support::SignalLog::connect(harness.tab(), "refresh-requested", |_| ());
    let strip_open = || {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        let model = harness.tab().imp().model.borrow();
        model.as_ref().is_some_and(|model| model.filter_strip.revealed())
    };

    harness
        .tab()
        .activate_action("browse.refresh", None)
        .expect("the browse group");
    harness
        .tab()
        .activate_action("browse.filter", None)
        .expect("the browse group");

    assert_eq!(refreshes.count(), 1);
    assert!(strip_open());
}

/// The grid's Filter by Value reaches the strip, which shows the rule
/// and reads the rows under it.
#[gtk4::test]
fn filter_by_value_adds_the_rule_to_the_strip_and_reads_under_it() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let mut script = serving_table();
    script
        .query_bound
        .when_sql_contains("IS NOT NULL", FakeReply::ok(rows(&["Ada"])))
        .always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let rule = not_null_name().rules.remove(0);

    harness
        .tab()
        .send(GridInput::Request(GridRequest::FilterByValue(rule.clone())));

    wait_until(WAIT, || harness.shown() == text(&["Ada"])).expect("the rows under the rule");
    assert_eq!(harness.tab().applied_filter().rules, [rule]);
    let model = harness.tab().imp().model.borrow();
    let strip = &model.as_ref().expect("the tab is open").filter_strip;
    assert!(strip.revealed(), "the strip that says why the rows changed is hidden");
}

#[gtk4::test]
fn a_read_only_tab_refuses_insert_row() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open_read_only(script);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");

    assert!(!harness.grid_enabled("insert-row"));
    assert!(
        !harness.tab().imp().insert_button.is_visible(),
        "a read-only tab offers Insert"
    );
    harness.tab().activate_action("grid.insert-row", None).ok();
    harness.select(0..1);
    assert!(!harness.grid_enabled("duplicate-rows"));
    harness.tab().activate_action("grid.duplicate-rows", None).ok();
    drain_main_context();

    assert_eq!(harness.tracker.pending_count(), 0, "a read-only table took a new row");
}

#[gtk4::test]
fn browse_buttons_announce_their_keys() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let imp = harness.tab().imp();

    for (name, button) in [
        ("insert row", imp.insert_button.get().upcast::<gtk4::Widget>()),
        ("delete rows", imp.delete_button.get().upcast()),
        ("row details", imp.details_toggle.get().upcast()),
        ("filter", imp.filter_button.get().upcast()),
        ("previous page", imp.pager_bar.imp().prev_button.get().upcast()),
        ("next page", imp.pager_bar.imp().next_button.get().upcast()),
        ("save", imp.pending_bar.imp().save_button.get().upcast()),
    ] {
        assert!(
            gtk4::test_accessible_has_property(&button, gtk4::AccessibleProperty::KeyShortcuts),
            "the {name} button announces no keys"
        );
    }
}

/// The toolbar's Row Details names the grid's action, so it opens the
/// grid's pane and follows it when the pane closes itself.
#[gtk4::test]
fn the_row_details_toggle_shows_the_grids_pane() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let toggle = harness.tab().imp().details_toggle.get();
    let details = || {
        harness
            .grid()
            .actions()
            .action_state("show-details")
            .and_then(|state| state.get::<bool>())
            .unwrap_or(false)
    };
    wait_until(WAIT, || toggle.is_sensitive()).expect("the toggle reaches the grid");

    toggle.emit_clicked();
    drain_main_context();
    assert!(details(), "the toggle did not open the pane");

    harness
        .grid()
        .actions()
        .change_action_state("show-details", &false.to_variant());
    drain_main_context();
    assert!(!toggle.is_active(), "the toggle stayed on with the pane closed");
}

/// A page that takes the selected rows away leaves GtkMultiSelection
/// without a selection-changed, so the tab reads the selection again.
#[gtk4::test]
fn a_new_page_turns_off_the_selection_keys() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus", "Ken"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    harness.select(0..3);
    assert!(harness.grid_enabled("copy"));
    assert!(harness.grid_enabled("clear-selection"));
    assert!(harness.tab().imp().selection_label.is_visible());

    harness.tab().send(PagingInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus", "Ken"])).expect("the next page");

    assert!(
        harness.selection().selection().is_empty(),
        "the new page kept a selection"
    );
    assert!(!harness.grid_enabled("copy"), "Ctrl+C stayed on with nothing selected");
    assert!(
        !harness.grid_enabled("clear-selection"),
        "Escape stayed on with nothing selected"
    );
    assert!(
        !harness.tab().imp().selection_label.is_visible(),
        "the footer still counts the rows that left"
    );
}

#[gtk4::test]
fn a_failed_row_count_logs_its_category_and_not_the_server_message() {
    let lines = LogLines::default();
    let _logging = tracing::subscriber::set_default(lines.subscriber(tracing::Level::DEBUG));
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    script.count_rows.always(FakeReply::err(DriverError::reported(
        tablepro_core::ServerDiagnostics::new(None, "You have an error in your SQL syntax near 'hunter2' at line 1"),
    )));
    let _harness = Harness::open(script, []);

    wait_until(WAIT, || lines.text().contains("the row count could not be read")).expect("the failure is logged");

    let text = lines.text();
    assert!(!text.contains("hunter2"), "{text}");
    assert!(text.contains("category=Some(Server)"), "{text}");
}

#[gtk4::test]
fn icon_buttons_are_labelled_without_accelerator_hints() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    let imp = harness.tab().imp();

    assert_eq!(
        crate::test_support::unlabelled_icon_buttons(harness.tab()),
        Vec::<String>::new()
    );
    assert_eq!(
        crate::test_support::tooltips_with_keys(harness.tab()),
        Vec::<String>::new()
    );
    for button in [
        imp.insert_button.get().upcast::<gtk4::Widget>(),
        imp.details_toggle.get().upcast(),
        imp.pager_bar.imp().next_button.get().upcast(),
        imp.pending_bar.imp().save_button.get().upcast(),
    ] {
        assert!(
            gtk4::test_accessible_has_property(&button, gtk4::AccessibleProperty::KeyShortcuts),
            "{:?} does not announce its keys",
            button.tooltip_text()
        );
    }
}

#[gtk4::test]
fn filter_button_tooltip_counts_the_active_rules() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let mut two_rules = not_null_name();
    two_rules.rules.extend(not_null("id").rules);
    let harness = Harness::open_filtered(script, [], two_rules);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let button = harness.tab().imp().filter_button.get();
    assert_eq!(button.tooltip_text().as_deref(), Some("2 Filter Rules Active"));

    harness.tab().send(PagingInput::FilterApplied(not_null_name()));
    wait_until(WAIT, || {
        button.tooltip_text().as_deref() == Some("1 Filter Rule Active")
    })
    .expect("the tooltip kept the old count");

    harness.tab().send(PagingInput::FilterApplied(FilterSet::default()));
    wait_until(WAIT, || button.tooltip_text().as_deref() == Some("Filter Rows"))
        .expect("the tooltip still counted rules after they were cleared");
}

/// A table with a key pages past the edge row of the page on screen,
/// so a page deep into it costs what the first does. The row numbers
/// still count from the first page.
#[gtk4::test]
fn a_keyed_table_pages_by_the_edge_rows_key_not_by_offset() {
    let mut script = serving_table();
    script.count_rows.always(FakeReply::ok(1_000));
    script.query_bound.always(FakeReply::ok(full_page(0)));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    let read = |count: usize| {
        wait_until(WAIT, || {
            page_queries(&harness).len() == count && !harness.tab().is_loading()
        })
        .expect("the page read");
    };

    harness.tab().send(PagingInput::NextPage);
    read(2);
    harness.tab().send(PagingInput::NextPage);
    read(3);
    harness.tab().send(PagingInput::PrevPage);
    read(4);

    let queries = page_queries(&harness);
    for query in &queries[1..] {
        assert!(!query.contains("OFFSET"), "{query}");
    }
    assert!(queries[1].contains(" > ("), "{}", queries[1]);
    assert!(
        queries[3].contains(" < (") && queries[3].contains(" DESC"),
        "Previous reads back from the page's first row: {}",
        queries[3]
    );
    assert_eq!(harness.tab().current_offset(), 100);
}

/// A sort of the user's has ties a key cannot resume from, so it pages
/// by offset.
#[gtk4::test]
fn a_sorted_table_pages_by_offset() {
    let mut script = serving_table();
    // A count below the second page would move it back to the first.
    script.count_rows.always(FakeReply::ok(1_000));
    script.query_bound.always(FakeReply::ok(full_page(0)));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    harness.grid().sort_by(Some((1, true)));
    wait_until(WAIT, || {
        page_queries(&harness).len() == 2 && !harness.tab().is_loading()
    })
    .expect("the sorted page");

    harness.tab().send(PagingInput::NextPage);
    wait_until(WAIT, || page_queries(&harness).len() == 3).expect("the next page");

    let next = page_queries(&harness).pop().unwrap_or_default();
    assert!(next.ends_with("LIMIT 100 OFFSET 100"), "{next}");
}

/// A header click asks the server for the page in that order, from the
/// first page, and a sort the tab makes shows on the header.
#[gtk4::test]
fn a_header_click_reads_the_first_page_in_that_order() {
    let mut script = serving_table();
    script.count_rows.always(FakeReply::ok(1_000));
    script.query_bound.always(FakeReply::ok(full_page(0)));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    harness.tab().send(PagingInput::NextPage);
    wait_until(WAIT, || {
        harness.tab().current_offset() == 100 && !harness.tab().is_loading()
    })
    .expect("the second page");
    let grid = harness.grid();
    let name = grid.data_view_column(1).expect("the name column");

    column_view(harness.tab()).sort_by_column(Some(&name), gtk4::SortType::Descending);
    drain_main_context();

    assert_eq!(harness.tab().current_sort(), Some((1, false)));
    wait_until(WAIT, || {
        page_queries(&harness).len() == 3 && !harness.tab().is_loading()
    })
    .expect("the sorted page");
    let sorted = page_queries(&harness).pop().unwrap_or_default();
    assert!(sorted.contains("ORDER BY \"users\".\"name\" DESC"), "{sorted}");
    assert_eq!(harness.tab().current_offset(), 0, "a new order kept the page it was on");

    harness.grid().sort_by(None);
    let sorter = column_view(harness.tab())
        .sorter()
        .and_downcast::<gtk4::ColumnViewSorter>()
        .expect("the view's sorter");
    assert_eq!(sorter.primary_sort_column(), None, "the header kept the cleared sort");
}

/// A document's field whose name has a dot cannot be named by a sort or
/// an update (ADR 0026), so its header takes no sort and its cells no
/// edit, while a plain field takes both.
#[gtk4::test]
fn a_dotted_field_of_a_document_neither_sorts_nor_takes_an_edit() {
    let columns = [column("_id", true), column("a.b", false)];
    let mut script = serving_table();
    script.dialect = Arc::new(tablepro_driver_mongodb::MongoDialect);
    script.fetch_columns = Default::default();
    script.fetch_columns.always(FakeReply::ok(columns.to_vec()));
    script.row_identity = Default::default();
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["_id".to_owned()],
    }));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), Value::Text("nested".to_owned())]],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["nested"])).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let grid = harness.grid();

    assert!(!grid.grid_columns()[1].addressable);
    assert!(
        grid.data_view_column(1).is_some_and(|column| column.sorter().is_none()),
        "the dotted field's header sorts"
    );
    assert!(
        grid.data_view_column(0).is_some_and(|column| column.sorter().is_some()),
        "a plain field lost its sort"
    );
    let cell = grid_cell_of(harness.tab(), 0, 1);
    assert_eq!(cell.lock(), Some(crate::services::grid::CellLock::Unaddressable));
    assert!(!grid.edit().edit_cell(&cell), "the dotted field opened for editing");
    assert_eq!(harness.tracker.pending_count(), 0);
}
