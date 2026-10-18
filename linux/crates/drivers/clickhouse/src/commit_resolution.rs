//! What became of a write whose answer never arrived, read from the
//! server's own records of the queries it ran.
//!
//! An ALTER runs its mutation wait inside the interpreter, so while it
//! waits the query log has no entry for it at all, and a wait that fails
//! is logged as ExceptionBeforeStart with no table named. The statement
//! is therefore looked for in `system.processes` too, and its mutation in
//! `system.mutations` by table and creation time when its ALTER failed
//! while the mutation may live on. The table comes from the write itself
//! when the log names none. `system.mutations` has no column linking a
//! mutation to its ALTER, so any doubt is Unresolvable.

use tablepro_core::meta::TableRef;
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

/// What the log says, or what else to ask.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LogVerdict {
    Resolved(CommitResolution),
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

/// `listed` is whether `system.processes` held the statement before the
/// log was flushed. The server queues a statement's last log entry
/// before it takes the statement off that list, so a statement in
/// neither is one the server cannot account for.
pub(crate) fn read_log(entries: &[LogEntry], listed: bool) -> LogVerdict {
    let find = |event: &str| entries.iter().find(|entry| entry.event == event);
    if find("QueryFinish").is_some() {
        return LogVerdict::Resolved(CommitResolution::Applied);
    }
    let before_start = find("ExceptionBeforeStart");
    let failed = before_start.or_else(|| find("ExceptionWhileProcessing"));
    let Some(failed) = failed else {
        return LogVerdict::Resolved(if listed {
            CommitResolution::StillRunning
        } else {
            CommitResolution::Unresolvable
        });
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

/// The table to look for the mutation in: the log's where it names one,
/// otherwise the one the write was for. Searching every table instead
/// would take another session's mutation in the same seconds for this
/// one.
pub(crate) fn mutation_table(logged: Option<MutatedTable>, written: &TableRef) -> Option<MutatedTable> {
    logged.or_else(|| {
        Some(MutatedTable {
            database: written.schema.clone().filter(|database| !database.is_empty())?,
            table: written.name.clone(),
        })
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

/// The statement a resolution asks about: the first one the write could
/// not confirm.
struct Unconfirmed<'a> {
    query_id: Uuid,
    index: usize,
    statements: usize,
    written: &'a TableRef,
}

impl<'a> Unconfirmed<'a> {
    fn of(token: &'a CommitToken) -> Option<Self> {
        let CommitToken::ClickHouseQuery {
            query_ids,
            first_unconfirmed,
            table,
        } = token
        else {
            return None;
        };
        Some(Self {
            query_id: *query_ids.get(*first_unconfirmed)?,
            index: *first_unconfirmed,
            statements: query_ids.len(),
            written: table,
        })
    }
}

/// Ask the server about the first statement a write could not confirm.
///
/// The process list is read before the log is flushed, so a statement
/// that ends between the two reads is either still listed or has its end
/// in the flushed log. Read the other way round, it would be in neither.
pub(crate) async fn resolve(calls: &CallClient, token: &CommitToken) -> Result<CommitResolution, DriverError> {
    let Some(statement) = Unconfirmed::of(token) else {
        return Ok(CommitResolution::Unresolvable);
    };
    let listed = listed(calls, statement.query_id).await?;
    from_log(calls, &statement, listed).await
}

async fn from_log(
    calls: &CallClient,
    statement: &Unconfirmed<'_>,
    listed: bool,
) -> Result<CommitResolution, DriverError> {
    match drain(calls.raw("SYSTEM FLUSH LOGS")?).await {
        Ok(_) => {}
        Err(error) if server_code(&error) == Some(code::ACCESS_DENIED) => {}
        Err(error) => return Err(error),
    }
    let entries = match log_entries(calls, statement.query_id).await {
        Ok(entries) => entries,
        Err(error) if matches!(server_code(&error), Some(code::ACCESS_DENIED | UNKNOWN_TABLE)) => {
            return Ok(CommitResolution::Unresolvable);
        }
        Err(error) => return Err(error),
    };
    let resolution = match read_log(&entries, listed) {
        LogVerdict::Resolved(resolution) => resolution,
        LogVerdict::Mutation { table, started, ended } => match mutation_table(table, statement.written) {
            Some(table) => mutation(calls, &table, &started, &ended).await?,
            None => CommitResolution::Unresolvable,
        },
    };
    Ok(compose(statement.index, statement.statements, resolution))
}

async fn log_entries(calls: &CallClient, query_id: Uuid) -> Result<Vec<LogEntry>, DriverError> {
    let query = calls.raw(LOG_SELECT)?.param("id", query_id.to_string());
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

/// The stock config's `select_from_system_db_requires_grant` refuses
/// `system.processes` to a login without a grant. Such a login learns
/// nothing here, which leaves the log to answer.
async fn listed(calls: &CallClient, query_id: Uuid) -> Result<bool, DriverError> {
    let query = calls
        .raw("SELECT count() FROM system.processes WHERE query_id = {id:String}")?
        .param("id", query_id.to_string());
    let result = match read_table(query, None).await {
        Ok(result) => result,
        Err(error) if server_code(&error) == Some(code::ACCESS_DENIED) => return Ok(false),
        Err(error) => return Err(error),
    };
    let running = result
        .rows
        .first()
        .and_then(|row| row.first())
        .and_then(Value::as_exact_u64)
        .unwrap_or(0);
    Ok(running > 0)
}

async fn mutation(
    calls: &CallClient,
    table: &MutatedTable,
    started: &str,
    ended: &str,
) -> Result<CommitResolution, DriverError> {
    let query = calls
        .raw(
            "SELECT is_done FROM system.mutations WHERE database = {db:String} AND table = {tbl:String} \
             AND create_time >= {started:DateTime} AND create_time <= {ended:DateTime}",
        )?
        .param("db", table.database.as_str())
        .param("tbl", table.table.as_str())
        .param("started", started)
        .param("ended", ended);
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
    use std::sync::Arc;
    use std::time::Duration;

    use tablepro_core::StopRequest;
    use tablepro_test_fixtures::ClickHouseFixture;
    use tablepro_test_support::conformance::test_liveness;
    use tokio::time::Instant;

    use super::*;
    use crate::cancel::ClickHouseStop;
    use crate::endpoint::ClickHouseEndpoint;

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

    /// A logged end answers the same whatever the list said.
    fn ended(entries: &[LogEntry]) -> LogVerdict {
        let verdict = read_log(entries, true);
        assert_eq!(read_log(entries, false), verdict, "{entries:?}");
        verdict
    }

    fn resolved(entries: &[LogEntry]) -> Option<CommitResolution> {
        match ended(entries) {
            LogVerdict::Resolved(resolution) => Some(resolution),
            LogVerdict::Mutation { .. } => None,
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

        for kind in ["Insert", "Alter", "Create"] {
            assert_eq!(
                resolved(&[entry("QueryStart", kind, 0), entry("QueryFinish", kind, 0)]),
                Some(Applied),
                "{kind} finished"
            );
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
            ended(&[
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
                ended(&[failed]),
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
    fn with_no_logged_end_the_list_answers() {
        use CommitResolution::{StillRunning, Unresolvable};
        let start = entry("QueryStart", "Alter", 0);

        assert_eq!(
            read_log(&[], true),
            LogVerdict::Resolved(StillRunning),
            "an ALTER still waiting logs nothing"
        );
        assert_eq!(
            read_log(std::slice::from_ref(&start), true),
            LogVerdict::Resolved(StillRunning),
            "only started"
        );
        assert_eq!(
            read_log(&[], false),
            LogVerdict::Resolved(Unresolvable),
            "neither listed nor logged"
        );
        assert_eq!(
            read_log(&[start], false),
            LogVerdict::Resolved(Unresolvable),
            "off the list with no end queued"
        );
    }

    #[test]
    fn a_mutation_is_looked_for_in_the_logged_table_then_the_written_one() {
        let written = TableRef::new(Some("tablepro".to_owned()), "orders");
        let orders = Some(MutatedTable {
            database: "tablepro".to_owned(),
            table: "orders".to_owned(),
        });

        assert_eq!(mutation_table(events_table(), &written), events_table());
        assert_eq!(
            mutation_table(None, &written),
            orders,
            "an ALTER whose wait failed names no table"
        );
        assert_eq!(
            mutation_table(None, &TableRef::unqualified("orders")),
            None,
            "a table without its database could be any database's"
        );
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

    async fn wait_until_listed(calls: &CallClient, query_id: Uuid, listing: bool) -> bool {
        let give_up = Instant::now() + Duration::from_secs(10);
        while listed(calls, query_id).await.expect("the process list") != listing {
            assert!(Instant::now() < give_up, "listed stayed {}", !listing);
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        listing
    }

    /// Stopped merges hold the ALTER in its mutation wait while the list
    /// is read, and it ends before the log is. The old order, log then
    /// list, found it in neither and answered Unresolvable.
    #[tokio::test]
    #[ignore = "requires docker"]
    async fn an_alter_that_ends_between_the_list_and_the_log_is_applied() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let endpoint = ClickHouseEndpoint::for_fixture(&fixture, test_liveness());
        let client = endpoint.workspace();
        for sql in [
            "CREATE TABLE held (id Int32, n Int32) ENGINE = MergeTree ORDER BY id",
            "INSERT INTO held VALUES (1, 0)",
            "SYSTEM STOP MERGES held",
        ] {
            client.query(sql).execute().await.expect(sql);
        }
        let query_id = Uuid::new_v4();
        let altering = tokio::spawn(
            client
                .query("ALTER TABLE held UPDATE n = 1 WHERE 1")
                .with_setting("query_id", query_id.to_string())
                .execute(),
        );
        let control = endpoint.control().clone();
        let calls = CallClient::new(
            control.clone(),
            Arc::new(ClickHouseStop::new(control)),
            StopRequest::new(),
        );
        let token = CommitToken::ClickHouseQuery {
            query_ids: vec![query_id],
            first_unconfirmed: 0,
            table: TableRef::new(Some("tablepro".to_owned()), "held"),
        };
        let statement = Unconfirmed::of(&token).expect("a ClickHouse token");

        let listed = wait_until_listed(&calls, query_id, true).await;
        assert_eq!(resolve(&calls, &token).await, Ok(CommitResolution::StillRunning));
        client
            .query("SYSTEM START MERGES held")
            .execute()
            .await
            .expect("the merges");
        altering.await.expect("the ALTER task").expect("the ALTER");
        wait_until_listed(&calls, query_id, false).await;

        assert_eq!(
            from_log(&calls, &statement, listed).await,
            Ok(CommitResolution::Applied)
        );
    }
}
