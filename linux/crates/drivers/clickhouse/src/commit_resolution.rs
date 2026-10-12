//! What became of a write whose answer never arrived, read from the
//! server's own records of the queries it ran.
//!
//! An ALTER runs its mutation wait inside the interpreter, so while it
//! waits the query log has no entry for it at all, and a wait that fails
//! is logged as ExceptionBeforeStart with no table named. The statement
//! is therefore looked for in `system.processes` when the log is silent,
//! and its mutation in `system.mutations` by creation time when its ALTER
//! failed while the mutation may live on. `system.mutations` has no
//! column linking a mutation to its ALTER, so any doubt is Unresolvable.

use tablepro_core::{CommitResolution, CommitToken, DriverError, Value};
use uuid::Uuid;

use crate::call_client::CallClient;
use crate::errors::{code, server_code};
use crate::result_reader::{CatalogRow, drain, read_table};

const LOG_SELECT: &str = "SELECT toString(type), query_kind, exception_code, databases, tables, \
     toString(query_start_time), toString(event_time) FROM system.query_log \
     WHERE event_date >= today() - 1 AND query_id = {id:String}";

/// `UNKNOWN_TABLE`: the server runs without a query log.
const UNKNOWN_TABLE: i32 = 60;

/// One `system.query_log` entry of the statement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LogEntry {
    pub(crate) event: String,
    pub(crate) query_kind: String,
    pub(crate) exception_code: i32,
    pub(crate) databases: Vec<String>,
    pub(crate) tables: Vec<String>,
    pub(crate) started: String,
    pub(crate) ended: String,
}

/// The table a mutation is looked for in, where the log names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MutatedTable {
    pub(crate) database: String,
    pub(crate) table: String,
}

/// What the log alone says, or what else to ask.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LogVerdict {
    Resolved(CommitResolution),
    /// Nothing says the statement ended, so only the server's list of
    /// running queries can tell whether it is still going.
    NotEnded,
    /// A mutation's ALTER failed while the mutation may live on.
    Mutation {
        table: Option<MutatedTable>,
        started: String,
        ended: String,
    },
}

/// Codes that end an ALTER's wait without saying anything about the
/// mutation it started: cancelled, timed out, or the wait gave up.
fn mutation_may_live_on(exception_code: i32) -> bool {
    matches!(
        exception_code,
        code::QUERY_WAS_CANCELLED
            | code::TIMEOUT_EXCEEDED
            | code::UNFINISHED
            | code::SOCKET_TIMEOUT
            | code::NETWORK_ERROR
    )
}

pub(crate) fn read_log(entries: &[LogEntry]) -> LogVerdict {
    let find = |event: &str| entries.iter().find(|entry| entry.event == event);
    if find("QueryFinish").is_some() {
        return LogVerdict::Resolved(CommitResolution::Applied);
    }
    let before_start = find("ExceptionBeforeStart");
    let failed = before_start.or_else(|| find("ExceptionWhileProcessing"));
    let Some(failed) = failed else {
        return LogVerdict::NotEnded;
    };
    let mutation =
        failed.query_kind == "Alter" && (before_start.is_none() || mutation_may_live_on(failed.exception_code));
    if mutation {
        return LogVerdict::Mutation {
            table: mutated_table(failed),
            started: failed.started.clone(),
            ended: failed.ended.clone(),
        };
    }
    if before_start.is_some() {
        return LogVerdict::Resolved(CommitResolution::NotApplied);
    }
    // An INSERT that failed part way may have written some of its blocks.
    LogVerdict::Resolved(CommitResolution::Unresolvable)
}

fn mutated_table(entry: &LogEntry) -> Option<MutatedTable> {
    let database = entry.databases.first()?;
    let table = entry.tables.first()?.strip_prefix(&format!("{database}."))?;
    Some(MutatedTable {
        database: database.clone(),
        table: table.to_owned(),
    })
}

/// One mutation in the window is the ALTER's; none means someone ran
/// KILL MUTATION, which removes the row but keeps the parts it already
/// changed, and more than one cannot be told apart.
pub(crate) fn read_mutations(done: &[bool]) -> CommitResolution {
    match done {
        [true] => CommitResolution::Applied,
        [false] => CommitResolution::StillRunning,
        _ => CommitResolution::Unresolvable,
    }
}

