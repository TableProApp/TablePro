use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use redis::Value as Reply;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState,
    EditorSessionStatus, LossPhase, ResultSink, RunOptions, RunSummary, TimeoutPhase, TransactionState,
    UnsupportedFeature, UserSql, deadline_elapsed,
};
use tokio_util::sync::CancellationToken;

use crate::editor_run::EditorRun;
use crate::endpoint::RedisEndpoint;
use crate::key_scan::unexpected;
use crate::link::{Link, command};
use crate::session_database::SessionDatabase;

/// One editor tab's own link to the server.
///
/// What the tab builds up lives on this link and nowhere else: the
/// database `SELECT` chose, a `MULTI` with commands queued, a `WATCH`.
/// A link that is lost is never opened again behind the tab's back.
pub(crate) struct RedisEditorSession {
    id: EditorSessionId,
    endpoint: Arc<RedisEndpoint>,
    link: Arc<Mutex<Option<Link>>>,
    status: Arc<EditorSessionStatus>,
    transaction: Arc<Mutex<TransactionState>>,
    database: Arc<Mutex<SessionDatabase>>,
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
        let database = SessionDatabase::new(endpoint.database());
        Ok(Arc::new(Self {
            id: EditorSessionId::new(),
            endpoint,
            link: Arc::new(Mutex::new(Some(link))),
            status: Arc::new(EditorSessionStatus::new()),
            transaction: Arc::new(Mutex::new(TransactionState::Idle)),
            database: Arc::new(Mutex::new(database)),
            read_only,
            statement_timeout: options.statement_timeout,
            shutdown: CancellationToken::new(),
        }))
    }

    fn take_link(&self) -> Option<Link> {
        self.link.lock().unwrap_or_else(PoisonError::into_inner).take()
    }

    fn current_database(&self) -> u32 {
        self.database.lock().unwrap_or_else(PoisonError::into_inner).current()
    }

    async fn select(&self, index: u32, options: &CallOptions) -> Result<(), DriverError> {
        let transaction = *self.transaction.lock().unwrap_or_else(PoisonError::into_inner);
        // Inside MULTI the server queues a SELECT until EXEC; the apps never move a tab that holds one.
        if matches!(transaction, TransactionState::InTransaction | TransactionState::Failed) {
            return Err(DriverError::Unsupported {
                feature: UnsupportedFeature::DatabaseSwitching,
            });
        }
        // A read-only ACL user is refused SELECT even of the database it is on.
        if self.current_database() == index {
            return Ok(());
        }
        let link = self.link.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let Some(link) = link else {
            self.status.lose();
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let select = command(&["SELECT".to_owned(), index.to_string()]);
        let sent = tokio::select! {
            biased;
            () = options.cancel().cancelled() => None,
            () = self.shutdown.cancelled() => None,
            () = deadline_elapsed(options.deadline()) => None,
            sent = link.send(&select) => Some(sent),
        };
        match sent {
            Some(Ok(Reply::Okay)) => {
                self.database
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .moved(index);
                Ok(())
            }
            Some(Ok(other)) => Err(unexpected(&other)),
            Some(Err(error)) => {
                self.take_link();
                self.status.lose();
                Err(self.endpoint.explain(error).await)
            }
            // The reply is still owed, so the link is in no database anything knows.
            None => {
                self.take_link();
                self.status.lose();
                Err(match options.cancel().is_cancelled() || self.shutdown.is_cancelled() {
                    true => DriverError::Cancelled,
                    false => DriverError::Timeout {
                        phase: TimeoutPhase::Statement,
                        server_cancelled: false,
                    },
                })
            }
        }
    }
}

// A switch dropped mid-SELECT leaves the link in a database nothing knows, so the session ends.
struct Switch<'a> {
    session: &'a RedisEditorSession,
    settled: bool,
}

impl Drop for Switch<'_> {
    fn drop(&mut self) {
        if !self.settled {
            self.session.take_link();
            self.session.status.lose();
        }
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
            database: self.database.clone(),
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

    fn database(&self) -> Option<String> {
        Some(self.current_database().to_string())
    }

    async fn use_database(&self, database: &str, options: CallOptions) -> Result<(), DriverError> {
        let index = tablepro_core::keyspace::database_number(Some(database))?;
        self.status.begin()?;
        let mut switch = Switch {
            session: self,
            settled: false,
        };
        let moved = self.select(index, &options).await;
        switch.settled = true;
        self.status.finish();
        moved
    }

    /// A run still going is stopped, and dropping the link closes it; a
    /// `MULTI` left open is discarded with it.
    async fn close(&self) {
        self.shutdown.cancel();
        self.status.lose();
        self.take_link();
    }
}
