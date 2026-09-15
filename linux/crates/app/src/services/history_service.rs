use std::sync::{Arc, Mutex};
use std::time::Duration;

use tablepro_session::runtime::Tasks;
use tablepro_storage::{QueryHistory, StoragePaths};
use tokio::sync::watch;

use super::history_availability::HistoryAvailability;

/// How often unpinned history is pruned while the app runs. Startup does
/// one pass, and this keeps a long session from growing without bound.
const PRUNE_INTERVAL: Duration = Duration::from_secs(3600);

/// Opens the query history off the GTK thread and prunes it on a timer.
///
/// Opening runs a migration and a prune, which is too slow to block
/// startup on, so the app starts and this reports when the database is
/// usable.
#[derive(Clone)]
pub struct HistoryService {
    availability: watch::Receiver<HistoryAvailability>,
    store: Arc<Mutex<Option<QueryHistory>>>,
    _worker: Arc<tokio_util::task::AbortOnDropHandle<()>>,
}

impl HistoryService {
    pub fn start(paths: StoragePaths, retention_days: u32, tasks: &Tasks) -> Self {
        let (sender, availability) = watch::channel(HistoryAvailability::Starting);
        let store: Arc<Mutex<Option<QueryHistory>>> = Arc::new(Mutex::new(None));
        let store_for_worker = store.clone();

        let worker = tasks.spawn_owned(async move {
            let history = match QueryHistory::open(&paths).await {
                Ok(history) => history,
                Err(error) => {
                    tracing::warn!(%error, "query history unavailable");
                    sender.send_replace(HistoryAvailability::Failed(error.to_string()));
                    return;
                }
            };
            prune(&history, retention_days).await;
            if let Ok(mut guard) = store_for_worker.lock() {
                *guard = Some(history.clone());
            }
            sender.send_replace(HistoryAvailability::Ready);

            let mut ticker = tokio::time::interval(PRUNE_INTERVAL);
            // The first tick fires immediately, and the startup prune
            // just ran.
            ticker.tick().await;
            loop {
                ticker.tick().await;
                prune(&history, retention_days).await;
            }
        });

        Self {
            availability,
            store,
            _worker: Arc::new(worker),
        }
    }

    pub fn availability(&self) -> watch::Receiver<HistoryAvailability> {
        self.availability.clone()
    }

    /// The database, once it opened. `None` while starting or after a
    /// failure, so callers cannot use a half-open handle.
    pub fn store(&self) -> Option<QueryHistory> {
        self.store.lock().ok().and_then(|guard| guard.clone())
    }
}

async fn prune(history: &QueryHistory, retention_days: u32) {
    match history.prune(retention_days).await {
        Ok(report) if report.removed_anything() => {
            tracing::info!(
                expired = report.expired,
                over_cap = report.over_cap,
                "pruned the query history"
            );
        }
        Ok(_) => {}
        Err(error) => tracing::warn!(%error, "history prune failed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::paused_tasks;

    fn paths(root: &tempfile::TempDir) -> StoragePaths {
        StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel")
    }

    async fn wait_for_ready(service: &HistoryService) -> HistoryAvailability {
        let mut availability = service.availability();
        loop {
            if !matches!(*availability.borrow_and_update(), HistoryAvailability::Starting) {
                return availability.borrow().clone();
            }
            availability.changed().await.expect("the sender outlives the service");
        }
    }

    #[tokio::test]
    async fn publishes_ready_after_open() {
        let root = tempfile::tempdir().expect("tempdir");
        let tasks = paused_tasks();

        let service = HistoryService::start(paths(&root), 30, &tasks);
        let state = wait_for_ready(&service).await;

        assert_eq!(state, HistoryAvailability::Ready);
        assert!(service.store().is_some());
    }

    #[tokio::test]
    async fn store_is_none_until_ready() {
        let root = tempfile::tempdir().expect("tempdir");
        let tasks = paused_tasks();

        let service = HistoryService::start(paths(&root), 30, &tasks);

        // Nothing has been polled yet, so the worker cannot have run.
        assert!(service.store().is_none());
        wait_for_ready(&service).await;
        assert!(service.store().is_some());
    }

    #[tokio::test]
    async fn publishes_failed_for_an_unusable_state_dir() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);
        // A file where the state directory should be: the database
        // cannot be created under it.
        std::fs::create_dir_all(paths.state.parent().expect("parent")).expect("create");
        std::fs::write(&paths.state, b"not a directory").expect("seed");
        let tasks = paused_tasks();

        let service = HistoryService::start(paths, 30, &tasks);
        let state = wait_for_ready(&service).await;

        assert!(state.failure().is_some(), "{state:?}");
        assert!(service.store().is_none());
    }
}
