use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use sqlx::Connection as _;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection as SqlxConnection};
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LivenessPolicy,
    LossPhase, ResultSink, RunEnd, RunOptions, RunSummary, TimeoutPhase, TransactionState, UserSql,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::autocommit::is_autocommit;
use crate::deadline;
use crate::errors::{is_interrupt, map_error, map_open_error};
use crate::interrupt::InterruptFlag;
use crate::result_stream::{StreamOutcome, run_script};

/// One editor tab's own connection to the file.
///
/// The tab's transaction and temporary tables live on this connection
/// and nowhere else, so it is never pooled and never reopened behind
/// the user's back.
#[derive(Debug)]
pub(crate) struct SqliteEditorSession {
    id: EditorSessionId,
    connection: tokio::sync::Mutex<Option<SqlxConnection>>,
    running: AtomicBool,
    lost: AtomicBool,
    /// The running statement's stop, so closing the tab stops it.
    current: Mutex<Option<InterruptFlag>>,
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

impl SqliteEditorSession {
    pub(crate) async fn open(
        options: &SqliteConnectOptions,
        path: &Path,
        session: EditorSessionOptions,
        liveness: &LivenessPolicy,
        cancel: CancellationToken,
    ) -> Result<Self, DriverError> {
        let connecting = SqlxConnection::connect_with(options);
        let connection = tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            opened = tokio::time::timeout(liveness.connect_timeout, connecting) => match opened {
                Ok(opened) => opened.map_err(|error| map_open_error(error, path))?,
                Err(_) => {
                    return Err(DriverError::Timeout {
                        phase: TimeoutPhase::Connect,
                        server_cancelled: false,
                    });
                }
            },
        };
        Ok(Self {
            id: EditorSessionId::new(),
            connection: tokio::sync::Mutex::new(Some(connection)),
            running: AtomicBool::new(false),
            lost: AtomicBool::new(false),
            current: Mutex::new(None),
            statement_timeout: session.statement_timeout,
            cancel_grace: liveness.cancel_grace,
            close_timeout: liveness.close_timeout,
        })
    }

    fn set_current(&self, flag: Option<InterruptFlag>) {
        *self.current.lock().unwrap_or_else(PoisonError::into_inner) = flag;
    }

    /// Run the script, stopping it on a cancel or at the deadline. A
    /// stopped statement gets the cancel grace to notice its flag; past
    /// that its read is dropped, which SQLite also takes as the end.
    async fn supervise(
        &self,
        connection: &mut SqlxConnection,
        flag: &InterruptFlag,
        sql: &UserSql,
        options: &RunOptions,
        sink: &mut dyn ResultSink,
    ) -> Result<RunEnd, DriverError> {
        let deadline = options
            .deadline
            .or(self.statement_timeout)
            .map(|limit| Instant::now() + limit);
        let running = run_script(connection, sql.as_str(), Some(options.row_limit), sink);
        tokio::pin!(running);
        let stop = tokio::select! {
            outcome = &mut running => return finished(outcome),
            () = options.cancel.cancelled() => Stop::Cancelled,
            () = deadline::elapsed(deadline) => Stop::DeadlineElapsed,
        };
        flag.raise();
        let settled = tokio::time::timeout(self.cancel_grace, &mut running).await;
        Ok(match (stop, settled) {
            (_, Ok(Ok(outcome))) => completed(outcome),
            (Stop::Cancelled, Ok(Err(error))) if is_interrupt(&error) => RunEnd::Cancelled,
            (Stop::DeadlineElapsed, Ok(Err(error))) if is_interrupt(&error) => {
                RunEnd::TimedOut { server_cancelled: true }
            }
            (_, Ok(Err(error))) => return session_failure(error),
            (Stop::Cancelled, Err(_)) => RunEnd::Cancelled,
            (Stop::DeadlineElapsed, Err(_)) => RunEnd::TimedOut {
                server_cancelled: false,
            },
        })
    }

