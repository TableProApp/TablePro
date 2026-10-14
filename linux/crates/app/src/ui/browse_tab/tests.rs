use std::sync::Arc;
use std::time::Duration;

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::edit::CellInput;
use tablepro_core::filter::{FilterOp, FilterRule};
use tablepro_core::meta::{RowCountEstimate, RowIdentity, TableEstimate};
use tablepro_core::{ColumnInfo, DriverError, FilterSet, LossPhase, QueryResult, Value};
use tablepro_session::Session;
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeReply};

use super::row_deletion::RowDeletion;
use super::{BrowseTab, BrowseTabInit, BrowseTabInput, Effects, RowTotal, apply_draft_changes};
use crate::services::change_tracker::{RowKey, StatementSource};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{FakeSession, drain_main_context, wait_until};
use crate::ui::clipboard::InsertRow;
use crate::ui::grid::{GridCell, GridRowIndex, RowObject};

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

fn row_at(store: &gtk4::gio::ListStore, position: u32) -> RowObject {
    store.item(position).and_downcast::<RowObject>().expect("a row")
}

#[test]
fn draft_changes_add_and_remove_draft_rows() {
    let store = gtk4::gio::ListStore::new::<RowObject>();
    store.append(&RowObject::persisted(None, vec![Value::Int(1)].into()));
    let mut index = GridRowIndex::default();
    let inserted = TrackerDelta {
        inserted_drafts: vec![4],
        ..TrackerDelta::default()
    };
    let removed = TrackerDelta {
        removed_drafts: vec![4],
        ..TrackerDelta::default()
    };

    apply_draft_changes(&store, &mut index, &inserted);
    assert_eq!(row_at(&store, 0).draft_id(), Some(4));
    assert_eq!(index.get(&RowKey::Draft(4)), Some(row_at(&store, 0)));

    apply_draft_changes(&store, &mut index, &removed);
    assert_eq!(store.n_items(), 1);
    assert_eq!(row_at(&store, 0).draft_id(), None);
    assert_eq!(index.get(&RowKey::Draft(4)), None);
}

pub(super) fn column(name: &str, primary_key: bool) -> ColumnInfo {
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
    root: tempfile::TempDir,
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
        Self::open_with(script, reconnects, saved, false)
    }

    fn open_read_only(script: ConnectionScript) -> Self {
        Self::open_with(script, [], FilterSet::default(), true)
    }

    fn open_with(
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
        saved: FilterSet,
        read_only: bool,
    ) -> Self {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, reconnects, runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let tracker = TabTrackerHandle::default();
        let tab = filtered_users_tab(&fake.session, &runtime, &root, saved, tracker.clone(), read_only);
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

    pub(super) fn tab(&self) -> &BrowseTab {
        self.tab.as_ref().expect("the tab is open")
    }

    /// Another tab on the same table and session.
    pub(super) fn open_another(&mut self) -> BrowseTab {
        let runtime = self.runtime.as_ref().expect("the runtime is running");
        let tab = users_tab(&self.session, runtime, &self.root);
        self.others.push(tab.clone());
        tab
    }

    /// The second cell of each saved row on screen, empty while the
    /// tab shows no page.
    pub(super) fn shown(&self) -> Vec<Value> {
        self.saved_rows()
            .iter()
            .filter_map(|row| row.cell(1).cloned())
            .collect()
    }

    /// The saved rows the grid holds for the page on screen.
    pub(super) fn saved_rows(&self) -> Vec<RowObject> {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        let model = self.tab().imp().model.borrow();
        let Some(selection) = model
            .as_ref()
            .filter(|model| model.page.is_some())
            .and_then(|model| model.current_selection.clone())
        else {
            return Vec::new();
        };
        (0..selection.n_items())
            .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
            .filter(|row| row.draft_id().is_none())
            .collect()
    }

    pub(super) fn visible_page(&self) -> Option<String> {
        self.tab().imp_stack().visible_child_name().map(|name| name.to_string())
    }

    /// The row the grid shows at `position`, drafts included.
    pub(super) fn grid_row(&self, position: u32) -> RowObject {
        self.selection()
            .item(position)
            .and_downcast::<RowObject>()
            .expect("a row")
    }

    pub(super) fn selection(&self) -> gtk4::MultiSelection {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        self.tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .and_then(|model| model.current_selection.clone())
            .expect("the grid is built")
    }

    pub(super) fn store(&self) -> gtk4::gio::ListStore {
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
        self.0.set_child(None::<&gtk4::Widget>);
        self.0.destroy();
    }
}

pub(super) fn users_tab(
    session: &Arc<Session>,
    runtime: &crate::runtime::AppRuntime,
    root: &tempfile::TempDir,
) -> BrowseTab {
    filtered_users_tab(
        session,
        runtime,
        root,
        FilterSet::default(),
        TabTrackerHandle::default(),
        false,
    )
}

pub(super) fn filtered_users_tab(
    session: &Arc<Session>,
    runtime: &crate::runtime::AppRuntime,
    root: &tempfile::TempDir,
    saved: FilterSet,
    tracker: TabTrackerHandle,
    read_only: bool,
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
        read_only,
        page_size: 100,
        initial_offset: 0,
        initial_sort: None,
        column_widths: crate::persistence::ColumnWidthStore::load(root.path().join("column-widths.json"), &tasks),
        filter_settings,
        session: session.clone(),
        tasks,
        deadlines: Arc::new(tablepro_session::operation::DefaultDeadlines::new(
            tablepro_core::LivenessPolicy::DESKTOP,
        )),
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

pub(super) fn header_titles(tab: &BrowseTab) -> Vec<String> {
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

pub(super) fn toasts(tab: &BrowseTab) -> std::rc::Rc<std::cell::RefCell<Vec<String>>> {
    let toasts = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = toasts.clone();
    tab.connect_toast(move |_, text| sink.borrow_mut().push(text));
    toasts
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
fn no_dim_label_class_remains() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    let _shown = Shown::new(harness.tab());
    wait_until(WAIT, || {
        crate::test_support::descendants(harness.tab())
            .iter()
            .any(|widget| widget.is::<GridCell>())
    })
    .expect("the grid draws its cells");
    harness.tab().send(BrowseTabInput::ToggleFilterStrip);

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

    harness.tab().send(BrowseTabInput::Export(None));
    harness.tab().send(BrowseTabInput::InsertRow);
    harness.tab().send(BrowseTabInput::CommitSave);

    assert_eq!(*exported.borrow(), [("users".to_owned(), Some(2))]);
    assert_eq!(saved.get(), 1);
}

#[gtk4::test]
fn current_page_export_includes_pending_edits() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness.apply_delta(&harness.tracker.apply(rename(0, "Ada", "Ada Lovelace")));
    let offers = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = offers.clone();
    harness
        .tab()
        .connect_export_results(move |_, offer| sink.borrow_mut().push(offer));

    harness.tab().send(BrowseTabInput::Export(None));

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

    harness.tab().send(BrowseTabInput::MarkRowsDeleted(RowDeletion {
        drafts,
        ..RowDeletion::default()
    }));

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

    harness.tab().send(typed(&ada, 1, "Ada Lovelace"));
    harness.tab().send(BrowseTabInput::DuplicateRows(vec![ada]));

    let drafts = harness.tracker.drafts();
    assert_eq!(drafts.len(), 1, "{drafts:?}");
    assert_eq!(
        drafts[0].cells,
        vec![
            CellInput::Value(Value::Null),
            CellInput::Value(Value::Text("Ada Lovelace".to_owned()))
        ],
        "the duplicate left out the row's pending edit"
    );
}

#[gtk4::test]
fn duplicating_a_draft_leaves_its_defaulted_cells_to_the_server() {
    let mut level = col_with_default("integer", "0");
    level.name = "level".to_owned();
    let (harness, _shown) = one_cell(level, Value::Int(3));
    harness.tab().send(BrowseTabInput::InsertRow);
    let draft = harness.grid_row(0);
    assert!(draft.draft_id().is_some(), "the new row goes on top");

    harness.tab().send(BrowseTabInput::DuplicateRows(vec![draft]));

    let drafts = harness.tracker.drafts();
    assert_eq!(drafts.len(), 2, "{drafts:?}");
    assert_eq!(
        drafts[1].cells[1],
        CellInput::Default,
        "the copy wrote NULL where the server fills in"
    );
}

#[gtk4::test]
fn duplicating_a_selection_is_one_undo_step() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");

    harness.tab().send(BrowseTabInput::DuplicateRows(vec![
        harness.grid_row(0),
        harness.grid_row(1),
    ]));
    assert_eq!(draft_rows(&harness.store()), 2);
    harness.tab().send(BrowseTabInput::Undo);

    assert_eq!(draft_rows(&harness.store()), 0, "one undo left copies behind");
    assert_eq!(harness.tracker.pending_count(), 0);
}

