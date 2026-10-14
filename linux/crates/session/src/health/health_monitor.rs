use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tablepro_core::CallOptions;
use tablepro_storage::CredentialDemand;
use tokio::sync::watch;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use super::{
    FailureCause, HealthPolicy, LinkGeneration, MonitorAction, MonitorMailbox, MonitorSignal, PendingSignals,
    ProbeOutcome, ReachabilityTarget, ReconnectPlan, ReconnectResult, SessionHealth,
};
use crate::connect::{ConnectError, PendingSession};
use crate::link::{ConnectionLease, ConnectionLink};
use crate::operation::{DeadlinePolicy, OperationKind};
use crate::runtime::{Tasks, catch_panic};
use crate::session::SchemaCatalog;

/// Everything the monitor task owns. It holds no `Session`, so dropping
/// the last session handle is what ends it.
pub(crate) struct MonitorContext {
    pub link: Arc<ConnectionLink>,
    pub plan: ReconnectPlan,
    pub deadlines: Arc<dyn DeadlinePolicy>,
    pub tasks: Tasks,
    pub health: watch::Sender<SessionHealth>,
    pub mailbox: Arc<MonitorMailbox>,
    pub cancel: CancellationToken,
    pub catalog: Arc<SchemaCatalog>,
    pub reachability: Arc<Mutex<ReachabilityTarget>>,
    pub close_timeout: Duration,
}

enum Wakeup {
    Signals(PendingSignals),
    Deadline,
    LeaseLost(LinkGeneration),
}

/// Watch one session's connection until the session is cancelled.
///
/// The policy is created here, inside the runtime, so its clock reading
/// is the runtime's own.
pub(crate) async fn run_monitor(ctx: MonitorContext) {
    let mut policy = HealthPolicy::new(ctx.link.generation(), Instant::now());
    // A lost connection stays lost, so its watch is dropped once it has
    // fired; otherwise a failed reconnect would wake on it forever.
    let mut reported_loss: Option<LinkGeneration> = None;
    loop {
        let watched = ctx
            .link
            .lease()
            .filter(|lease| lease.generation() == policy.generation() && reported_loss != Some(lease.generation()));
        let wakeup = tokio::select! {
            biased;
            () = ctx.cancel.cancelled() => return,
            signals = ctx.mailbox.next() => Wakeup::Signals(signals),
            () = sleep_until(policy.next_deadline()) => Wakeup::Deadline,
            generation = lease_lost(watched) => Wakeup::LeaseLost(generation),
        };
        let now = Instant::now();
        let (mut action, mut user_asked) = match wakeup {
            Wakeup::Signals(signals) => (policy.on_signals(&signals, now), signals.retry),
            Wakeup::Deadline => (policy.on_deadline(now), false),
            Wakeup::LeaseLost(generation) => {
                reported_loss = Some(generation);
                let mut signals = PendingSignals::default();
                signals.merge(MonitorSignal::ConnectionLost { generation });
                (policy.on_signals(&signals, now), false)
            }
        };
        loop {
            publish(&ctx.health, policy.health());
            action = match action {
                MonitorAction::Wait | MonitorAction::Park => break,
                MonitorAction::Probe => {
                    let outcome = probe(&ctx).await;
                    if let ProbeOutcome::Rejected(cause) = &outcome {
                        tracing::warn!(?cause, "the server refused a probe on a live connection");
                    }
                    policy.on_probe(&outcome, Instant::now())
                }
                MonitorAction::Reconnect => {
                    let Some(result) = reconnect(&ctx, user_asked).await else {
                        return;
                    };
                    // Only the attempt the user started may ask them
                    // anything; the backoff ones after it run unattended.
                    user_asked = false;
                    policy.on_reconnect(&result, Instant::now())
                }
            };
        }
    }
}

async fn sleep_until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}

/// Resolves when the leased connection reports itself lost, or when the
/// SSH master under it exits.
async fn lease_lost(lease: Option<ConnectionLease>) -> LinkGeneration {
    let Some(lease) = lease else {
        return std::future::pending().await;
    };
    let generation = lease.generation();
    let lost = lease.lost();
    match lease.ssh_closed() {
        Some(closed) => tokio::select! {
            biased;
            () = lost => {},
            () = closed => {},
        },
        None => lost.await,
    }
    generation
}

