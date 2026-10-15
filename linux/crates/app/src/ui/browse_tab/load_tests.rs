use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use libadwaita as adw;
use tablepro_core::{ColumnInfo, DriverError, LossPhase, QueryResult, Value};
use tablepro_test_support::{CallCounters, FakeReply};

use super::BrowseTabInput;
use super::tests::{
    Harness, Shown, WAIT, column, column_view, delete_action, full_page, header_titles, key, not_null_name, rows,
    serving_table, text, toasts,
};
use crate::test_support::{after_next_frame, drain_main_context, wait_until};
use crate::ui::grid::GridCell;

fn banner(harness: &Harness) -> adw::Banner {
    harness.tab().imp().stale_banner.get()
}

/// Every value the tab's loading signal carried, in order.
fn loading_log(harness: &Harness) -> Rc<RefCell<Vec<bool>>> {
    let log = Rc::new(RefCell::new(Vec::new()));
    let sink = log.clone();
    harness
        .tab()
        .connect_loading_changed(move |_, loading| sink.borrow_mut().push(loading));
    log
}

/// A page whose rows are keyed `ids`, each named after its key.
fn keyed(ids: &[i64]) -> QueryResult {
    let names: Vec<String> = ids.iter().map(|id| format!("row {id}")).collect();
    let names: Vec<&str> = names.iter().map(String::as_str).collect();
    let mut page = rows(&names);
    for (row, id) in page.rows.iter_mut().zip(ids) {
        row[0] = Value::Int(*id);
    }
    page
}

#[gtk4::test]
fn refresh_keeps_grid_visible_and_sets_tab_loading() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(rows(&["before"])))
        .always(FakeReply::Late {
            after: Duration::from_millis(300),
            outcome: Ok(rows(&["after"])),
        });
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["before"])).expect("the first page");
    let loading = loading_log(&harness);

    harness.tab().send(BrowseTabInput::Refresh);

    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
    assert_eq!(harness.shown(), text(&["before"]), "the refresh blanked the rows");
    assert!(harness.tab().is_loading());
    wait_until(WAIT, || harness.shown() == text(&["after"])).expect("the refreshed page");
    assert!(!harness.tab().is_loading());
    assert_eq!(*loading.borrow(), [true, false]);
}

#[gtk4::test]
fn failed_refresh_keeps_rows_and_reveals_stale_banner() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(rows(&["kept"])))
        .always(FakeReply::err(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        }));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    let counters = harness.connection.counters();

    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed refresh was not shown");

    assert_eq!(CallCounters::get(&counters.query_bound), 2);
    assert_eq!(harness.shown(), text(&["kept"]), "the failed refresh dropped the rows");
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
    assert!(!harness.tab().is_loading());
    let tooltip = banner(&harness).tooltip_text().map(|text| text.to_string());
    assert_eq!(tooltip.as_deref(), Some("The connection was closed. Try reconnecting."));
}

