use std::future::Future;
use std::sync::Arc;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::SinkExt;
use tablepro_core::{CopyInPiece, CopyInRows, DriverError, ResultEvent, ResultSink, RunEnd, SinkFlow};
use tokio_postgres::CancelToken;

use super::editor_dispatch::{CopyFlight, copy_plan};
use super::run::{Run, end_after_stop};
use super::session_core::Lost;
use super::stop_watch::StopWatch;
use super::transaction_tracker::KnownState;
use crate::errors::map_error;
use crate::physical::PgEndpoint;

/// How a copy ended.
pub(crate) struct Copied {
    pub(crate) end: RunEnd,
    pub(crate) rows: u64,
}

impl Copied {
    fn ended(end: RunEnd) -> Self {
        Self { end, rows: 0 }
    }
}

/// What the copy came to, before the driver's own transaction ends.
enum Flown {
    Copied(u64),
    /// The server refused the statement or a row, or the end of the copy.
    Failed(DriverError),
    /// Stopped, or the rows' source gave up, so the copy was failed on
    /// purpose and the server's answer to that is not the end.
    Abandoned,
}

impl Run<'_> {
    /// Run a `COPY ... FROM STDIN` with `rows` as its data, through
    /// tokio-postgres's copy-in on the session's own client.
    pub(crate) async fn copy_in(&mut self, statement: &str, rows: &mut CopyInRows) -> Result<Copied, Lost> {
        if let Some(interrupt) = self.watch.due() {
            self.watch.fire(interrupt, None);
        }
        if let Some(interrupt) = self.watch.fired() {
            return Ok(Copied::ended(end_after_stop(interrupt, &DriverError::Cancelled)));
        }
        self.watch.begin_statement(self.core.statement_timeout());
        let begin = match copy_plan(self.core.tracker.state(), self.core.read_only) {
            CopyFlight::Wrapped { read_only: true } => Some("START TRANSACTION READ ONLY"),
            CopyFlight::Wrapped { read_only: false } => Some("BEGIN"),
            CopyFlight::Plain => None,
        };
        let wrapped = begin.is_some();
        if let Some(begin) = begin
            && let Some(error) = self.control(begin).await?
        {
            return Ok(Copied::ended(self.failed_end(error)));
        }
        let outcome = match (self.copy_rows(statement, rows).await?, self.watch.fired()) {
            (Flown::Copied(rows), None) => Ok(rows),
            (Flown::Failed(error), _) => Err(self.failed_end(error)),
            (Flown::Abandoned, None) => Err(RunEnd::Cancelled),
            (Flown::Copied(_) | Flown::Abandoned, Some(interrupt)) => {
                Err(end_after_stop(interrupt, &DriverError::Cancelled))
            }
        };
        let outcome = match wrapped {
            true => self.end_wrap(outcome).await?,
            false => {
                if outcome.is_err() && self.core.tracker.state() == KnownState::InTransaction {
                    self.core.tracker.set(KnownState::Failed);
                }
                outcome
            }
        };
        Ok(match outcome {
            Ok(rows) => Copied {
                end: RunEnd::Completed,
                rows,
            },
            Err(end) => Copied::ended(end),
        })
    }

    /// Prepare the COPY, start it and send the rows as they come, then
    /// finish it for the server's count. A stop or a source that gives up
    /// drops the sink, which tokio-postgres turns into CopyFail.
    async fn copy_rows(&mut self, statement: &str, rows: &mut CopyInRows) -> Result<Flown, Lost> {
        self.watch.settle().await;
        let running: Running = (Arc::clone(&self.core.endpoint), self.core.cancel_token.clone());
        let client = &self.core.client;
        let prepared = match interruptible(&mut self.watch, &running, client.prepare(statement)).await? {
            Ok(prepared) => prepared,
            Err(error) => return server_error(&error).map(Flown::Failed),
        };
        if self.watch.fired().is_some() {
            return Ok(Flown::Abandoned);
        }
        let started = interruptible(&mut self.watch, &running, client.copy_in::<_, Bytes>(&prepared)).await?;
        let sink = match started {
            Ok(sink) => sink,
            Err(error) => return server_error(&error).map(Flown::Failed),
        };
        let mut sink = std::pin::pin!(sink);
        loop {
            if self.watch.fired().is_some() {
                return Ok(Flown::Abandoned);
            }
            let piece = tokio::select! {
                biased;
                interrupt = self.watch.triggered() => {
                    self.watch.fire(interrupt, Some(running.clone()));
                    return Ok(Flown::Abandoned);
                }
                piece = rows.recv() => piece,
            };
            let bytes = match piece {
                Some(CopyInPiece::Data(bytes)) => bytes,
                Some(CopyInPiece::End) => break,
                None => return Ok(Flown::Abandoned),
            };
            let sent = tokio::select! {
                biased;
                interrupt = self.watch.triggered() => {
                    self.watch.fire(interrupt, Some(running.clone()));
                    return Ok(Flown::Abandoned);
                }
                sent = sink.send(bytes) => sent,
            };
            if let Err(error) = sent {
                return server_error(&error).map(Flown::Failed);
            }
        }
        match interruptible(&mut self.watch, &running, sink.as_mut().finish()).await? {
            Ok(rows) => Ok(Flown::Copied(rows)),
            Err(error) => server_error(&error).map(Flown::Failed),
        }
    }

    /// End the driver's own transaction: COMMIT what copied, ROLLBACK the
    /// rest. A failed COMMIT has rolled back, unless a cancel reached it
    /// before it ran and left the block open, which the ROLLBACK ends.
    async fn end_wrap(&mut self, outcome: Result<u64, RunEnd>) -> Result<Result<u64, RunEnd>, Lost> {
        let ending = match outcome {
            Ok(_) => "COMMIT",
            Err(_) => "ROLLBACK",
        };
        let ended = self.control(ending).await?;
        if ended.is_some() {
            self.control("ROLLBACK").await?;
        }
        self.core.tracker.set(KnownState::Idle);
        Ok(match (outcome, ended) {
            (Ok(_), Some(error)) => Err(self.failed_end(error)),
            (outcome, _) => outcome,
        })
    }

    fn failed_end(&self, error: DriverError) -> RunEnd {
        match self.watch.fired() {
            Some(interrupt) => end_after_stop(interrupt, &error),
            None => RunEnd::Failed(error),
        }
    }
}

/// Where a cancel request for the running statement goes.
type Running = (Arc<PgEndpoint>, CancelToken);

/// Wait for `future`, sending the cancel request for it if the run is
/// stopped meanwhile. Lost once the grace after the stop runs out.
async fn interruptible<T>(
    watch: &mut StopWatch,
    running: &Running,
    future: impl Future<Output = T>,
) -> Result<T, Lost> {
    let mut future = std::pin::pin!(future);
    loop {
        tokio::select! {
            biased;
            done = &mut future => return Ok(done),
            interrupt = watch.triggered(), if watch.fired().is_none() => {
                watch.fire(interrupt, Some(running.clone()));
            }
            () = watch.gave_up(), if watch.fired().is_some() => return Err(Lost),
        }
    }
}

/// A server error is the copy's own answer; any other error means the
/// connection failed.
fn server_error(error: &tokio_postgres::Error) -> Result<DriverError, Lost> {
    match error.as_db_error() {
        Some(_) => Ok(map_error(error)),
        None => Err(Lost),
    }
}

/// A copy's notices and the driver's own statements' answers go nowhere.
pub(crate) struct NoRows;

#[async_trait]
impl ResultSink for NoRows {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        SinkFlow::Continue
    }
}
