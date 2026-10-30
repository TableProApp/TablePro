mod choices;
mod paste;
mod rows;

use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use tablepro_core::Value;
use tablepro_core::column::BoolStorage;
use tablepro_core::edit::CellInput;

use super::cell_editor::{EditorKey, editor_key};
use super::row_edits::toggled;
use crate::application::ShortcutOwner;
use crate::services::change_tracker::RowState;
use crate::services::grid::display_text::editable_null_sentinel;
use crate::services::grid::{CommitResult, EDIT_MAX_BYTES, EditDirection, EditStart};
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
use crate::test_support::{FocusThief, after_next_frame, assert_labelled, drain_main_context, wait_until};
use crate::ui::data_grid::test_grid::{
    Grid, WAIT, focus_in_grid, key, named, page, text, two_text_columns, two_text_values,
};
use crate::ui::data_grid::{GridCell, GridRequest, GridRow};

pub(super) fn none() -> gdk::ModifierType {
    gdk::ModifierType::empty()
}

pub(super) fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

pub(super) fn editor(grid: &Grid) -> Option<gtk::Text> {
    grid.grid.edit().open_text()
}

pub(super) fn editing_cell(grid: &Grid) -> Option<GridCell> {
    grid.grid.edit().editing_cell()
}

/// Open `cell`'s editor and type `value` over what it opened with.
pub(super) fn type_into(grid: &Grid, cell: &GridCell, value: &str) -> gtk::Text {
    assert!(grid.grid.edit().edit_cell(cell), "the cell took no edit");
    let editor = editor(grid).expect("the cell did not open for editing");
    editor.set_text(value);
    editor
}

/// What the tracker holds for the saved row `id`'s cell, `None` while it
/// shows what was read.
pub(super) fn pending(grid: &Grid, id: i64, column: usize) -> Option<CellInput> {
    grid.tracker.cell_overlay(&key(id), column).pending
}

pub(super) fn toasts(grid: &Grid) -> Vec<String> {
    grid.take_requests()
        .into_iter()
        .filter_map(|request| match request {
            GridRequest::Toast(text) => Some(text),
            _ => None,
        })
        .collect()
}

/// Run what `key` does on the focused cell, as a key press reaching the
/// grid's controllers would. `true` when the grid took the key.
pub(super) fn press(grid: &Grid, key: gdk::Key, modifiers: gdk::ModifierType) -> bool {
    let view: gtk::Widget = grid.grid.column_view().upcast();
    let on_grid: gtk::Widget = grid.grid.clone().upcast();
    let wanted = (key.to_lower(), modifiers);
    [(ShortcutOwner::GridCell, view), (ShortcutOwner::Grid, on_grid)]
        .into_iter()
        .filter_map(|(owner, widget)| Some((owner_controller(&widget, owner)?, widget)))
        .flat_map(|(controller, widget)| {
            shortcuts(&controller)
                .into_iter()
                .map(move |shortcut| (shortcut, widget.clone()))
        })
        .find(|(shortcut, _)| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&wanted))
        })
        .and_then(|(shortcut, widget)| Some((shortcut.action()?, widget)))
        .map(|(action, widget)| action.activate(gtk::ShortcutActionFlags::empty(), &widget, None))
        .expect("the grid binds the key")
}

/// Press `key` in the open editor, through the handler a real key press
/// reaches first.
pub(super) fn press_in_editor(editor: &gtk::Text, key: gdk::Key, modifiers: gdk::ModifierType) -> bool {
    let controllers = editor.observe_controllers();
    let keys = (0..controllers.n_items())
        .filter_map(|position| controllers.item(position).and_downcast::<gtk::EventControllerKey>())
        .find(|controller| controller.propagation_phase() == gtk::PropagationPhase::Capture)
        .expect("the editor's key handler");
    keys.emit_by_name::<bool>("key-pressed", &[&key, &0u32, &modifiers])
}

/// The cell being edited once the focus is in its editor.
pub(super) fn editing(grid: &Grid) -> GridCell {
    let mut cell = None;
    wait_until(WAIT, || {
        cell = editing_cell(grid).filter(|_| grid.grid.edit().editor_has_focus());
        cell.is_some()
    })
    .expect("a cell is open for editing with the focus");
    cell.expect("an editing cell")
}

pub(super) fn details_shown(grid: &Grid) -> bool {
    grid.grid
        .actions()
        .action_state("show-details")
        .and_then(|state| state.get::<bool>())
        .unwrap_or(false)
}

fn at(cell: &GridCell) -> (Option<u32>, usize) {
    (cell.position(), cell.column())
}

/// A key, a text, a boolean and a text: the key is locked on the saved
/// rows, and a boolean toggles rather than opening an editor.
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

fn name_rows(first: Value) -> Grid {
    Grid::open(
        vec![named("id", "integer", true), named("name", "text", false)],
        vec![vec![Value::Int(1), first], vec![Value::Int(2), Value::Text("B".into())]],
    )
}

fn number_row() -> Grid {
    let mut number = named("n", "integer", false);
    number.nullable = false;
    Grid::open(
        vec![named("id", "integer", true), number],
        vec![vec![Value::Int(1), Value::Int(5)]],
    )
}

