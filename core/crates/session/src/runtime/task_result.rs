use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

use tokio::task::JoinHandle;

use super::{TaskFailure, TaskPanic};

/// A running task's result, with the join error already turned into
/// something the UI can report.
///
/// Dropping it detaches the task rather than cancelling it, so a caller
/// that stops caring does not abort work someone else needs.
pub struct TaskResult<T> {
    handle: JoinHandle<T>,
}

impl<T> TaskResult<T> {
    pub(super) fn new(handle: JoinHandle<T>) -> Self {
        Self { handle }
    }

    /// Stop the task now. Awaiting afterwards gives `Aborted`.
    pub fn abort(&self) {
        self.handle.abort();
    }
}

impl<T> Future for TaskResult<T> {
    type Output = Result<T, TaskFailure>;

    fn poll(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Self::Output> {
        Pin::new(&mut self.handle).poll(context).map(|joined| match joined {
            Ok(value) => Ok(value),
            Err(error) if error.is_panic() => Err(TaskFailure::Panicked(TaskPanic::from_payload(error.into_panic()))),
            Err(_) => Err(TaskFailure::Aborted),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::paused_tasks;

    #[tokio::test]
    async fn returns_the_value() {
        let tasks = paused_tasks();

        let value = tasks.spawn_task(async { 7 }).await.expect("the task");

        assert_eq!(value, 7);
    }

    #[tokio::test]
    async fn reports_panicked() {
        let tasks = paused_tasks();

        let failure = tasks
            .spawn_task(async { panic!("boom") })
            .await
            .expect_err("a panicking task");

        assert_eq!(
            failure,
            TaskFailure::Panicked(TaskPanic::from_payload(Box::new("boom")))
        );
        assert!(failure.is_panic());
    }

    #[tokio::test]
    async fn reports_aborted_after_abort() {
        let tasks = paused_tasks();
        let running = tasks.spawn_task(async {
            std::future::pending::<()>().await;
        });

        running.abort();
        let failure = running.await.expect_err("an aborted task");

        assert_eq!(failure, TaskFailure::Aborted);
        assert!(!failure.is_panic());
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_awaiter_detaches() {
        let tasks = paused_tasks();
        let (sender, receiver) = tokio::sync::oneshot::channel();

        drop(tasks.spawn_task(async move {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            let _ = sender.send(());
        }));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        assert!(receiver.await.is_ok(), "dropping the handle cancelled the task");
    }
}