#[gtk4::test]
fn copy_row_as_insert_uses_row_below_draft() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");

    harness.tab().send(BrowseTabInput::InsertRow);
    let below_draft = harness.grid_row(1);
    let copied = copied_by(harness.tab(), || {
        harness
            .tab()
            .send(BrowseTabInput::GridCopyRowsAsInsert(vec![below_draft]));
    });

    assert_eq!(copied, "INSERT INTO \"users\" (\"id\", \"name\") VALUES (0, 'Ada');");
}

/// What the clipboard holds once the copy `copy` starts lands there.
fn copied_by(tab: &BrowseTab, copy: impl FnOnce()) -> String {
    const BEFORE: &str = "nothing copied yet";
    let clipboard = tab.clipboard();
    clipboard.set_text(BEFORE);
    copy();
    let text = || -> Option<String> { clipboard.content()?.value(String::static_type()).ok()?.get().ok() };
    wait_until(WAIT, || text().is_some_and(|text| text != BEFORE)).expect("the copy to land");
    text().unwrap_or_default()
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

/// A partitioned PostgreSQL table with no key, whose page carries the
/// partition, the row address and its version after the visible cells.
fn partitioned_table() -> ConnectionScript {
    let server = tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0);
    let mut script = ConnectionScript {
        dialect: Arc::new(drivers_postgres::PgDialect::new(&server)),
        ..ConnectionScript::default()
    };
    script
        .fetch_columns
        .always(FakeReply::ok(vec![column("id", false), column("name", false)]));
    script.row_identity.always(FakeReply::ok(RowIdentity::EngineRowId(
        tablepro_core::meta::EngineRowId::PostgresTableoidCtid,
    )));
    script.count_rows.always(FakeReply::ok(2));
    script.probe.always(FakeReply::ok(()));
    let mut columns: Vec<_> = [column("id", false), column("name", false)]
        .iter()
        .map(ColumnInfo::result_column)
        .collect();
    for hidden in ["__tablepro_row_oid", "__tablepro_row_id", "__tablepro_row_xmin"] {
        columns.push(column(hidden, false).result_column());
    }
    let rows = [("Ada", "(0,1)"), ("Grace", "(0,1)")]
        .iter()
        .zip(0..)
        .map(|((name, ctid), id)| {
            vec![
                Value::Int(id),
                Value::Text((*name).to_owned()),
                Value::Int(16_401 + id),
                Value::Text((*ctid).to_owned()),
                Value::Text("812".to_owned()),
            ]
        })
        .collect();
    script
        .query_bound
        .always(FakeReply::ok(QueryResult::new(columns, rows)));
    script
}

fn visible_only(values: &[Value]) {
    assert_eq!(values.len(), 2, "a row carried hidden cells: {values:?}");
}

#[gtk4::test]
fn row_objects_hold_only_visible_cells() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");

    for row in harness.saved_rows() {
        visible_only(&row.cells().expect("a saved row's cells"));
        assert_eq!(row.key(), None, "a table with no primary key took edits");
    }
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let model = harness.tab().imp().model.borrow();
    let page = model.as_ref().and_then(|model| model.page.clone()).expect("the page");
    assert_eq!(page.result_columns.len(), 2, "the grid was given the hidden columns");
}

#[gtk4::test]
fn page_rows_have_single_owner() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");

    for row in harness.saved_rows() {
        let cells = row.shared_cells().expect("a saved row's cells");
        assert_eq!(Arc::strong_count(cells), 1, "the tab kept its own copy of the page");
    }
}

#[gtk4::test]
fn copy_as_insert_and_duplicate_contain_no_hidden_columns() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");
    let rows = harness.saved_rows();

    let copied = copied_by(harness.tab(), || {
        harness.tab().send(BrowseTabInput::GridCopyRowsAsInsert(rows.clone()));
    });
    harness.tab().send(BrowseTabInput::DuplicateRows(rows));

    assert_eq!(copied.lines().count(), 2, "{copied}");
    for hidden in ["16401", "(0,1)", "812", "__tablepro"] {
        assert!(!copied.contains(hidden), "{hidden} reached the copy: {copied}");
    }
    let drafts = harness.tracker.drafts();
    assert_eq!(drafts.len(), 2);
    for draft in drafts {
        assert_eq!(
            draft.cells.len(),
            2,
            "a duplicate carried hidden cells: {:?}",
            draft.cells
        );
    }
}

#[gtk4::test]
fn copy_as_insert_shares_saved_rows_and_copies_only_drafts() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");
    harness.tab().send(BrowseTabInput::InsertRow);
    let saved = harness.saved_rows();
    let mut rows = vec![harness.grid_row(0)];
    rows.extend(saved.iter().cloned());

    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let model = harness.tab().imp().model.borrow();
    let insert_rows = model.as_ref().expect("the model").insert_rows(&rows);

    let [InsertRow::Draft(_), InsertRow::Saved(first), InsertRow::Saved(second)] = insert_rows.as_slice() else {
        panic!("{insert_rows:?}");
    };
    for (snapshot, row) in [first, second].into_iter().zip(&saved) {
        let cells = row.shared_cells().expect("a saved row's cells");
        assert!(snapshot.shares_cells_with(cells), "a saved row's cells were copied");
    }
}

#[gtk4::test]
fn page_export_snapshot_contains_no_hidden_columns() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");
    let exported = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = exported.clone();
    harness
        .tab()
        .connect_export_results(move |_, offer| sink.borrow_mut().push(offer.origin.shown().clone()));

    harness.tab().send(BrowseTabInput::Export(None));

    let exported = exported.borrow();
    let [crate::ui::export::ExportSource::Rows { columns, rows }] = exported.as_slice() else {
        panic!("one export, not {}", exported.len());
    };
    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["id", "name"]);
    assert_eq!(rows.len(), 2);
    for row in rows {
        visible_only(&row.to_values());
    }
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