#[gtk4::test]
fn tab_moves_escape_cancels_and_window_keys_pass() {
    let shift = gdk::ModifierType::SHIFT_MASK;

    assert_eq!(editor_key(gdk::Key::Escape, none()), Some(EditorKey::Cancel));
    assert_eq!(
        editor_key(gdk::Key::Tab, none()),
        Some(EditorKey::Move(EditDirection::Forward))
    );
    assert_eq!(
        editor_key(gdk::Key::ISO_Left_Tab, shift),
        Some(EditorKey::Move(EditDirection::Backward))
    );
    assert_eq!(
        editor_key(gdk::Key::ISO_Left_Tab, none()),
        Some(EditorKey::Move(EditDirection::Backward))
    );
    assert_eq!(
        editor_key(gdk::Key::Tab, shift),
        Some(EditorKey::Move(EditDirection::Backward))
    );
    assert_eq!(editor_key(gdk::Key::Tab, gdk::ModifierType::CONTROL_MASK), None);
    assert_eq!(editor_key(gdk::Key::Tab, gdk::ModifierType::ALT_MASK), None);
    assert_eq!(
        editor_key(gdk::Key::Return, none()),
        None,
        "Return is the field's activate"
    );
}

/// The editor reads keys itself, to leave them to an open preedit, so
/// the table's entries are checked against what it does.
#[gtk4::test]
fn edit_keys_match_cell_editor_entries() {
    let expected = [
        ("cell-editor.cancel", EditorKey::Cancel),
        ("cell-editor.next", EditorKey::Move(EditDirection::Forward)),
        ("cell-editor.previous", EditorKey::Move(EditDirection::Backward)),
    ];
    for (action, outcome) in expected {
        let triggers = crate::application::triggers_for(action);
        assert!(!triggers.is_empty(), "{action} is not in the table");
        for accel in triggers {
            let (key, modifiers) = keystroke(accel);
            assert_eq!(editor_key(key, modifiers), Some(outcome), "{accel}");
        }
    }
}

#[test]
fn a_toggle_writes_the_columns_own_form() {
    assert_eq!(
        toggled(&Value::Bool(false), false, BoolStorage::Native),
        Value::Bool(true)
    );
    assert_eq!(
        toggled(&Value::Bool(true), false, BoolStorage::Native),
        Value::Bool(false)
    );
    assert_eq!(toggled(&Value::Int(0), false, BoolStorage::Integer), Value::Int(1));
    assert_eq!(toggled(&Value::Int(1), false, BoolStorage::Integer), Value::Int(0));
}

#[test]
fn null_default_and_other_numbers_toggle_to_true() {
    assert_eq!(toggled(&Value::Null, false, BoolStorage::Native), Value::Bool(true));
    assert_eq!(toggled(&Value::Null, true, BoolStorage::Integer), Value::Int(1));
    assert_eq!(toggled(&Value::Int(2), false, BoolStorage::Integer), Value::Int(1));
}

#[gtk4::test]
fn f2_starts_editing_focused_text_cell() {
    let grid = two_text_rows();
    grid.focus(1, 1);

    assert!(press(&grid, gdk::Key::F2, none()));

    let editor = editor(&grid).expect("F2 opened no editor");
    assert_eq!(editor.text(), "B");
    assert_eq!(
        editor.selection_bounds(),
        Some((0, 1)),
        "the first key would not replace the value"
    );
}

#[gtk4::test]
fn kp_enter_starts_editing_focused_int_cell() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("n", "integer", false)],
        vec![vec![Value::Int(1), Value::Int(42)]],
    );
    grid.focus(0, 1);

    assert!(press(&grid, gdk::Key::KP_Enter, none()));

    let editor = editor(&grid).expect("KP_Enter opened no editor");
    assert_eq!(editor.text(), "42");
    assert_eq!(editor.input_purpose(), gtk::InputPurpose::Number);
}

#[gtk4::test]
fn return_commits_and_returns_focus_to_cell() {
    let grid = two_text_rows();
    let cell = grid.focus(1, 1);
    assert!(press(&grid, gdk::Key::Return, none()));
    let editor = editor(&grid).expect("Return opened no editor");
    editor.set_text("renamed");

    editor.emit_activate();

    assert_eq!(pending(&grid, 2, 1), Some(text("renamed")));
    assert!(editing_cell(&grid).is_none());
    assert_eq!(grid.focused_cell().as_ref(), Some(&cell), "the focus did not come back");
    assert!(
        grid.take_requests()
            .iter()
            .any(|request| matches!(request, GridRequest::PendingChanged))
    );
}

#[gtk4::test]
fn grid_shortcuts_proceed_while_editing() {
    let grid = two_text_rows();
    let cell = grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&cell));
    editing(&grid);

    assert!(!press(&grid, gdk::Key::Return, none()));
    assert!(!press(&grid, gdk::Key::space, none()));
    assert!(!press(&grid, gdk::Key::BackSpace, gdk::ModifierType::CONTROL_MASK));
    assert!(!press(&grid, gdk::Key::Menu, none()));

    assert!(editor(&grid).is_some(), "a grid key closed the open editor");
    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn grid_keys_proceed_with_no_focused_cell() {
    let grid = two_text_rows();
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    drain_main_context();

    assert!(!press(&grid, gdk::Key::F2, none()));
    assert!(!press(&grid, gdk::Key::BackSpace, gdk::ModifierType::CONTROL_MASK));
    assert_eq!(grid.tracker.pending_count(), 0);
}