fn publish(sender: &watch::Sender<SessionHealth>, health: &SessionHealth) {
    sender.send_if_modified(|current| {
        if current == health {
            return false;
        }
        *current = health.clone();
        true
    });
}

async fn probe(ctx: &MonitorContext) -> ProbeOutcome {
    let Some(lease) = ctx.link.lease() else {
        return ProbeOutcome::Lost;
    };
    let deadline = ctx
        .deadlines
        .deadline(OperationKind::Probe)
        .map(|limit| Instant::now() + limit);
    let options = CallOptions::new(deadline, ctx.cancel.child_token());
    match catch_panic(lease.probe(options)).await {
        Ok(result) => ProbeOutcome::classify(result),
        Err(panic) => {
            tracing::error!(%panic, "the health probe panicked");
            ProbeOutcome::Unresponsive
        }
    }
}

/// One reconnect attempt, or `None` when the session was cancelled
/// while it ran.
///
/// The attempt runs as its own task so a cancel can stop waiting on it
/// without dropping it: a driver blocked in a C call finishes anyway,
/// and whatever it built is closed rather than adopted.
async fn reconnect(ctx: &MonitorContext, user_asked: bool) -> Option<ReconnectResult> {
    let plan = ctx.plan.clone();
    let interaction = plan.interaction(user_asked);
    let attempt_cancel = ctx.cancel.child_token();
    let attempt = async move {
        // Only the connect has to run on after a cancel. A password
        // dialog a Retry raised goes with the session instead of
        // staying up for an attempt nobody waits on.
        let request = plan.request.clone();
        let refreshing = plan
            .credentials
            .refresh(request, interaction.clone(), CredentialDemand::default());
        let refreshed = attempt_cancel
            .run_until_cancelled(refreshing)
            .await
            .ok_or(ConnectError::Cancelled)??;
        let pending = plan
            .connector
            .establish(refreshed.request, interaction, attempt_cancel)
            .await?;
        Ok::<_, ConnectError>((pending, refreshed.remember))
    };
    let mut running = ctx.tasks.spawn_task(attempt);
    let joined = tokio::select! {
        biased;
        () = ctx.cancel.cancelled() => {
            ctx.tasks.spawn_task(async move {
                if let Ok(Ok((pending, _))) = running.await {
                    discard_late(pending).await;
                }
            });
            return None;
        }
        joined = &mut running => joined,
    };

    let (pending, remember) = match joined {
        Ok(Ok(established)) => established,
        Ok(Err(error)) => {
            tracing::info!(%error, "a reconnect attempt failed");
            return Some(classify_failure(&error));
        }
        Err(failure) => {
            tracing::error!(%failure, "a reconnect attempt panicked");
            return Some(ReconnectResult::Failed);
        }
    };
    if ctx.cancel.is_cancelled() {
        ctx.tasks.spawn_task(discard_late(pending));
        return None;
    }
    let parts = pending.into_parts();
    let reachability = ReachabilityTarget::for_established(&parts.request, &parts.established);
    let (generation, retired) = ctx.link.replace(parts.established);
    if let Some(retired) = retired {
        let close_timeout = ctx.close_timeout;
        ctx.tasks.spawn_task(async move {
            let report = retired.close(close_timeout).await;
            tracing::debug!(?report, "closed the replaced connection");
        });
    }
    // Shutdown cancels before it takes the link, so a replacement the
    // link refused, handed back above to close, always shows up here.
    if ctx.cancel.is_cancelled() {
        return None;
    }
    *ctx.reachability.lock().unwrap_or_else(PoisonError::into_inner) = reachability;
    ctx.catalog.commit(parts.schemas, parts.objects);
    if !remember.is_empty() {
        let stored = ctx.plan.credentials.remember(remember);
        ctx.tasks.spawn_task(async move {
            for (kind, error) in stored.await {
                tracing::warn!(?kind, %error, "a secret typed for the reconnect was not stored");
            }
        });
    }
    Some(ReconnectResult::Connected(generation))
}

/// A refused prompt is the user saying no, so the session parks rather
/// than retrying behind their back.
fn classify_failure(error: &ConnectError) -> ReconnectResult {
    match (error, error.failure_cause()) {
        (_, Some(cause)) => ReconnectResult::Rejected(cause),
        (ConnectError::Cancelled, None) => ReconnectResult::Rejected(FailureCause::Authentication),
        (_, None) => ReconnectResult::Failed,
    }
}

