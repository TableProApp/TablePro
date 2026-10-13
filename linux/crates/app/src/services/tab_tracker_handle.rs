use std::cell::RefCell;
use std::rc::Rc;

use tablepro_core::dml::BuildSqlError;
use tablepro_core::edit::CellInput;
use tablepro_core::{ColumnInfo, Value};

use super::cell_overlay::CellOverlay;
use super::change_tracker::{DraftRow, RowKey, RowState, TabChangeTracker, TrackedChanges};
use super::save_batch::{SaveBatch, SaveTarget};
use super::tracker_delta::TrackerDelta;
use super::tracker_edit::TrackerEdit;
use crate::workspace::{PendingState, SaveOutcome, SaveRejection, SaveSnapshot};

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

    /// Whether `apply` would hold the edit back for the running save.
    pub fn refuses(&self, edit: &TrackerEdit) -> bool {
        self.0.borrow().edit_is_in_flight(edit)
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

    pub fn draft_values(&self, draft_id: u64) -> Option<Vec<Value>> {
        self.0.borrow().draft_values(draft_id).map(<[Value]>::to_vec)
    }

    pub fn draft_cells(&self, draft_id: u64, columns: &[ColumnInfo]) -> Option<Vec<CellInput>> {
        self.0.borrow().draft_cells(draft_id, columns)
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

    /// The table and columns the tab read, which every save is planned
    /// against.
    #[must_use = "the grid shows stale rows until the delta is applied"]
    pub(crate) fn set_target(&self, target: SaveTarget) -> TrackerDelta {
        self.0.borrow_mut().set_target(target)
    }

    pub(crate) fn pending_state(&self) -> PendingState {
        self.0.borrow().pending_state()
    }

    pub(crate) fn begin_save(&self) -> Result<Option<SaveBatch>, SaveRejection> {
        self.0.borrow_mut().begin_save()
    }

    #[must_use = "the grid shows stale rows until the delta is applied"]
    pub(crate) fn settle_save(&self, outcome: &SaveOutcome, snapshot: SaveSnapshot) -> TrackerDelta {
        self.0.borrow_mut().settle_save(outcome, snapshot)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::DriverError;
    use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth};
    use tablepro_core::meta::TableRef;

    use super::*;
    use crate::services::tracker_delta::VisualChange;
    use crate::workspace::{RollbackCause, UnknownCause};

    fn row(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    fn integer(name: &str, primary_key: bool) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text("integer");
        column_type.kind = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        });
        ColumnInfo {
            name: name.to_owned(),
            column_type,
            nullable: false,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    /// A tracker on a two-column table, with one edit pending.
    fn edited() -> TabTrackerHandle {
        let tracker = TabTrackerHandle::default();
        let _ = tracker.set_target(SaveTarget {
            table: TableRef::unqualified("t"),
            columns: vec![integer("id", true), integer("n", false)],
        });
        edit_cell(&tracker, 1, 2);
        tracker
    }

    fn edit_cell(tracker: &TabTrackerHandle, id: i64, value: i64) {
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: row(id),
            col: 1,
            original: Value::Int(0),
            value: Value::Int(value),
        });
    }

    fn rolled_back() -> SaveOutcome {
        SaveOutcome::RolledBack(RollbackCause::Driver(DriverError::server("no")))
    }

    #[test]
    fn frozen_tracker_rejects_begin_save() {
        let tracker = edited();
        let batch = tracker.begin_save().expect("a save").expect("changes to save");

        assert_eq!(tracker.begin_save().err(), Some(SaveRejection::AlreadySaving));
        let _ = tracker.settle_save(&SaveOutcome::Unknown(UnknownCause::Interrupted), batch.snapshot);

        assert_eq!(tracker.begin_save().err(), Some(SaveRejection::OutcomeUnknown));
        assert_eq!(
            tracker.pending_state(),
            PendingState::OutcomeUnknown(UnknownCause::Interrupted)
        );
        let _ = tracker.discard();
        assert_eq!(tracker.pending_state(), PendingState::Clean);
        assert!(matches!(tracker.begin_save(), Ok(None)));
    }

    #[test]
    fn rolled_back_keeps_dirty() {
        let tracker = edited();
        let batch = tracker.begin_save().expect("a save").expect("changes to save");
        assert_eq!(tracker.pending_state(), PendingState::Saving);

        let delta = tracker.settle_save(&rolled_back(), batch.snapshot);

        assert_eq!(delta.pending_count, 1);
        assert_eq!(tracker.pending_state(), PendingState::Unsaved);
        let again = tracker.begin_save().expect("a save").expect("changes to save");
        assert_eq!(again.changes.changes.changes, batch.changes.changes.changes);
    }

    #[test]
    fn committed_clears_only_snapshot_edits() {
        let tracker = edited();
        let _ = tracker.apply(TrackerEdit::Insert {
            values: vec![Value::Int(9), Value::Int(9)],
        });
        let batch = tracker.begin_save().expect("a save").expect("changes to save");
        assert_eq!(batch.changes.changes.changes.len(), 2);

        // Made while the save ran: a new value for a cell in the save,
        // and an edit to another row.
        edit_cell(&tracker, 1, 3);
        edit_cell(&tracker, 4, 5);
        let delta = tracker.settle_save(&SaveOutcome::Committed { rows: Some(2) }, batch.snapshot);

        assert_eq!(delta.pending_count, 2);
        assert!(matches!(delta.visual.as_slice(), [VisualChange::RemoveDraft { .. }]));
        assert!(tracker.drafts().is_empty(), "the inserted draft stayed pending");
        assert_eq!(tracker.pending_state(), PendingState::Unsaved);
        assert_eq!(tracker.cell_overlay(&row(1), 1, &Value::Int(0)).value, Value::Int(3));
        assert_eq!(tracker.cell_overlay(&row(4), 1, &Value::Int(0)).value, Value::Int(5));
    }

    #[test]
    fn an_insert_or_delete_in_flight_is_not_changed_until_it_settles() {
        let tracker = edited();
        let inserted = tracker.apply(TrackerEdit::Insert {
            values: vec![Value::Int(9), Value::Int(9)],
        });
        let draft_id = match inserted.visual.as_slice() {
            [VisualChange::InsertDraft { draft_id, .. }] => *draft_id,
            other => panic!("an insert adds one draft row: {other:?}"),
        };
        let batch = tracker.begin_save().expect("a save").expect("changes to save");

        let typed = TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            value: Value::Int(10),
        };
        assert!(tracker.refuses(&typed));
        let held = tracker.apply(typed);
        let _ = tracker.apply(TrackerEdit::DiscardDraft { draft_id });
        assert!(tracker.undo().is_none(), "undo ran while a save was in flight");

        assert_eq!(held.rows, [RowKey::Draft(draft_id)], "the typed value stayed on screen");
        assert!(held.visual.is_empty());

        assert_eq!(tracker.drafts()[0].values[1], Value::Int(9));
        let _ = tracker.settle_save(&rolled_back(), batch.snapshot);
        assert!(tracker.undo().is_some());
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
        let [VisualChange::InsertDraft { draft_id }] = inserted.visual.as_slice() else {
            panic!("an insert adds one draft row: {:?}", inserted.visual);
        };
        assert_eq!(
            tracker.draft_values(*draft_id),
            Some(vec![Value::Null, Value::Text("c".into())])
        );
        assert_eq!(tracker.pending_count(), 2);
    }

    #[test]
    fn undo_rebinds_the_row_with_the_previous_pending_value() {
        let tracker = TabTrackerHandle::default();
        let fetched = Value::Text("a".into());
        for value in ["b", "c"] {
            let _ = tracker.apply(TrackerEdit::Cell {
                row_key: row(1),
                col: 1,
                original: fetched.clone(),
                value: Value::Text(value.into()),
            });
        }

        let undone = tracker.undo().expect("an edit to undo");

        assert_eq!(undone.rows, vec![row(1)]);
        assert_eq!(undone.pending_count, 1);
        assert_eq!(
            tracker.cell_overlay(&row(1), 1, &fetched).value,
            Value::Text("b".into())
        );
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
