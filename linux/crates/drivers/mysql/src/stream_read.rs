use std::sync::Arc;

use futures_util::TryStreamExt;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Either, Executor as _, Row as _};
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use tablepro_core::{
    DriverError, ReadOnlyRefusal, ReadStatement, ResultEvent, ResultSink, SinkFlow, StreamSummary, Truncation, Value,
};

use crate::catalog::result_column;
use crate::decode::decode_row;
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;
use crate::workspace_call::{describe, prepared};

const BATCH_ROWS: usize = 256;

/// The first words a statement may start with in a streamed read. Each
/// only reads, and none ends the read-only transaction the read relies
/// on; anything else, a CALL or a COMMIT, is refused before it is sent.
const READING_STATEMENTS: [&str; 7] = ["SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "TABLE"];

/// Every row of a read, into the sink, inside a read-only transaction.
/// The connection has no statement timeout: an export can take minutes,
/// and the caller's deadline and cancel still stop it.
pub(crate) async fn stream(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
) -> Result<StreamSummary, DriverError> {
    if let ReadStatement::User(sql) = read {
        refuse_writes(sql.as_str())?;
    }
    connection
        .execute("START TRANSACTION READ ONLY")
        .await
        .map_err(|error| map_error(&error, flavour))?;
    let mut emitter = Emitter {
        sink,
        batch: Vec::new(),
        rows: 0,
        set_rows: 0,
        started: false,
    };
    let streamed = match read {
        ReadStatement::Generated(statement) => {
            let query = prepared(statement)?;
            let streamed = emitter
                .rows_of(query.fetch(&mut *connection), flavour, MySqlWireFormat::Binary)
                .await;
            match (streamed, emitter.started) {
                (Ok(()), false) => {
                    let columns = describe(connection, flavour, statement.sql()).await?;
                    emitter.start(columns.into()).await?;
                    emitter.finish().await
                }
                (Ok(()), true) => emitter.finish().await,
                (Err(error), _) => Err(error),
            }
        }
        ReadStatement::User(sql) => {
            let results = connection.fetch_many(sqlx::raw_sql(AssertSqlSafe(sql.as_str().to_owned())));
            emitter.results(results, flavour).await
        }
    };
    let committed = connection
        .execute("COMMIT")
        .await
        .map(|_| ())
        .map_err(|error| map_error(&error, flavour));
    streamed?;
    committed?;
    Ok(StreamSummary::new(emitter.rows))
}

/// User SQL that does anything but read is refused: a write fails in the
/// read-only transaction anyway, but a COMMIT or DDL would end it first.
pub(crate) fn refuse_writes(sql: &str) -> Result<(), DriverError> {
    let plan = ScriptPlan::build(sql, SqlGrammar::MySql, LexicalSettings::default_for(SqlGrammar::MySql));
    for statement in plan.statements() {
        let first = plan
            .tokens(statement.range.clone())
            .find(|token| !token.kind.is_trivia());
        let reads = match first {
            Some(token) if token.kind == ScriptTokenKind::OpenParen => true,
            Some(token) if token.kind == ScriptTokenKind::Word => sql
                .get(token.range)
                .is_some_and(|word| READING_STATEMENTS.iter().any(|known| word.eq_ignore_ascii_case(known))),
            _ => false,
        };
        if !reads {
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
    started: bool,
}

impl Emitter<'_> {
    async fn rows_of<S>(&mut self, rows: S, flavour: MySqlFlavour, format: MySqlWireFormat) -> Result<(), DriverError>
    where
        S: futures_util::Stream<Item = Result<sqlx::mysql::MySqlRow, sqlx::Error>>,
    {
        let mut rows = std::pin::pin!(rows);
        while let Some(row) = rows.try_next().await.map_err(|error| map_error(&error, flavour))? {
            self.row(&row, format).await?;
        }
        Ok(())
    }

    async fn results<S>(&mut self, results: S, flavour: MySqlFlavour) -> Result<(), DriverError>
    where
        S: futures_util::Stream<
                Item = Result<Either<sqlx::mysql::MySqlQueryResult, sqlx::mysql::MySqlRow>, sqlx::Error>,
            >,
    {
        let mut results = std::pin::pin!(results);
        while let Some(item) = results.try_next().await.map_err(|error| map_error(&error, flavour))? {
            match item {
                Either::Right(row) => self.row(&row, MySqlWireFormat::Text).await?,
                Either::Left(_) if self.started => self.finish().await?,
                Either::Left(_) => {}
            }
        }
        Ok(())
    }

    async fn row(&mut self, row: &sqlx::mysql::MySqlRow, format: MySqlWireFormat) -> Result<(), DriverError> {
        if !self.started {
            let columns: Arc<[ResultColumn]> = row
                .columns()
                .iter()
                .map(|column| result_column(column, MySqlTimestampMode::WorkspaceUtc))
                .collect();
            self.start(columns).await?;
        }
        self.batch
            .push(decode_row(row, format, MySqlTimestampMode::WorkspaceUtc));
        self.rows += 1;
        self.set_rows += 1;
        if self.batch.len() >= BATCH_ROWS {
            self.flush().await?;
        }
        Ok(())
    }

    async fn start(&mut self, columns: Arc<[ResultColumn]>) -> Result<(), DriverError> {
        self.started = true;
        self.send(ResultEvent::ResultSetStarted { columns }).await
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
        self.started = false;
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

    #[test]
    fn user_sql_that_would_end_the_read_only_transaction_is_refused() {
        assert!(refuse_writes("SELECT 1; (SELECT 2); with x AS (SELECT 1) SELECT * FROM x; SHOW TABLES").is_ok());
        for sql in [
            "COMMIT; DELETE FROM t",
            "SELECT 1; ROLLBACK",
            "CALL p()",
            "BEGIN",
            "CREATE TABLE t (a int)",
        ] {
            assert_eq!(
                refuse_writes(sql),
                Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
                "{sql}"
            );
        }
    }
}
