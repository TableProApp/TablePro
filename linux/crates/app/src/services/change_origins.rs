use tablepro_core::save::{ChangeSet, RowChange};

/// How many rows a save adds and removes, which is what it does to the
/// table's row count.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ChangeOrigins {
    pub inserts: u64,
    pub deletes: u64,
}

impl ChangeOrigins {
    pub fn of(changes: &ChangeSet) -> Self {
        changes.changes.iter().fold(Self::default(), |mut origins, change| {
            match change {
                RowChange::Insert { .. } => origins.inserts += 1,
                RowChange::Delete { .. } => origins.deletes += 1,
                RowChange::Update(_) => {}
            }
            origins
        })
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::save::RowUpdate;

    use super::*;

    #[test]
    fn a_save_counts_its_inserts_and_deletes_but_not_its_updates() {
        let changes = ChangeSet {
            changes: vec![
                RowChange::Insert { cells: Vec::new() },
                RowChange::Update(RowUpdate {
                    key: vec![Value::Int(1)],
                    assignments: Vec::new(),
                }),
                RowChange::Delete {
                    key: vec![Value::Int(2)],
                },
                RowChange::Insert { cells: Vec::new() },
            ],
        };

        assert_eq!(ChangeOrigins::of(&changes), ChangeOrigins { inserts: 2, deletes: 1 });
    }
}
