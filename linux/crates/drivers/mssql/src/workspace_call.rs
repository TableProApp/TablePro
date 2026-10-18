use std::future::Future;
use std::pin::Pin;

use tablepro_core::column::ResultColumn;
use tablepro_core::statement::Statement;
use tablepro_core::{DriverError, QueryResult, RowLimit, Value};
use tiberius::{ColumnData, QueryItem};

use crate::catalog::result_column;
use crate::decode::decode_row;
use crate::encode::{as_sql, encode_params};
use crate::in_band_request::{Interrupt, Watch, cut_short};
use crate::physical::MssqlClient;
use crate::read_only_guard::{guarded_error, wrap};

pub(crate) type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What one workspace read does once it holds a connection.
pub(crate) type ReadOp<T> =
    Box<dyn for<'a> FnOnce(&'a mut MssqlClient, &'a Watch) -> BoxFuture<'a, Result<T, Interrupt>> + Send>;

pub(crate) fn read_op<T, F>(op: F) -> ReadOp<T>
where
    F: for<'a> FnOnce(&'a mut MssqlClient, &'a Watch) -> BoxFuture<'a, Result<T, Interrupt>> + Send + 'static,
{
    Box::new(op)
}

/// Whether a generated read runs inside the read-only guard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Guard {
    None,
    RolledBack,
}

impl Guard {
    pub(crate) fn for_connection(read_only: bool) -> Self {
        match read_only {
            true => Self::RolledBack,
            false => Self::None,
        }
    }

    fn sql(self, sql: &str) -> String {
        match self {
            Self::None => sql.to_owned(),
            Self::RolledBack => wrap(sql),
        }
    }

    fn error(self, interrupt: Interrupt) -> Interrupt {
        match (self, interrupt) {
            (Self::RolledBack, Interrupt::Failed(error)) => Interrupt::Failed(guarded_error(error)),
            (_, other) => other,
        }
    }
}

/// Read at most `limit` rows of a generated statement, and one more to
/// learn whether the result was cut short. Only the first result set is
/// kept; a statement that stacks more is read to its end, so the guard's
/// own ROLLBACK runs.
pub(crate) fn query_bound_op(statement: Statement, limit: RowLimit, guard: Guard) -> ReadOp<QueryResult> {
    read_op(move |client, watch| {
        Box::pin(async move {
            let params = encode_params(statement.params())?;
            let sql = guard.sql(statement.sql());
            let read = first_result(client, watch, &sql, &params, limit).await;
            let (columns, rows, truncated) = read.map_err(|interrupt| guard.error(interrupt))?;
            if truncated {
                cut_short(client, watch, true).await;
            }
            Ok(QueryResult::new(columns, rows).truncated(truncated))
        })
    })
}

/// The single number a count query returned.
pub(crate) fn count_op(statement: Statement, guard: Guard) -> ReadOp<u64> {
    read_op(move |client, watch| {
        Box::pin(async move {
            let params = encode_params(statement.params())?;
            let sql = guard.sql(statement.sql());
            let one = RowLimit::new(1).unwrap_or(RowLimit::EDITOR_DEFAULT);
            let (_, rows, truncated) = first_result(client, watch, &sql, &params, one)
                .await
                .map_err(|interrupt| guard.error(interrupt))?;
            if truncated {
                cut_short(client, watch, true).await;
            }
            exact_count(&rows).map_err(Interrupt::Failed)
        })
    })
}

pub(crate) fn exact_count(rows: &[Vec<Value>]) -> Result<u64, DriverError> {
    match rows.first().and_then(|row| row.first()) {
        Some(value) => value
            .as_exact_u64()
            .ok_or_else(|| DriverError::Protocol(format!("the count returned {value:?}"))),
        None => Err(DriverError::Protocol("the count returned no row".to_owned())),
    }
}

type FirstResult = (Vec<ResultColumn>, Vec<Vec<Value>>, bool);

/// The first result set's columns and up to `limit` of its rows, and
/// whether a row past the limit was there.
async fn first_result(
    client: &mut MssqlClient,
    watch: &Watch,
    sql: &str,
    params: &[ColumnData<'static>],
    limit: RowLimit,
) -> Result<FirstResult, Interrupt> {
    let refs = as_sql(params);
    let mut stream = watch.start(client.query(sql, &refs)).await?;
    let mut columns: Option<Vec<ResultColumn>> = None;
    let mut rows = Vec::new();
    let mut sets = 0usize;
    while let Some(item) = watch.next(&mut stream).await? {
        match item {
            QueryItem::Metadata(metadata) => {
                sets += 1;
                if columns.is_none() {
                    columns = Some(metadata.columns().iter().map(result_column).collect());
                }
            }
            QueryItem::Row(row) if sets <= 1 => {
                if u64::try_from(rows.len()).is_ok_and(|kept| kept >= limit.get()) {
                    return Ok((columns.unwrap_or_default(), rows, true));
                }
                rows.push(decode_row(&row));
            }
            QueryItem::Row(_) => {}
        }
    }
    Ok((columns.unwrap_or_default(), rows, false))
}

/// Every row of a driver-owned catalogue query.
pub(crate) async fn catalogue_rows(
    client: &mut MssqlClient,
    watch: &Watch,
    sql: &str,
    params: &[ColumnData<'static>],
) -> Result<Vec<Vec<Value>>, Interrupt> {
    let refs = as_sql(params);
    let mut stream = watch.start(client.query(sql, &refs)).await?;
    let mut rows = Vec::new();
    while let Some(item) = watch.next(&mut stream).await? {
        if let QueryItem::Row(row) = item {
            rows.push(decode_row(&row));
        }
    }
    Ok(rows)
}

/// A text parameter for a catalogue query.
pub(crate) fn text_param(text: &str) -> ColumnData<'static> {
    ColumnData::String(Some(text.to_owned().into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_count_must_be_one_exact_number() {
        assert_eq!(exact_count(&[vec![Value::Int(42)]]), Ok(42));
        assert!(exact_count(&[]).is_err());
        assert!(exact_count(&[vec![Value::Int(-1)]]).is_err());
        assert!(exact_count(&[vec![Value::Text("42".to_owned())]]).is_err());
    }

    #[test]
    fn a_read_only_connection_guards_its_reads() {
        assert_eq!(Guard::for_connection(true), Guard::RolledBack);
        assert_eq!(Guard::RolledBack.sql("SELECT 1"), wrap("SELECT 1"));
        assert_eq!(Guard::for_connection(false).sql("SELECT 1"), "SELECT 1");
    }
}