#[gtk4::test]
fn page_load_emits_one_items_changed_with_drafts_prepended() {
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus", "Ken"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    harness.tab().send(BrowseTabInput::InsertRow);
    let store = harness.store();
    let changes = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let log = changes.clone();
    store.connect_items_changed(move |_, position, removed, added| {
        log.borrow_mut().push((position, removed, added));
    });

    harness.tab().send(BrowseTabInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus", "Ken"])).expect("the next page");

    assert_eq!(*changes.borrow(), [(0, 101, 3)], "the page was not one splice");
    assert!(harness.grid_row(0).draft_id().is_some(), "the draft left the top");
    assert_eq!(harness.grid_row(1).key(), Some(&key(100)));
}

#[gtk4::test]
fn second_page_load_drops_previous_rows() {
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let _drawn = grid_cell_of(harness.tab(), 0, 1);
    let first: Vec<glib::WeakRef<RowObject>> = harness.saved_rows().iter().map(ObjectExt::downgrade).collect();

    harness.tab().send(BrowseTabInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus"])).expect("the next page");

    wait_until(WAIT, || first.iter().all(|row| row.upgrade().is_none())).expect("the first page's rows were let go");
}

/// The row holding the focus leaves in the splice, which takes the
/// focus from it first: the open edit ends as a focus change ends it.
#[gtk4::test]
fn a_page_that_replaces_the_row_being_edited_keeps_the_edit_and_the_focus() {
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    let shown = Shown::new(harness.tab());
    let view = column_view(harness.tab());
    let name = view
        .columns()
        .item(1)
        .and_downcast::<gtk4::ColumnViewColumn>()
        .expect("the name column");
    view.scroll_to(1, Some(&name), gtk4::ListScrollFlags::FOCUS, None);
    view.grab_focus();
    let focused_cell = || gtk4::prelude::GtkWindowExt::focus(&shown.0).and_then(|focus| GridCell::from_focus(&focus));
    wait_until(WAIT, || focused_cell().is_some_and(|cell| cell.position() == Some(1))).expect("a cell takes the focus");
    let cell = focused_cell().expect("the focused cell");
    let _editor = type_into(&cell, "typed");
    // A focus left in a row the splice took out of the window is what a
    // window focus-in then trips over.
    let stranded = std::rc::Rc::new(std::cell::Cell::new(false));
    let seen = stranded.clone();
    let window = shown.0.downgrade();
    harness.store().connect_items_changed(move |_, _, _, _| {
        let focus = window
            .upgrade()
            .and_then(|window| gtk4::prelude::GtkWindowExt::focus(&window));
        seen.set(seen.get() || focus.is_some_and(|focus| focus.root().is_none()));
    });

    harness.tab().send(BrowseTabInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus"])).expect("the next page");
    after_next_frame(&shown.0);

    assert!(!stranded.get(), "the focus stayed in a row the page removed");

    assert!(!cell.is_editing(), "the edit outlived its row");
    let pending = harness.tracker.cell_overlay(&key(1), 1).pending;
    assert!(
        matches!(&pending, Some(CellInput::Value(Value::Other(typed))) if typed.text == "typed"),
        "what was typed was lost, or landed on another row: {pending:?}"
    );
    assert_eq!(harness.tracker.pending_count(), 1);
    let focus = gtk4::prelude::GtkWindowExt::focus(&shown.0);
    assert!(
        focus.is_some_and(|focus| focus == *view.upcast_ref::<gtk4::Widget>() || focus.is_ancestor(&view)),
        "the focus left the grid"
    );
}

pub(super) fn after_next_frame(window: &gtk4::Window) {
    let clock = window.frame_clock().expect("the window's frame clock");
    let painted = std::rc::Rc::new(std::cell::Cell::new(false));
    let flag = painted.clone();
    let handler = clock.connect_after_paint(move |_| flag.set(true));
    clock.request_phase(gtk4::gdk::FrameClockPhase::AFTER_PAINT);
    wait_until(WAIT, || painted.get()).expect("the window paints a frame");
    clock.disconnect(handler);
}

/// The cell showing `column` of the saved row keyed `id`, once drawn.
pub(super) fn grid_cell_of(tab: &BrowseTab, id: i64, column: usize) -> GridCell {
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
    cell.display()
        .and_then(|display| display.text())
        .map(|text| text.to_string())
        .unwrap_or_default()
}

/// What the grid sends once `text` is typed into `column` of a saved
/// row and committed.
fn typed(row: &RowObject, column: usize, text: &str) -> BrowseTabInput {
    BrowseTabInput::GridEdit {
        row: row.clone(),
        column,
        edit: TrackerEdit::Cell {
            row_key: row.key().cloned().expect("a saved row"),
            col: column,
            original: row.cell(column).cloned().unwrap_or(Value::Null),
            value: Value::Text(text.to_owned()),
        },
    }
}

/// Open the cell's one-line editor and type `text` over its value.
fn type_into(cell: &GridCell, text: &str) -> gtk4::Text {
    crate::ui::grid::begin_edit(cell);
    let editor = cell.inline_text().expect("the cell did not open its one-line editor");
    editor.set_text(text);
    editor
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
    let editor = type_into(&cell, "Ada Lovelace");

    editor.emit_activate();

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
    wait_until(WAIT, || harness.saved_rows().len() == 1).expect("the first page");
    let toasts = toasts(harness.tab());
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    let editor = type_into(&cell, "thirty-six");

    editor.emit_activate();

    wait_until(WAIT, || cell_text(&cell) == "36").expect("the cell kept the text that was refused");
    assert_eq!(toasts.borrow().len(), 1, "{:?}", toasts.borrow());
    assert_eq!(harness.tracker.pending_count(), 0);
}

#[gtk4::test]
fn refused_edit_restores_cell_display() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let _shown = Shown::new(harness.tab());
    // A saved row's key, which the tab refuses to change in place.
    let cell = grid_cell_of(harness.tab(), 0, 0);
    let row = cell.row().expect("a bound row");
    cell.display().expect("a text cell").set_text(Some("7"));

    harness.tab().send(BrowseTabInput::GridEdit {
        row: row.clone(),
        column: 0,
        edit: TrackerEdit::Cell {
            row_key: key(0),
            col: 0,
            original: Value::Int(0),
            value: Value::Int(7),
        },
    });

    assert_eq!(cell_text(&cell), "0", "the cell kept the edit the tab refused");
    assert_eq!(harness.tracker.pending_count(), 0);
}

#[gtk4::test]
fn undo_under_an_open_editor_leaves_nothing_pending() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    harness.apply_delta(&harness.tracker.apply(rename(0, "Ada", "Ada Lovelace")));
    crate::ui::grid::begin_edit(&cell);
    assert!(cell.is_editing());

    harness.tab().send(BrowseTabInput::Undo);
    cell.cancel_edit();

    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "closing the editor sent the undone value back"
    );
    assert_eq!(cell_text(&cell), "Ada");
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
    let toasts = toasts(harness.tab());

    harness.tab().send(BrowseTabInput::InsertRow);
    let draft = harness.grid_row(0);
    assert!(draft.draft_id().is_some(), "the new row goes on top");
    harness.tab().send(BrowseTabInput::GridEdit {
        row: draft.clone(),
        column: 1,
        edit: TrackerEdit::DraftCell {
            draft_id: draft.draft_id().expect("a draft"),
            col: 1,
            input: CellInput::Value(Value::Text("x".into())),
        },
    });
    let copied = copied_by(harness.tab(), || {
        harness.tab().send(BrowseTabInput::GridCopyRowsAsInsert(vec![draft]));
    });

    assert_eq!(
        copied,
        "INSERT INTO \"users\" (\"name\") VALUES ('x');",
        "toasts: {:?}",
        toasts.borrow()
    );
}

fn people(names: &[&str]) -> Vec<ColumnInfo> {
    std::iter::once(column("id", true))
        .chain(names.iter().map(|name| column(name, false)))
        .collect()
}

/// One row, id 0, each cell holding its column's name.
fn people_page(columns: &[ColumnInfo]) -> QueryResult {
    QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![
            std::iter::once(Value::Int(0))
                .chain(columns[1..].iter().map(|column| Value::Text(column.name.clone())))
                .collect(),
        ],
    )
}

