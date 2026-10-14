use std::rc::Rc;

use gio::prelude::*;
use gtk4::glib;
use tablepro_session::registry::RegistrySubscription;
use tablepro_session::{RegistryEvent, SessionRegistry};

use super::ReachabilityFanout;

/// Rechecks every session's server when the network changes, and a new
/// session's as soon as it is adopted.
///
/// `network-changed` carries a global "network available" flag that only
/// says whether there is a default route. It is not used: each session
/// asks about its own server instead.
#[derive(Debug)]
pub struct NetworkWatch {
    monitor: gio::NetworkMonitor,
    handlers: Vec<glib::SignalHandlerId>,
    _registry: RegistrySubscription,
}

impl NetworkWatch {
    pub fn start(monitor: gio::NetworkMonitor, fanout: Rc<ReachabilityFanout>, sessions: &Rc<SessionRegistry>) -> Self {
        let changed = {
            let fanout = fanout.clone();
            monitor.connect_network_changed(move |_, _| fanout.reevaluate_all())
        };
        let connectivity = {
            let fanout = fanout.clone();
            monitor.connect_connectivity_notify(move |_| fanout.reevaluate_all())
        };
        // The registry holds its observers, so this one holds the fanout
        // weakly: the fanout holds the registry.
        let fanout = Rc::downgrade(&fanout);
        let registry = sessions.subscribe(move |event| {
            let Some(fanout) = fanout.upgrade() else {
                return;
            };
            match event {
                RegistryEvent::Attached { key, .. } => fanout.reevaluate(key),
                RegistryEvent::Released { key } => fanout.forget(key),
                RegistryEvent::LiveCountChanged(_) => {}
            }
        });
        Self {
            monitor,
            handlers: vec![changed, connectivity],
            _registry: registry,
        }
    }
}

impl Drop for NetworkWatch {
    fn drop(&mut self) {
        for handler in self.handlers.drain(..) {
            self.monitor.disconnect(handler);
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::NetworkEndpoint;

    use super::*;
    use crate::test_support::{FakeProbe, attach_remote};

    fn emit_network_changed(monitor: &gio::NetworkMonitor) {
        monitor.emit_by_name::<()>("network-changed", &[&true]);
        crate::test_support::drain_main_context();
    }

    #[gtk4::test]
    fn attach_triggers_reevaluate() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let probe = std::rc::Rc::new(FakeProbe::default());
        let fanout = ReachabilityFanout::new(registry.clone(), probe.clone());
        let watch = NetworkWatch::start(gio::NetworkMonitor::default(), fanout, &registry);
        let endpoint = NetworkEndpoint::new("db.example.com", 5432).unwrap();

        let attached = attach_remote(&registry, "db.example.com", Vec::new(), runtime.tasks());
        crate::test_support::drain_main_context();

        assert!(
            probe.asked().contains(&endpoint),
            "the new session's server was not checked"
        );
        drop(attached);
        drop(watch);
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_network_change_rechecks_until_the_watch_is_dropped() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let probe = std::rc::Rc::new(FakeProbe::default());
        let fanout = ReachabilityFanout::new(registry.clone(), probe.clone());
        let monitor = gio::NetworkMonitor::default();
        let watch = NetworkWatch::start(monitor.clone(), fanout, &registry);
        let _attached = attach_remote(&registry, "db.example.com", Vec::new(), runtime.tasks());
        crate::test_support::drain_main_context();

        let before = probe.asked().len();
        emit_network_changed(&monitor);
        assert!(probe.asked().len() > before, "a network change rechecked nothing");

        drop(watch);
        let after_drop = probe.asked().len();
        emit_network_changed(&monitor);
        assert_eq!(probe.asked().len(), after_drop, "a dropped watch still rechecked");
        runtime.shutdown();
    }
}
