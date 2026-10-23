use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;

use super::row_state_icon::RowPendingState;
use super::{ColumnWidthBinding, GridRowId, RowObject, RowSnapshot};
use crate::services::cell_overlay::CellMarks;
use crate::services::change_tracker::{CellState, RowKey};
use crate::services::tab_tracker_handle::TabTrackerHandle;

/// `tracker` and `column_widths` are `None` for a grid nothing tracks,
/// such as editor results.
#[derive(Debug, Clone)]
pub struct TabGridContext {
    pub tracker: Option<TabTrackerHandle>,
    /// Whether the grid offers edits at all. A read-only session's grid
    /// does not.
    pub editable: bool,
    /// What names the grid's rows, which decides the columns a saved
    /// row cannot change.
    pub identity: RowIdentity,
    pub column_widths: Option<ColumnWidthBinding>,
    /// Whether the menu offers to copy rows as an SQL `IN` list, which an
    /// engine without SQL has no spelling for.
    pub in_clause: bool,
}

impl Default for TabGridContext {
    fn default() -> Self {
        Self {
            tracker: None,
            editable: false,
            identity: RowIdentity::Unordered,
            column_widths: None,
            in_clause: true,
        }
    }
}

impl TabGridContext {
    /// `None` when nothing tracks the grid or the row has no key.
    fn tracked_key(&self, row: &RowObject) -> Option<(&TabTrackerHandle, RowKey)> {
        Some((self.tracker.as_ref()?, row.id().tracker_key()?))
    }

    /// `Unchanged` for a row nothing tracks.
    pub(super) fn row_pending_state(&self, row: &RowObject) -> RowPendingState {
        self.tracked_key(row)
            .map_or(RowPendingState::Unchanged, |(tracker, key)| {
                RowPendingState::new(tracker.row_state(&key), tracker.is_error_row(&key))
            })
    }

    /// Whether the grid's rows can carry pending changes, which is when
    /// it gives them a state column.
    pub(super) fn tracks_changes(&self) -> bool {
        self.editable && self.tracker.is_some()
    }

    /// The row as the grid shows it, for every copy and export path:
    /// `RowObject::cells` holds a saved row as read and a draft not at
    /// all. A draft's cell left to the server reads as NULL.
    pub(crate) fn snapshot(&self, row: &RowObject) -> RowSnapshot {
        if let (GridRowId::Draft(draft_id), Some(tracker)) = (row.id(), self.tracker.as_ref()) {
            return RowSnapshot::new(tracker.draft_values(*draft_id).unwrap_or_default().into(), Vec::new());
        }
        let cells = row.cells().unwrap_or_else(|| Arc::from([]));
        let overrides = self
            .tracked_key(row)
            .map(|(tracker, key)| tracker.pending_values(&key, cells.len()))
            .unwrap_or_default();
        RowSnapshot::new(cells, overrides)
    }

    /// Like `snapshot`, except a draft's cell left to the server stays
    /// `Default` rather than reading as NULL.
    pub(crate) fn effective_inputs(&self, row: &RowObject) -> Vec<CellInput> {
        if let (GridRowId::Draft(draft_id), Some(tracker)) = (row.id(), self.tracker.as_ref()) {
            return tracker.draft_inputs(*draft_id).unwrap_or_default();
        }
        self.snapshot(row)
            .to_values()
            .into_iter()
            .map(CellInput::Value)
            .collect()
    }

    /// What an editor opens on: a draft's cell as the tracker holds it,
    /// a saved row's pending value, else the value as it was read.
    pub(crate) fn edit_input(&self, row: &RowObject, col: usize) -> CellInput {
        self.with_effective_value(row, col, |value, default| match default {
            true => CellInput::Default,
            false => CellInput::Value(value.clone()),
        })
    }

    /// Calls `f` with the value the cell shows, borrowed from the row
    /// unless the tracker holds a pending one. `default` is set for a
    /// draft's cell left to the server, whose value then reads as NULL.
    pub(crate) fn with_effective_value<R>(&self, row: &RowObject, col: usize, f: impl FnOnce(&Value, bool) -> R) -> R {
        let pending = self
            .tracked_key(row)
            .and_then(|(tracker, key)| tracker.cell_overlay(&key, col).pending);
        match (pending, row.cell(col)) {
            (Some(CellInput::Value(value)), _) => f(&value, false),
            (Some(CellInput::Default), _) => f(&Value::Null, true),
            (None, Some(value)) => f(value, false),
            (None, None) => f(&Value::Null, false),
        }
    }

    /// The classes that tint the cell for its row's pending change, and
    /// the cell's own state.
    pub(super) fn pending_marks(&self, row: &RowObject, col: usize) -> (Vec<&'static str>, CellState) {
        let Some((tracker, key)) = self.tracked_key(row) else {
            return (Vec::new(), CellState::Clean);
        };
        let marks = tracker.cell_marks(&key, col);
        (pending_classes(&marks, col), marks.state)
    }
}

