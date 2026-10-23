use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use redis::Value as Reply;
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::sql_syntax::redis::{EditorUse, command_access, editor_use, split_commands};
use tablepro_core::{
    DriverError, ReadOnlyRefusal, ResultSink, RunEnd, RunOptions, RunSummary, SinkFlow, TransactionState,
    UnsupportedFeature, UserSql,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::endpoint::RedisEndpoint;
use crate::errors::{invalid_arguments, is_unblocked};
use crate::link::{Link, command};
use crate::reply_rows::{emit, reply_shape};

/// Why a run stopped before its command did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Interrupt {
    Cancelled,
    DeadlineElapsed,
}

/// What became of one command sent.
enum Sent {
    Reply(Reply),
    /// The command was stopped. `reply` is what it answered within the
    /// grace, the `UNBLOCKED` error or a reply that won the race.
    Stopped {
        interrupt: Interrupt,
        reply: Option<Reply>,
    },
    /// The link failed under the command.
    Lost(DriverError),
}

/// One run of an editor tab's text on its link: each command in turn,
/// until one fails or the run is stopped.
pub(crate) struct EditorRun {
    pub(crate) link: Link,
    pub(crate) endpoint: Arc<RedisEndpoint>,
    pub(crate) read_only: bool,
    pub(crate) statement_timeout: Option<Duration>,
    pub(crate) shutdown: CancellationToken,
    pub(crate) transaction: Arc<Mutex<TransactionState>>,
}

