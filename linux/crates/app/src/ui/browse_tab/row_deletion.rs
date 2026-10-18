use std::sync::Arc;

use tablepro_core::Value;

use crate::services::change_tracker::RowKey;
use crate::ui::grid::{GridRowId, RowObject};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct RowDeletion {
    /// Each with the row as it was read.
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

    /// A draft is dropped at once with its undo history, so a set that
    /// holds one cannot be described as waiting for Save.
    pub fn confirmation_body(&self) -> String {
        match (self.persisted.is_empty(), self.drafts.is_empty()) {
            (_, true) => crate::i18n::gettext(
                "These rows will be marked for deletion. They aren't removed until you click Save.",
            ),
            (true, false) => crate::i18n::gettext(
                "These rows were never saved. They're removed now, and Undo won't bring them back.",
            ),
            (false, false) => crate::i18n::gettext(
                "Saved rows will be marked for deletion and aren't removed until you click Save. Rows never saved are removed now, and Undo won't bring them back.",
            ),
        }
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

    #[test]
    fn the_confirmation_says_drafts_go_at_once() {
        let saved = RowObject::persisted(
            Some(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key")),
            vec![Value::Int(1)].into(),
        );

        let only_saved = plan_row_deletion(std::slice::from_ref(&saved)).confirmation_body();
        let only_drafts = plan_row_deletion(&[RowObject::draft(1)]).confirmation_body();
        let mixed = plan_row_deletion(&[saved, RowObject::draft(1)]).confirmation_body();

        assert!(only_saved.contains("click Save"), "{only_saved}");
        assert!(!only_saved.contains("removed now"), "{only_saved}");
        assert!(only_drafts.contains("removed now"), "{only_drafts}");
        assert!(!only_drafts.contains("click Save"), "{only_drafts}");
        assert!(mixed.contains("click Save") && mixed.contains("removed now"), "{mixed}");
    }
}
