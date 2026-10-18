use crate::edit::CellInput;
use crate::value::Value;

/// What the user changed in the grid, before any of it is SQL, in the
/// order the save runs it.
///
/// The order is the caller's: a row deleted and then replaced by a new
/// row with the same unique value only saves when the DELETE runs
/// first. Keys are in `key_components` order, the same order the page
/// laid them out, so a key read from a row can be bound straight back.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChangeSet {
    pub changes: Vec<RowChange>,
}

/// One row's change.
#[derive(Debug, Clone, PartialEq)]
pub enum RowChange {
    /// A draft row. A cell the user left alone is `Default`, which
    /// means the insert omits the column and the server fills it in.
    Insert {
        cells: Vec<CellInput>,
    },
    Update(RowUpdate),
    /// The key the row had when it was read.
    Delete {
        key: Vec<Value>,
    },
}

/// One row's edits, against the key it had when it was read.
#[derive(Debug, Clone, PartialEq)]
pub struct RowUpdate {
    pub key: Vec<Value>,
    /// Column position and its new value. Only the cells that moved.
    pub assignments: Vec<(usize, Value)>,
}

impl ChangeSet {
    pub fn is_empty(&self) -> bool {
        self.changes.is_empty()
    }

    /// How many statements this will become, which is what the
    /// progress label counts.
    pub fn step_count(&self) -> usize {
        self.changes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_change_set_has_no_steps() {
        let empty = ChangeSet::default();

        assert!(empty.is_empty());
        assert_eq!(empty.step_count(), 0);
    }

    #[test]
    fn steps_count_every_kind_of_change() {
        let changes = ChangeSet {
            changes: vec![
                RowChange::Insert {
                    cells: vec![CellInput::Default],
                },
                RowChange::Update(RowUpdate {
                    key: vec![Value::Int(1)],
                    assignments: vec![(1, Value::Text("x".to_owned()))],
                }),
                RowChange::Delete {
                    key: vec![Value::Int(2)],
                },
                RowChange::Delete {
                    key: vec![Value::Int(3)],
                },
            ],
        };

        assert!(!changes.is_empty());
        assert_eq!(changes.step_count(), 4);
    }
}
