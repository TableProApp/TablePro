use std::sync::Arc;

use gtk4::gdk;
use gtk4::prelude::*;
use libadwaita::prelude::*;
use tablepro_core::Value;
use tablepro_core::edit::CellInput;

use super::{editing, none, press, two_text_rows};
use crate::services::change_tracker::RowState;
use crate::services::grid::edit_policy;
use crate::test_support::{drain_main_context, respond, wait_until};
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, key, named, page, persisted, two_text_columns};
use crate::ui::data_grid::{GridRequest, RowData};

fn draft_cells(grid: &Grid, position: u32) -> Vec<CellInput> {
    let draft_id = grid
        .grid
        .store()
        .row(position)
        .and_then(|row| row.draft_id())
        .expect("a new row");
    grid.tracker.draft_inputs(draft_id).expect("the draft's cells")
}

fn name(value: &str) -> CellInput {
    CellInput::Value(Value::Text(value.to_owned()))
}

fn select_all_from(grid: &Grid, position: u32, column: usize) {
    grid.focus(position, column);
    grid.grid.selection().select_all();
    drain_main_context();
}

fn set_confirm_bulk_delete(grid: &Grid, confirm: bool) {
    grid.grid
        .config()
        .expect("a configured grid")
        .settings
        .set_confirm_bulk_delete(confirm)
        .expect("the setting is written");
}

#[gtk4::test]
fn insert_row_puts_a_draft_on_top_and_edits_it() {
    let grid = two_text_rows();
    grid.focus(1, 1);

    assert!(press(&grid, gdk::Key::n, gdk::ModifierType::CONTROL_MASK));
    drain_main_context();

    assert_eq!(grid.grid.store().draft_count(), 1);
    assert_eq!(
        draft_cells(&grid, 0),
        [CellInput::Value(Value::Null), CellInput::Value(Value::Null)]
    );
    let cell = editing(&grid);
    assert_eq!(
        (cell.position(), cell.column()),
        (Some(0), 0),
        "a draft sets its own key"
    );
    assert!(
        grid.take_requests()
            .iter()
            .any(|request| matches!(request, GridRequest::PendingChanged))
    );
}

/// D1: the menu inserted a row the toolbar refused, on a table whose
/// rows cannot be saved.
#[gtk4::test]
fn insert_and_duplicate_are_off_without_a_primary_key() {
    let grid = Grid::open(
        vec![named("id", "integer", false), named("name", "text", false)],
        vec![vec![Value::Int(1), Value::Text("A".into())]],
    );
    let cell = grid.focus(0, 1);
    assert!(grid.grid.open_cell_menu(&cell, None));

    for action in [
        "insert-row",
        "duplicate-rows",
        "delete-rows",
        "paste",
        "edit",
        "set-null",
    ] {
        assert!(!grid.is_enabled(action), "{action} was on");
    }
    grid.grid.actions().activate_action("insert-row", None);
    grid.grid.actions().activate_action("duplicate-rows", None);
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }
    drain_main_context();
    assert!(!press(&grid, gdk::Key::n, gdk::ModifierType::CONTROL_MASK));
    drain_main_context();

    assert_eq!(grid.grid.store().draft_count(), 0);
    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn a_grid_that_only_shows_rows_offers_no_change() {
    let grid = Grid::build(
        GridSpec::results(two_text_columns()),
        crate::ui::data_grid::test_grid::results(&[vec![Value::Int(1), Value::Text("A".into())]]),
    );
    grid.focus(0, 1);

    for action in [
        "edit",
        "toggle",
        "set-null",
        "insert-row",
        "duplicate-rows",
        "delete-rows",
        "paste",
    ] {
        assert!(!grid.is_enabled(action), "{action} was on");
    }
    assert!(grid.grid.edit().draft_rows().is_empty());
}

#[gtk4::test]
fn duplicated_rows_keep_their_order_on_screen_and_after_a_refresh() {
    let rows = vec![
        vec![Value::Int(0), Value::Text("Ada".into())],
        vec![Value::Int(1), Value::Text("Grace".into())],
    ];
    let grid = Grid::open(two_text_columns(), rows.clone());
    select_all_from(&grid, 0, 1);

    grid.activate("duplicate-rows");

    let names = |grid: &Grid| (draft_cells(grid, 0)[1].clone(), draft_cells(grid, 1)[1].clone());
    assert_eq!(names(&grid), (name("Ada"), name("Grace")));
    assert_eq!(
        draft_cells(&grid, 0)[0],
        CellInput::Value(Value::Null),
        "the copy took the key the database owns"
    );
    grid.grid.replace_rows(persisted(&rows), 0);
    assert_eq!(
        names(&grid),
        (name("Ada"), name("Grace")),
        "a refresh turned them around"
    );
    assert_eq!(grid.grid.store().draft_count(), 2);
}

