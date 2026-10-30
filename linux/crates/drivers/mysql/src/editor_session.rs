use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Connection as _, Executor as _};
use tablepro_core::sql_syntax::{SqlGrammar, may_change_database};
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LivenessPolicy,
    LossPhase, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, TimeoutPhase, TransactionState, UserSql, Value,
};
use tokio::sync::OwnedMutexGuard;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::cancel::ControlLink;
use crate::decode::decode_row;
use crate::editor_run::{RunOutcome, run_script};
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;
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
    shared: Arc<Shared>,
}

/// What a run needs once its caller is gone. A run goes on a task of
/// its own, so a dropped caller is a cancel that still sends the KILL
/// and settles the session, rather than a statement left running for
/// nobody.
struct Shared {
    held: Arc<tokio::sync::Mutex<Option<Held>>>,
    connection_id: u64,
    flavour: MySqlFlavour,
    control: ControlLink,
    probe: TransactionProbe,
    /// Where a `USE` left the session, once one ran.
    database: Mutex<Option<String>>,
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
            shared: Arc::new(Shared {
                held: Arc::new(tokio::sync::Mutex::new(Some(Held {
                    connection: physical.connection,
                    select_limit: None,
                }))),
                connection_id: physical.connection_id,
                flavour: physical.flavour,
                control: ControlLink::new(endpoint),
                probe: TransactionProbe::new(physical.flavour),
                database: Mutex::new(None),
                running: AtomicBool::new(false),
                lost: AtomicBool::new(false),
                closing: CancellationToken::new(),
                liveness,
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

    /// One run on the connection `guard` holds, which it gives up when
    /// the connection cannot take another.
    async fn run_held(
        &self,
        mut guard: OwnedMutexGuard<Option<Held>>,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        // A run whose task died leaves its connection behind, in a state
        // nothing knows.
        let Some(held) = guard.as_mut().filter(|_| !self.lost.load(Ordering::SeqCst)) else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let started = Instant::now();
        self.running.store(true, Ordering::SeqCst);
        let supervised = self.supervise(held, &sql, &options, sink.as_mut()).await;
        let transaction_state = match &supervised {
            Ok((_, true)) => {
                if may_change_database(sql.as_str(), SqlGrammar::MySql) {
                    self.follow_database(&mut held.connection).await;
                }
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

    async fn follow_database(&self, connection: &mut MySqlConnection) {
        let asking = connection.fetch_one(sqlx::raw_sql("SELECT DATABASE()"));
        let Ok(Ok(row)) = tokio::time::timeout(self.liveness.cancel_grace, asking).await else {
            return;
        };
        let current = match decode_row(&row, MySqlWireFormat::Text, MySqlTimestampMode::SessionLocal).first() {
            Some(Value::Text(name)) => Some(name.clone()),
            _ => None,
        };
        *self.database.lock().unwrap_or_else(PoisonError::into_inner) = current;
    }

    /// Run the script, stopping it on a cancel, at the deadline, when
    /// the session closes or when the sink stops reading. A stop is KILL
    /// QUERY on a connection of the session's own; the statement then
    /// has the cancel grace to end, and nothing after it is sent.
    async fn supervise(
        &self,
        held: &mut Held,
        sql: &UserSql,
        options: &RunOptions,
        sink: &mut dyn ResultSink,
    ) -> Result<(RunEnd, bool), DriverError> {
        let limit = options.row_limit;
        let deadline = options.deadline.map(|limit| Instant::now() + limit);
        let stopped = CancellationToken::new();
        // Read synchronously before each statement goes out, since the
        // select below sees a stop only once the run waits.
        let halt = || self.stop_due(options, deadline).is_some();
        let flavour = self.flavour;
        let running = async {
            set_select_limit(held, flavour, limit).await?;
            run_script(&mut held.connection, flavour, sql.as_str(), limit, sink, &stopped, halt).await
        };
        let mut running = std::pin::pin!(running);
        let stop = tokio::select! {
            outcome = &mut running => {
                return match outcome {
                    // Stopped between statements: nothing runs to KILL.
                    Ok(RunOutcome { halted: true, .. }) => {
                        let stop = self.stop_due(options, deadline).unwrap_or(Stop::Cancelled);
                        Ok((stopped_end(stop, false), true))
                    }
                    outcome => finished(outcome).map(|end| (end, true)),
                };
            }
            () = options.cancel.cancelled() => Stop::Cancelled,
            () = self.closing.cancelled() => Stop::Cancelled,
            () = stopped.cancelled() => Stop::Cancelled,
            () = elapsed(deadline) => Stop::DeadlineElapsed,
        };
        stopped.cancel();
        let until = Instant::now() + self.liveness.cancel_grace;
        // Nothing more is read until the KILL has its answer, so it lands
        // while the statement it names is still the connection's last.
        let answered = tokio::time::timeout_at(until, self.control.kill_query(self.connection_id))
            .await
            .is_ok();
        let settled = tokio::time::timeout_at(until, &mut running).await.ok();
        let confirmed = matches!(&settled, Some(Err(error)) if confirms_stop(error));
        let end = stopped_end(stop, confirmed);
        match settled {
            Some(Err(DriverError::ConnectionLost { during })) => Err(DriverError::ConnectionLost { during }),
            // An unanswered KILL may still land, on whatever runs next here.
            _ if !answered => Ok((end, false)),
            Some(_) => Ok((end, true)),
            // The statement would not stop, so the connection still has
            // its answer coming and cannot take another run.
            None => Ok((end, false)),
        }
    }

    fn stop_due(&self, options: &RunOptions, deadline: Option<Instant>) -> Option<Stop> {
        if options.cancel.is_cancelled() || self.closing.is_cancelled() {
            Some(Stop::Cancelled)
        } else if deadline.is_some_and(|at| Instant::now() >= at) {
            Some(Stop::DeadlineElapsed)
        } else {
            None
        }
    }
}

/// A stopped run reads as stopped whatever its statement did after the
/// stop, since nothing after it ran.
fn stopped_end(stop: Stop, confirmed: bool) -> RunEnd {
    match stop {
        Stop::Cancelled => RunEnd::Cancelled,
        Stop::DeadlineElapsed => RunEnd::TimedOut {
            server_cancelled: confirmed,
        },
    }
}

/// The statement ended with the server's word that it was stopped: 1317
/// from the KILL, or the server's own statement timeout. An OK, or a
/// KILL that only returned OK, says nothing about it.
fn confirms_stop(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::Cancelled
            | DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true,
            }
    )
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
        Ok(RunOutcome {
            consumer_gone: true, ..
        }) => Ok(RunEnd::Cancelled),
        Ok(RunOutcome { .. }) => Ok(RunEnd::Completed),
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
        self.shared.state()
    }

    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let Ok(guard) = self.shared.held.clone().try_lock_owned() else {
            return Err(DriverError::EditorSessionBusy);
        };
        // Dropping the caller is itself a cancel: the statement is
        // already running on the server and has to be stopped.
        let cancel_on_drop = options.cancel.clone().drop_guard();
        let shared = self.shared.clone();
        let running = tokio::spawn(async move { shared.run_held(guard, sql, options, sink).await });
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

    fn database(&self) -> Option<String> {
        self.shared
            .database
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    async fn transaction_state(&self, options: CallOptions) -> Result<TransactionState, DriverError> {
        let shared = &self.shared;
        let asking = async {
            let mut guard = shared.held.lock().await;
            match guard.as_mut() {
                Some(held) => Ok(shared.probe.state(&mut held.connection).await),
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
        let shared = &self.shared;
        shared.lost.store(true, Ordering::SeqCst);
        shared.closing.cancel();
        // A statement that will not stop keeps the connection until its
        // run gives it up at the end of the cancel grace.
        let grace = shared.liveness.cancel_grace + Duration::from_millis(100);
        if let Ok(mut guard) = tokio::time::timeout(grace, shared.held.lock()).await
            && let Some(held) = guard.take()
        {
            let _ = tokio::time::timeout(shared.liveness.close_timeout, held.connection.close()).await;
        }
        shared.control.close().await;
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::BusyReason;

    use super::*;

    #[test]
    fn a_timeout_reads_as_stopped_by_the_server_only_when_the_statement_said_so() {
        let server_timeout = DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        };

        assert!(confirms_stop(&DriverError::Cancelled));
        assert!(confirms_stop(&server_timeout));
        assert!(!confirms_stop(&DriverError::Busy(BusyReason::NoFreeConnection)));
        assert_eq!(
            stopped_end(Stop::DeadlineElapsed, false),
            RunEnd::TimedOut {
                server_cancelled: false
            }
        );
        assert_eq!(
            stopped_end(Stop::DeadlineElapsed, true),
            RunEnd::TimedOut { server_cancelled: true }
        );
        assert_eq!(stopped_end(Stop::Cancelled, false), RunEnd::Cancelled);
    }
}
