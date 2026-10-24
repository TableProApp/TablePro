//! Opening a scylla session on the target's transport: its relay, its
//! TLS, its login and the one node it stays on.

use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use scylla::client::caching_session::CachingSession;
use scylla::client::execution_profile::ExecutionProfile;
use scylla::client::session::Session;
use scylla::client::session_builder::SessionBuilder;
use scylla::client::{PoolSize, SelfIdentity};
use scylla::policies::retry::FallthroughRetryPolicy;
use scylla::response::query_result::QueryResult;
use scylla::response::{PagingState, PagingStateResponse};
use scylla::serialize::row::SerializeRow;
use scylla::statement::prepared::PreparedStatement;
use scylla::statement::unprepared::Statement as CqlStatement;
use scylla::value::CqlValue;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::statement::Statement;
use tablepro_core::{
    APPLICATION_NAME, ConfigError, ConnectEnvironment, Credentials, DriverError, LivenessPolicy, LossPhase,
    NetworkTarget, ServerCode, ServerInfo, TimeoutPhase, TlsFailure, Transport,
};
use tablepro_net::tls::{TlsSetupError, build_client_config_checking, set_up_off_runtime};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::bind::to_cql;
use crate::dialect::SCYLLA_PRODUCT;
use crate::errors::{execution_error, new_session_error, prepare_error};
use crate::pin::ContactPin;
use crate::relay::Relay;

/// Prepared statements a session keeps. A page query is the same text
/// for every page of a table, so a small cache serves a whole browse.
const PREPARED_CACHE: usize = 256;

/// The error code of a statement the role has no permission for.
const UNAUTHORIZED: i32 = 0x2100;

/// How long to wait between asking a session that was just moved to its
/// node whether that node's pool is up.
const PIN_RETRY: Duration = Duration::from_millis(100);

/// What opening a session of this target needs, kept for the editor
/// tabs that open sessions of their own later.
#[derive(Debug)]
pub(crate) struct CqlEndpoint {
    transport: Arc<dyn Transport>,
    login: Option<(String, SecretString)>,
    tls: Option<Arc<rustls::ClientConfig>>,
    keyspace: Option<String>,
    liveness: LivenessPolicy,
    client_version: String,
}

