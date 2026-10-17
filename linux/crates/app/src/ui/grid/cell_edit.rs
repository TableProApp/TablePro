use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::edit::{CellInput, EditParseError, EditText, edit_text};

use super::calendar_editor::CalendarEditor;
use super::cell_editor_kind::{CellEditorKind, EDIT_MAX_BYTES};
use super::edit_commit::empty_placeholder;
use super::inline_editor::{InlineEditor, InlineOptions};
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
        // A GTK editor would hold the text only up to the NUL, and
        // committing it would cut the value there.
        EditText::Editable(editable) if editable.contains('\0') => {
            if let Some(sink) = cell.sink() {
                sink(GridMsg::ShowToast(crate::i18n::gettext(
                    "Values with a NUL character can't be edited here",
                )));
            }
            return;
        }
        EditText::Editable(editable) if editable.len() > EDIT_MAX_BYTES => {
            if let Some(sink) = cell.sink() {
                sink(GridMsg::ShowToast(too_large_to_edit()));
            }
            return;
        }
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

fn too_large_to_edit() -> String {
    let size = gtk::glib::format_size(EDIT_MAX_BYTES as u64);
    crate::i18n::gettext_f("Values over {size} can't be edited here", &[("size", size.as_str())])
}

pub(super) fn install_edit_triggers(cell: &GridCell) {
    // Editing takes a double-click, since a single click in a grid
    // selects the row. Capture phase, because the column view's row
    // selection takes the press in the bubble phase. The handler reads
    // the cell from its gesture: the cell owns its controllers, so
    // capturing it would be a cycle.
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
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;

    use super::*;
    use crate::ui::grid::test_grid::{Grid, named};

    #[gtk4::test]
    fn a_value_too_large_to_lay_out_does_not_open_and_says_why() {
        let large = "x".repeat(EDIT_MAX_BYTES + 1);
        let grid = Grid::open(
            vec![named("id", "integer", true), named("body", "text", false)],
            vec![vec![Value::Int(1), Value::Text(large)]],
        );
        let cell = grid.cell_of(1, 1);

        begin_edit(&cell);

        assert!(!cell.is_editing(), "an editor opened on the whole value");
        let toasts: Vec<String> = grid
            .take_messages()
            .into_iter()
            .filter_map(|message| match message {
                GridMsg::ShowToast(text) => Some(text),
                _ => None,
            })
            .collect();
        // GLib puts a no-break space between the number and the unit.
        assert_eq!(toasts, ["Values over 1.0\u{a0}MB can't be edited here"]);
    }
}
