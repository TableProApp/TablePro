use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::call_options::CallOptions;
use crate::engine_stop::{CallResource, EngineStop, StopDelivery, StopScope};
use crate::error::DriverError;
use crate::loss_phase::LossPhase;
use crate::session_fate::SessionFate;
use crate::stop_request::{StopReason, StopRequest};
use crate::timeout_phase::TimeoutPhase;
use crate::write_ledger::WriteLedger;
use crate::write_report::WriteReport;

/// Runs calls that own their connection until they finish.
///
/// Stopping a request is not the same as dropping the future that
/// awaits it. The server keeps working, and some clients borrow the
/// connection for the whole request, so nothing outside can interrupt
/// them. Each call therefore runs in a task that outlives its caller:
/// it carries the stop into the work, sends the engine's own stop where
/// there is one, and decides afterwards whether the connection is clean
/// enough to go back to the pool.
#[derive(Debug)]
pub struct OwnedCalls {
    tracker: TaskTracker,
    shutdown: CancellationToken,
    cancel_grace: Duration,
}

impl OwnedCalls {
    pub fn new(cancel_grace: Duration) -> Self {
        Self {
            tracker: TaskTracker::new(),
            shutdown: CancellationToken::new(),
            cancel_grace,
        }
    }

    /// Run a read. A stop that the engine acknowledges reads as what
    /// asked for it, not as the error the engine raised to report it.
    pub async fn run_read<R, S, T, W, Fut>(
        &self,
        options: CallOptions,
        resource: R,
        stop: Arc<S>,
        work: W,
    ) -> Result<T, DriverError>
    where
        R: CallResource,
        S: EngineStop,
        T: Send + 'static,
        W: FnOnce(R, StopRequest) -> Fut + Send + 'static,
        Fut: Future<Output = (R, Result<T, DriverError>)> + Send + 'static,
    {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let abandon = resource.abandon_flag();
        let request = StopRequest::new();
        let running = work(resource, request.clone());
        let shutdown = self.shutdown.clone();
        let grace = self.cancel_grace;
        let cancel = options.cancel().clone();

        let spawned = self.tracker.spawn(async move {
            let settled = Supervisor {
                request,
                stop: stop.clone(),
                options,
                shutdown,
                grace,
                abandon,
                ledger: None,
            }
            .run(running)
            .await;
            let outcome = match settled {
                Settled::Finished {
                    resource,
                    result,
                    stopped,
                    stop_settled,
                } => {
                    let acknowledged = matches!(&result, Err(error) if stop.acknowledged(error));
                    let lost = matches!(&result, Err(DriverError::ConnectionLost { .. }));
                    release(
                        resource,
                        stop.delivery(),
                        stopped.is_some(),
                        acknowledged,
                        stop_settled,
                        lost,
                    );
                    match (stopped, acknowledged) {
                        (Some(StopReason::Cancelled | StopReason::Shutdown), true) => Err(DriverError::Cancelled),
                        (Some(StopReason::DeadlineElapsed), true) => Err(DriverError::Timeout {
                            phase: TimeoutPhase::Statement,
                            server_cancelled: true,
                        }),
                        _ => result,
                    }
                }
                Settled::Abandoned(_) => Err(DriverError::ConnectionLost {
                    during: LossPhase::Statement,
                }),
            };
            let _ = sender.send(outcome);
        });

        // Dropping the caller is itself a cancel: the work is already
        // running on the server and has to be stopped, not forgotten.
        let _guard = cancel.drop_guard();
        match receiver.await {
            Ok(outcome) => outcome,
            Err(_) => {
                spawned.abort();
                Err(DriverError::ConnectionLost {
                    during: LossPhase::Statement,
                })
            }
        }
    }

