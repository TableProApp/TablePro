use futures::future::{AbortHandle, Abortable, LocalBoxFuture};
use tokio::sync::watch;

/// Delivers each value a watch channel takes to a callback on the
/// thread that spawned it, until dropped.
///
/// The caller supplies the local spawner (on the GTK side,
/// `glib::spawn_future_local`), so this stays free of GTK while a view
/// still owns its loop: dropping the forwarder stops it, and a value
/// published after the view went away is never delivered.
#[derive(Debug)]
#[must_use = "dropping the forwarder stops delivery"]
pub struct WatchForwarder {
    abort: AbortHandle,
}

impl WatchForwarder {
    /// Deliver the current value at once, then every change.
    pub fn new<T, F, S>(mut receiver: watch::Receiver<T>, mut deliver: F, spawn_local: S) -> Self
    where
        T: Clone + 'static,
        F: FnMut(T) + 'static,
        S: FnOnce(LocalBoxFuture<'static, ()>),
    {
        let (abort, registration) = AbortHandle::new_pair();
        let forward = async move {
            let current = receiver.borrow_and_update().clone();
            deliver(current);
            while receiver.changed().await.is_ok() {
                let value = receiver.borrow_and_update().clone();
                deliver(value);
            }
        };
        spawn_local(Box::pin(async move {
            // Aborted means the owner went away, which is the normal end.
            let _ = Abortable::new(forward, registration).await;
        }));
        Self { abort }
    }
}

impl Drop for WatchForwarder {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;

    fn spawn_on(local: &tokio::task::LocalSet) -> impl FnOnce(LocalBoxFuture<'static, ()>) + '_ {
        move |future| {
            local.spawn_local(future);
        }
    }

    #[tokio::test]
    async fn delivers_the_current_value_then_each_change() {
        let local = tokio::task::LocalSet::new();
        let (sender, receiver) = watch::channel(1);
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();

        let forwarder = WatchForwarder::new(receiver, move |value| sink.borrow_mut().push(value), spawn_on(&local));
        local
            .run_until(async {
                tokio::task::yield_now().await;
                sender.send_replace(2);
                tokio::task::yield_now().await;
                sender.send_replace(3);
                tokio::task::yield_now().await;
            })
            .await;

        assert_eq!(*seen.borrow(), [1, 2, 3]);
        drop(forwarder);
    }

    #[tokio::test]
    async fn nothing_is_delivered_after_the_forwarder_drops() {
        let local = tokio::task::LocalSet::new();
        let (sender, receiver) = watch::channel(1);
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();

        let forwarder = WatchForwarder::new(receiver, move |value| sink.borrow_mut().push(value), spawn_on(&local));
        local
            .run_until(async {
                tokio::task::yield_now().await;
                drop(forwarder);
                sender.send_replace(2);
                tokio::task::yield_now().await;
                tokio::task::yield_now().await;
            })
            .await;

        assert_eq!(*seen.borrow(), [1]);
    }
}