fn pending_classes(marks: &CellMarks, col: usize) -> Vec<&'static str> {
    let mut classes = Vec::new();
    match (marks.row_deleted, marks.state) {
        (true, _) => classes.push("tp-row-pending-delete"),
        (false, CellState::InsertDraft) => classes.push("tp-row-pending-insert"),
        (false, CellState::Modified) => classes.push("tp-cell-modified"),
        (false, CellState::Clean) => {}
    }
    if col == 0 && marks.error_flash {
        classes.push("tp-row-leftmost-error-flash");
    }
    classes
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::edit::CellInput;

    use super::{RowObject, TabGridContext};
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_edit::TrackerEdit;

    fn context(tracker: &TabTrackerHandle) -> TabGridContext {
        TabGridContext {
            tracker: Some(tracker.clone()),
            ..TabGridContext::default()
        }
    }

    fn insert_draft(tracker: &TabTrackerHandle, values: Vec<Value>) -> u64 {
        let delta = tracker.apply(TrackerEdit::InsertDrafts {
            rows: vec![values.into_iter().map(CellInput::Value).collect()],
        });
        let Some(draft_id) = delta.inserted_drafts.into_iter().next() else {
            panic!("an insert adds a draft row");
        };
        draft_id
    }

    #[test]
    fn a_tracked_draft_carries_its_insert_tint_and_error_flash() {
        let tracker = TabTrackerHandle::default();
        let draft_id = insert_draft(&tracker, vec![Value::Int(4)]);
        let _ = tracker.flash_error_row(RowKey::Draft(draft_id));
        let draft = RowObject::draft(draft_id);

        let (classes, _) = context(&tracker).pending_marks(&draft, 0);

        assert_eq!(
            context(&tracker).edit_input(&draft, 0),
            CellInput::Value(Value::Int(4)),
            "a draft's cells are read from the tracker"
        );
        assert_eq!(classes, vec!["tp-row-pending-insert", "tp-row-leftmost-error-flash"]);
    }

    #[test]
    fn an_untracked_grid_draws_the_fetched_value_plainly() {
        let row = RowObject::result(vec![Value::Int(1)].into());

        let (classes, _) = TabGridContext::default().pending_marks(&row, 0);

        assert_eq!(
            TabGridContext::default().edit_input(&row, 0),
            CellInput::Value(Value::Int(1))
        );
        assert!(classes.is_empty());
    }

    #[test]
    fn a_clean_cell_is_drawn_from_the_row_itself() {
        let tracker = TabTrackerHandle::default();
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: key.clone(),
            col: 1,
            original: Value::Text("old".into()),
            value: Value::Text("new".into()),
        });
        let row = RowObject::persisted(Some(key), vec![Value::Int(1), Value::Text("old".into())].into());
        let cells = row.cells().expect("a saved row's cells");

        let borrowed = context(&tracker).with_effective_value(&row, 0, |value, _| std::ptr::eq(value, &cells[0]));
        let pending = context(&tracker).with_effective_value(&row, 1, |value, default| (value.clone(), default));

        assert!(borrowed, "an unedited cell was copied out of its row");
        assert_eq!(pending, (Value::Text("new".into()), false));
    }

    #[test]
    fn snapshots_include_pending_edits_and_draft_cells() {
        let tracker = TabTrackerHandle::default();
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: key.clone(),
            col: 1,
            original: Value::Text("old".into()),
            value: Value::Text("new".into()),
        });
        let draft_id = insert_draft(&tracker, vec![Value::Null, Value::Text("draft".into())]);
        let saved = RowObject::persisted(Some(key), vec![Value::Int(1), Value::Text("old".into())].into());

        assert_eq!(
            context(&tracker).snapshot(&saved).to_values(),
            vec![Value::Int(1), Value::Text("new".into())]
        );
        assert_eq!(
            context(&tracker).snapshot(&RowObject::draft(draft_id)).to_values(),
            vec![Value::Null, Value::Text("draft".into())]
        );
    }

    #[test]
    fn a_draft_cell_left_to_the_server_opens_as_the_default() {
        let tracker = TabTrackerHandle::default();
        let delta = tracker.apply(TrackerEdit::InsertDrafts {
            rows: vec![vec![CellInput::Default, CellInput::Value(Value::Null)]],
        });
        let draft = RowObject::draft(delta.inserted_drafts[0]);

        assert_eq!(context(&tracker).edit_input(&draft, 0), CellInput::Default);
        assert_eq!(context(&tracker).edit_input(&draft, 1), CellInput::Value(Value::Null));
        assert_eq!(
            context(&tracker).snapshot(&draft).to_values(),
            vec![Value::Null, Value::Null],
            "a copy has no value to give a default"
        );
    }
}
