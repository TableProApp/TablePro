use std::future::Future;
use std::sync::Arc;

use tablepro_core::{CallOptions, DriverError, ErrorCategory};
use tokio::sync::watch;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use super::{DeadlinePolicy, OperationError, OperationKind, ReplayRule};
use crate::health::{LinkGeneration, MonitorMailbox, MonitorSignal, SessionHealth};
use crate::link::{ConnectionLease, ConnectionLink};
use crate::runtime::catch_panic;

/// The chokepoint every use of a session's connection goes through.
///
/// It adds no timer of its own: the deadline travels in `CallOptions`,
/// so the driver can stop the statement on the server rather than
/// leaving it running behind a dropped future.
#[derive(Clone)]
pub struct OperationRunner {
    link: Arc<ConnectionLink>,
    deadlines: Arc<dyn DeadlinePolicy>,
    mailbox: Arc<MonitorMailbox>,
    health: watch::Receiver<SessionHealth>,
    cancel: CancellationToken,
}

struct Failure {
    error: OperationError,
    generation: LinkGeneration,
}

impl OperationRunner {
    pub fn new(
        link: Arc<ConnectionLink>,
        deadlines: Arc<dyn DeadlinePolicy>,
        mailbox: Arc<MonitorMailbox>,
        health: watch::Receiver<SessionHealth>,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            link,
            deadlines,
            mailbox,
            health,
            cancel,
        }
    }

    /// Run `op` on the current connection.
    ///
    /// `cancel` is the caller's: firing it gives `Cancelled`, while the
    /// session shutting down gives `Closed`. A read that failed because
    /// its connection was lost runs once more when the link has already
    /// been replaced, building its SQL again from the new lease.
    pub async fn run_cancellable<T, F, Fut>(
        &self,
        kind: OperationKind,
        cancel: &CancellationToken,
        op: F,
    ) -> Result<T, OperationError>
    where
        F: Fn(ConnectionLease, CallOptions) -> Fut + Send + Sync,
        Fut: Future<Output = Result<T, OperationError>> + Send,
        T: Send,
    {
        match self.attempt(kind, cancel, &op).await {
            Ok(value) => Ok(value),
            Err(failure)
                if ReplayRule::should_replay(kind, &failure.error, failure.generation, self.link.generation()) =>
            {
                tracing::debug!(
                    ?kind,
                    from = failure.generation.get(),
                    "replaying a read on the new connection"
                );
                self.attempt(kind, cancel, &op).await.map_err(|failure| failure.error)
            }
            Err(failure) => Err(failure.error),
        }
    }

    async fn attempt<T, F, Fut>(&self, kind: OperationKind, cancel: &CancellationToken, op: &F) -> Result<T, Failure>
    where
        F: Fn(ConnectionLease, CallOptions) -> Fut + Send + Sync,
        Fut: Future<Output = Result<T, OperationError>> + Send,
        T: Send,
    {
        let unleased = |error| Failure {
            error,
            generation: self.link.generation(),
        };
        if self.cancel.is_cancelled() {
            return Err(unleased(OperationError::Closed));
        }
        if cancel.is_cancelled() {
            return Err(unleased(OperationError::Cancelled));
        }
        let Some(lease) = self.link.lease() else {
            return Err(unleased(OperationError::Closed));
        };
        let generation = lease.generation();
        let child = self.cancel.child_token();
        let deadline = self.deadlines.deadline(kind).map(|limit| Instant::now() + limit);
        let options = CallOptions::new(deadline, child.clone());

        // Calling `op` inside the future puts a panic while building it
        // under the same catch as one while it runs.
        let running = catch_panic(async { op(lease, options).await });
        tokio::pin!(running);
        let outcome = tokio::select! {
            biased;
            outcome = &mut running => outcome,
            () = cancel.cancelled() => {
                // The driver stops the call itself and returns promptly,
                // which keeps the lease until the server has let go.
                child.cancel();
                running.await
            }
        };

        let error = match outcome {
            Ok(Ok(value)) => {
                if !self.health.borrow().is_online() {
                    self.mailbox.post(MonitorSignal::OperationSucceeded { generation });
                }
                return Ok(value);
            }
            Ok(Err(error)) => error,
            Err(panic) => {
                tracing::error!(?kind, %panic, "an operation panicked");
                self.mailbox.post(MonitorSignal::ProbeRequested { generation });
                OperationError::Panicked(panic)
            }
        };
        let error = match error {
            OperationError::Driver(DriverError::Cancelled) if cancel.is_cancelled() => OperationError::Cancelled,
            OperationError::Driver(DriverError::Cancelled) if self.cancel.is_cancelled() => OperationError::Closed,
            other => other,
        };
        if error.category() == Some(ErrorCategory::ConnectionLost) {
            self.mailbox.post(MonitorSignal::ConnectionLost { generation });
        }
        Err(Failure { error, generation })
    }
}

