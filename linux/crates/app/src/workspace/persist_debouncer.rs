use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::glib;

/// Runs one callback a while after the last request, on the GTK thread.
///
/// Trailing, not leading: every request cancels the pending one and
/// re-arms, so a run of keystrokes costs one callback at the end
/// rather than one each.
#[derive(Debug, Default)]
pub struct PersistDebouncer {
    delay: Duration,
    /// Shared with the callback, which clears it before running: a
    /// one-shot source removes itself when it fires, and removing it
    /// again panics.
    pending: Rc<RefCell<Option<glib::SourceId>>>,
}

impl PersistDebouncer {
    pub fn new(delay: Duration) -> Self {
        Self {
            delay,
            pending: Rc::new(RefCell::new(None)),
        }
    }

    pub fn request(&self, fire: impl FnOnce() + 'static) {
        self.cancel();
        let pending = self.pending.clone();
        let source = glib::timeout_add_local_once(self.delay, move || {
            pending.borrow_mut().take();
            fire();
        });
        *self.pending.borrow_mut() = Some(source);
    }

    pub fn cancel(&self) {
        if let Some(source) = self.pending.borrow_mut().take() {
            source.remove();
        }
    }

    #[cfg(test)]
    pub fn is_pending(&self) -> bool {
        self.pending.borrow().is_some()
    }
}

impl Drop for PersistDebouncer {
    fn drop(&mut self) {
        // The callback borrows whatever the owner handed it, so it must
        // not outlive the owner.
        self.cancel();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[gtk4::test]
    fn a_run_of_requests_fires_once_at_the_end() {
        let debouncer = PersistDebouncer::new(Duration::from_millis(20));
        let fires = Rc::new(Cell::new(0));

        for _ in 0..10 {
            let fires = fires.clone();
            debouncer.request(move || fires.set(fires.get() + 1));
        }
        crate::test_support::wait_until(Duration::from_secs(2), || fires.get() > 0).expect("the callback never ran");

        assert_eq!(fires.get(), 1, "a run of requests fired more than once");
    }

    #[gtk4::test]
    fn cancel_stops_a_pending_callback() {
        let debouncer = PersistDebouncer::new(Duration::from_millis(20));
        let fires = Rc::new(Cell::new(0));
        let fires_for_callback = fires.clone();
        debouncer.request(move || fires_for_callback.set(fires_for_callback.get() + 1));

        debouncer.cancel();
        assert!(!debouncer.is_pending());
        assert!(
            crate::test_support::wait_until(Duration::from_millis(200), || fires.get() > 0).is_err(),
            "a cancelled callback still ran"
        );
    }

    #[gtk4::test]
    fn dropping_the_debouncer_stops_a_pending_callback() {
        let fires = Rc::new(Cell::new(0));
        {
            let debouncer = PersistDebouncer::new(Duration::from_millis(20));
            let fires_for_callback = fires.clone();
            debouncer.request(move || fires_for_callback.set(fires_for_callback.get() + 1));
        }

        assert!(
            crate::test_support::wait_until(Duration::from_millis(200), || fires.get() > 0).is_err(),
            "a callback ran after its debouncer was dropped"
        );
    }
}
