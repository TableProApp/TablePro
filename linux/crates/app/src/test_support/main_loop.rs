use std::cell::RefCell;
use std::future::Future;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::glib;

use crate::test_support::WaitTimedOut;

pub(crate) fn drain_main_context() {
    let context = glib::MainContext::default();
    while context.iteration(false) {}
}

pub(crate) fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) -> Result<(), WaitTimedOut> {
    let context = glib::MainContext::default();
    let wake = glib::timeout_add_local(Duration::from_millis(10), || glib::ControlFlow::Continue);
    let deadline = Instant::now() + timeout;
    let outcome = loop {
        if condition() {
            break Ok(());
        }
        if Instant::now() >= deadline {
            break Err(WaitTimedOut { timeout });
        }
        context.iteration(true);
    };
    wake.remove();
    outcome
}

/// Run `future` on the main context until it ends, or give it up once
/// `timeout` passes.
pub(crate) fn finish_on_main<T: 'static>(
    timeout: Duration,
    future: impl Future<Output = T> + 'static,
) -> Result<T, WaitTimedOut> {
    let outcome = Rc::new(RefCell::new(None));
    let slot = outcome.clone();
    let running = glib::spawn_future_local(async move {
        slot.replace(Some(future.await));
    });
    if let Err(timed_out) = wait_until(timeout, || outcome.borrow().is_some()) {
        running.abort();
        return Err(timed_out);
    }
    outcome.take().ok_or(WaitTimedOut { timeout })
}
