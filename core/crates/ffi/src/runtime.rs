use std::future::Future;
use std::sync::OnceLock;

use tablepro_session::runtime::{TaskFailure, TaskResult, Tasks, worker_count};
use tokio::runtime::{Builder, Runtime};

use crate::error::CoreError;

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();

// Built once while any other caller waits, so no spare runtime is ever dropped on a runtime thread.
pub(crate) fn tasks() -> Result<Tasks, CoreError> {
    let built = RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(worker_count())
            .enable_all()
            .thread_name("tablepro-core")
            .build()
            .map_err(|error| error.to_string())
    });
    match built {
        Ok(runtime) => Ok(Tasks::new(runtime.handle().clone())),
        Err(detail) => Err(CoreError::failed(
            "ffi.runtime",
            format!("could not start the runtime: {detail}"),
        )),
    }
}

// Dropping this future aborts the task, which a dropped join handle alone would leave running.
pub(crate) async fn on_runtime<T, F>(tasks: &Tasks, work: F) -> Result<T, CoreError>
where
    T: Send + 'static,
    F: Future<Output = Result<T, CoreError>> + Send + 'static,
{
    let mut task = AbortOnDrop(tasks.spawn_task(work));
    match (&mut task.0).await {
        Ok(result) => result,
        Err(TaskFailure::Aborted) => Err(CoreError::Cancelled),
        Err(TaskFailure::Panicked(panic)) => Err(CoreError::failed(
            "ffi.panicked",
            format!("a core task panicked: {panic}"),
        )),
    }
}

struct AbortOnDrop<T>(TaskResult<T>);

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_runtime_keeps_the_worker_count_of_a_database_client() {
        tasks().expect("the runtime");
        let workers = RUNTIME
            .get()
            .and_then(|built| built.as_ref().ok())
            .map(|runtime| runtime.metrics().num_workers());

        assert_eq!(workers, Some(worker_count()));
    }
}