/// Return on a locked cell is the list's own activation, which shows
/// the whole value in the detail pane.
#[gtk4::test]
fn focused_read_only_cell_resolves_grid_cell() {
    let grid = two_text_rows();

    let cell = grid.focus(0, 0);

    assert!(cell.lock().is_some(), "a saved row's key was editable");
    assert_eq!(cell.row().and_then(|row| row.key()), Some(key(1)));
    assert!(!press(&grid, gdk::Key::F2, none()), "F2 took a locked cell");
    assert!(!grid.grid.edit().edit_cell(&cell));
    assert!(editing_cell(&grid).is_none());
    grid.grid.column_view().emit_by_name::<()>("activate", &[&0u32]);
    drain_main_context();
    assert!(details_shown(&grid), "Return on a locked cell showed nothing");
}

/// A page that lands between a double click and its editor gives the
/// slot another row, which the click never meant.
#[gtk4::test]
fn a_page_landing_after_a_double_click_opens_no_editor() {
    let grid = two_text_rows();
    grid.focus(0, 1);

    grid.grid.column_view().emit_by_name::<()>("activate", &[&0u32]);
    grid.grid.replace_rows(page(3..5), 0);
    drain_main_context();

    assert!(
        editing_cell(&grid).is_none(),
        "the editor opened on the row the page put there"
    );
}

#[gtk4::test]
fn return_toggles_a_focused_boolean_cell() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("flag", "boolean", false)],
        vec![vec![Value::Int(1), Value::Bool(false)]],
    );
    grid.focus(0, 1);

    assert!(press(&grid, gdk::Key::Return, none()));

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(Value::Bool(true))));
    assert!(editing_cell(&grid).is_none());
}

/// A boolean draws as text (D9), and Space flips it.
#[gtk4::test]
fn space_toggles_a_focused_boolean_and_selects_from_any_other_cell() {
    let grid = mixed_rows();

    grid.focus(0, 2);
    assert!(press(&grid, gdk::Key::space, none()));
    grid.focus(0, 1);
    assert!(
        !press(&grid, gdk::Key::space, none()),
        "Space on a text cell did not go on to select the row"
    );

    assert_eq!(pending(&grid, 1, 2), Some(CellInput::Value(Value::Bool(true))));
    assert_eq!(grid.tracker.pending_count(), 1);
}

#[gtk4::test]
fn ctrl_backspace_sets_focused_nullable_cell_null() {
    let mut required = named("code", "text", false);
    required.nullable = false;
    let grid = Grid::open(
        vec![named("id", "integer", true), named("name", "text", false), required],
        vec![vec![Value::Int(1), Value::Text("a".into()), Value::Text("b".into())]],
    );
    let ctrl = gdk::ModifierType::CONTROL_MASK;

    grid.focus(0, 1);
    assert!(press(&grid, gdk::Key::BackSpace, ctrl));
    grid.focus(0, 2);
    assert!(!press(&grid, gdk::Key::BackSpace, ctrl), "a NOT NULL column took NULL");
    grid.focus(0, 0);
    assert!(!press(&grid, gdk::Key::BackSpace, ctrl), "a saved row's key took NULL");

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(Value::Null)));
    assert_eq!(grid.tracker.pending_count(), 1);
}

#[gtk4::test]
fn tab_in_edit_mode_moves_to_next_editable_column() {
    let grid = mixed_rows();
    let name = grid.focus(0, 1);
    type_into(&grid, &name, "a2");

    assert!(press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::Tab,
        none()
    ));
    let note = editing(&grid);
    assert_eq!(at(&note), (Some(0), 3), "Tab did not skip the boolean");
    assert_eq!(
        editor(&grid).map(|editor| editor.text().to_string()).as_deref(),
        Some("x")
    );

    assert!(press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::Tab,
        none()
    ));
    let next_row = editing(&grid);
    assert_eq!(at(&next_row), (Some(1), 1), "Tab did not skip the saved row's key");

    assert!(press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::ISO_Left_Tab,
        gdk::ModifierType::SHIFT_MASK
    ));
    let back = editing(&grid);
    assert_eq!(back, note, "Shift+Tab did not go back a row");

    assert_eq!(pending(&grid, 1, 1), Some(text("a2")));
    assert_eq!(grid.tracker.pending_count(), 1);
}

#[gtk4::test]
fn tab_past_the_last_editable_cell_keeps_the_focus_there() {
    let grid = mixed_rows();
    let note = grid.focus(1, 3);
    assert!(grid.grid.edit().edit_cell(&note));

    assert!(press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::Tab,
        none()
    ));

    assert!(editing_cell(&grid).is_none());
    assert_eq!(grid.focused_cell().as_ref(), Some(&note));
}

#[gtk4::test]
fn escape_cancels_and_returns_focus_to_cell() {
    let grid = mixed_rows();
    let name = grid.focus(1, 1);
    let editor = type_into(&grid, &name, "typed");

    assert!(press_in_editor(&editor, gdk::Key::Escape, none()));

    assert!(editing_cell(&grid).is_none());
    assert_eq!(grid.focused_cell().as_ref(), Some(&name), "the focus did not come back");
    assert_eq!(grid.tracker.pending_count(), 0, "Escape sent the typed text");
}

