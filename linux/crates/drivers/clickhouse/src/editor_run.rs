use std::sync::Arc;
use std::time::Duration;

use tablepro_core::column::ResultColumn;
use tablepro_core::{
    DriverError, ErrorCategory, LossPhase, ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, SinkFlow,
    TimeoutPhase, TransactionState, Truncation, UserSql, Value,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::call_client::whole_seconds;
use crate::cancel::{acknowledges_stop, kill_query};
use crate::errors::{code, server_code};
use crate::result_reader::{ReadEvent, ResultReader};

/// Rows per `ResultEvent::Rows`. The sink is awaited per batch, so a slow
/// grid slows the read instead of growing a queue.
const BATCH_ROWS: usize = 256;

/// Why a run stopped before its statement did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Interrupt {
    Cancelled,
    DeadlineElapsed,
    /// The sink said nobody is reading any more.
    ConsumerGone,
}

/// One run of user SQL on an editor session's client.
pub(crate) struct EditorRun {
    pub(crate) session: clickhouse::Client,
    pub(crate) control: clickhouse::Client,
    pub(crate) statement_timeout: Option<Duration>,
    pub(crate) grace: Duration,
    pub(crate) shutdown: CancellationToken,
}

/// What a run ended with, or the session being gone.
pub(crate) type RunOutcome = Result<RunSummary, DriverError>;

impl EditorRun {
    /// Send the statement and stream what comes back.
    ///
    /// A stop sends KILL QUERY for this run's query id and keeps reading,
    /// because the server answers the KILL by ending the response; only
    /// a server that has not answered within the grace is cut off.
    pub(crate) async fn run(self, sql: UserSql, options: RunOptions, sink: Box<dyn ResultSink>) -> RunOutcome {
        let started = Instant::now();
        if sql.is_empty() {
            return Ok(summary(started, RunEnd::Completed));
        }
        let bound = match (options.deadline, self.statement_timeout) {
            (Some(run), Some(statement)) => Some(run.min(statement)),
            (run, statement) => run.or(statement),
        };
        let query_id = Uuid::new_v4();
        let mut query = self
            .session
            .query_raw(sql.as_str())
            .with_setting("query_id", query_id.to_string());
        if bound.is_some() {
            query = query
                .with_setting("max_execution_time", whole_seconds(bound).to_string())
                .with_setting("timeout_overflow_mode", "throw");
        }
        let deadline = bound.map(|bound| started + bound);
        let mut reader = match ResultReader::open(query) {
            Ok(reader) => reader,
            Err(error) => return Ok(summary(started, RunEnd::Failed(error))),
        };
        let mut emitter = Emitter::new(sink, options.row_limit);
        let mut stop = Stop::new(options.cancel, self.shutdown.clone(), deadline, self.grace);
        let end = loop {
            let event = tokio::select! {
                biased;
                event = reader.next_event() => event,
                interrupt = stop.triggered(), if stop.fired.is_none() => {
                    stop.fire(interrupt, &self.control, query_id);
                    continue;
                }
                () = stop.gave_up(), if stop.fired.is_some() => {
                    break stop.end(None);
                }
            };
            match event {
                Ok(ReadEvent::Columns(columns)) => emitter.start(columns).await,
                Ok(ReadEvent::Row(row)) => {
                    if emitter.row(row).await {
                        emitter.limit_reached().await;
                        // The rest of the result is not wanted, so the read
                        // stops on the server before its body is dropped.
                        kill_within(&self.control, query_id, self.grace).await;
                        break stop.fired.map_or(RunEnd::Completed, |_| stop.end(None));
                    }
                }
                Ok(ReadEvent::End) => {
                    emitter.finish(reader.has_result_set(), reader.written_rows()).await;
                    break stop.fired.map_or(RunEnd::Completed, |_| stop.end(None));
                }
                Err(error) if stop.fired.is_some() => break stop.end(Some(&error)),
                Err(error) if lost(&error) => {
                    return Err(DriverError::ConnectionLost {
                        during: LossPhase::Statement,
                    });
                }
                // The server let the session expire, and with it what the
                // tab built up there; carrying on in a new one would hide
                // that.
                Err(error) if server_code(&error) == Some(code::SESSION_NOT_FOUND) => {
                    return Err(DriverError::ConnectionLost {
                        during: LossPhase::Idle,
                    });
                }
                Err(DriverError::Timeout {
                    phase: TimeoutPhase::Statement,
                    server_cancelled,
                }) => break RunEnd::TimedOut { server_cancelled },
                Err(error) if unreadable(&error) => {
                    // The server is still sending what the driver could not
                    // read, so the query is stopped there before its body
                    // is dropped.
                    kill_within(&self.control, query_id, self.grace).await;
                    break RunEnd::Failed(error);
                }
                Err(error) => break RunEnd::Failed(error),
            }
            if emitter.consumer_gone && stop.fired.is_none() {
                stop.fire(Interrupt::ConsumerGone, &self.control, query_id);
            }
        };
        Ok(summary(started, end))
    }
}

