use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, glib};

use super::cell_edit::begin_edit;
use super::cell_focus::focused_cell;
use super::cell_preset::cell_presets;
use super::context_menu::prepare_menu;
use super::grid_menus::GridMenus;
use super::{CellPreset, GridCell, GridMsg, GridSink};

pub(super) struct GridKeyboard;

impl GridKeyboard {
    /// One controller on the column view, run in the capture phase.
    /// GtkListFactoryWidget class-binds Return, ISO_Enter and KP_Enter
    /// to activate-keybinding and space to listitem.select, and a
    /// G_TYPE_NONE signal action counts as handled, so on a focused cell
    /// those keys never reach a bubble-phase ancestor.
    ///
    /// Each action proceeds while the cell is editing. GtkShortcutController
    /// then tries its next shortcut and lets the key go on, so an open
    /// editor keeps Return, space, Menu and Ctrl+Backspace (delete word).
    pub(super) fn install(column_view: &gtk::ColumnView, menus: GridMenus, sink: GridSink) {
        let controller = gtk::ShortcutController::new();
        controller.set_scope(gtk::ShortcutScope::Local);
        controller.set_propagation_phase(gtk::PropagationPhase::Capture);
        let none = gdk::ModifierType::empty();
        controller.add_shortcut(gtk::Shortcut::new(
            Some(any_of(&[
                (gdk::Key::F2, none),
                (gdk::Key::Return, none),
                (gdk::Key::ISO_Enter, none),
                (gdk::Key::KP_Enter, none),
            ])),
            Some(on_focused_cell(|_, cell| edit_or_toggle(cell))),
        ));
        controller.add_shortcut(gtk::Shortcut::new(
            Some(any_of(&[(gdk::Key::space, none), (gdk::Key::KP_Space, none)])),
            Some(on_focused_cell(|_, cell| toggle(cell))),
        ));
        controller.add_shortcut(gtk::Shortcut::new(
            Some(any_of(&[
                (gdk::Key::Menu, none),
                (gdk::Key::F10, gdk::ModifierType::SHIFT_MASK),
            ])),
            Some(on_focused_cell(move |widget, cell| show_menu(widget, cell, &menus))),
        ));
        controller.add_shortcut(gtk::Shortcut::new(
            Some(any_of(&[(gdk::Key::BackSpace, gdk::ModifierType::CONTROL_MASK)])),
            Some(on_focused_cell(move |_, cell| set_null(cell, &sink))),
        ));
        column_view.add_controller(controller);
    }
}

fn any_of(keys: &[(gdk::Key, gdk::ModifierType)]) -> gtk::ShortcutTrigger {
    keys.iter()
        .map(|&(key, modifiers)| gtk::KeyvalTrigger::new(key, modifiers).upcast::<gtk::ShortcutTrigger>())
        .reduce(|first, second| gtk::AlternativeTrigger::new(first, second).upcast())
        .unwrap_or_else(|| gtk::NeverTrigger::get().upcast())
}

fn on_focused_cell(act: impl Fn(&gtk::Widget, &GridCell) -> glib::Propagation + 'static) -> gtk::CallbackAction {
    gtk::CallbackAction::new(move |widget, _| match focused_cell(widget) {
        Some(cell) if !cell.is_editing() => act(widget, &cell),
        _ => glib::Propagation::Proceed,
    })
}

/// A locked cell lets the key go on, so the list's own activation runs.
fn edit_or_toggle(cell: &GridCell) -> glib::Propagation {
    if cell.check_button().is_some() {
        return toggle(cell);
    }
    if cell.lock().is_some() {
        return glib::Propagation::Proceed;
    }
    begin_edit(cell);
    glib::Propagation::Stop
}

/// Space on any other cell goes on to select the row.
fn toggle(cell: &GridCell) -> glib::Propagation {
    let (None, Some(check)) = (cell.lock(), cell.check_button()) else {
        return glib::Propagation::Proceed;
    };
    // The check button's toggled handler sends the edit.
    check.set_active(!check.is_active());
    glib::Propagation::Stop
}

