use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use gtk4::glib;
use tablepro_session::registry::RegistrySubscription;
use tablepro_session::{RegistryEvent, SessionRegistry};

use super::{ClockSample, ClockSource, RESUME_THRESHOLD, detect_resume};

/// How often the clocks are compared. A whole-second GLib timer is
/// batched with the system's other wakeups, and the check reads two
/// clocks and nothing else.
const TICK_SECONDS: u32 = 5;

/// Notices that the machine slept, by the gap that opens between boot
/// time and monotonic time. GTK thread only.
///
/// logind's PrepareForSleep needs the system bus, which a Flatpak
/// sandbox reaches only with a permission the app does not ask for. The
/// clocks need nothing.
pub struct ResumeDetector {
    clocks: Box<dyn ClockSource>,
    last: Cell<ClockSample>,
    source: RefCell<Option<glib::SourceId>>,
}

impl ResumeDetector {
    pub fn new(clocks: Box<dyn ClockSource>) -> Rc<Self> {
        let last = clocks.sample();
        Rc::new(Self {
            clocks,
            last: Cell::new(last),
            source: RefCell::new(None),
        })
    }

    /// How long the machine slept since the last tick, if it did.
    pub fn tick(&self) -> Option<Duration> {
        let now = self.clocks.sample();
        let prev = self.last.replace(now);
        detect_resume(prev, now, RESUME_THRESHOLD)
    }

    pub fn is_running(&self) -> bool {
        self.source.borrow().is_some()
    }

    /// Check every few seconds until `stop`. A sleep while stopped is not
    /// reported: nothing was open to be told.
    pub fn start(self: &Rc<Self>, on_resume: Rc<dyn Fn(Duration)>) {
        if self.is_running() {
            return;
        }
        self.last.set(self.clocks.sample());
        let detector = Rc::downgrade(self);
        let source = glib::timeout_add_seconds_local(TICK_SECONDS, move || {
            // Never Break: stop() removes the source, and removing one
            // that already ended is a GLib critical.
            if let Some(slept) = detector.upgrade().and_then(|detector| detector.tick()) {
                tracing::info!(slept_secs = slept.as_secs(), "the computer woke from suspend");
                on_resume(slept);
            }
            glib::ControlFlow::Continue
        });
        self.source.replace(Some(source));
    }

    pub fn stop(&self) {
        if let Some(source) = self.source.take() {
            source.remove();
        }
    }

    /// Run while at least one session is open, calling `on_resume` after
    /// each sleep. Dropping the subscription stops following, not the
    /// detector.
    pub fn follow(
        self: &Rc<Self>,
        sessions: &Rc<SessionRegistry>,
        on_resume: Rc<dyn Fn(Duration)>,
    ) -> RegistrySubscription {
        if sessions.live_count() > 0 {
            self.start(on_resume.clone());
        }
        let detector = Rc::downgrade(self);
        sessions.subscribe(move |event| {
            let RegistryEvent::LiveCountChanged(live) = event else {
                return;
            };
            let Some(detector) = detector.upgrade() else {
                return;
            };
            match live {
                0 => detector.stop(),
                _ => detector.start(on_resume.clone()),
            }
        })
    }
}

impl Drop for ResumeDetector {
    fn drop(&mut self) {
        self.stop();
    }
}

impl std::fmt::Debug for ResumeDetector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ResumeDetector")
            .field("last", &self.last.get())
            .field("running", &self.is_running())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use tablepro_session::SessionKey;
    use tablepro_test_support::ConnectionScript;

    use super::*;
    use crate::test_support::{FakeClocks, FakeSession};

    fn detector() -> (Rc<ResumeDetector>, FakeClocks) {
        let clocks = FakeClocks::default();
        clocks.advance(1_000, 1_000);
        (ResumeDetector::new(Box::new(clocks.clone())), clocks)
    }

    fn ignore_resume() -> Rc<dyn Fn(Duration)> {
        Rc::new(|_| {})
    }

    #[test]
    fn tick_reports_fake_clock_jump() {
        let (detector, clocks) = detector();

        clocks.advance(60, 5);

        assert_eq!(detector.tick(), Some(Duration::from_secs(55)));
        assert_eq!(detector.tick(), None, "the same sleep was reported twice");
    }

    #[test]
    fn tick_without_jump_reports_none() {
        let (detector, clocks) = detector();

        clocks.advance(5, 5);

        assert_eq!(detector.tick(), None);
    }

    #[gtk4::test]
    fn start_then_stop_removes_source_without_critical() {
        let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
        let (detector, _clocks) = detector();

        detector.start(ignore_resume());
        assert!(detector.is_running());
        detector.stop();
        detector.stop();
        detector.start(ignore_resume());
        drop(detector);
        crate::test_support::drain_main_context();

        glib::log_set_always_fatal(previous);
    }

    #[gtk4::test]
    fn a_sleep_while_stopped_is_not_reported() {
        let (detector, clocks) = detector();
        detector.start(ignore_resume());
        detector.stop();

        clocks.advance(3_600, 0);
        detector.start(ignore_resume());

        assert_eq!(detector.tick(), None);
    }

    #[gtk4::test]
    fn stops_when_live_count_reaches_zero() {
        let runtime = crate::test_support::test_runtime();
        let registry = SessionRegistry::new();
        let (detector, _clocks) = detector();
        let _following = detector.follow(&registry, ignore_resume());
        assert!(!detector.is_running(), "running with no session open");

        let first = FakeSession::start(ConnectionScript::default(), Vec::new(), runtime.tasks());
        let second = FakeSession::start(ConnectionScript::default(), Vec::new(), runtime.tasks());
        let first_claim = registry.claim(SessionKey::File("file:///a.db".to_owned()), 1).unwrap();
        first_claim.attach(&first.session);
        assert!(detector.is_running(), "not running with a session open");
        let second_claim = registry.claim(SessionKey::File("file:///b.db".to_owned()), 2).unwrap();
        second_claim.attach(&second.session);

        drop(first_claim);
        assert!(detector.is_running(), "stopped with a session still open");
        drop(second_claim);
        assert!(!detector.is_running(), "still running with every session closed");
        runtime.shutdown();
    }
}
