use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_test_support::FakeReply;

use super::super::SaveInput;
use super::{
    Harness, Shown, WAIT, action_enabled, column_view, grid_cell_of, key, pending_bar_shown, rename, rows,
    serving_table, type_into,
};
use crate::services::change_tracker::{RowKey, StatementSource};
use crate::test_support::{drain_main_context, wait_until};

fn two_rows() -> Harness {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness
}

/// What the gutter says of the row keyed `key`, `None` when it has no
/// pending change.
fn row_state(harness: &Harness, key: &RowKey) -> Option<String> {
    let grid = harness.grid();
    let row = grid.store().row_for(key).expect("the row is on the page");
    grid.tracked().row_state(&row).text()
}

fn selected_keys(harness: &Harness) -> Vec<Option<RowKey>> {
    harness.grid().selected_rows().iter().map(|row| row.key()).collect()
}

fn fail_at(harness: &Harness, id: i64) {
    harness
        .tab()
        .send(SaveInput::MarkErrorRow(StatementSource::Update { row_key: key(id) }));
    drain_main_context();
}

/// D5: Ctrl+S with a value still in its editor saves that value.
#[gtk4::test]
fn save_commits_an_open_edit_first_and_stays_on_while_it_is_open() {
    let harness = two_rows();
    let _shown = Shown::new(harness.tab());
    let saved = std::rc::Rc::new(std::cell::Cell::new(0));
    let sink = saved.clone();
    harness.tab().connect_save_requested(move |_| sink.set(sink.get() + 1));
    let cell = grid_cell_of(harness.tab(), 0, 1);

    type_into(&harness, &cell, "Ada Lovelace");
    assert_eq!(harness.tracker.pending_count(), 0);
    wait_until(WAIT, || action_enabled(harness.tab(), "save")).expect("Save is off while a value is typed");

    harness
        .tab()
        .activate_action("browse.save", None)
        .expect("the browse group");

    assert_eq!(
        harness.tracker.pending_count(),
        1,
        "the save went without what was typed"
    );
    assert_eq!(saved.get(), 1);
    assert!(!cell.is_editing(), "the editor outlived the save");
}

/// F5 asks the window first when the tab has unsaved changes, and what is
/// typed in an open editor is one of them.
#[gtk4::test]
fn a_refresh_counts_what_is_typed_in_an_open_editor() {
    let harness = two_rows();
    let _shown = Shown::new(harness.tab());
    let refreshes = crate::test_support::SignalLog::connect(harness.tab(), "refresh-requested", |_| ());
    let cell = grid_cell_of(harness.tab(), 0, 1);
    type_into(&harness, &cell, "Ada Lovelace");

    harness
        .tab()
        .activate_action("browse.refresh", None)
        .expect("the browse group");

    assert_eq!(refreshes.count(), 1);
    assert_eq!(
        harness.tracker.pending_count(),
        1,
        "the window asked without the typed value"
    );
}

/// The bar's own states are tested with the bar; this is the tab's wiring.
#[gtk4::test]
fn stop_saving_follows_the_save_and_reaches_the_window() {
    let harness = two_rows();
    let stops = std::rc::Rc::new(std::cell::Cell::new(0));
    let stop_sink = stops.clone();
    harness
        .tab()
        .connect_stop_save_requested(move |_| stop_sink.set(stop_sink.get() + 1));
    let stop = harness.tab().imp().pending_bar.imp().stop_button.get();
    harness.activate_grid("insert-row");

    harness.tab().send(SaveInput::SaveStarted);
    assert!(stop.is_visible(), "a running save offered no Stop Saving");

    stop.emit_clicked();
    assert_eq!(stops.get(), 1);

    harness.tab().send(SaveInput::SaveFailed("rolled back".to_owned()));
    assert!(!stop.is_visible(), "Stop Saving outlived the save");
}

/// A failed save brings its row into view and marks it, with no timer:
/// the mark stays until the row is changed.
#[gtk4::test]
fn a_failed_save_marks_its_row_until_it_is_changed() {
    let harness = two_rows();
    let _shown = Shown::new(harness.tab());
    grid_cell_of(harness.tab(), 1, 1);

    fail_at(&harness, 1);

    assert_eq!(
        selected_keys(&harness),
        [Some(key(1))],
        "the failed row was not brought into view"
    );
    assert_eq!(row_state(&harness, &key(1)).as_deref(), Some("Not saved"));
    assert_eq!(row_state(&harness, &key(0)), None);
    std::thread::sleep(std::time::Duration::from_millis(500));
    drain_main_context();
    assert!(harness.tracker.is_error_row(&key(1)), "the mark went on its own");

    harness.apply_delta(&harness.tracker.apply(rename(1, "Grace", "Grace Hopper")));

    assert!(!harness.tracker.is_error_row(&key(1)));
    assert_eq!(row_state(&harness, &key(1)).as_deref(), Some("Modified"));
}

