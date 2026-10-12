use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tablepro_core::dialect::SqlDialect;
use tablepro_core::{CallOptions, EditorSession, EditorSessionOptions, WorkspaceSettings};
use tokio::sync::watch;
use tokio_util::sync::{CancellationToken, DropGuard};
use tokio_util::task::AbortOnDropHandle;
use uuid::Uuid;

use super::{CatalogSnapshot, SessionDeps};
use crate::connect::{ConnectionMetadata, PendingSession};
use crate::health::{
    LinkGeneration, MonitorContext, MonitorMailbox, MonitorSignal, ReachabilityTarget, ReconnectPlan, SessionHealth,
    run_monitor,
};
use crate::link::{CloseReport, ConnectionLease, ConnectionLink};
use crate::operation::{OperationError, OperationKind, OperationRunner};
use crate::runtime::{TaskResult, Tasks};

/// One window's connection to one database.
///
/// Built only from runtime-free parts, so the GTK thread can start one
/// without entering the runtime; the monitor runs on the app's `Tasks`.
/// Dropping the last handle cancels every operation and stops the
/// monitor; `begin_shutdown` is what closes the connection.
pub struct Session {
    metadata: ConnectionMetadata,
    workspace_settings: WorkspaceSettings,
    reachability: Arc<Mutex<ReachabilityTarget>>,
    runner: OperationRunner,
    mailbox: Arc<MonitorMailbox>,
    health: watch::Receiver<SessionHealth>,
    link: Arc<ConnectionLink>,
    catalog: watch::Receiver<CatalogSnapshot>,
    tasks: Tasks,
    close_timeout: Duration,
    cancel: CancellationToken,
    _cancel_on_drop: DropGuard,
    _monitor: AbortOnDropHandle<()>,
}

impl Session {
    pub fn start(pending: PendingSession, deps: SessionDeps) -> Arc<Session> {
        let parts = pending.into_parts();
        let close_timeout = deps
            .deadlines
            .deadline(OperationKind::Close)
            .unwrap_or(parts.close_timeout);
        let reachability = Arc::new(Mutex::new(ReachabilityTarget::for_established(
            &parts.request,
            &parts.established,
        )));
        let link = Arc::new(ConnectionLink::new(parts.established));
        let mailbox = Arc::new(MonitorMailbox::new());
        let (health_sender, health) = watch::channel(SessionHealth::Online);
        let (catalog_sender, catalog) = watch::channel(CatalogSnapshot {
            generation: link.generation(),
            schemas: parts.schemas.into(),
            objects: parts.objects.into(),
        });
        let cancel = CancellationToken::new();
        let runner = OperationRunner::new(
            link.clone(),
            deps.deadlines.clone(),
            mailbox.clone(),
            health.clone(),
            cancel.clone(),
        );
        let context = MonitorContext {
            link: link.clone(),
            plan: ReconnectPlan {
                connector: deps.connector,
                request: parts.request.for_reconnect(),
                credentials: deps.credentials,
                prompter: deps.prompter,
            },
            deadlines: deps.deadlines,
            tasks: deps.tasks.clone(),
            health: health_sender,
            mailbox: mailbox.clone(),
            cancel: cancel.clone(),
            catalog: catalog_sender,
            reachability: reachability.clone(),
            close_timeout,
        };
        let monitor = deps.tasks.spawn_owned(run_monitor(context));
        Arc::new(Session {
            metadata: parts.request.metadata,
            workspace_settings: parts.request.workspace_settings,
            reachability,
            runner,
            mailbox,
            health,
            link,
            catalog,
            tasks: deps.tasks,
            close_timeout,
            _cancel_on_drop: cancel.clone().drop_guard(),
            cancel,
            _monitor: monitor,
        })
    }

    pub fn id(&self) -> Uuid {
        self.metadata.id
    }

    pub fn metadata(&self) -> &ConnectionMetadata {
        &self.metadata
    }

    /// What the current connection enforces, which is what the session
    /// was asked for.
    pub fn read_only(&self) -> bool {
        self.link
            .lease()
            .map_or(self.workspace_settings.read_only, |lease| lease.read_only())
    }

