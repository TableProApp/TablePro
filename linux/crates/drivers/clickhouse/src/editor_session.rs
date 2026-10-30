use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionOptions, EditorSessionState, LossPhase,
    ResultSink, RunEnd, RunOptions, RunSummary, TimeoutPhase, TransactionState, UserSql,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::editor_run::EditorRun;
use crate::endpoint::ClickHouseEndpoint;
use crate::lingering_query::LingeringQuery;
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
    /// Every request names its database, which overrides a `USE` the
    /// session ran, so the tab's database lives in the client.
    session: Arc<Mutex<clickhouse::Client>>,
    control: clickhouse::Client,
    statement_timeout: Option<Duration>,
    grace: Duration,
    status: Arc<SessionStatus>,
    shutdown: CancellationToken,
    lingering: Arc<LingeringQuery>,
}

impl ClickHouseEditorSession {
    fn client(&self) -> clickhouse::Client {
        self.session.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

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
            // Without the check, a run on a session the server let expire
            // quietly starts a new, empty one under the same id.
            session: Arc::new(Mutex::new(session.with_setting("session_check", "1"))),
            control: endpoint.control().clone(),
            statement_timeout: options.statement_timeout,
            grace: liveness.cancel_grace,
            status: Arc::new(SessionStatus::new()),
            shutdown: CancellationToken::new(),
            lingering: Arc::new(LingeringQuery::default()),
        }))
    }
}