#[gtk4::test]
fn a_second_failed_row_takes_the_mark_off_the_first() {
    let harness = two_rows();
    let _shown = Shown::new(harness.tab());
    grid_cell_of(harness.tab(), 1, 1);

    fail_at(&harness, 1);
    fail_at(&harness, 0);

    assert_eq!(row_state(&harness, &key(0)).as_deref(), Some("Not saved"));
    assert_eq!(
        row_state(&harness, &key(1)),
        None,
        "the first row still reads as not saved"
    );
    assert_eq!(selected_keys(&harness), [Some(key(0))]);
}

#[gtk4::test]
fn the_next_save_takes_the_mark_off() {
    let harness = two_rows();
    let _shown = Shown::new(harness.tab());
    harness.apply_delta(&harness.tracker.apply(rename(1, "Grace", "Grace Hopper")));
    fail_at(&harness, 1);
    assert_eq!(row_state(&harness, &key(1)).as_deref(), Some("Not saved"));

    let _saving = harness.tracker.begin_save().expect("a save").expect("the edit");
    harness.tab().send(SaveInput::SaveStarted);

    assert_eq!(row_state(&harness, &key(1)).as_deref(), Some("Modified"));
}

/// Discard empties the footer, which slides away with the focus in it,
/// so the focus goes to the rows.
#[gtk4::test]
fn discard_hands_the_focus_to_the_grid() {
    let harness = two_rows();
    let shown = Shown::new(harness.tab());
    harness.activate_grid("insert-row");
    wait_until(WAIT, || pending_bar_shown(harness.tab())).expect("the footer");
    let discard = harness.tab().imp().pending_bar.imp().discard_button.get();
    assert!(discard.grab_focus());

    harness.tab().send(SaveInput::DiscardAll);

    let view = column_view(harness.tab());
    let focus = gtk4::prelude::GtkWindowExt::focus(&shown.0);
    assert!(
        focus.is_some_and(|focus| focus == *view.upcast_ref::<gtk4::Widget>() || focus.is_ancestor(&view)),
        "the focus left with the footer"
    );
}

/// The close prompts discard through the tracker and keep no delta, so
/// the grid rebuilds its drafts from the tracker.
#[gtk4::test]
fn a_discard_the_window_made_takes_the_new_rows_off_the_grid() {
    let harness = two_rows();
    harness.activate_grid("insert-row");
    assert_eq!(harness.drafts(), 1);
    let _ = harness.tracker.discard();

    harness.tab().send(SaveInput::DiscardAll);

    assert_eq!(harness.drafts(), 0, "the discarded row stayed in the grid");
    assert_eq!(harness.store().n_items(), 2);
    assert!(!pending_bar_shown(harness.tab()));
}

/// The pending bar's Discard drops the undo history with the edits, so
/// it asks first, as F5 does.
#[gtk4::test]
fn discard_asks_before_it_drops_the_pending_changes() {
    use libadwaita::prelude::{AdwDialogExt, AdwWindowExt, AlertDialogExt};
    let harness = two_rows();
    let window = crate::test_support::OwnedWindow::presented(libadwaita::Window::new());
    window.set_content(Some(harness.tab()));
    harness.activate_grid("insert-row");
    let discard = harness.tab().imp().pending_bar.imp().discard_button.get();
    let alert = || {
        let mut shown = None;
        wait_until(WAIT, || {
            shown = window.visible_dialog().and_downcast::<libadwaita::AlertDialog>();
            shown.is_some()
        })
        .expect("Discard asks first");
        shown.expect("the alert")
    };

    discard.emit_clicked();
    let first = alert();
    assert_eq!(harness.tracker.pending_count(), 1, "the edit went before the answer");
    assert_eq!(first.close_response(), "cancel");
    first.emit_by_name::<()>("response", &[&"cancel"]);
    first.force_close();
    drain_main_context();
    assert_eq!(harness.tracker.pending_count(), 1, "Cancel dropped the edit");

    discard.emit_clicked();
    let second = alert();
    second.emit_by_name::<()>("response", &[&"discard"]);
    second.force_close();

    wait_until(WAIT, || harness.tracker.pending_count() == 0).expect("the confirmed discard");
    assert_eq!(harness.drafts(), 0);
    window.set_content(None::<&gtk4::Widget>);
}
