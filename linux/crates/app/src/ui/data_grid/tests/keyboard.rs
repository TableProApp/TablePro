use std::collections::HashSet;

use gtk4 as gtk;
use gtk4::gdk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::Value;
use tablepro_core::edit::CellInput;

use super::{details_shown, none, pane, press, text};
use crate::application::{ACCELERATORS, AcceleratorScope, ShortcutOwner};
use crate::test_support::shortcut_keys::{
    Keystroke, class_binding_keys, class_keys_on_focus_paths, controller_keys, keystroke, keystrokes_with_twins,
    owner_controller,
};
use crate::test_support::wait_until;
use crate::test_support::{descendants, drain_main_context};
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, key, results, two_text_columns, two_text_values};

fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

/// Every key the table gives `owner`, with the keypad twins it binds.
fn table_keys(owner: ShortcutOwner) -> HashSet<Keystroke> {
    ACCELERATORS
        .iter()
        .filter(|entry| matches!(entry.scope, AcceleratorScope::Local { owner: of, .. } if of == owner))
        .flat_map(|entry| entry.triggers.iter())
        .flat_map(|accel| keystrokes_with_twins(accel))
        .collect()
}

fn value_text(grid: &Grid) -> String {
    let buffer = pane(grid).imp().value_buffer.get();
    buffer.text(&buffer.start_iter(), &buffer.end_iter(), true).to_string()
}

fn long_text() -> String {
    format!("tpyo{}", "x".repeat(60_000))
}

#[gtk4::test]
fn the_grid_binds_the_keys_the_table_gives_it() {
    let grid = two_text_rows();
    let view = grid.grid.column_view();
    let on_grid: gtk::Widget = grid.grid.clone().upcast();

    for (owner, widget, phase) in [
        (
            ShortcutOwner::GridCell,
            view.clone().upcast::<gtk::Widget>(),
            gtk::PropagationPhase::Capture,
        ),
        (ShortcutOwner::Grid, on_grid, gtk::PropagationPhase::Bubble),
    ] {
        let controller = owner_controller(&widget, owner).expect("the grid's keys");
        let bound: HashSet<Keystroke> = controller_keys(&controller).into_iter().collect();
        assert_eq!(controller.propagation_phase(), phase, "{owner:?}");
        assert_eq!(bound, table_keys(owner), "{owner:?}");
    }
    let cell_keys = owner_controller(&view, ShortcutOwner::GridCell).map(|controller| controller_keys(&controller));
    assert!(
        cell_keys.is_some_and(|keys| keys.contains(&(gdk::Key::KP_Enter, none()))),
        "the keypad Enter was lost"
    );
}

#[gtk4::test]
fn grid_shortcut_controller_runs_in_capture_phase_above_focus() {
    let grid = two_text_rows();
    let controller = owner_controller(&grid.grid.column_view(), ShortcutOwner::GridCell).expect("the grid's cell keys");

    grid.focus(1, 1);

    assert_eq!(controller.propagation_phase(), gtk::PropagationPhase::Capture);
    assert_eq!(controller.scope(), gtk::ShortcutScope::Local);
    let focus = gtk::prelude::GtkWindowExt::focus(&grid.window).expect("a focused widget");
    let owner = controller.widget().expect("the controller is on a widget");
    assert!(
        focus.is_ancestor(&owner),
        "a key on the focused cell does not pass the controller"
    );
    assert_eq!(focus.css_name(), "cell", "the focus is not on a cell");
}

/// A bubble-phase key on the column view reaches it only when no class
/// on the way up from the focused cell binds it first.
#[gtk4::test]
fn grid_keys_are_not_class_bindings_inside_the_grid() {
    let grid = two_text_rows();
    grid.focus(0, 1);

    let class_keys = class_keys_on_focus_paths(&grid.grid.column_view(), |widget| widget.is::<gtk::Text>());

    assert!(
        class_keys.contains(&keystroke("<Primary>a")),
        "the list view's own bindings were not found, so the check reads nothing"
    );
    for entry in ACCELERATORS {
        let AcceleratorScope::Local {
            owner: ShortcutOwner::Grid,
            phase,
        } = entry.scope
        else {
            continue;
        };
        assert_eq!(phase, gtk::PropagationPhase::Bubble, "{}", entry.action);
        for accel in entry.triggers {
            assert!(
                !class_keys.contains(&keystroke(accel)),
                "{accel} of {} never reaches the column view",
                entry.action
            );
        }
    }
}