#[async_trait]
impl EditorSession for ClickHouseEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn database(&self) -> Option<String> {
        self.client().database().map(str::to_owned)
    }

    /// The next request names `database`, once a request there answers.
    async fn use_database(&self, database: &str, options: CallOptions) -> Result<(), DriverError> {
        let moved = self.client().with_database(database);
        let asking = drain(moved.query_raw("SELECT 1"));
        let answered = tokio::select! {
            biased;
            () = options.cancel().cancelled() => return Err(DriverError::Cancelled),
            () = until(options.deadline()) => return Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false,
            }),
            answered = asking => answered,
        };
        answered?;
        *self.session.lock().unwrap_or_else(PoisonError::into_inner) = moved;
        Ok(())
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
        let used =
            tablepro_core::sql_syntax::used_database(sql.as_str(), tablepro_core::sql_syntax::SqlGrammar::ClickHouse);
        let run = EditorRun {
            session: self.client(),
            control: self.control.clone(),
            statement_timeout: self.statement_timeout,
            grace: self.grace,
            shutdown: self.shutdown.clone(),
            lingering: self.lingering.clone(),
        };
        let (status, client) = (self.status.clone(), self.session.clone());
        let running = tokio::spawn(async move {
            let outcome = run.run(sql, options, sink).await;
            // The server took the `USE`; the requests after it name that
            // database, as the session would have.
            if let (Ok(summary), Some(database)) = (&outcome, used)
                && summary.end == RunEnd::Completed
            {
                let mut client = client.lock().unwrap_or_else(PoisonError::into_inner);
                *client = client.clone().with_database(database);
            }
            match &outcome {
                // The server still held the session for a stopped query:
                // the session itself is fine.
                Ok(_) | Err(DriverError::EditorSessionBusy) => status.finish(),
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

async fn until(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use tablepro_core::{LivenessPolicy, ResultEvent, RunEnd, SinkFlow};
    use tablepro_test_fixtures::ClickHouseFixture;
    use tablepro_test_support::conformance::test_liveness;

    use super::*;

    struct Discard;

    #[async_trait]
    impl ResultSink for Discard {
        async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
            SinkFlow::Continue
        }
    }

    async fn run(session: &ClickHouseEditorSession, sql: &str) -> Result<RunSummary, DriverError> {
        session
            .run(
                UserSql::new(sql),
                RunOptions::new(CancellationToken::new()),
                Box::new(Discard),
            )
            .await
    }

    struct Collect(Arc<Mutex<Vec<Vec<tablepro_core::Value>>>>);

    #[async_trait]
    impl ResultSink for Collect {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            if let ResultEvent::Rows(rows) = event {
                self.0.lock().unwrap_or_else(PoisonError::into_inner).extend(rows);
            }
            SinkFlow::Continue
        }
    }

    async fn current_database(session: &ClickHouseEditorSession) -> Vec<Vec<tablepro_core::Value>> {
        let rows = Arc::new(Mutex::new(Vec::new()));
        session
            .run(
                UserSql::new("SELECT currentDatabase()"),
                RunOptions::new(CancellationToken::new()),
                Box::new(Collect(rows.clone())),
            )
            .await
            .expect("a run");
        let rows = rows.lock().unwrap_or_else(PoisonError::into_inner).clone();
        rows
    }

    /// Every request names its database, so a `USE` lasts only because
    /// the session's next requests name the database it chose.
    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_session_runs_in_the_database_it_moved_to() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let endpoint = ClickHouseEndpoint::for_fixture(&fixture, test_liveness());
        let session =
            ClickHouseEditorSession::open(&endpoint, EditorSessionOptions::default(), CancellationToken::new())
                .await
                .expect("an editor session");
        let text = |name: &str| vec![vec![tablepro_core::Value::Text(name.to_owned())]];

        session
            .use_database("system", CallOptions::new(None, CancellationToken::new()))
            .await
            .expect("a move to system");
        assert_eq!(current_database(&session).await, text("system"));
        assert_eq!(session.database().as_deref(), Some("system"));

        let used = run(&session, "USE default").await;
        assert_eq!(used.map(|summary| summary.end), Ok(RunEnd::Completed));
        assert_eq!(current_database(&session).await, text("default"));
        assert_eq!(session.database().as_deref(), Some("default"));

        let refused = session
            .use_database("no_such_database", CallOptions::new(None, CancellationToken::new()))
            .await;
        assert!(refused.is_err(), "{refused:?}");
        assert_eq!(session.database().as_deref(), Some("default"), "a refused move moved");
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_session_the_server_let_expire_is_lost_not_replaced() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let endpoint =
            ClickHouseEndpoint::for_fixture(&fixture, test_liveness()).with_session_timeout(Duration::from_secs(1));
        let session =
            ClickHouseEditorSession::open(&endpoint, EditorSessionOptions::default(), CancellationToken::new())
                .await
                .expect("an editor session");

        let created = run(&session, "CREATE TEMPORARY TABLE scratch (x UInt8)").await;
        assert_eq!(created.map(|summary| summary.end), Ok(RunEnd::Completed));
        tokio::time::sleep(Duration::from_secs(4)).await;
        let outcome = run(&session, "SELECT count() FROM scratch").await;

        assert_eq!(
            outcome.map(|summary| summary.end),
            Err(DriverError::ConnectionLost {
                during: LossPhase::Idle
            })
        );
        assert_eq!(session.state(), EditorSessionState::Lost);
    }

    /// The server notices a KILL inside `sleep` only once a second, so
    /// with a shorter grace the stopped run gives up its response while
    /// the server still holds the session, and a run sent at once would
    /// be refused with 373. The next run has a deadline, which bounds its
    /// wait; without one the grace would, and it is shorter than the
    /// server takes here.
    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_run_right_after_a_stop_waits_for_the_stopped_query() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let liveness = LivenessPolicy {
            cancel_grace: Duration::from_millis(300),
            ..test_liveness()
        };
        let endpoint = ClickHouseEndpoint::for_fixture(&fixture, liveness);
        let session =
            ClickHouseEditorSession::open(&endpoint, EditorSessionOptions::default(), CancellationToken::new())
                .await
                .expect("an editor session");
        let cancel = CancellationToken::new();
        let stopping = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            stopping.cancel();
        });

        let stopped = session
            .run(
                UserSql::new("SELECT sleep(3)"),
                RunOptions::new(cancel),
                Box::new(Discard),
            )
            .await;
        let next = session
            .run(
                UserSql::new("SELECT 1"),
                RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_secs(10))),
                Box::new(Discard),
            )
            .await;

        assert_eq!(stopped.map(|summary| summary.end), Ok(RunEnd::Cancelled));
        assert_eq!(next.map(|summary| summary.end), Ok(RunEnd::Completed));
        assert_eq!(session.state(), EditorSessionState::Ready);
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_stop_the_server_answered_leaves_nothing_for_the_next_run_to_wait_for() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let liveness = LivenessPolicy {
            cancel_grace: Duration::from_secs(10),
            ..test_liveness()
        };
        let endpoint = ClickHouseEndpoint::for_fixture(&fixture, liveness);
        let session =
            ClickHouseEditorSession::open(&endpoint, EditorSessionOptions::default(), CancellationToken::new())
                .await
                .expect("an editor session");
        let cancel = CancellationToken::new();
        let stopping = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            stopping.cancel();
        });

        let stopped = session
            .run(
                UserSql::new("SELECT sleep(3)"),
                RunOptions::new(cancel),
                Box::new(Discard),
            )
            .await;

        assert_eq!(stopped.map(|summary| summary.end), Ok(RunEnd::Cancelled));
        assert_eq!(session.lingering.take(), None);
    }
}
