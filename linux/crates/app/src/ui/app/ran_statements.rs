use std::time::SystemTime;

use tablepro_storage::QueryHistory;
use tablepro_storage::query_history::{NewEntry, Outcome};

use crate::services::database_service;

/// What the app needs to record a statement batch it ran on the user's
/// behalf.
///
/// A row save and a structure save change the database as surely as a
/// statement typed into the editor does, so the history that answers
/// "what did this to my table" has to carry them too. It is captured
/// before the work starts, because the connection can be gone by the
/// time the answer comes back.
#[derive(Debug, Clone)]
pub(super) struct RanStatements {
    history: Option<QueryHistory>,
    connection: Option<Connection>,
    sql: String,
    started_at: SystemTime,
}

#[derive(Debug, Clone)]
struct Connection {
    id: uuid::Uuid,
    name: String,
    driver_id: String,
}

impl RanStatements {
    /// Capture the batch about to run. `sql` reads as one entry in the
    /// history list, which is how the user thinks of one save.
    pub(super) fn starting(history: Option<QueryHistory>, statements: impl IntoIterator<Item = String>) -> Self {
        let connection = database_service::instance()
            .active_metadata()
            .map(|metadata| Connection {
                id: metadata.id,
                name: metadata.name,
                driver_id: metadata.driver_id,
            });
        Self {
            history,
            connection,
            sql: join(statements),
            started_at: SystemTime::now(),
        }
    }

    /// Record how it went. Does nothing when the history is closed or
    /// the batch was empty, and never fails the save it describes: a
    /// history that cannot be written is worth a log line, not a lost
    /// edit.
    pub(super) async fn finished(self, rows_affected: Option<i64>, outcome: Outcome) {
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
        if let Err(error) = history.record(entry).await {
            tracing::warn!(%error, "could not record the statements in history");
        }
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

    #[test]
    fn an_empty_batch_records_nothing() {
        assert_eq!(join(Vec::<String>::new()), "");
        assert_eq!(join(["".to_owned(), "   ".to_owned()]), "");
    }
}
