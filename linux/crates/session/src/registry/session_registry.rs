use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Weak};

use super::{ClaimError, RegistryEvent, RegistrySubscription, SessionClaim, SessionKey};
use crate::session::Session;

struct RegistryEntry {
    window_id: u32,
    session: Option<Weak<Session>>,
}

type Observer = Rc<dyn Fn(&RegistryEvent)>;

/// The sessions open in this process, keyed so one database opens in
/// one window.
///
/// It lives on the GTK thread. The live count moves only on attach and
/// on a claim being dropped, both on that thread, so it never depends
/// on when a worker drops its last `Arc<Session>`.
#[derive(Default)]
pub struct SessionRegistry {
    entries: RefCell<HashMap<SessionKey, RegistryEntry>>,
    live: Cell<usize>,
    observers: RefCell<Vec<(u64, Observer)>>,
    next_observer: Cell<u64>,
}

impl SessionRegistry {
    pub fn new() -> Rc<Self> {
        Rc::new(Self::default())
    }

    pub fn claim(self: &Rc<Self>, key: SessionKey, window_id: u32) -> Result<SessionClaim, ClaimError> {
        let mut entries = self.entries.borrow_mut();
        if let Some(entry) = entries.get(&key) {
            return Err(ClaimError::AlreadyOpen {
                window_id: entry.window_id,
            });
        }
        entries.insert(
            key.clone(),
            RegistryEntry {
                window_id,
                session: None,
            },
        );
        Ok(SessionClaim {
            registry: Rc::downgrade(self),
            key,
        })
    }

    pub fn window_for(&self, key: &SessionKey) -> Option<u32> {
        self.entries.borrow().get(key).map(|entry| entry.window_id)
    }

    pub fn session(&self, key: &SessionKey) -> Option<Arc<Session>> {
        self.entries.borrow().get(key)?.session.as_ref()?.upgrade()
    }

    pub fn attached_sessions(&self) -> Vec<(SessionKey, Arc<Session>)> {
        self.entries
            .borrow()
            .iter()
            .filter_map(|(key, entry)| {
                let session = entry.session.as_ref()?.upgrade()?;
                Some((key.clone(), session))
            })
            .collect()
    }

    pub fn live_count(&self) -> usize {
        self.live.get()
    }

    pub fn subscribe(self: &Rc<Self>, observer: impl Fn(&RegistryEvent) + 'static) -> RegistrySubscription {
        let id = self.next_observer.get();
        self.next_observer.set(id.wrapping_add(1));
        self.observers.borrow_mut().push((id, Rc::new(observer)));
        RegistrySubscription {
            registry: Rc::downgrade(self),
            id,
        }
    }

    pub(super) fn unsubscribe(&self, id: u64) {
        self.observers.borrow_mut().retain(|(observer, _)| *observer != id);
    }

    pub(super) fn attach(&self, key: &SessionKey, session: &Arc<Session>) {
        let first_attach = {
            let mut entries = self.entries.borrow_mut();
            let Some(entry) = entries.get_mut(key) else {
                return;
            };
            let first = entry.session.is_none();
            entry.session = Some(Arc::downgrade(session));
            first
        };
        let mut events = vec![RegistryEvent::Attached {
            key: key.clone(),
            reachability: session.reachability(),
        }];
        if first_attach {
            self.live.set(self.live.get() + 1);
            events.push(RegistryEvent::LiveCountChanged(self.live.get()));
        }
        self.emit(&events);
    }

    pub(super) fn release(&self, key: &SessionKey) {
        let Some(entry) = self.entries.borrow_mut().remove(key) else {
            return;
        };
        if entry.session.is_none() {
            return;
        }
        self.live.set(self.live.get().saturating_sub(1));
        self.emit(&[
            RegistryEvent::Released { key: key.clone() },
            RegistryEvent::LiveCountChanged(self.live.get()),
        ]);
    }

    /// Observers are copied out first, so one that claims or releases
    /// from inside its callback never meets a borrowed registry.
    fn emit(&self, events: &[RegistryEvent]) {
        let observers: Vec<Observer> = self
            .observers
            .borrow()
            .iter()
            .map(|(_, observer)| observer.clone())
            .collect();
        for event in events {
            for observer in &observers {
                observer(event);
            }
        }
    }
}

