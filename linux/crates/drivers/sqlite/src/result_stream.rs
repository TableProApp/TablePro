//! Running statements and handing their rows on.
//!
//! Each statement is prepared first, which gives its columns before any
//! row arrives, so a SELECT that finds nothing still has a header and a
//! statement without columns is known to be a command. The read that
//! follows hits the same cached statement, so nothing is compiled twice.

use std::sync::Arc;

use futures::TryStreamExt;
use sqlx::sqlite::{SqliteColumn, SqliteConnection as SqlxConnection};
use sqlx::{AssertSqlSafe, Column, Executor, SqlSafeStr, Statement as _, TypeInfo};
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{
    LexicalSettings, OpenConstruct, ScriptDiagnostic, ScriptPlan, ScriptTokenKind,
};
use tablepro_core::statement::{BoundParam, Statement};
use tablepro_core::value::Value;
use tablepro_core::{DriverError, QueryResult, ResultEvent, ResultSink, RowLimit, SinkFlow, Truncation};

use crate::catalog::{result_column_type, storage_class_type};
use crate::decode::decode_row;
use crate::encode::bind_all;
use crate::errors::map_error;

/// How many rows travel in one `Rows` event: enough that a large read
/// is not one await per row, few enough that the first rows show at
/// once.
const ROWS_PER_EVENT: usize = 256;

/// What a run of statements did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct StreamOutcome {
    pub rows: u64,
    /// The sink stopped reading, so the rest of the run was skipped.
    pub consumer_gone: bool,
    result_sets: usize,
}

/// A read the app built, kept to `limit` rows.
pub(crate) async fn collect(
    connection: &mut SqlxConnection,
    statement: &Statement,
    limit: Option<RowLimit>,
) -> Result<QueryResult, DriverError> {
    let sql = statement.sql().to_owned();
    let mut columns = prepare(connection, &sql).await?;
    let query = bind_all(sqlx::query(AssertSqlSafe(sql)), statement.params())?;
    let mut rows = Vec::new();
    let mut truncated = false;
    let mut stream = query.fetch(&mut *connection);
    while let Some(row) = stream.try_next().await.map_err(map_error)? {
        if limit.is_some_and(|limit| u64::try_from(rows.len()).is_ok_and(|kept| kept >= limit.get())) {
            truncated = true;
            break;
        }
        rows.push(decode_row(&row));
    }
    drop(stream);
    if let Some(first) = rows.first() {
        resolve(&mut columns, first);
    }
    Ok(QueryResult::new(finish(columns), rows).truncated(truncated))
}

/// The single number a count query returned.
pub(crate) async fn count(connection: &mut SqlxConnection, statement: &Statement) -> Result<u64, DriverError> {
    let result = collect(connection, statement, RowLimit::new(1)).await?;
    match result.cell(0, 0) {
        Some(Value::Int(count)) => {
            u64::try_from(*count).map_err(|_| DriverError::Protocol(format!("a row count of {count}")))
        }
        other => Err(DriverError::Protocol(format!("a row count read as {other:?}"))),
    }
}

/// Run SQL the user wrote, one statement after another, until one fails
/// or the sink stops reading.
pub(crate) async fn run_script(
    connection: &mut SqlxConnection,
    sql: &str,
    limit: Option<RowLimit>,
    sink: &mut dyn ResultSink,
) -> Result<StreamOutcome, DriverError> {
    let mut outcome = StreamOutcome::default();
    for statement in split_statements(sql) {
        run_statement(connection, statement, &[], limit, sink, &mut outcome).await?;
        if outcome.consumer_gone {
            break;
        }
    }
    Ok(outcome)
}

/// Run a read the app built, every row of it.
pub(crate) async fn run_bound(
    connection: &mut SqlxConnection,
    statement: &Statement,
    sink: &mut dyn ResultSink,
) -> Result<StreamOutcome, DriverError> {
    let mut outcome = StreamOutcome::default();
    run_statement(
        connection,
        statement.sql(),
        statement.params(),
        None,
        sink,
        &mut outcome,
    )
    .await?;
    Ok(outcome)
}

