use std::sync::Arc;

use tablepro_core::{ConnectOptions, Connection, DriverRegistry};
use tablepro_storage::SavedConnection;
use tablepro_transport::TransportError;
use tablepro_transport::{SshEnvironment, SshRoute, Tunnel};
use uuid::Uuid;

use super::database_service::{CandidateGuardFactory, ConnectionMetadata, DatabaseService, ReconnectParams};

/// A connection that has authenticated and completed its initial metadata
/// query, but has not replaced the active application connection yet.
/// Keeping preparation separate from activation makes failed switches leave
/// the existing workspace and connection untouched.
pub struct PreparedConnection {
    pub tables: Vec<tablepro_core::TableInfo>,
    pub views: Vec<tablepro_core::TableInfo>,
    pub driver_id: String,
    id: uuid::Uuid,
    metadata: ConnectionMetadata,
    connection: Arc<dyn Connection>,
    tunnel: Option<Tunnel>,
    read_only: bool,
    params: ReconnectParams,
}

impl std::fmt::Debug for PreparedConnection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedConnection")
            .field("id", &self.id)
            .field("driver_id", &self.driver_id)
            .field("table_count", &self.tables.len())
            .field("view_count", &self.views.len())
            .finish_non_exhaustive()
    }
}

pub struct ActivatedConnection {
    pub id: Uuid,
    pub tables: Vec<tablepro_core::TableInfo>,
    pub views: Vec<tablepro_core::TableInfo>,
    pub driver_id: String,
}

impl PreparedConnection {
    /// The saved connection this would activate, so a caller can check
    /// `DatabaseService::is_active(id)` before committing to
    /// the switch -- tearing down whatever it currently owns only after
    /// confirming the target isn't already open in another window.
    pub fn id(&self) -> Uuid {
        self.id
    }

    pub(crate) fn new(
        tables: Vec<tablepro_core::TableInfo>,
        views: Vec<tablepro_core::TableInfo>,
        driver_id: String,
        metadata: ConnectionMetadata,
        connection: Arc<dyn Connection>,
        tunnel: Option<Tunnel>,
        params: ReconnectParams,
    ) -> Self {
        Self {
            tables,
            views,
            driver_id,
            id: metadata.id,
            read_only: metadata.read_only,
            metadata,
            connection,
            tunnel,
            params,
        }
    }

    /// Returns `None` without changing anything when `id` is already active
    /// in another window; the caller should show that error and leave
    /// whatever it currently owns untouched. Callers that must guarantee
    /// success should check [`Self::id`] against
    /// `DatabaseService::is_active` before committing to the
    /// switch (tearing down a previous connection, clearing tabs) so a
    /// refusal here never needs to be rolled back.
    pub fn activate(self, database: &DatabaseService) -> Option<ActivatedConnection> {
        let id = self.id;
        let activated = database.activate_shared(
            id,
            self.metadata,
            self.connection,
            self.tunnel,
            self.read_only,
            self.params,
        );
        if !activated {
            return None;
        }
        Some(ActivatedConnection {
            id,
            tables: self.tables,
            views: self.views,
            driver_id: self.driver_id,
        })
    }
}

pub async fn open_saved(
    registry: Arc<DriverRegistry>,
    saved: SavedConnection,
    timeout_secs: u32,
    ssh_environment: SshEnvironment,
    cancellation: tokio_util::sync::CancellationToken,
    guard_factory: CandidateGuardFactory,
) -> Result<PreparedConnection, String> {
    let driver = registry
        .get(&saved.driver_id)
        .ok_or_else(|| format!("driver {} not registered", saved.driver_id))?;
    let id = saved.id;
    let environment = saved.environment;
    let read_only = saved.read_only;

    let ssh_hops = tablepro_transport::saved_ssh_route(&saved).await.map_err(message)?;
    let mut opts = tablepro_transport::connect_options_for(&saved).await.map_err(message)?;
    opts.application_name = Some("BookiE".into());

    let (conn, tunnel) = tablepro_transport::establish_with_cancellation(
        &*driver,
        opts.clone(),
        ssh_hops.clone(),
        &ssh_environment,
        cancellation,
    )
    .await
    .map_err(message)?;
    let connection: Arc<dyn Connection> = Arc::from(conn);
    let metadata = ConnectionMetadata {
        id,
        name: saved.name.clone(),
        driver_id: saved.driver_id.clone(),
        environment,
        read_only,
        server_version: None,
        query_timeout_secs: saved.query_timeout_secs,
    };
    let guarded = guard_factory.guard(connection.clone(), &metadata, tablepro_policy::Principal::human_gui());
    let server_version = match guarded.server_version().await {
        Ok(version) => version,
        Err(tablepro_core::DriverError::PolicyDenied(message)) => return Err(message),
        Err(_) => None,
    };
    let control = crate::services::operation_control::bounded(timeout_secs);
    let tables = guarded
        .list_tables_controlled(&control)
        .await
        .map_err(|e| format!("list_tables: {e}"))?;
    let views = guarded
        .list_views_controlled(&control)
        .await
        .map_err(|e| format!("list_views: {e}"))?;
    let metadata = ConnectionMetadata {
        server_version,
        ..metadata
    };
    let params = ReconnectParams {
        driver,
        opts,
        ssh: ssh_hops,
        environment: ssh_environment,
    };
    Ok(PreparedConnection::new(
        tables,
        views,
        saved.driver_id,
        metadata,
        connection,
        tunnel,
        params,
    ))
}

