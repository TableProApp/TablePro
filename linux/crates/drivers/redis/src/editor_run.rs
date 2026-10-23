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
use crate::reply_rows::{ReplyShape, emit, reply_shape};

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
        /// No `CLIENT UNBLOCK` is still on its way. One the server never
        /// answered may reach it during the next run, and stop that.
        settled: bool,
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
                Err(error) => {
                    return (
                        Ok(self.summary(started, RunEnd::Failed(invalid_arguments(error)))),
                        true,
                    );
                }
            };
            if let Some(refused) = self.refusal(&arguments) {
                return (Ok(self.summary(started, RunEnd::Failed(refused))), true);
            }
            let deadline = match (run_deadline, self.statement_timeout) {
                (Some(run), Some(statement)) => Some(run.min(Instant::now() + statement)),
                (run, statement) => run.or_else(|| statement.map(|statement| Instant::now() + statement)),
            };
            // Once polled, the send has written the command, so a stop that
            // came first must be seen here.
            if let Some(interrupt) = self.interrupted(&options.cancel, deadline) {
                return (Ok(self.summary(started, interrupt.end(false))), true);
            }
            let (reply, end) = match self.send(&arguments, &options.cancel, deadline).await {
                Sent::Reply(reply) => (reply, None),
                Sent::Stopped {
                    interrupt,
                    reply,
                    settled,
                } => {
                    let server_cancelled =
                        matches!(&reply, Some(Reply::ServerError(error)) if is_unblocked_reply(error));
                    let kept = in_step_after_stop(reply.as_ref(), settled);
                    let end = interrupt.end(server_cancelled);
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
            let delivered = match reply_shape(reply) {
                Ok(shape) => self.deliver(sink.as_mut(), shape, &options, deadline).await,
                Err(error) => return (Ok(self.summary(started, RunEnd::Failed(error))), true),
            };
            if let Some((end, kept)) = end {
                if !kept {
                    self.forget_transaction();
                }
                return (Ok(self.summary(started, end)), kept);
            }
            match delivered {
                Ok(SinkFlow::ConsumerGone) => return (Ok(self.summary(started, RunEnd::Cancelled)), true),
                Ok(SinkFlow::Continue) => {}
                Err(interrupt) => return (Ok(self.summary(started, interrupt.end(false))), true),
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

    fn interrupted(&self, cancel: &CancellationToken, deadline: Option<Instant>) -> Option<Interrupt> {
        if cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return Some(Interrupt::Cancelled);
        }
        deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
            .then_some(Interrupt::DeadlineElapsed)
    }

    /// Hand the reply to the sink, unless a stop comes while the sink is
    /// full. The reply is read whole, so the link stays in step.
    async fn deliver(
        &self,
        sink: &mut dyn ResultSink,
        shape: ReplyShape,
        options: &RunOptions,
        deadline: Option<Instant>,
    ) -> Result<SinkFlow, Interrupt> {
        tokio::select! {
            biased;
            flow = emit(sink, shape, Some(options.row_limit)) => Ok(flow),
            () = options.cancel.cancelled() => Err(Interrupt::Cancelled),
            () = self.shutdown.cancelled() => Err(Interrupt::Cancelled),
            () = until(deadline) => Err(Interrupt::DeadlineElapsed),
        }
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
        let control = tokio::time::timeout_at(grace_ends, self.endpoint.open())
            .await
            .ok()
            .and_then(Result::ok);
        let mut settled = true;
        if let (Some(control), Some(id)) = (&control, self.link.client_id()) {
            let unblock = command(&["CLIENT", "UNBLOCK", &id.to_string(), "ERROR"]);
            settled = tokio::time::timeout_at(grace_ends, control.ask(&unblock)).await.is_ok();
        }
        match tokio::time::timeout_at(grace_ends, &mut reply).await {
            Ok(Ok(reply)) => Sent::Stopped {
                interrupt,
                reply: Some(reply),
                settled,
            },
            Ok(Err(error)) => Sent::Lost(self.endpoint.explain(error).await),
            Err(_) => {
                if let (Some(control), Some(id)) = (&control, self.link.client_id()) {
                    let kill = command(&["CLIENT", "KILL", "ID", &id.to_string()]);
                    let grace = self.endpoint.liveness().cancel_grace;
                    let _ = tokio::time::timeout(grace, control.ask(&kill)).await;
                }
                Sent::Stopped {
                    interrupt,
                    reply: None,
                    settled,
                }
            }
        }
    }

    fn track(&self, arguments: &[Vec<u8>], reply: &Reply) {
        let name = arguments
            .first()
            .map(|name| String::from_utf8_lossy(name).to_ascii_uppercase())
            .unwrap_or_default();
        let mut state = self.transaction.lock().unwrap_or_else(PoisonError::into_inner);
        *state = next_transaction_state(&name, reply, *state);
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

impl Interrupt {
    fn end(self, server_cancelled: bool) -> RunEnd {
        match self {
            Self::Cancelled => RunEnd::Cancelled,
            Self::DeadlineElapsed => RunEnd::TimedOut { server_cancelled },
        }
    }
}

/// Where a link's `MULTI` stands once the command `name` got `reply`.
fn next_transaction_state(name: &str, reply: &Reply, current: TransactionState) -> TransactionState {
    let open = matches!(current, TransactionState::InTransaction | TransactionState::Failed);
    match (name, reply) {
        ("MULTI", Reply::Okay) => TransactionState::InTransaction,
        ("EXEC", Reply::ServerError(error)) if error.code() == "EXECABORT" => TransactionState::Idle,
        // Redis refuses a nested MULTI and a WATCH inside one without
        // touching the transaction.
        ("MULTI" | "WATCH", Reply::ServerError(_)) => current,
        // Any other refusal, EXEC's and DISCARD's included, keeps the
        // transaction open and makes its EXEC abort.
        (_, Reply::ServerError(_)) if open => TransactionState::Failed,
        ("EXEC" | "DISCARD" | "RESET", Reply::ServerError(_)) => current,
        ("EXEC" | "DISCARD" | "RESET", _) => TransactionState::Idle,
        _ => current,
    }
}

/// Whether the link can run the next command after a stop: the reply
/// came, and no unblock is left on its way to the server. An `UNBLOCKED`
/// reply is the server acting on the unblock.
fn in_step_after_stop(reply: Option<&Reply>, settled: bool) -> bool {
    match reply {
        Some(Reply::ServerError(error)) if is_unblocked_reply(error) => true,
        Some(_) => settled,
        None => false,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn error(line: &str) -> Reply {
        redis::parse_redis_value(format!("-{line}\r\n").as_bytes()).unwrap()
    }

    #[test]
    fn exec_and_discard_end_the_transaction_they_run() {
        use TransactionState::{Failed, Idle, InTransaction};
        let queued = Reply::SimpleString("QUEUED".to_owned());

        assert_eq!(next_transaction_state("MULTI", &Reply::Okay, Idle), InTransaction);
        assert_eq!(next_transaction_state("SET", &queued, InTransaction), InTransaction);
        assert_eq!(
            next_transaction_state("EXEC", &Reply::Array(Vec::new()), InTransaction),
            Idle
        );
        assert_eq!(next_transaction_state("EXEC", &Reply::Nil, InTransaction), Idle);
        assert_eq!(next_transaction_state("DISCARD", &Reply::Okay, Failed), Idle);
        assert_eq!(
            next_transaction_state("EXEC", &error("EXECABORT Transaction discarded"), Failed),
            Idle
        );
    }

    #[test]
    fn a_refused_exec_or_discard_leaves_the_transaction_open() {
        use TransactionState::{Failed, Idle, InTransaction, Unknown};
        let arity = error("ERR wrong number of arguments for 'exec' command");

        assert_eq!(next_transaction_state("EXEC", &arity, InTransaction), Failed);
        assert_eq!(next_transaction_state("DISCARD", &arity, InTransaction), Failed);
        assert_eq!(next_transaction_state("RESET", &arity, Failed), Failed);
        assert_eq!(
            next_transaction_state("EXEC", &error("ERR EXEC without MULTI"), Idle),
            Idle
        );
        assert_eq!(next_transaction_state("EXEC", &arity, Unknown), Unknown);
    }

    #[test]
    fn a_link_whose_unblock_may_still_arrive_is_not_used_again() {
        let unblocked = error("UNBLOCKED client unblocked via CLIENT UNBLOCK");

        assert!(in_step_after_stop(Some(&Reply::Okay), true));
        assert!(!in_step_after_stop(Some(&Reply::Okay), false));
        assert!(in_step_after_stop(Some(&unblocked), false));
        assert!(!in_step_after_stop(None, true));
    }

    #[test]
    fn a_nested_multi_or_a_watch_inside_one_changes_nothing() {
        use TransactionState::InTransaction;

        let nested = error("ERR MULTI calls can not be nested");
        let watch = error("ERR WATCH inside MULTI is not allowed");
        assert_eq!(next_transaction_state("MULTI", &nested, InTransaction), InTransaction);
        assert_eq!(next_transaction_state("WATCH", &watch, InTransaction), InTransaction);
        assert_eq!(
            next_transaction_state("NOSUCH", &error("ERR unknown command"), InTransaction),
            TransactionState::Failed
        );
    }
}
