use gtk4 as gtk;
use gtk4::prelude::*;

use super::GridCell;
use super::column_figures::digits_width;
use super::grid_menus::shown_column;

/// Which way a key or a menu item changes a column's width.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ColumnResize {
    Wider,
    Narrower,
}

/// A step is this many digits of the cell's font, so it stays the same
/// number of characters when the text is larger.
const STEP_DIGITS: u32 = 2;

/// Make the column `cell` is in one step wider or narrower, and save the
/// width as a header drag's is. Expand goes off, as GtkTreeView did for
/// these keys: an expanding column takes back part of the space a step
/// frees.
pub(super) fn resize_column(view: &gtk::ColumnView, cell: &GridCell, change: ColumnResize) {
    let Some(column) = shown_column(view, cell) else {
        return;
    };
    let column = column.view_column;
    if !column.is_resizable() {
        view.error_bell();
        return;
    }
    let Some(width) = current_width(&column, cell) else {
        return;
    };
    let step = digits_width(cell, STEP_DIGITS);
    // Never narrower than a step: a fixed width goes below what the cells
    // need, and the column the focus is in stays on screen to widen again.
    let width = match change {
        ColumnResize::Wider => width.saturating_add(step),
        ColumnResize::Narrower => width.saturating_sub(step).max(step),
    };
    column.set_expand(false);
    column.set_fixed_width(width);
}

/// The width a step starts from: the one the last step set, which holds
/// even before the view has laid it out, or else the width on screen,
/// where a header drag starts too.
fn current_width(column: &gtk::ColumnViewColumn, cell: &GridCell) -> Option<i32> {
    match (column.expands(), column.fixed_width()) {
        (false, fixed) if fixed >= 0 => Some(fixed),
        _ => column_width(cell),
    }
}

/// The width of the column `cell` is in, as the view laid it out. The
/// column view's cell widget spans the column, and `width()` would give
/// only its content box, narrower by the theme's padding.
fn column_width(cell: &GridCell) -> Option<i32> {
    let cell_widget = cell.parent()?;
    let bounds = cell_widget.compute_bounds(&cell_widget)?;
    Some(bounds.width().round() as i32)
}

#[cfg(test)]
pub(super) mod tests {
    use std::time::Duration;

    use gtk4::gdk;
    use gtk4::prelude::*;

    use super::{ColumnResize, STEP_DIGITS, column_width, resize_column};
    use crate::test_support::wait_until;
    use crate::ui::grid::ColumnWidthBinding;
    use crate::ui::grid::column_figures::digits_width;
    use crate::ui::grid::test_grid::{Grid, WAIT, two_text_columns, two_text_rows, two_text_values, type_into};

    /// The width the column has on screen, read from the first row's cell.
    pub(in crate::ui::grid) fn shown_width(grid: &Grid, column: usize) -> i32 {
        column_width(&grid.cell_of(1, column)).expect("a drawn cell")
    }

    pub(in crate::ui::grid) fn step(grid: &Grid) -> i32 {
        digits_width(&grid.cell_of(1, 1), STEP_DIGITS)
    }

    /// `Grid::open` waits for the cells, not for the first layout, before
    /// which no width is the one on screen.
    pub(in crate::ui::grid) fn laid_out(grid: Grid) -> Grid {
        wait_until(WAIT, || grid.view.width() > 0).expect("the grid to be laid out");
        grid
    }

    #[gtk4::test]
    fn a_step_wider_starts_from_the_width_on_screen_and_is_saved() {
        let runtime = crate::test_support::test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let widths = ColumnWidthBinding {
            store: crate::persistence::ColumnWidthStore::load(root.path().join("column-widths.json"), &runtime.tasks()),
            connection_id: uuid::Uuid::new_v4(),
            schema: None,
            table: "t".to_owned(),
        };
        let grid = laid_out(Grid::open_with_widths(
            two_text_columns(),
            two_text_values(),
            widths.clone(),
        ));
        let after = shown_width(&grid, 1) + step(&grid);

        resize_column(&grid.view, &grid.cell_of(1, 1), ColumnResize::Wider);

        assert_eq!(grid.column(1).fixed_width(), after);
        assert!(
            !grid.column(1).expands(),
            "an expanding column takes back part of a step"
        );
        assert_eq!(widths.width("name"), Some(after));
        wait_until(WAIT, || shown_width(&grid, 1) == after).expect("the column to be drawn wider");
    }