impl std::fmt::Debug for SessionRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionRegistry")
            .field("claimed", &self.entries.borrow().len())
            .field("live", &self.live.get())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::LivenessPolicy;
    use tablepro_test_support::ConnectionScript;
    use uuid::Uuid;

    use super::*;
    use crate::fakes::{FakeConnector, FakeCredentialSource};
    use crate::health::ReachabilityTarget;
    use crate::operation::DefaultDeadlines;
    use crate::session::SessionDeps;
    use crate::test_support::paused_tasks;

    fn session() -> Arc<Session> {
        let (pending, _) =
            FakeConnector::pending_session(FakeConnector::request().unwrap(), ConnectionScript::default());
        Session::start(
            pending,
            SessionDeps {
                connector: Arc::new(FakeConnector::new([])),
                credentials: Arc::new(FakeCredentialSource::new()),
                deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
                tasks: paused_tasks(),
                prompter: None,
            },
        )
    }

    fn recorded(registry: &Rc<SessionRegistry>) -> (Rc<RefCell<Vec<RegistryEvent>>>, RegistrySubscription) {
        let events = Rc::new(RefCell::new(Vec::new()));
        let sink = events.clone();
        let subscription = registry.subscribe(move |event| sink.borrow_mut().push(event.clone()));
        (events, subscription)
    }

    #[test]
    fn claim_refuses_duplicate() {
        let registry = SessionRegistry::new();
        let key = SessionKey::Saved(Uuid::new_v4());

        let _first = registry.claim(key.clone(), 7).unwrap();
        let second = registry.claim(key.clone(), 9);

        assert_eq!(second.unwrap_err(), ClaimError::AlreadyOpen { window_id: 7 });
        assert_eq!(registry.window_for(&key), Some(7));
    }

    #[test]
    fn claim_drop_releases_key() {
        let registry = SessionRegistry::new();
        let key = SessionKey::File("file:///srv/app.db".to_owned());

        drop(registry.claim(key.clone(), 7).unwrap());

        assert_eq!(registry.window_for(&key), None);
        assert!(registry.claim(key, 9).is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn live_count_event_on_attach_and_drop() {
        let registry = SessionRegistry::new();
        let (events, _subscription) = recorded(&registry);
        let key = SessionKey::Saved(Uuid::new_v4());
        let claim = registry.claim(key.clone(), 7).unwrap();
        let session = session();

        claim.attach(&session);
        assert_eq!(registry.live_count(), 1);
        assert_eq!(registry.attached_sessions().len(), 1);
        assert!(
            registry
                .session(&key)
                .is_some_and(|found| Arc::ptr_eq(&found, &session))
        );
        drop(claim);

        assert_eq!(registry.live_count(), 0);
        assert!(registry.session(&key).is_none());
        assert_eq!(
            *events.borrow(),
            [
                RegistryEvent::Attached {
                    key: key.clone(),
                    reachability: ReachabilityTarget::Local
                },
                RegistryEvent::LiveCountChanged(1),
                RegistryEvent::Released { key },
                RegistryEvent::LiveCountChanged(0),
            ]
        );
    }

    #[test]
    fn a_claim_that_never_attached_releases_quietly() {
        let registry = SessionRegistry::new();
        let (events, _subscription) = recorded(&registry);

        drop(registry.claim(SessionKey::Saved(Uuid::new_v4()), 7).unwrap());

        assert!(events.borrow().is_empty());
        assert_eq!(registry.live_count(), 0);
    }

    #[test]
    fn a_dropped_subscription_stops_receiving() {
        let registry = SessionRegistry::new();
        let (events, subscription) = recorded(&registry);
        drop(subscription);

        let claim = registry.claim(SessionKey::Saved(Uuid::new_v4()), 7).unwrap();
        drop(claim);

        assert!(events.borrow().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn an_observer_may_claim_from_inside_its_callback() {
        let registry = SessionRegistry::new();
        let reentrant = registry.clone();
        let claimed = Rc::new(RefCell::new(Vec::new()));
        let sink = claimed.clone();
        let _subscription = registry.subscribe(move |event| {
            if let RegistryEvent::Released { .. } = event {
                sink.borrow_mut()
                    .push(reentrant.claim(SessionKey::Saved(Uuid::new_v4()), 3));
            }
        });
        let claim = registry.claim(SessionKey::Saved(Uuid::new_v4()), 7).unwrap();
        claim.attach(&session());

        drop(claim);

        assert_eq!(claimed.borrow().len(), 1);
        assert!(claimed.borrow()[0].is_ok());
    }
}
