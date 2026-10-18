use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LossPhase,
    ResultSink, RunEnd, RunOptions, RunSummary, StopReason, StopRequest, TimeoutPhase, TransactionState, UserSql,
};
use tokio::sync::OwnedMutexGuard;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::editor_run::{EditorRun, ScriptOutcome, transaction_state};
use crate::endpoint::MssqlEndpoint;
use crate::errors::ends_connection;
use crate::in_band_request::StopPolicy;
use crate::physical::MssqlLink;

/// One editor tab's own connection to the server.
///
/// Its transaction, temporary tables and session settings live on this
/// connection and nowhere else, so it is never pooled and never reopened
/// behind the user's back. A stop that cannot leave the connection in
/// step with the server ends the session instead.
pub(crate) struct MssqlEditorSession {
    id: EditorSessionId,
    shared: Arc<Shared>,
}

/// What a run needs once its caller is gone. A run goes on a task of
/// its own, so a dropped caller is a cancel that still sends the
/// attention and settles the session, rather than a statement left
/// running for nobody.
struct Shared {
    link: Arc<tokio::sync::Mutex<Option<MssqlLink>>>,
    running: AtomicBool,
    lost: AtomicBool,
    /// The running statement's stop, so closing the tab stops it.
    current: Mutex<Option<StopRequest>>,
    statement_timeout: Option<Duration>,
    policy: StopPolicy,
    cancel_grace: Duration,
    close_timeout: Duration,
}

impl MssqlEditorSession {
    pub(crate) async fn open(
        endpoint: &MssqlEndpoint,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let link = endpoint.open_editor(&cancel).await?;
        let liveness = endpoint.liveness();
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            shared: Arc::new(Shared {
                link: Arc::new(tokio::sync::Mutex::new(Some(link))),
                running: AtomicBool::new(false),
                lost: AtomicBool::new(false),
                current: Mutex::new(None),
                statement_timeout: options.statement_timeout,
                policy: StopPolicy::within(liveness.cancel_grace),
                cancel_grace: liveness.cancel_grace,
                close_timeout: liveness.close_timeout,
            }),
        }))
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

    /// One run on the connection `held` holds, which it gives up when
    /// the connection cannot take another.
    async fn run_held(
        &self,
        mut held: OwnedMutexGuard<Option<MssqlLink>>,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        // A run whose task died leaves its connection behind, in a state
        // nothing knows.
        let Some(link) = held.as_mut().filter(|_| !self.lost.load(Ordering::SeqCst)) else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let started = Instant::now();
        self.running.store(true, Ordering::SeqCst);
        let request = StopRequest::new();
        self.set_current(Some(request.clone()));

        let supervised = self.supervise(link, &request, &sql, &options, sink.as_mut()).await;
        let (end, transaction_state, keep) = match supervised {
            Some(Ok(outcome)) if outcome.reusable => {
                let (state, keep) = self.state_after_run(link).await;
                (Ok(outcome.end), state, keep)
            }
            // The run ended, but somewhere the connection cannot go on
            // from: the session ends with it.
            Some(Ok(outcome)) => (Ok(outcome.end), TransactionState::Unknown, false),
            Some(Err(error)) => (Err(error), TransactionState::Unknown, false),
            None => (
                Ok(match request.reason() {
                    Some(StopReason::DeadlineElapsed) => RunEnd::TimedOut {
                        server_cancelled: false,
                    },
                    _ => RunEnd::Cancelled,
                }),
                TransactionState::Unknown,
                false,
            ),
        };
        self.set_current(None);
        self.running.store(false, Ordering::SeqCst);
        if !keep {
            self.lost.store(true, Ordering::SeqCst);
            *held = None;
        }
        Ok(RunSummary {
            elapsed: started.elapsed(),
            end: end?,
            transaction_state,
        })
    }

    fn set_current(&self, request: Option<StopRequest>) {
        *self.current.lock().unwrap_or_else(PoisonError::into_inner) = request;
    }

    /// Run the script, stopping it on a cancel or at the deadline. A
    /// stopped run sends its own attention and gets the cancel grace to
    /// settle; past that its connection is given up.
    async fn supervise(
        &self,
        link: &mut MssqlLink,
        request: &StopRequest,
        sql: &UserSql,
        options: &RunOptions,
        sink: &mut dyn ResultSink,
    ) -> Option<Result<ScriptOutcome, DriverError>> {
        let deadline = options
            .deadline
            .or(self.statement_timeout)
            .map(|limit| Instant::now() + limit);
        let tally = link.tally();
        let mut run = EditorRun {
            client: &mut link.client,
            tally,
            request: request.clone(),
            policy: self.policy,
            limit: options.row_limit,
            sink,
        };
        let running = run.script(sql.as_str());
        tokio::pin!(running);
        tokio::select! {
            biased;
            outcome = &mut running => return Some(outcome),
            () = options.cancel.cancelled() => request.request(StopReason::Cancelled),
            () = elapsed(deadline) => request.request(StopReason::DeadlineElapsed),
        }
        tokio::time::timeout(self.cancel_grace, running).await.ok()
    }

    /// Where the transaction stands after a run, within the cancel grace,
    /// and unknown rather than guessed when the answer does not come.
    async fn state_after_run(&self, link: &mut MssqlLink) -> (TransactionState, bool) {
        match tokio::time::timeout(self.cancel_grace, transaction_state(&mut link.client)).await {
            Ok(Ok(state)) => (state, true),
            Ok(Err(error)) => (TransactionState::Unknown, !ends_connection(&error)),
            // The question is still on the wire, unanswered.
            Err(_) => (TransactionState::Unknown, false),
        }
    }
}

async fn elapsed(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[async_trait]
impl EditorSession for MssqlEditorSession {
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
        let Ok(held) = self.shared.link.clone().try_lock_owned() else {
            return Err(DriverError::EditorSessionBusy);
        };
        // Dropping the caller is itself a cancel: the statement is
        // already running on the server and has to be stopped.
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
            held = shared.link.lock() => held,
        };
        let Some(link) = held.as_mut() else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let asking = transaction_state(&mut link.client);
        let answer = tokio::select! {
            biased;
            () = options.cancel().cancelled() => None,
            () = elapsed(options.deadline()) => None,
            answer = asking => Some(answer),
        };
        match answer {
            Some(Ok(state)) => Ok(state),
            Some(Err(error)) => {
                if ends_connection(&error) {
                    shared.lost.store(true, Ordering::SeqCst);
                    *held = None;
                }
                Err(error)
            }
            // The question was cut off mid-request, so the connection is
            // out of step and the session cannot go on.
            None => {
                shared.lost.store(true, Ordering::SeqCst);
                *held = None;
                Err(match options.cancel().is_cancelled() {
                    true => DriverError::Cancelled,
                    false => DriverError::Timeout {
                        phase: TimeoutPhase::Statement,
                        server_cancelled: false,
                    },
                })
            }
        }
    }

    async fn close(&self) {
        let shared = &self.shared;
        shared.lost.store(true, Ordering::SeqCst);
        if let Some(request) = shared.current.lock().unwrap_or_else(PoisonError::into_inner).take() {
            request.request(StopReason::Shutdown);
        }
        // A run still stopping holds the connection until it settles or
        // gives the connection up at the end of the cancel grace.
        let Ok(mut held) = tokio::time::timeout(shared.cancel_grace, shared.link.lock()).await else {
            return;
        };
        if let Some(link) = held.take() {
            let _ = tokio::time::timeout(shared.close_timeout, link.client.close()).await;
        }
    }
}