    #[gtk4::test]
    fn a_step_narrower_shrinks_the_column_on_screen() {
        let grid = laid_out(two_text_rows());
        let after = shown_width(&grid, 1) - step(&grid);

        resize_column(&grid.view, &grid.cell_of(1, 1), ColumnResize::Narrower);

        wait_until(WAIT, || shown_width(&grid, 1) == after).expect("the column to be drawn narrower");
    }

    #[gtk4::test]
    fn a_column_is_never_narrower_than_a_step() {
        let grid = two_text_rows();
        grid.column(1).set_expand(false);
        grid.column(1).set_fixed_width(step(&grid) + 1);

        resize_column(&grid.view, &grid.cell_of(1, 1), ColumnResize::Narrower);
        resize_column(&grid.view, &grid.cell_of(1, 1), ColumnResize::Narrower);

        assert_eq!(grid.column(1).fixed_width(), step(&grid));
    }

    #[gtk4::test]
    fn a_column_that_is_not_resizable_keeps_its_width() {
        let grid = two_text_rows();
        grid.column(1).set_resizable(false);
        grid.column(1).set_fixed_width(300);

        resize_column(&grid.view, &grid.cell_of(1, 1), ColumnResize::Wider);

        assert_eq!(grid.column(1).fixed_width(), 300);
        assert!(grid.column(1).expands());
    }

    /// Pressed through XTEST, the keys meet the list's own arrow bindings
    /// and the cell editor before the grid's controller.
    mod real_keys {
        use super::*;

        const SHIFT_ALT: gdk::ModifierType = gdk::ModifierType::SHIFT_MASK.union(gdk::ModifierType::ALT_MASK);

        fn focused_grid() -> (Grid, crate::test_support::KeyInjector) {
            let grid = laid_out(two_text_rows());
            crate::test_support::KeyInjector::focus_only(&grid.window);
            wait_until(Duration::from_secs(2), || grid.window.is_active()).expect("the window to take the focus");
            let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");
            (grid, keys)
        }

        #[gtk4::test]
        fn shift_alt_right_and_left_resize_the_focused_cells_column() {
            let (grid, keys) = focused_grid();
            grid.focus(0, 1);
            let wider = shown_width(&grid, 1) + step(&grid);

            keys.press(gdk::Key::Right, SHIFT_ALT).expect("the key press");
            wait_until(WAIT, || shown_width(&grid, 1) == wider).expect("Shift+Alt+Right to widen the column");
            keys.press(gdk::Key::Left, SHIFT_ALT).expect("the key press");
            keys.press(gdk::Key::Left, SHIFT_ALT).expect("the key press");

            let narrower = wider - 2 * step(&grid);
            wait_until(WAIT, || shown_width(&grid, 1) == narrower).expect("Shift+Alt+Left to narrow the column");
            assert_eq!(
                grid.focused_cell().map(|cell| cell.column()),
                Some(1),
                "the keys moved the focus"
            );
            assert_eq!(grid.column(0).fixed_width(), -1, "the keys resized another column");
        }

        #[gtk4::test]
        fn an_open_editor_keeps_shift_alt_arrows() {
            let (grid, keys) = focused_grid();
            let cell = grid.focus(0, 1);
            let editor = type_into(&cell, "typed");
            wait_until(Duration::from_secs(2), || editor.has_focus()).expect("the editor to take the focus");

            keys.press(gdk::Key::Right, SHIFT_ALT).expect("the key press");
            crate::test_support::drain_main_context();

            assert_eq!(
                grid.column(1).fixed_width(),
                -1,
                "the key resized the column being edited"
            );
            assert!(cell.is_editing(), "the key ended the edit");
        }
    }
}
