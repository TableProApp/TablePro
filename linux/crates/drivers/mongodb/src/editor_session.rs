use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use mongodb::Client;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LossPhase,
    ResultSink, RunOptions, RunSummary, TransactionState, UserSql,
};
use tokio_util::sync::CancellationToken;

use crate::editor_run::EditorRun;
use crate::endpoint::{ClientUse, MongoEndpoint};
use crate::session_status::SessionStatus;

/// One editor tab's own client of the server.
///
/// What the tab builds up lives here and nowhere else: the database
/// `use` chose. A client that is lost is never opened again behind the
/// tab's back.
pub(crate) struct MongoEditorSession {
    id: EditorSessionId,
    endpoint: Arc<MongoEndpoint>,
    client: Arc<Mutex<Option<Client>>>,
    database: Arc<Mutex<String>>,
    status: Arc<SessionStatus>,
    read_only: bool,
    statement_timeout: Option<Duration>,
    shutdown: CancellationToken,
}

impl MongoEditorSession {
    pub(crate) async fn open(
        endpoint: Arc<MongoEndpoint>,
        database: String,
        read_only: bool,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let client = tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = endpoint.open(ClientUse::Own) => opened,
        }?;
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            endpoint,
            client: Arc::new(Mutex::new(Some(client))),
            database: Arc::new(Mutex::new(database)),
            status: Arc::new(SessionStatus::new()),
            read_only,
            statement_timeout: options.statement_timeout,
            shutdown: CancellationToken::new(),
        }))
    }

    fn take_client(&self) -> Option<Client> {
        self.client.lock().unwrap_or_else(PoisonError::into_inner).take()
    }
}

#[async_trait]
impl EditorSession for MongoEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        self.status.state()
    }

    /// The run goes on a task of its own, so a dropped caller stops the
    /// statement instead of leaving it running on the server: the task
    /// sees the cancel, ends the statement's session and settles.
    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        self.status.begin()?;
        let client = self.client.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let Some(client) = client else {
            self.status.lose();
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let guard = options.cancel.clone().drop_guard();
        let run = EditorRun {
            client,
            endpoint: self.endpoint.clone(),
            database: self.database.clone(),
            read_only: self.read_only,
            statement_timeout: self.statement_timeout,
            shutdown: self.shutdown.clone(),
        };
        let (status, slot) = (self.status.clone(), self.client.clone());
        let running = tokio::spawn(async move {
            let outcome = run.run(sql, options, sink).await;
            match &outcome {
                Ok(_) => status.finish(),
                Err(_) => {
                    if let Some(client) = slot.lock().unwrap_or_else(PoisonError::into_inner).take() {
                        tokio::spawn(async move { client.shutdown().immediate(true).await });
                    }
                    status.lose();
                }
            }
            outcome
        });
        let outcome = running.await.unwrap_or_else(|_| {
            self.take_client();
            self.status.lose();
            Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            })
        });
        drop(guard.disarm());
        outcome
    }

    /// The editor runs no transaction: each statement stands alone.
    async fn transaction_state(&self, _options: CallOptions) -> Result<TransactionState, DriverError> {
        match self.status.state() {
            EditorSessionState::Lost => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
            EditorSessionState::Ready | EditorSessionState::Running => Ok(TransactionState::Idle),
        }
    }

    /// A run still going is stopped, and the client closes within the
    /// close timeout.
    async fn close(&self) {
        self.shutdown.cancel();
        self.status.lose();
        if let Some(client) = self.take_client() {
            let bound = self.endpoint.liveness().close_timeout;
            let _ = tokio::time::timeout(bound, client.shutdown().immediate(true)).await;
        }
    }
}
