use std::sync::Arc;

use tablepro_core::Value;

static NULL: Value = Value::Null;

/// A row as the grid shows it, pending edits included. It shares the
/// cells the page read and owns only the changed ones, so it can leave
/// the GTK thread cheaply.
#[derive(Debug, Clone)]
pub struct RowSnapshot {
    cells: Arc<[Value]>,
    /// Pending values by column, in column order.
    overrides: Box<[(usize, Value)]>,
}

impl RowSnapshot {
    pub fn new(cells: Arc<[Value]>, mut overrides: Vec<(usize, Value)>) -> Self {
        // `value` looks overrides up by binary search.
        overrides.sort_by_key(|(column, _)| *column);
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

    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    pub fn values(&self) -> impl Iterator<Item = &Value> {
        (0..self.len()).map(|column| self.value(column))
    }

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

    #[test]
    fn row_snapshot_shares_unmodified_cells() {
        let cells: Arc<[Value]> = vec![Value::Int(1), Value::Text("Ada".into()), Value::Text("old".into())].into();

        let snapshot = RowSnapshot::new(cells.clone(), vec![(2, Value::Text("new".into()))]);

        assert!(snapshot.shares_cells_with(&cells), "the row's cells were copied");
        assert_eq!(snapshot.overrides.len(), 1, "an unedited cell was copied");
        assert_eq!(
            snapshot.to_values(),
            vec![Value::Int(1), Value::Text("Ada".into()), Value::Text("new".into())]
        );
        assert_eq!(snapshot.value(9), &Value::Null);
        assert_eq!(snapshot.len(), 3);
    }

    #[test]
    fn overrides_given_out_of_order_still_apply() {
        let cells: Arc<[Value]> = vec![Value::Int(1), Value::Int(2), Value::Int(3)].into();

        let snapshot = RowSnapshot::new(cells, vec![(2, Value::Int(30)), (0, Value::Null)]);

        assert_eq!(snapshot.to_values(), vec![Value::Null, Value::Int(2), Value::Int(30)]);
    }

    #[test]
    fn a_snapshot_can_leave_the_gtk_thread() {
        fn sendable<T: Send + Sync>() {}

        sendable::<RowSnapshot>();
    }
}
