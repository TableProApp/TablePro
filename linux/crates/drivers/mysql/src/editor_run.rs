//! One editor run over the text protocol, as result events.
//!
//! A set starts with its first row, since that is where sqlx gives out
//! the columns, and ends with the OK packet behind it. The server stops
//! a plain SELECT at `sql_select_limit`, one row past the run's limit;
//! a SELECT with a LIMIT of its own, or one inside a routine, is read to
//! its end, and the rows past the limit are counted, never decoded.

use std::sync::Arc;

use futures_util::TryStreamExt;
use sqlx::mysql::{MySqlConnection, MySqlRow};
use sqlx::{AssertSqlSafe, Either, Executor as _, Row as _};
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use tablepro_core::{DriverError, ResultEvent, ResultSink, RowLimit, SinkFlow, Truncation, Value};
use tokio_util::sync::CancellationToken;

use crate::catalog::result_column;
use crate::decode::decode_row;
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;

/// How many rows travel in one `Rows` event.
const ROWS_PER_EVENT: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct RunOutcome {
    /// The sink stopped reading, so the run was cut short.
    pub consumer_gone: bool,
}

/// The texts to send. A script with mysql-client DELIMITER lines is
/// split where the client would split it, since the server does not
/// know the directive; anything else goes whole, and the server runs it
/// as one multi-statement batch.
pub(crate) fn batches(sql: &str) -> Vec<&str> {
    let plan = ScriptPlan::build(sql, SqlGrammar::MySql, LexicalSettings::default_for(SqlGrammar::MySql));
    let directives = plan
        .tokens(0..sql.len())
        .any(|token| token.kind == ScriptTokenKind::Directive);
    if !directives || !plan.diagnostics().is_empty() {
        return vec![sql];
    }
    plan.statements().iter().map(|statement| statement.text(sql)).collect()
}

/// Run the script. When the sink stops reading, `consumer_gone` is
/// cancelled so the caller can stop the server. The batch already sent
/// is still read to its end, unshown, since only that frees the
/// connection, and no later batch is sent.
pub(crate) async fn run_script(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    sql: &str,
    limit: RowLimit,
    sink: &mut dyn ResultSink,
    consumer_gone: &CancellationToken,
) -> Result<RunOutcome, DriverError> {
    let mut emitter = Emitter {
        sink,
        limit: limit.get(),
        open: None,
        sets: 0,
        gone: false,
    };
    for text in batches(sql) {
        if emitter.gone {
            break;
        }
        let results = connection.fetch_many(sqlx::raw_sql(AssertSqlSafe(text.to_owned())));
        let mut results = std::pin::pin!(results);
        while let Some(item) = results.try_next().await.map_err(|error| map_error(&error, flavour))? {
            match item {
                Either::Right(row) => emitter.row(&row).await,
                Either::Left(done) => emitter.done(done.rows_affected()).await,
            }
            if emitter.gone {
                consumer_gone.cancel();
            }
        }
    }
    Ok(RunOutcome {
        consumer_gone: emitter.gone,
    })
}

struct OpenSet {
    batch: Vec<Vec<Value>>,
    retained: u64,
    seen: u64,
}

struct Emitter<'a> {
    sink: &'a mut dyn ResultSink,
    limit: u64,
    open: Option<OpenSet>,
    sets: usize,
    gone: bool,
}

impl Emitter<'_> {
    async fn row(&mut self, row: &MySqlRow) {
        if self.gone {
            return;
        }
        if self.open.is_none() {
            let columns: Arc<[ResultColumn]> = row
                .columns()
                .iter()
                .map(|column| result_column(column, MySqlTimestampMode::SessionLocal))
                .collect();
            self.sets += 1;
            self.open = Some(OpenSet {
                batch: Vec::new(),
                retained: 0,
                seen: 0,
            });
            self.send(ResultEvent::ResultSetStarted { columns }).await;
        }
        let limit = self.limit;
        let Some(set) = self.open.as_mut() else {
            return;
        };
        set.seen += 1;
        if set.retained >= limit {
            return;
        }
        set.batch
            .push(decode_row(row, MySqlWireFormat::Text, MySqlTimestampMode::SessionLocal));
        set.retained += 1;
        if set.batch.len() >= ROWS_PER_EVENT {
            let rows = std::mem::take(&mut set.batch);
            self.send(ResultEvent::Rows(rows)).await;
        }
    }

    async fn done(&mut self, rows_affected: u64) {
        if self.gone {
            return;
        }
        let Some(set) = self.open.take() else {
            self.send(ResultEvent::CommandCompleted {
                rows_affected: Some(rows_affected),
            })
            .await;
            return;
        };
        if !set.batch.is_empty() {
            self.send(ResultEvent::Rows(set.batch)).await;
        }
        let (truncation, total_rows) = truncation(set.seen, self.limit);
        if truncation != Truncation::Complete {
            self.send(ResultEvent::RowLimitReached { retained: set.retained }).await;
        }
        self.send(ResultEvent::ResultSetFinished {
            retained: set.retained,
            total_rows,
            truncation,
        })
        .await;
    }

    async fn send(&mut self, event: ResultEvent) {
        if self.gone {
            return;
        }
        self.gone = self.sink.accept(event).await == SinkFlow::ConsumerGone;
    }
}

/// Why a set ended where it did. Exactly one row past the limit is
/// where `sql_select_limit` stops the server, so how many more there
/// were is unknown; past that the set was read to its end and the total
/// is known.
pub(crate) fn truncation(seen: u64, limit: u64) -> (Truncation, Option<u64>) {
    match seen {
        seen if seen <= limit => (Truncation::Complete, Some(seen)),
        seen if seen == limit.saturating_add(1) => (Truncation::ServerStopped, None),
        seen => (Truncation::ReadPastLimit, Some(seen)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_set_cut_by_the_server_is_told_from_one_read_past_the_limit() {
        assert_eq!(truncation(40, 100), (Truncation::Complete, Some(40)));
        assert_eq!(truncation(100, 100), (Truncation::Complete, Some(100)));
        assert_eq!(truncation(101, 100), (Truncation::ServerStopped, None));
        assert_eq!(truncation(150_000, 100), (Truncation::ReadPastLimit, Some(150_000)));
    }

    #[test]
    fn delimiter_scripts_split_where_the_client_would() {
        let script = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nCALL p();";

        let split = batches(script);

        assert_eq!(split.len(), 2, "{split:?}");
        assert!(split[0].starts_with("CREATE PROCEDURE"), "{split:?}");
        assert!(split[0].ends_with("END"), "{split:?}");
        assert!(split[1].starts_with("CALL p()"), "{split:?}");
        assert_eq!(batches("SELECT 1; SELECT 2"), ["SELECT 1; SELECT 2"]);
    }
}
