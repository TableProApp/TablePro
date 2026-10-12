use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{BatchErrorPolicy, LexicalSettings, ScriptPlan};
use tablepro_core::{
    DriverError, ResultEvent, ResultSink, RowLimit, RunEnd, SinkFlow, StopReason, StopRequest, TransactionState,
    Truncation, Value,
};
use tiberius::QueryItem;

use crate::cancel::MssqlStop;
use crate::catalog::{Cells, result_column};
use crate::decode::decode_row;
use crate::errors::{ends_connection, map_error};
use crate::in_band_request::{Interrupt, StopPolicy, Watch, conclude, cut_short};
use crate::physical::MssqlClient;
use crate::transport_io::ReadTally;

/// Rows per `ResultEvent::Rows`. The sink is awaited per batch, so a slow
/// grid slows the read instead of growing a queue.
const BATCH_ROWS: usize = 256;

/// How a run ended, and whether its connection can take the next one.
#[derive(Debug)]
pub(crate) struct ScriptOutcome {
    pub(crate) end: RunEnd,
    pub(crate) reusable: bool,
}

/// One run of user SQL on an editor session's own connection.
pub(crate) struct EditorRun<'a> {
    pub(crate) client: &'a mut MssqlClient,
    pub(crate) tally: ReadTally,
    pub(crate) request: StopRequest,
    pub(crate) policy: StopPolicy,
    pub(crate) limit: RowLimit,
    pub(crate) sink: &'a mut dyn ResultSink,
}

/// The result set an exchange is reading.
#[derive(Debug, Default)]
struct OpenSet {
    retained: u64,
    total: u64,
    batch: Vec<Vec<Value>>,
    limit_reported: bool,
}

/// How one batch ended without failing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BatchEnd {
    Done,
    ConsumerGone,
}