#[gtk4::test]
fn stale_banner_retry_reloads_and_hides_banner() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(rows(&["kept"])))
        .once(FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(rows(&["fresh"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the stale banner");

    banner(&harness).emit_by_name::<()>("button-clicked", &[]);

    wait_until(WAIT, || harness.shown() == text(&["fresh"])).expect("Retry read the page again");
    assert!(
        !banner(&harness).is_revealed(),
        "the banner outlived the read that landed"
    );
}

#[gtk4::test]
fn first_load_failure_shows_error_page_with_try_again() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::err(DriverError::server("relation <users> is gone")))
        .always(FakeReply::ok(rows(&["back"])));
    let harness = Harness::open(script, []);

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the error page");
    let imp = harness.tab().imp();
    let description = imp
        .error_page
        .description()
        .map(|text| text.to_string())
        .unwrap_or_default();
    assert!(description.contains("relation &lt;users&gt; is gone"), "{description}");
    assert!(!banner(&harness).is_revealed());
    assert!(imp.retry_button.has_css_class("pill") && imp.retry_button.has_css_class("suggested-action"));

    imp.retry_button.emit_clicked();

    wait_until(WAIT, || harness.shown() == text(&["back"])).expect("Try Again read the page");
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
}

#[gtk4::test]
fn refresh_restores_multi_row_selection_and_focus_by_key() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(keyed(&[0, 1, 2, 3, 4])))
        .always(FakeReply::ok(keyed(&[9, 0, 1, 2, 3, 4])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 5).expect("the first page");
    let shown = Shown::new(harness.tab());
    let view = column_view(harness.tab());
    let name = crate::ui::grid::data_columns(&view)
        .into_iter()
        .nth(1)
        .expect("the name column");
    view.scroll_to(3, Some(&name), gtk4::ListScrollFlags::FOCUS, None);
    view.grab_focus();
    let focused_cell = || gtk4::prelude::GtkWindowExt::focus(&shown.0).and_then(|focus| GridCell::from_focus(&focus));
    wait_until(WAIT, || focused_cell().is_some_and(|cell| cell.position() == Some(3))).expect("a cell takes the focus");
    let selection = harness.selection();
    let picked = gtk4::Bitset::new_empty();
    picked.add(1);
    picked.add(3);
    selection.set_selection(&picked, &gtk4::Bitset::new_range(0, selection.n_items()));

    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || harness.shown().len() == 6).expect("the refreshed page");
    after_next_frame(&shown.0);

    let selected: Vec<_> = crate::ui::grid::selected_positions(&harness.selection())
        .into_iter()
        .map(|position| harness.grid_row(position).key().cloned())
        .collect();
    assert_eq!(selected, [Some(key(1)), Some(key(3))]);
    wait_until(WAIT, || {
        focused_cell()
            .is_some_and(|cell| cell.column() == 1 && cell.row().and_then(|row| row.key().cloned()) == Some(key(3)))
    })
    .expect("the focus did not come back to the cell it was in");
}

#[gtk4::test]
fn a_selection_is_not_put_back_after_a_failed_refresh() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(keyed(&[0, 1, 2])))
        .once(FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(keyed(&[0, 1, 2])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 3).expect("the first page");
    let selection = harness.selection();
    selection.select_item(0, true);
    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the stale banner");
    selection.select_item(2, true);

    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || !banner(&harness).is_revealed()).expect("the second refresh");
    drain_main_context();

    let selected: Vec<_> = crate::ui::grid::selected_positions(&harness.selection())
        .into_iter()
        .map(|position| harness.grid_row(position).key().cloned())
        .collect();
    assert_eq!(
        selected,
        [Some(key(2))],
        "the selection from before the failed refresh came back"
    );
}

fn error_text(harness: &Harness) -> String {
    harness
        .tab()
        .imp()
        .error_page
        .description()
        .map(|text| text.to_string())
        .unwrap_or_default()
}

#[gtk4::test]
fn columns_failure_shows_error_page_not_spinner() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .always(FakeReply::err(DriverError::server("permission denied")));
    let harness = Harness::open(script, []);

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the tab stayed on its spinner");

    assert!(
        error_text(&harness).contains("permission denied"),
        "{}",
        error_text(&harness)
    );
    assert!(!harness.tab().is_loading());
    assert_eq!(CallCounters::get(&harness.connection.counters().query_bound), 0);
}

#[gtk4::test]
fn empty_column_list_is_a_load_failure() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script.fetch_columns.always(FakeReply::ok(Vec::<ColumnInfo>::new()));
    let harness = Harness::open(script, []);

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the tab stayed on its spinner");

    assert_eq!(
        error_text(&harness),
        gtk4::glib::markup_escape_text(&crate::ui::tab_load::LoadFailure::NoColumns.message()).as_str()
    );
    assert_eq!(CallCounters::get(&harness.connection.counters().query_bound), 0);
}

