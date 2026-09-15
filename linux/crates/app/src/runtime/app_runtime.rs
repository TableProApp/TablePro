use std::time::Duration;

use tablepro_session::runtime::Tasks;

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

/// A database client is not compute-bound: its work is waiting on
/// sockets and files. More workers than this only adds context
/// switching, and fewer than two lets one blocking call stall the rest.
fn worker_count() -> usize {
    std::thread::available_parallelism()
        .map(|count| count.get().clamp(2, 4))
        .unwrap_or(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_count_clamps() {
        let clamp = |available: usize| available.clamp(2, 4);

        assert_eq!(clamp(1), 2);
        assert_eq!(clamp(3), 3);
        assert_eq!(clamp(16), 4);
        assert!((2..=4).contains(&worker_count()));
    }

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
