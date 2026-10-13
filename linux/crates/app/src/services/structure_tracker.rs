//! What a Structure tab would save, kept so the close prompt and the
//! save dispatcher can read it without reaching into the tab. The tab
//! replaces it on every edit; DDL has no per-change undo, only Discard
//! back to the table as it was read.

use super::pending_structure::PendingStructure;

#[derive(Debug, Default)]
pub struct StructureChangeTracker {
    pending: Option<PendingStructure>,
}

impl StructureChangeTracker {
    pub fn has_pending(&self) -> bool {
        self.pending.as_ref().is_some_and(PendingStructure::has_changes)
    }

    pub fn set_pending(&mut self, pending: Option<PendingStructure>) {
        self.pending = pending;
    }

    /// What Save writes, or `None` when there is nothing to.
    pub fn begin_save(&self) -> Option<PendingStructure> {
        self.pending.clone().filter(PendingStructure::has_changes)
    }

    pub fn clear(&mut self) {
        self.pending = None;
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::{DraftColumn, DraftType, TableChanges, TableDraft};
    use tablepro_core::meta::TableRef;

    use super::*;

    fn new_table(columns: usize) -> PendingStructure {
        let mut draft = TableDraft::new(TableRef::unqualified("t"));
        for index in 0..columns {
            draft.columns.push(DraftColumn::new(
                format!("c{index}"),
                DraftType::Typed("int".to_owned()),
            ));
        }
        PendingStructure {
            original: None,
            draft,
            changes: TableChanges::default(),
            unparsed_defaults: Vec::new(),
        }
    }

    #[test]
    fn empty_tracker_has_no_pending() {
        let tracker = StructureChangeTracker::default();

        assert!(!tracker.has_pending());
        assert_eq!(tracker.begin_save(), None);
    }

    #[test]
    fn only_a_structure_with_changes_is_saved() {
        let mut tracker = StructureChangeTracker::default();
        tracker.set_pending(Some(new_table(0)));
        assert!(!tracker.has_pending());
        assert_eq!(tracker.begin_save(), None);

        tracker.set_pending(Some(new_table(1)));
        assert!(tracker.has_pending());
        assert_eq!(tracker.begin_save(), Some(new_table(1)));

        tracker.clear();
        assert!(!tracker.has_pending());
    }
}
