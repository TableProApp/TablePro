use std::sync::Arc;

use tablepro_core::credentials::SecretVault;
use tablepro_session::SessionKey;
use tablepro_session::connect::ConnectionWrites;
use tablepro_session::runtime::Tasks;
use tablepro_storage::QueryHistory;
use uuid::Uuid;

use super::deletion_error::DeletionError;
use super::deletion_report::{DeletionReport, PurgeFailure};
use crate::persistence::{ColumnWidthStore, FilterSettingsStore};
use crate::workspace::WorkspaceStore;

/// What the user chose in the delete dialog.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DeletionOptions {
    pub delete_history: bool,
}

/// Deletes a saved connection, then everything stored for it.
///
/// The order is what keeps a failure recoverable: the secrets go first,
/// because a secret with no entry is orphaned in the keyring while an
/// entry with no secrets only asks for them again. What is kept for the
/// connection goes last, once nothing can reach it.
///
/// GTK-thread only, like the width, filter and workspace stores.
pub struct ConnectionDeletion {
    pub secrets: Arc<dyn SecretVault>,
    pub connections: Arc<dyn ConnectionWrites>,
    pub column_widths: ColumnWidthStore,
    pub filters: FilterSettingsStore,
    pub workspaces: WorkspaceStore,
    /// `None` when the history database did not open.
    pub history: Option<QueryHistory>,
    pub spawner: Tasks,
}

impl ConnectionDeletion {
    pub async fn run(&self, id: Uuid, options: DeletionOptions) -> Result<DeletionReport, DeletionError> {
        // The Secret Service client runs on the runtime.
        let secrets = self.secrets.clone();
        self.spawner
            .spawn_task(async move { secrets.delete_connection(id).await })
            .await
            .map_err(DeletionError::Interrupted)?
            .map_err(DeletionError::Secrets)?;
        self.connections.remove(id).await.map_err(DeletionError::Entry)?;
        Ok(self.purge(id, options).await)
    }

    async fn purge(&self, id: Uuid, options: DeletionOptions) -> DeletionReport {
        let mut report = DeletionReport::default();
        self.column_widths.forget_connection(id);
        self.filters.forget_connection(id);
        // Awaited inside the delete's hold, so a quit right after it
        // cannot leave them on disk.
        self.column_widths.flush().await;
        self.filters.flush().await;
        if let Err(error) = self.workspaces.purge(&SessionKey::Saved(id)).await {
            report.purge_failures.push(PurgeFailure::Workspace(error));
        }
        let Some(history) = self.history.clone() else {
            let unavailable = || "the query history did not open".to_owned();
            report.purge_failures.push(PurgeFailure::SavedQueries(unavailable()));
            if options.delete_history {
                report.purge_failures.push(PurgeFailure::History(unavailable()));
            }
            return report;
        };
        // The queries saved under the connection name tables only its
        // database has, so they go with it whatever the history switch
        // says.
        let saved_queries = history.saved_queries();
        let removed = self
            .spawner
            .spawn_task(async move { saved_queries.delete_for_connection(id).await })
            .await;
        if let Some(error) = failure_text(removed) {
            report.purge_failures.push(PurgeFailure::SavedQueries(error));
        }
        if options.delete_history {
            let removed = self
                .spawner
                .spawn_task(async move { history.delete_for_connection(id).await })
                .await;
            if let Some(error) = failure_text(removed) {
                report.purge_failures.push(PurgeFailure::History(error));
            }
        }
        report
    }
}

