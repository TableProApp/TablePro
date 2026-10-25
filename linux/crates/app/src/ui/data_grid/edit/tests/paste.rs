use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use tablepro_core::edit::CellInput;
use tablepro_core::{ColumnInfo, Value};

use super::{pending, press, toasts};
use crate::services::grid::{RowSnapshot, edit_policy};
use crate::test_support::{drain_main_context, respond, wait_until};
use crate::ui::clipboard::{CopyKind, CopyRequest, copy_rows};
use crate::ui::data_grid::edit::paste::PASTE_CONFIRM_ROWS;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, named, persisted};

/// An `id` key, a name and an age, with Ada and Grace saved.
fn people() -> Vec<ColumnInfo> {
    let mut id = named("id", "integer", true);
    id.nullable = false;
    vec![id, named("name", "text", false), named("age", "integer", false)]
}

fn people_holding(saved: Vec<Vec<Value>>) -> Grid {
    Grid::open(people(), saved)
}

fn people_table() -> Grid {
    people_holding(vec![
        vec![Value::Int(0), Value::Text("Ada".into()), Value::Int(36)],
        vec![Value::Int(1), Value::Text("Grace".into()), Value::Int(85)],
    ])
}

/// Paste `text` with no cell to start at, so it lands as new rows.
fn paste_rows(grid: &Grid, text: &str) {
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    grid.grid.clipboard().set_text(text);
    grid.activate("paste");
}

/// Paste `text` at the cell of data column `column` at `position`.
fn paste_at(grid: &Grid, text: &str, position: u32, column: usize) {
    grid.focus(position, column);
    grid.grid.clipboard().set_text(text);
    grid.activate("paste");
}

fn drafts(grid: &Grid) -> usize {
    grid.grid.store().draft_count() as usize
}

fn draft_cells(grid: &Grid, position: u32) -> Vec<CellInput> {
    let draft_id = grid
        .grid
        .store()
        .row(position)
        .and_then(|row| row.draft_id())
        .expect("a new row");
    grid.tracker.draft_inputs(draft_id).expect("the draft's cells")
}

fn int(value: i64) -> CellInput {
    CellInput::Value(Value::Int(value))
}

fn name(value: &str) -> CellInput {
    CellInput::Value(Value::Text(value.to_owned()))
}

fn null() -> CellInput {
    CellInput::Value(Value::Null)
}

/// Copy `rows` of the grid as the copy action does, and wait for the
/// copy to reach the clipboard.
fn copy(grid: &Grid, rows: Vec<RowSnapshot>, kind: CopyKind) {
    const BEFORE: &str = "nothing copied yet";
    let clipboard = grid.grid.clipboard();
    clipboard.set_text(BEFORE);
    let tasks = grid.grid.config().expect("a configured grid").tasks.clone();
    let request = CopyRequest::Rows {
        columns: grid.columns.iter().map(|column| column.result_column()).collect(),
        rows,
        kind,
    };
    copy_rows(&grid.grid, &tasks, request, |_| {});
    let text = || -> Option<String> { clipboard.content()?.value(String::static_type()).ok()?.get().ok() };
    wait_until(WAIT, || text().is_some_and(|text| text != BEFORE)).expect("the copy to land");
}

fn saved_snapshot(grid: &Grid, position: u32) -> RowSnapshot {
    let cells = grid
        .grid
        .store()
        .row(position)
        .and_then(|row| row.cells())
        .expect("the row's cells");
    RowSnapshot::new(cells, Vec::new())
}

#[gtk4::test]
fn pasted_rows_are_new_rows_in_the_order_they_were_copied() {
    let grid = people_table();

    paste_rows(&grid, "7\tLinus\t54\n8\tKen\t\n");

    wait_until(WAIT, || drafts(&grid) == 2).expect("the rows were pasted");
    assert_eq!(draft_cells(&grid, 0), vec![int(7), name("Linus"), int(54)]);
    assert_eq!(draft_cells(&grid, 1), vec![int(8), name("Ken"), null()]);
    assert_eq!(
        grid.grid.store().row(2).and_then(|row| row.key()),
        Some(crate::ui::data_grid::test_grid::key(0)),
        "the saved rows moved above the new ones"
    );
    assert_eq!(toasts(&grid), ["Pasted 2 rows"]);
}

/// The copy offers the cells beside its text, which says the same of a
/// NULL and the text `NULL`, and quotes what it then cannot unquote.
#[gtk4::test]
fn rows_copied_from_the_grid_paste_back_exactly() {
    let grid = people_holding(vec![
        vec![Value::Int(0), Value::Text("NULL".into()), Value::Null],
        vec![Value::Int(1), Value::Text("\"two\nlines\"".into()), Value::Int(3)],
    ]);
    copy(
        &grid,
        vec![saved_snapshot(&grid, 0), saved_snapshot(&grid, 1)],
        CopyKind::Rows,
    );

    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    grid.activate("paste");

    wait_until(WAIT, || drafts(&grid) == 2).expect("the rows were pasted");
    assert_eq!(draft_cells(&grid, 0), vec![int(0), name("NULL"), null()]);
    assert_eq!(draft_cells(&grid, 1), vec![int(1), name("\"two\nlines\""), int(3)]);
}