impl CqlEndpoint {
    pub(crate) async fn new(
        target: &NetworkTarget,
        liveness: LivenessPolicy,
        environment: &ConnectEnvironment,
    ) -> Result<Self, DriverError> {
        let Credentials::Password { username, password } = &target.credentials else {
            return Err(DriverError::Config(ConfigError::AuthModeUnsupported));
        };
        let login = (!username.is_empty()).then(|| (username.clone(), password.clone()));
        let tls_config = target.tls.clone();
        let name = rustls_pki_types::ServerName::try_from(target.tls_server_name().to_owned())
            .map_err(|_| DriverError::Config(ConfigError::InvalidServerName))?;
        let tls =
            set_up_off_runtime(move || build_client_config_checking(&tls_config, name).map_err(setup_error)).await?;
        Ok(Self {
            transport: target.transport.clone(),
            login,
            tls,
            keyspace: target.database.clone().filter(|keyspace| !keyspace.is_empty()),
            liveness,
            client_version: environment.client_version.clone(),
        })
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    pub(crate) fn keyspace(&self) -> Option<&str> {
        self.keyspace.as_deref()
    }

    /// A session of its own, in `keyspace` when one is given, kept on the
    /// node the transport reaches. Gives up when `cancel` fires or the
    /// login timeout passes.
    pub(crate) async fn open(
        &self,
        keyspace: Option<&str>,
        cancel: &CancellationToken,
    ) -> Result<CqlLink, DriverError> {
        let until = Instant::now() + self.liveness.login_timeout;
        let relay = Relay::start(self.transport.clone()).await?;
        let pin = Arc::new(ContactPin::new(relay.address()));
        let profile = ExecutionProfile::builder()
            .request_timeout(None)
            .retry_policy(Arc::new(FallthroughRetryPolicy::new()))
            .build()
            .into_handle();
        let identity = SelfIdentity::new()
            .with_application_name(APPLICATION_NAME)
            .with_application_version(self.client_version.clone());
        let mut builder = SessionBuilder::new()
            .known_node_addr(relay.address())
            .host_filter(pin.clone())
            .address_translator(pin.clone())
            // The shard-aware port is the node's own, which no transport
            // here carries.
            .disallow_shard_aware_port(true)
            .pool_size(PoolSize::PerHost(NonZeroUsize::MIN))
            .connection_timeout(self.liveness.login_timeout)
            .fetch_schema_metadata(false)
            .default_execution_profile_handle(profile)
            .custom_identity(identity)
            .tls_context(self.tls.clone());
        if let Some((username, password)) = &self.login {
            builder = builder.user(username.as_str(), password.expose_secret());
        }
        if let Some(keyspace) = keyspace {
            builder = builder.use_keyspace(keyspace, true);
        }
        let built = tokio::select! {
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            built = tokio::time::timeout_at(until, builder.build()) => built,
        };
        let session = match built {
            Err(_) => {
                return Err(self
                    .explain(
                        &relay,
                        DriverError::Timeout {
                            phase: TimeoutPhase::Login,
                            server_cancelled: false,
                        },
                    )
                    .await);
            }
            Ok(Err(error)) => return Err(self.explain(&relay, new_session_error(error)).await),
            Ok(Ok(session)) => session,
        };
        let link = CqlLink {
            session: CachingSession::from(session, PREPARED_CACHE),
            relay,
        };
        let pinned = tokio::select! {
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            pinned = tokio::time::timeout_at(until, link.pin_to_contact(&pin, until)) => pinned,
        };
        match pinned {
            Ok(Ok(())) => Ok(link),
            Ok(Err(error)) => Err(self.explain(link.relay(), error).await),
            Err(_) => Err(self
                .explain(
                    link.relay(),
                    DriverError::Timeout {
                        phase: TimeoutPhase::Login,
                        server_cancelled: false,
                    },
                )
                .await),
        }
    }

    /// A failure the transport knows more about than the closed stream
    /// the client library saw. A save keeps the outcome it reports, and
    /// only what stopped it is explained.
    pub(crate) async fn explain(&self, relay: &Relay, error: DriverError) -> DriverError {
        match error {
            DriverError::RolledBack {
                statement_index,
                source,
            } => DriverError::RolledBack {
                statement_index,
                source: Box::new(self.explain_cause(relay, *source).await),
            },
            DriverError::CommitOutcomeUnknown { token, source } => DriverError::CommitOutcomeUnknown {
                token,
                source: Box::new(self.explain_cause(relay, *source).await),
            },
            DriverError::PartiallyApplied {
                applied,
                statement_index,
                failed_outcome,
                source,
            } => DriverError::PartiallyApplied {
                applied,
                statement_index,
                failed_outcome,
                source: Box::new(self.explain_cause(relay, *source).await),
            },
            other => self.explain_cause(relay, other).await,
        }
    }

    async fn explain_cause(&self, relay: &Relay, error: DriverError) -> DriverError {
        match error {
            DriverError::ConnectionLost { .. } | DriverError::Timeout { .. } => {
                if let Some(failure) = relay.take_failure() {
                    return DriverError::Transport(failure);
                }
                match self.transport.explain_closed_stream().await {
                    Some(failure) => DriverError::Transport(failure),
                    None => error,
                }
            }
            other => other,
        }
    }
}

fn setup_error(error: TlsSetupError) -> DriverError {
    match error {
        TlsSetupError::Config(error) => DriverError::Config(error),
        TlsSetupError::ClientIdentity(error) => DriverError::Tls {
            failure: TlsFailure::ClientIdentityInvalid,
            detail: error.to_string(),
        },
        other => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: other.to_string(),
        },
    }
}

/// The link a connection or an editor session holds until it closes. A
/// close lets go of it, so the session's connections and its relay close
/// once no call still running holds it.
pub(crate) struct LinkSlot(Mutex<Option<Arc<CqlLink>>>);

impl LinkSlot {
    pub(crate) fn new(link: CqlLink) -> Self {
        Self(Mutex::new(Some(Arc::new(link))))
    }

    pub(crate) fn get(&self) -> Result<Arc<CqlLink>, DriverError> {
        self.lock().clone().ok_or(DriverError::ConnectionLost {
            during: LossPhase::Idle,
        })
    }

    pub(crate) fn release(&self) {
        let link = self.lock().take();
        drop(link);
    }

    fn lock(&self) -> MutexGuard<'_, Option<Arc<CqlLink>>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// One scylla session and the relay it dials, which has to live as long
/// as the session does.
pub(crate) struct CqlLink {
    session: CachingSession,
    relay: Relay,
}

impl CqlLink {
    pub(crate) fn session(&self) -> &Session {
        self.session.get_session()
    }

    pub(crate) fn relay(&self) -> &Relay {
        &self.relay
    }

    pub(crate) async fn prepared(&self, sql: &str) -> Result<PreparedStatement, DriverError> {
        self.session
            .add_prepared_statement(&CqlStatement::new(sql))
            .await
            .map_err(|error| prepare_error(error, LossPhase::Statement))
    }

    /// One page of a generated statement, its values sent as the types
    /// the server gave its markers.
    pub(crate) async fn page(
        &self,
        statement: &Statement,
        page_size: i32,
        paging: PagingState,
    ) -> Result<(QueryResult, PagingStateResponse), DriverError> {
        let mut prepared = self.prepared(statement.sql()).await?;
        prepared.set_page_size(page_size.max(1));
        let values = bound_values(&prepared, statement)?;
        self.session()
            .execute_single_page(&prepared, values, paging)
            .await
            .map_err(|error| execution_error(error, LossPhase::Statement))
    }

