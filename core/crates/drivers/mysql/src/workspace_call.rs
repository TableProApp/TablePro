use futures_util::TryStreamExt;
use futures_util::future::BoxFuture;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Executor as _, Row as _, SqlSafeStr as _, Statement as _};
use tablepro_core::column::ResultColumn;
use tablepro_core::statement::Statement;
use tablepro_core::{DriverError, QueryResult, RowLimit};

use crate::catalog::result_column;
use crate::decode::decode_row;
use crate::encode::{MySqlQuery, bind_all};
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;

/// What one workspace call does once it holds a connection.
pub(crate) type ReadOp<T> =
    Box<dyn for<'c> FnOnce(&'c mut MySqlConnection, MySqlFlavour) -> BoxFuture<'c, Result<T, DriverError>> + Send>;

pub(crate) fn read_op<T, F>(op: F) -> ReadOp<T>
where
    F: for<'c> FnOnce(&'c mut MySqlConnection, MySqlFlavour) -> BoxFuture<'c, Result<T, DriverError>> + Send + 'static,
{
    Box::new(op)
}

/// A generated statement as a prepared statement, never cached: it is
/// closed on the server as soon as it has run.
pub(crate) fn prepared(statement: &Statement) -> Result<MySqlQuery<'static>, DriverError> {
    bind_all(
        sqlx::query(AssertSqlSafe(statement.sql().to_owned())).persistent(false),
        statement.params(),
    )
}

/// Read at most `limit` rows, and one more to learn whether the result
/// was cut short. The rest of the result stays unread on the wire and
/// sqlx drains it before the connection's next command.
pub(crate) fn query_bound_op(statement: Statement, limit: RowLimit) -> ReadOp<QueryResult> {
    read_op(move |connection, flavour| {
        Box::pin(async move { query_bound(connection, flavour, &statement, limit).await })
    })
}

pub(crate) async fn query_bound(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    statement: &Statement,
    limit: RowLimit,
) -> Result<QueryResult, DriverError> {
    let query = prepared(statement)?;
    let mut columns = None;
    let mut rows = Vec::new();
    let mut truncated = false;
    {
        let mut stream = query.fetch(&mut *connection);
        while let Some(row) = stream.try_next().await.map_err(|error| map_error(&error, flavour))? {
            if u64::try_from(rows.len()).is_ok_and(|kept| kept >= limit.get()) {
                truncated = true;
                break;
            }
            if columns.is_none() {
                columns = Some(
                    row.columns()
                        .iter()
                        .map(|column| result_column(column, MySqlTimestampMode::WorkspaceUtc))
                        .collect::<Vec<_>>(),
                );
            }
            rows.push(decode_row(
                &row,
                MySqlWireFormat::Binary,
                MySqlTimestampMode::WorkspaceUtc,
            ));
        }
    }
    let columns = match columns {
        Some(columns) => columns,
        None => describe(connection, flavour, statement.sql()).await?,
    };
    Ok(QueryResult::new(columns, rows).truncated(truncated))
}

/// The columns of a statement that returned no rows: the prepare
/// carries them, and with no cache the statement is closed right after.
pub(crate) async fn describe(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    sql: &str,
) -> Result<Vec<ResultColumn>, DriverError> {
    let prepared = (&mut *connection)
        .prepare(AssertSqlSafe(sql.to_owned()).into_sql_str())
        .await
        .map_err(|error| map_error(&error, flavour))?;
    Ok(prepared
        .columns()
        .iter()
        .map(|column| result_column(column, MySqlTimestampMode::WorkspaceUtc))
        .collect())
}

pub(crate) fn count_op(statement: Statement) -> ReadOp<u64> {
    read_op(move |connection, flavour| Box::pin(async move { count(connection, flavour, &statement).await }))
}

pub(crate) async fn count(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    statement: &Statement,
) -> Result<u64, DriverError> {
    let row = prepared(statement)?
        .fetch_optional(&mut *connection)
        .await
        .map_err(|error| map_error(&error, flavour))?
        .ok_or_else(|| DriverError::Protocol("the count returned no row".to_owned()))?;
    let values = decode_row(&row, MySqlWireFormat::Binary, MySqlTimestampMode::WorkspaceUtc);
    let value = values
        .first()
        .ok_or_else(|| DriverError::Protocol("the count returned no column".to_owned()))?;
    value
        .as_exact_u64()
        .ok_or_else(|| DriverError::Protocol(format!("the count returned {value:?}")))
}
