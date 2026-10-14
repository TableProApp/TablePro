//! The review a structure save asks for on its way to the ledger.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::WriteReport;
use tablepro_core::ddl::{DraftColumn, DraftType, TableDraft};
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::dialog_response::{answer, visible_alert};
use super::test_workspace::{WAIT, Workspace, edited_table, window};
use super::{PendingState, SaveOutcome, SaveRejection, SaveStart};
use crate::services::pending_structure::PendingStructure;
use crate::test_support::wait_until;

fn without_n(draft: &mut TableDraft) {
    draft.columns.retain(|column| column.name != "n");
}

fn writing() -> ConnectionScript {
    let mut script = ConnectionScript::default();
    script.write_batch.always(FakeReply::ok(WriteReport::new(vec![None])));
    script
}

fn review_on(window: &adw::Window) -> adw::AlertDialog {
    let mut shown = None;
    wait_until(WAIT, || {
        shown = visible_alert(window);
        shown.is_some()
    })
    .expect("the review");
    shown.expect("the review")
}

fn review_sql(review: &adw::AlertDialog) -> String {
    let buffer = review
        .extra_child()
        .and_then(|child| child.downcast::<gtk::ScrolledWindow>().ok())
        .and_then(|scrolled| scrolled.child())
        .and_then(|child| child.downcast::<sourceview5::View>().ok())
        .expect("the SQL view")
        .buffer();
    buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
}

fn started(starts: &Rc<RefCell<Option<Vec<SaveStart>>>>) -> Vec<SaveStart> {
    wait_until(WAIT, || starts.borrow().is_some()).expect("the save to be asked");
    starts.borrow().clone().expect("the starts")
}

#[gtk4::test]
fn drop_column_save_presents_review_with_sql_child() {
    let workspace = Workspace::open_structure(ConnectionScript::default(), edited_table(without_n));
    let window = window();

    let starts = workspace.start_on(&window);
    let review = review_on(&window);

    assert_eq!(review.heading().as_deref(), Some("Apply 1 Change to “t”?"));
    assert_eq!(review.body(), "Drops column “n” and the data in it.");
    assert_eq!(review_sql(&review), "ALTER TABLE \"t\" DROP COLUMN \"n\";");
    assert!(
        starts.borrow().is_none(),
        "the save started before the review was answered"
    );
    assert_eq!(workspace.handle.ledger().in_flight(), 0);
    assert!(answer(&window, "cancel"));
    started(&starts);
}

#[gtk4::test]
fn cancel_review_sends_nothing() {
    let workspace = Workspace::open_structure(writing(), edited_table(without_n));
    let window = window();

    let starts = workspace.start_on(&window);
    review_on(&window);
    assert!(answer(&window, "cancel"));

    assert_eq!(started(&starts), [SaveStart::Rejected(SaveRejection::ReviewDeclined)]);
    crate::test_support::drain_main_context();
    assert_eq!(CallCounters::get(&workspace.counters().write_batch), 0);
    assert_eq!(workspace.structure.pending_state(), PendingState::Unsaved);
    assert_eq!(workspace.handle.ledger().in_flight(), 0);
    assert!(workspace.settled.borrow().is_empty());
}

#[gtk4::test]
fn apply_review_runs_one_write_batch() {
    let workspace = Workspace::open_structure(writing(), edited_table(without_n));
    let window = window();

    let starts = workspace.start_on(&window);
    review_on(&window);
    assert!(answer(&window, "apply"));

    assert!(matches!(started(&starts).as_slice(), [SaveStart::Started(_)]));
    assert!(matches!(workspace.settle().outcome, SaveOutcome::Committed { .. }));
    assert_eq!(CallCounters::get(&workspace.counters().write_batch), 1);
    assert_eq!(workspace.structure.pending_state(), PendingState::Clean);
}

#[gtk4::test]
fn transactional_additive_save_starts_without_a_review() {
    let pending = edited_table(|draft| {
        draft
            .columns
            .push(DraftColumn::new("c", DraftType::Typed("TEXT".to_owned())));
    });
    let workspace = Workspace::open_structure(writing(), pending);

    assert!(matches!(workspace.start().as_slice(), [SaveStart::Started(_)]));
    workspace.settle();
    assert_eq!(CallCounters::get(&workspace.counters().write_batch), 1);
}

#[gtk4::test]
fn a_rebuild_save_says_it_rebuilds_the_table() {
    let pending = edited_table(|draft| {
        if let Some(n) = draft.columns.iter_mut().find(|column| column.name == "n") {
            n.column_type = DraftType::Typed("TEXT".to_owned());
        }
    });
    let workspace = Workspace::open_structure(ConnectionScript::default(), pending);
    let window = window();

    let starts = workspace.start_on(&window);
    let review = review_on(&window);

    assert_eq!(
        review.body(),
        "Rebuilds the table: copies its rows into a new table and drops the old one.\nChanges column “n” from \
         INTEGER to TEXT. A value the new type can't hold is converted or refused."
    );
    assert!(
        review_sql(&review).contains("DROP TABLE \"t\";"),
        "{}",
        review_sql(&review)
    );
    assert_eq!(
        review.response_appearance("apply"),
        adw::ResponseAppearance::Destructive
    );
    assert!(answer(&window, "cancel"));
    started(&starts);
}

#[gtk4::test]
fn a_draft_changed_during_the_review_is_not_saved() {
    let workspace = Workspace::open_structure(writing(), edited_table(without_n));
    let window = window();

    let starts = workspace.start_on(&window);
    review_on(&window);
    let renamed: PendingStructure = edited_table(|draft| {
        without_n(draft);
        draft.table.name = "u".to_owned();
    });
    workspace.structure.set_pending(Some(renamed));
    assert!(answer(&window, "apply"));

    assert!(matches!(started(&starts).as_slice(), [SaveStart::Started(_)]));
    assert!(matches!(workspace.settle().outcome, SaveOutcome::RolledBack(_)));
    assert_eq!(CallCounters::get(&workspace.counters().write_batch), 0);
    assert_eq!(workspace.structure.pending_state(), PendingState::Unsaved);
}
