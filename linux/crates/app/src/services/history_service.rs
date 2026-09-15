use gio::prelude::SettingsExt;
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

/// Mirror the retention preference onto a channel the prune worker can
/// read.
///
/// `gio::Settings` lives on the GTK thread, so the worker cannot hold
/// it. This keeps the newest value where the worker can see it.
pub fn publish_retention(settings: &std::rc::Rc<tablepro_storage::AppSettings>) -> watch::Receiver<u32> {
    let (sender, receiver) = watch::channel(settings.history_retention_days());
    let settings_for_change = settings.clone();
    settings.gio().connect_changed(
        Some(tablepro_storage::settings::keys::HISTORY_RETENTION_DAYS),
        move |_, _| {
            sender.send_replace(settings_for_change.history_retention_days());
        },
    );
    receiver
}

impl HistoryService {
    /// `retention` is read at every tick rather than captured, so a
    /// value the user typed through on the way to another one never
    /// decides what is deleted an hour later.
    pub fn start(paths: StoragePaths, retention: watch::Receiver<u32>, tasks: &Tasks) -> Self {
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
            prune_now(&history, &retention).await;
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
                prune_now(&history, &retention).await;
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

/// One prune at the retention the user has set right now.
///
/// Reading the channel here rather than capturing a value is what keeps
/// a number typed through on the way to another one from deciding, an
/// hour later, what gets deleted.
async fn prune_now(history: &QueryHistory, retention: &watch::Receiver<u32>) {
    // The guard cannot be held across the await below.
    let days = *retention.borrow();
    prune(history, days).await;
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

    fn retention(days: u32) -> watch::Receiver<u32> {
        watch::channel(days).1
    }

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

        let service = HistoryService::start(paths(&root), retention(30), &tasks);
        let state = wait_for_ready(&service).await;

        assert_eq!(state, HistoryAvailability::Ready);
        assert!(service.store().is_some());
    }

    #[tokio::test]
    async fn store_is_none_until_ready() {
        let root = tempfile::tempdir().expect("tempdir");
        let tasks = paused_tasks();

        let service = HistoryService::start(paths(&root), retention(30), &tasks);

        // Nothing has been polled yet, so the worker cannot have run.
        assert!(service.store().is_none());
        wait_for_ready(&service).await;
        assert!(service.store().is_some());
    }

    /// One entry `age_days` old, unpinned unless asked.
    async fn seed(history: &QueryHistory, query: &str, age_days: u64, pinned: bool) {
        let id = history
            .record(tablepro_storage::query_history::NewEntry {
                query: query.to_owned(),
                driver_id: "postgres".to_owned(),
                connection_id: uuid::Uuid::new_v4(),
                connection_name: "local".to_owned(),
                executed_at: std::time::SystemTime::now() - Duration::from_secs(age_days * 86_400),
                duration_ms: Some(1),
                rows_affected: Some(0),
                outcome: tablepro_storage::query_history::Outcome::Success,
            })
            .await
            .expect("record");
        if pinned {
            history.set_pinned(id, true).await.expect("pin");
        }
    }

    async fn queries(history: &QueryHistory) -> Vec<String> {
        history
            .search(tablepro_storage::query_history::SearchFilter {
                limit: 100,
                ..Default::default()
            })
            .await
            .expect("search")
            .into_iter()
            .map(|entry| entry.query)
            .collect()
    }

    /// A service whose store is open, with its retention channel.
    async fn ready_service(root: &tempfile::TempDir, days: u32) -> (QueryHistory, watch::Sender<u32>) {
        let (retention, receiver) = watch::channel(days);
        let service = HistoryService::start(paths(root), receiver.clone(), &paused_tasks());
        let state = wait_for_ready(&service).await;
        assert_eq!(state, HistoryAvailability::Ready, "the history did not open");
        (service.store().expect("the store"), retention)
    }

    #[tokio::test]
    async fn scheduled_prune_uses_current_setting() {
        let root = tempfile::tempdir().expect("tempdir");
        let (history, retention) = ready_service(&root, 3_650).await;
        seed(&history, "SELECT old", 40, false).await;
        seed(&history, "SELECT pinned", 40, true).await;
        seed(&history, "SELECT recent", 1, false).await;
        // Set after the service started, so a captured value would
        // still be the 3650 it was built with.
        retention.send_replace(30);

        prune_now(&history, &retention.subscribe()).await;

        let left = queries(&history).await;
        assert!(!left.contains(&"SELECT old".to_owned()), "{left:?}");
        assert!(
            left.contains(&"SELECT pinned".to_owned()),
            "a pinned entry was pruned: {left:?}"
        );
        assert!(left.contains(&"SELECT recent".to_owned()), "{left:?}");
    }

    #[tokio::test]
    async fn transient_retention_value_does_not_prune() {
        let root = tempfile::tempdir().expect("tempdir");
        let (history, retention) = ready_service(&root, 30).await;
        seed(&history, "SELECT kept", 20, false).await;

        // The spin row writes every value it passes through, so a user
        // on their way from 30 to 1000 types a 1 first. Only the value
        // at the prune may decide anything.
        retention.send_replace(1);
        retention.send_replace(30);
        prune_now(&history, &retention.subscribe()).await;

        assert_eq!(
            queries(&history).await,
            vec!["SELECT kept".to_owned()],
            "a value typed through pruned"
        );
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

        let service = HistoryService::start(paths, retention(30), &tasks);
        let state = wait_for_ready(&service).await;

        assert!(state.failure().is_some(), "{state:?}");
        assert!(service.store().is_none());
    }
}