/// GTK ends the focus change by walking up from the field the edit was
/// in. GTK 4.22 logs a critical forever and never returns when the field
/// has left its cell by then.
#[gtk4::test]
fn the_focus_moving_to_another_cell_commits_the_edit() {
    let grid = mixed_rows();
    let name = grid.focus(0, 1);
    type_into(&grid, &name, "a2");

    let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
    let note = grid.focus(1, 3);
    drain_main_context();
    glib::log_set_always_fatal(previous);

    assert!(editing_cell(&grid).is_none(), "the edit outlived the focus");
    assert!(!name.is_editing(), "the field stayed in the cell");
    assert_eq!(pending(&grid, 1, 1), Some(text("a2")));
    assert_eq!(grid.focused_cell().as_ref(), Some(&note));
    assert!(
        !name.state_flags().contains(gtk::StateFlags::FOCUS_WITHIN),
        "the cell the edit left still shows the focus"
    );
}

/// Another window taking the focus is no focus change in this one, so
/// the edit stays open, and typing goes on there once it is back.
#[gtk4::test]
fn an_edit_stays_open_while_another_window_has_the_focus() {
    let grid = mixed_rows();
    let name = grid.focus(1, 1);
    let editor = type_into(&grid, &name, "typed");

    let thief = FocusThief::take_from(&grid.window).expect("another window takes the focus");
    after_next_frame(&grid.window);
    assert!(
        editing_cell(&grid).is_some(),
        "another window taking the focus ended the edit"
    );
    thief.give_back(&grid.window);
    drain_main_context();
    after_next_frame(&grid.window);

    assert!(
        editing_cell(&grid).is_some(),
        "the edit ended when the window came back"
    );
    assert_eq!(grid.tracker.pending_count(), 0, "the half-typed value was sent");
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
    assert!(grid.grid.edit().edit_cell(&name));

    assert!(!press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::Tab,
        gdk::ModifierType::CONTROL_MASK
    ));
    assert!(editing_cell(&grid).is_some());
}

#[gtk4::test]
fn new_draft_enters_edit_mode_on_first_editable_cell() {
    let mut serial = named("id", "integer", true);
    serial.is_auto_increment = true;
    let grid = Grid::open(
        vec![serial, named("name", "text", false), named("note", "text", false)],
        vec![vec![Value::Int(1), Value::Text("a".into()), Value::Text("x".into())]],
    );

    grid.activate("insert-row");

    let cell = editing(&grid);
    assert!(cell.row().is_some_and(|row| row.draft_id().is_some()));
    assert_eq!(cell.column(), 1, "the edit did not skip the auto-increment key");
    let selection = grid.grid.selection();
    assert!(selection.is_selected(0) && !selection.is_selected(1));
}

/// Tab moves an edit across the columns, and no header is focused on
/// the way, so the editor names the column it edits.
#[gtk4::test]
fn the_cell_editor_is_named_by_its_column() {
    let grid = two_text_rows();

    let editor = type_into(&grid, &grid.cell_of(2, 1), "B");

    assert_eq!(assert_labelled(&editor), Ok(()));
}

#[gtk4::test]
fn a_value_too_large_to_lay_out_does_not_open_and_says_why() {
    let large = "x".repeat(EDIT_MAX_BYTES + 1);
    let grid = Grid::open(
        vec![named("id", "integer", true), named("body", "text", false)],
        vec![vec![Value::Int(1), Value::Text(large)]],
    );
    let cell = grid.cell_of(1, 1);

    assert!(grid.grid.edit().edit_cell(&cell));

    assert!(editing_cell(&grid).is_none(), "an editor opened on the whole value");
    assert!(
        !details_shown(&grid),
        "the detail pane took a value too large to lay out"
    );
    // GLib puts a no-break space between the number and the unit.
    assert_eq!(toasts(&grid), ["Values over 1.0\u{a0}MB can't be edited here"]);
}

#[gtk4::test]
fn a_text_with_a_nul_draws_and_refuses_an_editor() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("name", "text", false)],
        vec![vec![Value::Int(1), Value::Text("a\0b".into())]],
    );
    let cell = grid.cell_of(1, 1);
    assert_eq!(Grid::display_text(&cell), "a\u{2400}b");

    grid.grid.edit().edit_cell(&cell);

    assert!(
        editing_cell(&grid).is_none(),
        "an editor opened on a value it cannot hold"
    );
    assert_eq!(
        toasts(&grid),
        ["Values with a NUL character can't be edited here"],
        "the refusal was not explained"
    );
}

#[gtk4::test]
fn a_saved_rows_key_is_locked_and_a_drafts_is_not() {
    let grid = two_text_rows();
    grid.insert_draft();
    let draft_key_cell = grid
        .cells()
        .into_iter()
        .find(|cell| cell.column() == 0 && cell.row().is_some_and(|row| row.draft_id().is_some()))
        .expect("the draft's key cell");

    assert!(
        grid.cell_of(1, 0).lock().is_some(),
        "a saved row's key was offered for editing"
    );
    assert!(grid.cell_of(1, 1).lock().is_none());
    assert!(draft_key_cell.lock().is_none(), "a draft could not set its own key");

    assert!(!grid.grid.edit().edit_cell(&grid.cell_of(1, 0)));
    assert!(editing_cell(&grid).is_none());
    assert!(grid.grid.edit().edit_cell(&draft_key_cell));
    assert_eq!(editing_cell(&grid), Some(draft_key_cell));
}

