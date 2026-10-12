use std::sync::Arc;
use std::time::Duration;

use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::meta::{ObjectInfo, ObjectScope, SchemaInfo};
use tablepro_core::{
    CallOptions, ConfigError, ConnectOptions, ConnectTarget, Connection, DriverError, NetworkTarget, TlsMode, Transport,
};
use tablepro_net::DirectTcpTransport;
use tablepro_ssh::SshSession;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use super::{ConnectError, ConnectRequest, ConnectServices, Connector, PendingSession, RequestTarget};
use crate::link::EstablishedConnection;
use crate::operation::{DeadlinePolicy, OperationKind};

/// The production connector: validate, build the transport, connect the
/// driver, read the first catalog.
///
/// Each stage gets the cancel token and runs to completion; cancelling
/// is checked between stages. A stage that finished after the cancel
/// closes what it built, because a driver blocked in a C call cannot be
/// interrupted and would otherwise leave its connection behind.
pub struct DriverConnector {
    pub services: ConnectServices,
    pub deadlines: Arc<dyn DeadlinePolicy>,
}

impl DriverConnector {
    pub fn new(services: ConnectServices, deadlines: Arc<dyn DeadlinePolicy>) -> Self {
        Self { services, deadlines }
    }
}

impl Connector for DriverConnector {
    fn establish(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<PendingSession, ConnectError>> {
        Box::pin(establish(
            self.services.clone(),
            self.deadlines.clone(),
            request,
            interaction,
            cancel,
        ))
    }
}

impl std::fmt::Debug for DriverConnector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DriverConnector")
            .field("services", &self.services)
            .finish_non_exhaustive()
    }
}

async fn establish(
    services: ConnectServices,
    deadlines: Arc<dyn DeadlinePolicy>,
    request: ConnectRequest,
    interaction: CredentialInteraction,
    cancel: CancellationToken,
) -> Result<PendingSession, ConnectError> {
    let liveness = services.liveness;
    validate(&request)?;
    if cancel.is_cancelled() {
        return Err(ConnectError::Cancelled);
    }

    let (target, ssh_session) = match &request.target {
        RequestTarget::File(endpoint) => (ConnectTarget::File(endpoint.clone()), None),
        RequestTarget::Network {
            endpoint,
            ssh,
            credentials,
            database,
            tls,
        } => {
            let (transport, ssh_session): (Arc<dyn Transport>, _) = match ssh {
                Some(config) => {
                    let session =
                        SshSession::connect(config, &services.ssh, &liveness, interaction, cancel.child_token())
                            .await
                            .map_err(|error| stage_error(&cancel, error.into()))?;
                    if cancel.is_cancelled() {
                        return Err(ConnectError::Cancelled);
                    }
                    let transport = session
                        .forward(endpoint.clone(), &liveness)
                        .await
                        .map_err(|error| stage_error(&cancel, error.into()))?;
                    (transport, Some(session))
                }
                None => (Arc::new(DirectTcpTransport::new(endpoint.clone(), &liveness)), None),
            };
            let target = NetworkTarget {
                transport,
                credentials: credentials.clone(),
                database: database.clone(),
                tls: tls.clone(),
            };
            (ConnectTarget::Network(target), ssh_session)
        }
    };
    if cancel.is_cancelled() {
        return Err(ConnectError::Cancelled);
    }

    let options = ConnectOptions {
        target,
        workspace_settings: request.workspace_settings,
        liveness,
        environment: services.environment.clone(),
    };
    let connection = request
        .driver
        .connect(options, cancel.clone())
        .await
        .map_err(|error| stage_error(&cancel, error))?;
    let established = EstablishedConnection {
        connection,
        ssh_session,
    };
    if cancel.is_cancelled() {
        close(&established, liveness.close_timeout).await;
        return Err(ConnectError::Cancelled);
    }

    let deadline = deadlines.deadline(OperationKind::Metadata);
    match first_catalog(&*established.connection, deadline, &cancel).await {
        Ok(_) if cancel.is_cancelled() => {
            close(&established, liveness.close_timeout).await;
            Err(ConnectError::Cancelled)
        }
        Ok((schemas, objects)) => Ok(PendingSession::new(
            request,
            established,
            schemas,
            objects,
            liveness.close_timeout,
        )),
        Err(error) => {
            close(&established, liveness.close_timeout).await;
            Err(stage_error(&cancel, error))
        }
    }
}

