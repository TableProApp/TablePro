use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::meta::RowCountEstimate;
use tablepro_core::{DriverError, TimeoutPhase};
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::BrowseTabInput;
use super::tests::{
    Harness, LogLines, WAIT, estimate, full_page, not_null, not_null_name, paging, rows, rows_from, serving_table,
    text, toasts,
};
use crate::services::change_origins::ChangeOrigins;
use crate::test_support::{drain_main_context, wait_until};

fn paginator(harness: &Harness) -> String {
    harness.tab().imp().paginator_label.label().to_string()
}

fn count_button(harness: &Harness) -> gtk4::Button {
    harness.tab().imp().count_button.get()
}

fn count_label(harness: &Harness) -> String {
    harness.tab().imp().count_label.label().to_string()
}

fn count_calls(harness: &Harness) -> usize {
    CallCounters::get(&harness.connection.counters().count_rows)
}

/// A one-row table whose estimate is `estimate`.
fn estimated(rows_estimate: RowCountEstimate) -> ConnectionScript {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    script.table_estimate = Default::default();
    script.table_estimate.always(FakeReply::ok(estimate(rows_estimate)));
    script
}

/// Long enough for a count the tab ran on its own to have been asked.
fn settle() {
    std::thread::sleep(Duration::from_millis(200));
    drain_main_context();
}

#[gtk4::test]
fn large_estimate_offers_count_without_counting() {
    let harness = Harness::open(estimated(RowCountEstimate::Approximate(5_000_000)), []);
    wait_until(WAIT, || paginator(&harness).contains("of about")).expect("the estimate in the paginator");
    settle();

    assert_eq!(count_calls(&harness), 0, "a large table was counted on its own");
    assert!(count_button(&harness).is_visible() && count_button(&harness).is_sensitive());
    assert_eq!(count_label(&harness), "Count Rows");
    assert!(!harness.tab().imp().last_button.is_sensitive());
}

#[gtk4::test]
fn unknown_estimate_offers_count_without_counting() {
    let harness = Harness::open(estimated(RowCountEstimate::Unknown), []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    wait_until(WAIT, || count_button(&harness).is_visible()).expect("Count Rows offered");
    settle();

    assert_eq!(
        count_calls(&harness),
        0,
        "a table with no estimate was counted on its own"
    );
    assert_eq!(paginator(&harness), "Rows 1 – 2");
}

#[gtk4::test]
fn estimate_error_offers_count_and_logs() {
    let lines = LogLines::default();
    let subscriber = tracing_subscriber::fmt()
        .with_ansi(false)
        .with_writer({
            let lines = lines.clone();
            move || lines.clone()
        })
        .finish();
    let _logging = tracing::subscriber::set_default(subscriber);
    let mut script = estimated(RowCountEstimate::Unknown);
    script.table_estimate = Default::default();
    script
        .table_estimate
        .always(FakeReply::err(DriverError::server("pg_class is hidden from hunter2")));
    let harness = Harness::open(script, []);

    wait_until(WAIT, || lines.text().contains("row estimate unavailable")).expect("the failure is logged");
    wait_until(WAIT, || count_button(&harness).is_visible()).expect("Count Rows offered");
    settle();

    let text = lines.text();
    assert!(text.contains("category=Some(Server)"), "{text}");
    assert!(!text.contains("hunter2"), "{text}");
    assert_eq!(count_calls(&harness), 0);
}

#[gtk4::test]
fn small_estimate_counts_automatically() {
    let harness = Harness::open(estimated(RowCountEstimate::Approximate(40)), []);

    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 2 of 2").expect("the exact total");

    assert_eq!(count_calls(&harness), 1);
    assert!(
        !count_button(&harness).is_visible(),
        "Count Rows stayed for an exact total"
    );
}

#[gtk4::test]
fn count_rows_button_counts_and_shows_progress() {
    let mut script = estimated(RowCountEstimate::Unknown);
    script.count_rows = Default::default();
    script.count_rows.always(FakeReply::Late {
        after: Duration::from_millis(300),
        outcome: Ok(2),
    });
    let harness = Harness::open(script, []);
    wait_until(WAIT, || count_button(&harness).is_visible()).expect("Count Rows offered");

    count_button(&harness).emit_clicked();

    assert_eq!(count_label(&harness), "Counting…");
    assert!(!count_button(&harness).is_sensitive());
    assert!(harness.tab().imp().count_spinner.is_visible());
    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 2 of 2").expect("the counted total");
    assert!(!count_button(&harness).is_visible());
}

/// The table is too large to count on its own, so under the filter
/// nothing replaces the count: only the filter itself can stop it.
#[gtk4::test]
fn count_is_cancelled_when_filter_changes() {
    let mut script = estimated(RowCountEstimate::Approximate(5_000_000));
    script.count_rows = Default::default();
    script.count_rows.always(FakeReply::UntilStopped);
    let harness = Harness::open(script, []);
    wait_until(WAIT, || paginator(&harness).contains("of about")).expect("the estimate in the paginator");
    count_button(&harness).emit_clicked();
    wait_until(WAIT, || count_calls(&harness) == 1).expect("the count was asked for");
    let counters = harness.connection.counters();

    harness.tab().send(BrowseTabInput::FilterApplied(not_null_name()));

    wait_until(WAIT, || CallCounters::get(&counters.stopped) == 1).expect("the filter left the count running");
    wait_until(WAIT, || count_label(&harness) == "Count Rows").expect("the stopped count still shows");
    settle();
    assert_eq!(count_calls(&harness), 1, "the filter counted on its own");
}

#[gtk4::test]
fn stale_count_reply_does_not_overwrite_newer_total() {
    let mut script = estimated(RowCountEstimate::Approximate(40));
    script.count_rows = Default::default();
    script
        .count_rows
        .once(FakeReply::Late {
            after: Duration::from_millis(300),
            outcome: Ok(999),
        })
        .always(FakeReply::ok(5));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || count_calls(&harness) == 1).expect("the first count was asked for");

    harness.tab().send(BrowseTabInput::FilterApplied(not_null_name()));
    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 2 of 5").expect("the filtered total");
    std::thread::sleep(Duration::from_millis(500));
    drain_main_context();

    assert_eq!(
        paginator(&harness),
        "Rows 1 – 2 of 5",
        "the replaced count's reply was shown"
    );
}