/// The table lists these as GtkListBase's own, so the list must bind
/// them.
#[gtk4::test]
fn stock_list_keys_are_list_view_bindings() {
    let grid = two_text_rows();
    let list_view = descendants(&grid.grid.column_view())
        .into_iter()
        .find(|widget| widget.is::<gtk::ListView>())
        .expect("the column view's list");
    let bound = class_binding_keys(&list_view);

    for entry in ACCELERATORS.iter().filter(|entry| {
        entry.scope == AcceleratorScope::Stock
            && entry.action.starts_with("list.")
            && entry.triggers.iter().all(|accel| !accel.contains("Pointer"))
    }) {
        for accel in entry.triggers {
            assert!(bound.contains(&keystroke(accel)), "the list does not bind {accel}");
        }
    }
}

/// The grid lets Return go on a locked cell, and the list turns it, as
/// it turns a double click, into `activate`.
#[gtk4::test]
fn return_or_a_double_click_on_a_locked_cell_opens_its_field_in_the_detail_pane() {
    let table = two_text_rows();
    let shown = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));

    for (grid, position, column) in [(&table, 1, 0), (&shown, 0, 1)] {
        grid.focus(position, column);
        assert!(
            !press(grid, gdk::Key::Return, none()),
            "the grid's Return took a locked cell"
        );

        grid.grid.column_view().emit_by_name::<()>("activate", &[&position]);
        drain_main_context();

        assert!(details_shown(grid), "the detail pane did not open");
        assert_eq!(
            pane(grid).imp().field.get(),
            Some(column),
            "the pane shows another field"
        );
        assert!(grid.grid.edit().open_text().is_none());
    }
}

#[gtk4::test]
fn f2_on_a_locked_cell_does_nothing() {
    let grid = two_text_rows();
    grid.focus(0, 0);

    assert!(!press(&grid, gdk::Key::F2, none()), "F2 took a locked cell");

    assert!(grid.grid.edit().open_text().is_none());
    assert!(!details_shown(&grid), "F2 opened the detail pane");
    assert_eq!(grid.tracker.pending_count(), 0);
}

#[gtk4::test]
fn editing_a_long_text_starts_from_the_whole_value() {
    let grid = Grid::open(two_text_columns(), vec![vec![Value::Int(1), text(&long_text())]]);
    let cell = grid.focus(0, 1);

    assert!(grid.grid.edit().edit_cell(&cell));

    assert!(
        grid.grid.edit().open_text().is_none(),
        "a long text opened in a one-line field"
    );
    wait_until(WAIT, || value_text(&grid).len() == long_text().len()).expect("the pane opened on the cut text");
    assert_eq!(value_text(&grid), long_text());
}

#[gtk4::test]
fn a_long_text_saved_from_its_editor_sends_the_whole_value() {
    let grid = Grid::open(two_text_columns(), vec![vec![Value::Int(1), text(&long_text())]]);
    let cell = grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&cell));
    wait_until(WAIT, || value_text(&grid).len() == long_text().len()).expect("the pane holds the value");
    let fixed = long_text().replacen("tpyo", "typo", 1);

    pane(&grid).imp().value_buffer.set_text(&fixed);
    assert!(grid.grid.is_editing(), "typing in the pane opened no edit");
    grid.grid.commit_edit();

    assert_eq!(
        grid.tracker.cell_overlay(&key(1), 1).pending,
        Some(CellInput::Value(text(&fixed)))
    );
    assert!(
        Grid::display_text(&grid.cell_of(1, 1)).len() < 20_000,
        "the cell drew the whole value"
    );
}

/// These press real keys on the X display every test shares; nextest runs
/// them with no other test beside them.
mod real_keys {
    use gtk4::gdk;
    use gtk4::prelude::*;

