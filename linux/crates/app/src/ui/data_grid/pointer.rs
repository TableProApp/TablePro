use gtk4::prelude::*;
use gtk4::{self as gtk, gdk};

use super::{DataGrid, GridCell, GridRow};

/// Where a click landed in the view.
enum Hit {
    Cell(GridCell),
    /// A row outside its data cells: the row number column or the space
    /// after the last column.
    Row(GridRow, u32),
    /// The list below its last row.
    Empty,
    /// The header, which GTK handles itself.
    Header,
    /// An open inline editor, whose own menu cuts, copies and pastes.
    Editor,
}

/// One gesture per button on the view for every cell, resolving the cell
/// under the pointer when a click lands: a gesture per cell adds a quarter
/// or more to every scroll at a hundred columns. Capture phase, so each
/// runs before the list's own row gesture. A double click reaches the grid
/// as the view's own `activate`.
pub fn install(grid: &DataGrid) {
    grid.column_view().add_controller(focus_on_click(grid));
    let gesture = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = grid.downgrade();
    gesture.connect_pressed(move |gesture, n_press, x, y| {
        let Some(grid) = weak.upgrade() else {
            return;
        };
        let claimed = n_press == 1 && grid.menu_at_pointer(hit_at(&grid, x, y), x, y);
        if claimed {
            gesture.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    grid.column_view().add_controller(gesture);
    grid.column_view()
        .connect_query_tooltip(|view, x, y, _, tooltip| cut_text_tooltip(view, x, y, tooltip));
}

/// GTK gives a column view cell no click of its own, so a click focuses
/// the row, on the column focused before. The clicked cell takes the
/// focus first, as a focusable widget in it would, and the row's gesture
/// then keeps it there and selects. The sequence stays the list's.
fn focus_on_click(grid: &DataGrid) -> gtk::GestureClick {
    let gesture = gtk::GestureClick::builder().button(gdk::BUTTON_PRIMARY).build();
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = grid.downgrade();
    gesture.connect_pressed(move |_, _, x, y| {
        if let Some(grid) = weak.upgrade()
            && let Hit::Cell(cell) = hit_at(&grid, x, y)
            && let Some(focusable) = cell.parent()
        {
            focusable.grab_focus();
        }
    });
    gesture
}

/// The longest tooltip; the detail pane shows the rest.
const TOOLTIP_MAX_CHARS: usize = 300;

/// A cell's text when the cell cuts it, one handler for the whole view.
fn cut_text_tooltip(view: &gtk::ColumnView, x: i32, y: i32, tooltip: &gtk::Tooltip) -> bool {
    let Some(text) = cut_text(view, x, y) else {
        return false;
    };
    tooltip.set_text(Some(&text));
    true
}

/// The text of the cell at `x`, `y` when the cell cuts it, up to
/// `TOOLTIP_MAX_CHARS`.
pub(super) fn cut_text(view: &gtk::ColumnView, x: i32, y: i32) -> Option<String> {
    let cell = view
        .pick(f64::from(x), f64::from(y), gtk::PickFlags::DEFAULT)
        .and_then(|picked| GridCell::from_focus(&picked))?;
    let display = cell.display()?;
    let text = display.text().filter(|text| !text.is_empty())?;
    let (width, _) = display.create_pango_layout(Some(&text)).pixel_size();
    if width <= display.width() {
        return None;
    }
    let mut shown: String = text.chars().take(TOOLTIP_MAX_CHARS).collect();
    if shown.len() < text.len() {
        shown.push('…');
    }
    Some(shown)
}

fn hit_at(grid: &DataGrid, x: f64, y: f64) -> Hit {
    let view = grid.column_view();
    let Some(picked) = view.pick(x, y, gtk::PickFlags::DEFAULT) else {
        return Hit::Header;
    };
    let Some(list) = picked
        .ancestor(gtk::ListView::static_type())
        .or_else(|| picked.downcast_ref::<gtk::ListView>().map(|list| list.clone().upcast()))
    else {
        return Hit::Header;
    };
    if picked.is::<gtk::Text>() || picked.ancestor(gtk::Text::static_type()).is_some() {
        return Hit::Editor;
    }
    if let Some(cell) = GridCell::from_focus(&picked) {
        return Hit::Cell(cell);
    }
    // A row widget is the list's direct child; the row number column's
    // cell sits under it.
    let mut widget = Some(picked);
    while let Some(current) = widget {
        if current.parent().as_ref() == Some(&list) {
            return row_of(&current).map_or(Hit::Empty, |(row, position)| Hit::Row(row, position));
        }
        widget = current.parent();
    }
    Hit::Empty
}

/// The row a row widget shows, read from one of its cells.
fn row_of(row_widget: &gtk::Widget) -> Option<(GridRow, u32)> {
    let mut child = row_widget.first_child();
    while let Some(cell_widget) = child {
        if let Some(cell) = cell_widget.first_child().and_downcast::<GridCell>()
            && let (Some(row), Some(position)) = (cell.row(), cell.position())
        {
            return Some((row, position));
        }
        child = cell_widget.next_sibling();
    }
    None
}

impl DataGrid {
    fn menu_at_pointer(&self, hit: Hit, x: f64, y: f64) -> bool {
        let at = gdk::Rectangle::new(x as i32, y as i32, 1, 1);
        match hit {
            Hit::Cell(cell) => self.open_cell_menu(&cell, Some(at)),
            Hit::Row(row, position) => self.open_row_menu(&row, position, at),
            Hit::Empty => self.open_empty_menu(at),
            Hit::Header | Hit::Editor => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use gtk4::graphene;
    use gtk4::prelude::*;

    use super::{Hit, hit_at};
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::{Grid, WAIT, two_text_columns, two_text_values};

    fn point_in(grid: &Grid, widget: &impl IsA<gtk4::Widget>) -> (f64, f64) {
        let view = grid.grid.column_view();
        let mut at = None;
        wait_until(WAIT, || {
            at = widget
                .compute_point(&view, &graphene::Point::new(4.0, 4.0))
                .filter(|_| widget.width() > 0);
            at.is_some()
        })
        .expect("the widget is laid out");
        let at = at.expect("a point in the view");
        (f64::from(at.x()), f64::from(at.y()))
    }

    /// A right click there opens the row's menu, as one on its number does.
    #[gtk4::test]
    fn a_click_after_the_last_column_is_on_the_row() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let row = grid
            .cell_of(2, 1)
            .parent()
            .and_then(|cell| cell.parent())
            .expect("the row");
        let after = row.last_child().expect("the row's last cell");

        let (x, y) = point_in(&grid, &after);

        assert!(matches!(hit_at(&grid.grid, x, y), Hit::Row(_, 1)));
    }

    /// GtkText's own menu cuts, copies and pastes in the open editor.
    #[gtk4::test]
    fn a_right_click_in_the_open_editor_is_left_to_it() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let other = grid.cell_of(2, 1);
        assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 1)));
        let editor = grid.grid.edit().open_text().expect("the editor");

        let (x, y) = point_in(&grid, &editor);
        assert!(matches!(hit_at(&grid.grid, x, y), Hit::Editor));
        let (x, y) = point_in(&grid, &other);
        assert!(matches!(hit_at(&grid.grid, x, y), Hit::Cell(cell) if cell == other));
    }

    /// A click focuses the cell under it, not the column focused before,
    /// and a double click edits that cell.
    #[gtk4::test]
    fn a_click_focuses_the_cell_under_it_and_a_double_click_edits_it() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        KeyInjector::focus_only(&grid.window);
        grid.focus(0, 0);
        let mouse = KeyInjector::connect().expect("an X11 display");
        let clicked = grid.cell_of(2, 1);

        point_in(&grid, &clicked);
        mouse.click(&clicked, (4.0, 4.0), 1).expect("the click");
        wait_until(WAIT, || grid.focused_cell().as_ref() == Some(&clicked))
            .expect("the click left the focus off the clicked cell");
        mouse.click(&clicked, (4.0, 4.0), 2).expect("the double click");
        wait_until(WAIT, || grid.grid.edit().editing_cell().as_ref() == Some(&clicked))
            .expect("the double click edited another cell");
    }
}