impl EditorRun {
    /// The run's outcome, and whether the link is still in step for the
    /// next run: a command stopped past the grace leaves its reply owed.
    pub(crate) async fn run(
        self,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> (Result<RunSummary, DriverError>, bool) {
        let started = Instant::now();
        let run_deadline = options.deadline.map(|bound| started + bound);
        for lexed in split_commands(sql.as_str()) {
            let arguments = match lexed.values {
                Ok(arguments) => arguments,
                Err(error) => return (Ok(self.summary(started, RunEnd::Failed(invalid_arguments(error)))), true),
            };
            if let Some(refused) = self.refusal(&arguments) {
                return (Ok(self.summary(started, RunEnd::Failed(refused))), true);
            }
            let deadline = match (run_deadline, self.statement_timeout) {
                (Some(run), Some(statement)) => Some(run.min(Instant::now() + statement)),
                (run, statement) => run.or_else(|| statement.map(|statement| Instant::now() + statement)),
            };
            let (reply, end) = match self.send(&arguments, &options.cancel, deadline).await {
                Sent::Reply(reply) => (reply, None),
                Sent::Stopped { interrupt, reply } => {
                    let server_cancelled = matches!(&reply, Some(Reply::ServerError(error)) if is_unblocked_reply(error));
                    let kept = reply.is_some();
                    let end = match interrupt {
                        Interrupt::Cancelled => RunEnd::Cancelled,
                        Interrupt::DeadlineElapsed => RunEnd::TimedOut { server_cancelled },
                    };
                    match reply.filter(|_| !server_cancelled) {
                        Some(reply) => (reply, Some((end, kept))),
                        None => {
                            if !kept {
                                self.forget_transaction();
                            }
                            return (Ok(self.summary(started, end)), kept);
                        }
                    }
                }
                Sent::Lost(error) => {
                    self.forget_transaction();
                    return (Err(error), false);
                }
            };
            self.track(&arguments, &reply);
            let flow = match reply_shape(reply) {
                Ok(shape) => emit(sink.as_mut(), shape, Some(options.row_limit)).await,
                Err(error) => return (Ok(self.summary(started, RunEnd::Failed(error))), true),
            };
            if let Some((end, kept)) = end {
                return (Ok(self.summary(started, end)), kept);
            }
            if flow == SinkFlow::ConsumerGone {
                return (Ok(self.summary(started, RunEnd::Cancelled)), true);
            }
        }
        (Ok(self.summary(started, RunEnd::Completed)), true)
    }

    /// Why the command is not sent at all: it would turn the link into a
    /// stream the editor cannot read, or it writes on a read-only
    /// connection, which Redis itself cannot refuse.
    fn refusal(&self, arguments: &[Vec<u8>]) -> Option<DriverError> {
        if let EditorUse::Refused(command) = editor_use(arguments) {
            return Some(DriverError::Unsupported {
                feature: UnsupportedFeature::EditorCommand { command },
            });
        }
        (self.read_only && command_access(arguments) != StatementAccess::Read)
            .then_some(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
    }

    /// Send one command and wait for its reply, or stop it: `CLIENT
    /// UNBLOCK` ends a command waiting on a key or a replica, and the
    /// reply then comes back as an error. A command that is still busy
    /// on the server after the grace, which nothing can interrupt, costs
    /// the link: the server is told to drop it, and it is closed.
    async fn send(&self, arguments: &[Vec<u8>], cancel: &CancellationToken, deadline: Option<Instant>) -> Sent {
        let packed = command(arguments);
        let mut reply = std::pin::pin!(self.link.send(&packed));
        let interrupt = tokio::select! {
            biased;
            outcome = &mut reply => return match outcome {
                Ok(reply) => Sent::Reply(reply),
                Err(error) => Sent::Lost(self.endpoint.explain(error).await),
            },
            () = cancel.cancelled() => Interrupt::Cancelled,
            () = self.shutdown.cancelled() => Interrupt::Cancelled,
            () = until(deadline) => Interrupt::DeadlineElapsed,
        };
        let grace_ends = Instant::now() + self.endpoint.liveness().cancel_grace;
        let control = tokio::time::timeout_at(grace_ends, self.endpoint.open()).await.ok().and_then(Result::ok);
        if let (Some(control), Some(id)) = (&control, self.link.client_id()) {
            let unblock = command(&["CLIENT", "UNBLOCK", &id.to_string(), "ERROR"]);
            let _ = tokio::time::timeout_at(grace_ends, control.ask(&unblock)).await;
        }
        match tokio::time::timeout_at(grace_ends, &mut reply).await {
            Ok(Ok(reply)) => Sent::Stopped {
                interrupt,
                reply: Some(reply),
            },
            Ok(Err(error)) => Sent::Lost(self.endpoint.explain(error).await),
            Err(_) => {
                if let (Some(control), Some(id)) = (&control, self.link.client_id()) {
                    let kill = command(&["CLIENT", "KILL", "ID", &id.to_string()]);
                    let grace = self.endpoint.liveness().cancel_grace;
                    let _ = tokio::time::timeout(grace, control.ask(&kill)).await;
                }
                Sent::Stopped { interrupt, reply: None }
            }
        }
    }

    /// Where the link's `MULTI` stands after `reply` to `arguments`.
    fn track(&self, arguments: &[Vec<u8>], reply: &Reply) {
        let name = arguments
            .first()
            .map(|name| String::from_utf8_lossy(name).to_ascii_uppercase())
            .unwrap_or_default();
        let mut state = self.transaction.lock().unwrap_or_else(PoisonError::into_inner);
        *state = match (name.as_str(), reply, *state) {
            ("MULTI", Reply::Okay, _) => TransactionState::InTransaction,
            ("EXEC" | "DISCARD" | "RESET", _, _) => TransactionState::Idle,
            // A command that cannot be queued makes EXEC abort them all.
            (_, Reply::ServerError(_), TransactionState::InTransaction) => TransactionState::Failed,
            (_, _, current) => current,
        };
    }

    fn forget_transaction(&self) {
        *self.transaction.lock().unwrap_or_else(PoisonError::into_inner) = TransactionState::Unknown;
    }

    fn summary(&self, started: Instant, end: RunEnd) -> RunSummary {
        RunSummary {
            elapsed: started.elapsed(),
            end,
            transaction_state: *self.transaction.lock().unwrap_or_else(PoisonError::into_inner),
        }
    }
}

fn is_unblocked_reply(error: &redis::ServerError) -> bool {
    is_unblocked(&crate::errors::server_error(error))
}

async fn until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}
