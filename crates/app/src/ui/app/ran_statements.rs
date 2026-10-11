use std::time::{Instant, SystemTime};

use tablepro_core::Value;
use tablepro_storage::query_history::{HistoryStore, NewEntry, Outcome, Source};

use crate::services::database_service::ConnectionMetadata;

use super::App;

pub(super) fn combined_sql(statements: &[String]) -> Option<String> {
    let joined = statements
        .iter()
        .map(|sql| sql.trim())
        .filter(|sql| !sql.is_empty())
        .collect::<Vec<_>>()
        .join(";\n");
    if joined.is_empty() { None } else { Some(joined) }
}

pub(super) fn sql_without_parameters(statements: &[(String, Vec<Value>)]) -> Vec<String> {
    statements.iter().map(|(sql, _)| sql.clone()).collect()
}

pub(super) fn new_entry(
    metadata: &ConnectionMetadata,
    source: Source,
    sql: String,
    started_at: SystemTime,
    duration_ms: i64,
    outcome: Outcome,
) -> NewEntry {
    NewEntry {
        query: sql,
        driver_id: metadata.driver_id.clone(),
        connection_id: metadata.id,
        connection_name: metadata.name.clone(),
        executed_at: started_at,
        duration_ms: Some(duration_ms),
        rows_affected: None,
        outcome,
        source,
    }
}

pub(super) struct RanStatements {
    store: HistoryStore,
    metadata: ConnectionMetadata,
    source: Source,
    sql: String,
    started_at: SystemTime,
    clock: Instant,
}

impl RanStatements {
    pub(super) async fn finish(self, outcome: Outcome) {
        let duration_ms = self.clock.elapsed().as_millis().min(i64::MAX as u128) as i64;
        let entry = new_entry(
            &self.metadata,
            self.source,
            self.sql,
            self.started_at,
            duration_ms,
            outcome,
        );
        if let Err(e) = self.store.record(entry).await {
            tracing::warn!(error = %e, "history record failed");
        }
    }
}

impl App {
    pub(super) fn ran_statements(&self, source: Source, statements: &[String]) -> Option<RanStatements> {
        let store = self.history.clone()?;
        let metadata = self.window_metadata()?;
        let sql = combined_sql(statements)?;
        Some(RanStatements {
            store,
            metadata,
            source,
            sql,
            started_at: SystemTime::now(),
            clock: Instant::now(),
        })
    }
}

pub(super) async fn finish_if_recorded(recorded: &mut Option<RanStatements>, outcome: Outcome) {
    if let Some(recorded) = recorded.take() {
        recorded.finish(outcome).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::Value;

    fn metadata() -> ConnectionMetadata {
        ConnectionMetadata {
            id: uuid::Uuid::nil(),
            name: "local".into(),
            driver_id: "postgres".into(),
            environment: tablepro_core::Environment::Local,
            read_only: false,
            server_version: None,
            query_timeout_secs: None,
        }
    }

    #[test]
    fn a_browse_transaction_records_the_statement_text_and_never_its_parameters() {
        let statements = vec![(
            "UPDATE people SET email = ? WHERE id = ?".to_string(),
            vec![Value::Text("secret@example.com".into()), Value::Int(7)],
        )];

        let sql = sql_without_parameters(&statements);
        let recorded = combined_sql(&sql).unwrap();

        assert_eq!(recorded, "UPDATE people SET email = ? WHERE id = ?");
        assert!(!recorded.contains("secret@example.com"));
        assert!(!recorded.contains('7'));
    }

    #[test]
    fn several_statements_are_recorded_as_one_script() {
        let statements = vec!["ALTER TABLE t ADD COLUMN a INT".into(), "DROP INDEX i".into()];

        assert_eq!(
            combined_sql(&statements).unwrap(),
            "ALTER TABLE t ADD COLUMN a INT;\nDROP INDEX i"
        );
    }

    #[test]
    fn an_empty_batch_records_nothing() {
        assert_eq!(combined_sql(&[]), None);
        assert_eq!(combined_sql(&["   ".to_string()]), None);
    }

    #[test]
    fn a_recorded_entry_carries_the_connection_and_its_source() {
        let entry = new_entry(
            &metadata(),
            Source::Structure,
            "DROP TABLE t".into(),
            SystemTime::UNIX_EPOCH,
            12,
            Outcome::Success,
        );

        assert_eq!(entry.source, Source::Structure);
        assert_eq!(entry.driver_id, "postgres");
        assert_eq!(entry.connection_name, "local");
        assert_eq!(entry.duration_ms, Some(12));
    }
}