#[gtk4::test]
fn a_copied_cell_pastes_into_another_cell_as_it_was() {
    let grid = people_holding(vec![
        vec![Value::Int(0), Value::Text("\"two\nlines\"".into()), Value::Null],
        vec![Value::Int(1), Value::Text("Grace".into()), Value::Int(85)],
    ]);
    copy(&grid, vec![saved_snapshot(&grid, 0)], CopyKind::Value(1));

    grid.focus(1, 1);
    grid.activate("paste");

    wait_until(WAIT, || grid.tracker.pending_count() == 1).expect("the cell was edited");
    assert_eq!(pending(&grid, 1, 1), Some(name("\"two\nlines\"")));
}

#[gtk4::test]
fn one_undo_takes_back_the_whole_paste() {
    let grid = people_table();
    paste_rows(&grid, "7\tLinus\t54\n8\tKen\t1\n9\tDennis\t70\n");
    wait_until(WAIT, || drafts(&grid) == 3).expect("the rows were pasted");

    grid.grid.undo();

    assert_eq!(drafts(&grid), 0);
    assert_eq!(grid.tracker.pending_count(), 0);
    grid.grid.redo();
    assert_eq!(drafts(&grid), 3);
    assert_eq!(
        draft_cells(&grid, 0)[1],
        name("Linus"),
        "the redone rows came back in another order"
    );
}

#[gtk4::test]
fn rows_fill_the_columns_from_the_one_the_paste_starts_at() {
    let grid = people_table();

    paste_at(&grid, "Linus\t54\textra\n", 0, 1);

    wait_until(WAIT, || drafts(&grid) == 1).expect("the row was pasted");
    assert_eq!(draft_cells(&grid, 0), vec![null(), name("Linus"), int(54)]);
    assert_eq!(toasts(&grid), ["Pasted 1 row", "Left out 1 value no column could take"]);
}

#[gtk4::test]
fn values_fill_the_columns_in_the_order_the_grid_shows_them() {
    let grid = people_table();
    let view = grid.grid.column_view();
    let (name_column, age_column) = (
        grid.grid.data_view_column(1).expect("the name column"),
        grid.grid.data_view_column(2).expect("the age column"),
    );
    let columns = view.columns();
    let name_at = (0..columns.n_items())
        .find(|position| columns.item(*position).as_ref() == Some(name_column.upcast_ref::<glib::Object>()))
        .expect("the name column");
    view.insert_column(name_at, &age_column);
    assert_eq!(grid.grid.shown_columns(), [0, 2, 1]);

    paste_at(&grid, "7\t54\tLinus\n", 0, 0);

    wait_until(WAIT, || drafts(&grid) == 1).expect("the row was pasted");
    assert_eq!(draft_cells(&grid, 0), vec![int(7), name("Linus"), int(54)]);
}

#[gtk4::test]
fn a_header_line_maps_the_values_by_name() {
    let grid = people_table();

    paste_rows(&grid, "age\tname\tid\n54\tLinus\t7\n");

    wait_until(WAIT, || drafts(&grid) == 1).expect("the row was pasted");
    assert_eq!(draft_cells(&grid, 0), vec![int(7), name("Linus"), int(54)]);
}

#[gtk4::test]
fn one_value_goes_into_the_cell_the_paste_starts_at() {
    let grid = people_table();

    paste_at(&grid, "Lovelace", 0, 1);

    wait_until(WAIT, || grid.tracker.pending_count() == 1).expect("the cell was edited");
    assert_eq!(drafts(&grid), 0, "one value made a new row");
    assert_eq!(pending(&grid, 0, 1), Some(name("Lovelace")));
}

#[gtk4::test]
fn one_value_a_cell_cannot_take_says_why() {
    let grid = people_table();

    paste_at(&grid, "5", 0, 0);
    let mut said = Vec::new();
    wait_until(WAIT, || {
        said.extend(toasts(&grid));
        !said.is_empty()
    })
    .expect("the key said why");
    paste_at(&grid, "old", 0, 2);
    wait_until(WAIT, || {
        said.extend(toasts(&grid));
        said.len() == 2
    })
    .expect("the number said why");

    assert_eq!(grid.tracker.pending_count(), 0);
    assert_eq!(
        said,
        ["A saved row's key can't be changed here", "Enter a whole number"]
    );
}

#[gtk4::test]
fn ctrl_v_pastes_at_the_focused_cell() {
    let grid = people_table();
    grid.focus(1, 2);
    grid.grid.clipboard().set_text("90");

    assert!(press(&grid, gdk::Key::v, gdk::ModifierType::CONTROL_MASK));

    wait_until(WAIT, || grid.tracker.pending_count() == 1).expect("the focused cell was edited");
    assert_eq!(pending(&grid, 1, 2), Some(int(90)));
}

