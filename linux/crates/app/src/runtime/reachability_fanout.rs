use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Weak};

use gtk4::glib;
use tablepro_session::health::ReachabilityTarget;
use tablepro_session::{MonitorSignal, Session, SessionKey, SessionRegistry};

use super::ReachabilityProbe;

/// Checks each attached session's server and tells the session what it
/// found. GTK thread only.
///
/// Checks overlap when the network changes several times in a row, and
/// can finish in any order, so each is stamped and only the newest
/// answer for a session reaches it.
pub struct ReachabilityFanout {
    sessions: Rc<SessionRegistry>,
    probe: Rc<dyn ReachabilityProbe>,
    stamps: RefCell<HashMap<SessionKey, u64>>,
    last_stamp: Cell<u64>,
}

impl ReachabilityFanout {
    pub fn new(sessions: Rc<SessionRegistry>, probe: Rc<dyn ReachabilityProbe>) -> Rc<Self> {
        Rc::new(Self {
            sessions,
            probe,
            stamps: RefCell::new(HashMap::new()),
            last_stamp: Cell::new(0),
        })
    }

    pub fn reevaluate_all(self: &Rc<Self>) {
        for (key, session) in self.sessions.attached_sessions() {
            self.check(key, &session);
        }
    }

    pub fn reevaluate(self: &Rc<Self>, key: &SessionKey) {
        if let Some(session) = self.sessions.session(key) {
            self.check(key.clone(), &session);
        }
    }

    /// The session went away, so an answer still on its way has nowhere
    /// to go.
    pub fn forget(&self, key: &SessionKey) {
        self.stamps.borrow_mut().remove(key);
    }

    /// A file, a socket or a loopback server needs no network, so it is
    /// never checked and never told it is unreachable.
    fn check(self: &Rc<Self>, key: SessionKey, session: &Arc<Session>) {
        let ReachabilityTarget::Remote(endpoint) = session.reachability() else {
            return;
        };
        let stamp = self.last_stamp.get().wrapping_add(1);
        self.last_stamp.set(stamp);
        self.stamps.borrow_mut().insert(key.clone(), stamp);
        let probing = self.probe.can_reach(&endpoint);
        let fanout = Rc::downgrade(self);
        let session: Weak<Session> = Arc::downgrade(session);
        glib::spawn_future_local(async move {
            let reachability = probing.await;
            let Some(fanout) = fanout.upgrade() else {
                return;
            };
            if !fanout.accept(&key, stamp) {
                return;
            }
            if let Some(session) = session.upgrade() {
                session.signal(MonitorSignal::Reachability(reachability));
            }
        });
    }

    fn accept(&self, key: &SessionKey, stamp: u64) -> bool {
        let mut stamps = self.stamps.borrow_mut();
        if stamps.get(key) != Some(&stamp) {
            return false;
        }
        stamps.remove(key);
        true
    }
}

impl std::fmt::Debug for ReachabilityFanout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReachabilityFanout")
            .field("checking", &self.stamps.borrow().len())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::NetworkEndpoint;
    use tablepro_session::SessionHealth;
    use tablepro_session::fakes::FakeEstablish;
    use tablepro_session::health::Reachability;
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::{Attached, FakeProbe, FakeSession, attach_remote, wait_until};

    const WAIT: Duration = Duration::from_secs(10);

    fn endpoint(host: &str) -> NetworkEndpoint {
        NetworkEndpoint::new(host, 5432).expect("an endpoint")
    }

    fn health(attached: &Attached) -> SessionHealth {
        attached.fake.session.health().borrow().clone()
    }

    #[gtk4::test]
    fn loopback_never_probed() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let probe = Rc::new(FakeProbe::default());
        let fanout = ReachabilityFanout::new(registry.clone(), probe.clone());
        let loopback = attach_remote(&registry, "127.0.0.1", Vec::new(), runtime.tasks());
        let _localhost = attach_remote(&registry, "localhost", Vec::new(), runtime.tasks());
        let _file = {
            let fake = FakeSession::start(ConnectionScript::default(), Vec::new(), runtime.tasks());
            let claim = registry
                .claim(SessionKey::File("file:///srv/app.db".to_owned()), 1)
                .expect("a claim");
            claim.attach(&fake.session);
            (fake, claim)
        };
        let remote = attach_remote(&registry, "db.example.com", Vec::new(), runtime.tasks());

        fanout.reevaluate_all();
        fanout.reevaluate(&loopback.key);
        crate::test_support::drain_main_context();

        assert_eq!(probe.asked(), [endpoint("db.example.com")]);
        drop(remote);
        runtime.shutdown();
    }

    #[gtk4::test]
    fn lan_host_reachable_without_default_route_stays_online() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let probe = FakeProbe::answering(Reachability::Reachable);
        let fanout = ReachabilityFanout::new(registry.clone(), probe.clone());
        let mut healthy = ConnectionScript::default();
        healthy.probe.always(FakeReply::ok(()));
        let lan = attach_remote(
            &registry,
            "192.168.1.20",
            vec![FakeEstablish::Connect(healthy)],
            runtime.tasks(),
        );

        fanout.reevaluate_all();
        crate::test_support::drain_main_context();
        lan.fake.connection.mark_lost();

        wait_until(WAIT, || lan.fake.connector.calls().len() == 1).expect("a reconnect");
        wait_until(WAIT, || health(&lan) == SessionHealth::Online).expect("the session back online");
        assert_eq!(probe.asked(), [endpoint("192.168.1.20")]);
        runtime.shutdown();
    }

    #[gtk4::test]
    fn stale_stamp_dropped() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let probe = Rc::new(FakeProbe::default());
        let fanout = ReachabilityFanout::new(registry.clone(), probe.clone());
        let refused = FakeEstablish::Fail(tablepro_session::ConnectError::Driver(
            tablepro_core::DriverError::Transport(tablepro_core::TransportError::Refused {
                endpoint: endpoint("db.example.com"),
            }),
        ));
        let remote = attach_remote(
            &registry,
            "db.example.com",
            vec![refused.clone(), refused],
            runtime.tasks(),
        );
        let first = probe.then_held();
        let second = probe.then_held();

        fanout.reevaluate_all();
        fanout.reevaluate(&remote.key);
        crate::test_support::drain_main_context();
        assert_eq!(probe.asked().len(), 2);
        let _ = second.send(Reachability::Reachable);
        crate::test_support::drain_main_context();
        let _ = first.send(Reachability::Unreachable);
        crate::test_support::drain_main_context();
        remote.fake.connection.mark_lost();

        wait_until(WAIT, || !remote.fake.connector.calls().is_empty())
            .expect("the session to reconnect, as its server is reachable");
        assert_ne!(
            health(&remote),
            SessionHealth::Offline,
            "the older answer overrode the newer one"
        );
        runtime.shutdown();
    }
}
