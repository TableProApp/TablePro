use tablepro_core::Value;

use super::{ColumnWidthBinding, RowObject};
use crate::services::cell_overlay::CellOverlay;
use crate::services::change_tracker::{CellState, RowKey, RowState};
use crate::services::tab_tracker_handle::TabTrackerHandle;

/// `tracker` and `column_widths` are `None` for a grid nothing tracks,
/// such as editor results.
#[derive(Debug, Clone, Default)]
pub struct TabGridContext {
    pub tracker: Option<TabTrackerHandle>,
    pub pk_col_indices: Vec<usize>,
    pub column_widths: Option<ColumnWidthBinding>,
}

impl TabGridContext {
    /// `None` when nothing tracks the grid or a persisted row has no
    /// usable primary key.
    fn tracked_key(&self, row: &RowObject) -> Option<(&TabTrackerHandle, RowKey)> {
        let tracker = self.tracker.as_ref()?;
        let key = match row.draft_id() {
            Some(draft_id) => RowKey::Draft(draft_id),
            None => {
                let pk_values: Vec<Value> = self.pk_col_indices.iter().map(|&i| row.cell_value(i)).collect();
                RowKey::from_pk_values(&pk_values)?
            }
        };
        Some((tracker, key))
    }

    /// Every copy and export path reads this rather than
    /// `RowObject::cells_clone`, which holds a persisted row as fetched.
    pub(crate) fn effective_cells(&self, row: &RowObject) -> Vec<Value> {
        let raw = row.cells_clone();
        let Some((tracker, key)) = self.tracked_key(row) else {
            return raw;
        };
        raw.iter()
            .enumerate()
            .map(|(col, value)| tracker.cell_overlay(&key, col, value).value)
            .collect()
    }

    pub(super) fn bind_state(&self, row: &RowObject, col: usize) -> (Value, Vec<&'static str>) {
        let raw = row.cell_value(col);
        let Some((tracker, key)) = self.tracked_key(row) else {
            return (raw, Vec::new());
        };
        let overlay = tracker.cell_overlay(&key, col, &raw);
        let classes = pending_classes(tracker.row_state(&key), &overlay, col);
        (overlay.value, classes)
    }
}

fn pending_classes(row_state: RowState, overlay: &CellOverlay, col: usize) -> Vec<&'static str> {
    let mut classes = Vec::new();
    match (row_state, overlay.state) {
        (RowState::PendingDelete, _) => classes.push("tp-row-pending-delete"),
        (RowState::InsertDraft, _) => classes.push("tp-row-pending-insert"),
        (_, CellState::Modified) => classes.push("tp-cell-modified"),
        _ => {}
    }
    if col == 0 && overlay.error_flash {
        classes.push("tp-row-leftmost-error-flash");
    }
    classes
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;

    use super::{RowObject, TabGridContext};
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;

    #[test]
    fn a_tracked_draft_carries_its_insert_tint_and_error_flash() {
        let tracker = TabTrackerHandle::default();
        let delta = tracker.apply(crate::services::tracker_edit::TrackerEdit::Insert {
            values: vec![Value::Null],
        });
        let Some(crate::services::tracker_delta::VisualChange::InsertDraft { draft_id, values }) =
            delta.visual.into_iter().next()
        else {
            panic!("an insert adds a draft row");
        };
        let _ = tracker.flash_error_row(RowKey::Draft(draft_id));
        let context = TabGridContext {
            tracker: Some(tracker),
            pk_col_indices: vec![0],
            column_widths: None,
        };

        let (_, classes) = context.bind_state(&RowObject::new_draft(draft_id, values), 0);

        assert_eq!(classes, vec!["tp-row-pending-insert", "tp-row-leftmost-error-flash"]);
    }

    #[test]
    fn an_untracked_grid_draws_the_fetched_value_plainly() {
        let row = RowObject::new(vec![Value::Int(1)]);

        let (value, classes) = TabGridContext::default().bind_state(&row, 0);

        assert_eq!(value, Value::Int(1));
        assert!(classes.is_empty());
    }
}
