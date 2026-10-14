use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use libadwaita as adw;
use tablepro_core::{DriverError, LossPhase, QueryResult, Value};
use tablepro_test_support::{CallCounters, FakeReply};

use super::BrowseTabInput;
use super::tests::{Harness, Shown, WAIT, after_next_frame, column_view, key, rows, serving_table, text};
use crate::test_support::{drain_main_context, wait_until};
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
    let name = view
        .columns()
        .item(1)
        .and_downcast::<gtk4::ColumnViewColumn>()
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