/// A table whose `nickname` another client drops before the tab reads
/// its columns again. `after` is what the page under the new columns
/// answers.
fn losing_nickname(after: FakeReply<QueryResult>) -> ConnectionScript {
    let before = people(&["nickname", "name", "email"]);
    let mut script = serving_table();
    script
        .fetch_columns
        .once(FakeReply::ok(before.clone()))
        .always(FakeReply::ok(people(&["name", "email"])));
    script
        .query_bound
        .when_sql_contains("nickname", FakeReply::ok(people_page(&before)))
        .always(after);
    script
}

fn without_nickname() -> FakeReply<QueryResult> {
    FakeReply::ok(people_page(&people(&["name", "email"])))
}

/// Each assignment of the save, by the name of the column it writes.
fn saved_cells(tracker: &TabTrackerHandle) -> Vec<(String, Option<String>)> {
    let batch = tracker.begin_save().expect("a save").expect("changes to save");
    batch
        .changes
        .changes
        .changes
        .iter()
        .flat_map(|change| match change {
            tablepro_core::save::RowChange::Update(update) => update.assignments.clone(),
            other => panic!("only a cell was edited: {other:?}"),
        })
        .map(|(col, value)| {
            (
                batch.columns[col].name.clone(),
                tablepro_core::export::value_to_text(&value),
            )
        })
        .collect()
}

fn edit_first_row(harness: &Harness, column: usize, input: &str) {
    harness.tab().send(typed(&harness.grid_row(0), column, input));
    assert_eq!(harness.tracker.pending_count(), 1);
}

fn headers_are(tab: &BrowseTab, expected: &[&str]) -> bool {
    header_titles(tab) == expected
}

#[gtk4::test]
fn refresh_after_a_column_is_dropped_keeps_an_edit_on_its_column() {
    let harness = Harness::open(losing_nickname(without_nickname()), []);
    wait_until(WAIT, || {
        headers_are(harness.tab(), &["id", "nickname", "name", "email"])
    })
    .expect("the first grid");
    edit_first_row(&harness, 2, "Grace");

    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || headers_are(harness.tab(), &["id", "name", "email"])).expect("the grid under the new columns");

    assert_eq!(
        saved_cells(&harness.tracker),
        vec![("name".to_owned(), Some("Grace".to_owned()))]
    );
}

#[gtk4::test]
fn a_structure_save_that_drops_the_edited_column_refuses_the_save() {
    let harness = Harness::open(losing_nickname(without_nickname()), []);
    wait_until(WAIT, || {
        headers_are(harness.tab(), &["id", "nickname", "name", "email"])
    })
    .expect("the first grid");
    edit_first_row(&harness, 1, "countess");

    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(BrowseTabInput::SchemaChanged);
    wait_until(WAIT, || headers_are(harness.tab(), &["id", "name", "email"])).expect("the grid under the new columns");

    let refused = harness
        .tracker
        .begin_save()
        .map(|batch| batch.map(|batch| batch.changes.changes));
    assert!(
        refused
            .as_ref()
            .is_err_and(|rejection| rejection.message().contains("nickname")),
        "{refused:?}"
    );
    assert_eq!(
        harness.tracker.pending_count(),
        1,
        "the edit was dropped without a word"
    );
}

#[gtk4::test]
fn a_grid_built_for_columns_the_table_lost_takes_no_edits() {
    let harness = Harness::open(losing_nickname(FakeReply::UntilStopped), []);
    wait_until(WAIT, || {
        headers_are(harness.tab(), &["id", "nickname", "name", "email"])
    })
    .expect("the first grid");
    let row = harness.grid_row(0);

    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(BrowseTabInput::SchemaChanged);
    wait_until(WAIT, || harness.tab().columns() == people(&["name", "email"])).expect("the new columns");
    // Column 2 was name in the grid the event came from, and is email now.
    harness.tab().send(typed(&row, 2, "Grace"));

    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "an edit in the old grid landed on another column"
    );
    assert_eq!(harness.visible_page().as_deref(), Some("loading"));
}

pub(super) fn delete_action(tab: &BrowseTab) -> gtk4::gio::SimpleAction {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    tab.imp()
        .model
        .borrow()
        .as_ref()
        .map(|model| model.actions.delete_rows.clone())
        .expect("the tab has a model")
}

fn delete_rows(tab: &BrowseTab) {
    tab.activate_action("browse.delete-rows", None)
        .expect("the tab has a delete action");
}

fn draft_rows(store: &gtk4::gio::ListStore) -> usize {
    (0..store.n_items())
        .filter(|position| row_at(store, *position).draft_id().is_some())
        .count()
}

fn pending_bar_shown(tab: &BrowseTab) -> bool {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    tab.imp().pending_revealer.reveals_child()
}

#[gtk4::test]
fn deleting_a_draft_removes_its_row() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness.tab().send(BrowseTabInput::InsertRow);
    let store = harness.store();
    assert_eq!(store.n_items(), 3);
    harness.selection().select_item(0, true);
    assert!(
        delete_action(harness.tab()).is_enabled(),
        "a draft could not be deleted"
    );

    delete_rows(harness.tab());

    assert_eq!(store.n_items(), 2, "the dropped draft stayed in the grid");
    assert_eq!(draft_rows(&store), 0);
    assert_eq!(harness.tracker.pending_count(), 0);
    assert!(
        !pending_bar_shown(harness.tab()),
        "the footer still counts the dropped draft"
    );
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

/// The grid's keys sit on the column view, so a text field elsewhere in
/// the tab keeps Ctrl+C, Delete and Escape.
#[gtk4::test]
fn browse_grid_shortcuts_live_on_the_column_view() {
    use crate::application::ShortcutOwner;
    use crate::test_support::shortcut_keys::{owner_controller, shortcut_controllers};
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let view = column_view(harness.tab());

    let grid = owner_controller(&view, ShortcutOwner::BrowseGrid).expect("the grid's shortcuts");
    let tab = owner_controller(harness.tab(), ShortcutOwner::BrowseTab).expect("the tab's shortcuts");

    assert_eq!(named_actions(&grid), table_actions(ShortcutOwner::BrowseGrid));
    assert_eq!(named_actions(&tab), table_actions(ShortcutOwner::BrowseTab));
    let on_the_tab: Vec<String> = shortcut_controllers(harness.tab())
        .iter()
        .flat_map(named_actions)
        .collect();
    assert_eq!(on_the_tab, table_actions(ShortcutOwner::BrowseTab), "{on_the_tab:?}");
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
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let activate = |name: &str| {
        harness
            .tab()
            .activate_action(&format!("browse.{name}"), None)
            .expect("the browse group");
    };

    assert!(
        action_enabled(harness.tab(), "insert-row"),
        "a keyed table refused Ctrl+N"
    );
    assert!(!action_enabled(harness.tab(), "save"), "Save with nothing to save");
    assert!(!action_enabled(harness.tab(), "undo"));
    assert!(
        !action_enabled(harness.tab(), "copy-rows"),
        "Ctrl+C with no rows selected"
    );

    harness.selection().select_all();
    assert!(action_enabled(harness.tab(), "copy-rows"));
    assert!(action_enabled(harness.tab(), "clear-selection"));
    activate("clear-selection");
    assert!(
        !action_enabled(harness.tab(), "clear-selection"),
        "the selection was not cleared"
    );

    harness.tab().send(BrowseTabInput::InsertRow);
    assert!(action_enabled(harness.tab(), "save"));
    assert!(action_enabled(harness.tab(), "undo"));
    assert!(!action_enabled(harness.tab(), "redo"));
    activate("undo");
    assert_eq!(harness.tracker.pending_count(), 0, "browse.undo did not undo");
    assert!(action_enabled(harness.tab(), "redo"));
    assert!(!action_enabled(harness.tab(), "save"));
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
        harness
            .tab()
            .send(BrowseTabInput::DeleteRows(vec![harness.grid_row(0)]));
        assert_eq!(harness.tracker.pending_count(), 1);
        let strip = {
            use gtk4::subclass::prelude::ObjectSubclassIsExt;
            let model = harness.tab().imp().model.borrow();
            let strip = model.as_ref().and_then(|model| model.filter_strip.as_ref());
            strip.expect("the filter strip").widget.clone()
        };

        harness.tab().send(BrowseTabInput::ToggleFilterStrip);
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
        model
            .as_ref()
            .and_then(|model| model.filter_strip.as_ref())
            .is_some_and(crate::ui::filter_strip::FilterStrip::is_revealed)
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

#[gtk4::test]
fn a_read_only_tab_refuses_insert_row() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open_read_only(script);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");

    assert!(!action_enabled(harness.tab(), "insert-row"));
    harness.tab().activate_action("browse.insert-row", None).ok();
    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "Ctrl+N added a row to a read-only table"
    );

    harness.tab().send(BrowseTabInput::InsertRow);
    harness
        .tab()
        .send(BrowseTabInput::DuplicateRows(vec![harness.grid_row(0)]));
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
        ("insert row", imp.insert_button.get()),
        ("delete rows", imp.delete_button.get()),
        ("filter", imp.filter_button.get()),
        ("previous page", imp.prev_button.get()),
        ("next page", imp.next_button.get()),
        ("save", imp.save_button.get()),
    ] {
        assert!(
            gtk4::test_accessible_has_property(&button, gtk4::AccessibleProperty::KeyShortcuts),
            "the {name} button announces no keys"
        );
    }
}

