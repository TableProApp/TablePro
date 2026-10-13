use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::edit::EditContext;
use tablepro_core::filter::{FilterOp, FilterRule};
use tablepro_core::meta::RowIdentity;
use tablepro_core::{ColumnInfo, DriverError, FilterSet, LossPhase, QueryResult, Value};
use tablepro_session::Session;
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeReply};

use super::{
    BrowseTab, BrowseTabInit, BrowseTabInput, Effects, apply_visual_change, format_thousands, parse_input_for_column,
    persisted_key,
};
use crate::services::change_tracker::{RowKey, StatementSource};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_delta::{TrackerDelta, VisualChange};
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{FakeSession, drain_main_context, wait_until};
use crate::ui::grid::{GridCell, GridRowIndex, RowObject};

const WAIT: Duration = Duration::from_secs(10);

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
        default: tablepro_core::column::ColumnDefault::None,
        comment: None,
    }
}

#[expect(
    clippy::disallowed_methods,
    reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
)]
fn col_with_default(data_type: &str, default: &str) -> ColumnInfo {
    let mut c = col(data_type, false);
    c.default = tablepro_core::column::ColumnDefault::Expression(
        tablepro_core::column::SqlExpression::from_catalog_text(default),
    );
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
fn clearing_a_text_cell_stores_the_empty_string() {
    let cleared =
        parse_input_for_column("", Some(&col("text", true)), EditContext::UpdateRow).expect("an empty string");

    assert_eq!(cleared, Value::Text(String::new()));
}

#[test]
fn clearing_a_column_with_no_empty_value_yields_null() {
    let cleared = parse_input_for_column("", Some(&col("timestamp", true)), EditContext::UpdateRow).expect("a null");

    assert!(matches!(cleared, Value::Null));
}

#[test]
fn empty_on_not_null_with_default_is_left_to_the_server_only_in_a_draft() {
    let column = col_with_default("timestamp", "now()");

    let draft = parse_input_for_column("", Some(&column), EditContext::InsertDraft).unwrap();
    assert!(matches!(draft, Value::Null), "a draft leaves it to the default");

    let existing = parse_input_for_column("", Some(&column), EditContext::UpdateRow);
    assert!(existing.is_err(), "an UPDATE cannot ask for the default: {existing:?}");
}

#[test]
fn empty_on_a_required_column_with_no_empty_value_is_rejected() {
    let r = parse_input_for_column("", Some(&col("integer", false)), EditContext::UpdateRow);

    assert!(r.is_err());
    assert!(r.as_ref().is_err_and(|message| message.contains("required")), "{r:?}");
}

#[test]
fn parses_int_decimal_float_bool() {
    assert!(matches!(
        parse_input_for_column("42", Some(&col("integer", false)), EditContext::UpdateRow).unwrap(),
        Value::Int(42)
    ));
    assert!(matches!(
        parse_input_for_column("3.14", Some(&col("real", false)), EditContext::UpdateRow).unwrap(),
        Value::Float32(_)
    ));
    assert!(matches!(
        parse_input_for_column("99.99", Some(&col("decimal(10,2)", false)), EditContext::UpdateRow).unwrap(),
        Value::Decimal(_)
    ));
    assert!(matches!(
        parse_input_for_column("yes", Some(&col("boolean", false)), EditContext::UpdateRow).unwrap(),
        Value::Bool(true)
    ));
    // MySQL spells boolean as tinyint(1), so it parses as the integer it
    // is and the grid renders 0 and 1.
    assert!(matches!(
        parse_input_for_column("0", Some(&col("tinyint(1)", false)), EditContext::UpdateRow).unwrap(),
        Value::Int(0)
    ));
}

#[test]
fn parses_uuid_json_date_time_datetime_timestamptz() {
    let uuid = parse_input_for_column(
        "550e8400-e29b-41d4-a716-446655440000",
        Some(&col("uuid", false)),
        EditContext::UpdateRow,
    )
    .unwrap();
    assert!(matches!(uuid, Value::Uuid(_)));

    let json = parse_input_for_column(r#"{"a":1}"#, Some(&col("jsonb", false)), EditContext::UpdateRow).unwrap();
    assert!(matches!(json, Value::Json(_)));

    let date = parse_input_for_column("2024-01-15", Some(&col("date", false)), EditContext::UpdateRow).unwrap();
    assert!(matches!(date, Value::Date(_)));

    let time = parse_input_for_column("14:30:00", Some(&col("time", false)), EditContext::UpdateRow).unwrap();
    assert!(matches!(time, Value::Time(_)));
    let time_short = parse_input_for_column("14:30", Some(&col("time", false)), EditContext::UpdateRow).unwrap();
    assert!(matches!(time_short, Value::Time(_)));

    let datetime = parse_input_for_column(
        "2024-01-15 14:30:00",
        Some(&col("timestamp", false)),
        EditContext::UpdateRow,
    )
    .unwrap();
    assert!(matches!(datetime, Value::Timestamp(_)));
    let datetime_t = parse_input_for_column(
        "2024-01-15T14:30:00",
        Some(&col("datetime", false)),
        EditContext::UpdateRow,
    )
    .unwrap();
    assert!(matches!(datetime_t, Value::Timestamp(_)));
}

#[test]
fn rejects_invalid_type_specific_input() {
    assert!(parse_input_for_column("not-a-number", Some(&col("integer", false)), EditContext::UpdateRow).is_err());
    assert!(parse_input_for_column("not-a-uuid", Some(&col("uuid", false)), EditContext::UpdateRow).is_err());
    assert!(parse_input_for_column("{not json", Some(&col("jsonb", false)), EditContext::UpdateRow).is_err());
    assert!(parse_input_for_column("2024/01/15", Some(&col("date", false)), EditContext::UpdateRow).is_err());
    assert!(parse_input_for_column("13:00:99", Some(&col("time", false)), EditContext::UpdateRow).is_err());
    assert!(
        parse_input_for_column("128", Some(&col("tinyint", false)), EditContext::UpdateRow).is_err(),
        "a number past the column's range was accepted"
    );
    assert!(parse_input_for_column("not-a-date", Some(&col("timestamp", false)), EditContext::UpdateRow).is_err());
    assert!(parse_input_for_column("maybe", Some(&col("boolean", false)), EditContext::UpdateRow).is_err());
}

#[test]
fn unknown_type_falls_through_to_text() {
    let r = parse_input_for_column(
        "anything goes here",
        Some(&col("varchar(255)", false)),
        EditContext::UpdateRow,
    )
    .unwrap();
    assert!(matches!(r, Value::Text(_)));
}

#[test]
fn null_sentinel_typed_literally_is_text() {
    // Only an actually-empty input becomes NULL. The grid clears the
    // visual sentinel before an edit, so `<NULL>` here was typed on
    // purpose.
    let r = parse_input_for_column("<NULL>", Some(&col("text", true)), EditContext::UpdateRow).unwrap();
    match r {
        Value::Text(s) => assert_eq!(s, "<NULL>"),
        other => panic!("expected Text(\"<NULL>\") got {other:?}"),
    }
}

#[test]
fn a_fetched_row_is_keyed_by_its_primary_key_cells() {
    let cells = vec![Value::Int(42), Value::Text("alice".into())];

    assert_eq!(persisted_key(&cells, &[0]), RowKey::from_pk_values(&[Value::Int(42)]));
}

#[test]
fn a_composite_key_keeps_the_key_order() {
    // Two tables with the same columns in a different key order must not
    // produce colliding keys.
    let cells = vec![
        Value::Text("eu-west".into()),
        Value::Text("ignored".into()),
        Value::Int(7),
    ];

    assert_eq!(
        persisted_key(&cells, &[2, 0]),
        RowKey::from_pk_values(&[Value::Int(7), Value::Text("eu-west".into())])
    );
}

#[test]
fn a_row_without_its_key_cells_is_unkeyed() {
    assert!(
        persisted_key(&[Value::Int(1)], &[]).is_none(),
        "a table with no primary key"
    );
    assert!(persisted_key(&[Value::Int(1)], &[5]).is_none());
    assert!(persisted_key(&[Value::Int(1)], &[0, 1]).is_none());
}

#[test]
fn a_null_key_cell_still_names_the_row() {
    assert!(matches!(
        persisted_key(&[Value::Null, Value::Text("x".into())], &[0]),
        Some(RowKey::Persisted(_))
    ));
}

fn row_at(store: &gtk4::gio::ListStore, position: u32) -> RowObject {
    store.item(position).and_downcast::<RowObject>().expect("a row")
}

#[test]
fn visual_changes_add_and_remove_draft_rows() {
    let store = gtk4::gio::ListStore::new::<RowObject>();
    store.append(&RowObject::persisted(None, vec![Value::Int(1)].into()));
    let mut index = GridRowIndex::default();

    apply_visual_change(&store, &mut index, &VisualChange::InsertDraft { draft_id: 4 });
    assert_eq!(row_at(&store, 0).draft_id(), Some(4));
    assert_eq!(index.get(&RowKey::Draft(4)), Some(row_at(&store, 0)));

    apply_visual_change(&store, &mut index, &VisualChange::RemoveDraft { draft_id: 4 });
    assert_eq!(store.n_items(), 1);
    assert_eq!(row_at(&store, 0).draft_id(), None);
    assert_eq!(index.get(&RowKey::Draft(4)), None);
}

fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn rows(names: &[&str]) -> QueryResult {
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
fn serving_table() -> ConnectionScript {
    let mut script = ConnectionScript::default();
    script
        .fetch_columns
        .always(FakeReply::ok(vec![column("id", true), column("name", false)]));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(2));
    script.probe.always(FakeReply::ok(()));
    script
}

struct Harness {
    tab: Option<BrowseTab>,
    tracker: TabTrackerHandle,
    others: Vec<BrowseTab>,
    session: Arc<Session>,
    connection: Arc<FakeConnection>,
    fake: FakeSession,
    root: tempfile::TempDir,
    runtime: Option<crate::runtime::AppRuntime>,
}

impl Harness {
    fn open(script: ConnectionScript, reconnects: impl IntoIterator<Item = FakeEstablish>) -> Self {
        Self::open_filtered(script, reconnects, FilterSet::default())
    }

    /// The tab opens under `saved`, the filter the table was left with.
    fn open_filtered(
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
        saved: FilterSet,
    ) -> Self {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, reconnects, runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let tracker = TabTrackerHandle::default();
        let tab = filtered_users_tab(&fake.session, &runtime, &root, saved, tracker.clone());
        Self {
            tab: Some(tab),
            tracker,
            others: Vec::new(),
            session: fake.session.clone(),
            connection: fake.connection.clone(),
            fake,
            root,
            runtime: Some(runtime),
        }
    }

    fn tab(&self) -> &BrowseTab {
        self.tab.as_ref().expect("the tab is open")
    }

    /// Another tab on the same table and session.
    fn open_another(&mut self) -> BrowseTab {
        let runtime = self.runtime.as_ref().expect("the runtime is running");
        let tab = users_tab(&self.session, runtime, &self.root);
        self.others.push(tab.clone());
        tab
    }

    fn shown(&self) -> Vec<Value> {
        self.tab()
            .snapshot()
            .map(|result| result.rows.into_iter().filter_map(|row| row.get(1).cloned()).collect())
            .unwrap_or_default()
    }

    fn visible_page(&self) -> Option<String> {
        self.tab().imp_stack().visible_child_name().map(|name| name.to_string())
    }

    /// The row the grid shows at `position`, drafts included.
    fn grid_row(&self, position: u32) -> RowObject {
        self.selection()
            .item(position)
            .and_downcast::<RowObject>()
            .expect("a row")
    }

    fn selection(&self) -> gtk4::MultiSelection {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        self.tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .and_then(|model| model.current_selection.clone())
            .expect("the grid is built")
    }

    fn store(&self) -> gtk4::gio::ListStore {
        self.selection()
            .model()
            .and_downcast::<gtk4::gio::ListStore>()
            .expect("a list store")
    }

    /// What the tab does with the delta of an edit it made itself.
    fn apply_delta(&self, delta: &TrackerDelta) {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        let mut effects = Effects::default();
        if let Some(model) = self.tab().imp().model.borrow_mut().as_mut() {
            model.apply_tracker_delta(delta, &mut effects);
        }
    }
}

/// The tab in a window, so its grid draws cells.
struct Shown(gtk4::Window);

impl Shown {
    fn new(tab: &BrowseTab) -> Self {
        let window = gtk4::Window::new();
        window.set_default_size(600, 400);
        window.set_child(Some(tab));
        window.present();
        Self(window)
    }
}

impl Drop for Shown {
    fn drop(&mut self) {
        self.0.set_child(None::<&gtk4::Widget>);
        self.0.destroy();
    }
}

fn users_tab(session: &Arc<Session>, runtime: &crate::runtime::AppRuntime, root: &tempfile::TempDir) -> BrowseTab {
    filtered_users_tab(
        session,
        runtime,
        root,
        FilterSet::default(),
        TabTrackerHandle::default(),
    )
}

fn filtered_users_tab(
    session: &Arc<Session>,
    runtime: &crate::runtime::AppRuntime,
    root: &tempfile::TempDir,
    saved: FilterSet,
    tracker: TabTrackerHandle,
) -> BrowseTab {
    let tasks = runtime.tasks();
    let connection_id = uuid::Uuid::new_v4();
    let filter_settings = crate::persistence::FilterSettingsStore::load(root.path().join("filters.json"), &tasks);
    filter_settings.set_filters(connection_id, None, "users", saved);
    BrowseTab::new(BrowseTabInit {
        tracker,
        schema: None,
        table: "users".to_owned(),
        connection_id: Some(connection_id),
        read_only: false,
        page_size: 100,
        initial_offset: 0,
        initial_sort: None,
        column_widths: crate::persistence::ColumnWidthStore::load(root.path().join("column-widths.json"), &tasks),
        filter_settings,
        session: session.clone(),
        tasks,
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

fn text(values: &[&str]) -> Vec<Value> {
    values.iter().map(|value| Value::Text((*value).to_owned())).collect()
}

fn not_null(column: &str) -> FilterSet {
    FilterSet {
        rules: vec![FilterRule {
            column: column.to_owned(),
            op: FilterOp::IsNotNull,
            value: None,
        }],
        ..FilterSet::default()
    }
}

fn not_null_name() -> FilterSet {
    not_null("name")
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

    harness.tab().send(BrowseTabInput::FilterApplied(not_null_name()));
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
    harness.tab().send(BrowseTabInput::SchemaChanged);
    wait_until(WAIT, || CallCounters::get(&counters.query_bound) == 2).expect("the page after the columns");

    assert_eq!(CallCounters::get(&counters.fetch_columns), 2);
}

fn header_titles(tab: &BrowseTab) -> Vec<String> {
    let Some(view) = crate::test_support::first_descendant_of_type::<gtk4::ColumnView>(tab) else {
        return Vec::new();
    };
    let columns = view.columns();
    (0..columns.n_items())
        .filter_map(|position| columns.item(position).and_downcast::<gtk4::ColumnViewColumn>())
        .filter_map(|column| column.title().map(|title| title.to_string()))
        .collect()
}

#[gtk4::test]
fn a_renamed_column_builds_the_grid_again() {
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
    wait_until(WAIT, || header_titles(harness.tab()).contains(&"name".to_owned())).expect("the first grid");

    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(BrowseTabInput::SchemaChanged);

    wait_until(WAIT, || header_titles(harness.tab()).contains(&"full_name".to_owned()))
        .expect("the grid kept the old column's header");
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

fn toasts(tab: &BrowseTab) -> std::rc::Rc<std::cell::RefCell<Vec<String>>> {
    let toasts = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = toasts.clone();
    tab.connect_toast(move |_, text| sink.borrow_mut().push(text));
    toasts
}

#[gtk4::test]
fn a_failed_refresh_keeps_the_rows_on_screen() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(rows(&["kept"])))
        .always(FakeReply::err(DriverError::server("denied")));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    let toasts = toasts(harness.tab());
    let counters = harness.connection.counters();

    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the failed refresh was not reported");

    assert_eq!(CallCounters::get(&counters.query_bound), 2);
    assert_eq!(harness.shown(), text(&["kept"]), "the failed refresh dropped the rows");
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
    assert!(toasts.borrow()[0].contains("denied"), "{:?}", toasts.borrow());
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

    harness.tab().send(BrowseTabInput::FilterApplied(not_null_name()));

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error"))
        .expect("rows read without the filter stayed under it");
    assert!(harness.shown().is_empty());
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
fn a_filter_column_renamed_away_drops_the_grid_for_the_error() {
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
    harness.tab().send(BrowseTabInput::SchemaChanged);

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error"))
        .expect("the grid read under the old columns stayed on screen");
    assert!(harness.shown().is_empty());
    assert_eq!(harness.tab().columns(), renamed);
}

#[gtk4::test]
fn a_refresh_under_a_filter_that_no_longer_fits_keeps_the_rows() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["kept"])));
    let harness = Harness::open_filtered(script, [], not_null_name());
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    let toasts = toasts(harness.tab());

    harness.tab().send(BrowseTabInput::FilterApplied(not_null("nickname")));
    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || toasts.borrow().len() == 2).expect("the filter that does not fit was not reported");

    assert_eq!(harness.shown(), text(&["kept"]));
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
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
    harness.tab().connect_export_results(move |_, request| {
        export_sink.borrow_mut().push((request.name, request.result.rows.len()));
    });
    let save_sink = saved.clone();
    harness
        .tab()
        .connect_save_requested(move |_| save_sink.set(save_sink.get() + 1));

    harness.tab().send(BrowseTabInput::ExportCurrentPage);
    harness.tab().send(BrowseTabInput::InsertRow);
    harness.tab().send(BrowseTabInput::CommitSave);

    assert_eq!(*exported.borrow(), [("users".to_owned(), 2)]);
    assert_eq!(saved.get(), 1);
}

