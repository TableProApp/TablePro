use super::tab_registry::{TabRegistry, TrackerHandle};
use super::tab_tracker_handle::TabTrackerHandle;

pub type ChangeTrackerRegistry = TabRegistry<TabTrackerHandle>;

impl TrackerHandle for TabTrackerHandle {
    fn has_pending(&self) -> bool {
        self.pending_count() > 0
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use uuid::Uuid;

    use super::*;
    use crate::services::change_tracker::RowKey;
    use crate::services::tracker_edit::TrackerEdit;

    fn edit(tracker: &TabTrackerHandle) {
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
            col: 1,
            original: Value::Int(1),
            value: Value::Int(2),
        });
    }

    #[test]
    fn registries_isolated_per_workspace() {
        let first = ChangeTrackerRegistry::default();
        let second = ChangeTrackerRegistry::default();
        let tab = Uuid::new_v4();

        edit(&first.register(tab));
        let other = second.register(tab);

        assert_eq!(first.dirty(), vec![tab]);
        assert!(second.dirty().is_empty());
        assert_eq!(other.pending_count(), 0);
    }

    #[test]
    fn dirty_lists_only_pending_tabs() {
        let registry = ChangeTrackerRegistry::default();
        let edited = Uuid::new_v4();
        let clean = Uuid::new_v4();
        edit(&registry.register(edited));
        registry.register(clean);

        assert_eq!(registry.dirty(), vec![edited]);

        let _ = registry.get(edited).expect("registered").discard();
        assert!(registry.dirty().is_empty());
    }

    #[test]
    fn register_returns_the_same_tracker_until_unregistered() {
        let registry = ChangeTrackerRegistry::default();
        let tab = Uuid::new_v4();
        edit(&registry.register(tab));

        assert_eq!(registry.register(tab).pending_count(), 1);

        registry.unregister(tab);
        assert!(registry.get(tab).is_none());
        assert!(registry.dirty().is_empty());
        assert_eq!(registry.register(tab).pending_count(), 0);
    }
}
