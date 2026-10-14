use gtk4 as gtk;
use gtk4::prelude::*;

use super::GridCell;
use super::cell_edit::begin_edit;
use super::edit_navigation::{EditDirection, next_edit_target};
use super::grid_columns::ShownColumn;
use super::selection::row_at;

/// The grid cell that holds the keyboard focus in `widget`'s window.
pub(super) fn focused_cell(widget: &impl IsA<gtk::Widget>) -> Option<GridCell> {
    let window = widget.root().and_downcast::<gtk::Window>()?;
    GridCell::from_focus(&gtk::prelude::GtkWindowExt::focus(&window)?)
}

fn n_rows(view: &gtk::ColumnView) -> u32 {
    view.model().map_or(0, |model| model.n_items())
}

/// Focus `column`'s cell in the row at `position`, and return it.
pub(super) fn focus_cell(view: &gtk::ColumnView, position: u32, column: &ShownColumn) -> Option<GridCell> {
    if position >= n_rows(view) {
        return None;
    }
    view.scroll_to(position, Some(&column.view_column), gtk::ListScrollFlags::FOCUS, None);
    let landed = |cell: &GridCell| {
        cell.position() == Some(position) && cell.column() == column.index && cell.column_view().as_ref() == Some(view)
    };
    // `scroll_to` moves the focus only while it is in the list already.
    // Otherwise it marks the cell the list focuses next, which the grab
    // then reaches.
    if !focused_cell(view).is_some_and(|cell| landed(&cell)) {
        view.grab_focus();
    }
    focused_cell(view).filter(landed)
}

/// Give the focus back to `cell` once its editor closed, since the
/// editor took the focus with it.
pub(super) fn return_focus(cell: &GridCell) {
    let (Some(view), Some(position), Some(columns)) = (cell.column_view(), cell.position(), cell.columns()) else {
        return;
    };
    if let Some(column) = columns
        .shown(&view)
        .into_iter()
        .find(|column| column.index == cell.column())
    {
        focus_cell(&view, position, &column);
    }
}

/// Edit the cell Tab or Shift+Tab goes to from `cell`. With none left
/// on the page, the focus stays on `cell`.
pub(super) fn edit_next(cell: &GridCell, direction: EditDirection) {
    let (Some(view), Some(position), Some(columns)) = (cell.column_view(), cell.position(), cell.columns()) else {
        return;
    };
    let shown = columns.shown(&view);
    let Some(from) = shown.iter().position(|column| column.index == cell.column()) else {
        return;
    };
    let opens_editor = |row: u32, column: usize| {
        shown
            .get(column)
            .zip(row_at(&view, row))
            .is_some_and(|(column, row)| column.opens_editor(&row))
    };
    let target = next_edit_target(opens_editor, shown.len(), from, position, n_rows(&view), direction)
        .and_then(|(row, column)| Some((row, shown.get(column)?)));
    match target {
        Some((row, column)) => {
            if let Some(next) = focus_cell(&view, row, column) {
                begin_edit(&next);
            }
        }
        None => {
            if let Some(column) = shown.get(from) {
                focus_cell(&view, position, column);
            }
        }
    }
}

