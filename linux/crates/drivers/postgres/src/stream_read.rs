use std::sync::Arc;

use futures_util::StreamExt;
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken};
use tablepro_core::statement::Statement;
use tablepro_core::{
    DriverError, ReadOnlyRefusal, ReadStatement, ResultEvent, ResultSink, SinkFlow, StreamSummary, Truncation, Value,
};
use tokio_postgres::{Client, SimpleQueryMessage};

use crate::catalog::{result_column, text_column};
use crate::codec::typed;
use crate::editor::statement_class::{StatementClass, classify};
use crate::errors::{map_error, read_only_refusal};
use crate::workspace_call::{decode_row, describe};

const BATCH_ROWS: usize = 256;

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
    let mut emitter = Emitter {
        sink,
        batch: Vec::new(),
        rows: 0,
        set_rows: 0,
    };
    let streamed = match read {
        ReadStatement::Generated(statement) => {
            let rows = client
                .query_typed_raw(statement.sql(), typed(statement.params()))
                .await
                .map_err(|error| map_error(&error))?;
            emitter.binary(client, statement, rows).await
        }
        ReadStatement::User(sql) => {
            let messages = client
                .simple_query_raw(sql.as_str())
                .await
                .map_err(|error| map_error(&error))?;
            emitter.text(messages).await
        }
    };
    let committed = client.batch_execute("COMMIT").await.map_err(|error| map_error(&error));
    streamed.map_err(read_only_refusal)?;
    committed?;
    Ok(StreamSummary::new(emitter.rows))
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

struct Emitter<'a> {
    sink: &'a mut dyn ResultSink,
    batch: Vec<Vec<Value>>,
    rows: u64,
    set_rows: u64,
}

impl Emitter<'_> {
    async fn binary(
        &mut self,
        client: &Client,
        statement: &Statement,
        rows: tokio_postgres::RowStream,
    ) -> Result<(), DriverError> {
        let mut rows = std::pin::pin!(rows);
        let mut started = false;
        while let Some(row) = rows.next().await {
            let row = row.map_err(|error| map_error(&error))?;
            if !started {
                started = true;
                let columns: Arc<[ResultColumn]> = row.columns().iter().map(result_column).collect();
                self.send(ResultEvent::ResultSetStarted { columns }).await?;
            }
            self.row(decode_row(&row)?).await?;
        }
        if !started {
            // Still inside the read's transaction, so the columns of an
            // empty result are read in it.
            let columns: Arc<[ResultColumn]> = describe(client, statement).await?.into();
            self.send(ResultEvent::ResultSetStarted { columns }).await?;
        }
        self.finish().await
    }

    async fn text(&mut self, messages: tokio_postgres::SimpleQueryStream) -> Result<(), DriverError> {
        let mut messages = std::pin::pin!(messages);
        let mut first_error = None;
        while let Some(message) = messages.next().await {
            match message {
                Ok(SimpleQueryMessage::RowDescription(columns)) => {
                    let columns = columns.iter().map(|column| text_column(column.name())).collect();
                    self.send(ResultEvent::ResultSetStarted { columns }).await?;
                }
                Ok(SimpleQueryMessage::Row(row)) => {
                    let values = (0..row.len())
                        .map(|index| row.get(index).map_or(Value::Null, |text| Value::Text(text.to_owned())))
                        .collect();
                    self.row(values).await?;
                }
                Ok(SimpleQueryMessage::CommandComplete(_)) => self.finish().await?,
                Ok(_) => {}
                Err(error) if error.as_db_error().is_none() => return Err(map_error(&error)),
                Err(error) => {
                    first_error.get_or_insert_with(|| map_error(&error));
                }
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    async fn row(&mut self, values: Vec<Value>) -> Result<(), DriverError> {
        self.batch.push(values);
        self.rows += 1;
        self.set_rows += 1;
        if self.batch.len() >= BATCH_ROWS {
            self.flush().await?;
        }
        Ok(())
    }

    async fn flush(&mut self) -> Result<(), DriverError> {
        if self.batch.is_empty() {
            return Ok(());
        }
        let rows = std::mem::take(&mut self.batch);
        self.send(ResultEvent::Rows(rows)).await
    }

    async fn finish(&mut self) -> Result<(), DriverError> {
        self.flush().await?;
        let rows = std::mem::take(&mut self.set_rows);
        self.send(ResultEvent::ResultSetFinished {
            retained: rows,
            total_rows: Some(rows),
            truncation: Truncation::Complete,
        })
        .await
    }

    /// A consumer that went away ends the read: the rows would go
    /// nowhere.
    async fn send(&mut self, event: ResultEvent) -> Result<(), DriverError> {
        match self.sink.accept(event).await {
            SinkFlow::Continue => Ok(()),
            SinkFlow::ConsumerGone => Err(DriverError::Cancelled),
        }
    }
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
