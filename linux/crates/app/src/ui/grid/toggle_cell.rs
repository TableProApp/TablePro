use gtk4::prelude::*;
use gtk4::{self as gtk};
use tablepro_core::Value;
use tablepro_core::column::{BoolStorage, ColumnKind, ColumnType};
use tablepro_core::edit::CellInput;

use super::display_text::display_text;
use super::edit_commit::{commit_input, send_commit};
use super::{EditSnapshot, GridCell};

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
    /// `column` names the check box, as written in the table, since a
    /// box with no label reads as nothing but its state.
    pub(super) fn setup(cell: &GridCell, column: &str) {
        let check = gtk::CheckButton::builder()
            .halign(gtk::Align::Start)
            .valign(gtk::Align::Center)
            .margin_start(8)
            .margin_end(8)
            // The cell takes the focus, and toggles on F2, Return or Space,
            // so Tab leaves the grid rather than stopping inside the cell.
            .focusable(false)
            .focus_on_click(false)
            .build();
        check.update_property(&[gtk::accessible::Property::Label(column)]);
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

    pub(super) fn draw(cell: &GridCell, check: &gtk::CheckButton, state: &ToggleState) {
        // Suppressed, so drawing the value does not echo back as an edit.
        cell.suppress_toggle(true);
        check.set_inconsistent(state.inconsistent);
        check.set_active(state.active);
        cell.suppress_toggle(false);
        check.set_tooltip_text(state.tooltip.as_deref());
    }
}

/// `default` is a draft's cell left to the server.
pub fn toggle_state(value: &Value, default: bool, column: &ColumnType, storage: BoolStorage) -> ToggleState {
    let neither = |tooltip: &str| ToggleState {
        active: false,
        inconsistent: true,
        tooltip: Some(tooltip.to_owned()),
    };
    let shown = |active| ToggleState {
        active,
        inconsistent: false,
        tooltip: None,
    };
    match (default, value, storage) {
        (true, ..) => neither("DEFAULT"),
        (false, Value::Bool(flag), _) => shown(*flag),
        (false, Value::Int(0), BoolStorage::Integer) => shown(false),
        (false, Value::Int(1), BoolStorage::Integer) => shown(true),
        (false, other, _) => neither(display_text(other, column, &mut String::new()).text),
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
    use tablepro_core::column::{BoolStorage, ColumnType};

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
        let column = ColumnType::untyped_text("boolean");
        let value = |value: Value, storage| toggle_state(&value, false, &column, storage);

        assert_eq!(value(Value::Bool(true), BoolStorage::Native), state(true, false, None));
        assert_eq!(value(Value::Int(1), BoolStorage::Integer), state(true, false, None));
        assert_eq!(value(Value::Int(0), BoolStorage::Integer), state(false, false, None));
        assert_eq!(
            value(Value::Int(2), BoolStorage::Integer),
            state(false, true, Some("2"))
        );
        assert_eq!(
            value(Value::Null, BoolStorage::Native),
            state(false, true, Some("NULL"))
        );
        assert_eq!(
            toggle_state(&Value::Null, true, &column, BoolStorage::Integer),
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
