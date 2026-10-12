use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LossPhase,
    ResultSink, RunOptions, RunSummary, TransactionState, UserSql,
};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use super::actor::{Command, session_actor};
use super::session_core::SessionCore;
use super::session_status::SessionStatus;
use crate::physical::PgEndpoint;

/// One editor tab's own connection, run by an actor task that owns it.
///
/// No session-level SET is ever sent: behind a transaction pooler the
/// server connection is shared, and a session setting would follow it
/// to other clients. Read-only is applied per transaction and deadlines
/// are enforced with cancel requests.
pub(crate) struct PgEditorSession {
    id: EditorSessionId,
    commands: mpsc::Sender<Command>,
    status: Arc<SessionStatus>,
    shutdown: CancellationToken,
    actor: Mutex<Option<JoinHandle<()>>>,
    close_timeout: Duration,
}

impl PgEditorSession {
    pub(crate) async fn open(
        endpoint: Arc<PgEndpoint>,
        read_only: bool,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let (client, connection) = endpoint.open(&cancel).await?;
        let close_timeout = endpoint.liveness().close_timeout;
        let (notice_sender, notices) = mpsc::unbounded_channel();
        // PostgreSQL has defaulted to on since 9.1; the server reports
        // its own value at startup and on every change.
        let conforming = Arc::new(AtomicBool::new(true));
        let core = SessionCore::new(
            client,
            endpoint,
            read_only,
            options.statement_timeout,
            notices,
            conforming,
        );
        let (commands, receiver) = mpsc::channel(1);
        let status = Arc::new(SessionStatus::new());
        let shutdown = CancellationToken::new();
        // The tab owns the session, and it outlives the workspace
        // connection, so the actor is not on the workspace's tracker.
        let actor = tokio::spawn(session_actor(
            core,
            connection,
            notice_sender,
            receiver,
            status.clone(),
            shutdown.clone(),
            close_timeout,
        ));
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            commands,
            status,
            shutdown,
            actor: Mutex::new(Some(actor)),
            close_timeout,
        }))
    }
}

#[async_trait]
impl EditorSession for PgEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        self.status.state()
    }

    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        self.status.begin()?;
        // Dropping the caller is itself a cancel: the statement is
        // already running on the server and has to be stopped.
        let guard = options.cancel.clone().drop_guard();
        let (reply, answer) = oneshot::channel();
        let command = Command::Run {
            sql,
            options,
            sink,
            reply,
        };
        if self.commands.send(command).await.is_err() {
            self.status.lose();
            return Err(lost());
        }
        let outcome = answer.await.unwrap_or_else(|_| Err(lost()));
        drop(guard.disarm());
        outcome
    }

    async fn transaction_state(&self, _options: CallOptions) -> Result<TransactionState, DriverError> {
        match self.status.state() {
            EditorSessionState::Lost => Err(lost()),
            EditorSessionState::Ready | EditorSessionState::Running => Ok(self.status.transaction()),
        }
    }

    async fn close(&self) {
        self.shutdown.cancel();
        let _ = self.commands.try_send(Command::Close);
        let actor = self.actor.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(mut actor) = actor
            && tokio::time::timeout(self.close_timeout, &mut actor).await.is_err()
        {
            actor.abort();
        }
        self.status.lose();
    }
}

fn lost() -> DriverError {
    DriverError::ConnectionLost {
        during: LossPhase::Idle,
    }
}
