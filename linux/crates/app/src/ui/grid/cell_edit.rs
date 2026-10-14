use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::edit::{CellInput, EditParseError, EditText, edit_text};

use super::calendar_editor::CalendarEditor;
use super::cell_editor_kind::CellEditorKind;
use super::edit_commit::empty_placeholder;
use super::inline_editor::{InlineEditor, InlineOptions, finish_inline};
use super::multiline_editor::MultilineEditor;
use super::{EditSnapshot, GridCell, GridMsg};
use crate::ui::error_text::edit_parse_message;

/// Open the editor the cell's column and value call for. It starts from
/// the whole value with any pending edit, never from the text the cell
/// draws, which is cut short or stands in for the value.
///
/// A boolean cell opens nothing: its check button is the editor, so
/// opening it never writes a value.
pub(crate) fn begin_edit(cell: &GridCell) {
    let (Some(row), Some(drawing)) = (cell.row(), cell.drawing()) else {
        return;
    };
    let Some(column) = drawing.catalog.as_ref() else {
        return;
    };
    let kind = CellEditorKind::for_cell(column, cell.lock().map_or(Ok(()), Err));
    match kind {
        CellEditorKind::ReadOnly(_) | CellEditorKind::Toggle(_) => return,
        CellEditorKind::Inline { .. } | CellEditorKind::Multiline { .. } | CellEditorKind::Calendar => {}
    }
    let original = drawing.tab_ctx.edit_input(&row, cell.column());
    let text = match &original {
        CellInput::Value(value) => edit_text(value, &column.column_type),
        CellInput::Default => EditText::Editable(String::new()),
    };
    let editable = match &text {
        EditText::Editable(editable) => editable.clone(),
        EditText::ReadOnly(reason) => {
            if let Some(sink) = cell.sink() {
                sink(GridMsg::ShowToast(edit_parse_message(&EditParseError::NotEditable(
                    *reason,
                ))));
            }
            return;
        }
    };
    let inline = |accepts_line_breaks, purpose| InlineOptions {
        accepts_line_breaks,
        purpose,
        placeholder: empty_placeholder(column, row.id()),
    };
    let snapshot = EditSnapshot {
        row: row.clone(),
        column: cell.column(),
        original,
    };
    match kind.for_text(&text) {
        CellEditorKind::Inline {
            accepts_line_breaks,
            purpose,
        } => InlineEditor::begin(cell, snapshot, &editable, inline(accepts_line_breaks, purpose)),
        CellEditorKind::Multiline { language } => MultilineEditor::open(cell, snapshot, &editable, language),
        CellEditorKind::Calendar => CalendarEditor::open(
            cell,
            snapshot,
            column,
            editable,
            inline(false, gtk::InputPurpose::FreeForm),
        ),
        CellEditorKind::Toggle(_) | CellEditorKind::ReadOnly(_) => {}
    }
}

/// `child_focus` on the window is what a real Tab press does.
fn move_focus(widget: &impl IsA<gtk::Widget>, direction: gtk::DirectionType) {
    let Some(root) = widget.root() else { return };
    let Ok(window) = root.dynamic_cast::<gtk::Window>() else {
        return;
    };
    window.child_focus(direction);
}

pub(super) fn install_edit_triggers(cell: &GridCell) {
    // Editing takes a double-click, since a single click in a grid
    // selects the row. Capture phase, because the column view's row
    // selection takes the press in the bubble phase.
    //
    // The handlers read the cell from their controller: the cell owns
    // both controllers, so capturing it would be a cycle.
    let gesture = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_PRIMARY).build();
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    gesture.connect_pressed(move |gesture, n_press, _, _| {
        if n_press != 2 {
            return;
        }
        let Some(cell) = gesture.widget().and_downcast::<GridCell>() else {
            return;
        };
        if cell.lock().is_some() || cell.is_editing() {
            return;
        }
        gesture.set_state(gtk::EventSequenceState::Claimed);
        begin_edit(&cell);
    });
    cell.add_controller(gesture);

    // While editing, Return and Escape belong to the open editor.
    let controller = gtk::EventControllerKey::new();
    controller.connect_key_pressed(move |controller, keyval, _, modifiers| {
        let Some(cell) = controller.widget().and_downcast::<GridCell>() else {
            return glib::Propagation::Proceed;
        };
        let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);
        let direction = match keyval {
            gtk::gdk::Key::Tab if !shift => Some(gtk::DirectionType::TabForward),
            gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => Some(gtk::DirectionType::TabBackward),
            _ => None,
        };
        if cell.inline_text().is_some() {
            let Some(direction) = direction else {
                return glib::Propagation::Proceed;
            };
            finish_inline(&cell, true);
            move_focus(&cell, direction);
            return glib::Propagation::Stop;
        }
        if cell.is_editing() {
            return glib::Propagation::Proceed;
        }
        match keyval {
            gtk::gdk::Key::F2 | gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter => {
                begin_edit(&cell);
                glib::Propagation::Stop
            }
            // The column view moves between rows only.
            gtk::gdk::Key::Right => {
                move_focus(&cell, gtk::DirectionType::TabForward);
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Left => {
                move_focus(&cell, gtk::DirectionType::TabBackward);
                glib::Propagation::Stop
            }
            // Left to GTK, Tab leaves the grid for the paginator.
            _ => match direction {
                Some(direction) => {
                    move_focus(&cell, direction);
                    glib::Propagation::Stop
                }
                None => glib::Propagation::Proceed,
            },
        }
    });
    cell.add_controller(controller);
}
