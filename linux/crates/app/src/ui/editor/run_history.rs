use std::time::SystemTime;

use tablepro_session::ConnectionMetadata;
use tablepro_storage::query_history::{NewEntry, Outcome};

use super::run_log::RunLog;

/// The history line for one press of Run: the SQL that was sent, which
/// is the selection when there was one, and how the run ended.
pub fn history_entry(query: String, metadata: &ConnectionMetadata, executed_at: SystemTime, log: &RunLog) -> NewEntry {
    let outcome = if let Some(message) = log.first_failure() {
        Outcome::Error(message.to_owned())
    } else if log.timed_out() {
        Outcome::Error(crate::i18n::gettext(
            "The statement ran past the time limit set in Preferences.",
        ))
    } else if log.was_stopped() {
        Outcome::Cancelled
    } else {
        Outcome::Success
    };
    let duration_ms = SystemTime::now()
        .duration_since(executed_at)
        .ok()
        .and_then(|elapsed| i64::try_from(elapsed.as_millis()).ok());
    NewEntry {
        query,
        driver_id: metadata.driver_id.clone(),
        connection_id: metadata.id,
        connection_name: metadata.name.clone(),
        executed_at,
        duration_ms,
        rows_affected: log.rows_for_history(),
        outcome,
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::super::run_log::{BatchReport, EntryKind, RunEvent, Verdict};
    use super::*;

    fn metadata() -> ConnectionMetadata {
        ConnectionMetadata {
            id: Uuid::new_v4(),
            name: "Prod".to_owned(),
            driver_id: "postgres".to_owned(),
        }
    }

    fn log_of(entries: Vec<EntryKind>, verdict: Verdict) -> RunLog {
        let mut log = RunLog::new(vec!["SELECT 2".to_owned()], Vec::new());
        log.apply(RunEvent::Batch(BatchReport {
            batch: 0,
            entries,
            verdict,
            transaction: None,
            lost: false,
            elapsed_ms: 1,
        }));
        log.apply(RunEvent::Finished);
        log
    }

    #[test]
    fn history_records_executed_selection() {
        let log = log_of(vec![EntryKind::Command { rows_affected: Some(3) }], Verdict::Completed);
        let metadata = metadata();

        let entry = history_entry("SELECT 2".to_owned(), &metadata, SystemTime::now(), &log);

        assert_eq!(entry.query, "SELECT 2");
        assert_eq!(entry.connection_id, metadata.id);
        assert_eq!(entry.rows_affected, Some(3));
        assert_eq!(entry.outcome, Outcome::Success);
    }

    #[test]
    fn a_failure_or_a_stop_is_what_history_remembers() {
        let failed = log_of(
            vec![EntryKind::Failed {
                message: "boom".to_owned(),
                error_char: None,
            }],
            Verdict::Failed,
        );
        let stopped = log_of(vec![EntryKind::Cancelled], Verdict::Stopped);

        let metadata = metadata();
        assert_eq!(
            history_entry(String::new(), &metadata, SystemTime::now(), &failed).outcome,
            Outcome::Error("boom".to_owned())
        );
        assert_eq!(
            history_entry(String::new(), &metadata, SystemTime::now(), &stopped).outcome,
            Outcome::Cancelled
        );
    }
}