    /// Where the transaction stands after a run. A statement still
    /// winding down holds the connection, so the answer may not come in
    /// time, and then it is unknown rather than guessed.
    async fn state_after_run(&self, connection: &mut SqlxConnection) -> TransactionState {
        let asking = async {
            let mut handle = connection.lock_handle().await.map_err(map_error)?;
            Ok::<_, DriverError>(is_autocommit(&mut handle))
        };
        match tokio::time::timeout(self.cancel_grace, asking).await {
            Ok(Ok(true)) => TransactionState::Idle,
            Ok(Ok(false)) => TransactionState::InTransaction,
            Ok(Err(_)) | Err(_) => TransactionState::Unknown,
        }
    }
}

fn finished(outcome: Result<StreamOutcome, DriverError>) -> Result<RunEnd, DriverError> {
    match outcome {
        Ok(outcome) => Ok(completed(outcome)),
        Err(error) => session_failure(error),
    }
}

fn completed(outcome: StreamOutcome) -> RunEnd {
    match outcome.consumer_gone {
        true => RunEnd::Cancelled,
        false => RunEnd::Completed,
    }
}

/// A statement SQLite refused ends the run. A connection that is gone
/// ends the session.
fn session_failure(error: DriverError) -> Result<RunEnd, DriverError> {
    match error {
        DriverError::ConnectionLost { .. } => Err(error),
        other => Ok(RunEnd::Failed(other)),
    }
}

#[async_trait]
impl EditorSession for SqliteEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        if self.lost.load(Ordering::SeqCst) {
            EditorSessionState::Lost
        } else if self.running.load(Ordering::SeqCst) {
            EditorSessionState::Running
        } else {
            EditorSessionState::Ready
        }
    }

    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let Ok(mut held) = self.connection.try_lock() else {
            return Err(DriverError::EditorSessionBusy);
        };
        let Some(connection) = held.as_mut() else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let started = Instant::now();
        self.running.store(true, Ordering::SeqCst);
        let flag = InterruptFlag::new();
        self.set_current(Some(flag.clone()));

        let ended = match flag.install(connection).await {
            Ok(()) => self.supervise(connection, &flag, &sql, &options, sink.as_mut()).await,
            Err(error) => session_failure(error),
        };
        let transaction_state = match &ended {
            Ok(_) => self.state_after_run(connection).await,
            Err(_) => TransactionState::Unknown,
        };
        self.set_current(None);
        self.running.store(false, Ordering::SeqCst);
        let end = match ended {
            Ok(end) => end,
            Err(error) => {
                self.lost.store(true, Ordering::SeqCst);
                *held = None;
                return Err(error);
            }
        };
        Ok(RunSummary {
            elapsed: started.elapsed(),
            end,
            transaction_state,
        })
    }

    async fn transaction_state(&self, options: CallOptions) -> Result<TransactionState, DriverError> {
        let mut held = tokio::select! {
            biased;
            () = options.cancel().cancelled() => return Err(DriverError::Cancelled),
            () = deadline::elapsed(options.deadline()) => {
                return Err(DriverError::Timeout { phase: TimeoutPhase::Statement, server_cancelled: false });
            }
            held = self.connection.lock() => held,
        };
        let Some(connection) = held.as_mut() else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let mut handle = connection.lock_handle().await.map_err(map_error)?;
        Ok(match is_autocommit(&mut handle) {
            true => TransactionState::Idle,
            false => TransactionState::InTransaction,
        })
    }

    async fn close(&self) {
        self.lost.store(true, Ordering::SeqCst);
        if let Some(flag) = self.current.lock().unwrap_or_else(PoisonError::into_inner).take() {
            flag.raise();
        }
        // A statement that will not stop keeps the connection, which
        // closes when the session itself is dropped.
        let Ok(mut held) = tokio::time::timeout(self.cancel_grace, self.connection.lock()).await else {
            return;
        };
        if let Some(connection) = held.take() {
            let _ = tokio::time::timeout(self.close_timeout, connection.close()).await;
        }
    }
}