fn failure_text<T, E: std::fmt::Display>(
    outcome: Result<Result<T, E>, tablepro_session::runtime::TaskFailure>,
) -> Option<String> {
    match outcome {
        Ok(Ok(_)) => None,
        Ok(Err(error)) => Some(error.to_string()),
        Err(failure) => Some(failure.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Mutex;

    use futures::future::BoxFuture;
    use secrecy::SecretString;
    use tablepro_core::credentials::{SecretError, SecretKind};
    use tablepro_core::{AuthMode, Combinator, FilterOp, FilterRule, FilterSet, FilterValue, TlsConfig};
    use tablepro_session::connect::StoreConnectionWrites;
    use tablepro_storage::query_history::{HistoryPageRequest, HistoryQuery, NewEntry, Outcome};
    use tablepro_storage::saved_queries::NewSavedQuery;
    use tablepro_storage::{ConnectionStore, DraftId, DraftStore, SavedConnection, StorageError, StoragePaths};
    use tablepro_test_support::{Call, FakeSecretVault};

    use super::*;
    use crate::test_support::paused_tasks;
    use crate::workspace::{TabRecord, WorkspaceFileName, WorkspaceRecord};

    type Log = Arc<Mutex<Vec<String>>>;

    /// The list on disk, noting at each removal whether the secrets were
    /// already deleted and the saved tabs were still there.
    struct LoggedWrites {
        writes: StoreConnectionWrites,
        vault: Arc<FakeSecretVault>,
        log: Log,
        tabs: PathBuf,
    }

    impl ConnectionWrites for LoggedWrites {
        fn upsert(&self, connection: SavedConnection) -> BoxFuture<'_, Result<(), StorageError>> {
            self.writes.upsert(connection)
        }

        fn remove(&self, id: Uuid) -> BoxFuture<'_, Result<(), StorageError>> {
            let secrets_gone = self.vault.calls().contains(&Call::DeleteConnection(id));
            self.log.lock().unwrap().push(format!(
                "list, secrets deleted: {secrets_gone}, tabs still saved: {}",
                self.tabs.exists()
            ));
            self.writes.remove(id)
        }
    }

    struct Fixture {
        _root: tempfile::TempDir,
        paths: StoragePaths,
        store: ConnectionStore,
        vault: Arc<FakeSecretVault>,
        widths: ColumnWidthStore,
        filters: FilterSettingsStore,
        workspaces: WorkspaceStore,
        drafts: DraftStore,
        history: QueryHistory,
        id: Uuid,
        other: Uuid,
        log: Log,
    }

    fn connection(id: Uuid) -> SavedConnection {
        SavedConnection {
            id,
            name: "Prod".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.example.com".to_owned(),
            port: 5432,
            database: "shop".to_owned(),
            username: "app".to_owned(),
            tls: TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn filter() -> FilterSet {
        FilterSet {
            combinator: Combinator::And,
            rules: vec![FilterRule {
                column: "name".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("alice".into())),
            }],
            extra_sql: None,
        }
    }

    fn ran(query: &str, connection: Uuid) -> NewEntry {
        NewEntry {
            query: query.to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: connection,
            connection_name: "Prod".to_owned(),
            executed_at: std::time::SystemTime::now(),
            duration_ms: Some(1),
            rows_affected: Some(0),
            outcome: Outcome::Success,
        }
    }

    /// Two connections with something of every kind stored for each.
    async fn fixture() -> Fixture {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test");
        let tasks = paused_tasks();
        let store = ConnectionStore::new(&paths);
        let vault = Arc::new(FakeSecretVault::new());
        let widths = ColumnWidthStore::load(paths.column_widths_file(), &tasks);
        let filters = FilterSettingsStore::load(paths.filter_settings_file(), &tasks);
        let drafts = DraftStore::new(paths.drafts_dir());
        let workspaces = WorkspaceStore::start(paths.workspaces_dir(), drafts.clone(), &tasks);
        let history = QueryHistory::open(&paths).await.expect("the history");
        let (id, other) = (Uuid::new_v4(), Uuid::new_v4());
        for connection_id in [id, other] {
            store.upsert_blocking(connection(connection_id)).expect("the entry");
            vault
                .store(
                    connection_id,
                    SecretKind::DatabasePassword,
                    &SecretString::from("s3cret"),
                    "label",
                )
                .await
                .expect("the password");
            widths.record(connection_id, Some("public"), "users", "name", 120);
            filters.set_filters(connection_id, Some("public"), "users", filter());
            let key = SessionKey::Saved(connection_id);
            let draft = DraftId::new();
            drafts
                .write_blocking(&WorkspaceFileName::for_key(&key).draft_scope(), draft, "SELECT 1")
                .expect("a draft");
            workspaces
                .schedule(
                    &key,
                    WorkspaceRecord {
                        active_tab: Some(0),
                        tabs: vec![TabRecord::Editor { draft, file: None }],
                    },
                )
                .expect("scheduled");
            workspaces.flush(&key).await.expect("the saved tabs");
            history
                .record(ran("SELECT * FROM users", connection_id))
                .await
                .expect("a history entry");
            history
                .saved_queries()
                .save(NewSavedQuery {
                    name: "users".to_owned(),
                    query: "SELECT * FROM users".to_owned(),
                    connection_id,
                    connection_name: "Prod".to_owned(),
                })
                .await
                .expect("a saved query");
        }
        Fixture {
            _root: root,
            paths,
            store,
            vault,
            widths,
            filters,
            workspaces,
            drafts,
            history,
            id,
            other,
            log: Log::default(),
        }
    }

    impl Fixture {
        fn deletion(&self) -> ConnectionDeletion {
            ConnectionDeletion {
                secrets: self.vault.clone(),
                connections: Arc::new(LoggedWrites {
                    writes: StoreConnectionWrites::new(self.store.clone(), paused_tasks()),
                    vault: self.vault.clone(),
                    log: self.log.clone(),
                    tabs: self.tabs(self.id),
                }),
                column_widths: self.widths.clone(),
                filters: self.filters.clone(),
                workspaces: self.workspaces.clone(),
                history: Some(self.history.clone()),
                spawner: paused_tasks(),
            }
        }

        fn tabs(&self, id: Uuid) -> PathBuf {
            self.paths
                .workspaces_dir()
                .join(WorkspaceFileName::for_key(&SessionKey::Saved(id)).file_name())
        }

        fn drafts_of(&self, id: Uuid) -> PathBuf {
            self.drafts.root().join(
                WorkspaceFileName::for_key(&SessionKey::Saved(id))
                    .draft_scope()
                    .as_str(),
            )
        }

        fn listed(&self, id: Uuid) -> bool {
            self.store
                .load_blocking()
                .expect("the list")
                .iter()
                .any(|saved| saved.id == id)
        }

        fn has_password(&self, id: Uuid) -> bool {
            self.vault.stored_secret(id, SecretKind::DatabasePassword).is_some()
        }

        async fn history_count(&self, id: Uuid) -> u64 {
            self.history.count_for_connection(id).await.expect("the count")
        }

        async fn saved_query_count(&self, id: Uuid) -> usize {
            self.history
                .saved_queries()
                .list(Some(id))
                .await
                .expect("the saved queries")
                .len()
        }

        /// Everything stored for `id` other than its entry and secrets
        /// is still there.
        async fn kept_everything_for(&self, id: Uuid) {
            assert!(self.widths.width(id, Some("public"), "users", "name").is_some());
            assert_eq!(self.filters.filters(id, Some("public"), "users"), filter());
            assert!(self.tabs(id).exists(), "the saved tabs went");
            assert!(self.drafts_of(id).exists(), "the drafts went");
            assert_eq!(self.history_count(id).await, 1);
            assert_eq!(self.saved_query_count(id).await, 1);
        }
    }

    #[tokio::test]
    async fn secret_failure_keeps_entry_and_skips_purge() {
        let fixture = fixture().await;
        fixture.vault.fail_delete_connection(SecretError::Locked);

        let refused = fixture
            .deletion()
            .run(fixture.id, DeletionOptions { delete_history: true })
            .await;

        assert!(
            matches!(refused, Err(DeletionError::Secrets(SecretError::Locked))),
            "{refused:?}"
        );
        assert!(fixture.listed(fixture.id), "the entry went while its secrets stayed");
        assert!(fixture.log.lock().unwrap().is_empty(), "the list was written");
        assert!(fixture.has_password(fixture.id));
        fixture.kept_everything_for(fixture.id).await;
    }

    #[tokio::test]
    async fn order_is_secrets_then_list_then_purge() {
        let fixture = fixture().await;

        fixture
            .deletion()
            .run(fixture.id, DeletionOptions::default())
            .await
            .expect("the delete");

        assert_eq!(
            *fixture.log.lock().unwrap(),
            ["list, secrets deleted: true, tabs still saved: true"],
            "the steps ran out of order"
        );
        assert!(!fixture.tabs(fixture.id).exists(), "the purge did not follow the list");
    }

    #[tokio::test]
    async fn success_forgets_widths_filters_workspace_and_drafts() {
        let fixture = fixture().await;

        let report = fixture
            .deletion()
            .run(fixture.id, DeletionOptions::default())
            .await
            .expect("the delete");

        assert!(report.is_complete(), "{report:?}");
        assert!(!fixture.listed(fixture.id));
        assert!(!fixture.has_password(fixture.id));
        assert!(
            fixture
                .widths
                .width(fixture.id, Some("public"), "users", "name")
                .is_none()
        );
        assert!(fixture.filters.filters(fixture.id, Some("public"), "users").is_empty());
        for file in [fixture.paths.column_widths_file(), fixture.paths.filter_settings_file()] {
            let on_disk = std::fs::read_to_string(&file).expect("the file");
            assert!(
                !on_disk.contains(&fixture.id.to_string()),
                "{} still names the deleted connection once the delete ended",
                file.display()
            );
            assert!(on_disk.contains(&fixture.other.to_string()));
        }
        assert!(
            !fixture.tabs(fixture.id).exists(),
            "the saved tabs outlived the connection"
        );
        assert!(
            !fixture.drafts_of(fixture.id).exists(),
            "the drafts outlived the connection"
        );
        assert_eq!(fixture.saved_query_count(fixture.id).await, 0);
        assert!(fixture.listed(fixture.other));
        assert!(fixture.has_password(fixture.other));
        fixture.kept_everything_for(fixture.other).await;
    }

    #[tokio::test]
    async fn history_kept_unless_requested() {
        let fixture = fixture().await;

        fixture
            .deletion()
            .run(fixture.id, DeletionOptions::default())
            .await
            .expect("the delete");

        assert_eq!(fixture.history_count(fixture.id).await, 1);
    }

    #[tokio::test]
    async fn history_deleted_when_requested() {
        let fixture = fixture().await;

        let report = fixture
            .deletion()
            .run(fixture.id, DeletionOptions { delete_history: true })
            .await
            .expect("the delete");

        assert!(report.is_complete(), "{report:?}");
        assert_eq!(fixture.history_count(fixture.id).await, 0);
        assert_eq!(fixture.history_count(fixture.other).await, 1);
        let left = fixture
            .history
            .search_page(&HistoryQuery::from_input("users"), HistoryPageRequest::first(10))
            .await
            .expect("search")
            .entries;
        assert!(left.iter().all(|entry| entry.connection_id == fixture.other));
    }

    #[tokio::test]
    async fn without_the_history_database_only_the_saved_queries_are_left_unless_history_was_asked_for() {
        let fixture = fixture().await;
        let mut deletion = fixture.deletion();
        deletion.history = None;

        let report = deletion
            .run(fixture.id, DeletionOptions::default())
            .await
            .expect("the delete");

        assert!(
            matches!(report.purge_failures.as_slice(), [PurgeFailure::SavedQueries(_)]),
            "{report:?}"
        );
    }

    #[tokio::test]
    async fn purge_failure_reported_but_entry_removed() {
        let fixture = fixture().await;
        let drafts = fixture.drafts_of(fixture.id);
        std::fs::remove_dir_all(&drafts).expect("clear the drafts");
        // A file where the drafts directory goes cannot be removed as
        // one.
        std::fs::write(&drafts, b"not a directory").expect("seed");
        let mut deletion = fixture.deletion();
        deletion.history = None;

        let report = deletion
            .run(fixture.id, DeletionOptions { delete_history: true })
            .await
            .expect("the delete");

        assert!(!fixture.listed(fixture.id), "a failed purge kept the entry");
        assert!(!fixture.has_password(fixture.id));
        assert!(
            report
                .purge_failures
                .iter()
                .any(|failure| matches!(failure, PurgeFailure::Workspace(_))),
            "{report:?}"
        );
        assert!(
            report
                .purge_failures
                .iter()
                .any(|failure| matches!(failure, PurgeFailure::SavedQueries(_))),
            "{report:?}"
        );
        assert!(
            report
                .purge_failures
                .iter()
                .any(|failure| matches!(failure, PurgeFailure::History(_))),
            "{report:?}"
        );
        assert!(
            fixture
                .widths
                .width(fixture.id, Some("public"), "users", "name")
                .is_none()
        );
        assert!(
            !fixture.tabs(fixture.id).exists(),
            "the saved tabs stayed with the drafts"
        );
    }
}
