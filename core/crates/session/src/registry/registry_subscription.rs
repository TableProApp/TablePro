use std::rc::Weak;

use super::SessionRegistry;

/// Keeps an observer registered; dropping it unregisters.
#[derive(Debug)]
#[must_use = "dropping the subscription unregisters the observer"]
pub struct RegistrySubscription {
    pub(super) registry: Weak<SessionRegistry>,
    pub(super) id: u64,
}

impl Drop for RegistrySubscription {
    fn drop(&mut self) {
        if let Some(registry) = self.registry.upgrade() {
            registry.unsubscribe(self.id);
        }
    }
}