    /// Run a write. The work reports its own outcome through the
    /// ledger, so its result passes through: only a write abandoned
    /// past the grace is classified here, from what the ledger saw.
    pub async fn run_write<R, S, W, Fut>(
        &self,
        options: CallOptions,
        resource: R,
        stop: Arc<S>,
        ledger: Arc<WriteLedger>,
        work: W,
    ) -> Result<WriteReport, DriverError>
    where
        R: CallResource,
        S: EngineStop,
        W: FnOnce(R, StopRequest) -> Fut + Send + 'static,
        Fut: Future<Output = (R, Result<WriteReport, DriverError>)> + Send + 'static,
    {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let abandon = resource.abandon_flag();
        let request = StopRequest::new();
        let running = work(resource, request.clone());
        let shutdown = self.shutdown.clone();
        let grace = self.cancel_grace;
        let cancel = options.cancel().clone();
        let caller_ledger = ledger.clone();

        let spawned = self.tracker.spawn(async move {
            let settled = Supervisor {
                request,
                stop: stop.clone(),
                options,
                shutdown,
                grace,
                abandon,
                ledger: Some(ledger.clone()),
            }
            .run(running)
            .await;
            let outcome = match settled {
                Settled::Finished {
                    resource,
                    result,
                    stopped,
                    stop_settled,
                } => {
                    let acknowledged = matches!(&result, Err(error) if stop.acknowledged(error));
                    let lost = matches!(&result, Err(DriverError::ConnectionLost { .. }));
                    release(
                        resource,
                        stop.delivery(),
                        stopped.is_some(),
                        acknowledged,
                        stop_settled,
                        lost,
                    );
                    result
                }
                // The connection is gone with the write half-sent, so
                // what is in the database comes from what the ledger
                // saw go out.
                Settled::Abandoned(reason) => Err(ledger.interrupted(reason_error(reason), SessionFate::Discarded)),
            };
            let _ = sender.send(outcome);
        });

        let _guard = cancel.drop_guard();
        match receiver.await {
            Ok(outcome) => outcome,
            Err(_) => {
                spawned.abort();
                Err(caller_ledger.interrupted(
                    DriverError::ConnectionLost {
                        during: LossPhase::Statement,
                    },
                    SessionFate::Discarded,
                ))
            }
        }
    }

    /// Stop every call and wait out the grace for them to settle.
    pub async fn shutdown(&self) {
        self.shutdown.cancel();
        self.tracker.close();
        let _ = tokio::time::timeout(self.cancel_grace, self.tracker.wait()).await;
    }
}

enum Settled<R, T> {
    Finished {
        resource: R,
        result: Result<T, DriverError>,
        stopped: Option<StopReason>,
        stop_settled: bool,
    },
    /// The work was still running when the grace ran out, so its
    /// connection went with it.
    Abandoned(StopReason),
}

/// One call's whole context, so the supervisor reads as a sequence of
/// decisions rather than a long argument list.
struct Supervisor<S> {
    request: StopRequest,
    stop: Arc<S>,
    options: CallOptions,
    shutdown: CancellationToken,
    grace: Duration,
    abandon: Arc<AtomicBool>,
    ledger: Option<Arc<WriteLedger>>,
}

impl<S: EngineStop> Supervisor<S> {
    async fn run<R, T, Fut>(self, work: Fut) -> Settled<R, T>
    where
        Fut: Future<Output = (R, Result<T, DriverError>)> + Send,
    {
        let mut work = std::pin::pin!(work);
        let reason = tokio::select! {
            (resource, result) = &mut work => {
                return Settled::Finished { resource, result, stopped: None, stop_settled: false };
            }
            () = self.options.cancel().cancelled() => StopReason::Cancelled,
            () = self.shutdown.cancelled() => StopReason::Shutdown,
            () = deadline_elapsed(self.options.deadline()) => StopReason::DeadlineElapsed,
        };
        self.request.request(reason);

        let until = Instant::now() + self.grace;
        // A write holds its engine stop until the ledger says the write
        // can survive one: a stop that races a commit turns a knowable
        // outcome into an unknown one.
        let send_stop = matches!(self.stop.delivery(), StopDelivery::OutOfBand(_))
            && self.ledger.as_ref().is_none_or(|ledger| ledger.stop_permitted());
        let stop = self.stop.clone();
        let engine = async {
            if send_stop {
                let _ = stop.stop().await;
            }
        };
        let mut engine = std::pin::pin!(engine);
        let mut stop_settled = !send_stop;

        let finished = loop {
            tokio::select! {
                // The stop goes out first: work that is waiting on the
                // server cannot finish until the server has been told.
                biased;
                () = &mut engine, if !stop_settled => stop_settled = true,
                finished = &mut work => break Some(finished),
                () = tokio::time::sleep_until(until) => break None,
            }
        };

        match finished {
            Some((resource, result)) => {
                // A connection-scoped stop can still be in flight, and
                // it names the connection rather than the statement, so
                // it could hit whatever that connection runs next.
                if !stop_settled && self.stop.delivery() == StopDelivery::OutOfBand(StopScope::Connection) {
                    stop_settled = tokio::time::timeout_at(until, &mut engine).await.is_ok();
                }
                Settled::Finished {
                    resource,
                    result,
                    stopped: Some(reason),
                    stop_settled,
                }
            }
            None => {
                self.abandon.store(true, Ordering::SeqCst);
                Settled::Abandoned(reason)
            }
        }
    }
}

/// Give the connection back, or take it out of the pool when it may not
/// be clean.
fn release<R: CallResource>(
    resource: R,
    delivery: StopDelivery,
    stopped: bool,
    acknowledged: bool,
    stop_settled: bool,
    lost: bool,
) {
    let discard = match delivery {
        StopDelivery::OutOfBand(StopScope::Connection) if stopped => !(acknowledged && stop_settled),
        _ => lost,
    };
    if discard {
        resource.discard();
    }
}