fn show_menu(widget: &gtk::Widget, cell: &GridCell, menus: &GridMenus) -> glib::Propagation {
    let Some(column_view) = widget.downcast_ref::<gtk::ColumnView>() else {
        return glib::Propagation::Proceed;
    };
    let popover = prepare_menu(menus, cell, column_view);
    // A key has no pointer position, so the menu points at the whole
    // cell, in the coordinates of the view the menu is parented to.
    let bounds = cell.compute_bounds(column_view).map(|bounds| {
        gdk::Rectangle::new(
            bounds.x() as i32,
            bounds.y() as i32,
            bounds.width() as i32,
            bounds.height() as i32,
        )
    });
    popover.set_pointing_to(bounds.as_ref());
    popover.popup();
    glib::Propagation::Stop
}

fn set_null(cell: &GridCell, sink: &GridSink) -> glib::Propagation {
    let (None, Some(row), Some(drawing)) = (cell.lock(), cell.row(), cell.drawing()) else {
        return glib::Propagation::Proceed;
    };
    let Some(column) = drawing.catalog.as_ref() else {
        return glib::Propagation::Proceed;
    };
    if !cell_presets(column, row.id()).null {
        return glib::Propagation::Proceed;
    }
    sink(GridMsg::SetCellValue {
        row,
        column: cell.column(),
        preset: CellPreset::Null,
    });
    glib::Propagation::Stop
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, gdk};
    use tablepro_core::Value;

    use crate::application::APP_ACCELS;
    use crate::test_support::{descendants, wait_until};
    use crate::ui::grid::test_grid::{Grid, WAIT, content, edited_rows, key, named, recorder, text, two_text_rows};
    use crate::ui::grid::{CellPreset, GridCell, GridMsg, RowObject, TabGridContext, begin_edit, build_column_view};

    type Accel = (gdk::Key, gdk::ModifierType);

    fn keys_of(trigger: &gtk::ShortcutTrigger, into: &mut Vec<Accel>) {
        if let Some(keyval) = trigger.downcast_ref::<gtk::KeyvalTrigger>() {
            into.push((keyval.keyval().to_lower(), keyval.modifiers()));
        } else if let Some(pair) = trigger.downcast_ref::<gtk::AlternativeTrigger>() {
            keys_of(&pair.first(), into);
            keys_of(&pair.second(), into);
        }
    }

    fn shortcuts(controller: &gtk::ShortcutController) -> Vec<gtk::Shortcut> {
        (0..controller.n_items())
            .filter_map(|position| controller.item(position).and_downcast::<gtk::Shortcut>())
            .collect()
    }

    fn accels(shortcut: &gtk::Shortcut) -> Vec<Accel> {
        let mut keys = Vec::new();
        if let Some(trigger) = shortcut.trigger() {
            keys_of(&trigger, &mut keys);
        }
        keys
    }

    fn keyboard(view: &gtk::ColumnView) -> gtk::ShortcutController {
        let controllers = view.observe_controllers();
        (0..controllers.n_items())
            .filter_map(|position| controllers.item(position).and_downcast::<gtk::ShortcutController>())
            .find(|controller| {
                shortcuts(controller)
                    .iter()
                    .any(|shortcut| accels(shortcut).contains(&(gdk::Key::F2, gdk::ModifierType::empty())))
            })
            .expect("the grid's keyboard controller")
    }

    /// Run what `key` does on the focused cell, as a key press reaching
    /// the controller would. `true` when the grid took the key.
    fn press(view: &gtk::ColumnView, key: gdk::Key, modifiers: gdk::ModifierType) -> bool {
        let action = shortcuts(&keyboard(view))
            .into_iter()
            .find(|shortcut| accels(shortcut).contains(&(key.to_lower(), modifiers)))
            .and_then(|shortcut| shortcut.action())
            .expect("the grid binds the key");
        action.activate(gtk::ShortcutActionFlags::empty(), view, None)
    }

    fn none() -> gdk::ModifierType {
        gdk::ModifierType::empty()
    }

    fn parse(accel: &str) -> Accel {
        let (key, modifiers) = gtk::accelerator_parse(accel).expect("an accelerator GTK can parse");
        (key.to_lower(), modifiers)
    }

    #[gtk4::test]
    fn grid_accels_do_not_collide_with_app_accels() {
        let grid = two_text_rows();
        let bound: Vec<Accel> = shortcuts(&keyboard(&grid.view)).iter().flat_map(accels).collect();
        assert!(bound.contains(&parse("<Primary>BackSpace")));

        let reserved = APP_ACCELS
            .iter()
            .flat_map(|(_, accels)| accels.iter())
            .chain(std::iter::once(&"<Primary>question"));
        for accel in reserved {
            assert!(!bound.contains(&parse(accel)), "the grid binds {accel}");
        }
        for accel in ["<Primary>q", "<Primary><Shift>n", "<Primary>comma", "<Primary>question"] {
            assert!(!bound.contains(&parse(accel)), "the grid binds {accel}");
        }
    }

    #[gtk4::test]
    fn grid_shortcut_controller_runs_in_capture_phase_above_focus() {
        let grid = two_text_rows();
        let controller = keyboard(&grid.view);

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

    #[gtk4::test]
    fn grid_shortcuts_proceed_while_editing() {
        let grid = two_text_rows();
        let cell = grid.focus(0, 1);
        begin_edit(&cell);
        assert!(cell.inline_text().is_some());

        assert!(!press(&grid.view, gdk::Key::Return, none()));
        assert!(!press(&grid.view, gdk::Key::space, none()));
        assert!(!press(&grid.view, gdk::Key::BackSpace, gdk::ModifierType::CONTROL_MASK));
        assert!(!press(&grid.view, gdk::Key::Menu, none()));

        assert!(cell.inline_text().is_some(), "a grid key closed the open editor");
        assert!(grid.take_messages().is_empty());
    }

    #[gtk4::test]
    fn f2_starts_editing_focused_text_cell() {
        let grid = two_text_rows();
        let cell = grid.focus(1, 1);

        assert!(press(&grid.view, gdk::Key::F2, none()));

        let editor = cell.inline_text().expect("F2 opened no editor");
        assert_eq!(editor.text(), "B");
    }

    #[gtk4::test]
    fn kp_enter_starts_editing_focused_int_cell() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("n", "integer", false)],
            vec![vec![Value::Int(1), Value::Int(42)]],
        );
        let cell = grid.focus(0, 1);

        assert!(press(&grid.view, gdk::Key::KP_Enter, none()));

        let editor = cell.inline_text().expect("KP_Enter opened no editor");
        assert_eq!(editor.text(), "42");
        assert_eq!(editor.input_purpose(), gtk::InputPurpose::Number);
    }

    #[gtk4::test]
    fn return_toggles_a_focused_boolean_cell() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("flag", "boolean", false)],
            vec![vec![Value::Int(1), Value::Bool(false)]],
        );
        let cell = grid.focus(0, 1);

        assert!(press(&grid.view, gdk::Key::Return, none()));

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(
                Some(key(1)),
                1,
                tablepro_core::edit::CellInput::Value(Value::Bool(true))
            )]
        );
        assert!(!cell.is_editing());
    }

    #[gtk4::test]
    fn space_toggles_a_focused_check_box_and_selects_from_any_other_cell() {
        let grid = Grid::open(
            vec![
                named("id", "integer", true),
                named("name", "text", false),
                named("flag", "boolean", false),
            ],
            vec![vec![Value::Int(1), Value::Text("a".into()), Value::Bool(false)]],
        );

        grid.focus(0, 2);
        assert!(press(&grid.view, gdk::Key::space, none()));
        grid.focus(0, 1);
        assert!(
            !press(&grid.view, gdk::Key::space, none()),
            "Space on a text cell did not go on to select the row"
        );

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(
                Some(key(1)),
                2,
                tablepro_core::edit::CellInput::Value(Value::Bool(true))
            )]
        );
    }

    #[gtk4::test]
    fn return_commits_and_returns_focus_to_cell() {
        let grid = two_text_rows();
        let cell = grid.focus(1, 1);
        assert!(press(&grid.view, gdk::Key::Return, none()));
        let editor = cell.inline_text().expect("Return opened no editor");
        editor.set_text("renamed");

        editor.emit_activate();

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, text("renamed"))]
        );
        assert!(!cell.is_editing());
        assert_eq!(grid.focused_cell().as_ref(), Some(&cell), "the focus did not come back");
    }

    #[gtk4::test]
    fn shift_f10_opens_menu_anchored_to_focused_cell() {
        let grid = two_text_rows();
        let cell = grid.focus(1, 1);
        wait_until(WAIT, || {
            cell.compute_bounds(&grid.view)
                .is_some_and(|bounds| bounds.width() > 0.0 && bounds.y() > 0.0)
        })
        .expect("the cell is laid out");

        assert!(press(&grid.view, gdk::Key::F10, gdk::ModifierType::SHIFT_MASK));

        let mut popover = None;
        wait_until(WAIT, || {
            popover = descendants(&grid.view)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk::PopoverMenu>().ok())
                .find(|popover| popover.is_visible());
            popover.is_some()
        })
        .expect("the cell menu opens");
        let popover = popover.expect("an open menu");
        let bounds = cell.compute_bounds(&grid.view).expect("the cell's bounds");
        let (pointed, rect) = popover.pointing_to();
        assert!(pointed);
        assert_eq!(
            (rect.x(), rect.y(), rect.width(), rect.height()),
            (
                bounds.x() as i32,
                bounds.y() as i32,
                bounds.width() as i32,
                bounds.height() as i32
            )
        );
        grid.view
            .activate_action("cell.set-null", None)
            .expect("the menu's Set to NULL");
        popover.popdown();
        let set: Vec<_> = grid
            .take_messages()
            .into_iter()
            .filter_map(|msg| match msg {
                GridMsg::SetCellValue { row, column, preset } => Some((row.key().cloned(), column, preset)),
                _ => None,
            })
            .collect();
        assert_eq!(
            set,
            vec![(Some(key(2)), 1, CellPreset::Null)],
            "the menu acts on another cell"
        );
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
        assert!(press(&grid.view, gdk::Key::BackSpace, ctrl));
        grid.focus(0, 2);
        assert!(
            !press(&grid.view, gdk::Key::BackSpace, ctrl),
            "a NOT NULL column took NULL"
        );
        grid.focus(0, 0);
        assert!(
            !press(&grid.view, gdk::Key::BackSpace, ctrl),
            "a saved row's key took NULL"
        );

        let set: Vec<_> = grid
            .take_messages()
            .into_iter()
            .filter_map(|msg| match msg {
                GridMsg::SetCellValue { row, column, preset } => Some((row.key().cloned(), column, preset)),
                _ => None,
            })
            .collect();
        assert_eq!(set, vec![(Some(key(1)), 1, CellPreset::Null)]);
    }

    #[gtk4::test]
    fn focused_read_only_cell_resolves_grid_cell() {
        let grid = two_text_rows();

        let cell = grid.focus(0, 0);

        assert!(cell.lock().is_some(), "a saved row's key was editable");
        assert_eq!(cell.row().and_then(|row| row.key().cloned()), Some(key(1)));
        assert!(!press(&grid.view, gdk::Key::F2, none()), "F2 took a locked cell");
        assert!(!cell.is_editing());
        assert!(press(&grid.view, gdk::Key::Menu, none()), "a locked cell has no menu");
    }

    #[gtk4::test]
    fn a_result_grid_opens_its_read_only_menu_from_the_keyboard() {
        let columns = [named("id", "integer", true)];
        let (sink, _messages) = recorder();
        let (view, _selection) = build_column_view(
            content(&columns, vec![RowObject::result(vec![Value::Int(7)].into())]),
            &[],
            sink,
            None,
            false,
            TabGridContext::default(),
        );
        let window = gtk::Window::new();
        window.set_child(Some(&view));
        window.present();
        view.grab_focus();
        let mut focused = None;
        wait_until(WAIT, || {
            focused = gtk::prelude::GtkWindowExt::focus(&window).and_then(|focus| GridCell::from_focus(&focus));
            focused.is_some()
        })
        .expect("a result cell takes the focus");

        assert!(!press(&view, gdk::Key::Return, none()), "Return edited a result cell");
        assert!(press(&view, gdk::Key::Menu, none()));
        let open: Vec<gtk::PopoverMenu> = descendants(&view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::PopoverMenu>().ok())
            .filter(|popover| popover.is_visible())
            .collect();
        assert_eq!(open.len(), 1);
        assert!(
            view.activate_action("cell.set-null", None).is_err(),
            "a result grid offers Set to NULL"
        );
        for popover in open {
            popover.popdown();
        }
        window.destroy();
    }

    #[gtk4::test]
    fn grid_keys_proceed_with_no_focused_cell() {
        let grid = two_text_rows();
        gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);

        assert!(!press(&grid.view, gdk::Key::F2, none()));
        assert!(!press(&grid.view, gdk::Key::BackSpace, gdk::ModifierType::CONTROL_MASK));
        assert!(grid.take_messages().is_empty());
    }
}
