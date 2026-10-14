use tablepro_core::Value;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;

use super::{ColumnWidthBinding, GridRowId, RowObject};
use crate::services::cell_overlay::CellOverlay;
use crate::services::change_tracker::{CellState, RowKey, RowState};
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
}

impl Default for TabGridContext {
    fn default() -> Self {
        Self {
            tracker: None,
            editable: false,
            identity: RowIdentity::Unordered,
            column_widths: None,
        }
    }
}

impl TabGridContext {
    /// `None` when nothing tracks the grid or the row has no key.
    fn tracked_key(&self, row: &RowObject) -> Option<(&TabTrackerHandle, RowKey)> {
        Some((self.tracker.as_ref()?, row.id().tracker_key()?))
    }

    /// Every copy and export path reads this rather than
    /// `RowObject::cells`, which holds a saved row as fetched and a
    /// draft not at all.
    pub(crate) fn effective_cells(&self, row: &RowObject) -> Vec<Value> {
        if let (GridRowId::Draft(draft_id), Some(tracker)) = (row.id(), self.tracker.as_ref()) {
            return tracker.draft_values(*draft_id).unwrap_or_default();
        }
        let Some(raw) = row.cells() else {
            return Vec::new();
        };
        let Some((tracker, key)) = self.tracked_key(row) else {
            return raw.to_vec();
        };
        raw.iter()
            .enumerate()
            .map(|(col, value)| tracker.cell_overlay(&key, col, value).value)
            .collect()
    }

    /// Like `effective_cells`, except a draft's cell left to the server
    /// stays `Default` rather than reading as NULL.
    pub(crate) fn effective_inputs(&self, row: &RowObject) -> Vec<CellInput> {
        if let (GridRowId::Draft(draft_id), Some(tracker)) = (row.id(), self.tracker.as_ref()) {
            return tracker.draft_inputs(*draft_id).unwrap_or_default();
        }
        self.effective_cells(row).into_iter().map(CellInput::Value).collect()
    }

    /// What an editor opens on: a draft's cell as the tracker holds it,
    /// a saved row's pending value, else the value as it was read.
    pub(crate) fn edit_input(&self, row: &RowObject, col: usize) -> CellInput {
        self.bind_state(row, col).0
    }

    pub(super) fn bind_state(&self, row: &RowObject, col: usize) -> (CellInput, Vec<&'static str>) {
        let raw = row.cell(col).cloned().unwrap_or(Value::Null);
        let Some((tracker, key)) = self.tracked_key(row) else {
            return (CellInput::Value(raw), Vec::new());
        };
        let overlay = tracker.cell_overlay(&key, col, &raw);
        let classes = pending_classes(tracker.row_state(&key), &overlay, col);
        let input = match row.id() {
            GridRowId::Draft(draft_id) => tracker
                .draft_input(*draft_id, col)
                .unwrap_or(CellInput::Value(overlay.value)),
            GridRowId::Result | GridRowId::Unkeyed | GridRowId::Persisted(_) => CellInput::Value(overlay.value),
        };
        (input, classes)
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

        let (value, classes) = context(&tracker).bind_state(&RowObject::draft(draft_id), 0);

        assert_eq!(
            value,
            CellInput::Value(Value::Int(4)),
            "a draft's cells are read from the tracker"
        );
        assert_eq!(classes, vec!["tp-row-pending-insert", "tp-row-leftmost-error-flash"]);
    }

    #[test]
    fn an_untracked_grid_draws_the_fetched_value_plainly() {
        let row = RowObject::result(vec![Value::Int(1)].into());

        let (value, classes) = TabGridContext::default().bind_state(&row, 0);

        assert_eq!(value, CellInput::Value(Value::Int(1)));
        assert!(classes.is_empty());
    }

    #[test]
    fn effective_cells_include_pending_edits_and_draft_cells() {
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
            context(&tracker).effective_cells(&saved),
            vec![Value::Int(1), Value::Text("new".into())]
        );
        assert_eq!(
            context(&tracker).effective_cells(&RowObject::draft(draft_id)),
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
            context(&tracker).effective_cells(&draft),
            vec![Value::Null, Value::Null],
            "a copy has no value to give a default"
        );
    }
}
