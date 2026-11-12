use std::time::Duration;

use tablepro_session::runtime::{Tasks, worker_count};

/// How long a shutdown waits for in-flight work before giving up. Long
/// enough for a durable write to finish, short enough that quitting
/// still feels immediate.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

/// The app's own tokio runtime, built once at startup.
///
/// Owning it means the app decides how many threads exist and when they
/// stop, instead of leaving that to whichever library starts a runtime
/// first.
pub struct AppRuntime {
    runtime: tokio::runtime::Runtime,
}

impl AppRuntime {
    pub fn build() -> std::io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(worker_count())
            .thread_name("tablepro-rt")
            .enable_all()
            .build()?;
        Ok(Self { runtime })
    }

    pub fn tasks(&self) -> Tasks {
        Tasks::new(self.runtime.handle().clone())
    }

    /// Let in-flight work finish, then stop. Called after the GTK main
    /// loop returns, so nothing is still producing work.
    pub fn shutdown(self) {
        self.runtime.shutdown_timeout(SHUTDOWN_GRACE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "the test drives the runtime from outside it, which is the one place block_on cannot deadlock"
    )]
    fn runtime_threads_are_named_tablepro_rt() {
        let runtime = AppRuntime::build().expect("build the runtime");
        let tasks = runtime.tasks();

        let name = tasks
            .handle()
            .block_on(tasks.spawn_blocking_task(|| std::thread::current().name().map(str::to_owned)))
            .expect("the task");

        assert_eq!(name.as_deref(), Some("tablepro-rt"));
        runtime.shutdown();
    }
}
