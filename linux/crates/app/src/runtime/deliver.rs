use std::future::Future;

use tablepro_session::runtime::{TaskFailure, Tasks};

/// Run `work` on the app runtime and hand its result to `deliver` on the
/// GTK thread.
///
/// Drivers need a tokio context and widgets need the GTK thread, so a
/// view never awaits driver work itself: the work runs on `Tasks` and
/// only the answer crosses back. Aborting the returned handle drops the
/// delivery, never the work, so a save the user started still lands.
pub fn spawn_and_deliver<T, W, D>(tasks: &Tasks, work: W, deliver: D) -> glib::JoinHandle<()>
where
    T: Send + 'static,
    W: Future<Output = T> + Send + 'static,
    D: FnOnce(Result<T, TaskFailure>) + 'static,
{
    let running = tasks.spawn_task(work);
    glib::spawn_future_local(async move {
        deliver(running.await);
    })
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;

    #[gtk4::test]
    fn the_result_arrives_on_the_main_thread() {
        let runtime = crate::test_support::test_runtime();
        let main_thread = std::thread::current().id();
        let seen = Rc::new(RefCell::new(None));
        let sink = seen.clone();

        let _delivery = spawn_and_deliver(
            &runtime.tasks(),
            async { std::thread::current().id() },
            move |worker| {
                *sink.borrow_mut() = Some((worker.ok(), std::thread::current().id()));
            },
        );
        crate::test_support::wait_until(std::time::Duration::from_secs(5), || seen.borrow().is_some())
            .expect("the delivery");

        let (worker, delivered_on) = seen.borrow_mut().take().expect("a result");
        assert_ne!(worker, Some(main_thread), "the work ran on the GTK thread");
        assert_eq!(delivered_on, main_thread);
    }
}