/// Select the row at `position` and edit its first cell that opens an
/// editor. A row with none keeps the focus on the cell the row gave it.
pub(crate) fn edit_row(view: &gtk::ColumnView, position: u32) {
    if position >= n_rows(view) {
        return;
    }
    // Every cell knows the grid's columns, so the row takes the focus
    // first and its cell finds the column to edit. The grab reaches the
    // row when the focus was outside the list, where `scroll_to` only
    // marks it.
    view.scroll_to(
        position,
        None,
        gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
        None,
    );
    view.grab_focus();
    let (Some(columns), Some(row)) = (
        focused_cell(view).and_then(|cell| cell.columns()),
        row_at(view, position),
    ) else {
        return;
    };
    let Some(column) = columns.shown(view).into_iter().find(|column| column.opens_editor(&row)) else {
        return;
    };
    if let Some(cell) = focus_cell(view, position, &column) {
        begin_edit(&cell);
    }
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, gdk};
    use tablepro_core::Value;

    use super::edit_row;
    use crate::test_support::wait_until;
    use crate::ui::grid::GridCell;
    use crate::ui::grid::test_grid::{Grid, WAIT, edited_rows, key, named, text};

    /// Press `key` in the cell's open one-line editor, through the
    /// handler a real key press reaches first.
    fn press_in_editor(cell: &GridCell, key: gdk::Key, modifiers: gdk::ModifierType) -> bool {
        let editor = cell.inline_text().expect("an open one-line editor");
        let controllers = editor.observe_controllers();
        let keys = (0..controllers.n_items())
            .filter_map(|position| controllers.item(position).and_downcast::<gtk::EventControllerKey>())
            .find(|controller| controller.propagation_phase() == gtk::PropagationPhase::Capture)
            .expect("the editor's key handler");
        keys.emit_by_name::<bool>("key-pressed", &[&key, &0u32, &modifiers])
    }

    /// The editing cell once the focus is in its editor.
    fn editing(grid: &Grid) -> GridCell {
        let mut editing = None;
        wait_until(WAIT, || {
            editing = grid.focused_cell().filter(|cell| cell.inline_text().is_some());
            editing.is_some()
        })
        .expect("a cell is open for editing with the focus");
        editing.expect("an editing cell")
    }

    fn at(cell: &GridCell) -> (Option<u32>, usize) {
        (cell.position(), cell.column())
    }

    /// A key, a text, a check box and a text: the key is locked on the
    /// saved rows, and a check box opens no editor.
    fn mixed_rows() -> Grid {
        Grid::open(
            vec![
                named("id", "integer", true),
                named("name", "text", false),
                named("flag", "boolean", false),
                named("note", "text", false),
            ],
            vec![
                vec![
                    Value::Int(1),
                    Value::Text("a".into()),
                    Value::Bool(false),
                    Value::Text("x".into()),
                ],
                vec![
                    Value::Int(2),
                    Value::Text("b".into()),
                    Value::Bool(true),
                    Value::Text("y".into()),
                ],
            ],
        )
    }

    #[gtk4::test]
    fn tab_in_edit_mode_moves_to_next_editable_column() {
        let grid = mixed_rows();
        let name = grid.focus(0, 1);
        crate::ui::grid::begin_edit(&name);
        name.inline_text().expect("an editor").set_text("a2");
        let none = gdk::ModifierType::empty();

        assert!(press_in_editor(&name, gdk::Key::Tab, none));
        let note = editing(&grid);
        assert_eq!(at(&note), (Some(0), 3), "Tab did not skip the check box");
        assert_eq!(
            note.inline_text().map(|editor| editor.text().to_string()).as_deref(),
            Some("x")
        );

        assert!(press_in_editor(&note, gdk::Key::Tab, none));
        let next_row = editing(&grid);
        assert_eq!(at(&next_row), (Some(1), 1), "Tab did not skip the saved row's key");

        assert!(press_in_editor(
            &next_row,
            gdk::Key::ISO_Left_Tab,
            gdk::ModifierType::SHIFT_MASK
        ));
        let back = editing(&grid);
        assert_eq!(back, note, "Shift+Tab did not go back a row");

        assert!(!name.is_editing() && !next_row.is_editing());
        assert_eq!(edited_rows(&grid.take_messages()), vec![(Some(key(1)), 1, text("a2"))]);
    }

    #[gtk4::test]
    fn tab_past_the_last_editable_cell_keeps_the_focus_there() {
        let grid = mixed_rows();
        let note = grid.focus(1, 3);
        crate::ui::grid::begin_edit(&note);

        assert!(press_in_editor(&note, gdk::Key::Tab, gdk::ModifierType::empty()));

        assert!(!note.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&note));
    }

    #[gtk4::test]
    fn escape_cancels_and_returns_focus_to_cell() {
        let grid = mixed_rows();
        let name = grid.focus(1, 1);
        crate::ui::grid::begin_edit(&name);
        name.inline_text().expect("an editor").set_text("typed");

        assert!(press_in_editor(&name, gdk::Key::Escape, gdk::ModifierType::empty()));

        assert!(!name.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&name), "the focus did not come back");
        assert!(grid.take_messages().is_empty(), "Escape sent the typed text");
    }

    #[gtk4::test]
    fn ctrl_tab_in_an_editor_is_left_to_the_window() {
        let grid = mixed_rows();
        let name = grid.focus(1, 1);
        crate::ui::grid::begin_edit(&name);

        assert!(!press_in_editor(&name, gdk::Key::Tab, gdk::ModifierType::CONTROL_MASK));
        assert!(name.is_editing());
    }

    #[gtk4::test]
    fn new_draft_enters_edit_mode_on_first_editable_cell() {
        let mut serial = named("id", "integer", true);
        serial.is_auto_increment = true;
        let grid = Grid::open(
            vec![serial, named("name", "text", false), named("note", "text", false)],
            vec![vec![Value::Int(1), Value::Text("a".into()), Value::Text("x".into())]],
        );
        grid.insert_draft();

        edit_row(&grid.view, 0);

        let cell = editing(&grid);
        assert!(cell.row().is_some_and(|row| row.draft_id().is_some()));
        assert_eq!(cell.column(), 1, "the edit did not skip the auto-increment key");
        let selection = grid.view.model().expect("a selection model");
        assert!(selection.is_selected(0) && !selection.is_selected(1));
    }
}
