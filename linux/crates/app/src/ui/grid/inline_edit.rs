use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use super::GridMsg;
use super::cell_editor::CellEditor;
use super::cell_editor_kind::CellEditorKind;
use super::cell_popovers::{show_calendar_popover, show_json_popover, show_spin_button_popover};
use super::display_text::editable_null_sentinel;
use super::widget_slot::{POSITION_SLOT, PREEDIT_SLOT, SNAPSHOT_SLOT};

#[derive(Debug)]
pub(super) struct EditSnapshot {
    position: u32,
    original: String,
}

/// Clears the `<NULL>` sentinel first, so the user does not type over it.
pub(super) fn enter_edit_mode(label: &CellEditor) {
    if label.text().as_str() == editable_null_sentinel() {
        label.set_text("");
    }
    label.start_editing();
}

/// `child_focus` on the window is what a real Tab press does.
fn move_focus(widget: &impl IsA<gtk::Widget>, direction: gtk::DirectionType) {
    let Some(root) = widget.root() else { return };
    let Ok(window) = root.dynamic_cast::<gtk::Window>() else {
        return;
    };
    window.child_focus(direction);
}

pub(super) fn install_edit_triggers(
    label: &CellEditor,
    col_index: usize,
    sender: relm4::Sender<GridMsg>,
    editor_kind: CellEditorKind,
) {
    let trigger: std::rc::Rc<dyn Fn(&CellEditor)> = match editor_kind {
        CellEditorKind::Text => std::rc::Rc::new(|l: &CellEditor| enter_edit_mode(l)),
        CellEditorKind::Date => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_calendar_popover(l, col_index, &sender))
        }
        CellEditorKind::Int => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_spin_button_popover(l, col_index, &sender, false))
        }
        CellEditorKind::Float => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_spin_button_popover(l, col_index, &sender, true))
        }
        CellEditorKind::Json => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_json_popover(l, col_index, &sender))
        }
    };

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
        let Some(label) = gesture.widget().and_downcast::<CellEditor>() else {
            return;
        };
        gesture.set_state(gtk::EventSequenceState::Claimed);
        trigger_for_press(&label);
    });
    label.add_controller(gesture);

    // While editing, Return and Escape belong to the CellEditor's entry.
    let controller = gtk::EventControllerKey::new();
    let trigger_for_key = trigger;
    controller.connect_key_pressed(move |controller, keyval, _, modifiers| {
        let Some(label) = controller.widget().and_downcast::<CellEditor>() else {
            return glib::Propagation::Proceed;
        };
        let editing = label.is_editing();
        let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);

        if !editing {
            match keyval {
                gtk::gdk::Key::F2 | gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter => {
                    trigger_for_key(&label);
                    return glib::Propagation::Stop;
                }
                // Left to GTK, Tab leaves the grid for the paginator.
                gtk::gdk::Key::Tab if !shift => {
                    move_focus(&label, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                    move_focus(&label, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
                // The column view moves between rows only.
                gtk::gdk::Key::Right => {
                    move_focus(&label, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Left => {
                    move_focus(&label, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
                _ => {}
            }
            return glib::Propagation::Proceed;
        }

        match keyval {
            gtk::gdk::Key::Tab if !shift => {
                label.stop_editing(true);
                move_focus(&label, gtk::DirectionType::TabForward);
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                label.stop_editing(true);
                move_focus(&label, gtk::DirectionType::TabBackward);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    label.add_controller(controller);
}

/// Focus moving to an IME popover ends the edit mid-composition, so the
/// commit waits until the preedit clears.
pub(super) fn install_edit_commit_handler(label: &CellEditor, col_index: usize, sender: relm4::Sender<GridMsg>) {
    {
        let text = label.entry();
        // The entry is the cell's own child, so it holds the cell weakly.
        let label_for_preedit = label.downgrade();
        let sender_for_preedit = sender.clone();
        text.connect_preedit_changed(move |_t, preedit| {
            let Some(label_for_preedit) = label_for_preedit.upgrade() else {
                return;
            };
            let active = !preedit.is_empty();
            PREEDIT_SLOT.set(&label_for_preedit, active);
            // The edit ended during the composition, so this is its commit.
            if !active && !label_for_preedit.is_editing() {
                commit_cell_edit(&label_for_preedit, col_index, &sender_for_preedit);
            }
        });
    }

    label.connect_editing_notify(move |label| {
        if label.is_editing() {
            let position = POSITION_SLOT.get(label).unwrap_or(0);
            let original = label.text().to_string();
            SNAPSHOT_SLOT.set(label, EditSnapshot { position, original });
            return;
        }
        if PREEDIT_SLOT.get(label).unwrap_or(false) {
            return;
        }
        commit_cell_edit(label, col_index, &sender);
    });
}

fn commit_cell_edit(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let Some(snap) = SNAPSHOT_SLOT.take(label) else {
        return;
    };
    let new_value = label.text().to_string();
    if new_value == snap.original {
        return;
    }
    sender
        .send(GridMsg::CellEdited {
            row_position: snap.position,
            col_index,
            new_value,
        })
        .ok();
}