/// A page splice leaves the selection model without a selection-changed,
/// so the tab reads the selection again.
#[gtk4::test]
fn a_new_page_turns_off_the_selection_keys() {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus", "Ken"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    harness.selection().select_range(0, 2, true);
    assert!(action_enabled(harness.tab(), "copy-rows"));
    assert!(action_enabled(harness.tab(), "clear-selection"));

    harness.tab().send(BrowseTabInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus", "Ken"])).expect("the next page");

    assert!(
        harness.selection().selection().is_empty(),
        "the new page kept a selection"
    );
    assert!(
        !action_enabled(harness.tab(), "copy-rows"),
        "Ctrl+C stayed on with nothing selected"
    );
    assert!(
        !action_enabled(harness.tab(), "clear-selection"),
        "Escape stayed on with nothing selected"
    );
    assert!(
        !harness.tab().imp().selection_label.is_visible(),
        "the footer still counts the rows that left"
    );
}

fn action_enabled(tab: &BrowseTab, name: &str) -> bool {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    let model = tab.imp().model.borrow();
    let actions = &model.as_ref().expect("the tab has a model").actions;
    let action = match name {
        "save" => &actions.save,
        "undo" => &actions.undo,
        "redo" => &actions.redo,
        "insert-row" => &actions.insert_row,
        "delete-rows" => &actions.delete_rows,
        "copy-rows" => &actions.copy_rows,
        "clear-selection" => &actions.clear_selection,
        _ => panic!("browse.{name} does not follow the tab"),
    };
    action.is_enabled()
}

#[gtk4::test]
fn deleting_mixed_selection_removes_drafts_and_marks_persisted() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness.tab().send(BrowseTabInput::InsertRow);
    harness.selection().select_range(0, 2, true);

    delete_rows(harness.tab());

    let store = harness.store();
    assert_eq!(store.n_items(), 2);
    assert_eq!(draft_rows(&store), 0);
    assert_eq!(
        harness.tracker.row_state(&key(0)),
        crate::services::change_tracker::RowState::PendingDelete
    );
    assert_eq!(
        harness.tracker.row_state(&key(1)),
        crate::services::change_tracker::RowState::Clean
    );
    assert_eq!(harness.tracker.pending_count(), 1);
    assert!(
        crate::ui::grid::selected_positions(&harness.selection()).is_empty(),
        "the delete kept the selection it acted on"
    );
}

fn menu_gesture(cell: &GridCell) -> gtk4::GestureClick {
    let controllers = cell.observe_controllers();
    (0..controllers.n_items())
        .filter_map(|index| controllers.item(index).and_downcast::<gtk4::GestureClick>())
        .find(|gesture| gesture.button() == 3)
        .expect("a cell answers a right-click")
}

pub(super) fn column_view(tab: &BrowseTab) -> gtk4::ColumnView {
    crate::test_support::first_descendant_of_type::<gtk4::ColumnView>(tab).expect("the grid")
}

#[gtk4::test]
fn menu_delete_inside_selection_marks_whole_selection() {
    let names: Vec<String> = (0..20).map(|n| format!("user {n}")).collect();
    let names: Vec<&str> = names.iter().map(String::as_str).collect();
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&names)));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 20).expect("the first page");
    use libadwaita::prelude::{AdwDialogExt, AdwWindowExt};
    let window = libadwaita::Window::new();
    window.set_default_size(600, 400);
    window.set_content(Some(harness.tab()));
    window.present();
    harness.selection().select_all();
    let cell = grid_cell_of(harness.tab(), 2, 1);

    menu_gesture(&cell).emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
    column_view(harness.tab())
        .activate_action("cell.delete-row", None)
        .expect("the menu's Delete");
    let mut dialog = None;
    wait_until(WAIT, || {
        dialog = window.visible_dialog().and_downcast::<libadwaita::AlertDialog>();
        dialog.is_some()
    })
    .expect("a delete of 20 rows was not confirmed first");
    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "the rows were marked before the answer"
    );
    let dialog = dialog.expect("the confirmation");
    dialog.emit_by_name::<()>("response", &[&"delete"]);

    wait_until(WAIT, || harness.tracker.pending_count() == 20).expect("the whole selection was not marked");
    dialog.force_close();
    window.set_content(None::<&gtk4::Widget>);
    window.destroy();
}

#[gtk4::test]
fn undo_insert_removes_draft_row() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness.tab().send(BrowseTabInput::InsertRow);
    let store = harness.store();
    assert_eq!(store.n_items(), 3);

    harness.tab().send(BrowseTabInput::Undo);

    assert_eq!(store.n_items(), 2, "the undone draft stayed in the grid");
    assert_eq!(draft_rows(&store), 0);
    assert_eq!(harness.tracker.pending_count(), 0);
}

#[gtk4::test]
fn redo_insert_restores_draft_row_once() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness.tab().send(BrowseTabInput::InsertRow);
    harness.tab().send(BrowseTabInput::Undo);

    harness.tab().send(BrowseTabInput::Redo);

    let store = harness.store();
    assert_eq!(store.n_items(), 3);
    assert_eq!(draft_rows(&store), 1, "the redone draft is in the grid more than once");
    assert!(row_at(&store, 0).draft_id().is_some(), "the redone draft is not on top");
}