#[gtk4::test]
fn count_failure_shows_unavailable_with_reason() {
    let mut script = estimated(RowCountEstimate::Approximate(40));
    script.count_rows = Default::default();
    script
        .count_rows
        .once(FakeReply::err(DriverError::server("statement denied")))
        .always(FakeReply::ok(2));
    let harness = Harness::open(script, []);

    // The count and the page are separate reads, and either can land first.
    wait_until(WAIT, || {
        count_label(&harness) == "Try Again" && paginator(&harness) == "Rows 1 – 2 of about 40"
    })
    .expect("the failed count under the first page");
    let tooltip = count_button(&harness)
        .tooltip_text()
        .map(|text| text.to_string())
        .unwrap_or_default();
    assert!(tooltip.contains("statement denied"), "{tooltip}");
    assert!(count_button(&harness).is_sensitive());

    count_button(&harness).emit_clicked();

    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 2 of 2").expect("Try Again counted");
}

#[gtk4::test]
fn save_adjusts_unfiltered_total_without_recount() {
    let harness = Harness::open(estimated(RowCountEstimate::Approximate(40)), []);
    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 2 of 2").expect("the exact total");
    let queries = CallCounters::get(&harness.connection.counters().query_bound);

    harness
        .tab()
        .send(BrowseTabInput::SaveCommitted(ChangeOrigins { inserts: 2, deletes: 1 }));
    wait_until(WAIT, || {
        CallCounters::get(&harness.connection.counters().query_bound) == queries + 1
    })
    .expect("the page read after the save");
    settle();

    assert_eq!(count_calls(&harness), 1, "the save counted the table again");
    assert_eq!(paginator(&harness), "Rows 1 – 2 of 3");
}

#[gtk4::test]
fn save_on_filtered_view_demotes_total_to_about() {
    let harness = Harness::open_filtered(estimated(RowCountEstimate::Approximate(40)), [], not_null_name());
    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 2 of 2").expect("the exact filtered total");

    harness
        .tab()
        .send(BrowseTabInput::SaveCommitted(ChangeOrigins { inserts: 1, deletes: 0 }));

    assert_eq!(paginator(&harness), "Rows 1 – 2 of about 3");
    assert_eq!(count_label(&harness), "Count Rows");
    assert!(count_button(&harness).is_visible());
}

#[gtk4::test]
fn closing_tab_cancels_running_count() {
    let mut script = estimated(RowCountEstimate::Approximate(40));
    script.count_rows = Default::default();
    script.count_rows.always(FakeReply::UntilStopped);
    let mut harness = Harness::open(script, []);
    wait_until(WAIT, || count_calls(&harness) == 1).expect("the count was asked for");
    let counters = harness.connection.counters();

    harness.tab.take();
    drain_main_context();

    wait_until(WAIT, || CallCounters::get(&counters.stopped) == 1).expect("closing the tab left the count running");
}

#[gtk4::test]
fn last_page_waits_for_an_exact_total() {
    let mut script = paging(full_page(0), rows_from(900, &["Linus"]));
    script.table_estimate = Default::default();
    script
        .table_estimate
        .always(FakeReply::ok(estimate(RowCountEstimate::Approximate(5_000_000))));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    wait_until(WAIT, || count_button(&harness).is_visible()).expect("Count Rows offered");
    let last = harness.tab().imp().last_button.get();
    assert!(!last.is_sensitive());
    assert_eq!(
        last.tooltip_text().as_deref(),
        Some("Count rows to go to the last page")
    );
    harness.tab().send(BrowseTabInput::LastPage);
    drain_main_context();
    assert_eq!(CallCounters::get(&harness.connection.counters().query_bound), 1);

    count_button(&harness).emit_clicked();
    wait_until(WAIT, || last.is_sensitive()).expect("Last after the count");
    last.emit_clicked();

    wait_until(WAIT, || harness.shown() == text(&["Linus"])).expect("the last page");
    assert_eq!(harness.tab().current_offset(), 900);
}

