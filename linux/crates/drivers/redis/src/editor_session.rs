use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LossPhase,
    ResultSink, RunOptions, RunSummary, TransactionState, UserSql,
};
use tokio_util::sync::CancellationToken;

use crate::editor_run::EditorRun;
use crate::endpoint::RedisEndpoint;
use crate::link::Link;
use crate::session_status::SessionStatus;

/// One editor tab's own link to the server.
///
/// What the tab builds up lives on this link and nowhere else: the
/// database `SELECT` chose, a `MULTI` with commands queued, a `WATCH`.
/// A link that is lost is never opened again behind the tab's back.
pub(crate) struct RedisEditorSession {
    id: EditorSessionId,
    endpoint: Arc<RedisEndpoint>,
    link: Arc<Mutex<Option<Link>>>,
    status: Arc<SessionStatus>,
    transaction: Arc<Mutex<TransactionState>>,
    read_only: bool,
    statement_timeout: Option<Duration>,
    shutdown: CancellationToken,
}

impl RedisEditorSession {
    pub(crate) async fn open(
        endpoint: Arc<RedisEndpoint>,
        read_only: bool,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let link = tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = endpoint.open() => opened,
        }?;
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            endpoint,
            link: Arc::new(Mutex::new(Some(link))),
            status: Arc::new(SessionStatus::new()),
            transaction: Arc::new(Mutex::new(TransactionState::Idle)),
            read_only,
            statement_timeout: options.statement_timeout,
            shutdown: CancellationToken::new(),
        }))
    }

    fn take_link(&self) -> Option<Link> {
        self.link.lock().unwrap_or_else(PoisonError::into_inner).take()
    }
}

#[async_trait]
impl EditorSession for RedisEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        self.status.state()
    }

    /// The run goes on a task of its own, so a dropped caller stops the
    /// command instead of leaving it blocked on the server: the task sees
    /// the cancel, unblocks the command and settles the session.
    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        self.status.begin()?;
        let link = self.link.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let Some(link) = link else {
            self.status.lose();
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let guard = options.cancel.clone().drop_guard();
        let run = EditorRun {
            link,
            endpoint: self.endpoint.clone(),
            read_only: self.read_only,
            statement_timeout: self.statement_timeout,
            shutdown: self.shutdown.clone(),
            transaction: self.transaction.clone(),
        };
        let status = self.status.clone();
        let slot = self.link.clone();
        let running = tokio::spawn(async move {
            let (outcome, kept) = run.run(sql, options, sink).await;
            if kept && outcome.is_ok() {
                status.finish();
            } else {
                slot.lock().unwrap_or_else(PoisonError::into_inner).take();
                status.lose();
            }
            outcome
        });
        let outcome = running.await.unwrap_or_else(|_| {
            self.take_link();
            self.status.lose();
            Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            })
        });
        drop(guard.disarm());
        outcome
    }

    /// What the commands sent so far said: Redis cannot be asked whether
    /// a `MULTI` is open.
    async fn transaction_state(&self, _options: CallOptions) -> Result<TransactionState, DriverError> {
        match self.status.state() {
            EditorSessionState::Lost => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
            EditorSessionState::Ready | EditorSessionState::Running => {
                Ok(*self.transaction.lock().unwrap_or_else(PoisonError::into_inner))
            }
        }
    }

    /// A run still going is stopped, and dropping the link closes it; a
    /// `MULTI` left open is discarded with it.
    async fn close(&self) {
        self.shutdown.cancel();
        self.status.lose();
        self.take_link();
    }
}