pub struct EstablishFailure {
    pub message: String,
    pub permanent: bool,
}

pub async fn establish_classified_with_cancellation(
    driver: &dyn tablepro_core::DatabaseDriver,
    opts: ConnectOptions,
    ssh: Option<SshRoute>,
    environment: &SshEnvironment,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<(Box<dyn Connection>, Option<Tunnel>), EstablishFailure> {
    tablepro_transport::establish_with_cancellation(driver, opts, ssh, environment, cancellation)
        .await
        .map_err(|error| EstablishFailure {
            permanent: is_permanent_failure(&error),
            message: message(error),
        })
}

pub fn was_cancelled(token: Option<&tokio_util::sync::CancellationToken>) -> bool {
    token.is_some_and(tokio_util::sync::CancellationToken::is_cancelled)
}

pub fn is_permanent_failure(error: &TransportError) -> bool {
    use tablepro_core::DriverError;
    match error {
        TransportError::Driver(driver) => matches!(
            driver,
            DriverError::AuthFailed
                | DriverError::Tls(_)
                | DriverError::IntegratedAuth(_)
                | DriverError::PolicyDenied(_)
                | DriverError::Unsupported(_)
        ),
        TransportError::Keyring(_)
        | TransportError::Secret(_)
        | TransportError::IntegratedAuthUnsupported(_)
        | TransportError::LocalSocketUnsupported(_)
        | TransportError::LocalSocketWithSsh
        | TransportError::LocalSocketWithTls
        | TransportError::InvalidLocalSocket(_)
        | TransportError::SystemSshUnavailableInSandbox => true,
        TransportError::HostKeyRefused(_) | TransportError::HostKeyChanged(_) | TransportError::HostKeyRevoked(_) => {
            true
        }
        TransportError::AuditWriteFailed(_) => true,
        TransportError::Ssh(_)
        | TransportError::SshTimeout(_)
        | TransportError::Cancelled
        | TransportError::DatabaseTimeout { .. } => false,
    }
}

fn message(error: TransportError) -> String {
    match error {
        TransportError::Driver(error) => crate::ui::error_text::driver_message(&error),
        TransportError::Keyring(failure) => crate::ui::error_text::keyring_message(&failure),
        TransportError::IntegratedAuthUnsupported(driver_name) => {
            crate::tr!("The {driver} driver does not support Windows (Kerberos) authentication.")
                .replace("{driver}", &driver_name)
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod failure_tests {
    use super::*;
    #[test]
    fn a_connect_is_cancelled_only_when_its_token_was_cancelled() {
        let token = tokio_util::sync::CancellationToken::new();
        assert!(!was_cancelled(None));
        assert!(!was_cancelled(Some(&token)));
        token.cancel();
        assert!(was_cancelled(Some(&token)));
    }

    use tablepro_core::DriverError;
    use tablepro_storage::KeyringFailure;

    #[test]
    fn wrong_credentials_tls_and_configuration_are_permanent() {
        for error in [
            TransportError::Driver(DriverError::AuthFailed),
            TransportError::Driver(DriverError::Tls("bad certificate".into())),
            TransportError::Driver(DriverError::IntegratedAuth("no ticket".into())),
            TransportError::Driver(DriverError::PolicyDenied("blocked".into())),
            TransportError::Keyring(KeyringFailure::Locked),
            TransportError::IntegratedAuthUnsupported("sqlite".into()),
            TransportError::LocalSocketWithSsh,
            TransportError::HostKeyRefused("unknown".into()),
            TransportError::HostKeyChanged("changed".into()),
            TransportError::HostKeyRevoked("revoked".into()),
            TransportError::AuditWriteFailed("journal unavailable".into()),
        ] {
            assert!(is_permanent_failure(&error), "{error} should stop a reconnect");
        }
    }

    #[test]
    fn a_server_that_is_down_or_slow_is_worth_retrying() {
        for error in [
            TransportError::Driver(DriverError::ConnectionRefused),
            TransportError::Driver(DriverError::Disconnected),
            TransportError::Driver(DriverError::TimedOut),
            TransportError::Ssh("connection reset".into()),
            TransportError::SshTimeout("connection timeout".into()),
            TransportError::Cancelled,
            TransportError::DatabaseTimeout { seconds: 30 },
        ] {
            assert!(!is_permanent_failure(&error), "{error} should keep retrying");
        }
    }
}
