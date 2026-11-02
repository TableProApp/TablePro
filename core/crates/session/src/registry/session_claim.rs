use std::rc::Weak;
use std::sync::Arc;

use super::{SessionKey, SessionRegistry};
use crate::session::Session;

/// A window's hold on a session key, taken before connecting.
///
/// Claiming first means a second window asking for the same database is
/// sent to the first instead of building a connection it would throw
/// away. Dropping the claim releases the key at once, before the old
/// connection has finished closing, so it can be picked again.
#[derive(Debug)]
#[must_use = "dropping the claim releases the key"]
pub struct SessionClaim {
    pub(super) registry: Weak<SessionRegistry>,
    pub(super) key: SessionKey,
}

impl SessionClaim {
    pub fn key(&self) -> &SessionKey {
        &self.key
    }

    /// Record the adopted session under this claim.
    pub fn attach(&self, session: &Arc<Session>) {
        if let Some(registry) = self.registry.upgrade() {
            registry.attach(&self.key, session);
        }
    }
}

impl Drop for SessionClaim {
    fn drop(&mut self) {
        if let Some(registry) = self.registry.upgrade() {
            registry.release(&self.key);
        }
    }
}