impl std::fmt::Debug for OperationRunner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OperationRunner")
            .field("link", &self.link)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use tablepro_core::{LivenessPolicy, LossPhase, WriteKind};
    use tablepro_test_support::{ConnectionScript, FakeConnection, FakeReply};

    use super::*;
    use crate::health::PendingSignals;
    use crate::link::EstablishedConnection;
    use crate::operation::DefaultDeadlines;

    struct Harness {
        runner: OperationRunner,
        link: Arc<ConnectionLink>,
        mailbox: Arc<MonitorMailbox>,
        health: watch::Sender<SessionHealth>,
        session: CancellationToken,
    }

    fn established() -> EstablishedConnection {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::UntilStopped);
        EstablishedConnection {
            connection: Arc::new(FakeConnection::new(script)),
            ssh_session: None,
        }
    }

    fn harness() -> Harness {
        let link = Arc::new(ConnectionLink::new(established()));
        let mailbox = Arc::new(MonitorMailbox::new());
        let (health, health_receiver) = watch::channel(SessionHealth::Online);
        let session = CancellationToken::new();
        let runner = OperationRunner::new(
            link.clone(),
            Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
            mailbox.clone(),
            health_receiver,
            session.clone(),
        );
        Harness {
            runner,
            link,
            mailbox,
            health,
            session,
        }
    }

    fn lost() -> OperationError {
        OperationError::Driver(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        })
    }

    async fn pending(mailbox: &MonitorMailbox) -> PendingSignals {
        tokio::time::timeout(Duration::from_secs(1), mailbox.next())
            .await
            .unwrap_or_default()
    }

    /// An op that replaces the link the first time it runs, then fails
    /// with `error`, the way a reconnect lands mid-operation.
    async fn run_failing_after_replace(
        harness: &Harness,
        kind: OperationKind,
        error: OperationError,
    ) -> (Result<LinkGeneration, OperationError>, usize) {
        let calls = AtomicUsize::new(0);
        let outcome = harness
            .runner
            .run_cancellable(kind, &CancellationToken::new(), |lease, _| {
                let call = calls.fetch_add(1, Ordering::SeqCst);
                let link = harness.link.clone();
                let error = error.clone();
                async move {
                    if call == 0 {
                        link.replace(established());
                        return Err(error);
                    }
                    Ok(lease.generation())
                }
            })
            .await;
        (outcome, calls.load(Ordering::SeqCst))
    }

    #[tokio::test(start_paused = true)]
    async fn loss_on_retired_generation_does_not_post_current_loss() {
        let harness = harness();

        let (outcome, _) =
            run_failing_after_replace(&harness, OperationKind::Save(WriteKind::RowChanges), lost()).await;

        assert_eq!(outcome, Err(lost()));
        assert_eq!(harness.link.generation(), LinkGeneration::FIRST.next());
        assert_eq!(
            pending(&harness.mailbox).await.lost,
            Some(LinkGeneration::FIRST),
            "the loss was posted against the connection that replaced the lost one"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn page_replays_once_on_newer_lease_after_connection_lost() {
        let harness = harness();

        let (outcome, calls) = run_failing_after_replace(&harness, OperationKind::Page, lost()).await;

        assert_eq!(outcome, Ok(LinkGeneration::FIRST.next()));
        assert_eq!(calls, 2);
    }

    #[tokio::test(start_paused = true)]
    async fn a_replay_runs_once_even_when_it_fails_the_same_way() {
        let harness = harness();
        let calls = AtomicUsize::new(0);

        let outcome = harness
            .runner
            .run_cancellable(OperationKind::Metadata, &CancellationToken::new(), |_, _| {
                calls.fetch_add(1, Ordering::SeqCst);
                harness.link.replace(established());
                async { Err::<(), _>(lost()) }
            })
            .await;

        assert_eq!(outcome, Err(lost()));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn server_error_is_not_replayed_on_newer_lease() {
        let harness = harness();
        let server = OperationError::Driver(DriverError::server("relation does not exist"));

        let (outcome, calls) = run_failing_after_replace(&harness, OperationKind::Page, server.clone()).await;

        assert_eq!(outcome, Err(server));
        assert_eq!(calls, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn save_is_never_replayed() {
        let harness = harness();

        for kind in [WriteKind::RowChanges, WriteKind::SchemaChanges] {
            let (outcome, calls) = run_failing_after_replace(&harness, OperationKind::Save(kind), lost()).await;

            assert_eq!(outcome, Err(lost()));
            assert_eq!(calls, 1, "{kind:?} ran twice");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn caller_cancel_maps_cancelled_session_cancel_maps_closed() {
        let harness = harness();
        let probe = |lease: ConnectionLease, options: CallOptions| async move {
            lease.probe(options).await.map_err(OperationError::from)
        };

        let caller = CancellationToken::new();
        let stopping = {
            let caller = caller.clone();
            async move {
                tokio::time::sleep(Duration::from_millis(10)).await;
                caller.cancel();
            }
        };
        let (outcome, ()) = tokio::join!(
            harness.runner.run_cancellable(OperationKind::Page, &caller, probe),
            stopping
        );
        assert_eq!(outcome, Err(OperationError::Cancelled));

        let closing = {
            let session = harness.session.clone();
            async move {
                tokio::time::sleep(Duration::from_millis(10)).await;
                session.cancel();
            }
        };
        let unrelated = CancellationToken::new();
        let (outcome, ()) = tokio::join!(
            harness.runner.run_cancellable(OperationKind::Page, &unrelated, probe),
            closing
        );
        assert_eq!(outcome, Err(OperationError::Closed));

        let calls = AtomicUsize::new(0);
        let after_close = harness
            .runner
            .run_cancellable(OperationKind::Page, &CancellationToken::new(), |_, _| {
                calls.fetch_add(1, Ordering::SeqCst);
                async { Ok(()) }
            })
            .await;
        assert_eq!(after_close, Err(OperationError::Closed));
        assert_eq!(calls.load(Ordering::SeqCst), 0, "a closed session still ran the op");
    }

    async fn explode() -> Result<(), OperationError> {
        panic!("boom")
    }

    #[tokio::test(start_paused = true)]
    async fn panic_posts_probe_requested() {
        let harness = harness();

        let outcome = harness
            .runner
            .run_cancellable(OperationKind::Page, &CancellationToken::new(), |_, _| explode())
            .await;

        assert!(matches!(outcome, Err(OperationError::Panicked(_))));
        assert_eq!(
            pending(&harness.mailbox).await.probe_requested,
            Some(LinkGeneration::FIRST)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn success_while_reconnecting_posts_operation_succeeded() {
        let harness = harness();
        harness.health.send_replace(SessionHealth::Reconnecting { attempt: 2 });

        harness
            .runner
            .run_cancellable(OperationKind::Count, &CancellationToken::new(), |_, _| async {
                Ok::<u64, OperationError>(3)
            })
            .await
            .unwrap();

        assert_eq!(pending(&harness.mailbox).await.succeeded, Some(LinkGeneration::FIRST));
    }

    #[tokio::test(start_paused = true)]
    async fn success_while_online_posts_nothing() {
        let harness = harness();

        harness
            .runner
            .run_cancellable(OperationKind::Count, &CancellationToken::new(), |_, _| async {
                Ok::<u64, OperationError>(3)
            })
            .await
            .unwrap();

        assert!(pending(&harness.mailbox).await.is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn the_kind_sets_the_call_deadline() {
        let harness = harness();
        let started = Instant::now();

        let deadlines = harness
            .runner
            .run_cancellable(
                OperationKind::Page,
                &CancellationToken::new(),
                |_, options| async move { Ok::<_, OperationError>(options.deadline()) },
            )
            .await
            .unwrap();
        let unbounded = harness
            .runner
            .run_cancellable(
                OperationKind::Save(WriteKind::SchemaChanges),
                &CancellationToken::new(),
                |_, options| async move { Ok::<_, OperationError>(options.deadline()) },
            )
            .await
            .unwrap();

        assert_eq!(deadlines, Some(started + DefaultDeadlines::PAGE));
        assert_eq!(unbounded, None);
    }
}
