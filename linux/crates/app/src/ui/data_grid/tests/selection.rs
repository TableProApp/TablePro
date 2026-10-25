use gtk4::prelude::*;

use super::{int, keyed, selected_ids};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::data_grid::PinnedRow;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, focus_in_grid, key, two_text_columns};

fn five_rows() -> Grid {
    Grid::build(GridSpec::table(two_text_columns()), keyed(&[0, 1, 2, 3, 4]))
}

fn pinned_ids(rows: &[PinnedRow]) -> Vec<i64> {
    rows.iter()
        .filter_map(|row| row.get().and_then(|row| row.cells()))
        .filter_map(|cells| cells.first().and_then(int))
        .collect()
}

/// The rows follow by key, wherever the new page puts them.
#[gtk4::test]
fn a_page_of_the_same_keys_keeps_the_selection_and_the_focused_cell() {
    let grid = five_rows();
    grid.focus(3, 1);
    let selection = grid.grid.selection();
    selection.select_item(1, true);
    selection.select_item(3, false);

    grid.grid.replace_rows(keyed(&[2, 0, 4, 1, 3]), 0);
    drain_main_context();

    assert_eq!(selected_ids(&grid), [1, 3]);
    wait_until(WAIT, || {
        grid.focused_cell()
            .is_some_and(|cell| cell.position() == Some(4) && cell.column() == 1)
    })
    .expect("the focus follows its row");
    let focused = grid
        .focused_cell()
        .and_then(|cell| cell.row())
        .and_then(|row| row.key());
    assert_eq!(focused, Some(key(3)));
}

/// Neither may stay on a row that took another's place.
#[gtk4::test]
fn a_page_of_other_keys_clears_the_selection_and_keeps_the_focus_in_the_grid() {
    let grid = five_rows();
    grid.focus(3, 1);
    let selection = grid.grid.selection();
    selection.select_item(1, true);
    selection.select_item(3, false);

    grid.grid.replace_rows(keyed(&[10, 11, 12, 13, 14]), 0);
    drain_main_context();

    assert!(
        selected_ids(&grid).is_empty(),
        "rows of the new page took the selection"
    );
    assert_eq!(grid.grid.selected_count(), 0);
    assert!(focus_in_grid(&grid), "the focus left the grid");
}

#[gtk4::test]
fn menu_rows_uses_selection_when_clicked_row_is_selected() {
    let grid = five_rows();
    let selection = grid.grid.selection();
    selection.select_item(3, false);
    selection.select_item(1, false);
    let row = grid.grid.store().row(3).expect("a row");

    assert_eq!(
        pinned_ids(&grid.grid.rows_for(&row, 3)),
        [1, 3],
        "the rows are not the selection in position order"
    );
}

#[gtk4::test]
fn menu_rows_uses_only_clicked_row_outside_selection() {
    let grid = five_rows();
    grid.grid.selection().select_range(0, 2, true);
    let row = grid.grid.store().row(4).expect("a row");

    assert_eq!(pinned_ids(&grid.grid.rows_for(&row, 4)), [4]);
    assert_eq!(
        pinned_ids(&grid.grid.rows_for(&row, 1)),
        [4],
        "a selected row at the clicked position stood in for the clicked one"
    );
}