fn summary(started: Instant, end: RunEnd) -> RunSummary {
    RunSummary {
        elapsed: started.elapsed(),
        end,
        // ClickHouse has no transaction an editor statement can leave
        // open.
        transaction_state: TransactionState::Idle,
    }
}

/// A failure of the route rather than of the statement.
fn lost(error: &DriverError) -> bool {
    matches!(
        error.category(),
        ErrorCategory::Network | ErrorCategory::ConnectionLost | ErrorCategory::Tls
    )
}

/// A body the driver gave up reading, while the server may still be
/// producing it.
fn unreadable(error: &DriverError) -> bool {
    matches!(error, DriverError::Protocol(_) | DriverError::Decode { .. })
}

/// A KILL that gives up after `grace`: on a route that stopped
/// answering, it would otherwise wait, and hold its connection, for good.
async fn kill_within(control: &clickhouse::Client, query_id: Uuid, grace: Duration) {
    match tokio::time::timeout(grace, kill_query(control, query_id)).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::debug!(%error, "the KILL QUERY for an editor run failed"),
        Err(_) => tracing::debug!("the KILL QUERY for an editor run got no answer"),
    }
}

/// What stops a run, and when the stop was sent.
struct Stop {
    cancel: CancellationToken,
    shutdown: CancellationToken,
    deadline: Option<Instant>,
    grace: Duration,
    fired: Option<Interrupt>,
    give_up: Option<Instant>,
}

impl Stop {
    fn new(cancel: CancellationToken, shutdown: CancellationToken, deadline: Option<Instant>, grace: Duration) -> Self {
        Self {
            cancel,
            shutdown,
            deadline,
            grace,
            fired: None,
            give_up: None,
        }
    }

    async fn triggered(&self) -> Interrupt {
        let deadline = async {
            match self.deadline {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            () = self.cancel.cancelled() => Interrupt::Cancelled,
            () = self.shutdown.cancelled() => Interrupt::Cancelled,
            () = deadline => Interrupt::DeadlineElapsed,
        }
    }

    /// Record the stop and send the KILL on a task of its own, so the run
    /// keeps reading the answer it brings.
    fn fire(&mut self, interrupt: Interrupt, control: &clickhouse::Client, query_id: Uuid) {
        self.fired = Some(interrupt);
        self.give_up = Some(Instant::now() + self.grace);
        let control = control.clone();
        let grace = self.grace;
        tokio::spawn(async move { kill_within(&control, query_id, grace).await });
    }

    async fn gave_up(&self) {
        match self.give_up {
            Some(at) => tokio::time::sleep_until(at).await,
            None => std::future::pending().await,
        }
    }

    /// How a stopped run ends. The server's 394 or its own timeout is the
    /// acknowledgement; anything else was the statement's own end.
    fn end(&self, error: Option<&DriverError>) -> RunEnd {
        match self.fired {
            Some(Interrupt::DeadlineElapsed) => RunEnd::TimedOut {
                server_cancelled: error.is_some_and(|error| {
                    acknowledges_stop(error)
                        || matches!(
                            error,
                            DriverError::Timeout {
                                server_cancelled: true,
                                ..
                            }
                        )
                }),
            },
            Some(Interrupt::Cancelled | Interrupt::ConsumerGone) | None => RunEnd::Cancelled,
        }
    }
}

/// The run's events, batched, with the row limit applied.
struct Emitter {
    sink: Box<dyn ResultSink>,
    limit: RowLimit,
    batch: Vec<Vec<Value>>,
    retained: u64,
    consumer_gone: bool,
}

impl Emitter {
    fn new(sink: Box<dyn ResultSink>, limit: RowLimit) -> Self {
        Self {
            sink,
            limit,
            batch: Vec::new(),
            retained: 0,
            consumer_gone: false,
        }
    }

