use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use mongodb::Client;
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::sql_syntax::mongo::{access_of, parse_statement, statement_ranges};
use tablepro_core::{
    DriverError, ErrorCategory, ReadOnlyRefusal, ResultSink, RunEnd, RunOptions, RunSummary, SinkFlow, TimeoutPhase,
    TransactionState, UserSql,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::call::{SessionKill, remaining_millis, session};
use crate::endpoint::MongoEndpoint;
use crate::errors::{stopped_by_kill, syntax_error};
use crate::execute::{Source, start};
use crate::rows::emit;
use crate::shell_command::plan;

/// Why a run stopped before its statement did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Interrupt {
    Cancelled,
    DeadlineElapsed,
}

impl Interrupt {
    fn end(self, server_cancelled: bool) -> RunEnd {
        match self {
            Self::Cancelled => RunEnd::Cancelled,
            Self::DeadlineElapsed => RunEnd::TimedOut { server_cancelled },
        }
    }
}

/// What became of one statement.
enum Ran {
    Done(SinkFlow),
    Failed(DriverError),
    Stopped {
        interrupt: Interrupt,
        server_cancelled: bool,
    },
}

/// One run of an editor tab's text: each statement in turn, until one
/// fails or the run is stopped.
pub(crate) struct EditorRun {
    pub(crate) client: Client,
    pub(crate) endpoint: Arc<MongoEndpoint>,
    pub(crate) database: Arc<Mutex<String>>,
    pub(crate) read_only: bool,
    pub(crate) statement_timeout: Option<Duration>,
    pub(crate) shutdown: CancellationToken,
}

impl EditorRun {
    /// The run's outcome. An `Err` is the session lost: its connection
    /// failed under a statement.
    pub(crate) async fn run(
        self,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let started = Instant::now();
        let run_deadline = options.deadline.map(|bound| started + bound);
        let text = sql.as_str();
        for range in statement_ranges(text) {
            let statement = match parse_statement(&text[range.clone()]) {
                Ok(statement) => statement,
                Err(error) => {
                    return Ok(summary(
                        started,
                        RunEnd::Failed(syntax_error(&error, text, range.start)),
                    ));
                }
            };
            if self.read_only && access_of(&statement) != StatementAccess::Read {
                return Ok(summary(
                    started,
                    RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
                ));
            }
            let deadline = match (run_deadline, self.statement_timeout) {
                (Some(run), Some(statement)) => Some(run.min(Instant::now() + statement)),
                (run, statement) => run.or_else(|| statement.map(|statement| Instant::now() + statement)),
            };
            let database = self.database.lock().unwrap_or_else(PoisonError::into_inner).clone();
            let mut planned = match plan(&statement, &database, &[]) {
                Ok(planned) => planned,
                Err(error) => return Ok(summary(started, RunEnd::Failed(error))),
            };
            planned.limit_time(remaining_millis(deadline));
            if let Some(interrupt) = self.interrupted(&options.cancel, deadline) {
                return Ok(summary(started, interrupt.end(false)));
            }
            let ran = self.statement(planned, sink.as_mut(), &options, deadline).await;
            match ran {
                Ran::Done(SinkFlow::ConsumerGone) => return Ok(summary(started, RunEnd::Cancelled)),
                Ran::Done(SinkFlow::Continue) => {}
                Ran::Stopped {
                    interrupt,
                    server_cancelled,
                } => return Ok(summary(started, interrupt.end(server_cancelled))),
                Ran::Failed(DriverError::Timeout {
                    phase: TimeoutPhase::Statement,
                    server_cancelled,
                }) => return Ok(summary(started, RunEnd::TimedOut { server_cancelled })),
                Ran::Failed(error) if loses_session(&error) => return Err(error),
                Ran::Failed(error) => return Ok(summary(started, RunEnd::Failed(error))),
            }
        }
        Ok(summary(started, RunEnd::Completed))
    }

    /// Send one statement in a session of its own and stream what it
    /// returns, or stop it: `killSessions` ends what that session runs on
    /// the server, cursors included.
    fn statement<'a>(
        &'a self,
        planned: crate::shell_command::Plan,
        sink: &'a mut dyn ResultSink,
        options: &'a RunOptions,
        deadline: Option<Instant>,
    ) -> Pin<Box<dyn Future<Output = Ran> + Send + 'a>> {
        Box::pin(async move {
            let kill = SessionKill::new();
            let mut session = match session(&self.endpoint, &self.client, &kill).await {
                Ok(session) => session,
                Err(error) => return Ran::Failed(error),
            };
            let work = async {
                match start(&self.endpoint, &self.client, &mut session, planned).await? {
                    Source::Used(next) => {
                        *self.database.lock().unwrap_or_else(PoisonError::into_inner) = next.clone();
                        emit(&self.endpoint, Source::Used(next), &mut session, sink, None)
                            .await
                            .map(|(flow, _)| flow)
                    }
                    source => emit(&self.endpoint, source, &mut session, sink, Some(options.row_limit))
                        .await
                        .map(|(flow, _)| flow),
                }
            };
            let mut work = std::pin::pin!(work);
            let interrupt = tokio::select! {
                biased;
                outcome = &mut work => return match outcome {
                    Ok(flow) => Ran::Done(flow),
                    Err(error) => Ran::Failed(error),
                },
                () = options.cancel.cancelled() => Interrupt::Cancelled,
                () = self.shutdown.cancelled() => Interrupt::Cancelled,
                () = until(deadline) => Interrupt::DeadlineElapsed,
            };
            let grace_ends = Instant::now() + self.endpoint.cancel_grace();
            let _ = tokio::time::timeout_at(grace_ends, kill.kill()).await;
            let server_cancelled = match tokio::time::timeout_at(grace_ends, &mut work).await {
                Ok(Err(error)) => {
                    stopped_by_kill(&error)
                        || matches!(
                            error,
                            DriverError::Timeout {
                                server_cancelled: true,
                                ..
                            }
                        )
                }
                Ok(Ok(_)) | Err(_) => false,
            };
            Ran::Stopped {
                interrupt,
                server_cancelled,
            }
        })
    }

    fn interrupted(&self, cancel: &CancellationToken, deadline: Option<Instant>) -> Option<Interrupt> {
        if cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return Some(Interrupt::Cancelled);
        }
        deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
            .then_some(Interrupt::DeadlineElapsed)
    }
}

/// A failure that means the tab's client lost the server, rather than
/// the server refusing the statement.
fn loses_session(error: &DriverError) -> bool {
    matches!(error.category(), ErrorCategory::Network | ErrorCategory::ConnectionLost)
}

fn summary(started: Instant, end: RunEnd) -> RunSummary {
    RunSummary {
        elapsed: started.elapsed(),
        end,
        transaction_state: TransactionState::Idle,
    }
}

async fn until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}