async fn discard_late(pending: PendingSession) {
    let report = pending.discard().await;
    tracing::debug!(?report, "closed a reconnect that finished after its session ended");
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_core::{DriverError, LivenessPolicy, LossPhase, NetworkEndpoint, TransportError};
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakePrompter, FakeReply};

    use super::*;
    use crate::connect::{ConnectRequest, CredentialSource, RefreshedRequest};
    use crate::fakes::{FakeConnector, FakeCredentialSource, FakeEstablish};
    use crate::health::Reachability;
    use crate::operation::DefaultDeadlines;
    use crate::session::{Session, SessionDeps};
    use crate::test_support::paused_tasks;

    /// Credentials that ask the user, who never answers. Each question
    /// stays open for as long as the refresh that asked it is alive.
    #[derive(Debug, Default)]
    struct UnansweredPrompt {
        questions: Mutex<Vec<tokio::sync::oneshot::Sender<()>>>,
    }

    impl UnansweredPrompt {
        fn still_asking(&self) -> bool {
            self.questions
                .lock()
                .unwrap()
                .iter()
                .any(|question| !question.is_closed())
        }
    }

    impl CredentialSource for UnansweredPrompt {
        fn refresh(
            &self,
            request: ConnectRequest,
            _interaction: tablepro_core::credentials::CredentialInteraction,
            _demand: CredentialDemand,
        ) -> futures::future::BoxFuture<'static, Result<RefreshedRequest, ConnectError>> {
            let (question, answer) = tokio::sync::oneshot::channel();
            self.questions.lock().unwrap().push(question);
            Box::pin(async move {
                let _unanswered = answer.await;
                Ok(RefreshedRequest {
                    request,
                    remember: Vec::new(),
                })
            })
        }
    }

    fn refused() -> ConnectError {
        ConnectError::Driver(DriverError::Transport(TransportError::Refused {
            endpoint: NetworkEndpoint::new("db.example.com", 5432).unwrap(),
        }))
    }

    fn healthy() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::ok(()));
        script
    }

    struct Started {
        session: Arc<Session>,
        connection: Arc<FakeConnection>,
        connector: Arc<FakeConnector>,
        credentials: Arc<FakeCredentialSource>,
    }

    fn start(script: ConnectionScript, connector: FakeConnector) -> Started {
        start_with(script, connector, None)
    }

    fn start_with(script: ConnectionScript, connector: FakeConnector, prompter: Option<Arc<FakePrompter>>) -> Started {
        let (pending, connection) = FakeConnector::pending_session(FakeConnector::request().unwrap(), script);
        let connector = Arc::new(connector);
        let credentials = Arc::new(FakeCredentialSource::new());
        let session = Session::start(
            pending,
            SessionDeps {
                connector: connector.clone(),
                credentials: credentials.clone(),
                deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
                tasks: paused_tasks(),
                prompter: prompter.map(|prompter| prompter as _),
            },
        );
        Started {
            session,
            connection,
            connector,
            credentials,
        }
    }

    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    fn lost() -> MonitorSignal {
        MonitorSignal::ConnectionLost {
            generation: LinkGeneration::FIRST,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn reconnects_on_connection_lost_with_exact_backoff() {
        let connector = FakeConnector::new([
            FakeEstablish::Fail(refused()),
            FakeEstablish::Fail(refused()),
            FakeEstablish::Fail(refused()),
            FakeEstablish::Connect(healthy()),
        ]);
        let started = start(healthy(), connector);
        let lost_at = Instant::now();

        started.session.signal(lost());
        tokio::time::sleep(Duration::from_secs(120)).await;

        let offsets: Vec<Duration> = started.connector.calls().iter().map(|call| call.at - lost_at).collect();
        assert_eq!(
            offsets,
            [0, 5, 15, 35].map(Duration::from_secs),
            "attempts did not follow the 5 s doubling backoff"
        );
        assert_eq!(*started.session.health().borrow(), SessionHealth::Online);
        assert_eq!(
            started.session.link_changes().borrow().get(),
            1,
            "the reconnect did not replace the link"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_commits_the_new_catalog() {
        let column = tablepro_core::ColumnInfo {
            name: "id".to_owned(),
            column_type: tablepro_core::column::ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: tablepro_core::column::ColumnDefault::None,
            comment: None,
        };
        let mut first = healthy();
        first.fetch_columns.always(FakeReply::ok(vec![column.clone()]));
        let mut second = healthy();
        second.fetch_columns.always(FakeReply::ok(vec![column]));
        let started = start(first, FakeConnector::new([FakeEstablish::Connect(second)]));
        let table = tablepro_core::TableRef::unqualified("users");
        let objects = started
            .session
            .subscribe_objects(tablepro_core::meta::ObjectScope::DefaultSchema);
        started.session.columns(table.clone()).await.unwrap();

        started.session.signal(lost());
        tokio::time::sleep(Duration::from_secs(1)).await;
        started.session.columns(table).await.unwrap();

        assert_eq!(started.session.link_changes().borrow().get(), 1);
        assert_eq!(objects.borrow().generation, 2, "the reconnect left the old object list");
        let replacement = started.connector.connections().pop().unwrap();
        assert_eq!(
            CallCounters::get(&replacement.counters().fetch_columns),
            1,
            "columns read before the reconnect were trusted after it"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn lost_then_unreachable_offline_then_reachable_reconnects_immediately() {
        let connector = FakeConnector::new([FakeEstablish::Fail(refused()), FakeEstablish::Fail(refused())])
            .always(FakeEstablish::Connect(healthy()));
        let started = start(healthy(), connector);
        let lost_at = Instant::now();

        started.session.signal(lost());
        settle().await;
        started
            .session
            .signal(MonitorSignal::Reachability(Reachability::Unreachable));
        tokio::time::sleep(HealthPolicy::BACKOFF_INITIAL + Duration::from_secs(5)).await;
        assert_eq!(*started.session.health().borrow(), SessionHealth::Offline);
        assert_eq!(started.connector.calls().len(), 2);

        let back_at = Instant::now();
        started
            .session
            .signal(MonitorSignal::Reachability(Reachability::Reachable));
        settle().await;

        let calls = started.connector.calls();
        assert_eq!(calls.len(), 3, "the network came back and nothing reconnected");
        assert_eq!(
            calls[2].at, back_at,
            "the reconnect waited for the offline recheck instead of the network"
        );
        assert!(back_at - lost_at < HealthPolicy::OFFLINE_RECHECK);
        assert_eq!(*started.session.health().borrow(), SessionHealth::Online);
    }

    #[tokio::test(start_paused = true)]
    async fn health_counts_the_reconnect_attempts() {
        let connector = FakeConnector::new([]).always(FakeEstablish::Fail(refused()));
        let started = start(healthy(), connector);

        started.session.signal(lost());
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert_eq!(
            *started.session.health().borrow(),
            SessionHealth::Reconnecting { attempt: 2 }
        );
        tokio::time::sleep(Duration::from_secs(5)).await;
        assert_eq!(
            *started.session.health().borrow(),
            SessionHealth::Reconnecting { attempt: 3 }
        );
    }

    #[tokio::test(start_paused = true)]
    async fn refresh_called_each_attempt() {
        let connector = FakeConnector::new([
            FakeEstablish::Fail(refused()),
            FakeEstablish::Fail(refused()),
            FakeEstablish::Connect(healthy()),
        ]);
        let started = start(healthy(), connector);

        started.session.signal(lost());
        tokio::time::sleep(Duration::from_secs(60)).await;

        assert_eq!(started.connector.calls().len(), 3);
        assert_eq!(
            started.credentials.refreshes().len(),
            3,
            "a reconnect reused stale secrets"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn monitor_passes_unattended() {
        let prompter = Arc::new(FakePrompter::new([]));
        let connector = FakeConnector::new([FakeEstablish::Fail(refused()), FakeEstablish::Connect(healthy())]);
        let started = start_with(healthy(), connector, Some(prompter));

        started.session.signal(lost());
        tokio::time::sleep(Duration::from_secs(30)).await;

        let calls = started.connector.calls();
        assert_eq!(calls.len(), 2);
        assert!(
            calls.iter().all(|call| !call.attended),
            "a background reconnect could prompt"
        );
        assert!(started.credentials.refreshes().iter().all(|attended| !attended));
    }

    #[tokio::test(start_paused = true)]
    async fn retry_now_reconnects_attended_once() {
        let prompter = Arc::new(FakePrompter::new([]));
        let connector = FakeConnector::new([FakeEstablish::Fail(refused()), FakeEstablish::Connect(healthy())]);
        let started = start_with(healthy(), connector, Some(prompter));

        started.session.signal(MonitorSignal::RetryNow);
        tokio::time::sleep(Duration::from_secs(30)).await;

        let attended: Vec<bool> = started.connector.calls().iter().map(|call| call.attended).collect();
        assert_eq!(
            attended,
            [true, false],
            "only the attempt the user asked for may prompt"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn rejected_reconnect_parks_until_retry() {
        let connector = FakeConnector::new([
            FakeEstablish::Fail(ConnectError::Driver(DriverError::auth(None))),
            FakeEstablish::Connect(healthy()),
        ]);
        let started = start(healthy(), connector);

        started.session.signal(lost());
        tokio::time::sleep(Duration::from_secs(600)).await;
        assert_eq!(
            *started.session.health().borrow(),
            SessionHealth::Failed {
                cause: FailureCause::Authentication
            }
        );
        assert_eq!(started.connector.calls().len(), 1, "a parked session kept retrying");

        started.session.signal(MonitorSignal::RetryNow);
        settle().await;
        assert_eq!(started.connector.calls().len(), 2);
        assert_eq!(*started.session.health().borrow(), SessionHealth::Online);
    }

    #[tokio::test(start_paused = true)]
    async fn busy_probe_keeps_online() {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::err(DriverError::Busy));
        let started = start(script, FakeConnector::new([]));

        tokio::time::sleep(HealthPolicy::PROBE_INTERVAL * 5).await;

        assert!(CallCounters::get(&started.connection.counters().probe) >= 4);
        assert_eq!(*started.session.health().borrow(), SessionHealth::Online);
        assert!(
            started.connector.calls().is_empty(),
            "a busy server was treated as lost"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn three_lost_probes_reconnect() {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::err(DriverError::ConnectionLost {
            during: LossPhase::Idle,
        }));
        let started = start(script, FakeConnector::new([FakeEstablish::Connect(healthy())]));

        tokio::time::sleep(HealthPolicy::PROBE_INTERVAL + Duration::from_secs(1)).await;

        assert_eq!(started.connector.calls().len(), 1);
        assert_eq!(started.session.link_changes().borrow().get(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn lease_lost_future_wakes_monitor() {
        let started = start(healthy(), FakeConnector::new([FakeEstablish::Connect(healthy())]));
        settle().await;

        started.connection.mark_lost();
        settle().await;

        assert_eq!(
            started.connector.calls().len(),
            1,
            "the monitor waited for its probe timer instead"
        );
        assert_eq!(started.session.link_changes().borrow().get(), 1);
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(started.connection.is_closed(), "the replaced connection was left open");
    }

    #[tokio::test(start_paused = true)]
    async fn shutting_down_ends_a_prompt_a_retry_raised() {
        let prompt = Arc::new(UnansweredPrompt::default());
        let (pending, _connection) = FakeConnector::pending_session(FakeConnector::request().unwrap(), healthy());
        let connector = Arc::new(FakeConnector::new([]));
        let session = Session::start(
            pending,
            SessionDeps {
                connector: connector.clone(),
                credentials: prompt.clone(),
                deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
                tasks: paused_tasks(),
                prompter: Some(Arc::new(FakePrompter::new([]))),
            },
        );
        session.signal(MonitorSignal::RetryNow);
        settle().await;
        assert!(prompt.still_asking(), "the retry never asked");

        let report = session.begin_shutdown();
        tokio::time::sleep(Duration::from_secs(30)).await;

        assert!(report.await.is_ok());
        assert!(!prompt.still_asking(), "the prompt outlived the session that raised it");
        assert!(connector.calls().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn late_reconnect_after_cancel_is_discarded_and_closed() {
        let connector = FakeConnector::new([FakeEstablish::Late {
            after: Duration::from_secs(10),
            script: healthy(),
        }]);
        let started = start(healthy(), connector);
        started.session.signal(lost());
        settle().await;
        assert_eq!(started.connector.calls().len(), 1);

        let report = started.session.begin_shutdown();
        tokio::time::sleep(Duration::from_secs(30)).await;

        assert!(report.await.is_ok());
        let late = started.connector.connections();
        assert_eq!(late.len(), 1, "the late attempt never finished");
        assert!(late[0].is_closed(), "the late connection was adopted or left open");
        assert_eq!(started.session.link_changes().borrow().get(), 0);
    }
}
