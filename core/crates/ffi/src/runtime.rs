use std::future::Future;
use std::sync::OnceLock;

use tablepro_session::runtime::{TaskFailure, TaskResult, Tasks};
use tokio::runtime::{Builder, Runtime};

use crate::error::CoreError;

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();

/// The process's one runtime, built by the first caller while any other
/// waits, so no spare runtime is ever dropped on a runtime thread.
pub(crate) fn tasks() -> Result<Tasks, CoreError> {
    let built = RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
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

/// Runs `work` on the runtime and waits for it. The foreign side polls
/// only the join, and dropping this future aborts the task, which a
/// dropped join handle alone would leave running.
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
