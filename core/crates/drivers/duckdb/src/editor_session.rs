use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LivenessPolicy,
    LossPhase, ResultSink, RunEnd, RunOptions, RunSummary, TimeoutPhase, TransactionState, UserSql,
};
use tokio::sync::OwnedMutexGuard;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::connection::{blocking, stream_into};
use crate::errors::is_interrupt;
use crate::instance::{Instance, StopHandle};
use crate::pool::DuckCall;
use crate::result_stream::{StreamOutcome, run_script};
use crate::stop::interrupt_until_settled;
use crate::transaction_state::transaction_state;

/// One editor tab's own connection to the database.
///
/// The tab's transaction and temporary tables live on this connection
/// and nowhere else, so it is never pooled and never reopened behind
/// the user's back. Its connection keeps the database open after the
/// workspace closes.
pub(crate) struct DuckDbEditorSession {
    id: EditorSessionId,
    shared: Arc<Shared>,
}

/// What a run needs once its caller is gone. A run goes on a task of
/// its own, so a dropped caller is a cancel that still interrupts the
/// statement and settles the session.
struct Shared {
    call: Arc<tokio::sync::Mutex<Option<DuckCall>>>,
    stop: StopHandle,
    running: AtomicBool,
    lost: AtomicBool,
    /// Raised to keep the run from starting another statement.
    halt: Arc<AtomicBool>,
    statement_timeout: Option<Duration>,
    cancel_grace: Duration,
    close_timeout: Duration,
}

/// Why a run stopped before it finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stop {
    Cancelled,
    DeadlineElapsed,
}

impl DuckDbEditorSession {
    pub(crate) async fn open(
        instance: Arc<Instance>,
        options: EditorSessionOptions,
        liveness: &LivenessPolicy,
        cancel: CancellationToken,
    ) -> Result<Self, DriverError> {
        let connecting = blocking(move || instance.link());
        let link = tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            opened = tokio::time::timeout(liveness.connect_timeout, connecting) => match opened {
                Ok(link) => link?,
                Err(_) => {
                    return Err(DriverError::Timeout {
                        phase: TimeoutPhase::Connect,
                        server_cancelled: false,
                    });
                }
            },
        };
        let stop = link.stop_handle();
        Ok(Self {
            id: EditorSessionId::new(),
            shared: Arc::new(Shared {
                call: Arc::new(tokio::sync::Mutex::new(Some(DuckCall::own(link)))),
                stop,
                running: AtomicBool::new(false),
                lost: AtomicBool::new(false),
                halt: Arc::new(AtomicBool::new(false)),
                statement_timeout: options.statement_timeout,
                cancel_grace: liveness.cancel_grace,
                close_timeout: liveness.close_timeout,
            }),
        })
    }
}

impl Shared {
    fn state(&self) -> EditorSessionState {
        if self.lost.load(Ordering::SeqCst) {
            EditorSessionState::Lost
        } else if self.running.load(Ordering::SeqCst) {
            EditorSessionState::Running
        } else {
            EditorSessionState::Ready
        }
    }

    /// Keep the run from starting another statement, and interrupt the
    /// one running until it gives way.
    async fn stop(&self) {
        self.halt.store(true, Ordering::SeqCst);
        interrupt_until_settled(&self.stop).await;
    }

