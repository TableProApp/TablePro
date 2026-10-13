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
    use tablepro_core::sql_ddl::{DraftColumn, StructureOp};
    use uuid::Uuid;

    use super::*;

    fn add_column() -> StructureOp {
        StructureOp::AddColumn {
            schema: None,
            table: "t".into(),
            column: DraftColumn {
                original: None,
                name: "a".into(),
                data_type: "int".into(),
                nullable: true,
                primary_key: false,
                auto_increment: false,
                default_value: None,
                comment: None,
            },
        }
    }

    #[test]
    fn registries_isolated_per_workspace() {
        let first = StructureTrackerRegistry::default();
        let second = StructureTrackerRegistry::default();
        let tab = Uuid::new_v4();

        first.register(tab).set_ops(vec![add_column()]);
        second.register(tab);

        assert_eq!(first.dirty(), vec![tab]);
        assert!(second.dirty().is_empty());
    }

    #[test]
    fn dirty_lists_only_pending_tabs() {
        let registry = StructureTrackerRegistry::default();
        let edited = Uuid::new_v4();
        registry.register(edited).set_ops(vec![add_column()]);
        registry.register(Uuid::new_v4());

        assert_eq!(registry.dirty(), vec![edited]);

        registry.get(edited).expect("registered").clear();
        assert!(registry.dirty().is_empty());
    }
}