    pub fn workspace_settings(&self) -> WorkspaceSettings {
        self.workspace_settings
    }

    /// What the network must reach for this session, recomputed when a
    /// reconnect lands, because ssh may resolve its first hop anew.
    pub fn reachability(&self) -> ReachabilityTarget {
        self.reachability.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// The current connection's dialect, for UI that adapts to the
    /// server. `None` once the session shut down. SQL that runs is built
    /// inside an operation from its own lease instead, so it always
    /// matches the connection it runs on.
    pub fn current_dialect(&self) -> Option<Arc<dyn SqlDialect>> {
        self.link.lease().map(|lease| lease.dialect())
    }

    /// Ticks each time a reconnect replaces the connection.
    pub fn link_changes(&self) -> watch::Receiver<LinkGeneration> {
        self.link.subscribe()
    }

    pub fn health(&self) -> watch::Receiver<SessionHealth> {
        self.health.clone()
    }

    /// The catalog of the current connection, as read when it connected.
    pub fn catalog(&self) -> watch::Receiver<CatalogSnapshot> {
        self.catalog.clone()
    }

    pub fn signal(&self, signal: MonitorSignal) {
        self.mailbox.post(signal);
    }

    pub fn runner(&self) -> &OperationRunner {
        &self.runner
    }

    pub fn tasks(&self) -> &Tasks {
        &self.tasks
    }

    pub async fn run<T, F, Fut>(&self, kind: OperationKind, op: F) -> Result<T, OperationError>
    where
        F: Fn(ConnectionLease, CallOptions) -> Fut + Send + Sync,
        Fut: Future<Output = Result<T, OperationError>> + Send,
        T: Send,
    {
        self.runner.run_cancellable(kind, &CancellationToken::new(), op).await
    }

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
        self.runner.run_cancellable(kind, cancel, op).await
    }