#[gtk4::test]
fn refresh_after_columns_failure_refetches_columns() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::err(DriverError::server("busy")))
        .always(FakeReply::ok(vec![column("id", true), column("name", false)]));
    script.query_bound.always(FakeReply::ok(rows(&["back"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the error page");

    harness.tab().imp().retry_button.emit_clicked();

    wait_until(WAIT, || harness.shown() == text(&["back"])).expect("the grid after the columns were read again");
    assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 2);
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
}

#[gtk4::test]
fn refresh_failure_of_columns_keeps_cached_columns() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::err(DriverError::server("busy")));
    script.query_bound.always(FakeReply::ok(rows(&["kept"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");

    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed refresh was not shown");

    assert_eq!(header_titles(harness.tab()), ["id", "name"]);
    assert_eq!(harness.tab().columns(), [column("id", true), column("name", false)]);
    assert_eq!(harness.shown(), text(&["kept"]));
    assert_eq!(CallCounters::get(&harness.connection.counters().query_bound), 1);
}

#[gtk4::test]
fn page_column_mismatch_refetches_columns_once() {
    let renamed = [column("id", true), column("full_name", false)];
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        renamed.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), Value::Text("Ada".to_owned())]],
    )));
    let harness = Harness::open(script, []);

    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the mismatched page was shown");

    let counters = harness.connection.counters();
    assert_eq!(CallCounters::get(&counters.fetch_columns), 2);
    assert_eq!(CallCounters::get(&counters.query_bound), 2);
    assert!(
        harness.shown().is_empty(),
        "rows read under other columns reached the grid"
    );
    assert!(
        error_text(&harness).contains("columns changed"),
        "{}",
        error_text(&harness)
    );
}

/// The page under the new filter could not be read, so the error page
/// shows. The rows read without the filter are still in the store,
/// and nothing may act on them from behind it.
#[gtk4::test]
fn the_rows_behind_the_error_page_take_no_action() {
    let mut script = serving_table();
    script
        .query_bound
        .when_sql_contains("IS NOT NULL", FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(rows(&["unfiltered"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown() == text(&["unfiltered"])).expect("the first page");
    harness.selection().select_item(0, true);
    assert!(delete_action(harness.tab()).is_enabled());
    let exported = Rc::new(RefCell::new(0));
    let sink = exported.clone();
    harness
        .tab()
        .connect_export_results(move |_, _| *sink.borrow_mut() += 1);
    let toasts = toasts(harness.tab());

    harness.tab().send(BrowseTabInput::FilterApplied(not_null_name()));
    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the error page");
    harness.tab().send(BrowseTabInput::Export(None));

    assert_eq!(*exported.borrow(), 0, "Export wrote rows the filter does not match");
    assert!(
        !copy_rows_action(harness.tab()).is_enabled(),
        "Copy stayed on for rows behind the error page"
    );
    assert_eq!(*toasts.borrow(), ["Nothing to export"]);
    assert!(
        !delete_action(harness.tab()).is_enabled(),
        "Delete stayed on for rows behind the error page"
    );
    assert_eq!(harness.tab().imp().paginator_label.label(), "");
}

/// Next moved the pager before its read failed, so the way back goes
/// from where the pager is, and the key for it with the button.
#[gtk4::test]
fn a_failed_next_page_leaves_the_way_back_open() {
    let mut script = serving_table();
    // A count below the second page would clamp the pager back to the
    // first before the failed read lands.
    script.count_rows.always(FakeReply::ok(1_000));
    script
        .query_bound
        .once(FakeReply::ok(full_page(0)))
        .once(FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(full_page(0)));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    let imp = harness.tab().imp();
    assert!(!imp.prev_button.is_sensitive());

    harness.tab().send(BrowseTabInput::NextPage);
    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("the error page");

    assert_eq!(harness.tab().current_offset(), 100);
    assert!(imp.first_button.is_sensitive(), "First stayed off past the first page");
    assert!(
        imp.prev_button.is_sensitive(),
        "Previous stayed off past the first page"
    );
    assert!(
        !imp.next_button.is_sensitive(),
        "Next stayed on past a page that was not read"
    );
    harness
        .tab()
        .activate_action("browse.previous-page", None)
        .expect("the action");
    wait_until(WAIT, || harness.visible_page().as_deref() == Some("grid")).expect("the first page again");
    assert_eq!(harness.tab().current_offset(), 0);
    assert!(!imp.prev_button.is_sensitive());
    assert!(imp.next_button.is_sensitive());
}

fn renamed_page() -> QueryResult {
    let renamed = [column("id", true), column("full_name", false)];
    QueryResult::new(
        renamed.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), Value::Text("Ada".to_owned())]],
    )
}

