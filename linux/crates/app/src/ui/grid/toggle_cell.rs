use gtk4::prelude::*;
use gtk4::{self as gtk};
use tablepro_core::Value;
use tablepro_core::column::{BoolStorage, ColumnKind};
use tablepro_core::edit::CellInput;

use super::display_text::value_to_display_text;
use super::edit_commit::{commit_input, send_commit};
use super::{EditSnapshot, GridCell};

/// A boolean cell: a check button that commits as it is toggled.
pub struct ToggleCell;

/// How a check button shows a cell's value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToggleState {
    pub active: bool,
    /// A value that is neither true nor false shows as neither, with the
    /// value itself in the tooltip, rather than as a confidently wrong
    /// box.
    pub inconsistent: bool,
    pub tooltip: Option<String>,
}

impl ToggleCell {
    pub(super) fn setup(cell: &GridCell) {
        let check = gtk::CheckButton::builder()
            .halign(gtk::Align::Start)
            .valign(gtk::Align::Center)
            .margin_start(8)
            .margin_end(8)
            .build();
        cell.set_content(&check);
        // The cell owns the check button, so the handler finds the cell
        // through its parent rather than holding it.
        check.connect_toggled(|check| {
            let Some(cell) = check.parent().and_downcast::<GridCell>() else {
                return;
            };
            if !cell.toggle_suppressed() && cell.lock().is_none() {
                commit_toggle(&cell, check.is_active());
            }
        });
    }

    /// Flip the cell from the keyboard, as a click would.
    pub(super) fn toggle(cell: &GridCell) {
        if let Some(check) = cell.check_button() {
            check.set_active(!check.is_active());
        }
    }

    pub(super) fn draw(cell: &GridCell, check: &gtk::CheckButton, state: &ToggleState) {
        // Suppressed, so drawing the value does not echo back as an edit.
        cell.suppress_toggle(true);
        check.set_inconsistent(state.inconsistent);
        check.set_active(state.active);
        cell.suppress_toggle(false);
        check.set_tooltip_text(state.tooltip.as_deref());
    }
}

pub fn toggle_state(input: &CellInput, storage: BoolStorage) -> ToggleState {
    let neither = |tooltip: String| ToggleState {
        active: false,
        inconsistent: true,
        tooltip: Some(tooltip),
    };
    let shown = |active| ToggleState {
        active,
        inconsistent: false,
        tooltip: None,
    };
    match (input, storage) {
        (CellInput::Default, _) => neither("DEFAULT".to_owned()),
        (CellInput::Value(Value::Null), _) => neither("NULL".to_owned()),
        (CellInput::Value(Value::Bool(flag)), _) => shown(*flag),
        (CellInput::Value(Value::Int(0)), BoolStorage::Integer) => shown(false),
        (CellInput::Value(Value::Int(1)), BoolStorage::Integer) => shown(true),
        (CellInput::Value(other), _) => neither(value_to_display_text(other)),
    }
}

/// `tinyint(1)` keeps any integer, so a toggle writes 0 or 1 as one.
pub fn toggled_value(storage: BoolStorage, active: bool) -> Value {
    match storage {
        BoolStorage::Native => Value::Bool(active),
        BoolStorage::Integer => Value::Int(i64::from(active)),
    }
}

fn commit_toggle(cell: &GridCell, active: bool) {
    let (Some(row), Some(drawing)) = (cell.row(), cell.drawing()) else {
        return;
    };
    let Some(column) = drawing.catalog.as_ref() else {
        return;
    };
    let ColumnKind::Bool(storage) = column.column_type.kind else {
        return;
    };
    let snapshot = EditSnapshot {
        original: drawing.tab_ctx.edit_input(&row, cell.column()),
        row,
        column: cell.column(),
    };
    let result = commit_input(column, &snapshot, CellInput::Value(toggled_value(storage, active)));
    send_commit(cell, snapshot, result);
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::BoolStorage;
    use tablepro_core::edit::CellInput;

    use super::{ToggleState, toggle_state, toggled_value};

    fn state(active: bool, inconsistent: bool, tooltip: Option<&str>) -> ToggleState {
        ToggleState {
            active,
            inconsistent,
            tooltip: tooltip.map(str::to_owned),
        }
    }

    #[test]
    fn a_toggle_shows_only_true_and_false_as_checked_or_not() {
        let value = |value| CellInput::Value(value);

        assert_eq!(
            toggle_state(&value(Value::Bool(true)), BoolStorage::Native),
            state(true, false, None)
        );
        assert_eq!(
            toggle_state(&value(Value::Int(1)), BoolStorage::Integer),
            state(true, false, None)
        );
        assert_eq!(
            toggle_state(&value(Value::Int(0)), BoolStorage::Integer),
            state(false, false, None)
        );
        assert_eq!(
            toggle_state(&value(Value::Int(2)), BoolStorage::Integer),
            state(false, true, Some("2"))
        );
        assert_eq!(
            toggle_state(&value(Value::Null), BoolStorage::Native),
            state(false, true, Some("NULL"))
        );
        assert_eq!(
            toggle_state(&CellInput::Default, BoolStorage::Integer),
            state(false, true, Some("DEFAULT"))
        );
    }

    #[test]
    fn a_toggle_writes_the_columns_own_form() {
        assert_eq!(toggled_value(BoolStorage::Native, true), Value::Bool(true));
        assert_eq!(toggled_value(BoolStorage::Integer, true), Value::Int(1));
        assert_eq!(toggled_value(BoolStorage::Integer, false), Value::Int(0));
    }
}
