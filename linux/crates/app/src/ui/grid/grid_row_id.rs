use crate::services::change_tracker::RowKey;

/// What a grid row is to the tab that tracks its edits. Fixed when the
/// row object is made, so an event that reaches the row after others
/// moved around it still names the same row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GridRowId {
    /// An editor result row, which nothing tracks.
    Result,
    /// A table row with no usable key, which can be read but not edited.
    Unkeyed,
    Persisted(RowKey),
    Draft(u64),
}

impl GridRowId {
    /// The key of a persisted row, which is what an UPDATE or DELETE
    /// names it by.
    pub fn key(&self) -> Option<&RowKey> {
        match self {
            Self::Persisted(key) => Some(key),
            Self::Result | Self::Unkeyed | Self::Draft(_) => None,
        }
    }

    pub fn draft_id(&self) -> Option<u64> {
        match self {
            Self::Draft(draft_id) => Some(*draft_id),
            Self::Result | Self::Unkeyed | Self::Persisted(_) => None,
        }
    }

    /// The key the tracker files this row's pending changes under.
    pub fn tracker_key(&self) -> Option<RowKey> {
        match self {
            Self::Persisted(key) => Some(key.clone()),
            Self::Draft(draft_id) => Some(RowKey::Draft(*draft_id)),
            Self::Result | Self::Unkeyed => None,
        }
    }

    /// Whether the tracker's `key` is this row, without building one.
    pub fn is_tracked_as(&self, key: &RowKey) -> bool {
        match (self, key) {
            (Self::Persisted(own), _) => own == key,
            (Self::Draft(own), RowKey::Draft(other)) => own == other,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;

    use super::GridRowId;
    use crate::services::change_tracker::RowKey;

    #[test]
    fn grid_row_id_key_is_none_for_result_and_draft_rows() {
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");

        assert_eq!(GridRowId::Result.key(), None);
        assert_eq!(GridRowId::Draft(3).key(), None);
        assert_eq!(GridRowId::Unkeyed.key(), None);
        assert_eq!(GridRowId::Persisted(key.clone()).key(), Some(&key));
        assert_eq!(GridRowId::Draft(3).tracker_key(), Some(RowKey::Draft(3)));
        assert_eq!(GridRowId::Result.tracker_key(), None);
    }

    #[test]
    fn a_draft_is_never_taken_for_a_persisted_row() {
        let key = RowKey::from_pk_values(&[Value::Int(3)]).expect("a key");

        assert!(GridRowId::Draft(3).is_tracked_as(&RowKey::Draft(3)));
        assert!(!GridRowId::Draft(3).is_tracked_as(&key));
        assert!(GridRowId::Persisted(key.clone()).is_tracked_as(&key));
        assert!(!GridRowId::Persisted(key).is_tracked_as(&RowKey::Draft(3)));
        assert!(!GridRowId::Unkeyed.is_tracked_as(&RowKey::Draft(3)));
    }
}