#[gtk4::test]
fn f004_edit_after_draft_insert_targets_edited_row() {
    let grid = two_text_rows();
    grid.insert_draft();

    let cell = grid.focus(2, 1);
    assert_eq!(cell.row().and_then(|row| row.key()), Some(key(2)));
    let editor = type_into(&grid, &cell, "renamed");
    editor.emit_activate();

    assert_eq!(pending(&grid, 2, 1), Some(text("renamed")));
}

#[gtk4::test]
fn f004_menu_set_null_after_draft_removal_targets_clicked_row() {
    let grid = two_text_rows();
    let draft_id = grid.insert_draft();
    let cell = grid.cell_of(2, 1);
    assert!(grid.grid.open_cell_menu(&cell, None));

    let removed = grid.tracker.apply(TrackerEdit::DeleteRows {
        persisted: Vec::new(),
        drafts: vec![draft_id],
    });
    grid.grid.apply_delta(&removed);
    drain_main_context();
    grid.grid
        .activate_action("grid.set-null", None)
        .expect("the menu's Set to NULL");

    assert_eq!(pending(&grid, 2, 1), Some(CellInput::Value(Value::Null)));
    assert_eq!(pending(&grid, 1, 1), None, "the menu acted on another row");
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }
}

#[gtk4::test]
fn edit_started_before_rows_shift_commits_to_original_row() {
    let grid = two_text_rows();
    let cell = grid.cell_of(2, 1);
    let editor = type_into(&grid, &cell, "renamed");

    grid.insert_draft();
    editor.emit_activate();

    assert_eq!(pending(&grid, 2, 1), Some(text("renamed")));
}

#[gtk4::test]
fn toggle_after_draft_insert_targets_toggled_row() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("flag", "boolean", false)],
        vec![
            vec![Value::Int(1), Value::Bool(true)],
            vec![Value::Int(2), Value::Bool(false)],
        ],
    );
    grid.insert_draft();
    let cell = grid.focus(2, 1);
    assert_eq!(cell.row().and_then(|row| row.key()), Some(key(2)));

    grid.activate("toggle");

    assert_eq!(pending(&grid, 2, 1), Some(CellInput::Value(Value::Bool(true))));
    assert_eq!(pending(&grid, 1, 1), None);
}

#[gtk4::test]
fn an_edit_in_progress_keeps_its_text_when_the_row_is_drawn_again() {
    let grid = two_text_rows();
    let cell = grid.cell_of(2, 1);
    let editor = type_into(&grid, &cell, "typed");
    let row = cell.row().expect("a bound row");

    row.bump_revision();

    assert_eq!(editor.text(), "typed", "the redraw overwrote what was typed");
    grid.grid.edit().cancel_open_edit();
    assert_eq!(
        Grid::display_text(&cell),
        "B",
        "Escape did not go back to the row's value"
    );
    assert!(editing_cell(&grid).is_none());
    assert_eq!(grid.tracker.pending_count(), 0);
}

/// Row 1's name edited from `from` to `to`, its editor opened on `to`,
/// then the edit undone under the open editor.
fn undo_under_open_editor(from: Value, to: Value) -> (Grid, GridCell) {
    let grid = name_rows(from.clone());
    let cell = grid.cell_of(1, 1);
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: from,
        value: to,
    }));
    assert!(grid.grid.edit().edit_cell(&cell));
    assert!(editor(&grid).is_some(), "the cell did not open for editing");

    grid.grid.undo();

    (grid, cell)
}

#[gtk4::test]
fn escape_after_an_undo_under_the_editor_sends_nothing() {
    let (grid, cell) = undo_under_open_editor(Value::Text("A".into()), Value::Text("X".into()));
    assert!(
        editing_cell(&grid).is_none(),
        "the editor stayed open on a value the row no longer has"
    );

    grid.grid.edit().cancel_open_edit();

    assert_eq!(Grid::display_text(&cell), "A");
    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn escape_after_undoing_an_edit_of_null_sends_nothing() {
    let (grid, cell) = undo_under_open_editor(Value::Null, Value::Text("hello".into()));

    grid.grid.edit().cancel_open_edit();

    assert_eq!(grid.tracker.pending_count(), 0);
    assert_eq!(Grid::display_text(&cell), editable_null_sentinel());
}

#[gtk4::test]
fn escape_on_a_null_cell_drawn_again_under_its_editor_sends_nothing() {
    let grid = name_rows(Value::Null);
    let cell = grid.cell_of(1, 1);
    assert!(grid.grid.edit().edit_cell(&cell));

    cell.row().expect("a bound row").bump_revision();
    assert!(
        editing_cell(&grid).is_some(),
        "a redraw of the same value closed the editor"
    );
    grid.grid.edit().cancel_open_edit();

    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn a_null_text_cell_left_as_it_opened_stays_null() {
    let grid = name_rows(Value::Null);
    let cell = grid.cell_of(1, 1);

    let editor = type_into(&grid, &cell, "");

    assert_eq!(
        editor.placeholder_text().unwrap_or_default(),
        "",
        "a text column keeps the empty string, so empty means nothing more"
    );
    editor.emit_activate();
    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn a_text_that_reads_as_the_null_sentinel_opens_as_itself() {
    let grid = name_rows(Value::Text(editable_null_sentinel()));

    assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 1)));

    assert_eq!(
        editor(&grid).map(|editor| editor.text().to_string()),
        Some(editable_null_sentinel())
    );
}

