use tokio::runtime::Handle;
use tokio_util::task::AbortOnDropHandle;

use super::TaskResult;

/// A handle to the app's runtime.
///
/// Everything background goes through this, so there is one place that
/// decides where work runs and nothing reaches for the ambient runtime.
#[derive(Debug, Clone)]
pub struct Tasks {
    handle: Handle,
}

#[expect(
    clippy::disallowed_methods,
    reason = "this is the one wrapper the ban points every other caller at"
)]
impl Tasks {
    pub fn new(handle: Handle) -> Self {
        Self { handle }
    }

    pub fn handle(&self) -> &Handle {
        &self.handle
    }

    /// Spawn async work. Dropping the result detaches the task.
    pub fn spawn_task<F>(&self, future: F) -> TaskResult<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        TaskResult::new(self.handle.spawn(future))
    }

    /// Spawn work that blocks, such as a durable file write, so it never
    /// occupies a runtime worker or the GTK thread.
    pub fn spawn_blocking_task<F, T>(&self, work: F) -> TaskResult<T>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        TaskResult::new(self.handle.spawn_blocking(work))
    }

    /// Spawn work that belongs to the returned handle: dropping it stops
    /// the task. For loops that exist only while a view does.
    pub fn spawn_owned<F>(&self, future: F) -> AbortOnDropHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        AbortOnDropHandle::new(self.handle.spawn(future))
    }
}

#[cfg(test)]
mod tests {
    use crate::test_support::paused_tasks;

    #[tokio::test]
    async fn spawn_blocking_task_runs_off_the_worker() {
        let tasks = paused_tasks();

        let value = tasks.spawn_blocking_task(|| 5).await.expect("the task");

        assert_eq!(value, 5);
    }

    #[tokio::test(start_paused = true)]
    async fn spawn_owned_stops_when_the_handle_drops() {
        let tasks = paused_tasks();
        let counter = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter_for_task = counter.clone();

        let owned = tasks.spawn_owned(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                counter_for_task.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        });
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        drop(owned);
        let after_drop = counter.load(std::sync::atomic::Ordering::Relaxed);
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;

        assert_eq!(
            counter.load(std::sync::atomic::Ordering::Relaxed),
            after_drop,
            "the task kept running after its handle dropped"
        );
    }
}
