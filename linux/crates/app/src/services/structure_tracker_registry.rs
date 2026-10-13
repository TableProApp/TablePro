use super::structure_tracker_handle::StructureTrackerHandle;
use super::tab_registry::{TabRegistry, TrackerHandle};

pub type StructureTrackerRegistry = TabRegistry<StructureTrackerHandle>;

impl TrackerHandle for StructureTrackerHandle {
    fn has_pending(&self) -> bool {
        StructureTrackerHandle::has_pending(self)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::{DraftColumn, DraftType, TableChanges, TableDraft};
    use tablepro_core::meta::TableRef;
    use uuid::Uuid;

    use super::*;
    use crate::services::pending_structure::PendingStructure;

    fn new_table() -> Option<PendingStructure> {
        let mut draft = TableDraft::new(TableRef::unqualified("t"));
        draft
            .columns
            .push(DraftColumn::new("a", DraftType::Typed("int".to_owned())));
        Some(PendingStructure {
            original: None,
            draft,
            changes: TableChanges::default(),
        })
    }

    #[test]
    fn registries_isolated_per_workspace() {
        let first = StructureTrackerRegistry::default();
        let second = StructureTrackerRegistry::default();
        let tab = Uuid::new_v4();

        first.register(tab).set_pending(new_table());
        second.register(tab);

        assert_eq!(first.dirty(), vec![tab]);
        assert!(second.dirty().is_empty());
    }

    #[test]
    fn dirty_lists_only_pending_tabs() {
        let registry = StructureTrackerRegistry::default();
        let edited = Uuid::new_v4();
        registry.register(edited).set_pending(new_table());
        registry.register(Uuid::new_v4());

        assert_eq!(registry.dirty(), vec![edited]);

        registry.get(edited).expect("registered").clear();
        assert!(registry.dirty().is_empty());
    }
}