    /// Open an editor tab's own connection from the current one.
    ///
    /// Opening is idempotent, so it runs as a replayable read: a tab
    /// opened just as the link was replaced gets a session on the new
    /// connection instead of an error. The session outlives any later
    /// replacement; the tab closes it.
    pub async fn open_editor_session(
        &self,
        options: EditorSessionOptions,
        cancel: &CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, OperationError> {
        self.runner
            .run_cancellable(OperationKind::Metadata, cancel, |lease, call| {
                let options = options.clone();
                async move {
                    lease
                        .open_editor_session(options, call.cancel().clone())
                        .await
                        .map_err(OperationError::from)
                }
            })
            .await
    }

    /// Stop every operation, take the connection and close it under the
    /// close deadline. A second call finds nothing to close.
    pub fn begin_shutdown(&self) -> TaskResult<CloseReport> {
        self.cancel.cancel();
        let retired = self.link.take();
        let close_timeout = self.close_timeout;
        self.tasks.spawn_task(async move {
            match retired {
                Some(retired) => retired.close(close_timeout).await,
                None => CloseReport::AlreadyClosed,
            }
        })
    }

    pub fn is_shut_down(&self) -> bool {
        self.link.is_taken()
    }
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("id", &self.metadata.id)
            .field("name", &self.metadata.name)
            .field("link", &self.link)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Weak;

    use tablepro_core::{DriverError, LivenessPolicy};
    use tablepro_test_support::{
        CallCounters, CloseBehaviour, ConnectionScript, FakeConnection, FakeEditorSession, FakeReply, Replies,
    };

    use super::*;
    use crate::fakes::{FakeConnector, FakeCredentialSource};
    use crate::operation::DefaultDeadlines;
    use crate::test_support::paused_tasks;

    fn deps(credentials: Arc<FakeCredentialSource>) -> SessionDeps {
        SessionDeps {
            connector: Arc::new(FakeConnector::new([])),
            credentials,
            deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
            tasks: paused_tasks(),
            prompter: None,
        }
    }

    fn start(script: ConnectionScript) -> (Arc<Session>, Arc<FakeConnection>) {
        let (pending, connection) = FakeConnector::pending_session(FakeConnector::request().unwrap(), script);
        (
            Session::start(pending, deps(Arc::new(FakeCredentialSource::new()))),
            connection,
        )
    }

    #[tokio::test(start_paused = true)]
    async fn begin_shutdown_closes_once_then_already_closed() {
        let (session, connection) = start(ConnectionScript::default());

        let first = session.begin_shutdown().await.unwrap();
        let second = session.begin_shutdown().await.unwrap();

        assert_eq!(first, CloseReport::Closed);
        assert_eq!(second, CloseReport::AlreadyClosed);
        assert_eq!(CallCounters::get(&connection.counters().close), 1);
        assert!(session.is_shut_down());
        let after = session.run(OperationKind::Page, |_, _| async { Ok(()) }).await;
        assert_eq!(after, Err(OperationError::Closed));
        assert!(session.current_dialect().is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn hanging_close_reports_abandoned_at_close_timeout() {
        let (session, _) = start(ConnectionScript {
            close: CloseBehaviour::Hang,
            ..ConnectionScript::default()
        });
        let started = tokio::time::Instant::now();

        let report = session.begin_shutdown().await.unwrap();

        assert_eq!(report, CloseReport::Abandoned);
        assert_eq!(started.elapsed(), LivenessPolicy::DESKTOP.close_timeout);
    }

    #[tokio::test(start_paused = true)]
    async fn dropping_last_arc_ends_monitor() {
        let credentials = Arc::new(FakeCredentialSource::new());
        let (pending, connection) =
            FakeConnector::pending_session(FakeConnector::request().unwrap(), ConnectionScript::default());
        let session = Session::start(pending, deps(credentials.clone()));
        let weak: Weak<Session> = Arc::downgrade(&session);
        let mut health = session.health();
        assert_eq!(Arc::strong_count(&credentials), 2, "the monitor holds no plan");

        drop(session);
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }

        assert!(weak.upgrade().is_none());
        assert_eq!(Arc::strong_count(&credentials), 1, "the monitor outlived its session");
        assert!(health.changed().await.is_err(), "the health sender is still alive");
        assert_eq!(
            CallCounters::get(&connection.counters().close),
            0,
            "dropping is not closing; that is begin_shutdown's job"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn session_start_without_entered_runtime() {
        let mut script = ConnectionScript::default();
        script.count_rows.always(FakeReply::ok(7));
        let (pending, _) = FakeConnector::pending_session(FakeConnector::request().unwrap(), script);
        let deps = deps(Arc::new(FakeCredentialSource::new()));

        // A plain thread has no runtime entered, like the GTK thread.
        let session = std::thread::spawn(move || Session::start(pending, deps))
            .join()
            .unwrap();

        let count = session
            .run(OperationKind::Count, |lease, options| async move {
                let statement = tablepro_core::statement::StatementBuilder::new().finish();
                Ok(lease.count_rows(&statement, options).await?)
            })
            .await
            .unwrap();
        assert_eq!(count, 7);
    }

    #[tokio::test(start_paused = true)]
    async fn read_only_and_dialect_follow_the_current_connection() {
        let (session, _) = start(ConnectionScript {
            read_only: true,
            ..ConnectionScript::default()
        });

        assert!(session.read_only());
        assert!(session.current_dialect().is_some());
        assert_eq!(session.reachability(), ReachabilityTarget::Local);
        assert_eq!(session.catalog().borrow().generation, LinkGeneration::FIRST);
        assert_eq!(session.metadata().name, "Fake");
    }

    #[tokio::test(start_paused = true)]
    async fn open_editor_session_leases_the_current_connection() {
        let editor: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(Replies::default()));
        let mut script = ConnectionScript::default();
        script.open_editor_session.once(FakeReply::ok(editor.clone()));
        script
            .open_editor_session
            .always(FakeReply::err(DriverError::server("one per test")));
        let (session, connection) = start(script);

        let opened = session
            .open_editor_session(EditorSessionOptions::default(), &CancellationToken::new())
            .await
            .unwrap();

        assert_eq!(opened.id(), editor.id());
        assert_eq!(CallCounters::get(&connection.counters().open_editor_session), 1);
    }
}
