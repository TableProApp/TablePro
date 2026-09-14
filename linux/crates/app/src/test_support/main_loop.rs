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
