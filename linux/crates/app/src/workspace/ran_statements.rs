use std::sync::Arc;
use std::time::SystemTime;

use tablepro_core::dialect::SqlDialect;
use tablepro_session::ConnectionMetadata;
use tablepro_storage::query_history::{NewEntry, Outcome};

use crate::services::history_service::HistoryService;

/// What the app needs to record a statement batch it ran on the user's
/// behalf.
///
/// A row save and a structure save change the database as surely as a
/// statement typed into the editor does, so the history that answers
/// "what did this to my table" has to carry them too. It is captured
/// before the work starts, because the connection can be gone by the
/// time the answer comes back.
#[derive(Clone)]
pub(crate) struct RanStatements {
    history: Option<HistoryService>,
    connection: Option<ConnectionMetadata>,
    dialect: Option<Arc<dyn SqlDialect>>,
    sql: String,
    started_at: SystemTime,
}

impl RanStatements {
    /// Capture the batch about to run. `sql` reads as one entry in the
    /// history list, which is how the user thinks of one save.
    pub(crate) fn starting(
        history: Option<HistoryService>,
        connection: Option<ConnectionMetadata>,
        dialect: Option<Arc<dyn SqlDialect>>,
        statements: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            history,
            connection,
            dialect,
            sql: join(statements),
            started_at: SystemTime::now(),
        }
    }

    /// Record how it went, through the same gate as an editor run. Does
    /// nothing when the history is closed or the batch was empty, and
    /// never fails the save it describes: a history that cannot be
    /// written is worth a log line, not a lost edit.
    pub(crate) async fn finished(self, rows_affected: Option<i64>, outcome: Outcome) {
        let (Some(history), Some(connection)) = (self.history, self.connection) else {
            return;
        };
        if self.sql.is_empty() {
            return;
        }
        let entry = NewEntry {
            query: self.sql,
            driver_id: connection.driver_id,
            connection_id: connection.id,
            connection_name: connection.name,
            executed_at: self.started_at,
            duration_ms: self
                .started_at
                .elapsed()
                .ok()
                .and_then(|elapsed| i64::try_from(elapsed.as_millis()).ok()),
            rows_affected,
            outcome,
        };
        history.record(entry, self.dialect).await;
    }
}

/// One entry carries the whole batch, because one save is what the
/// user did even when it took several statements.
fn join(statements: impl IntoIterator<Item = String>) -> String {
    let parts: Vec<String> = statements
        .into_iter()
        .map(|statement| statement.trim().trim_end_matches(';').to_owned())
        .filter(|statement| !statement.is_empty())
        .collect();
    match parts.is_empty() {
        true => String::new(),
        false => format!("{};", parts.join(";\n")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_batch_reads_as_one_statement_list() {
        let sql = join(["UPDATE t SET a = 1".to_owned(), "DELETE FROM t WHERE id = 2".to_owned()]);

        assert_eq!(sql, "UPDATE t SET a = 1;\nDELETE FROM t WHERE id = 2;");
    }

    #[test]
    fn a_statement_that_already_ends_in_a_semicolon_does_not_gain_a_second() {
        assert_eq!(join(["SELECT 1;".to_owned()]), "SELECT 1;");
    }

    #[tokio::test]
    async fn a_save_goes_through_the_history_gate() {
        use tokio::sync::watch;

        use crate::services::history_preferences::HistoryPreferences;

        let root = tempfile::tempdir().expect("tempdir");
        let paths = tablepro_storage::StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let (save, receiver) = watch::channel(true);
        let preferences = HistoryPreferences {
            retention_days: watch::channel(30).1,
            save: receiver,
        };
        let history = HistoryService::start(paths, preferences, &crate::test_support::paused_tasks());
        let dialect: Arc<dyn SqlDialect> = Arc::new(tablepro_test_support::FakeDialect);
        let connection = ConnectionMetadata {
            id: uuid::Uuid::new_v4(),
            name: "local".to_owned(),
            driver_id: "postgres".to_owned(),
        };
        let save_of = |sql: &str| {
            RanStatements::starting(
                Some(history.clone()),
                Some(connection.clone()),
                Some(dialect.clone()),
                [sql.to_owned()],
            )
        };

        save_of("UPDATE t SET a = 1").finished(Some(1), Outcome::Success).await;
        save_of("CREATE USER u PASSWORD 'p'")
            .finished(None, Outcome::Success)
            .await;
        save.send_replace(false);
        save_of("UPDATE t SET a = 2").finished(Some(1), Outcome::Success).await;

        let store = history.ready_store().await.expect("the store");
        let queries: Vec<String> = store
            .search(tablepro_storage::query_history::SearchFilter {
                limit: 100,
                ..Default::default()
            })
            .await
            .expect("search")
            .into_iter()
            .map(|entry| entry.query)
            .collect();
        assert_eq!(queries, vec!["UPDATE t SET a = 1;".to_owned()]);
    }

    #[test]
    fn an_empty_batch_records_nothing() {
        assert_eq!(join(Vec::<String>::new()), "");
        assert_eq!(join(["".to_owned(), "   ".to_owned()]), "");
    }
}