#[gtk4::test]
fn delete_action_disabled_for_unkeyed_selection() {
    let columns = [column("id", false), column("name", false)];
    let mut script = serving_table();
    script.fetch_columns.always(FakeReply::ok(columns.to_vec()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![
            vec![Value::Int(0), Value::Text("Ada".into())],
            vec![Value::Int(1), Value::Text("Grace".into())],
        ],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let _shown = Shown::new(harness.tab());
    let action = delete_action(harness.tab());

    harness.selection().select_item(0, true);

    assert!(!action.is_enabled(), "Delete was offered for a row with no key");
    let button = {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        harness.tab().imp().delete_button.get()
    };
    assert_eq!(
        button.tooltip_text().as_deref(),
        Some("Rows without a primary key or unique key can't be deleted here")
    );
    let view = column_view(harness.tab());
    let mut cell = None;
    wait_until(WAIT, || {
        cell = crate::test_support::descendants(&view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .find(|cell| cell.column() == 1 && cell.position() == Some(0));
        cell.is_some()
    })
    .expect("the row's cell is drawn");
    menu_gesture(&cell.expect("a cell")).emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
    // A menu item is a model button bound to the action's enabled state,
    // with the item's label as its text.
    let items: Vec<gtk4::Widget> = crate::test_support::descendants(&view)
        .into_iter()
        .filter(|widget| widget.type_().name() == "GtkModelButton")
        .filter(|widget| widget.property::<Option<String>>("text").as_deref() == Some("Delete"))
        .collect();
    assert!(!items.is_empty(), "the menu has no Delete item");
    wait_until(WAIT, || items.iter().all(|item| !item.is_sensitive()))
        .expect("the menu offered Delete for a row with no key");
    view.activate_action("cell.delete-row", None)
        .expect("the menu's Delete");
    delete_rows(harness.tab());
    assert_eq!(harness.tracker.pending_count(), 0);
}

fn named_col(name: &str, data_type: &str, nullable: bool) -> ColumnInfo {
    let mut column = col(data_type, nullable);
    column.name = name.to_owned();
    column
}

/// A table of an `id` key and `column`, with one row, id 0, holding
/// `value`, drawn in a window.
fn one_cell(column: ColumnInfo, value: Value) -> (Harness, Shown) {
    let columns = vec![self::column("id", true), column];
    let mut script = ConnectionScript::default();
    script.fetch_columns.always(FakeReply::ok(columns.clone()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(1));
    script.probe.always(FakeReply::ok(()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), value]],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.saved_rows().len() == 1).expect("the first page");
    let shown = Shown::new(harness.tab());
    (harness, shown)
}

/// The value the tracker holds for row 0's second cell.
fn pending_value(harness: &Harness, fetched: &Value) -> Value {
    harness.tracker.cell_overlay(&key(0), 1).shown(fetched.clone())
}

/// Open the cell's one-line editor and paste `text` over its value
/// through the clipboard, as Ctrl+V does.
fn paste_into(cell: &GridCell, text: &str) -> gtk4::Text {
    crate::ui::grid::begin_edit(cell);
    let editor = cell.inline_text().expect("the cell did not open its one-line editor");
    let opened = editor.text();
    editor.clipboard().set_text(text);
    editor.emit_paste_clipboard();
    wait_until(WAIT, || editor.text() != opened).expect("the paste never landed");
    editor
}

fn calendar_of(cell: &GridCell) -> Option<gtk4::Calendar> {
    crate::test_support::first_descendant_of_type::<gtk4::Calendar>(cell)
}

#[gtk4::test]
fn unchanged_40kb_multiline_text_records_no_edit() {
    let long = "lorem ipsum ".repeat(3_500);
    let (harness, _shown) = one_cell(named_col("note", "text", true), Value::Text(long.clone()));
    let cell = grid_cell_of(harness.tab(), 0, 1);

    crate::ui::grid::begin_edit(&cell);

    assert!(cell.inline_text().is_none(), "40 KB of text opened in a one-line field");
    let view =
        crate::test_support::first_descendant_of_type::<sourceview5::View>(&cell).expect("the multi-line editor");
    let buffer = view.buffer();
    assert_eq!(buffer.text(&buffer.start_iter(), &buffer.end_iter(), true), long);
    crate::test_support::descendants(&cell)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
        .find(|button| button.has_css_class("suggested-action"))
        .expect("the Save button")
        .emit_clicked();
    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "saving the text as it was recorded an edit"
    );
    assert!(!cell.is_editing());
}

#[gtk4::test]
fn bigint_edit_is_exact() {
    let fetched = Value::Int(1_234_567_890_123_456_789);
    let (harness, _shown) = one_cell(named_col("n", "bigint", false), fetched.clone());
    let cell = grid_cell_of(harness.tab(), 0, 1);

    let editor = type_into(&cell, "1234567890123456790");
    assert_eq!(
        editor.input_purpose(),
        gtk4::InputPurpose::Number,
        "a signed integer field offers a number keypad"
    );
    editor.emit_activate();

    assert_eq!(pending_value(&harness, &fetched), Value::Int(1_234_567_890_123_456_790));
}

#[gtk4::test]
#[expect(
    clippy::approx_constant,
    reason = "a double with every digit it can hold, which is the point, not pi"
)]
fn pressing_enter_on_float_keeps_full_precision() {
    let fetched = Value::Float64(3.141_592_653_589_79);
    let (harness, _shown) = one_cell(named_col("x", "double precision", false), fetched);
    let cell = grid_cell_of(harness.tab(), 0, 1);

    crate::ui::grid::begin_edit(&cell);
    let editor = cell.inline_text().expect("a one-line field");
    assert_eq!(editor.text(), "3.14159265358979");
    editor.emit_activate();

    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "Enter rounded the value it opened on"
    );
}

#[gtk4::test]
fn null_int_opens_empty_with_null_placeholder() {
    let (harness, _shown) = one_cell(named_col("n", "integer", true), Value::Null);
    let cell = grid_cell_of(harness.tab(), 0, 1);

    crate::ui::grid::begin_edit(&cell);

    let editor = cell.inline_text().expect("a one-line field");
    assert_eq!(editor.text(), "", "NULL opened as the text of its sentinel");
    assert_eq!(editor.placeholder_text().as_deref(), Some("NULL"));
}

#[gtk4::test]
fn clearing_not_null_int_without_default_shows_required_toast() {
    let fetched = Value::Int(5);
    let (harness, _shown) = one_cell(named_col("n", "integer", false), fetched.clone());
    let toasts = toasts(harness.tab());
    let cell = grid_cell_of(harness.tab(), 0, 1);

    let editor = type_into(&cell, "");
    assert_eq!(editor.placeholder_text().as_deref(), Some("Required"));
    editor.emit_activate();

    assert_eq!(*toasts.borrow(), ["This column needs a value".to_owned()]);
    assert_eq!(harness.tracker.pending_count(), 0);
    assert_eq!(cell_text(&cell), "5");
}

#[gtk4::test]
fn draft_not_null_with_default_placeholder_is_default() {
    let mut level = col_with_default("integer", "0");
    level.name = "level".to_owned();
    let (harness, _shown) = one_cell(level, Value::Int(3));
    harness.tab().send(BrowseTabInput::InsertRow);
    let mut cell = None;
    wait_until(WAIT, || {
        cell = crate::test_support::descendants(harness.tab())
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .find(|cell| cell.column() == 1 && cell.row().is_some_and(|row| row.draft_id().is_some()));
        cell.is_some()
    })
    .expect("the new row's cell is drawn");
    let cell = cell.expect("a cell");
    cell.cancel_edit();
    assert_eq!(cell_text(&cell), "DEFAULT", "a cell left to the server read as NULL");

    crate::ui::grid::begin_edit(&cell);

    let editor = cell.inline_text().expect("a one-line field");
    assert_eq!(editor.text(), "");
    assert_eq!(editor.placeholder_text().as_deref(), Some("DEFAULT"));
}

#[gtk4::test]
fn pasted_newlines_in_text_cell_are_kept() {
    let fetched = Value::Text("a".into());
    let (harness, _shown) = one_cell(named_col("note", "text", true), fetched.clone());
    let cell = grid_cell_of(harness.tab(), 0, 1);

    let editor = paste_into(&cell, "first line\nsecond line");
    editor.emit_activate();

    assert_eq!(
        pending_value(&harness, &fetched),
        Value::Text("first line\nsecond line".into())
    );
}