/// The columns read again for a page that came back with others failed.
/// Try Again starts over, so a page that comes back with other columns
/// then gets its own read of them.
#[gtk4::test]
fn try_again_after_a_failed_recheck_reads_the_columns_once_more() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .once(FakeReply::err(DriverError::server("busy")))
        .always(FakeReply::ok(vec![column("id", true), column("name", false)]));
    script
        .query_bound
        .once(FakeReply::ok(renamed_page()))
        .once(FakeReply::ok(renamed_page()))
        .always(FakeReply::ok(rows(&["back"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || error_text(&harness).contains("busy")).expect("the failed read of the columns");

    harness.tab().imp().retry_button.emit_clicked();

    wait_until(WAIT, || harness.shown() == text(&["back"])).expect("the page after the columns were read again");
    assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 4);
}

/// A refresh whose columns failed asked for no page and no estimate. A
/// later read of the columns, for a page that came back with others,
/// must not start them.
#[gtk4::test]
fn a_failed_column_read_leaves_no_read_for_a_later_one_to_start() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .once(FakeReply::err(DriverError::server("busy")))
        .always(FakeReply::ok(vec![column("id", true), column("name", false)]));
    script
        .query_bound
        .once(FakeReply::ok(rows(&["first"])))
        .once(FakeReply::ok(renamed_page()))
        .always(FakeReply::ok(rows(&["back"])));
    let harness = Harness::open(script, []);
    let counters = harness.connection.counters();
    wait_until(WAIT, || harness.shown() == text(&["first"])).expect("the first page");
    wait_until(WAIT, || CallCounters::get(&counters.count_rows) == 1).expect("the count");
    harness.tab().send(BrowseTabInput::Refresh);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed refresh");

    harness.tab().send(BrowseTabInput::SortChanged {
        col_idx: 0,
        ascending: false,
    });
    wait_until(WAIT, || harness.shown() == text(&["back"])).expect("the page after the columns were read again");
    std::thread::sleep(Duration::from_millis(200));
    drain_main_context();

    assert_eq!(CallCounters::get(&counters.fetch_columns), 3);
    assert_eq!(
        CallCounters::get(&counters.table_estimate),
        1,
        "the failed refresh's estimate ran under a later read of the columns"
    );
}

fn copy_rows_action(tab: &super::BrowseTab) -> gtk4::gio::SimpleAction {
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    tab.imp()
        .model
        .borrow()
        .as_ref()
        .map(|model| model.actions.copy_rows.clone())
        .expect("the tab has a model")
}

/// The status page reads its description as markup, where the `&`
/// would leave it empty.
#[gtk4::test]
fn the_loading_page_names_a_table_with_an_ampersand() {
    libadwaita::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let mut script = serving_table();
    script.query_bound.always(FakeReply::Late {
        after: Duration::from_secs(5),
        outcome: Ok(rows(&["late"])),
    });
    let fake = crate::test_support::FakeSession::start(script, [], runtime.tasks());
    let root = tempfile::tempdir().expect("tempdir");
    let tab = super::tests::table_tab(
        &fake.session,
        &runtime,
        &root,
        "R&D",
        Default::default(),
        Default::default(),
        false,
    );
    let shown = || crate::test_support::status_page_description(&tab.imp().loading_page);

    assert_eq!(shown().as_deref(), Some("Fetching rows from R&D"));
    wait_until(WAIT, || tab.is_loading()).expect("the read to start");
    assert_eq!(shown().as_deref(), Some("Fetching rows from R&D"));

    drop(tab);
    runtime.shutdown();
}
