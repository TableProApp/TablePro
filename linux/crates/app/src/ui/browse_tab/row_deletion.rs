use std::sync::Arc;

use tablepro_core::Value;

use crate::services::change_tracker::RowKey;
use crate::ui::grid::{GridRowId, RowObject};

/// What one Delete does to the rows it was given.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RowDeletion {
    /// Saved rows to mark, each with the row as it was read.
    pub persisted: Vec<(RowKey, Arc<[Value]>)>,
    pub drafts: Vec<u64>,
    /// Rows a DELETE has no key to name by.
    pub unkeyed: usize,
}

impl RowDeletion {
    pub fn len(&self) -> usize {
        self.persisted.len() + self.drafts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

pub fn plan_row_deletion(rows: &[RowObject]) -> RowDeletion {
    let mut deletion = RowDeletion::default();
    for row in rows {
        match row.id() {
            GridRowId::Draft(draft_id) => deletion.drafts.push(*draft_id),
            GridRowId::Persisted(key) => deletion.persisted.push((key.clone(), row.cells().unwrap_or_default())),
            GridRowId::Unkeyed | GridRowId::Result => deletion.unkeyed += 1,
        }
    }
    deletion
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;

    use super::plan_row_deletion;
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::RowObject;

    #[test]
    fn plan_row_deletion_partitions_drafts_persisted_and_unkeyed() {
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");
        let rows = [
            RowObject::draft(4),
            RowObject::persisted(Some(key.clone()), vec![Value::Int(1), Value::Text("a".into())].into()),
            RowObject::persisted(None, vec![Value::Int(2)].into()),
            RowObject::result(vec![Value::Int(3)].into()),
            RowObject::draft(5),
        ];

        let deletion = plan_row_deletion(&rows);

        assert_eq!(deletion.drafts, vec![4, 5]);
        assert_eq!(
            deletion.persisted,
            vec![(key, vec![Value::Int(1), Value::Text("a".into())].into())]
        );
        assert_eq!(deletion.unkeyed, 2);
        assert_eq!(deletion.len(), 3);
    }
}