#[gtk4::test]
fn stop_saving_button_visible_only_while_saving() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;

    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let stops = std::rc::Rc::new(std::cell::Cell::new(0));
    let stop_sink = stops.clone();
    harness
        .tab()
        .connect_stop_save_requested(move |_| stop_sink.set(stop_sink.get() + 1));
    let imp = harness.tab().imp();
    let (stop, spinner, save) = (imp.stop_button.get(), imp.saving_spinner.get(), imp.save_button.get());
    harness.tab().send(BrowseTabInput::InsertRow);

    assert!(!stop.is_visible() && !spinner.is_visible());
    harness.tab().send(BrowseTabInput::SaveStarted);
    assert!(stop.is_visible() && spinner.is_visible());
    assert!(!save.is_sensitive(), "Save stayed on while a save ran");

    stop.emit_clicked();
    assert_eq!(stops.get(), 1);

    harness.tab().send(BrowseTabInput::SaveFailed("rolled back".to_owned()));
    assert!(!stop.is_visible() && !spinner.is_visible());
    assert!(save.is_sensitive());
}

#[gtk4::test]
fn an_edit_held_for_the_running_save_says_so_once() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;

    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let tracker = harness
        .tab()
        .imp()
        .model
        .borrow()
        .as_ref()
        .map(|model| model.tracker.clone())
        .expect("the tab has a model");
    let toasts = toasts(harness.tab());
    harness.tab().send(BrowseTabInput::InsertRow);
    harness.tab().send(BrowseTabInput::InsertRow);
    let _saving = tracker.begin_save().expect("a save").expect("the drafts");
    let drafts: Vec<u64> = tracker.drafts().iter().map(|draft| draft.draft_id).collect();

    harness.tab().send(BrowseTabInput::MarkRowsDeleted {
        rows: Vec::new(),
        drafts,
    });

    assert_eq!(tracker.drafts().len(), 2, "a draft the save holds was dropped");
    assert_eq!(toasts.borrow().len(), 1, "{:?}", toasts.borrow());
}