/// The batch's answer from its first unconfirmed statement's: work
/// confirmed before it, or statements never sent after it, make a
/// whole answer partial.
pub(crate) fn compose(first_unconfirmed: usize, statements: usize, statement: CommitResolution) -> CommitResolution {
    match statement {
        CommitResolution::NotApplied if first_unconfirmed > 0 => CommitResolution::PartiallyApplied,
        CommitResolution::Applied if first_unconfirmed + 1 < statements => CommitResolution::PartiallyApplied,
        other => other,
    }
}

/// Ask the server about the first statement a write could not confirm.
pub(crate) async fn resolve(calls: &CallClient, token: &CommitToken) -> Result<CommitResolution, DriverError> {
    let CommitToken::ClickHouseQuery {
        query_ids,
        first_unconfirmed,
    } = token
    else {
        return Ok(CommitResolution::Unresolvable);
    };
    let Some(query_id) = query_ids.get(*first_unconfirmed) else {
        return Ok(CommitResolution::Unresolvable);
    };
    match drain(calls.raw("SYSTEM FLUSH LOGS")).await {
        Ok(_) => {}
        Err(error) if server_code(&error) == Some(code::ACCESS_DENIED) => {}
        Err(error) => return Err(error),
    }
    let entries = match log_entries(calls, *query_id).await {
        Ok(entries) => entries,
        Err(error) if matches!(server_code(&error), Some(code::ACCESS_DENIED | UNKNOWN_TABLE)) => {
            return Ok(CommitResolution::Unresolvable);
        }
        Err(error) => return Err(error),
    };
    let statement = match read_log(&entries) {
        LogVerdict::Resolved(resolution) => resolution,
        LogVerdict::NotEnded => still_running(calls, *query_id).await?,
        LogVerdict::Mutation { table, started, ended } => mutation(calls, table.as_ref(), &started, &ended).await?,
    };
    Ok(compose(*first_unconfirmed, query_ids.len(), statement))
}

async fn log_entries(calls: &CallClient, query_id: Uuid) -> Result<Vec<LogEntry>, DriverError> {
    let query = calls.raw(LOG_SELECT).param("id", query_id.to_string());
    let result = read_table(query, None).await?;
    result
        .rows
        .iter()
        .map(|row| {
            let row = CatalogRow(row);
            Ok(LogEntry {
                event: row.text(0)?,
                query_kind: row.text(1)?,
                exception_code: row.integer(2)?,
                databases: row.texts(3)?,
                tables: row.texts(4)?,
                started: row.text(5)?,
                ended: row.text(6)?,
            })
        })
        .collect()
}

/// Logged as started and never ended: still running if the server still
/// lists it, and lost otherwise.
async fn still_running(calls: &CallClient, query_id: Uuid) -> Result<CommitResolution, DriverError> {
    let query = calls
        .raw("SELECT count() FROM system.processes WHERE query_id = {id:String}")
        .param("id", query_id.to_string());
    let result = read_table(query, None).await?;
    let running = result
        .rows
        .first()
        .and_then(|row| row.first())
        .and_then(Value::as_exact_u64)
        .unwrap_or(0);
    Ok(if running > 0 {
        CommitResolution::StillRunning
    } else {
        CommitResolution::Unresolvable
    })
}

