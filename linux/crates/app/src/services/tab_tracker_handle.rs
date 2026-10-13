use std::cell::RefCell;
use std::rc::Rc;

use tablepro_core::dml::BuildSqlError;
use tablepro_core::{ColumnInfo, Value};

use super::cell_overlay::CellOverlay;
use super::change_tracker::{DraftRow, RowKey, RowState, TabChangeTracker, TrackedChanges};
use super::tracker_delta::TrackerDelta;
use super::tracker_edit::TrackerEdit;

/// A browse tab's tracker. Each method borrows only for its own body
/// and hands back owned data, so a grid bind that runs while the
/// caller is still applying a delta never meets a held borrow.
#[derive(Debug, Clone, Default)]
pub struct TabTrackerHandle(Rc<RefCell<TabChangeTracker>>);

impl TabTrackerHandle {
    pub fn cell_overlay(&self, row_key: &RowKey, col: usize, original: &Value) -> CellOverlay {
        self.0.borrow().cell_overlay(row_key, col, original)
    }

    pub fn row_state(&self, row_key: &RowKey) -> RowState {
        self.0.borrow().row_state(row_key)
    }

    #[must_use = "the grid shows stale rows until the delta is applied"]
    pub fn apply(&self, edit: TrackerEdit) -> TrackerDelta {
        self.0.borrow_mut().apply(edit)
    }

    #[must_use = "the grid shows stale rows until the delta is applied"]
    pub fn undo(&self) -> Option<TrackerDelta> {
        self.0.borrow_mut().undo()
    }

    #[must_use = "the grid shows stale rows until the delta is applied"]
    pub fn redo(&self) -> Option<TrackerDelta> {
        self.0.borrow_mut().redo()
    }

    pub fn pending_count(&self) -> usize {
        self.0.borrow().pending_count()
    }

    pub fn drafts(&self) -> Vec<DraftRow> {
        self.0.borrow().drafts().to_vec()
    }

    pub fn change_set(&self, columns: &[ColumnInfo]) -> Result<TrackedChanges, BuildSqlError> {
        self.0.borrow().change_set(columns)
    }

    #[must_use = "the grid shows stale rows until the delta is applied"]
    pub fn discard(&self) -> TrackerDelta {
        self.0.borrow_mut().discard()
    }

    pub fn flash_error_row(&self, row_key: RowKey) -> u64 {
        self.0.borrow_mut().flash_error_row(row_key)
    }

    pub fn clear_error_row_if(&self, generation: u64) -> bool {
        self.0.borrow_mut().clear_error_row_if(generation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::tracker_delta::VisualChange;

    fn row(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    #[test]
    fn apply_returns_delta_with_pending_count() {
        let tracker = TabTrackerHandle::default();

        let edited = tracker.apply(TrackerEdit::Cell {
            row_key: row(1),
            col: 1,
            original: Value::Text("a".into()),
            value: Value::Text("b".into()),
        });
        let inserted = tracker.apply(TrackerEdit::Insert {
            values: vec![Value::Null, Value::Text("c".into())],
        });

        assert_eq!(edited.rows, vec![row(1)]);
        assert_eq!(edited.pending_count, 1);
        assert_eq!(inserted.pending_count, 2);
        assert!(matches!(
            inserted.visual.as_slice(),
            [VisualChange::InsertDraft { values, .. }] if values[1] == Value::Text("c".into())
        ));
        assert_eq!(tracker.pending_count(), 2);
    }

    #[test]
    fn clones_share_one_tracker() {
        let tracker = TabTrackerHandle::default();
        let grid_copy = tracker.clone();

        let _ = tracker.apply(TrackerEdit::Delete {
            row_key: row(4),
            original_values: vec![Value::Int(4)],
        });

        assert_eq!(grid_copy.row_state(&row(4)), RowState::PendingDelete);
    }

    #[test]
    fn a_read_inside_a_delta_loop_finds_no_held_borrow() {
        let tracker = TabTrackerHandle::default();
        let delta = tracker.apply(TrackerEdit::Cell {
            row_key: row(1),
            col: 0,
            original: Value::Int(1),
            value: Value::Int(2),
        });

        for key in &delta.rows {
            let _ = tracker.apply(TrackerEdit::Delete {
                row_key: key.clone(),
                original_values: vec![Value::Int(1)],
            });
            assert_eq!(tracker.cell_overlay(key, 0, &Value::Int(1)).value, Value::Int(2));
        }
    }
}