#[gtk4::test]
fn browse_tab_and_filter_strip_freed_after_drop() {
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
            .and_then(|model| model.filter_strip.as_ref().map(|strip| strip.widget.downgrade()))
            .expect("the filter strip")
    };
    let tab = harness.tab().downgrade();

    harness.tab.take();
    drain_main_context();

    assert!(strip.upgrade().is_none(), "the filter strip outlived its tab");
    assert!(tab.upgrade().is_none(), "the browse tab outlived its last reference");
}

#[gtk4::test]
fn duplicate_row_copies_pending_edits_of_persisted_row() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let ada = harness.grid_row(0);

    harness.tab().send(BrowseTabInput::GridCellEdited {
        row: ada.clone(),
        column: 1,
        input: "Ada Lovelace".to_owned(),
    });
    harness.tab().send(BrowseTabInput::DuplicateRow { row: ada });

    let drafts = harness.tracker.drafts();
    assert_eq!(drafts.len(), 1, "{drafts:?}");
    let texts: Vec<Option<String>> = drafts[0]
        .values
        .iter()
        .map(tablepro_core::export::value_to_text)
        .collect();
    assert_eq!(
        texts,
        vec![None, Some("Ada Lovelace".to_owned())],
        "the duplicate left out the row's pending edit"
    );
}