/// A request the driver cannot serve is refused before anything is
/// opened: a saved file can name an auth mode or TLS option the driver
/// never had, and sending it anyway fails as a confusing login error.
fn validate(request: &ConnectRequest) -> Result<(), ConnectError> {
    let capabilities = request.driver.capabilities();
    let refuse = |error: DriverError| Err(ConnectError::Driver(error));
    match &request.target {
        RequestTarget::File(_) if !capabilities.is_file_based() => refuse(DriverError::Unsupported {
            feature: "database files",
        }),
        RequestTarget::File(_) => Ok(()),
        RequestTarget::Network { .. } if capabilities.is_file_based() => refuse(DriverError::Unsupported {
            feature: "network connections",
        }),
        RequestTarget::Network {
            credentials,
            database,
            tls,
            ..
        } => {
            if !capabilities.supports(credentials.mode()) {
                return refuse(ConfigError::AuthModeUnsupported.into());
            }
            match (&capabilities.tls, request.target.transport_class()) {
                (Some(caps), Some(route)) => tls.validate(caps, route).map_err(DriverError::from)?,
                _ if tls.mode != TlsMode::Disable => return refuse(ConfigError::UnsupportedTlsMode.into()),
                _ => {}
            }
            let missing_database = database.as_deref().is_none_or(|name| name.trim().is_empty());
            if capabilities.database_required && missing_database {
                return refuse(ConfigError::DatabaseRequired.into());
            }
            Ok(())
        }
    }
}

async fn first_catalog(
    connection: &dyn Connection,
    deadline: Option<Duration>,
    cancel: &CancellationToken,
) -> Result<(Vec<SchemaInfo>, Vec<ObjectInfo>), DriverError> {
    let options = || CallOptions::new(deadline.map(|limit| Instant::now() + limit), cancel.child_token());
    let schemas = connection.list_schemas(options()).await?;
    let objects = connection.list_objects(&ObjectScope::DefaultSchema, options()).await?;
    Ok((schemas, objects))
}

fn stage_error(cancel: &CancellationToken, error: DriverError) -> ConnectError {
    if cancel.is_cancelled() {
        ConnectError::Cancelled
    } else {
        ConnectError::Driver(error)
    }
}

