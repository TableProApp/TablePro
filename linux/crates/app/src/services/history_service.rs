use std::sync::{Arc, Mutex};
use std::time::Duration;

use tablepro_core::dialect::SqlDialect;
use tablepro_core::sql_syntax::HistoryRecording;
use tablepro_session::runtime::Tasks;
use tablepro_storage::query_history::{MAX_QUERY_BYTES, NewEntry};
use tablepro_storage::{QueryHistory, StoragePaths};
use tokio::sync::watch;

use super::history_availability::HistoryAvailability;
use super::history_preferences::HistoryPreferences;

/// How often unpinned history is pruned while the app runs. Startup does
/// one pass, and this keeps a long session from growing without bound.
const PRUNE_INTERVAL: Duration = Duration::from_secs(3600);

/// Opens the query history off the GTK thread, prunes it on a timer and
/// decides what goes into it.
///
/// Opening runs a migration and a prune, which is too slow to block
/// startup on, so the app starts and this reports when the database is
/// usable.
#[derive(Clone)]
pub struct HistoryService {
    availability: watch::Receiver<HistoryAvailability>,
    store: Arc<Mutex<Option<QueryHistory>>>,
    save: watch::Receiver<bool>,
    _worker: Arc<tokio_util::task::AbortOnDropHandle<()>>,
}