#[gtk4::test]
fn the_cell_menu_pastes_rows_from_its_column() {
    let grid = people_table();
    let cell = grid.cell_of(1, 1);
    grid.grid.clipboard().set_text("Linus\t54\nKen\t81\n");

    assert!(grid.grid.open_cell_menu(&cell, None));
    grid.activate("paste");
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }

    wait_until(WAIT, || drafts(&grid) == 2).expect("the rows were pasted");
    assert_eq!(draft_cells(&grid, 1), vec![null(), name("Ken"), int(81)]);
    wait_until(WAIT, || {
        let selection = grid.grid.selection();
        selection.is_selected(0) && selection.is_selected(1) && grid.grid.selected_count() == 2
    })
    .expect("the pasted rows are the selection");
}

#[gtk4::test]
fn a_value_the_column_refuses_stops_the_paste_and_names_it() {
    let grid = people_table();

    paste_rows(&grid, "7\tLinus\t54\n8\tKen\tforty\n");

    let mut alerts = Vec::new();
    wait_until(WAIT, || {
        alerts.extend(grid.grid.edit().take_alerts());
        !alerts.is_empty()
    })
    .expect("the paste said why it stopped");
    assert_eq!(drafts(&grid), 0, "part of the paste landed");
    assert_eq!(
        alerts,
        ["Couldn't Paste: Line 2, column age: Enter a whole number (the value was “forty”)"]
    );
}

#[gtk4::test]
fn an_empty_clipboard_says_there_is_nothing_to_paste() {
    let grid = people_table();

    paste_rows(&grid, "\n\n");

    let mut said = Vec::new();
    wait_until(WAIT, || {
        said.extend(toasts(&grid));
        !said.is_empty()
    })
    .expect("the paste said why it stopped");
    assert_eq!(said, ["The clipboard has no rows to paste."]);
}

/// Paste follows the grid's policy like every other change: off, with
/// nothing to read, where no pasted row could be saved.
#[gtk4::test]
fn paste_is_off_on_a_read_only_connection_and_without_a_key() {
    for policy in [edit_policy(true, true, true), edit_policy(false, false, true)] {
        let mut spec = GridSpec::table(people());
        spec.policy = Some(policy);
        let grid = Grid::build(
            spec,
            persisted(&[vec![Value::Int(0), Value::Text("Ada".into()), Value::Null]]),
        );

        assert!(!grid.is_enabled("paste"), "{policy:?}");
        grid.grid.clipboard().set_text("7\tLinus\n");
        grid.grid.actions().activate_action("paste", None);
        drain_main_context();

        assert_eq!(grid.tracker.pending_count(), 0);
        assert_eq!(drafts(&grid), 0);
    }
}

#[gtk4::test]
fn a_large_paste_asks_first() {
    let grid = people_table();
    let text: String = (0..=PASTE_CONFIRM_ROWS)
        .map(|n| format!("{}\tuser {n}\t\n", n + 10))
        .collect();

    paste_rows(&grid, &text);

    wait_until(WAIT, || grid.grid.edit().question().is_some()).expect("a paste this large asks first");
    // The question is presented by a task the ask spawned.
    drain_main_context();
    let question = grid.grid.edit().question().expect("the question");
    assert_eq!(grid.tracker.pending_count(), 0, "the rows landed before the answer");
    respond(&question, "paste");

    wait_until(WAIT, || drafts(&grid) == PASTE_CONFIRM_ROWS + 1).expect("the rows were pasted");
    assert_eq!(draft_cells(&grid, 0)[1], name("user 0"));
}

#[gtk4::test]
fn more_lines_than_a_paste_takes_point_to_import_csv() {
    let grid = people_table();
    let text = "x\n".repeat(tablepro_core::import::MAX_PASTED_ROWS + 1);

    paste_rows(&grid, &text);

    let mut said = Vec::new();
    wait_until(WAIT, || {
        said.extend(toasts(&grid));
        !said.is_empty()
    })
    .expect("the paste said why it stopped");
    assert_eq!(
        said,
        ["The clipboard holds too much to paste. Import CSV takes large amounts of data."]
    );
    assert_eq!(grid.tracker.pending_count(), 0);
}

/// The clipboard of another program can take any time to answer, so a
/// paste made while another reads is the only one that lands.
#[gtk4::test]
fn only_the_latest_paste_lands() {
    let grid = people_table();
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    grid.grid.clipboard().set_text("7\tLinus\t54\n");

    for _ in 0..2 {
        grid.grid.activate_action("grid.paste", None).expect("the grid's Paste");
    }

    wait_until(WAIT, || drafts(&grid) > 0).expect("a paste landed");
    drain_main_context();
    assert_eq!(drafts(&grid), 1, "both pastes landed");
}
