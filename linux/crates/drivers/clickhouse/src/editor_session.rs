use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LossPhase,
    ResultSink, RunOptions, RunSummary, TimeoutPhase, TransactionState, UserSql,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::editor_run::EditorRun;
use crate::endpoint::ClickHouseEndpoint;
use crate::result_reader::drain;
use crate::session_status::SessionStatus;

/// One editor tab's ClickHouse HTTP session.
///
/// The server keeps the session's settings and temporary tables under
/// its id for as long as it is used within the session timeout, so the
/// state a user builds up survives between runs even though each run is
/// a request of its own. One statement goes per run: the HTTP interface
/// takes no scripts.
pub(crate) struct ClickHouseEditorSession {
    id: EditorSessionId,
    session: clickhouse::Client,
    control: clickhouse::Client,
    statement_timeout: Option<Duration>,
    grace: Duration,
    status: Arc<SessionStatus>,
    shutdown: CancellationToken,
}

impl ClickHouseEditorSession {
    /// Open the session with one trivial question, so a session the
    /// server will not create fails here rather than on the first run.
    pub(crate) async fn open(
        endpoint: &ClickHouseEndpoint,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let session = endpoint.session(Uuid::new_v4());
        let liveness = endpoint.liveness();
        let bound = liveness.connect_timeout + liveness.login_timeout;
        let opening = tokio::time::timeout(bound, drain(session.query_raw("SELECT 1")));
        let opened = tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => opened.unwrap_or(Err(DriverError::Timeout {
                phase: TimeoutPhase::Login,
                server_cancelled: false,
            })).map(|_| ()),
        };
        if let Err(error) = opened {
            return Err(endpoint.explain(error).await);
        }
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            session,
            control: endpoint.control().clone(),
            statement_timeout: options.statement_timeout,
            grace: liveness.cancel_grace,
            status: Arc::new(SessionStatus::new()),
            shutdown: CancellationToken::new(),
        }))
    }
}

#[async_trait]
impl EditorSession for ClickHouseEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        self.status.state()
    }

    /// The run goes on a task of its own, so dropping the caller cancels
    /// it rather than leaving the statement running for nobody: the task
    /// sees the cancel, sends the KILL and settles the session.
    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        self.status.begin()?;
        let guard = options.cancel.clone().drop_guard();
        let run = EditorRun {
            session: self.session.clone(),
            control: self.control.clone(),
            statement_timeout: self.statement_timeout,
            grace: self.grace,
            shutdown: self.shutdown.clone(),
        };
        let status = self.status.clone();
        let running = tokio::spawn(async move {
            let outcome = run.run(sql, options, sink).await;
            match &outcome {
                Ok(_) => status.finish(),
                Err(_) => status.lose(),
            }
            outcome
        });
        let outcome = running.await.unwrap_or_else(|_| {
            self.status.lose();
            Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            })
        });
        drop(guard.disarm());
        outcome
    }

    async fn transaction_state(&self, _options: CallOptions) -> Result<TransactionState, DriverError> {
        match self.status.state() {
            EditorSessionState::Lost => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
            EditorSessionState::Ready | EditorSessionState::Running => Ok(TransactionState::Idle),
        }
    }

    /// The server lets an idle session expire on its own; a run still
    /// going is stopped.
    async fn close(&self) {
        self.shutdown.cancel();
        self.status.lose();
    }
}