impl HistoryService {
    /// `retention` is read at every tick rather than captured, so a
    /// value the user typed through on the way to another one never
    /// decides what is deleted an hour later.
    pub fn start(paths: StoragePaths, preferences: HistoryPreferences, tasks: &Tasks) -> Self {
        let HistoryPreferences {
            retention_days: retention,
            save,
        } = preferences;
        let (sender, availability) = watch::channel(HistoryAvailability::Starting);
        let store: Arc<Mutex<Option<QueryHistory>>> = Arc::new(Mutex::new(None));
        let store_for_worker = store.clone();

        let worker = tasks.spawn_owned(async move {
            let history = match QueryHistory::open(&paths).await {
                Ok(history) => history,
                Err(error) => {
                    tracing::warn!(%error, "query history unavailable");
                    sender.send_replace(HistoryAvailability::failed(&error));
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
            save,
            _worker: Arc::new(worker),
        }
    }

    /// Record one run once the database is open, unless the user turned
    /// the history off or the SQL can carry a credential.
    ///
    /// `dialect` is the connection's: without it nobody can say which
    /// statements hold a secret, so nothing is recorded. The setting is
    /// read now, so a run that ends after the history was turned off is
    /// not recorded either.
    pub fn record(
        &self,
        entry: NewEntry,
        dialect: Option<Arc<dyn SqlDialect>>,
    ) -> impl Future<Output = ()> + Send + use<> {
        let saving = *self.save.borrow();
        let store = self.ready_store();
        async move {
            if !saving {
                return;
            }
            let Some(dialect) = dialect else {
                tracing::debug!(connection = %entry.connection_id, "no dialect, so the run is not recorded");
                return;
            };
            // The store refuses it anyway, and reading it for credentials
            // lexes it once per way the server may read it.
            if entry.query.len() > MAX_QUERY_BYTES {
                tracing::debug!(connection = %entry.connection_id, "a run too large for the history was not recorded");
                return;
            }
            if let HistoryRecording::Withhold(reason) = dialect.history_recording(&entry.query) {
                tracing::debug!(connection = %entry.connection_id, ?reason, "a run was kept out of the history");
                return;
            }
            let Some(history) = store.await else {
                return;
            };
            if let Err(error) = history.record(entry).await {
                tracing::warn!(%error, "history record failed");
            }
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

    /// The database once the open at startup has finished, or `None`
    /// when it failed, for work that must not skip the history just
    /// because it ran early.
    pub fn ready_store(&self) -> impl Future<Output = Option<QueryHistory>> + use<> {
        let mut availability = self.availability.clone();
        let store = self.store.clone();
        async move {
            // A sender gone means the worker ended, which it does only
            // after it has said how the open went.
            let _ = availability.wait_for(HistoryAvailability::is_settled).await;
            store.lock().ok().and_then(|guard| guard.clone())
        }
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

    /// Preferences that stay as given: a dropped sender leaves the
    /// receiver on its last value.
    fn preferences(days: u32, save: bool) -> HistoryPreferences {
        HistoryPreferences {
            retention_days: watch::channel(days).1,
            save: watch::channel(save).1,
        }
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

        let service = HistoryService::start(paths(&root), preferences(30, true), &tasks);
        let state = wait_for_ready(&service).await;

        assert_eq!(state, HistoryAvailability::Ready);
        assert!(service.store().is_some());
    }

    #[tokio::test]
    async fn ready_store_waits_for_the_open() {
        let root = tempfile::tempdir().expect("tempdir");

        let service = HistoryService::start(paths(&root), preferences(30, true), &paused_tasks());
        assert!(service.store().is_none());

        assert!(service.ready_store().await.is_some());
    }

    #[tokio::test]
    async fn store_is_none_until_ready() {
        let root = tempfile::tempdir().expect("tempdir");
        let tasks = paused_tasks();

        let service = HistoryService::start(paths(&root), preferences(30, true), &tasks);

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
            .search_page(
                &tablepro_storage::query_history::HistoryQuery::default(),
                tablepro_storage::query_history::HistoryPageRequest::first(100),
            )
            .await
            .expect("search")
            .entries
            .into_iter()
            .map(|entry| entry.query)
            .collect()
    }

    /// A service whose store is open, with its retention channel.
    async fn ready_service(root: &tempfile::TempDir, days: u32) -> (QueryHistory, watch::Sender<u32>) {
        let (retention, receiver) = watch::channel(days);
        let preferences = HistoryPreferences {
            retention_days: receiver,
            save: watch::channel(true).1,
        };
        let service = HistoryService::start(paths(root), preferences, &paused_tasks());
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

        let service = HistoryService::start(paths, preferences(30, true), &tasks);
        let state = wait_for_ready(&service).await;

        assert!(state.failure().is_some(), "{state:?}");
        assert!(service.store().is_none());
    }

    fn run_of(query: &str) -> NewEntry {
        NewEntry {
            query: query.to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: uuid::Uuid::new_v4(),
            connection_name: "local".to_owned(),
            executed_at: std::time::SystemTime::now(),
            duration_ms: Some(1),
            rows_affected: None,
            outcome: tablepro_storage::query_history::Outcome::Success,
        }
    }

    fn fake_dialect() -> Option<Arc<dyn SqlDialect>> {
        Some(Arc::new(tablepro_test_support::FakeDialect))
    }

    /// Record `query` through a service built with `save`, and read back
    /// what the store holds.
    async fn recorded(save: bool, query: &str, dialect: Option<Arc<dyn SqlDialect>>) -> Vec<String> {
        let root = tempfile::tempdir().expect("tempdir");
        let service = HistoryService::start(paths(&root), preferences(30, save), &paused_tasks());

        service.record(run_of(query), dialect).await;

        let history = service.ready_store().await.expect("the store");
        queries(&history).await
    }

    #[tokio::test]
    async fn history_service_skips_when_setting_off() {
        assert_eq!(recorded(false, "SELECT 1", fake_dialect()).await, Vec::<String>::new());
    }

    #[tokio::test]
    async fn history_service_skips_without_dialect() {
        assert_eq!(recorded(true, "SELECT 1", None).await, Vec::<String>::new());
    }

    #[tokio::test]
    async fn history_service_skips_credential_statement() {
        assert_eq!(
            recorded(true, "SELECT 1; CREATE USER u PASSWORD 'p'", fake_dialect()).await,
            Vec::<String>::new()
        );
    }

    #[tokio::test]
    async fn history_service_records_plain_select_unchanged() {
        let query = "SELECT id FROM users WHERE password IS NULL AND email = 'a@b'  -- kept as typed\n";

        assert_eq!(recorded(true, query, fake_dialect()).await, vec![query.to_owned()]);
    }

    #[tokio::test]
    async fn turning_the_history_off_stops_the_next_record() {
        let root = tempfile::tempdir().expect("tempdir");
        let (save, receiver) = watch::channel(true);
        let preferences = HistoryPreferences {
            retention_days: watch::channel(30).1,
            save: receiver,
        };
        let service = HistoryService::start(paths(&root), preferences, &paused_tasks());
        service.record(run_of("SELECT 'kept'"), fake_dialect()).await;

        save.send_replace(false);
        service.record(run_of("SELECT 'dropped'"), fake_dialect()).await;

        let history = service.ready_store().await.expect("the store");
        assert_eq!(queries(&history).await, vec!["SELECT 'kept'".to_owned()]);
    }
}
