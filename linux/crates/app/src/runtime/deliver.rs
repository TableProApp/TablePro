use std::future::Future;

use tablepro_session::runtime::{ProcessHold, TaskFailure, Tasks};

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

/// Run `work` on the app runtime with the process held until it ends,
/// so a quit right after a write started waits for it instead of
/// cutting it off.
pub fn spawn_held<W>(tasks: &Tasks, hold: &dyn ProcessHold, work: W)
where
    W: Future<Output = ()> + Send + 'static,
{
    let token = hold.acquire();
    let running = tasks.spawn_task(work);
    glib::spawn_future_local(async move {
        if let Err(failure) = running.await {
            tracing::warn!(%failure, "a held background task failed");
        }
        drop(token);
    });
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use tablepro_session::runtime::CountingHold;

    use super::*;

    #[gtk4::test]
    fn held_work_keeps_the_process_until_it_ends() {
        let runtime = crate::test_support::test_runtime();
        let hold = CountingHold::new();
        let (finish, finished) = tokio::sync::oneshot::channel::<()>();

        spawn_held(&runtime.tasks(), &hold, async move {
            let _ = finished.await;
        });
        crate::test_support::drain_main_context();
        assert_eq!(hold.live(), 1, "the work was not held");

        let _ = finish.send(());
        crate::test_support::wait_until(std::time::Duration::from_secs(5), || hold.live() == 0)
            .expect("the hold to end with the work");
        runtime.shutdown();
    }

    #[gtk4::test]
    fn the_result_arrives_on_the_main_thread() {
        let runtime = crate::test_support::test_runtime();
        let main_thread = std::thread::current().id();
        let seen = Rc::new(RefCell::new(None));
        let sink = seen.clone();

        let _delivery = spawn_and_deliver(&runtime.tasks(), async { std::thread::current().id() }, move |worker| {
            *sink.borrow_mut() = Some((worker.ok(), std::thread::current().id()));
        });
        crate::test_support::wait_until(std::time::Duration::from_secs(5), || seen.borrow().is_some())
            .expect("the delivery");

        let (worker, delivered_on) = seen.borrow_mut().take().expect("a result");
        assert_ne!(worker, Some(main_thread), "the work ran on the GTK thread");
        assert_eq!(delivered_on, main_thread);
    }
}
