use super::tab_registry::TabRegistry;
use super::tab_tracker_handle::TabTrackerHandle;

pub type ChangeTrackerRegistry = TabRegistry<TabTrackerHandle>;

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

        assert_eq!(first.get(tab).map(|tracker| tracker.pending_count()), Some(1));
        assert_eq!(other.pending_count(), 0);
    }

    #[test]
    fn a_discard_empties_the_tabs_tracker() {
        let registry = ChangeTrackerRegistry::default();
        let edited = Uuid::new_v4();
        edit(&registry.register(edited));
        registry.register(Uuid::new_v4());

        let _ = registry.get(edited).expect("registered").discard();

        assert_eq!(registry.register(edited).pending_count(), 0);
    }

    #[test]
    fn register_returns_the_same_tracker_until_unregistered() {
        let registry = ChangeTrackerRegistry::default();
        let tab = Uuid::new_v4();
        edit(&registry.register(tab));

        assert_eq!(registry.register(tab).pending_count(), 1);

        registry.unregister(tab);
        assert!(registry.get(tab).is_none());
        assert_eq!(registry.register(tab).pending_count(), 0);
    }
}
