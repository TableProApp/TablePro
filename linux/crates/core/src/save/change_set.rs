use crate::edit::CellInput;
use crate::value::Value;

/// What the user changed in the grid, before any of it is SQL.
///
/// Keys are in `key_components` order, the same order the page laid
/// them out, so a key read from a row can be bound straight back.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChangeSet {
    pub inserts: Vec<RowInsert>,
    pub updates: Vec<RowUpdate>,
    pub deletes: Vec<Vec<Value>>,
}

/// A draft row. A cell the user left alone is `Default`, which means
/// the insert omits the column and the server fills it in.
#[derive(Debug, Clone, PartialEq)]
pub struct RowInsert {
    pub cells: Vec<CellInput>,
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
        self.inserts.is_empty() && self.updates.is_empty() && self.deletes.is_empty()
    }

    /// How many statements this will become, which is what the
    /// progress label counts.
    pub fn step_count(&self) -> usize {
        self.inserts.len() + self.updates.len() + self.deletes.len()
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
            inserts: vec![RowInsert {
                cells: vec![CellInput::Default],
            }],
            updates: vec![RowUpdate {
                key: vec![Value::Int(1)],
                assignments: vec![(1, Value::Text("x".to_owned()))],
            }],
            deletes: vec![vec![Value::Int(2)], vec![Value::Int(3)]],
        };

        assert!(!changes.is_empty());
        assert_eq!(changes.step_count(), 4);
    }
}
