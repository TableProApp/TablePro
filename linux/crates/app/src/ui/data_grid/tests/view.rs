use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::Value;

use super::{keyed, settled_width, text};
use crate::test_support::wait_until;
use crate::ui::data_grid::GridCell;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, two_text_columns};

/// Ask the view for a tooltip at the middle of `cell`, as GTK does when
/// the pointer rests there. `true` when one is shown.
fn asks_tooltip(grid: &Grid, cell: &GridCell) -> bool {
    let view = grid.grid.column_view();
    let bounds = cell.compute_bounds(&view).expect("the cell's bounds");
    let x = (bounds.x() + bounds.width() / 2.0) as i32;
    let y = (bounds.y() + bounds.height() / 2.0) as i32;
    let tooltip = glib::Object::new::<gtk::Tooltip>();
    view.emit_by_name::<bool>("query-tooltip", &[&x, &y, &false, &tooltip])
}

/// Drawn over the view rather than in its place, so the view stays
/// mapped and keeps its row widgets while it holds no row.
#[gtk4::test]
fn the_empty_page_shows_over_the_view_and_goes_with_the_first_row() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), Vec::new());
    let view = grid.grid.column_view();
    let empty = grid.grid.imp().empty_page.get();
    wait_until(WAIT, || view.is_mapped()).expect("the view is on screen");
    let overlay = empty
        .parent()
        .and_downcast::<gtk::Overlay>()
        .expect("the placeholder is drawn over the view");

    assert!(empty.is_visible(), "a grid of no rows showed no placeholder");
    assert!(view.is_ancestor(&overlay));
    assert!(
        !empty.can_target(),
        "the placeholder takes the clicks meant for the rows"
    );

    grid.insert_draft();
    assert!(!empty.is_visible(), "the placeholder stayed over the first row");
    assert!(view.is_mapped(), "the view left the screen while it held no row");

    grid.grid.discard();
    assert!(empty.is_visible());
    assert!(view.is_mapped());
    grid.grid.replace_rows(keyed(&[1]), 0);
    assert!(!empty.is_visible());
    grid.grid.clear_rows();
    assert!(empty.is_visible());
    grid.grid.set_empty_text("No Matches", Some("Change the filter"));
    assert_eq!(empty.title().as_str(), "No Matches");
    assert_eq!(empty.description().as_deref(), Some("Change the filter"));
}

/// GTK makes the header and rows only as wide as the columns unless one
/// expands, so a selection stopped at the last column.
#[gtk4::test]
fn the_header_and_rows_reach_the_grids_edge_and_the_columns_keep_their_width() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), keyed(&[1, 2]));
    let view = grid.grid.column_view();
    let header = view.first_child().expect("the header");
    let row = grid
        .cell_of(1, 1)
        .parent()
        .and_then(|cell| cell.parent())
        .expect("the row");
    let reaches_edge = |widget: &gtk::Widget| {
        widget
            .compute_bounds(&view)
            .is_some_and(|bounds| (bounds.x() + bounds.width() - view.width() as f32).abs() < 1.0)
    };

    wait_until(WAIT, || reaches_edge(&header) && reaches_edge(&row)).expect("the header and rows as wide as the grid");
    for index in 0..2 {
        settled_width(&grid, index);
    }
}

/// The tooltip quotes the whole text, up to 300 characters; GTK keeps
/// no text a test can read back, so this checks only that it shows.
#[gtk4::test]
fn a_cut_cell_has_a_tooltip_and_one_that_fits_has_none() {
    let grid = Grid::open(
        two_text_columns(),
        vec![
            vec![Value::Int(1), text(&"x".repeat(500))],
            vec![Value::Int(2), text("B")],
        ],
    );
    let (cut, fits) = (grid.cell_of(1, 1), grid.cell_of(2, 1));
    wait_until(WAIT, || cut.width() > 0 && fits.width() > 0).expect("the cells are laid out");

    assert!(grid.grid.column_view().has_tooltip());
    assert!(asks_tooltip(&grid, &cut), "a cut value has no tooltip");
    assert!(!asks_tooltip(&grid, &fits), "a value that fits has a tooltip");
}
