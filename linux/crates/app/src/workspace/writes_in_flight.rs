use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use tablepro_session::SessionKey;
use tokio::sync::oneshot;

/// Writes for a session that run outside the workspace store, such as
/// the editor drafts of a workspace being closed, counted per session.
#[derive(Default)]
pub(super) struct OutsideWrites {
    sessions: RefCell<HashMap<SessionKey, Landing>>,
}

#[derive(Default)]
struct Landing {
    writes: usize,
    waiters: Vec<oneshot::Sender<()>>,
}

impl OutsideWrites {
    pub(super) fn begin(self: &Rc<Self>, key: &SessionKey) -> WritesInFlight {
        self.sessions.borrow_mut().entry(key.clone()).or_default().writes += 1;
        WritesInFlight {
            outside: Rc::downgrade(self),
            key: key.clone(),
        }
    }

    /// The sessions with writes still in flight that `keep` picks.
    pub(super) fn keys_in_flight(&self, keep: impl Fn(&SessionKey) -> bool) -> Vec<SessionKey> {
        self.sessions
            .borrow()
            .iter()
            .filter(|(key, landing)| landing.writes > 0 && keep(key))
            .map(|(key, _)| key.clone())
            .collect()
    }

    /// Resolves once every write for `key` has landed, or `None` when
    /// none is in flight.
    pub(super) fn landing(&self, key: &SessionKey) -> Option<oneshot::Receiver<()>> {
        let mut sessions = self.sessions.borrow_mut();
        let landing = sessions.get_mut(key)?;
        let (landed, receiver) = oneshot::channel();
        landing.waiters.push(landed);
        Some(receiver)
    }

    fn end(&self, key: &SessionKey) {
        let waiters = {
            let mut sessions = self.sessions.borrow_mut();
            let Some(landing) = sessions.get_mut(key) else {
                return;
            };
            landing.writes = landing.writes.saturating_sub(1);
            if landing.writes > 0 {
                return;
            }
            sessions.remove(key).map(|landing| landing.waiters).unwrap_or_default()
        };
        for waiter in waiters {
            let _ = waiter.send(());
        }
    }
}

/// Counts writes for one session as still landing until it drops.
#[must_use = "the writes count as landed once this drops"]
pub struct WritesInFlight {
    outside: Weak<OutsideWrites>,
    key: SessionKey,
}

impl Drop for WritesInFlight {
    fn drop(&mut self) {
        if let Some(outside) = self.outside.upgrade() {
            outside.end(&self.key);
        }
    }
}

impl std::fmt::Debug for WritesInFlight {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WritesInFlight").field("key", &self.key).finish()
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    fn key() -> SessionKey {
        SessionKey::Saved(Uuid::new_v4())
    }

    #[test]
    fn nothing_in_flight_has_nothing_to_wait_for() {
        let outside = Rc::new(OutsideWrites::default());

        assert!(outside.landing(&key()).is_none());
    }

    #[tokio::test]
    async fn the_wait_ends_when_the_last_write_lands() {
        let outside = Rc::new(OutsideWrites::default());
        let (key, other) = (key(), key());
        let first = outside.begin(&key);
        let second = outside.begin(&key);
        let _unrelated = outside.begin(&other);
        let mut landing = outside.landing(&key).expect("writes in flight");

        drop(first);
        assert!(landing.try_recv().is_err(), "the wait ended with a write still landing");
        drop(second);

        assert!(landing.await.is_ok());
        assert!(outside.landing(&key).is_none());
        assert!(
            outside.landing(&other).is_some(),
            "another session's writes were counted as landed"
        );
    }
}