async fn close(established: &EstablishedConnection, close_timeout: Duration) {
    match tokio::time::timeout(close_timeout, established.connection.close()).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::debug!(%error, "closing a connection nobody adopted failed"),
        Err(_) => tracing::warn!("a connection nobody adopted did not close in time"),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use secrecy::SecretString;
    use tablepro_core::meta::ObjectKind;
    use tablepro_core::{
        ConnectEnvironment, Credentials, DriverCapabilities, FileEndpoint, LivenessPolicy, NetworkEndpoint, TlsConfig,
        TransportKind, WorkspaceSettings,
    };
    use tablepro_ssh::{SshRuntimeCell, SshServices};
    use tablepro_test_support::{ConnectionScript, FakeDriver, FakeReply};
    use uuid::Uuid;

    use super::*;
    use crate::connect::ConnectionMetadata;
    use crate::link::CloseReport;
    use crate::operation::DefaultDeadlines;

    const DATABASE_REQUIRED: DriverCapabilities = DriverCapabilities {
        database_required: true,
        ..FakeDriver::NETWORK_CAPABILITIES
    };

    fn connector() -> DriverConnector {
        let services = ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh: SshServices {
                runtime: Arc::new(SshRuntimeCell::new(PathBuf::from("/nonexistent"))),
                ssh_program: PathBuf::from("/nonexistent/ssh"),
                ssh_keygen_program: PathBuf::from("/nonexistent/ssh-keygen"),
                askpass_program: PathBuf::from("/nonexistent/tablepro-askpass"),
            },
            liveness: LivenessPolicy::DESKTOP,
        };
        DriverConnector::new(services, Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)))
    }

    fn cataloguing() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.list_schemas.always(FakeReply::ok(vec![SchemaInfo {
            name: "public".to_owned(),
            is_default: true,
            is_system: false,
        }]));
        script.list_objects.always(FakeReply::ok(vec![ObjectInfo {
            schema: Some("public".to_owned()),
            name: "orders".to_owned(),
            kind: ObjectKind::Table,
        }]));
        script
    }

    fn request(driver: Arc<FakeDriver>, target: RequestTarget) -> ConnectRequest {
        ConnectRequest {
            metadata: ConnectionMetadata {
                id: Uuid::new_v4(),
                name: "Fake".to_owned(),
                driver_id: "fake".to_owned(),
            },
            driver,
            target,
            workspace_settings: WorkspaceSettings::workspace(false),
        }
    }

    fn file() -> RequestTarget {
        RequestTarget::File(FileEndpoint::open_existing(PathBuf::from("/srv/app.db")).unwrap())
    }

    fn network(credentials: Credentials, tls: TlsConfig, database: Option<&str>) -> RequestTarget {
        RequestTarget::Network {
            endpoint: NetworkEndpoint::new("db.example.com", 5432).unwrap(),
            ssh: None,
            credentials,
            database: database.map(str::to_owned),
            tls,
        }
    }

    fn password() -> Credentials {
        Credentials::Password {
            username: "app".to_owned(),
            password: SecretString::from("s3cret"),
        }
    }

    async fn establish(request: ConnectRequest, cancel: CancellationToken) -> Result<PendingSession, ConnectError> {
        connector()
            .establish(request, CredentialInteraction::Unattended, cancel)
            .await
    }

    #[tokio::test(start_paused = true)]
    async fn establish_reads_the_schemas_and_the_default_schema_objects() {
        let driver = Arc::new(FakeDriver::connecting(&FakeDriver::FILE_CAPABILITIES, cataloguing()));

        let pending = establish(request(driver.clone(), file()), CancellationToken::new())
            .await
            .unwrap();

        assert_eq!(pending.schemas()[0].name, "public");
        assert_eq!(pending.objects()[0].name, "orders");
        assert_eq!(pending.metadata().name, "Fake");
        assert!(matches!(driver.requests()[0].target, ConnectTarget::File(_)));
    }

    #[tokio::test(start_paused = true)]
    async fn a_network_target_without_ssh_dials_direct_tcp() {
        let driver = Arc::new(FakeDriver::connecting(&FakeDriver::NETWORK_CAPABILITIES, cataloguing()));
        let target = network(password(), TlsConfig::verify_full(), Some("shop"));

        let pending = establish(request(driver.clone(), target), CancellationToken::new())
            .await
            .unwrap();

        let ConnectTarget::Network(sent) = &driver.requests()[0].target else {
            panic!("a network request reached the driver as a file");
        };
        assert_eq!(sent.transport.kind(), TransportKind::DirectTcp);
        assert_eq!(sent.transport.service_endpoint().host(), "db.example.com");
        assert_eq!(sent.database.as_deref(), Some("shop"));
        assert!(pending.established().ssh_session.is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn cancelled_establish_closes_late_connection() {
        let late = FakeReply::Late {
            after: Duration::from_secs(5),
            outcome: Ok(cataloguing()),
        };
        let driver = Arc::new(FakeDriver::new(&FakeDriver::FILE_CAPABILITIES, [late]));
        let cancel = CancellationToken::new();
        let cancelling = {
            let cancel = cancel.clone();
            async move {
                tokio::time::sleep(Duration::from_secs(1)).await;
                cancel.cancel();
            }
        };

        let (outcome, ()) = tokio::join!(establish(request(driver.clone(), file()), cancel), cancelling);

        assert_eq!(outcome.unwrap_err(), ConnectError::Cancelled);
        let connections = driver.connections();
        assert_eq!(connections.len(), 1, "the late connect never finished");
        assert!(connections[0].is_closed(), "the late connection was left open");
    }

    #[tokio::test(start_paused = true)]
    async fn kerberos_refused_for_driver_without_mode() {
        let driver = Arc::new(FakeDriver::connecting(&FakeDriver::NETWORK_CAPABILITIES, cataloguing()));
        let target = network(Credentials::Integrated, TlsConfig::verify_full(), None);

        let refused = establish(request(driver.clone(), target), CancellationToken::new()).await;

        assert_eq!(
            refused.unwrap_err(),
            ConnectError::Driver(DriverError::Config(ConfigError::AuthModeUnsupported))
        );
        assert!(driver.requests().is_empty(), "the driver was asked anyway");
    }

    #[tokio::test(start_paused = true)]
    async fn a_required_database_is_checked_before_connecting() {
        let driver = Arc::new(FakeDriver::connecting(&DATABASE_REQUIRED, cataloguing()));
        let target = network(password(), TlsConfig::verify_full(), Some("  "));

        let refused = establish(request(driver.clone(), target), CancellationToken::new()).await;

        assert_eq!(
            refused.unwrap_err(),
            ConnectError::Driver(DriverError::Config(ConfigError::DatabaseRequired))
        );
        assert!(driver.requests().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn a_file_driver_refuses_a_network_target() {
        let driver = Arc::new(FakeDriver::connecting(&FakeDriver::FILE_CAPABILITIES, cataloguing()));
        let target = network(password(), TlsConfig::disabled(), None);

        let refused = establish(request(driver, target), CancellationToken::new()).await;

        assert!(matches!(
            refused,
            Err(ConnectError::Driver(DriverError::Unsupported { .. }))
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_catalog_read_closes_the_connection() {
        let mut script = ConnectionScript::default();
        script
            .list_schemas
            .always(FakeReply::err(DriverError::server("no access")));
        let driver = Arc::new(FakeDriver::connecting(&FakeDriver::FILE_CAPABILITIES, script));

        let refused = establish(request(driver.clone(), file()), CancellationToken::new()).await;

        assert_eq!(
            refused.unwrap_err(),
            ConnectError::Driver(DriverError::server("no access"))
        );
        assert!(driver.connections()[0].is_closed());
    }

    #[tokio::test(start_paused = true)]
    async fn discard_closes_connection() {
        let driver = Arc::new(FakeDriver::connecting(&FakeDriver::FILE_CAPABILITIES, cataloguing()));
        let pending = establish(request(driver.clone(), file()), CancellationToken::new())
            .await
            .unwrap();

        let report = pending.discard().await;

        assert_eq!(report, CloseReport::Closed);
        assert!(driver.connections()[0].is_closed());
    }
}
