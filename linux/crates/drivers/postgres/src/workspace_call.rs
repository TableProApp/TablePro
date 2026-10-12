use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use futures_util::{StreamExt, TryStreamExt};
use tablepro_core::column::ResultColumn;
use tablepro_core::statement::Statement;
use tablepro_core::{DriverError, QueryResult, RowLimit, Value, WorkspaceSettings};
use tokio::time::Instant;
use tokio_postgres::Client;

use crate::catalog::result_column;
use crate::codec::{RawCell, typed};
use crate::errors::map_error;
use crate::pg_call::PgCall;

pub(crate) type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What one workspace call does once it holds a connection inside its
/// transaction.
pub(crate) type ReadOp<T> = Box<dyn for<'a> FnOnce(&'a Client) -> BoxFuture<'a, Result<T, DriverError>> + Send>;

pub(crate) fn read_op<T, F>(op: F) -> ReadOp<T>
where
    F: for<'a> FnOnce(&'a Client) -> BoxFuture<'a, Result<T, DriverError>> + Send + 'static,
{
    Box::new(op)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Access {
    ReadOnly,
    ReadWrite,
}

/// The transaction a workspace call runs in, with its bounds set for
/// that transaction only. SET LOCAL ends with the transaction, so the
/// bounds reach the server through PgBouncer's transaction pooling and
/// leave nothing behind on a server connection other clients share.
///
/// `statement_timeout` of `None` sends 0, the server's "no limit". A
/// bound is never rendered as 0 otherwise, since that would lift it.
pub(crate) fn preamble(access: Access, statement_timeout: Option<Duration>, lock_timeout: Duration) -> String {
    let mode = match access {
        Access::ReadOnly => "READ ONLY",
        Access::ReadWrite => "READ WRITE",
    };
    let statement = statement_timeout.map_or(0, millis);
    format!(
        "START TRANSACTION {mode}; SET LOCAL statement_timeout = {statement}; SET LOCAL lock_timeout = {}",
        millis(lock_timeout)
    )
}

/// Whole milliseconds, at least one: a sub-millisecond remainder still
/// bounds the statement.
pub(crate) fn millis(duration: Duration) -> u128 {
    duration.as_millis().max(1)
}

/// The statement bound of a read: the call's deadline when it is nearer
/// than the workspace's own timeout.
pub(crate) fn statement_bound(settings: &WorkspaceSettings, deadline: Option<Instant>) -> Duration {
    let configured = settings.statement_timeout;
    match deadline {
        Some(deadline) => deadline.saturating_duration_since(Instant::now()).min(configured),
        None => configured,
    }
}

/// One pipelined flight: the transaction, the work and the COMMIT go out
/// together and their answers come back in order, so a read costs one
/// round trip. A failed step leaves the transaction aborted, and the
/// COMMIT then ends it as a rollback.
pub(crate) async fn flight<T>(call: &PgCall, preamble: &str, op: ReadOp<T>) -> Result<T, DriverError> {
    let client = call.client()?;
    let (begun, result, committed) = futures_util::join!(
        client.batch_execute(preamble),
        op(client),
        client.batch_execute("COMMIT")
    );
    if committed.is_err() {
        call.taint();
    }
    match (begun, result, committed) {
        (Err(error), _, _) => Err(map_error(&error)),
        (Ok(()), Err(error), _) => Err(error),
        (Ok(()), Ok(_), Err(error)) => Err(map_error(&error)),
        (Ok(()), Ok(value), Ok(())) => Ok(value),
    }
}

/// Read at most `limit` rows of a generated statement, and one more to
/// learn whether the result was cut short.
pub(crate) fn query_bound_op(statement: Statement, limit: RowLimit, begin: String) -> ReadOp<QueryResult> {
    read_op(move |client| {
        Box::pin(async move {
            let stream = client
                .query_typed_raw(statement.sql(), typed(statement.params()))
                .await
                .map_err(|error| map_error(&error))?;
            let mut stream = std::pin::pin!(stream);
            let mut columns = None;
            let mut rows = Vec::new();
            let mut truncated = false;
            while let Some(row) = stream.next().await {
                let row = row.map_err(|error| map_error(&error))?;
                if u64::try_from(rows.len()).is_ok_and(|kept| kept >= limit.get()) {
                    truncated = true;
                    break;
                }
                if columns.is_none() {
                    columns = Some(row.columns().iter().map(result_column).collect::<Vec<_>>());
                }
                rows.push(decode_row(&row)?);
            }
            let columns = match columns {
                Some(columns) => columns,
                None => describe_in_own_flight(client, &statement, &begin).await,
            };
            Ok(QueryResult::new(columns, rows).truncated(truncated))
        })
    })
}

/// The columns of a statement that returned no rows.
///
/// tokio-postgres keeps the RowDescription of an unnamed statement to
/// itself and hands columns out only with a row, and naming a statement
/// to describe it is what a pooler forbids. So the statement runs once
/// more as a subquery right-joined to one row on a false condition: one
/// row of NULLs, typed as its columns, and the planner skips the
/// subquery itself. The outer flight's COMMIT has already gone out, so
/// this one is its own read-only transaction.
async fn describe_in_own_flight(client: &Client, statement: &Statement, begin: &str) -> Vec<ResultColumn> {
    let (_, described, _) = futures_util::join!(
        client.batch_execute(begin),
        describe(client, statement),
        client.batch_execute("COMMIT")
    );
    described.unwrap_or_default()
}

pub(crate) async fn describe(client: &Client, statement: &Statement) -> Result<Vec<ResultColumn>, DriverError> {
    let sql = format!(
        "SELECT tablepro_described.* FROM ({}\n) AS tablepro_described \
         RIGHT JOIN (VALUES (1)) AS tablepro_one(one) ON false",
        statement.sql()
    );
    let rows: Vec<tokio_postgres::Row> = client
        .query_typed_raw(&sql, typed(statement.params()))
        .await
        .map_err(|error| map_error(&error))?
        .try_collect()
        .await
        .map_err(|error| map_error(&error))?;
    Ok(rows
        .first()
        .map(|row| row.columns().iter().map(result_column).collect())
        .unwrap_or_default())
}

pub(crate) fn count_op(statement: Statement) -> ReadOp<u64> {
    read_op(move |client| {
        Box::pin(async move {
            let stream = client
                .query_typed_raw(statement.sql(), typed(statement.params()))
                .await
                .map_err(|error| map_error(&error))?;
            let mut stream = std::pin::pin!(stream);
            let row = match stream.next().await {
                Some(row) => row.map_err(|error| map_error(&error))?,
                None => return Err(DriverError::Protocol("the count returned no row".to_owned())),
            };
            let RawCell(value) = row.try_get(0).map_err(|error| map_error(&error))?;
            value
                .as_exact_u64()
                .ok_or_else(|| DriverError::Protocol(format!("the count returned {value:?}")))
        })
    })
}

pub(crate) fn decode_row(row: &tokio_postgres::Row) -> Result<Vec<Value>, DriverError> {
    (0..row.len())
        .map(|index| {
            row.try_get::<_, RawCell>(index)
                .map(|cell| cell.0)
                .map_err(|error| map_error(&error))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preamble_uses_integer_milliseconds() {
        let preamble = preamble(
            Access::ReadOnly,
            Some(Duration::from_millis(1_500)),
            Duration::from_secs(10),
        );

        assert_eq!(
            preamble,
            "START TRANSACTION READ ONLY; SET LOCAL statement_timeout = 1500; SET LOCAL lock_timeout = 10000"
        );
    }

    #[test]
    fn a_sub_millisecond_bound_never_renders_as_zero() {
        let preamble = preamble(Access::ReadWrite, Some(Duration::from_micros(300)), Duration::ZERO);

        assert!(preamble.contains("statement_timeout = 1;"), "{preamble}");
        assert!(preamble.ends_with("lock_timeout = 1"), "{preamble}");
        assert!(preamble.starts_with("START TRANSACTION READ WRITE"));
    }

    #[test]
    fn an_unbounded_schema_change_sends_the_servers_no_limit() {
        assert!(preamble(Access::ReadWrite, None, Duration::from_secs(10)).contains("statement_timeout = 0;"));
    }

    #[tokio::test(start_paused = true)]
    async fn a_near_deadline_tightens_the_bound() {
        let settings = WorkspaceSettings::workspace(false);

        assert_eq!(statement_bound(&settings, None), WorkspaceSettings::STATEMENT_TIMEOUT);
        let near = Instant::now() + Duration::from_secs(2);
        assert_eq!(statement_bound(&settings, Some(near)), Duration::from_secs(2));
    }
}