    /// One run on the connection `held` holds, which it gives up when
    /// the connection cannot take another.
    async fn run_held(
        &self,
        mut held: OwnedMutexGuard<Option<DuckCall>>,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let usable = held
            .as_mut()
            .filter(|call| call.holds_connection() && !self.lost.load(Ordering::SeqCst));
        let Some(call) = usable else {
            self.lose(&mut held);
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let started = Instant::now();
        self.running.store(true, Ordering::SeqCst);
        self.halt.store(false, Ordering::SeqCst);
        let ended = self.supervise(call, &sql, &options, sink.as_mut()).await;
        let transaction_state = match &ended {
            Ok(_) => self.state_after_run(call).await,
            Err(_) => TransactionState::Unknown,
        };
        let kept = call.holds_connection();
        self.running.store(false, Ordering::SeqCst);
        let end = match ended {
            Ok(end) => end,
            Err(error) => {
                self.lose(&mut held);
                return Err(error);
            }
        };
        // The state read ran past the cancel grace and kept the
        // connection.
        if !kept {
            self.lose(&mut held);
        }
        Ok(RunSummary {
            elapsed: started.elapsed(),
            end,
            transaction_state,
        })
    }

    /// Run the script, stopping it on a cancel or at the deadline. A
    /// stopped statement gets the cancel grace to give way; past that
    /// the connection is given up.
    async fn supervise(
        &self,
        call: &mut DuckCall,
        sql: &UserSql,
        options: &RunOptions,
        sink: &mut dyn ResultSink,
    ) -> Result<RunEnd, DriverError> {
        let deadline = options
            .deadline
            .or(self.statement_timeout)
            .map(|limit| Instant::now() + limit);
        if options.cancel.is_cancelled() {
            return Ok(RunEnd::Cancelled);
        }
        // The run reads the cancel and the deadline itself before each
        // statement, so one that comes as the run starts sends nothing,
        // whichever future the select below polls first.
        let halt = self.halt.clone();
        let cancel = options.cancel.clone();
        let due = deadline.map(Instant::into_std);
        let halted = move || {
            halt.load(Ordering::SeqCst)
                || cancel.is_cancelled()
                || due.is_some_and(|at| std::time::Instant::now() >= at)
        };
        let text = sql.as_str().to_owned();
        let limit = options.row_limit;
        let running = stream_into(call, None, sink, move |link, events| {
            run_script(link, &text, Some(limit), events, &halted)
        });
        tokio::pin!(running);
        let stop = tokio::select! {
            biased;
            () = options.cancel.cancelled() => Stop::Cancelled,
            () = elapsed(deadline) => Stop::DeadlineElapsed,
            outcome = &mut running => {
                return match outcome {
                    Ok(outcome) if outcome.halted => Ok(halted_end(self.stop_due(options, deadline))),
                    outcome => finished(outcome),
                };
            }
        };
        let stopping = async {
            let stopped = self.stop();
            tokio::pin!(stopped);
            let mut sent = false;
            loop {
                tokio::select! {
                    outcome = &mut running => return outcome,
                    () = &mut stopped, if !sent => sent = true,
                }
            }
        };
        let settled = tokio::time::timeout(self.cancel_grace, stopping).await;
        Ok(match (stop, settled) {
            (_, Ok(Ok(outcome))) if outcome.halted => halted_end(stop),
            (_, Ok(Ok(outcome))) => completed(outcome),
            (Stop::Cancelled, Ok(Err(error))) if is_interrupt(&error) => RunEnd::Cancelled,
            (Stop::DeadlineElapsed, Ok(Err(error))) if is_interrupt(&error) => {
                RunEnd::TimedOut { server_cancelled: true }
            }
            (_, Ok(Err(error))) => return session_failure(error),
            // The statement did not give way in time, and the connection
            // goes with it.
            (_, Err(_)) => {
                return Err(DriverError::ConnectionLost {
                    during: LossPhase::Statement,
                });
            }
        })
    }

    /// Give the connection up: nothing runs on the session again.
    fn lose(&self, held: &mut Option<DuckCall>) {
        self.lost.store(true, Ordering::SeqCst);
        *held = None;
    }

    fn stop_due(&self, options: &RunOptions, deadline: Option<Instant>) -> Stop {
        match deadline.is_some_and(|at| Instant::now() >= at) && !options.cancel.is_cancelled() {
            true => Stop::DeadlineElapsed,
            false => Stop::Cancelled,
        }
    }

    /// Where the transaction stands after a run. The answer may not come
    /// in time, and then it is unknown rather than guessed.
    async fn state_after_run(&self, call: &mut DuckCall) -> TransactionState {
        let asking = call.run(None, |link| Ok(transaction_state(link)));
        match tokio::time::timeout(self.cancel_grace, asking).await {
            Ok(Ok(state)) => state,
            Ok(Err(_)) | Err(_) => TransactionState::Unknown,
        }
    }
}

/// Marks the session lost unless disarmed: a caller that gives up a
/// call while its work runs leaves the connection with that work.
struct LoseOnDrop<'a>(Option<&'a AtomicBool>);