    /// A generated statement that is not paged: a write, a count. One
    /// with no values goes as it is, so a schema change or a batch the
    /// user wrote does not fill the prepared statement cache.
    pub(crate) async fn execute(&self, statement: &Statement) -> Result<QueryResult, DriverError> {
        if statement.params().is_empty() {
            return self
                .session()
                .query_unpaged(statement.sql(), ())
                .await
                .map_err(|error| execution_error(error, LossPhase::Statement));
        }
        let prepared = self.prepared(statement.sql()).await?;
        let values = bound_values(&prepared, statement)?;
        self.session()
            .execute_unpaged(&prepared, values)
            .await
            .map_err(|error| execution_error(error, LossPhase::Statement))
    }

    /// A catalogue read with values of its own, prepared once.
    pub(crate) async fn catalogue(&self, sql: &str, values: impl SerializeRow) -> Result<QueryResult, DriverError> {
        self.session
            .execute_unpaged(sql, values)
            .await
            .map_err(|error| execution_error(error, LossPhase::Statement))
    }

    /// The node on the other end of the relay, in its own words.
    async fn local_host_id(&self) -> Result<Uuid, DriverError> {
        let result = self
            .catalogue("SELECT host_id FROM system.local WHERE key = 'local'", ())
            .await?;
        let rows = result
            .into_rows_result()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let (host,): (Uuid,) = rows
            .single_row()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        Ok(host)
    }

    /// Keep the session on the node that answers through the relay. The
    /// first node the session took may not be it, so the node that
    /// answers is pinned and the topology read again, until the two agree.
    async fn pin_to_contact(&self, pin: &ContactPin, until: Instant) -> Result<(), DriverError> {
        loop {
            match self.local_host_id().await {
                Ok(host) if !pin.pin(host) => return Ok(()),
                Ok(_) => self
                    .session()
                    .refresh_metadata()
                    .await
                    .map_err(|error| DriverError::Protocol(error.to_string()))?,
                // A node the topology was just moved to has its pool to
                // open before it serves anything.
                Err(DriverError::ConnectionLost { .. }) if Instant::now() + PIN_RETRY < until => {
                    tokio::time::sleep(PIN_RETRY).await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    /// What the server says it is. ScyllaDB answers with a sharded
    /// connection, and keeps its own version apart from the Cassandra
    /// release it reports for compatibility.
    pub(crate) async fn server_info(&self) -> Result<ServerInfo, DriverError> {
        let scylla = self
            .session()
            .get_cluster_state()
            .get_nodes_info()
            .iter()
            .any(|node| node.sharder().is_some());
        let compatible = "SELECT release_version FROM system.local WHERE key = 'local'";
        if !scylla {
            return self.version_of("Cassandra", compatible).await;
        }
        // ScyllaDB 2026.1 reads its own version only to a role granted
        // SELECT on system.versions; another role gets the Cassandra
        // release ScyllaDB reports for compatibility.
        match self
            .version_of(
                SCYLLA_PRODUCT,
                "SELECT version FROM system.versions WHERE key = 'local'",
            )
            .await
        {
            Err(DriverError::Server(diagnostics))
                if diagnostics.code == Some(ServerCode::Cql { code: UNAUTHORIZED }) =>
            {
                self.version_of(SCYLLA_PRODUCT, compatible).await
            }
            other => other,
        }
    }

    async fn version_of(&self, product: &str, sql: &str) -> Result<ServerInfo, DriverError> {
        let rows = self
            .catalogue(sql, ())
            .await?
            .into_rows_result()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let (version,): (Option<String>,) = rows
            .single_row()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let version = version.unwrap_or_default();
        let [major, minor, patch] = version_numbers(&version);
        Ok(ServerInfo::new(product, version, major, minor, patch))
    }
}

/// The values of `statement` as the markers of `prepared` take them.
fn bound_values(prepared: &PreparedStatement, statement: &Statement) -> Result<Vec<Option<CqlValue>>, DriverError> {
    let specs = prepared.get_variable_col_specs();
    if specs.len() != statement.params().len() {
        return Err(DriverError::Protocol(format!(
            "the statement has {} markers and {} values",
            specs.len(),
            statement.params().len()
        )));
    }
    specs
        .iter()
        .zip(statement.params())
        .map(|(spec, param)| to_cql(param.value(), spec.typ()))
        .collect()
}

/// The leading numbers of a version such as `5.0.9` or
/// `2026.1.3-0.20260912.abc`, zero where one is missing.
fn version_numbers(version: &str) -> [u32; 3] {
    let mut numbers = [0; 3];
    for (slot, part) in numbers.iter_mut().zip(version.split('.')) {
        *slot = part
            .chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>()
            .parse()
            .unwrap_or(0);
    }
    numbers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_read_their_leading_numbers() {
        assert_eq!(version_numbers("5.0.9"), [5, 0, 9]);
        assert_eq!(version_numbers("2026.1.3-0.20260912.abcdef"), [2026, 1, 3]);
        assert_eq!(version_numbers("4.1"), [4, 1, 0]);
        assert_eq!(version_numbers(""), [0, 0, 0]);
    }
}
