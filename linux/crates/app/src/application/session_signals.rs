use std::rc::Rc;
use std::time::Duration;

use tablepro_session::registry::RegistrySubscription;
use tablepro_session::{MonitorSignal, SessionRegistry};

use crate::runtime::{
    ClockSource, GioReachability, NetworkWatch, ReachabilityFanout, ReachabilityProbe, ResumeDetector, SystemClocks,
};

/// What tells the open sessions about the world outside their
/// connections: whether the network reaches each server, and that the
/// computer woke from suspend. It lives from startup to shutdown.
#[derive(Debug)]
pub(super) struct SessionSignals {
    _network: NetworkWatch,
    _live_count: RegistrySubscription,
    _fanout: Rc<ReachabilityFanout>,
    _resume: Rc<ResumeDetector>,
}

impl SessionSignals {
    pub(super) fn start(sessions: &Rc<SessionRegistry>) -> Self {
        let monitor = gio::NetworkMonitor::default();
        Self::start_with(
            sessions,
            monitor.clone(),
            Rc::new(GioReachability::new(monitor)),
            Box::new(SystemClocks),
        )
    }

    fn start_with(
        sessions: &Rc<SessionRegistry>,
        monitor: gio::NetworkMonitor,
        probe: Rc<dyn ReachabilityProbe>,
        clocks: Box<dyn ClockSource>,
    ) -> Self {
        let fanout = ReachabilityFanout::new(sessions.clone(), probe);
        let network = NetworkWatch::start(monitor, fanout.clone(), sessions);
        let resume = ResumeDetector::new(clocks);
        // Held weakly: the registry keeps this closure among its
        // observers, and the fanout keeps the registry.
        let registry = Rc::downgrade(sessions);
        let rechecks = Rc::downgrade(&fanout);
        let on_resume: Rc<dyn Fn(Duration)> = Rc::new(move |slept| {
            if let Some(sessions) = registry.upgrade() {
                for (_, session) in sessions.attached_sessions() {
                    session.signal(MonitorSignal::Resumed { slept });
                }
            }
            if let Some(fanout) = rechecks.upgrade() {
                fanout.reevaluate_all();
            }
        });
        let live_count = resume.follow(sessions, on_resume);
        Self {
            _network: network,
            _live_count: live_count,
            _fanout: fanout,
            _resume: resume,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_test_support::CallCounters;

    use super::*;
    use crate::test_support::{FakeClocks, FakeProbe, attach_remote, wait_until};

    #[gtk4::test]
    fn a_resume_probes_every_session_and_rechecks_its_server() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let probe = Rc::new(FakeProbe::default());
        let clocks = FakeClocks::default();
        let signals = SessionSignals::start_with(
            &registry,
            gio::NetworkMonitor::default(),
            probe.clone(),
            Box::new(clocks.clone()),
        );
        let attached = attach_remote(&registry, "db.example.com", Vec::new(), runtime.tasks());
        crate::test_support::drain_main_context();
        let checked = probe.asked().len();
        let probes = || CallCounters::get(&attached.fake.connection.counters().probe);
        let probed = probes();

        clocks.advance(600, 0);

        wait_until(Duration::from_secs(10), || probes() > probed)
            .expect("the session to probe its connection after the sleep");
        wait_until(Duration::from_secs(1), || probe.asked().len() > checked)
            .expect("the server to be checked again after the sleep");
        drop(signals);
        runtime.shutdown();
    }
}