fn reason_error(reason: StopReason) -> DriverError {
    match reason {
        StopReason::Cancelled => DriverError::Cancelled,
        StopReason::DeadlineElapsed => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        },
        StopReason::Shutdown => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
    }
}

async fn deadline_elapsed(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;

    use async_trait::async_trait;

    use super::*;
    use crate::server_diagnostics::{ServerCode, ServerDiagnostics};

    #[derive(Debug)]
    struct Connection {
        abandon: Arc<AtomicBool>,
        discarded: Arc<AtomicBool>,
    }

    impl Connection {
        fn new() -> (Self, Arc<AtomicBool>, Arc<AtomicBool>) {
            let abandon = Arc::new(AtomicBool::new(false));
            let discarded = Arc::new(AtomicBool::new(false));
            (
                Self {
                    abandon: abandon.clone(),
                    discarded: discarded.clone(),
                },
                abandon,
                discarded,
            )
        }
    }

    impl CallResource for Connection {
        fn abandon_flag(&self) -> Arc<AtomicBool> {
            self.abandon.clone()
        }

        fn discard(self) {
            self.discarded.store(true, Ordering::SeqCst);
        }
    }

    struct Engine {
        delivery: StopDelivery,
        sent: Arc<AtomicUsize>,
    }

    impl Engine {
        fn new(delivery: StopDelivery) -> (Arc<Self>, Arc<AtomicUsize>) {
            let sent = Arc::new(AtomicUsize::new(0));
            (
                Arc::new(Self {
                    delivery,
                    sent: sent.clone(),
                }),
                sent,
            )
        }
    }

    #[async_trait]
    impl EngineStop for Engine {
        fn delivery(&self) -> StopDelivery {
            self.delivery
        }

        async fn stop(&self) -> Result<(), DriverError> {
            self.sent.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }

        fn acknowledged(&self, error: &DriverError) -> bool {
            matches!(error, DriverError::Server(diagnostics) if diagnostics.sqlstate() == Some("57014"))
        }
    }

    fn cancelled_by_server() -> DriverError {
        DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::SqlState("57014".to_owned())),
            "canceling statement due to user request",
        ))
    }

    fn options(deadline: Option<Instant>, cancel: &CancellationToken) -> CallOptions {
        CallOptions::new(deadline, cancel.clone())
    }

    #[tokio::test]
    async fn a_call_that_finishes_gives_its_answer_and_keeps_the_connection() {
        let calls = OwnedCalls::new(Duration::from_secs(1));
        let (connection, _abandon, discarded) = Connection::new();
        let (engine, sent) = Engine::new(StopDelivery::OutOfBand(StopScope::Connection));
        let cancel = CancellationToken::new();

        let answer = calls
            .run_read(
                options(None, &cancel),
                connection,
                engine,
                |resource, _stop| async move { (resource, Ok(7)) },
            )
            .await;

        assert_eq!(answer.expect("the answer"), 7);
        assert!(
            !discarded.load(Ordering::SeqCst),
            "a finished call discarded its connection"
        );
        assert_eq!(
            sent.load(Ordering::SeqCst),
            0,
            "a stop was sent for a call that finished"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_deadline_stops_the_work_and_reads_as_a_timeout() {
        let calls = OwnedCalls::new(Duration::from_secs(5));
        let (connection, _abandon, discarded) = Connection::new();
        let (engine, sent) = Engine::new(StopDelivery::OutOfBand(StopScope::Statement));
        let cancel = CancellationToken::new();
        let deadline = Instant::now() + Duration::from_millis(100);

        let answer = calls
            .run_read::<_, _, u8, _, _>(
                options(Some(deadline), &cancel),
                connection,
                engine,
                |resource, stop| async move {
                    stop.requested().await;
                    (resource, Err(cancelled_by_server()))
                },
            )
            .await;

        assert!(
            matches!(
                answer,
                Err(DriverError::Timeout {
                    phase: TimeoutPhase::Statement,
                    server_cancelled: true
                })
            ),
            "got {answer:?}"
        );
        assert_eq!(sent.load(Ordering::SeqCst), 1, "the engine's own stop was not sent");
        assert!(
            !discarded.load(Ordering::SeqCst),
            "a statement-scoped stop discarded the connection"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_cancelled_call_reads_as_cancelled_not_as_the_engines_error() {
        let calls = OwnedCalls::new(Duration::from_secs(5));
        let (connection, _abandon, _discarded) = Connection::new();
        let (engine, _sent) = Engine::new(StopDelivery::InBand);
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            trigger.cancel();
        });

        let answer = calls
            .run_read::<_, _, u8, _, _>(
                options(None, &cancel),
                connection,
                engine,
                |resource, stop| async move {
                    stop.requested().await;
                    (resource, Err(cancelled_by_server()))
                },
            )
            .await;

        assert!(matches!(answer, Err(DriverError::Cancelled)), "got {answer:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn work_that_ignores_the_stop_loses_its_connection() {
        let calls = OwnedCalls::new(Duration::from_millis(50));
        let (connection, abandon, _discarded) = Connection::new();
        let (engine, _sent) = Engine::new(StopDelivery::InBand);
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            trigger.cancel();
        });

        let answer = calls
            .run_read::<_, _, u8, _, _>(
                options(None, &cancel),
                connection,
                engine,
                |resource, _stop| async move {
                    tokio::time::sleep(Duration::from_secs(60)).await;
                    (resource, Ok(1))
                },
            )
            .await;

        assert!(
            matches!(
                answer,
                Err(DriverError::ConnectionLost {
                    during: LossPhase::Statement
                })
            ),
            "got {answer:?}"
        );
        assert!(
            abandon.load(Ordering::SeqCst),
            "the pool was not told to reject the connection"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_connection_scoped_stop_that_may_still_land_takes_the_connection_with_it() {
        let calls = OwnedCalls::new(Duration::from_secs(5));
        let (connection, _abandon, discarded) = Connection::new();
        let (engine, _sent) = Engine::new(StopDelivery::OutOfBand(StopScope::Connection));
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            trigger.cancel();
        });

        // The work finishes on its own rather than by acknowledging the
        // stop, so the stop is still out there with this connection's
        // name on it.
        let answer = calls
            .run_read(
                options(None, &cancel),
                connection,
                engine,
                |resource, _stop| async move {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    (resource, Ok(3))
                },
            )
            .await;

        assert_eq!(answer.expect("the answer"), 3);
        assert!(
            discarded.load(Ordering::SeqCst),
            "a connection a stop may still hit went back to the pool"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_write_lost_past_the_grace_reports_what_the_ledger_saw() {
        let calls = OwnedCalls::new(Duration::from_millis(50));
        let (connection, _abandon, _discarded) = Connection::new();
        let (engine, _sent) = Engine::new(StopDelivery::InBand);
        let ledger = Arc::new(WriteLedger::new(crate::write_ledger::WriteAtomicity::Transactional));
        ledger.statement_confirmed(0);
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            trigger.cancel();
        });

        let answer = calls
            .run_write(
                options(None, &cancel),
                connection,
                engine,
                ledger.clone(),
                |resource, _stop| async move {
                    tokio::time::sleep(Duration::from_secs(60)).await;
                    (resource, Ok(WriteReport::default()))
                },
            )
            .await;

        assert!(
            matches!(answer, Err(DriverError::RolledBack { .. })),
            "a write lost before its commit did not report a rollback: {answer:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_write_holds_its_engine_stop_while_a_statement_is_in_flight() {
        let calls = OwnedCalls::new(Duration::from_millis(50));
        let (connection, _abandon, _discarded) = Connection::new();
        let (engine, sent) = Engine::new(StopDelivery::OutOfBand(StopScope::Connection));
        let ledger = Arc::new(WriteLedger::new(
            crate::write_ledger::WriteAtomicity::StatementByStatement,
        ));
        ledger.statement_sending(0);
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            trigger.cancel();
        });

        let _ = calls
            .run_write(
                options(None, &cancel),
                connection,
                engine,
                ledger,
                |resource, _stop| async move {
                    tokio::time::sleep(Duration::from_secs(60)).await;
                    (resource, Ok(WriteReport::default()))
                },
            )
            .await;

        assert_eq!(
            sent.load(Ordering::SeqCst),
            0,
            "a statement that cannot be taken back was stopped anyway"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn shutdown_stops_the_calls_that_are_still_running() {
        let calls = Arc::new(OwnedCalls::new(Duration::from_millis(50)));
        let (connection, _abandon, _discarded) = Connection::new();
        let (engine, _sent) = Engine::new(StopDelivery::InBand);
        let cancel = CancellationToken::new();

        let running = {
            let calls = calls.clone();
            let cancel = cancel.clone();
            tokio::spawn(async move {
                calls
                    .run_read::<_, _, u8, _, _>(
                        CallOptions::new(None, cancel),
                        connection,
                        engine,
                        |resource, stop| async move {
                            stop.requested().await;
                            (resource, Err(cancelled_by_server()))
                        },
                    )
                    .await
            })
        };

        tokio::time::sleep(Duration::from_millis(10)).await;
        calls.shutdown().await;

        let answer = running.await.expect("the call finished");
        assert!(matches!(answer, Err(DriverError::Cancelled)), "got {answer:?}");
    }
}