fn timed_out() -> DriverError {
    DriverError::Timeout {
        phase: TimeoutPhase::Statement,
        server_cancelled: true,
    }
}

/// A count the user asked for ran out of time. Nothing counts again
/// until they ask, a reconnect included, and least of all under the
/// filter they applied since.
#[gtk4::test]
fn a_failed_count_does_not_run_again_after_a_reconnect() {
    let mut first = estimated(RowCountEstimate::Approximate(5_000_000));
    first.count_rows = Default::default();
    first.count_rows.always(FakeReply::err(timed_out()));
    let harness = Harness::open(
        first,
        [FakeEstablish::Connect(estimated(RowCountEstimate::Approximate(
            5_000_000,
        )))],
    );
    wait_until(WAIT, || paginator(&harness).contains("of about")).expect("the estimate in the paginator");
    count_button(&harness).emit_clicked();
    wait_until(WAIT, || count_label(&harness) == "Try Again").expect("the count that ran out of time");
    harness.tab().send(BrowseTabInput::FilterApplied(not_null_name()));
    wait_until(WAIT, || count_label(&harness) == "Count Rows").expect("the filtered total");

    harness.connection.mark_lost();
    wait_until(WAIT, || harness.session.link_generation().get() == 1).expect("the reconnect");
    settle();
    settle();

    assert_eq!(
        CallCounters::get(&harness.fake.replacement().counters().count_rows),
        0,
        "the reconnect counted the table without being asked"
    );
    assert_eq!(count_calls(&harness), 1);
}

/// Deleting the only row on the last page leaves the table one page
/// shorter, which the exact total says, so the tab moves to the page
/// that is now the last.
#[gtk4::test]
fn saving_away_the_last_page_moves_to_the_new_last_page() {
    let mut script = paging(full_page(0), rows_from(100, &["Linus"]));
    script.count_rows = Default::default();
    script.count_rows.always(FakeReply::ok(101));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || paginator(&harness) == "Rows 1 – 100 of 101").expect("the exact total");
    harness.tab().send(BrowseTabInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus"])).expect("the last page");
    let queries = CallCounters::get(&harness.connection.counters().query_bound);

    harness
        .tab()
        .send(BrowseTabInput::SaveCommitted(ChangeOrigins { inserts: 0, deletes: 1 }));
    wait_until(WAIT, || {
        CallCounters::get(&harness.connection.counters().query_bound) == queries + 1
    })
    .expect("the page read after the save");
    settle();

    assert_eq!(harness.tab().current_offset(), 0, "the tab stayed past the end");
    assert_eq!(
        CallCounters::get(&harness.connection.counters().query_bound),
        queries + 1,
        "the save read a page twice"
    );
    assert_eq!(count_calls(&harness), 1);
}

/// The estimate can land after the user asked for a count. The count
/// gives the total, so it keeps running and keeps its spinner.
#[gtk4::test]
fn an_estimate_that_lands_during_a_count_keeps_it_counting() {
    let mut script = estimated(RowCountEstimate::Unknown);
    script.table_estimate = Default::default();
    script.table_estimate.always(FakeReply::Late {
        after: Duration::from_millis(300),
        outcome: Ok(estimate(RowCountEstimate::Approximate(5_000_000))),
    });
    script.count_rows = Default::default();
    script.count_rows.always(FakeReply::UntilStopped);
    let harness = Harness::open(script, []);
    wait_until(WAIT, || count_button(&harness).is_visible()).expect("Count Rows offered");

    count_button(&harness).emit_clicked();
    wait_until(WAIT, || paginator(&harness).contains("of about")).expect("the estimate");

    assert_eq!(count_label(&harness), "Counting…");
    assert!(!count_button(&harness).is_sensitive());
    assert!(harness.tab().imp().count_spinner.is_visible());
    assert_eq!(count_calls(&harness), 1);
    assert_eq!(CallCounters::get(&harness.connection.counters().stopped), 0);
}

#[gtk4::test]
fn count_rows_under_a_filter_that_no_longer_fits_says_why() {
    let harness = Harness::open(estimated(RowCountEstimate::Approximate(5_000_000)), []);
    wait_until(WAIT, || paginator(&harness).contains("of about")).expect("the estimate in the paginator");
    let toasts = toasts(harness.tab());
    harness.tab().send(BrowseTabInput::FilterApplied(not_null("nickname")));
    wait_until(WAIT, || toasts.borrow().len() == 1).expect("the filter that does not fit");

    count_button(&harness).emit_clicked();

    let shown = toasts.borrow().clone();
    assert_eq!(shown.len(), 2, "Count Rows did nothing and said nothing");
    assert_eq!(shown[1], shown[0]);
    assert_eq!(count_calls(&harness), 0);
}
