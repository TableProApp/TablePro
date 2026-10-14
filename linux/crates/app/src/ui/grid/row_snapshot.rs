use std::sync::Arc;

use tablepro_core::Value;

static NULL: Value = Value::Null;

/// A row as the grid shows it, pending edits included, for a copy or an
/// export. It shares the cells the page read and holds its own copy of
/// only the cells the user changed, and it can leave the GTK thread.
#[derive(Debug, Clone)]
pub struct RowSnapshot {
    cells: Arc<[Value]>,
    /// Pending values by column, in column order.
    overrides: Box<[(usize, Value)]>,
}

impl RowSnapshot {
    pub fn new(cells: Arc<[Value]>, overrides: Vec<(usize, Value)>) -> Self {
        Self {
            cells,
            overrides: overrides.into_boxed_slice(),
        }
    }

    /// NULL for a column past the row's end.
    pub fn value(&self, column: usize) -> &Value {
        match self.overrides.binary_search_by_key(&column, |(col, _)| *col) {
            Ok(index) => &self.overrides[index].1,
            Err(_) => self.cells.get(column).unwrap_or(&NULL),
        }
    }

    pub fn len(&self) -> usize {
        self.cells.len()
    }

    /// Each cell as the grid shows it, borrowed, for an encoder that
    /// takes a row at a time.
    pub fn values(&self) -> impl Iterator<Item = &Value> {
        (0..self.len()).map(|column| self.value(column))
    }

    /// The row as owned cells, for a renderer that takes whole rows.
    pub fn to_values(&self) -> Vec<Value> {
        self.values().cloned().collect()
    }

    #[cfg(test)]
    pub(crate) fn shares_cells_with(&self, cells: &Arc<[Value]>) -> bool {
        Arc::ptr_eq(&self.cells, cells)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_core::Value;

    use super::RowSnapshot;
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::ui::grid::{RowObject, TabGridContext};

    #[test]
    fn row_snapshot_shares_unmodified_cells() {
        let tracker = TabTrackerHandle::default();
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: key.clone(),
            col: 2,
            original: Value::Text("old".into()),
            value: Value::Text("new".into()),
        });
        let cells: Arc<[Value]> = vec![Value::Int(1), Value::Text("Ada".into()), Value::Text("old".into())].into();
        let row = RowObject::persisted(Some(key), cells.clone());
        let context = TabGridContext {
            tracker: Some(tracker),
            ..TabGridContext::default()
        };

        let snapshot = context.snapshot(&row);

        assert!(Arc::ptr_eq(&snapshot.cells, &cells), "the row's cells were copied");
        assert_eq!(snapshot.overrides.len(), 1, "an unedited cell was copied");
        assert_eq!(snapshot.overrides[0].0, 2);
        assert_eq!(
            snapshot.to_values(),
            vec![Value::Int(1), Value::Text("Ada".into()), Value::Text("new".into())]
        );
        assert_eq!(snapshot.value(9), &Value::Null);
    }

    #[test]
    fn a_draft_snapshot_reads_a_default_as_null() {
        let tracker = TabTrackerHandle::default();
        let delta = tracker.apply(TrackerEdit::InsertDrafts {
            rows: vec![vec![
                tablepro_core::edit::CellInput::Default,
                tablepro_core::edit::CellInput::Value(Value::Int(3)),
            ]],
        });
        let draft = RowObject::draft(delta.inserted_drafts[0]);
        let context = TabGridContext {
            tracker: Some(tracker),
            ..TabGridContext::default()
        };

        assert_eq!(context.snapshot(&draft).to_values(), vec![Value::Null, Value::Int(3)]);
    }

    #[test]
    fn a_snapshot_can_leave_the_gtk_thread() {
        fn sendable<T: Send + Sync>() {}

        sendable::<RowSnapshot>();
    }
}