#[gtk4::test]
fn copy_row_as_insert_uses_row_below_draft() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let copied = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = copied.clone();
    harness
        .tab()
        .connect_copy_to_clipboard(move |_, text| sink.borrow_mut().push(text));

    harness.tab().send(BrowseTabInput::InsertRow);
    let below_draft = harness.grid_row(1);
    harness
        .tab()
        .send(BrowseTabInput::GridCopyRowAsInsert { row: below_draft });

    assert_eq!(
        *copied.borrow(),
        ["INSERT INTO \"users\" (\"id\", \"name\") VALUES (0, 'Ada');".to_owned()]
    );
}

fn key(id: i64) -> RowKey {
    RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
}

/// The cell showing `column` of the saved row keyed `id`, once drawn.
fn grid_cell_of(tab: &BrowseTab, id: i64, column: usize) -> GridCell {
    let key = key(id);
    let mut found = None;
    wait_until(WAIT, || {
        found = crate::test_support::descendants(tab)
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .find(|cell| cell.column() == column && cell.row().is_some_and(|row| row.key() == Some(&key)));
        found.is_some()
    })
    .expect("the row's cell is drawn");
    found.expect("a cell")
}

fn cell_text(cell: &GridCell) -> String {
    cell.editor()
        .map(|editor| editor.text().to_string())
        .unwrap_or_default()
}

