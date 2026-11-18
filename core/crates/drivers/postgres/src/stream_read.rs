use std::sync::Arc;

use futures_util::StreamExt;
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken};
use tablepro_core::statement::Statement;
use tablepro_core::{DriverError, ReadEmitter, ReadOnlyRefusal, ReadStatement, ResultSink, StreamSummary, Value};
use tokio_postgres::{Client, SimpleQueryMessage};

use crate::catalog::{result_column, text_column};
use crate::codec::typed;
use crate::editor::statement_class::{StatementClass, classify};
use crate::errors::{map_error, read_only_refusal};
use crate::workspace_call::{decode_row, describe};

/// The read's transaction. Its SELECT takes the snapshot, after which
/// the server refuses SET TRANSACTION READ WRITE and any other way of
/// making the transaction writable, so user SQL cannot write in it.
const BEGIN: &str = "START TRANSACTION READ ONLY; SET LOCAL statement_timeout = 0; SELECT 1";

/// Every row of a read, into the sink, inside a read-only transaction
/// with no server timeout: an export can take minutes, and the caller's
/// deadline and cancel still stop it. `conforming` is the session's
/// `standard_conforming_strings`, which decides how the server splits
/// the user's SQL.
pub(crate) async fn stream(
    client: &Client,
    conforming: bool,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
) -> Result<StreamSummary, DriverError> {
    if let ReadStatement::User(sql) = read {
        refuse_transaction_control(sql.as_str(), conforming)?;
    }
    client.batch_execute(BEGIN).await.map_err(|error| map_error(&error))?;
    let mut emitter = ReadEmitter::new(sink);
    let streamed = match read {
        ReadStatement::Generated(statement) => {
            let rows = client
                .query_typed_raw(statement.sql(), typed(statement.params()))
                .await
                .map_err(|error| map_error(&error))?;
            binary(&mut emitter, client, statement, rows).await
        }
        ReadStatement::User(sql) => {
            refuse_more_than_one(client, sql.as_str()).await?;
            let messages = client
                .simple_query_raw(sql.as_str())
                .await
                .map_err(|error| map_error(&error))?;
            text(&mut emitter, messages).await
        }
    };
    let committed = client.batch_execute("COMMIT").await.map_err(|error| map_error(&error));
    streamed.map_err(read_only_refusal)?;
    committed?;
    Ok(StreamSummary::new(emitter.rows()))
}

/// The read-only transaction is the export's whole guarantee, so user
/// SQL that would end it, or a routine that may, is refused before
/// anything is sent. The server reads the whole text before it runs any
/// of it, so the split is the one the session's setting gives.
fn refuse_transaction_control(sql: &str, conforming: bool) -> Result<(), DriverError> {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::PostgreSql,
        LexicalSettings {
            backslash_escapes: !conforming,
        },
    );
    for statement in plan.statements() {
        let tokens: Vec<ScriptToken> = plan.tokens(statement.range.clone()).collect();
        let class = classify(sql, &tokens);
        if class.is_transaction_control() || class == StatementClass::Undetermined {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
    }
    Ok(())
}

/// The extended protocol's Parse refuses a text that holds more than one
/// statement, and the simple query that follows splits the text with the
/// same parser, so nothing can follow the read inside its transaction
/// whatever the client's lexer made of the text. The simple query keeps
/// every value as the server's text. The statement is prepared under a
/// name, which the read's own connection allows.
async fn refuse_more_than_one(client: &Client, sql: &str) -> Result<(), DriverError> {
    client
        .prepare_typed(sql, &[])
        .await
        .map(drop)
        .map_err(|error| map_error(&error))
}

async fn binary(
    emitter: &mut ReadEmitter<'_>,
    client: &Client,
    statement: &Statement,
    rows: tokio_postgres::RowStream,
) -> Result<(), DriverError> {
    let mut rows = std::pin::pin!(rows);
    while let Some(row) = rows.next().await {
        let row = row.map_err(|error| map_error(&error))?;
        if !emitter.is_open() {
            let columns: Arc<[ResultColumn]> = row.columns().iter().map(result_column).collect();
            emitter.start(columns).await?;
        }
        emitter.row(decode_row(&row)?).await?;
    }
    if !emitter.is_open() {
        // Still inside the read's transaction, so the columns of an
        // empty result are read in it.
        let columns: Arc<[ResultColumn]> = describe(client, statement).await?.into();
        emitter.start(columns).await?;
    }
    emitter.finish().await
}

async fn text(emitter: &mut ReadEmitter<'_>, messages: tokio_postgres::SimpleQueryStream) -> Result<(), DriverError> {
    let mut messages = std::pin::pin!(messages);
    let mut first_error = None;
    while let Some(message) = messages.next().await {
        match message {
            Ok(SimpleQueryMessage::RowDescription(columns)) => {
                let columns = columns.iter().map(|column| text_column(column.name())).collect();
                emitter.start(columns).await?;
            }
            Ok(SimpleQueryMessage::Row(row)) => {
                let values = (0..row.len())
                    .map(|index| row.get(index).map_or(Value::Null, |text| Value::Text(text.to_owned())))
                    .collect();
                emitter.row(values).await?;
            }
            Ok(SimpleQueryMessage::CommandComplete(_)) => emitter.finish().await?,
            Ok(_) => {}
            Err(error) if error.as_db_error().is_none() => return Err(map_error(&error)),
            Err(error) => {
                first_error.get_or_insert_with(|| map_error(&error));
            }
        }
    }
    first_error.map_or(Ok(()), Err)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guarded(sql: &str, conforming: bool) -> bool {
        matches!(
            refuse_transaction_control(sql, conforming),
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
        )
    }

    #[test]
    fn user_sql_that_would_end_the_read_only_transaction_is_refused() {
        assert!(refuse_transaction_control("SELECT 1; SELECT 2", true).is_ok());
        for sql in ["COMMIT; DELETE FROM t", "SELECT 1; ROLLBACK", "CALL p()", "BEGIN"] {
            assert!(guarded(sql, true), "{sql}");
        }
    }

    /// With `standard_conforming_strings` off the server reads `\'` as an
    /// escaped quote, so the COMMIT here is a statement of its own.
    #[test]
    fn the_guard_splits_the_way_a_non_conforming_server_does() {
        let sql = "SELECT 'a\\', '; COMMIT; DELETE FROM t; SELECT '1'";

        assert!(guarded(sql, false), "{sql}");
        assert!(!guarded(sql, true), "{sql}");
    }
}
