use std::cell::Cell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::glib;

/// How often the probe asks to run.
const TICK: Duration = Duration::from_millis(5);

/// The longest the main loop went without getting back to its sources:
/// a timeout due every `TICK`, above every other priority, that runs
/// late by as long as something else held the loop.
pub(crate) struct StallProbe {
    longest: Rc<Cell<Duration>>,
    last: Rc<Cell<Instant>>,
    source: Option<glib::SourceId>,
}

impl StallProbe {
    pub(crate) fn start() -> Self {
        let longest = Rc::new(Cell::new(Duration::ZERO));
        let last = Rc::new(Cell::new(Instant::now()));
        let (worst, previous) = (longest.clone(), last.clone());
        let source = glib::timeout_add_local_full(TICK, glib::Priority::HIGH, move || {
            let now = Instant::now();
            let gap = now.saturating_duration_since(previous.replace(now));
            worst.set(worst.get().max(gap));
            glib::ControlFlow::Continue
        });
        Self {
            longest,
            last,
            source: Some(source),
        }
    }

    /// The longest stall since the start or the last `take`, past the
    /// tick the probe waits for anyway.
    pub(crate) fn take(&self) -> Duration {
        let pending = self.last.get().elapsed();
        let worst = self.longest.replace(Duration::ZERO).max(pending);
        self.last.set(Instant::now());
        worst.saturating_sub(TICK)
    }
}

impl Drop for StallProbe {
    fn drop(&mut self) {
        if let Some(source) = self.source.take() {
            source.remove();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::wait_until;

    #[gtk4::test]
    fn a_blocked_main_loop_reads_as_a_stall() {
        let probe = StallProbe::start();
        wait_until(Duration::from_secs(5), {
            let started = Instant::now();
            move || started.elapsed() >= Duration::from_millis(50)
        })
        .expect("the main loop runs");
        let idle = probe.take();

        std::thread::sleep(Duration::from_millis(150));
        wait_until(Duration::from_secs(5), {
            let started = Instant::now();
            move || started.elapsed() >= Duration::from_millis(20)
        })
        .expect("the main loop runs");
        let blocked = probe.take();

        assert!(idle < Duration::from_millis(100), "an idle loop stalled for {idle:?}");
        assert!(
            blocked >= Duration::from_millis(140),
            "a 150 ms block read as {blocked:?}"
        );
    }
}
