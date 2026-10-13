use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Connection as _, Executor as _};
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LivenessPolicy,
    LossPhase, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, TimeoutPhase, TransactionState, UserSql,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::cancel::ControlLink;
use crate::editor_run::{RunOutcome, run_script};
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::physical::{MysqlEndpoint, SessionKind};
use crate::session_statements::{SessionLimits, select_limit};
use crate::transaction_probe::TransactionProbe;

/// The tab's own connection and the row limit last set on it.
struct Held {
    connection: MySqlConnection,
    select_limit: Option<u64>,
}

/// One editor tab's own connection to the server.
///
/// The session runs on the server's default settings, as the mysql
/// client's would: its zone, its sql_mode and its collation. Only the
/// read-only default, the lock bounds and the row limit are its own.
pub(crate) struct MysqlEditorSession {
    id: EditorSessionId,
    held: tokio::sync::Mutex<Option<Held>>,
    connection_id: u64,
    flavour: MySqlFlavour,
    control: ControlLink,
    probe: TransactionProbe,
    running: AtomicBool,
    lost: AtomicBool,
    /// Cancelled when the session closes, so a running statement stops.
    closing: CancellationToken,
    liveness: LivenessPolicy,
}

/// Why a run stopped before it finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stop {
    Cancelled,
    DeadlineElapsed,
}

impl MysqlEditorSession {
    pub(crate) async fn open(
        endpoint: Arc<MysqlEndpoint>,
        limits: SessionLimits,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let limits = SessionLimits {
            statement_timeout: options.statement_timeout,
            ..limits
        };
        let physical = endpoint.connect_physical(SessionKind::Editor, &limits, &cancel).await?;
        let liveness = *endpoint.liveness();
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            held: tokio::sync::Mutex::new(Some(Held {
                connection: physical.connection,
                select_limit: None,
            })),
            connection_id: physical.connection_id,
            flavour: physical.flavour,
            control: ControlLink::new(endpoint),
            probe: TransactionProbe::new(physical.flavour),
            running: AtomicBool::new(false),
            lost: AtomicBool::new(false),
            closing: CancellationToken::new(),
            liveness,
        }))
    }

    /// Run the script, stopping it on a cancel, at the deadline, when
    /// the session closes or when the sink stops reading. A stop is KILL
    /// QUERY on a connection of the session's own; the statement then
    /// has the cancel grace to end.
    async fn supervise(
        &self,
        held: &mut Held,
        sql: &UserSql,
        options: &RunOptions,
        sink: &mut dyn ResultSink,
    ) -> Result<(RunEnd, bool), DriverError> {
        let limit = options.row_limit;
        if let Err(error) = set_select_limit(held, self.flavour, limit).await {
            return finished(Err(error)).map(|end| (end, true));
        }
        let deadline = options.deadline.map(|limit| Instant::now() + limit);
        let consumer_gone = CancellationToken::new();
        let running = run_script(
            &mut held.connection,
            self.flavour,
            sql.as_str(),
            limit,
            sink,
            &consumer_gone,
        );
        let mut running = std::pin::pin!(running);
        let stop = tokio::select! {
            outcome = &mut running => return finished(outcome).map(|end| (end, true)),
            () = options.cancel.cancelled() => Stop::Cancelled,
            () = self.closing.cancelled() => Stop::Cancelled,
            () = consumer_gone.cancelled() => Stop::Cancelled,
            () = elapsed(deadline) => Stop::DeadlineElapsed,
        };
        let until = Instant::now() + self.liveness.cancel_grace;
        // Nothing more is read until the KILL has landed. A batch the
        // server is still sending then waits on the socket, so it cannot
        // move on to its next statement before the KILL stops it.
        let delivered = tokio::time::timeout_at(until, self.control.kill_query(self.connection_id))
            .await
            .ok()
            .map(|sent| sent.is_ok());
        let settled = tokio::time::timeout_at(until, &mut running).await.ok();
        let server_cancelled = delivered == Some(true);
        let end = match stop {
            Stop::Cancelled => RunEnd::Cancelled,
            Stop::DeadlineElapsed => RunEnd::TimedOut { server_cancelled },
        };
        match settled {
            // Whatever the statement did once it was stopped, the run
            // ends as stopped: its result may be cut short by the KILL.
            Some(Ok(_)) => Ok((end, true)),
            Some(Err(DriverError::ConnectionLost { during })) => Err(DriverError::ConnectionLost { during }),
            Some(Err(_)) => Ok((end, true)),
            // The statement would not stop, so the connection still has
            // its answer coming and cannot take another run.
            None => Ok((end, false)),
        }
    }
}

async fn set_select_limit(held: &mut Held, flavour: MySqlFlavour, limit: RowLimit) -> Result<(), DriverError> {
    if held.select_limit == Some(limit.get()) {
        return Ok(());
    }
    held.connection
        .execute(AssertSqlSafe(select_limit(limit.get())))
        .await
        .map_err(|error| map_error(&error, flavour))?;
    held.select_limit = Some(limit.get());
    Ok(())
}

fn finished(outcome: Result<RunOutcome, DriverError>) -> Result<RunEnd, DriverError> {
    match outcome {
        Ok(RunOutcome { consumer_gone: true }) => Ok(RunEnd::Cancelled),
        Ok(RunOutcome { consumer_gone: false }) => Ok(RunEnd::Completed),
        // A connection that is gone ends the session; a statement the
        // server refused ends the run.
        Err(error @ DriverError::ConnectionLost { .. }) => Err(error),
        Err(error) => Ok(RunEnd::Failed(error)),
    }
}

async fn elapsed(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[async_trait]
impl EditorSession for MysqlEditorSession {
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
        let Ok(mut guard) = self.held.try_lock() else {
            return Err(DriverError::EditorSessionBusy);
        };
        let Some(held) = guard.as_mut() else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let started = Instant::now();
        self.running.store(true, Ordering::SeqCst);
        let supervised = self.supervise(held, &sql, &options, sink.as_mut()).await;
        let transaction_state = match &supervised {
            Ok((_, true)) => {
                let asking = self.probe.state(&mut held.connection);
                tokio::time::timeout(self.liveness.cancel_grace, asking)
                    .await
                    .unwrap_or(TransactionState::Unknown)
            }
            _ => TransactionState::Unknown,
        };
        self.running.store(false, Ordering::SeqCst);
        let end = match supervised {
            Ok((end, true)) => end,
            Ok((end, false)) => {
                self.lost.store(true, Ordering::SeqCst);
                *guard = None;
                end
            }
            Err(error) => {
                self.lost.store(true, Ordering::SeqCst);
                *guard = None;
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
        let asking = async {
            let mut guard = self.held.lock().await;
            match guard.as_mut() {
                Some(held) => Ok(self.probe.state(&mut held.connection).await),
                None => Err(DriverError::ConnectionLost {
                    during: LossPhase::Idle,
                }),
            }
        };
        tokio::select! {
            biased;
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            () = elapsed(options.deadline()) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false,
            }),
            state = asking => state,
        }
    }

    async fn close(&self) {
        self.lost.store(true, Ordering::SeqCst);
        self.closing.cancel();
        // A statement that will not stop keeps the connection, which
        // closes when the session itself is dropped.
        let grace = self.liveness.cancel_grace + Duration::from_millis(100);
        if let Ok(mut guard) = tokio::time::timeout(grace, self.held.lock()).await
            && let Some(held) = guard.take()
        {
            let _ = tokio::time::timeout(self.liveness.close_timeout, held.connection.close()).await;
        }
        self.control.close().await;
    }
}
