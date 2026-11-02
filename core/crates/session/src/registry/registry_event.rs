use super::SessionKey;
use crate::health::ReachabilityTarget;

/// What changed in the registry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryEvent {
    /// A session was adopted. Carries what the network must reach for
    /// it, so the network watch can check it straight away.
    Attached {
        key: SessionKey,
        reachability: ReachabilityTarget,
    },
    Released {
        key: SessionKey,
    },
    /// How many sessions are attached. The resume detector runs only
    /// while this is above zero.
    LiveCountChanged(usize),
}
