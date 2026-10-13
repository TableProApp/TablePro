use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use super::cell_editor_kind::CellEditorKind;
use super::cell_popovers::{show_calendar_popover, show_json_popover, show_spin_button_popover};
use super::display_text::editable_null_sentinel;
use super::{EditSnapshot, GridCell, GridMsg, GridSink};

/// Clears the `<NULL>` sentinel first, so the user does not type over it.
pub(crate) fn enter_edit_mode(cell: &GridCell) {
    if cell.lock().is_some() {
        return;
    }
    let Some(editor) = cell.editor() else {
        return;
    };
    if editor.text().as_str() == editable_null_sentinel() {
        editor.set_text("");
    }
    editor.start_editing();
}

/// `child_focus` on the window is what a real Tab press does.
fn move_focus(widget: &impl IsA<gtk::Widget>, direction: gtk::DirectionType) {
    let Some(root) = widget.root() else { return };
    let Ok(window) = root.dynamic_cast::<gtk::Window>() else {
        return;
    };
    window.child_focus(direction);
}

pub(super) fn install_edit_triggers(cell: &GridCell, sink: GridSink, editor_kind: CellEditorKind) {
    let open: Rc<dyn Fn(&GridCell)> = match editor_kind {
        CellEditorKind::Text => Rc::new(enter_edit_mode),
        CellEditorKind::Date => Rc::new(move |cell| show_calendar_popover(cell, &sink)),
        CellEditorKind::Int => Rc::new(move |cell| show_spin_button_popover(cell, &sink, false)),
        CellEditorKind::Float => Rc::new(move |cell| show_spin_button_popover(cell, &sink, true)),
        CellEditorKind::Json => Rc::new(move |cell| show_json_popover(cell, &sink)),
    };
    let trigger = move |cell: &GridCell| {
        if cell.lock().is_none() {
            open(cell);
        }
    };
    let trigger = Rc::new(trigger);

    // Editing takes a double-click, since a single click in a grid
    // selects the row. Capture phase, because the column view's row
    // selection takes the press in the bubble phase.
    //
    // The handlers read the cell from their controller: the cell owns
    // both controllers, so capturing it would be a cycle.
    let gesture = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_PRIMARY).build();
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    let trigger_for_press = trigger.clone();
    gesture.connect_pressed(move |gesture, n_press, _, _| {
        if n_press != 2 {
            return;
        }
        let Some(cell) = gesture.widget().and_downcast::<GridCell>() else {
            return;
        };
        // Left to a locked cell's label, which selects a word with it.
        if cell.lock().is_some() {
            return;
        }
        gesture.set_state(gtk::EventSequenceState::Claimed);
        trigger_for_press(&cell);
    });
    cell.add_controller(gesture);

    // While editing, Return and Escape belong to the CellEditor's entry.
    let controller = gtk::EventControllerKey::new();
    controller.connect_key_pressed(move |controller, keyval, _, modifiers| {
        let Some(cell) = controller.widget().and_downcast::<GridCell>() else {
            return glib::Propagation::Proceed;
        };
        let Some(editor) = cell.editor() else {
            return glib::Propagation::Proceed;
        };
        let editing = editor.is_editing();
        let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);

        if !editing {
            match keyval {
                gtk::gdk::Key::F2 | gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter => {
                    trigger(&cell);
                    return glib::Propagation::Stop;
                }
                // Left to GTK, Tab leaves the grid for the paginator.
                gtk::gdk::Key::Tab if !shift => {
                    move_focus(&cell, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                    move_focus(&cell, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
                // The column view moves between rows only.
                gtk::gdk::Key::Right => {
                    move_focus(&cell, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Left => {
                    move_focus(&cell, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
                _ => {}
            }
            return glib::Propagation::Proceed;
        }

        match keyval {
            gtk::gdk::Key::Tab if !shift => {
                editor.stop_editing(true);
                move_focus(&cell, gtk::DirectionType::TabForward);
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                editor.stop_editing(true);
                move_focus(&cell, gtk::DirectionType::TabBackward);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    cell.add_controller(controller);
}

/// The row is taken when the edit begins, so a commit after rows moved
/// still lands on it. Focus moving to an IME popover ends the edit
/// mid-composition, so the commit waits until the preedit clears.
pub(super) fn install_edit_commit_handler(cell: &GridCell, sink: GridSink) {
    let Some(editor) = cell.editor() else {
        return;
    };
    // The editor is the cell's own child, so its handlers hold the cell
    // weakly.
    let cell_for_preedit = cell.downgrade();
    let sink_for_preedit = sink.clone();
    editor.entry().connect_preedit_changed(move |_, preedit| {
        let Some(cell) = cell_for_preedit.upgrade() else {
            return;
        };
        let active = !preedit.is_empty();
        cell.set_preedit_active(active);
        // The edit ended during the composition, so this is its commit.
        if !active && !cell.editor().is_some_and(|editor| editor.is_editing()) {
            commit_cell_edit(&cell, &sink_for_preedit);
        }
    });

    let cell_for_edit = cell.downgrade();
    editor.connect_editing_notify(move |editor| {
        let Some(cell) = cell_for_edit.upgrade() else {
            return;
        };
        if editor.is_editing() {
            if let Some(row) = cell.row() {
                cell.begin_edit(EditSnapshot {
                    row,
                    column: cell.column(),
                    original_text: editor.text().to_string(),
                });
            }
            return;
        }
        if cell.preedit_active() {
            return;
        }
        commit_cell_edit(&cell, &sink);
    });
}

fn commit_cell_edit(cell: &GridCell, sink: &GridSink) {
    let Some(snapshot) = cell.take_edit() else {
        return;
    };
    let Some(editor) = cell.editor() else {
        return;
    };
    let input = editor.text().to_string();
    if input == snapshot.original_text {
        return;
    }
    sink(GridMsg::CellEdited {
        row: snapshot.row,
        column: snapshot.column,
        input,
    });
}