    use super::super::{data_column, laid_out, none, settled_width, shown_width, step};
    use super::two_text_rows;
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::{Grid, WAIT};

    const SHIFT_ALT: gdk::ModifierType = gdk::ModifierType::SHIFT_MASK.union(gdk::ModifierType::ALT_MASK);

    fn keys_for(grid: &Grid) -> KeyInjector {
        KeyInjector::focus_only(&grid.window);
        wait_until(WAIT, || grid.window.is_active()).expect("the window to take the focus");
        KeyInjector::connect().expect("an X11 display")
    }

    fn editor_text(grid: &Grid) -> Option<String> {
        grid.grid.edit().open_text().map(|editor| editor.text().to_string())
    }

    /// The key reaches the editor through its input method, so a dead
    /// key or a composed character starts there too.
    #[gtk4::test]
    fn typing_on_a_cell_opens_its_editor_with_the_typed_key() {
        let grid = two_text_rows();
        let keys = keys_for(&grid);
        grid.focus(1, 1);

        keys.press(gdk::Key::x, none()).expect("the key press");
        wait_until(WAIT, || editor_text(&grid).as_deref() == Some("x")).expect("the key to land in a new editor");
        keys.press(gdk::Key::Escape, none()).expect("the key press");

        wait_until(WAIT, || editor_text(&grid).is_none()).expect("Escape to close the editor");
        assert_eq!(grid.tracker.pending_count(), 0);
        assert_eq!(Grid::display_text(&grid.cell_of(2, 1)), "B");
    }

    /// Space on a cell that is no boolean is the list's, and a key with
    /// Ctrl is a command, never text.
    #[gtk4::test]
    fn space_and_ctrl_keys_start_no_edit() {
        let grid = laid_out(two_text_rows());
        let keys = keys_for(&grid);
        grid.focus(0, 1);
        let wider = settled_width(&grid, 1) + step(&grid);

        for (key, modifiers) in [
            (gdk::Key::space, none()),
            (gdk::Key::space, gdk::ModifierType::CONTROL_MASK),
            (gdk::Key::x, gdk::ModifierType::CONTROL_MASK),
        ] {
            keys.press(key, modifiers).expect("the key press");
        }
        // The keys arrive in order, so once the column widens the ones
        // before it have run.
        keys.press(gdk::Key::Right, SHIFT_ALT).expect("the key press");
        wait_until(WAIT, || shown_width(&grid, 1) == wider).expect("the keys to arrive");

        assert_eq!(editor_text(&grid), None, "a key started an edit");
        assert_eq!(grid.tracker.pending_count(), 0);
    }

    #[gtk4::test]
    fn shift_alt_right_and_left_resize_the_focused_cells_column() {
        let grid = laid_out(two_text_rows());
        let keys = keys_for(&grid);
        grid.focus(0, 1);
        let id_width = data_column(&grid, 0).fixed_width();
        let wider = settled_width(&grid, 1) + step(&grid);

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
        assert_eq!(
            data_column(&grid, 0).fixed_width(),
            id_width,
            "the keys resized another column"
        );
    }

    #[gtk4::test]
    fn an_open_editor_keeps_shift_alt_arrows() {
        let grid = laid_out(two_text_rows());
        let keys = keys_for(&grid);
        let cell = grid.focus(0, 1);
        let width = data_column(&grid, 1).fixed_width();
        assert!(grid.grid.edit().edit_cell(&cell));
        let editor = grid.grid.edit().open_text().expect("the cell's editor");
        editor.set_text("typed");
        wait_until(WAIT, || editor.has_focus()).expect("the editor to take the focus");

        keys.press(gdk::Key::Right, SHIFT_ALT).expect("the key press");
        keys.press(gdk::Key::z, none()).expect("the key press");
        wait_until(WAIT, || editor.text().contains('z')).expect("the keys to reach the editor");

        assert_eq!(
            data_column(&grid, 1).fixed_width(),
            width,
            "the key resized the column being edited"
        );
        assert!(grid.grid.edit().open_text().is_some(), "the key ended the edit");
    }
}