#[gtk4::test]
fn a_blob_in_a_text_column_does_not_open_on_its_placeholder() {
    let grid = name_rows(Value::Bytes(vec![1, 2, 3]));
    let cell = grid.cell_of(1, 1);

    grid.grid.edit().edit_cell(&cell);

    assert!(
        editing_cell(&grid).is_none(),
        "the editor opened on the size placeholder"
    );
    assert_eq!(toasts(&grid).len(), 1, "the cell did not say why it would not open");
}

/// Long and multi-line text is edited in the detail pane's editor now,
/// which shows all of it.
#[gtk4::test]
fn a_long_or_multi_line_text_opens_in_the_detail_pane() {
    let long = format!("tpyo{}", "x".repeat(60_000));
    let grid = Grid::open(
        vec![named("id", "integer", true), named("name", "text", false)],
        vec![
            vec![Value::Int(1), Value::Text(long)],
            vec![Value::Int(2), Value::Text("one\ntwo".into())],
        ],
    );

    for id in [1, 2] {
        grid.grid
            .actions()
            .change_action_state("show-details", &false.to_variant());
        let cell = grid.focus(u32::try_from(id - 1).expect("a position"), 1);

        assert!(grid.grid.edit().edit_cell(&cell));

        assert!(editing_cell(&grid).is_none(), "row {id} opened in a one-line field");
        assert!(details_shown(&grid), "row {id} did not open the detail pane");
    }
}

/// JSON, XML and dates open the detail pane's value editor rather than a
/// popover in the cell.
#[gtk4::test]
fn documents_and_dates_open_in_the_detail_pane() {
    let grid = Grid::open(
        vec![
            named("id", "integer", true),
            named("doc", "jsonb", false),
            named("day", "date", false),
        ],
        vec![vec![
            Value::Int(1),
            Value::Json(tablepro_core::value::JsonText::parse("[1]".to_owned()).expect("json")),
            Value::Date(tablepro_core::value::Temporal::Finite(
                chrono::NaiveDate::from_ymd_opt(2026, 9, 15).expect("a date"),
            )),
        ]],
    );

    for column in [1, 2] {
        grid.grid
            .actions()
            .change_action_state("show-details", &false.to_variant());
        grid.focus(0, column);

        assert!(press(&grid, gdk::Key::Return, none()));

        assert!(editing_cell(&grid).is_none());
        assert!(details_shown(&grid), "column {column} did not open the detail pane");
    }
    assert_eq!(grid.tracker.pending_count(), 0);
}

/// A closed editor must leave nothing holding its cell.
#[gtk4::test]
fn a_closed_editor_frees_its_cell() {
    let grid = two_text_rows();
    type_into(&grid, &grid.focus(1, 1), "typed");
    grid.grid.edit().cancel_open_edit();
    type_into(&grid, &grid.cell_of(1, 1), "again");
    grid.grid.edit().commit_open_edit();
    let freed: Vec<glib::WeakRef<GridCell>> = grid.cells().iter().map(ObjectExt::downgrade).collect();

    drop(grid);

    assert!(
        freed.iter().all(|cell| cell.upgrade().is_none()),
        "an editor kept its cell alive"
    );
}

/// D7: what was typed stays, marked, with the reason, and Escape goes
/// back to the value.
#[gtk4::test]
fn a_refused_value_stays_in_the_editor_with_its_reason() {
    let grid = number_row();
    let cell = grid.focus(0, 1);
    let editor = type_into(&grid, &cell, "12,5");

    editor.emit_activate();

    assert_eq!(
        editor_text(&grid).as_deref(),
        Some("12,5"),
        "the typed text was thrown away"
    );
    assert!(editor.has_css_class("error"));
    assert_eq!(toasts(&grid), ["Enter a whole number"]);
    assert_eq!(grid.tracker.pending_count(), 0);
    editor.set_text("12");
    assert!(!editor.has_css_class("error"), "the mark outlived the change");
    editor.set_text("12,5");
    editor.emit_activate();

    assert!(press_in_editor(&editor, gdk::Key::Escape, none()));

    assert!(editing_cell(&grid).is_none());
    assert_eq!(Grid::display_text(&cell), "5");
    assert_eq!(grid.focused_cell().as_ref(), Some(&cell));
    assert_eq!(grid.tracker.pending_count(), 0);
}

fn editor_text(grid: &Grid) -> Option<String> {
    editor(grid).map(|editor| editor.text().to_string())
}

/// A value never pending goes when a save, a reload or a close commits.
#[gtk4::test]
fn committing_before_a_reload_drops_a_refused_value() {
    let grid = number_row();
    let cell = grid.focus(0, 1);
    type_into(&grid, &cell, "thirty").emit_activate();
    assert!(editing_cell(&grid).is_some());

    grid.grid.commit_edit();

    assert!(editing_cell(&grid).is_none());
    assert!(!grid.grid.is_editing());
    assert_eq!(grid.tracker.pending_count(), 0);
    assert_eq!(toasts(&grid), ["Enter a whole number", "Enter a whole number"]);
}

