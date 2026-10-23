use gtk4 as gtk;
use gtk4::prelude::*;

use super::GridCell;
use super::cell_edit::begin_edit;
use super::edit_navigation::{EditDirection, next_edit_target};
use super::grid_columns::ShownColumn;
use super::inline_editor::commit_inline;
use super::selection::row_at;

fn window_focus(widget: &impl IsA<gtk::Widget>) -> Option<gtk::Widget> {
    let window = widget.root().and_downcast::<gtk::Window>()?;
    gtk::prelude::GtkWindowExt::focus(&window)
}

pub(super) fn focused_cell(widget: &impl IsA<gtk::Widget>) -> Option<GridCell> {
    GridCell::from_focus(&window_focus(widget)?)
}

/// Unlike `focused_cell`, not a cell whose editor has the focus.
fn cell_holding_focus(view: &gtk::ColumnView) -> Option<GridCell> {
    window_focus(view)?.first_child()?.downcast().ok()
}

fn n_rows(view: &gtk::ColumnView) -> u32 {
    view.model().map_or(0, |model| model.n_items())
}

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
    if !cell_holding_focus(view).is_some_and(|cell| landed(&cell)) {
        view.grab_focus();
    }
    cell_holding_focus(view).filter(landed)
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

/// Commit the one-line edit open in `view`, as Return does.
pub(crate) fn commit_open_edit(view: &gtk::ColumnView) {
    let Some(cell) = focused_cell(view) else {
        return;
    };
    if cell.inline_text().is_none() || cell.column_view().as_ref() != Some(view) {
        return;
    }
    commit_inline(&cell);
    return_focus(&cell);
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

/// Select the first `count` rows, where new rows land, and give the
/// first of them the focus.
pub(crate) fn select_top_rows(view: &gtk::ColumnView, count: u32) {
    let Some(model) = view.model() else {
        return;
    };
    let count = count.min(model.n_items());
    if count == 0 {
        return;
    }
    model.select_range(0, count, true);
    view.scroll_to(0, None, gtk::ListScrollFlags::FOCUS, None);
    view.grab_focus();
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use gtk4::prelude::*;
    use gtk4::{self as gtk, gdk, glib};
    use tablepro_core::Value;
    use tablepro_core::edit::CellInput;
    use tablepro_core::value::Temporal;

    use super::edit_row;
    use crate::test_support::{
        FocusThief, after_next_frame, assert_labelled, drain_main_context, first_descendant_of_type, wait_until,
    };
    use crate::ui::grid::test_grid::{Grid, WAIT, edited_rows, key, named, text};
    use crate::ui::grid::{GridCell, begin_edit};

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

    /// GTK ends the focus change by walking up from the field the edit
    /// was in. GTK 4.22 logs a critical forever and never returns when the
    /// field has left its cell by then.
    #[gtk4::test]
    fn the_focus_moving_to_another_cell_commits_the_edit() {
        let grid = mixed_rows();
        let name = grid.focus(0, 1);
        crate::ui::grid::begin_edit(&name);
        name.inline_text().expect("an editor").set_text("a2");

        let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
        let note = grid.focus(1, 3);
        glib::log_set_always_fatal(previous);

        assert!(!name.is_editing(), "the edit outlived the focus");
        assert_eq!(edited_rows(&grid.take_messages()), vec![(Some(key(1)), 1, text("a2"))]);
        assert_eq!(grid.focused_cell().as_ref(), Some(&note));
        assert!(
            !name.state_flags().contains(gtk::StateFlags::FOCUS_WITHIN),
            "the cell the edit left still shows the focus"
        );
    }

    /// Another window taking the focus is no focus change in this one,
    /// so the edit stays open, and typing goes on there once it is back.
    #[gtk4::test]
    fn an_edit_stays_open_while_another_window_has_the_focus() {
        let grid = mixed_rows();
        let name = grid.focus(1, 1);
        crate::ui::grid::begin_edit(&name);
        let editor = name.inline_text().expect("an editor");
        editor.set_text("typed");

        let thief = FocusThief::take_from(&grid.window).expect("another window takes the focus");
        after_next_frame(&grid.window);
        assert!(name.is_editing(), "another window taking the focus ended the edit");
        thief.give_back(&grid.window);
        drain_main_context();
        after_next_frame(&grid.window);

        assert!(name.is_editing(), "the edit ended when the window came back");
        assert!(grid.take_messages().is_empty(), "the half-typed value was sent");
        assert_eq!(
            gtk::prelude::GtkWindowExt::focus(&grid.window).as_ref(),
            Some(editor.upcast_ref::<gtk::Widget>()),
            "the focus left the field"
        );
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

    fn focus_in(grid: &Grid, popover: &gtk::Popover) -> bool {
        gtk::prelude::GtkWindowExt::focus(&grid.window).is_some_and(|focus| focus.is_ancestor(popover))
    }

    /// Open the cell's editor popover with the focus in it. Test processes
    /// share one X display, where another test's window can close an
    /// autohide popover before it maps.
    fn open_popover(grid: &Grid, cell: &GridCell) -> gtk::Popover {
        for _ in 0..5 {
            begin_edit(cell);
            if let Some(popover) = first_descendant_of_type::<gtk::Popover>(cell)
                && wait_until(Duration::from_secs(2), || {
                    popover.is_mapped() && focus_in(grid, &popover)
                })
                .is_ok()
            {
                return popover;
            }
            cell.cancel_edit();
            drain_main_context();
        }
        panic!("the editor popover never showed");
    }

    fn button(popover: &gtk::Popover, label: &str) -> gtk::Button {
        crate::test_support::descendants(popover)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some(label))
            .expect("the popover's button")
    }

    fn day(day: u32) -> Value {
        Value::Date(Temporal::Finite(
            chrono::NaiveDate::from_ymd_opt(2024, 3, day).expect("a date"),
        ))
    }

    fn dated_row() -> Grid {
        Grid::open(
            vec![named("id", "integer", true), named("day", "date", false)],
            vec![vec![Value::Int(1), day(15)]],
        )
    }

    #[gtk4::test]
    fn picking_a_day_returns_focus_to_cell() {
        let grid = dated_row();
        let cell = grid.focus(0, 1);
        let popover = open_popover(&grid, &cell);
        let calendar = first_descendant_of_type::<gtk::Calendar>(&popover).expect("the calendar");

        calendar.set_date(&glib::DateTime::from_utc(2024, 3, 16, 0, 0, 0.0).expect("a day"));
        after_next_frame(&grid.window);

        assert!(!cell.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&cell), "the focus left the grid");
        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(1)), 1, CellInput::Value(day(16)))]
        );
    }

    #[gtk4::test]
    fn closing_the_calendar_returns_focus_to_cell() {
        let grid = dated_row();
        let cell = grid.focus(0, 1);
        let popover = open_popover(&grid, &cell);

        // As Escape does.
        popover.popdown();
        after_next_frame(&grid.window);

        assert!(!cell.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&cell), "the focus left the grid");
        assert!(grid.take_messages().is_empty());
    }

    #[gtk4::test]
    fn removing_the_row_under_an_open_calendar_drops_its_edit() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("day", "date", false)],
            vec![vec![Value::Int(1), day(15)], vec![Value::Int(2), day(20)]],
        );
        let cell = grid.focus(0, 1);
        let popover = open_popover(&grid, &cell);

        grid.store.remove(0);
        after_next_frame(&grid.window);

        assert!(popover.parent().is_none(), "the popover outlived its row");
        assert!(!cell.is_editing());
        assert!(grid.take_messages().is_empty());
        let focus = gtk::prelude::GtkWindowExt::focus(&grid.window);
        assert!(
            focus.is_some_and(|focus| focus == *grid.view.upcast_ref::<gtk::Widget>() || focus.is_ancestor(&grid.view)),
            "the focus left the grid"
        );
    }

    /// Tab moves an edit across the columns, and no header is focused on
    /// the way, so each editor names the column it edits.
    #[gtk4::test]
    fn every_cell_editor_is_named_by_its_column() {
        let grid = Grid::open(
            vec![
                named("id", "integer", true),
                named("note", "text", false),
                named("day", "date", false),
            ],
            vec![
                vec![Value::Int(1), Value::Text("one\ntwo".into()), day(15)],
                vec![Value::Int(2), Value::Text("plain".into()), day(16)],
            ],
        );

        let one_line = grid.cell_of(2, 1);
        begin_edit(&one_line);
        let field = one_line.inline_text().expect("the one-line editor");
        assert_eq!(assert_labelled(&field), Ok(()));
        one_line.cancel_edit();

        let lines = grid.cell_of(1, 1);
        begin_edit(&lines);
        let view = first_descendant_of_type::<sourceview5::View>(&lines).expect("the multi-line editor");
        assert_eq!(assert_labelled(&view), Ok(()));
        let save = crate::test_support::descendants(&lines)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Save"))
            .expect("the Save button");
        assert!(gtk::test_accessible_has_property(
            &save,
            gtk::AccessibleProperty::KeyShortcuts
        ));
        lines.cancel_edit();

        let dated = grid.cell_of(1, 2);
        begin_edit(&dated);
        let calendar = first_descendant_of_type::<gtk::Calendar>(&dated).expect("the calendar");
        assert_eq!(assert_labelled(&calendar), Ok(()));
        dated.cancel_edit();
    }

    #[gtk4::test]
    fn the_multi_line_editor_returns_focus_to_cell() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("note", "text", false)],
            vec![vec![Value::Int(1), Value::Text("one\ntwo".into())]],
        );
        let cell = grid.focus(0, 1);

        let popover = open_popover(&grid, &cell);
        button(&popover, "Cancel").emit_clicked();
        after_next_frame(&grid.window);
        assert!(!cell.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&cell), "Cancel left the grid");

        let popover = open_popover(&grid, &cell);
        let view = first_descendant_of_type::<sourceview5::View>(&popover).expect("the multi-line editor");
        view.buffer().set_text("one\nthree");
        button(&popover, "Save").emit_clicked();
        after_next_frame(&grid.window);
        assert!(!cell.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&cell), "Save left the grid");
        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(1)), 1, text("one\nthree"))]
        );
    }
}