/// The statements of a script, split where SQLite itself would end one
/// (a trigger body's semicolons do not end it).
///
/// An unterminated string, identifier or comment runs to the end of the
/// text. The statements before it still run one at a time, and the one
/// it opens goes to SQLite as it stands, so the error is SQLite's own.
/// Sent whole, the script would run as one statement under the first
/// statement's columns. SQLite reads an open comment as a comment, so
/// only the text before one is sent.
pub(crate) fn split_statements(sql: &str) -> Vec<&str> {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::Sqlite,
        LexicalSettings::default_for(SqlGrammar::Sqlite),
    );
    let open = plan
        .diagnostics()
        .iter()
        .map(|ScriptDiagnostic::Unterminated { construct, start }| (*start, *construct))
        .min_by_key(|(start, _)| *start);
    let (open_at, tail_end) = match open {
        Some((start, OpenConstruct::BlockComment)) => (start, start),
        Some((start, _)) => (start, sql.len()),
        None => (sql.len(), sql.len()),
    };
    let mut statements = Vec::with_capacity(plan.statements().len());
    for statement in plan.statements() {
        if statement.range.end <= open_at {
            statements.push(statement.text(sql));
            continue;
        }
        let tail = sql.get(statement.range.start..tail_end).unwrap_or_default().trim_end();
        if !tail.is_empty() {
            statements.push(tail);
        }
        break;
    }
    statements
}

/// Whether SQLite's change count describes this statement. It counts
/// only INSERT, UPDATE and DELETE, and after anything else still holds
/// the count of the last one of those.
pub(crate) fn reports_changes(sql: &str) -> bool {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::Sqlite,
        LexicalSettings::default_for(SqlGrammar::Sqlite),
    );
    let first = plan
        .tokens(0..sql.len())
        .find(|token| !token.kind.is_trivia())
        .filter(|token| token.kind == ScriptTokenKind::Word)
        .and_then(|token| sql.get(token.range));
    first.is_some_and(|word| {
        ["INSERT", "UPDATE", "DELETE", "REPLACE", "WITH"]
            .iter()
            .any(|keyword| word.eq_ignore_ascii_case(keyword))
    })
}

async fn run_statement(
    connection: &mut SqlxConnection,
    sql: &str,
    params: &[BoundParam],
    limit: Option<RowLimit>,
    sink: &mut dyn ResultSink,
    outcome: &mut StreamOutcome,
) -> Result<(), DriverError> {
    let mut columns = prepare(connection, sql).await?;
    let query = bind_all(sqlx::query(AssertSqlSafe(sql.to_owned())), params)?;
    if columns.is_empty() {
        let done = query.execute(&mut *connection).await.map_err(map_error)?;
        let rows_affected = reports_changes(sql).then(|| done.rows_affected());
        outcome.consumer_gone = gone(sink.accept(ResultEvent::CommandCompleted { rows_affected }).await);
        return Ok(());
    }

    let set_index = outcome.result_sets;
    outcome.result_sets += 1;
    let started = ResultEvent::ResultSetStarted {
        columns: shared(&columns),
    };
    if gone(sink.accept(started).await) {
        outcome.consumer_gone = true;
        return Ok(());
    }

    let mut stream = query.fetch(&mut *connection);
    let mut batch: Vec<Vec<Value>> = Vec::with_capacity(ROWS_PER_EVENT);
    let mut retained = 0u64;
    let mut truncation = Truncation::Complete;
    while let Some(row) = stream.try_next().await.map_err(map_error)? {
        if limit.is_some_and(|limit| retained >= limit.get()) {
            truncation = Truncation::ReadPastLimit;
            break;
        }
        let values = decode_row(&row);
        if retained == 0 && columns.iter().any(|column| column.column_type.is_none()) {
            resolve(&mut columns, &values);
            let resolved = ResultEvent::ColumnsResolved {
                set_index,
                columns: shared(&columns),
            };
            if gone(sink.accept(resolved).await) {
                outcome.consumer_gone = true;
                return Ok(());
            }
        }
        batch.push(values);
        retained += 1;
        if batch.len() == ROWS_PER_EVENT && gone(sink.accept(ResultEvent::Rows(std::mem::take(&mut batch))).await) {
            outcome.rows += retained;
            outcome.consumer_gone = true;
            return Ok(());
        }
    }
    // Dropping the read resets the statement, which is what stops it
    // reading past the limit.
    drop(stream);
    outcome.rows += retained;

    let mut closing = Vec::new();
    if !batch.is_empty() {
        closing.push(ResultEvent::Rows(batch));
    }
    if truncation == Truncation::ReadPastLimit {
        closing.push(ResultEvent::RowLimitReached { retained });
    }
    closing.push(ResultEvent::ResultSetFinished {
        retained,
        total_rows: (truncation == Truncation::Complete).then_some(retained),
        truncation,
    });
    for event in closing {
        if gone(sink.accept(event).await) {
            outcome.consumer_gone = true;
            break;
        }
    }
    Ok(())
}