#[gtk4::test]
fn a_page_that_replaces_the_row_commits_the_open_edit_to_it() {
    let grid = two_text_rows();
    let cell = grid.focus(1, 1);
    type_into(&grid, &cell, "renamed");

    grid.grid.replace_rows(page(5..7), 0);

    assert!(editing_cell(&grid).is_none());
    assert_eq!(pending(&grid, 2, 1), Some(text("renamed")));
    assert_eq!(
        pending(&grid, 6, 1),
        None,
        "the edit went to the row that took the slot"
    );
}

/// D8: a row marked for deletion takes no edit, which would count as
/// pending and never save.
#[gtk4::test]
fn a_row_marked_for_deletion_opens_no_editor() {
    let grid = two_text_rows();
    grid.focus(0, 1);
    grid.activate("delete-rows");
    assert_eq!(grid.tracker.row_state(&key(1)), RowState::PendingDelete);

    let cell = grid.focus(0, 1);

    assert!(!grid.is_enabled("edit"));
    assert!(!grid.is_enabled("set-null"));
    assert!(!grid.grid.edit().edit_cell(&cell));
    assert!(grid.grid.edit().open_for_typing().is_none());
    assert!(editing_cell(&grid).is_none());
    assert_eq!(grid.tracker.pending_count(), 1);
}

#[gtk4::test]
fn typing_on_a_cell_opens_an_empty_editor() {
    let grid = two_text_rows();
    grid.focus(1, 1);

    let editor = grid.grid.edit().open_for_typing().expect("typing opened no editor");

    assert_eq!(editor.text(), "");
    assert_eq!(editor.selection_bounds(), None);
    editor.set_text("C");
    editor.emit_activate();
    assert_eq!(pending(&grid, 2, 1), Some(text("C")));
    grid.focus(0, 0);
    assert!(
        grid.grid.edit().open_for_typing().is_none(),
        "typing opened a locked key"
    );
}

/// The detail pane commits through `commit_value`, against the row it
/// pinned.
#[gtk4::test]
fn commit_value_commits_nothing_once_the_row_left_its_slot() {
    let grid = two_text_rows();
    let row = grid.grid.store().row(0).expect("a row");
    let pinned = row.pin();
    let start = EditStart {
        row: row.id(),
        read: Value::Text("A".into()),
        original: CellInput::Value(Value::Text("A".into())),
    };

    let committed = grid.grid.edit().commit_value(&pinned, 1, &start, "Ada");
    assert!(matches!(committed, Some(CommitResult::Edit(_))), "{committed:?}");
    assert_eq!(pending(&grid, 1, 1), Some(text("Ada")));
    assert_eq!(
        grid.grid.edit().commit_value(&pinned, 0, &start, "9"),
        None,
        "a saved row's key took a value"
    );

    grid.grid.replace_rows(page(5..7), 0);

    assert_eq!(grid.grid.edit().commit_value(&pinned, 1, &start, "again"), None);
    assert_eq!(pending(&grid, 5, 1), None);
}

#[gtk4::test]
fn presets_follow_the_cell_and_default_is_for_new_rows() {
    let mut stamped = named("made", "integer", false);
    stamped.nullable = false;
    stamped.default = tablepro_core::column::ColumnDefault::Literal(Value::Int(0));
    let grid = Grid::open(
        vec![named("id", "integer", true), named("name", "text", false), stamped],
        vec![vec![Value::Int(1), Value::Text("a".into()), Value::Int(3)]],
    );

    grid.focus(0, 1);
    assert!(grid.is_enabled("set-empty") && grid.is_enabled("set-null"));
    assert!(!grid.is_enabled("set-default"), "a saved row offered DEFAULT");
    grid.activate("set-empty");
    assert_eq!(pending(&grid, 1, 1), Some(text("")));
    grid.focus(0, 2);
    assert!(!grid.is_enabled("set-null") && !grid.is_enabled("set-empty"));

    let draft_id = grid.insert_draft();
    grid.focus(0, 2);
    assert!(grid.is_enabled("set-default"));
    grid.activate("set-default");
    assert_eq!(grid.tracker.draft_input(draft_id, 2), Some(CellInput::Default));
}

/// The rows a store holds after an edit are the same objects, so the
/// selection and the cells' widgets stay.
#[gtk4::test]
fn an_edit_redraws_the_row_in_its_own_slot() {
    let grid = two_text_rows();
    let row = grid.grid.store().row(1).expect("a row");
    let revision = row.revision();
    let cell = grid.focus(1, 1);

    type_into(&grid, &cell, "renamed").emit_activate();

    assert_eq!(grid.grid.store().row(1), Some(row.clone()));
    assert!(row.revision() > revision);
    assert_eq!(Grid::display_text(&grid.cell_of(2, 1)), "renamed");
}

/// Rows taken out of the list without the grid's own replace, as GTK
/// sees a page that drops the rows it had.
fn drop_every_row(grid: &Grid, ids: std::ops::Range<i64>) {
    let store = grid.grid.store();
    let rows: Vec<GridRow> = page(ids).into_iter().map(GridRow::new).collect();
    store.list().splice(0, store.len(), &rows);
}

