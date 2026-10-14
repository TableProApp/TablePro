use super::structure_tracker_handle::StructureTrackerHandle;
use super::tab_registry::TabRegistry;

pub type StructureTrackerRegistry = TabRegistry<StructureTrackerHandle>;

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
            unparsed_defaults: Vec::new(),
        })
    }

    #[test]
    fn registries_isolated_per_workspace() {
        let first = StructureTrackerRegistry::default();
        let second = StructureTrackerRegistry::default();
        let tab = Uuid::new_v4();

        first.register(tab).set_pending(new_table());
        second.register(tab);

        assert!(first.get(tab).is_some_and(|tracker| tracker.has_pending()));
        assert!(second.get(tab).is_some_and(|tracker| !tracker.has_pending()));
    }

    #[test]
    fn register_returns_the_tabs_own_tracker() {
        let registry = StructureTrackerRegistry::default();
        let edited = Uuid::new_v4();
        registry.register(edited).set_pending(new_table());
        registry.register(Uuid::new_v4());

        assert!(registry.register(edited).has_pending());

        registry.get(edited).expect("registered").clear();
        assert!(!registry.register(edited).has_pending());
    }
}