fn gone(flow: SinkFlow) -> bool {
    flow == SinkFlow::ConsumerGone
}

/// A result column whose type may wait for the first row.
#[derive(Debug, Clone)]
struct PendingColumn {
    name: String,
    column_type: Option<ColumnType>,
}

async fn prepare(connection: &mut SqlxConnection, sql: &str) -> Result<Vec<PendingColumn>, DriverError> {
    let prepared = (&mut *connection)
        .prepare(AssertSqlSafe(sql.to_owned()).into_sql_str())
        .await
        .map_err(map_error)?;
    Ok(prepared.columns().iter().map(pending).collect())
}

fn pending(column: &SqliteColumn) -> PendingColumn {
    PendingColumn {
        name: column.name().to_owned(),
        column_type: result_column_type(column.type_info().name()),
    }
}

/// Give an expression column the type of the value its first row
/// holds, which is all SQLite can say about it.
fn resolve(columns: &mut [PendingColumn], row: &[Value]) {
    for (column, value) in columns.iter_mut().zip(row) {
        if column.column_type.is_none() && !value.is_null() {
            column.column_type = Some(storage_class_type(value));
        }
    }
}

fn finish(columns: Vec<PendingColumn>) -> Vec<ResultColumn> {
    columns
        .into_iter()
        .map(|column| {
            let column_type = column.column_type.unwrap_or_else(|| storage_class_type(&Value::Null));
            ResultColumn::new(column.name, column_type)
        })
        .collect()
}

fn shared(columns: &[PendingColumn]) -> Arc<[ResultColumn]> {
    finish(columns.to_vec()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_trigger_body_stays_one_statement() {
        let script = "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; SELECT 2; END; SELECT 3;";

        let statements = split_statements(script);

        assert_eq!(statements.len(), 2, "{statements:?}");
        assert!(statements[0].starts_with("CREATE TRIGGER"));
        assert!(statements[1].starts_with("SELECT 3"));
    }

    #[test]
    fn an_unfinished_script_goes_to_sqlite_whole() {
        assert_eq!(split_statements("SELECT 'open"), ["SELECT 'open"]);
        assert!(split_statements("  -- only a comment\n").is_empty());
    }

    #[test]
    fn statements_before_an_unfinished_one_still_run_alone() {
        assert_eq!(
            split_statements("SELECT 1 AS a; SELECT 2 AS b, 3 AS c /* open"),
            ["SELECT 1 AS a", "SELECT 2 AS b, 3 AS c"]
        );
        assert_eq!(
            split_statements("SELECT 1; SELECT 'open; still open"),
            ["SELECT 1", "SELECT 'open; still open"]
        );
        assert_eq!(split_statements("SELECT 1; /* open"), ["SELECT 1"]);
    }

    #[test]
    fn only_row_changes_report_a_change_count() {
        assert!(reports_changes("  INSERT INTO t VALUES (1)"));
        assert!(reports_changes("with x AS (SELECT 1) DELETE FROM t"));
        assert!(reports_changes("/* why */ update t SET a = 1"));
        assert!(!reports_changes("CREATE TABLE t (a)"));
        assert!(!reports_changes("PRAGMA foreign_keys = ON"));
    }
}
