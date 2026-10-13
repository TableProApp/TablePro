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
    session: clickhouse::Client,
    control: clickhouse::Client,
    statement_timeout: Option<Duration>,
    grace: Duration,
    status: Arc<SessionStatus>,
    shutdown: CancellationToken,
    lingering: Arc<LingeringQuery>,
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
            // Without the check, a run on a session the server let expire
            // quietly starts a new, empty one under the same id.
            session: session.with_setting("session_check", "1"),
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
            lingering: self.lingering.clone(),
        };
        let status = self.status.clone();
        let running = tokio::spawn(async move {
            let outcome = run.run(sql, options, sink).await;
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

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use secrecy::SecretString;
    use tablepro_core::{
        ConnectEnvironment, Credentials, LivenessPolicy, NetworkEndpoint, NetworkTarget, ResultEvent, RunEnd, SinkFlow,
        TlsConfig,
    };
    use tablepro_net::DirectTcpTransport;
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

    fn endpoint(fixture: &ClickHouseFixture, liveness: LivenessPolicy) -> ClickHouseEndpoint {
        let address = NetworkEndpoint::new(fixture.host(), fixture.http_port()).expect("an endpoint");
        let credentials = fixture.password_credentials();
        let target = NetworkTarget {
            transport: Arc::new(DirectTcpTransport::new(address, &liveness)),
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: Some("tablepro".to_owned()),
            tls: TlsConfig::disabled(),
        };
        ClickHouseEndpoint::new(&target, liveness, &ConnectEnvironment::new("test"), false).expect("an endpoint")
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_session_the_server_let_expire_is_lost_not_replaced() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let endpoint = endpoint(&fixture, test_liveness()).with_session_timeout(Duration::from_secs(1));
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
    /// be refused with 373.
    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_run_right_after_a_stop_waits_for_the_stopped_query() {
        let fixture = ClickHouseFixture::start().await.expect("a ClickHouse container");
        let liveness = LivenessPolicy {
            cancel_grace: Duration::from_millis(300),
            ..test_liveness()
        };
        let endpoint = endpoint(&fixture, liveness);
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
        let next = run(&session, "SELECT 1").await;

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
        let endpoint = endpoint(&fixture, liveness);
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