fn has_class(cell: &GridCell, class: &str) -> bool {
    cell.content().is_some_and(|content| content.has_css_class(class))
}

fn rename(id: i64, from: &str, to: &str) -> TrackerEdit {
    TrackerEdit::Cell {
        row_key: key(id),
        col: 1,
        original: Value::Text(from.to_owned()),
        value: Value::Text(to.to_owned()),
    }
}

#[gtk4::test]
fn a_commit_is_tracked_at_once_and_leaves_its_cell_in_the_window() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    crate::ui::grid::enter_edit_mode(&cell);
    let editor = cell.editor().expect("a text cell");
    editor.entry().set_text("Ada Lovelace");

    editor.stop_editing(true);

    assert!(
        cell.root().is_some(),
        "the commit took its own cell out of the window before Tab could move on"
    );
    assert_eq!(harness.tracker.pending_count(), 1, "the edit waited for the main loop");
    assert_eq!(cell_text(&cell), "Ada Lovelace");
    assert!(
        has_class(&cell, "tp-cell-modified"),
        "the cell does not show the edit as pending"
    );
}

#[gtk4::test]
fn tracked_edit_keeps_multi_row_selection() {
    let mut script = serving_table();
    script
        .query_bound
        .always(FakeReply::ok(rows(&["Ada", "Grace", "Linus", "Ken"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 4).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 2, 1);
    let selection = harness.selection();
    selection.select_range(1, 3, true);

    let delta = harness.tracker.apply(rename(2, "Linus", "Linus Torvalds"));
    harness.apply_delta(&delta);

    assert_eq!(
        crate::ui::grid::selected_positions(&selection),
        vec![1, 2, 3],
        "the edited row left the selection"
    );
    assert_eq!(cell_text(&cell), "Linus Torvalds");
    assert!(has_class(&cell, "tp-cell-modified"));
}

#[gtk4::test]
fn tracked_edit_keeps_row_object_identity() {
    let mut script = serving_table();
    script
        .query_bound
        .always(FakeReply::ok(rows(&["Ada", "Grace", "Linus"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 3).expect("the first page");
    let store = harness.store();
    let before = store.item(2);
    let changes = std::rc::Rc::new(std::cell::Cell::new(0));
    let counter = changes.clone();
    store.connect_items_changed(move |_, _, _, _| counter.set(counter.get() + 1));

    let delta = harness.tracker.apply(rename(2, "Linus", "Linus Torvalds"));
    harness.apply_delta(&delta);

    assert!(before.is_some());
    assert_eq!(store.item(2), before, "the edited row was swapped for another object");
    assert_eq!(changes.get(), 0, "the store announced a change to its rows");
}

#[gtk4::test]
fn rejected_edit_restores_cell_display() {
    let mut age = col("integer", true);
    age.name = "age".to_owned();
    let columns = vec![column("id", true), age];
    let mut script = serving_table();
    script.fetch_columns.always(FakeReply::ok(columns.clone()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), Value::Int(36)]],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || {
        harness.tab().snapshot().is_some_and(|page| page.rows.len() == 1)
    })
    .expect("the first page");
    let toasts = toasts(harness.tab());
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    crate::ui::grid::enter_edit_mode(&cell);
    let editor = cell.editor().expect("a text cell");
    editor.entry().set_text("thirty-six");

    editor.stop_editing(true);

    wait_until(WAIT, || cell_text(&cell) == "36").expect("the cell kept the text that was refused");
    assert_eq!(toasts.borrow().len(), 1, "{:?}", toasts.borrow());
    assert_eq!(harness.tracker.pending_count(), 0);
}

#[gtk4::test]
fn error_flash_sets_and_clears_on_the_failed_row() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 1, 0);

    harness
        .tab()
        .send(BrowseTabInput::FlashErrorRow(StatementSource::Update {
            row_key: key(1),
        }));

    assert!(
        has_class(&cell, "tp-row-leftmost-error-flash"),
        "the failed row did not flash"
    );
    assert!(!has_class(
        &grid_cell_of(harness.tab(), 0, 0),
        "tp-row-leftmost-error-flash"
    ));
    wait_until(WAIT, || !has_class(&cell, "tp-row-leftmost-error-flash")).expect("the flash never ended");
}

#[gtk4::test]
fn copy_row_as_insert_on_a_draft_leaves_what_the_server_fills_out() {
    let mut id = col("integer", false);
    id.name = "id".to_owned();
    id.primary_key = true;
    id.is_auto_increment = true;
    let mut name = col("text", true);
    name.name = "name".to_owned();
    let mut created_at = col_with_default("timestamptz", "now()");
    created_at.name = "created_at".to_owned();
    let columns = vec![id, name, created_at];
    let mut script = ConnectionScript::default();
    script.fetch_columns.always(FakeReply::ok(columns.clone()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(1));
    script.probe.always(FakeReply::ok(()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(1), Value::Text("Ada".into()), Value::Null]],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let copied = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = copied.clone();
    harness
        .tab()
        .connect_copy_to_clipboard(move |_, text| sink.borrow_mut().push(text));
    let toasts = toasts(harness.tab());

    harness.tab().send(BrowseTabInput::InsertRow);
    let draft = harness.grid_row(0);
    assert!(draft.draft_id().is_some(), "the new row goes on top");
    harness.tab().send(BrowseTabInput::GridCellEdited {
        row: draft.clone(),
        column: 1,
        input: "x".to_owned(),
    });
    harness.tab().send(BrowseTabInput::GridCopyRowAsInsert { row: draft });

    assert_eq!(
        *copied.borrow(),
        ["INSERT INTO \"users\" (\"name\") VALUES ('x');".to_owned()],
        "toasts: {:?}",
        toasts.borrow()
    );
}