#[gtk4::test]
fn a_line_break_pasted_into_a_number_keeps_the_first_line() {
    let fetched = Value::Int(1);
    let (harness, _shown) = one_cell(named_col("n", "integer", true), fetched.clone());
    let cell = grid_cell_of(harness.tab(), 0, 1);

    let editor = paste_into(&cell, "42\n43");
    assert_eq!(editor.text(), "42");
    editor.emit_activate();

    assert_eq!(pending_value(&harness, &fetched), Value::Int(42));
}

#[gtk4::test]
fn tinyint1_value_2_renders_inconsistent_with_exact_tooltip() {
    let mut flag = named_col("flag", "tinyint(1)", false);
    flag.column_type.kind = tablepro_core::column::ColumnKind::Bool(tablepro_core::column::BoolStorage::Integer);
    let (harness, _shown) = one_cell(flag, Value::Int(2));
    let cell = grid_cell_of(harness.tab(), 0, 1);

    let check = cell.check_button().expect("a check button");

    assert!(check.is_inconsistent(), "2 showed as true or false");
    assert_eq!(check.tooltip_text().as_deref(), Some("2"));
    check.set_active(true);
    assert_eq!(pending_value(&harness, &Value::Int(2)), Value::Int(1));
}

fn a_date(year: i32, month: u32, day: u32) -> Value {
    Value::Date(tablepro_core::value::Temporal::Finite(
        chrono::NaiveDate::from_ymd_opt(year, month, day).expect("a date"),
    ))
}

#[gtk4::test]
fn calendar_preselects_date_value() {
    let (harness, _shown) = one_cell(named_col("day", "date", true), a_date(2024, 2, 29));
    let cell = grid_cell_of(harness.tab(), 0, 1);

    crate::ui::grid::begin_edit(&cell);

    let calendar = calendar_of(&cell).expect("a date opened its calendar");
    assert_eq!(calendar.date().ymd(), (2024, 2, 29));
}

#[gtk4::test]
fn picking_a_day_commits_it() {
    let fetched = a_date(2024, 2, 29);
    let (harness, _shown) = one_cell(named_col("day", "date", true), fetched.clone());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    crate::ui::grid::begin_edit(&cell);
    let calendar = calendar_of(&cell).expect("the calendar");

    let picked = gtk4::glib::DateTime::from_utc(2024, 3, 1, 0, 0, 0.0).expect("a day");
    calendar.set_date(&picked);

    assert_eq!(pending_value(&harness, &fetched), a_date(2024, 3, 1));
    assert!(!cell.is_editing());
}

/// The middle of the first of the calendar's labels that `matches`,
/// once the popover has laid it out.
fn calendar_label(calendar: &gtk4::Calendar, matches: impl Fn(&gtk4::Widget) -> bool) -> (f64, f64) {
    let mut found = None;
    wait_until(WAIT, || {
        found = crate::test_support::descendants(calendar)
            .into_iter()
            .find(|widget| widget.width() > 0 && matches(widget));
        found.is_some()
    })
    .expect("the label is drawn");
    let label = found.expect("a label");
    let middle = gtk4::graphene::Point::new(label.width() as f32 / 2.0, label.height() as f32 / 2.0);
    let point = label
        .compute_point(calendar, &middle)
        .expect("the label is inside the calendar");
    (f64::from(point.x()), f64::from(point.y()))
}

fn selected_day(calendar: &gtk4::Calendar) -> (f64, f64) {
    calendar_label(calendar, |label| {
        label.has_css_class("day-number") && label.state_flags().contains(gtk4::StateFlags::SELECTED)
    })
}

/// What the calendar hears when a primary click at `(x, y)` ends.
fn release_on(calendar: &gtk4::Calendar, (x, y): (f64, f64)) {
    let controllers = calendar.observe_controllers();
    for gesture in
        (0..controllers.n_items()).filter_map(|index| controllers.item(index).and_downcast::<gtk4::GestureClick>())
    {
        gesture.emit_by_name::<()>("released", &[&1i32, &x, &y]);
    }
}

fn release_space(calendar: &gtk4::Calendar) {
    use gtk4::glib::translate::IntoGlib;
    let controllers = calendar.observe_controllers();
    for keys in (0..controllers.n_items())
        .filter_map(|index| controllers.item(index).and_downcast::<gtk4::EventControllerKey>())
    {
        keys.emit_by_name::<()>(
            "key-released",
            &[
                &gtk4::gdk::Key::space.into_glib(),
                &0u32,
                &gtk4::gdk::ModifierType::empty(),
            ],
        );
    }
}

/// Open the cell's calendar until its popover shows. Test processes
/// share one X display, where another test's window can close an
/// autohide popover before it maps.
fn open_calendar(cell: &GridCell) -> gtk4::Calendar {
    for _ in 0..5 {
        crate::ui::grid::begin_edit(cell);
        if let Some(calendar) = calendar_of(cell)
            && wait_until(Duration::from_secs(2), || calendar.is_mapped() && calendar.width() > 0).is_ok()
        {
            return calendar;
        }
        cell.cancel_edit();
        drain_main_context();
    }
    panic!("the calendar never showed");
}

fn shown_day(calendar: &gtk4::Calendar) -> Value {
    let (year, month, day) = calendar.date().ymd();
    a_date(year, u32::try_from(month).unwrap(), u32::try_from(day).unwrap())
}

#[gtk4::test]
fn clicking_today_on_a_null_date_commits_it() {
    let (harness, _shown) = one_cell(named_col("day", "date", true), Value::Null);
    let cell = grid_cell_of(harness.tab(), 0, 1);
    let calendar = open_calendar(&cell);
    let today = shown_day(&calendar);

    release_on(
        &calendar,
        calendar_label(&calendar, |label| label.has_css_class("day-name")),
    );
    assert!(cell.is_editing(), "a click on a weekday name picked a day");
    release_on(&calendar, selected_day(&calendar));

    assert_eq!(pending_value(&harness, &Value::Null), today);
    assert!(!cell.is_editing());
}

#[gtk4::test]
fn picking_the_same_day_in_another_month_commits_it() {
    let fetched = a_date(2024, 3, 15);
    let (harness, _shown) = one_cell(named_col("day", "date", true), fetched.clone());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    let calendar = open_calendar(&cell);

    // As the next-month arrow does, this moves the date without a
    // day-selected.
    calendar.set_date(&gtk4::glib::DateTime::from_utc(2024, 4, 15, 0, 0, 0.0).expect("a day"));
    assert!(cell.is_editing(), "a month change picked a day");
    release_on(&calendar, selected_day(&calendar));

    assert_eq!(pending_value(&harness, &fetched), a_date(2024, 4, 15));
}

#[gtk4::test]
fn space_on_the_selected_day_commits_it() {
    let (harness, _shown) = one_cell(named_col("day", "date", true), Value::Null);
    let cell = grid_cell_of(harness.tab(), 0, 1);
    let calendar = open_calendar(&cell);
    let today = shown_day(&calendar);

    release_space(&calendar);

    assert_eq!(pending_value(&harness, &Value::Null), today);
}

#[gtk4::test]
fn opening_calendar_on_existing_date_records_no_edit() {
    let (harness, _shown) = one_cell(named_col("day", "date", true), a_date(2024, 2, 29));
    let cell = grid_cell_of(harness.tab(), 0, 1);
    crate::ui::grid::begin_edit(&cell);
    let popover = crate::test_support::first_descendant_of_type::<gtk4::Popover>(&cell).expect("the calendar popover");

    popover.popdown();
    wait_until(WAIT, || popover.parent().is_none()).expect("the popover closes");

    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "opening the calendar recorded its own day"
    );
    assert!(!cell.is_editing());
}