#[gtk4::test]
fn delete_marks_saved_rows_drops_drafts_and_ends_the_selection() {
    let grid = two_text_rows();
    grid.insert_draft();
    select_all_from(&grid, 0, 1);

    assert!(press(&grid, gdk::Key::Delete, none()));

    assert_eq!(grid.grid.store().draft_count(), 0);
    assert_eq!(grid.tracker.row_state(&key(1)), RowState::PendingDelete);
    assert_eq!(grid.tracker.row_state(&key(2)), RowState::PendingDelete);
    assert_eq!(grid.grid.selected_count(), 0);
}

#[gtk4::test]
fn delete_is_off_for_rows_without_a_key() {
    let mut spec = GridSpec::table(two_text_columns());
    spec.policy = Some(edit_policy(false, true, true));
    let grid = Grid::build(
        spec,
        vec![RowData::persisted(
            None,
            Arc::from([Value::Int(1), Value::Text("A".into())]),
        )],
    );
    grid.focus(0, 1);

    assert!(!grid.is_enabled("delete-rows"));
    assert!(!press(&grid, gdk::Key::Delete, none()));
    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn a_bulk_delete_asks_first() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), page(0..12));
    select_all_from(&grid, 0, 1);

    grid.activate("delete-rows");
    let question = grid.grid.edit().question().expect("twelve rows ask first");
    assert_eq!(question.heading().as_deref(), Some("Delete 12 Rows?"));
    assert_eq!(grid.tracker.pending_count(), 0, "the rows went before the answer");
    respond(&question, "cancel");
    drain_main_context();
    assert_eq!(grid.tracker.pending_count(), 0);
    assert!(grid.grid.edit().question().is_none());

    grid.activate("delete-rows");
    respond(&grid.grid.edit().question().expect("asked again"), "delete");

    wait_until(WAIT, || grid.tracker.pending_count() == 12).expect("every row is marked");
    assert_eq!(grid.grid.selected_count(), 0);
}

#[gtk4::test]
fn a_bulk_delete_goes_at_once_when_preferences_say_not_to_ask() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), page(0..12));
    set_confirm_bulk_delete(&grid, false);
    select_all_from(&grid, 0, 1);

    grid.activate("delete-rows");

    assert!(grid.grid.edit().question().is_none());
    assert_eq!(grid.tracker.pending_count(), 12);
}

/// A second Delete while one waits replaces the question, and the first
/// answer, when it comes, does nothing.
#[gtk4::test]
fn a_second_bulk_delete_replaces_the_question() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), page(0..12));
    select_all_from(&grid, 0, 1);
    grid.activate("delete-rows");
    let first = grid.grid.edit().question().expect("the first question");

    grid.activate("delete-rows");
    let second = grid.grid.edit().question().expect("the second question");

    assert_ne!(first, second);
    drain_main_context();
    assert_eq!(grid.tracker.pending_count(), 0, "the closed question deleted");
    respond(&second, "delete");
    wait_until(WAIT, || grid.tracker.pending_count() == 12).expect("the rows are marked");
}

#[gtk4::test]
fn undo_and_redo_take_a_new_row_away_and_back() {
    let grid = two_text_rows();
    grid.insert_draft();
    grid.take_requests();

    grid.grid.undo();
    assert_eq!(grid.grid.store().draft_count(), 0);
    assert_eq!(grid.tracker.pending_count(), 0);
    grid.grid.redo();
    assert_eq!(grid.grid.store().draft_count(), 1);

    let changed = grid
        .take_requests()
        .iter()
        .filter(|request| matches!(request, GridRequest::PendingChanged))
        .count();
    assert_eq!(changed, 2);
}

#[gtk4::test]
fn discard_drops_every_pending_change() {
    let grid = two_text_rows();
    grid.insert_draft();
    let cell = grid.focus(1, 1);
    let editor = super::type_into(&grid, &cell, "typed");
    assert!(editor.is_visible());

    grid.grid.discard();

    assert_eq!(grid.grid.store().draft_count(), 0);
    assert_eq!(grid.tracker.pending_count(), 0);
    assert!(super::editing_cell(&grid).is_none(), "the editor outlived the discard");
}