    async fn start(&mut self, columns: Arc<[ResultColumn]>) {
        self.send(ResultEvent::ResultSetStarted { columns }).await;
    }

    /// Keep a row, or say the limit was passed: the row past the limit is
    /// the proof there were more.
    async fn row(&mut self, row: Vec<Value>) -> bool {
        if self.retained >= self.limit.get() {
            return true;
        }
        self.batch.push(row);
        self.retained += 1;
        if self.batch.len() >= BATCH_ROWS {
            self.flush().await;
        }
        false
    }

    async fn limit_reached(&mut self) {
        self.flush().await;
        self.send(ResultEvent::RowLimitReached {
            retained: self.retained,
        })
        .await;
        self.send(ResultEvent::ResultSetFinished {
            retained: self.retained,
            total_rows: None,
            truncation: Truncation::ReadPastLimit,
        })
        .await;
    }

    async fn finish(&mut self, result_set: bool, written_rows: Option<u64>) {
        if !result_set {
            self.send(ResultEvent::CommandCompleted {
                rows_affected: written_rows.filter(|rows| *rows > 0),
            })
            .await;
            return;
        }
        self.flush().await;
        self.send(ResultEvent::ResultSetFinished {
            retained: self.retained,
            total_rows: Some(self.retained),
            truncation: Truncation::Complete,
        })
        .await;
    }

    async fn flush(&mut self) {
        if self.batch.is_empty() {
            return;
        }
        let rows = std::mem::take(&mut self.batch);
        self.send(ResultEvent::Rows(rows)).await;
    }

    async fn send(&mut self, event: ResultEvent) {
        if self.consumer_gone {
            return;
        }
        if self.sink.accept(event).await == SinkFlow::ConsumerGone {
            self.consumer_gone = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ServerCode, ServerDiagnostics};

    use super::*;

    #[tokio::test]
    async fn a_kill_the_server_never_answers_gives_up_at_the_grace() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("a listener");
        let address = listener.local_addr().expect("an address");
        let silent = tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((socket, _)) = listener.accept().await {
                held.push(socket);
            }
        });
        let control = clickhouse::Client::default().with_url(format!("http://{address}"));

        let killing = kill_within(&control, Uuid::new_v4(), Duration::from_millis(200));

        assert!(
            tokio::time::timeout(Duration::from_secs(10), killing).await.is_ok(),
            "the KILL waited on a server that never answered"
        );
        silent.abort();
    }

    #[test]
    fn only_a_body_the_driver_could_not_read_is_killed_after_it_fails() {
        let refused = DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::ClickHouse { code: 62 }),
            "Code: 62. DB::Exception: Syntax error",
        ));

        assert!(unreadable(&DriverError::Protocol("a row ran past 256 MiB".to_owned())));
        assert!(unreadable(&DriverError::Decode {
            column: "c".to_owned(),
            detail: "not a number".to_owned(),
        }));
        assert!(!unreadable(&refused));
    }

    fn stopped(interrupt: Interrupt) -> Stop {
        let mut stop = Stop::new(
            CancellationToken::new(),
            CancellationToken::new(),
            None,
            Duration::from_secs(1),
        );
        stop.fired = Some(interrupt);
        stop
    }

    #[test]
    fn a_stopped_run_ends_by_what_stopped_it() {
        let killed = DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::ClickHouse { code: 394 }),
            "Code: 394. DB::Exception: Query was cancelled",
        ));
        let timed_out = DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        };

        assert_eq!(stopped(Interrupt::Cancelled).end(Some(&killed)), RunEnd::Cancelled);
        assert_eq!(stopped(Interrupt::ConsumerGone).end(None), RunEnd::Cancelled);
        assert_eq!(
            stopped(Interrupt::DeadlineElapsed).end(Some(&killed)),
            RunEnd::TimedOut { server_cancelled: true }
        );
        assert_eq!(
            stopped(Interrupt::DeadlineElapsed).end(Some(&timed_out)),
            RunEnd::TimedOut { server_cancelled: true }
        );
        assert_eq!(
            stopped(Interrupt::DeadlineElapsed).end(None),
            RunEnd::TimedOut {
                server_cancelled: false
            }
        );
    }
}