async fn mutation(
    calls: &CallClient,
    table: Option<&MutatedTable>,
    started: &str,
    ended: &str,
) -> Result<CommitResolution, DriverError> {
    let window = "create_time >= {started:DateTime} AND create_time <= {ended:DateTime}";
    let query = match table {
        Some(table) => calls
            .raw(&format!(
                "SELECT is_done FROM system.mutations WHERE database = {{db:String}} AND table = {{tbl:String}} AND {window}"
            ))
            .param("db", table.database.as_str())
            .param("tbl", table.table.as_str()),
        None => calls.raw(&format!("SELECT is_done FROM system.mutations WHERE {window}")),
    };
    let query = query.param("started", started).param("ended", ended);
    let result = read_table(query, None).await?;
    let done = result
        .rows
        .iter()
        .map(|row| CatalogRow(row).flag(0))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(read_mutations(&done))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(event: &str, query_kind: &str, exception_code: i32) -> LogEntry {
        LogEntry {
            event: event.to_owned(),
            query_kind: query_kind.to_owned(),
            exception_code,
            databases: vec!["tablepro".to_owned()],
            tables: vec!["tablepro.events".to_owned()],
            started: "2026-10-12 08:00:00".to_owned(),
            ended: "2026-10-12 08:00:05".to_owned(),
        }
    }

    fn resolved(entries: &[LogEntry]) -> Option<CommitResolution> {
        match read_log(entries) {
            LogVerdict::Resolved(resolution) => Some(resolution),
            _ => None,
        }
    }

    fn mutation(table: Option<MutatedTable>) -> LogVerdict {
        LogVerdict::Mutation {
            table,
            started: "2026-10-12 08:00:00".to_owned(),
            ended: "2026-10-12 08:00:05".to_owned(),
        }
    }

    fn events_table() -> Option<MutatedTable> {
        Some(MutatedTable {
            database: "tablepro".to_owned(),
            table: "events".to_owned(),
        })
    }

    #[test]
    fn mapping_table() {
        use CommitResolution::{Applied, NotApplied, StillRunning, Unresolvable};

        assert_eq!(
            read_log(&[]),
            LogVerdict::NotEnded,
            "an ALTER still waiting logs nothing"
        );
        for kind in ["Insert", "Alter", "Create"] {
            let start = entry("QueryStart", kind, 0);
            assert_eq!(
                resolved(&[start.clone(), entry("QueryFinish", kind, 0)]),
                Some(Applied),
                "{kind} finished"
            );
            assert_eq!(read_log(&[start]), LogVerdict::NotEnded, "{kind} only started");
            assert_eq!(
                resolved(&[entry("ExceptionBeforeStart", kind, 62)]),
                Some(NotApplied),
                "{kind} refused before it ran"
            );
        }
        assert_eq!(
            resolved(&[
                entry("QueryStart", "Insert", 0),
                entry("ExceptionWhileProcessing", "Insert", 394)
            ]),
            Some(Unresolvable),
            "an INSERT that failed part way"
        );
        assert_eq!(
            resolved(&[entry("ExceptionBeforeStart", "Insert", 394)]),
            Some(NotApplied),
            "an INSERT stopped before it ran"
        );
        assert_eq!(
            resolved(&[entry("ExceptionWhileProcessing", "Create", 241)]),
            Some(Unresolvable),
            "a failed statement that is not a mutation"
        );
        assert_eq!(
            read_log(&[
                entry("QueryStart", "Alter", 0),
                entry("ExceptionWhileProcessing", "Alter", 241)
            ]),
            mutation(events_table())
        );
        for code in [394, 159, 341, 209, 210] {
            let mut failed = entry("ExceptionBeforeStart", "Alter", code);
            failed.databases.clear();
            failed.tables.clear();
            assert_eq!(
                read_log(&[failed]),
                mutation(None),
                "an ALTER whose wait ended with {code}"
            );
        }

        let mutation_rows: [(&[bool], CommitResolution); 5] = [
            (&[], Unresolvable),
            (&[true], Applied),
            (&[false], StillRunning),
            (&[true, false], Unresolvable),
            (&[true, true], Unresolvable),
        ];
        for (done, expected) in mutation_rows {
            assert_eq!(read_mutations(done), expected, "{done:?}");
        }
    }

    #[test]
    fn a_statement_answer_composes_over_the_batch() {
        use CommitResolution::{Applied, NotApplied, PartiallyApplied, StillRunning, Unresolvable};

        assert_eq!(compose(0, 1, Applied), Applied);
        assert_eq!(compose(0, 1, NotApplied), NotApplied);
        assert_eq!(
            compose(1, 2, NotApplied),
            PartiallyApplied,
            "an earlier statement landed"
        );
        assert_eq!(
            compose(0, 3, Applied),
            PartiallyApplied,
            "later statements were never sent"
        );
        assert_eq!(
            compose(2, 3, Applied),
            Applied,
            "the last statement completed the batch"
        );
        assert_eq!(compose(1, 3, StillRunning), StillRunning);
        assert_eq!(compose(1, 3, Unresolvable), Unresolvable);
    }
}