/// The keyboard sits on the list's own cell widget, above the cell.
/// GTK moves a focus left in a removed row only after the next frame,
/// and a window focus-in before then crashed GTK 4.22 on the row.
#[gtk4::test]
fn a_focus_in_after_a_page_took_the_focused_row_keeps_the_focus_in_the_grid() {
    let grid = two_text_rows();
    grid.focus(0, 1);
    let thief = FocusThief::take_from(&grid.window).expect("another window takes the focus");

    drop_every_row(&grid, 3..5);
    thief.give_back(&grid.window);
    drain_main_context();
    after_next_frame(&grid.window);

    assert!(focus_in_grid(&grid), "the focus left the grid");
}

/// A field whose window lost the focus to another hears no focus
/// leaving when its row goes, and its edit is committed all the same.
#[gtk4::test]
fn a_page_that_takes_an_edited_row_from_an_inactive_window_commits_the_edit() {
    let grid = two_text_rows();
    let cell = grid.focus(0, 1);
    type_into(&grid, &cell, "typed");
    let _thief = FocusThief::take_from(&grid.window).expect("another window takes the focus");

    drop_every_row(&grid, 3..5);
    drain_main_context();

    assert!(editing_cell(&grid).is_none(), "the edit outlived its row");
    assert!(!grid.grid.is_editing());
    assert_eq!(pending(&grid, 1, 1), Some(text("typed")));
}

/// Paste `text` into `cell`'s editor through the clipboard, as Ctrl+V in
/// the field does.
fn paste_into(grid: &Grid, cell: &GridCell, text: &str) -> gtk::Text {
    assert!(grid.grid.edit().edit_cell(cell), "the cell took no edit");
    let editor = editor(grid).expect("the cell did not open its one-line editor");
    let opened = editor.text();
    editor.clipboard().set_text(text);
    editor.emit_paste_clipboard();
    wait_until(WAIT, || editor.text() != opened).expect("the paste never landed");
    editor
}

#[gtk4::test]
fn bigint_edit_is_exact() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("n", "bigint", false)],
        vec![vec![Value::Int(1), Value::Int(1_234_567_890_123_456_789)]],
    );
    let cell = grid.cell_of(1, 1);

    let editor = type_into(&grid, &cell, "1234567890123456790");
    assert_eq!(
        editor.input_purpose(),
        gtk::InputPurpose::Number,
        "a signed integer field offers a number keypad"
    );
    editor.emit_activate();

    assert_eq!(
        pending(&grid, 1, 1),
        Some(CellInput::Value(Value::Int(1_234_567_890_123_456_790)))
    );
}

#[gtk4::test]
fn f005_pasted_newlines_in_text_cell_are_kept() {
    let grid = name_rows(Value::Text("a".into()));
    let cell = grid.cell_of(1, 1);

    let editor = paste_into(&grid, &cell, "first line\nsecond line");
    editor.emit_activate();

    assert_eq!(pending(&grid, 1, 1), Some(text("first line\nsecond line")));
}

#[gtk4::test]
fn a_line_break_pasted_into_a_number_keeps_the_first_line() {
    let grid = number_row();
    let cell = grid.cell_of(1, 1);

    let editor = paste_into(&grid, &cell, "42\n43");
    assert_eq!(editor.text(), "42");
    editor.emit_activate();

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(Value::Int(42))));
}

#[gtk4::test]
#[expect(
    clippy::approx_constant,
    reason = "a double with every digit it can hold, which is the point, not pi"
)]
fn f005_pressing_enter_on_float_keeps_full_precision() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("x", "double precision", false)],
        vec![vec![Value::Int(1), Value::Float64(3.141_592_653_589_79)]],
    );
    let cell = grid.cell_of(1, 1);

    assert!(grid.grid.edit().edit_cell(&cell));
    let editor = editor(&grid).expect("a one-line field");
    assert_eq!(editor.text(), "3.14159265358979");
    editor.emit_activate();

    assert_eq!(grid.tracker.pending_count(), 0, "Enter rounded the value it opened on");
}

/// An editor left open across a save would commit against the value read
/// before it, so a cell the save writes takes no editor until it settles.
#[gtk4::test]
fn a_cell_the_running_save_writes_opens_no_editor() {
    let grid = two_text_rows();
    let _ = grid.tracker.set_target(crate::services::save_batch::SaveTarget {
        table: tablepro_core::meta::TableRef::unqualified("t"),
        columns: two_text_columns(),
    });
    type_into(&grid, &grid.cell_of(1, 1), "renamed").emit_activate();
    let batch = grid.tracker.begin_save().expect("a save").expect("changes to save");
    grid.grid.redraw();

    assert!(
        !grid.grid.edit().edit_cell(&grid.cell_of(1, 1)),
        "an editor opened on a cell being saved"
    );
    assert!(
        grid.grid.edit().edit_cell(&grid.cell_of(2, 1)),
        "the save locked a cell it does not write"
    );
    grid.grid.edit().cancel_open_edit();
    let _ = grid.tracker.settle_save(
        &crate::workspace::SaveOutcome::Committed { rows: Some(1) },
        batch.snapshot,
    );
    grid.grid.redraw();
    assert!(
        grid.grid.edit().edit_cell(&grid.cell_of(1, 1)),
        "the cell stayed locked after the save"
    );
}
