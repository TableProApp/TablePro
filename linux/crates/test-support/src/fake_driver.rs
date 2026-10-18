use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, ConnectOptions, Connection, DatabaseDriver, DriverCapabilities, DriverError,
    EndpointKind, EstimateQuality, ReadOnlyEnforcement, ScriptExecution, ServerNameOverride, TimeoutPhase,
    TlsCapabilities, TlsMode, WriteAtomicity,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::fake_reply::Stop;
use crate::{ConnectionScript, FakeConnection, FakeReply, Replies, lock};

/// A `DatabaseDriver` whose connects are scripted.
///
/// It keeps every connection it made and every request it was given,
/// so a test can check what the code under test asked for and what it
/// did with the result, including a late connect it should have closed.
#[derive(Debug)]
pub struct FakeDriver {
    capabilities: &'static DriverCapabilities,
    connects: Mutex<Replies<FakeReply<ConnectionScript>>>,
    connections: Mutex<Vec<Arc<FakeConnection>>>,
    requests: Mutex<Vec<ConnectOptions>>,
}

impl FakeDriver {
    pub const NETWORK_CAPABILITIES: DriverCapabilities = DriverCapabilities {
        endpoint: EndpointKind::Network { default_port: 1 },
        auth_modes: &[AuthMode::Password],
        tls: Some(TlsCapabilities {
            modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
            ca_file: true,
            client_identity: true,
            server_name_override: ServerNameOverride::AnyRoute,
        }),
        read_only: ReadOnlyEnforcement::EngineEnforced,
        dml_writes: WriteAtomicity::Transactional,
        ddl_writes: WriteAtomicity::Transactional,
        script_execution: ScriptExecution::SingleStatement,
        commit_resolution: CommitResolutionSupport::Unavailable,
        row_count_estimate: EstimateQuality::Statistics,
        object_kinds: &[ObjectKind::Table, ObjectKind::View],
        database_required: false,
    };

    pub const FILE_CAPABILITIES: DriverCapabilities = DriverCapabilities {
        endpoint: EndpointKind::File,
        auth_modes: &[],
        tls: None,
        ..Self::NETWORK_CAPABILITIES
    };

    pub fn new(
        capabilities: &'static DriverCapabilities,
        connects: impl IntoIterator<Item = FakeReply<ConnectionScript>>,
    ) -> Self {
        let mut replies = Replies::default();
        for connect in connects {
            replies.once(connect);
        }
        Self::with_replies(capabilities, replies)
    }

    /// A driver that answers every connect with a fresh connection
    /// scripted the same way.
    pub fn connecting(capabilities: &'static DriverCapabilities, script: ConnectionScript) -> Self {
        let mut replies = Replies::default();
        replies.always(FakeReply::ok(script));
        Self::with_replies(capabilities, replies)
    }

    fn with_replies(capabilities: &'static DriverCapabilities, connects: Replies<FakeReply<ConnectionScript>>) -> Self {
        Self {
            capabilities,
            connects: Mutex::new(connects),
            connections: Mutex::new(Vec::new()),
            requests: Mutex::new(Vec::new()),
        }
    }

    pub fn connections(&self) -> Vec<Arc<FakeConnection>> {
        lock(&self.connections).clone()
    }

    pub fn requests(&self) -> Vec<ConnectOptions> {
        lock(&self.requests).clone()
    }
}

#[async_trait]
impl DatabaseDriver for FakeDriver {
    fn id(&self) -> &'static str {
        "fake"
    }

    fn display_name(&self) -> &'static str {
        "Fake"
    }

    fn capabilities(&self) -> &'static DriverCapabilities {
        self.capabilities
    }

    async fn connect(
        &self,
        options: ConnectOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn Connection>, DriverError> {
        let login = options.liveness.connect_timeout + options.liveness.login_timeout;
        lock(&self.requests).push(options);
        let reply = lock(&self.connects).next(None);
        let Some(reply) = reply else {
            return Err(DriverError::Protocol(
                "FakeDriver has no scripted connect result".to_owned(),
            ));
        };
        let never_closed = CancellationToken::new();
        let stop = Stop {
            deadline: Some(Instant::now() + login),
            cancel: &cancel,
            closed: &never_closed,
            phase: TimeoutPhase::Login,
        };
        let script = reply.resolve(&stop).await?;
        let connection = Arc::new(FakeConnection::new(script));
        lock(&self.connections).push(connection.clone());
        Ok(connection)
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::Duration;

    use tablepro_core::{
        CallOptions, ConnectEnvironment, ConnectTarget, FileEndpoint, LivenessPolicy, WorkspaceSettings,
    };

    use super::*;
    use crate::CallCounters;

    fn options() -> ConnectOptions {
        ConnectOptions {
            target: ConnectTarget::File(FileEndpoint::open_existing(PathBuf::from("/fake.db")).unwrap()),
            workspace_settings: WorkspaceSettings::workspace(false),
            liveness: LivenessPolicy::DESKTOP,
            environment: ConnectEnvironment::new("test"),
        }
    }

    #[tokio::test]
    async fn fake_driver_returns_scripted_connect_error() {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::ok(()));
        let driver = FakeDriver::new(
            &FakeDriver::NETWORK_CAPABILITIES,
            [FakeReply::err(DriverError::auth(None)), FakeReply::ok(script)],
        );

        assert!(matches!(
            driver.connect(options(), CancellationToken::new()).await,
            Err(DriverError::Auth { .. })
        ));
        let connection = driver.connect(options(), CancellationToken::new()).await.unwrap();
        connection
            .probe(CallOptions::new(None, CancellationToken::new()))
            .await
            .unwrap();
        assert!(matches!(
            driver.connect(options(), CancellationToken::new()).await,
            Err(DriverError::Protocol(_))
        ));

        let connections = driver.connections();
        assert_eq!(connections.len(), 1);
        assert_eq!(CallCounters::get(&connections[0].counters().probe), 1);
        assert_eq!(driver.requests().len(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn a_connect_that_never_answers_ends_with_its_cancel_or_login_deadline() {
        let driver = FakeDriver::new(
            &FakeDriver::FILE_CAPABILITIES,
            [FakeReply::UntilStopped, FakeReply::UntilStopped],
        );
        let cancel = CancellationToken::new();
        let cancelled = {
            let cancel = cancel.clone();
            async move {
                tokio::time::sleep(Duration::from_millis(100)).await;
                cancel.cancel();
            }
        };

        let (outcome, ()) = tokio::join!(driver.connect(options(), cancel), cancelled);
        assert!(matches!(outcome, Err(DriverError::Cancelled)));

        let started = Instant::now();
        let outcome = driver.connect(options(), CancellationToken::new()).await;
        assert!(matches!(
            outcome,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Login,
                ..
            })
        ));
        assert_eq!(started.elapsed(), Duration::from_secs(25));
        assert!(driver.capabilities().is_file_based());
    }
}