#[gtk4::test]
fn out_of_range_date_opens_inline_editor() {
    let (harness, _shown) = one_cell(named_col("day", "date", true), a_date(12_000, 1, 1));
    let cell = grid_cell_of(harness.tab(), 0, 1);

    crate::ui::grid::begin_edit(&cell);

    assert!(
        calendar_of(&cell).is_none(),
        "the calendar opened on a year it cannot show"
    );
    let editor = cell.inline_text().expect("a one-line field");
    assert!(editor.text().contains("12000"), "{}", editor.text());
}

#[gtk4::test]
fn read_only_cells_use_inscription_not_selectable_label() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let _shown = Shown::new(harness.tab());
    // A saved row's key, which the row is named by and cannot change.
    let cell = grid_cell_of(harness.tab(), 0, 0);

    assert!(cell.lock().is_some());
    assert!(
        cell.display().is_some(),
        "a locked cell does not draw in an Inscription"
    );
    assert!(
        crate::test_support::descendants(&cell)
            .iter()
            .all(|widget| !widget.is::<gtk4::Label>()),
        "a locked cell carries a selectable label"
    );
    crate::ui::grid::begin_edit(&cell);
    assert!(!cell.is_editing(), "a locked cell opened for editing");
}

/// More rows than a delete marks without asking first.
const DOZEN: [&str; 12] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"];

/// The confirmation a bulk delete is waiting on, by its ticket.
fn confirming(tab: &BrowseTab) -> Option<(u64, libadwaita::AlertDialog)> {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    tab.imp().model.borrow().as_ref().and_then(|model| {
        model
            .confirming_delete
            .as_ref()
            .map(|pending| (pending.ticket, pending.dialog.clone()))
    })
}

/// Every row selected and Delete pressed, which asks before marking.
fn ask_to_delete_every_row(harness: &Harness) -> libadwaita::AlertDialog {
    wait_until(WAIT, || harness.shown().len() == DOZEN.len()).expect("the first page");
    harness.selection().select_all();
    delete_rows(harness.tab());
    let (_, dialog) = confirming(harness.tab()).expect("a bulk delete asks first");
    assert_eq!(harness.tracker.pending_count(), 0);
    dialog
}

fn answer_delete(dialog: &libadwaita::AlertDialog) {
    dialog.emit_by_name::<()>("response", &[&"delete"]);
    drain_main_context();
}

fn change_schema(harness: &Harness, done: impl Fn(&[ColumnInfo]) -> bool) {
    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(BrowseTabInput::SchemaChanged);
    wait_until(WAIT, || done(&harness.tab().columns())).expect("the new columns");
}

/// Closing the dialog after the answer answers again with its close
/// response, and the rows stay marked.
#[gtk4::test]
fn a_confirmed_bulk_delete_marks_every_selected_row() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&DOZEN)));
    let harness = Harness::open(script, []);
    let _shown = Shown::new(harness.tab());
    let dialog = ask_to_delete_every_row(&harness);

    answer_delete(&dialog);
    libadwaita::prelude::AdwDialogExt::force_close(&dialog);
    drain_main_context();

    assert_eq!(harness.tracker.pending_count(), DOZEN.len());
    assert!(confirming(harness.tab()).is_none());
}

#[gtk4::test]
fn a_bulk_delete_waiting_while_the_primary_key_moves_is_cancelled() {
    let mut script = serving_table();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(vec![column("id", false), column("name", true)]));
    script.query_bound.always(FakeReply::ok(rows(&DOZEN)));
    let harness = Harness::open(script, []);
    let _shown = Shown::new(harness.tab());
    let toasts = toasts(harness.tab());
    let dialog = ask_to_delete_every_row(&harness);

    change_schema(&harness, |columns| {
        columns.iter().any(|column| column.name == "name" && column.primary_key)
    });
    answer_delete(&dialog);

    assert!(confirming(harness.tab()).is_none(), "the confirmation outlived the key");
    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "rows were marked by the key they had before"
    );
    assert_eq!(toasts.borrow().len(), 1, "{:?}", toasts.borrow());
}

#[gtk4::test]
fn a_bulk_delete_waiting_while_a_column_is_added_marks_its_rows_under_the_new_columns() {
    let widened = [column("id", true), column("name", false), column("email", false)];
    let mut script = serving_table();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(widened.to_vec()));
    script.query_bound.always(FakeReply::ok(rows(&DOZEN)));
    let harness = Harness::open(script, []);
    let _shown = Shown::new(harness.tab());
    let dialog = ask_to_delete_every_row(&harness);

    change_schema(&harness, |columns| columns.len() == widened.len());
    assert!(
        confirming(harness.tab()).is_some(),
        "a change that keeps the key cancelled the delete"
    );
    answer_delete(&dialog);

    assert_eq!(harness.tracker.pending_count(), DOZEN.len());
    assert_eq!(
        harness.tracker.row_state(&key(0)),
        crate::services::change_tracker::RowState::PendingDelete
    );
}

/// What this thread logs, as text.
#[derive(Clone, Default)]
pub(super) struct LogLines(Arc<std::sync::Mutex<Vec<u8>>>);

impl LogLines {
    pub(super) fn text(&self) -> String {
        let bytes = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

impl std::io::Write for LogLines {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[gtk4::test]
fn a_failed_row_count_logs_its_category_and_not_the_server_message() {
    let lines = LogLines::default();
    let subscriber = tracing_subscriber::fmt()
        .with_ansi(false)
        .with_max_level(tracing::Level::DEBUG)
        .with_writer({
            let lines = lines.clone();
            move || lines.clone()
        })
        .finish();
    let _logging = tracing::subscriber::set_default(subscriber);
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
fn a_second_delete_replaces_the_waiting_confirmation() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&DOZEN)));
    let harness = Harness::open(script, []);
    let _shown = Shown::new(harness.tab());
    ask_to_delete_every_row(&harness);
    let (first, _) = confirming(harness.tab()).expect("the first confirmation");

    delete_rows(harness.tab());
    drain_main_context();
    let (second, dialog) = confirming(harness.tab()).expect("the closed confirmation cancelled the new one");
    assert_ne!(first, second);
    harness.tab().send(BrowseTabInput::BulkDeleteAnswered {
        ticket: first,
        confirmed: true,
    });
    drain_main_context();

    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "an answer to the replaced confirmation marked the rows"
    );
    assert_eq!(confirming(harness.tab()).map(|(ticket, _)| ticket), Some(second));
    answer_delete(&dialog);
    assert_eq!(harness.tracker.pending_count(), DOZEN.len());
}

#[gtk4::test]
fn insert_row_opens_the_new_rows_first_editable_cell() {
    let (harness, shown) = one_cell(named_col("name", "text", true), Value::Text("Ada".into()));
    grid_cell_of(harness.tab(), 0, 1);

    harness.tab().send(BrowseTabInput::InsertRow);

    let mut editing = None;
    wait_until(WAIT, || {
        editing = crate::test_support::descendants(harness.tab())
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .find(|cell| cell.inline_text().is_some());
        editing.is_some()
    })
    .expect("the new row opens for editing");
    let cell = editing.expect("an editing cell");
    assert!(cell.row().is_some_and(|row| row.draft_id().is_some()));
    assert_eq!(cell.column(), 0, "a new row sets its own key first");
    let focus = gtk4::prelude::GtkWindowExt::focus(&shown.0).expect("a focused widget");
    assert_eq!(GridCell::from_focus(&focus).as_ref(), Some(&cell));
}