impl EditorRun<'_> {
    /// Run the script one GO batch at a time, as sqlcmd and SSMS do. Each
    /// batch goes as a SQL batch rather than through sp_executesql, so a
    /// USE or a SET in it lasts for the rest of the session.
    pub(crate) async fn script(&mut self, sql: &str) -> Result<ScriptOutcome, DriverError> {
        let plan = ScriptPlan::build(sql, SqlGrammar::MsSql, LexicalSettings::default_for(SqlGrammar::MsSql));
        let batches: Vec<(std::ops::Range<usize>, u32)> = match plan.diagnostics().is_empty() {
            true => plan
                .batches()
                .iter()
                .map(|batch| (batch.range.clone(), batch.repeat.get()))
                .collect(),
            // Text the splitter cannot finish goes to the server whole,
            // so the error is the server's own.
            false => vec![(0..sql.len(), 1)],
        };
        let continue_after_error = plan.batch_error_policy() == BatchErrorPolicy::ContinueNextBatch;
        let mut first_error = None;
        for (range, repeat) in batches {
            let text = sql.get(range).unwrap_or_default().trim();
            if text.is_empty() {
                continue;
            }
            for _ in 0..repeat {
                let watch = Watch::new(self.request.clone(), self.tally.clone(), self.policy);
                let outcome = self.batch(&watch, text).await;
                match outcome {
                    Ok(BatchEnd::Done) => {}
                    Ok(BatchEnd::ConsumerGone) => {
                        cut_short(self.client, &watch, false).await;
                        return Ok(ScriptOutcome {
                            end: RunEnd::Cancelled,
                            reusable: !watch.spoiled(),
                        });
                    }
                    Err(Interrupt::Failed(error)) if ends_connection(&error) => return Err(error),
                    Err(Interrupt::Failed(error)) => {
                        first_error.get_or_insert(error);
                        if !continue_after_error {
                            break;
                        }
                    }
                    Err(Interrupt::Stopped(halt)) => {
                        let stopped = Err::<(), _>(Interrupt::Stopped(halt));
                        let concluded = conclude(self.client, &watch, stopped, &MssqlStop::new(), false).await;
                        return Ok(ScriptOutcome {
                            end: end_after_stop(&self.request, concluded.result.err()),
                            reusable: concluded.reusable,
                        });
                    }
                }
            }
            if first_error.is_some() && !continue_after_error {
                break;
            }
        }
        Ok(ScriptOutcome {
            end: first_error.map_or(RunEnd::Completed, RunEnd::Failed),
            reusable: true,
        })
    }

    async fn batch(&mut self, watch: &Watch, text: &str) -> Result<BatchEnd, Interrupt> {
        let limit = self.limit.get();
        let sink = &mut *self.sink;
        let mut stream = watch.start(self.client.simple_query(text)).await?;
        let mut open: Option<OpenSet> = None;
        let mut produced = false;
        loop {
            let item = match watch.next(&mut stream).await {
                Ok(Some(item)) => item,
                Ok(None) => break,
                // The server's error closes the response; what it sent
                // before still gets its end.
                Err(Interrupt::Failed(error)) if !ends_connection(&error) => {
                    if let Some(set) = open.take() {
                        finish(sink, set).await;
                    }
                    return Err(Interrupt::Failed(error));
                }
                Err(other) => return Err(other),
            };
            let flow = match item {
                QueryItem::Metadata(metadata) => {
                    produced = true;
                    if let Some(set) = open.take()
                        && finish(sink, set).await == SinkFlow::ConsumerGone
                    {
                        return Ok(BatchEnd::ConsumerGone);
                    }
                    open = Some(OpenSet::default());
                    let columns: Arc<[ResultColumn]> = metadata.columns().iter().map(result_column).collect();
                    sink.accept(ResultEvent::ResultSetStarted { columns }).await
                }
                QueryItem::Row(row) => match open.as_mut() {
                    Some(set) => keep(sink, set, limit, || decode_row(&row)).await,
                    None => SinkFlow::Continue,
                },
            };
            if flow == SinkFlow::ConsumerGone {
                return Ok(BatchEnd::ConsumerGone);
            }
        }
        if let Some(set) = open.take()
            && finish(sink, set).await == SinkFlow::ConsumerGone
        {
            return Ok(BatchEnd::ConsumerGone);
        }
        // TDS reports a statement's row count in a DONE token, which
        // tiberius's batch stream does not hand out.
        if !produced
            && sink.accept(ResultEvent::CommandCompleted { rows_affected: None }).await == SinkFlow::ConsumerGone
        {
            return Ok(BatchEnd::ConsumerGone);
        }
        Ok(BatchEnd::Done)
    }
}

/// Keep a row while under the limit; past it only count, without
/// converting the row, so the total can still be reported.
async fn keep(
    sink: &mut dyn ResultSink,
    set: &mut OpenSet,
    limit: u64,
    values: impl FnOnce() -> Vec<Value>,
) -> SinkFlow {
    set.total += 1;
    if set.retained < limit {
        set.batch.push(values());
        set.retained += 1;
        if set.batch.len() < BATCH_ROWS {
            return SinkFlow::Continue;
        }
        return sink.accept(ResultEvent::Rows(std::mem::take(&mut set.batch))).await;
    }
    if set.limit_reported {
        return SinkFlow::Continue;
    }
    set.limit_reported = true;
    if !set.batch.is_empty()
        && sink.accept(ResultEvent::Rows(std::mem::take(&mut set.batch))).await == SinkFlow::ConsumerGone
    {
        return SinkFlow::ConsumerGone;
    }
    sink.accept(ResultEvent::RowLimitReached { retained: set.retained })
        .await
}

async fn finish(sink: &mut dyn ResultSink, mut set: OpenSet) -> SinkFlow {
    if !set.batch.is_empty()
        && sink.accept(ResultEvent::Rows(std::mem::take(&mut set.batch))).await == SinkFlow::ConsumerGone
    {
        return SinkFlow::ConsumerGone;
    }
    sink.accept(ResultEvent::ResultSetFinished {
        retained: set.retained,
        total_rows: Some(set.total),
        truncation: match set.total > set.retained {
            true => Truncation::ReadPastLimit,
            false => Truncation::Complete,
        },
    })
    .await
}