impl LoseOnDrop<'_> {
    fn disarm(mut self) {
        self.0 = None;
    }
}

impl Drop for LoseOnDrop<'_> {
    fn drop(&mut self) {
        if let Some(lost) = self.0 {
            lost.store(true, Ordering::SeqCst);
        }
    }
}

async fn elapsed(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

fn finished(outcome: Result<StreamOutcome, DriverError>) -> Result<RunEnd, DriverError> {
    match outcome {
        Ok(outcome) => Ok(completed(outcome)),
        Err(error) => session_failure(error),
    }
}

/// The statement before the stop ended on its own, so DuckDB stopped
/// nothing.
fn halted_end(stop: Stop) -> RunEnd {
    match stop {
        Stop::Cancelled => RunEnd::Cancelled,
        Stop::DeadlineElapsed => RunEnd::TimedOut {
            server_cancelled: false,
        },
    }
}

fn completed(outcome: StreamOutcome) -> RunEnd {
    match outcome.consumer_gone {
        true => RunEnd::Cancelled,
        false => RunEnd::Completed,
    }
}

/// A statement DuckDB refused ends the run. A database that is gone
/// ends the session.
fn session_failure(error: DriverError) -> Result<RunEnd, DriverError> {
    match error {
        DriverError::ConnectionLost { .. } => Err(error),
        other => Ok(RunEnd::Failed(other)),
    }
}

#[async_trait]
impl EditorSession for DuckDbEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        self.shared.state()
    }

    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let Ok(held) = self.shared.call.clone().try_lock_owned() else {
            return Err(DriverError::EditorSessionBusy);
        };
        // Dropping the caller is itself a cancel: the statement keeps
        // running until it is interrupted.
        let cancel_on_drop = options.cancel.clone().drop_guard();
        let shared = self.shared.clone();
        let running = tokio::spawn(async move { shared.run_held(held, sql, options, sink).await });
        let outcome = running.await.unwrap_or_else(|_| {
            self.shared.running.store(false, Ordering::SeqCst);
            self.shared.lost.store(true, Ordering::SeqCst);
            Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            })
        });
        drop(cancel_on_drop.disarm());
        outcome
    }

    async fn transaction_state(&self, options: CallOptions) -> Result<TransactionState, DriverError> {
        let shared = &self.shared;
        let mut held = tokio::select! {
            biased;
            () = options.cancel().cancelled() => return Err(DriverError::Cancelled),
            () = elapsed(options.deadline()) => {
                return Err(DriverError::Timeout { phase: TimeoutPhase::Statement, server_cancelled: false });
            }
            held = shared.call.lock() => held,
        };
        let Some(call) = held.as_mut().filter(|call| call.holds_connection()) else {
            shared.lose(&mut held);
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let given_up = LoseOnDrop(Some(&shared.lost));
        let state = call.run(None, |link| Ok(transaction_state(link))).await;
        given_up.disarm();
        state
    }

    async fn close(&self) {
        let shared = &self.shared;
        shared.lost.store(true, Ordering::SeqCst);
        // The run holds the connection until its statement ends and the
        // transaction state is read. When that outlasts this wait, the
        // connection closes once the session and its run are both gone.
        let locking = async {
            let stopped = shared.stop();
            tokio::pin!(stopped);
            let locked = shared.call.lock();
            tokio::pin!(locked);
            let mut sent = false;
            loop {
                tokio::select! {
                    held = &mut locked => return held,
                    () = &mut stopped, if !sent => sent = true,
                }
            }
        };
        let Ok(mut held) = tokio::time::timeout(shared.cancel_grace, locking).await else {
            return;
        };
        if let Some(call) = held.take() {
            let closing = blocking(move || {
                drop(call);
                Ok(())
            });
            let _ = tokio::time::timeout(shared.close_timeout, closing).await;
        }
    }
}
