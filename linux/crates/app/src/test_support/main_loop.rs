use std::cell::{Cell, RefCell};
use std::future::Future;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use gtk4::{gdk, glib};

use crate::test_support::WaitTimedOut;

pub(crate) fn drain_main_context() {
    let context = glib::MainContext::default();
    while context.iteration(false) {}
}

/// Wait for the window `widget` is in to paint a frame. GTK leaves some
/// work for after the paint: it moves a focus out of a removed widget
/// then, and holds that widget until it has.
pub(crate) fn after_next_frame(widget: &impl IsA<gtk4::Widget>) {
    let clock = widget.frame_clock().expect("the window's frame clock");
    let painted = Rc::new(Cell::new(false));
    let flag = painted.clone();
    let handler = clock.connect_after_paint(move |_| flag.set(true));
    clock.request_phase(gdk::FrameClockPhase::AFTER_PAINT);
    wait_until(Duration::from_secs(10), || painted.get()).expect("the window paints a frame");
    clock.disconnect(handler);
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