/// How a stopped run ends: as its reason, and as a server-side stop
/// only where the server confirmed it.
fn end_after_stop(request: &StopRequest, error: Option<DriverError>) -> RunEnd {
    let confirmed = matches!(error, Some(DriverError::Cancelled));
    match request.reason() {
        Some(StopReason::DeadlineElapsed) => RunEnd::TimedOut {
            server_cancelled: confirmed,
        },
        Some(StopReason::Cancelled | StopReason::Shutdown) | None => RunEnd::Cancelled,
    }
}

/// Where the session's transaction stands, from the server itself.
pub(crate) async fn transaction_state(client: &mut MssqlClient) -> Result<TransactionState, DriverError> {
    let stream = client
        .simple_query("SELECT CAST(@@TRANCOUNT AS int), CAST(XACT_STATE() AS int)")
        .await
        .map_err(map_error)?;
    let row = stream.into_row().await.map_err(map_error)?;
    let Some(row) = row else {
        return Ok(TransactionState::Unknown);
    };
    let values = decode_row(&row);
    let cells = Cells::new(&values, "@@TRANCOUNT");
    Ok(state_of(cells.int(0), cells.int(1)))
}

/// XACT_STATE is -1 when an error has doomed the transaction: it can
/// only be rolled back.
fn state_of(transaction_count: Option<i64>, xact_state: Option<i64>) -> TransactionState {
    match (transaction_count, xact_state) {
        (Some(0), _) => TransactionState::Idle,
        (Some(_), Some(-1)) => TransactionState::Failed,
        (Some(_), Some(_)) => TransactionState::InTransaction,
        _ => TransactionState::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use async_trait::async_trait;

    use super::*;

    #[derive(Clone, Default)]
    struct Recording(Arc<Mutex<Vec<ResultEvent>>>);

    #[async_trait]
    impl ResultSink for Recording {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.0.lock().unwrap().push(event);
            SinkFlow::Continue
        }
    }

    #[test]
    fn transaction_state_in_transaction_and_failed() {
        assert_eq!(state_of(Some(0), Some(0)), TransactionState::Idle);
        assert_eq!(state_of(Some(1), Some(1)), TransactionState::InTransaction);
        assert_eq!(state_of(Some(2), Some(1)), TransactionState::InTransaction);
        assert_eq!(state_of(Some(1), Some(-1)), TransactionState::Failed);
        assert_eq!(state_of(None, None), TransactionState::Unknown);
    }

    #[test]
    fn a_stop_ends_the_run_as_its_reason() {
        let deadline = StopRequest::new();
        deadline.request(StopReason::DeadlineElapsed);
        let cancel = StopRequest::new();
        cancel.request(StopReason::Cancelled);

        assert_eq!(
            end_after_stop(&deadline, Some(DriverError::Cancelled)),
            RunEnd::TimedOut { server_cancelled: true }
        );
        assert_eq!(
            end_after_stop(&deadline, None),
            RunEnd::TimedOut {
                server_cancelled: false
            }
        );
        assert_eq!(end_after_stop(&cancel, None), RunEnd::Cancelled);
    }

    #[tokio::test]
    async fn rows_past_the_limit_are_counted_not_kept() {
        let recording = Recording::default();
        let mut sink = recording.clone();
        let mut set = OpenSet::default();

        for row in 0..5 {
            keep(&mut sink, &mut set, 2, || vec![Value::Int(row)]).await;
        }
        finish(&mut sink, set).await;

        let events = recording.0.lock().unwrap().clone();
        assert_eq!(
            events,
            vec![
                ResultEvent::Rows(vec![vec![Value::Int(0)], vec![Value::Int(1)]]),
                ResultEvent::RowLimitReached { retained: 2 },
                ResultEvent::ResultSetFinished {
                    retained: 2,
                    total_rows: Some(5),
                    truncation: Truncation::ReadPastLimit,
                },
            ]
        );
    }
}
