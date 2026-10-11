//! Shared composition pieces for the headless TablePro agent daemon.
//!
//! Agents reach a database through exactly the transport a saved connection
//! describes, and every handle handed out is wrapped by `PolicyGuard`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    AuthMode, ColumnInfo, Connection, DriverError, DriverRegistry, ExecResult, ForeignKeyInfo, IndexInfo,
    OperationControl, QueryResult, TableInfo, TlsMode, Transaction, Value,
};
use tablepro_mcp::ConnectionProvider;
use tablepro_policy::{AuditState, GuardContext, PolicyConfig, PolicyGuard, Principal};
use tablepro_storage::{SavedConnection, SavedSshConfig, load_connections};
use uuid::Uuid;

const SESSION_PING_TIMEOUT: Duration = Duration::from_secs(5);

pub(crate) const AGENT_UNKNOWN_HOST_KEY: tablepro_ssh::UnknownHostKey = tablepro_ssh::UnknownHostKey::Refuse;

struct OpenSession {
    key: SessionKey,
    connection: Arc<dyn Connection>,
    audit_state: Arc<AuditState>,
    retired: Arc<std::sync::atomic::AtomicBool>,
}

struct SessionFaultSink {
    retired: Arc<std::sync::atomic::AtomicBool>,
}

impl tablepro_policy::ConnectionFaultSink for SessionFaultSink {
    fn connection_became_unusable(&self, operation: &str) {
        tracing::warn!(operation, "a cached session became unusable and will be replaced");
        self.retired.store(true, std::sync::atomic::Ordering::Release);
    }
}

struct SessionConnection {
    inner: Arc<dyn Connection>,
    _tunnel: Option<tablepro_transport::Tunnel>,
}

#[async_trait]
impl Connection for SessionConnection {
    fn supports_server_cancellation(&self) -> bool {
        self.inner.supports_server_cancellation()
    }

    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        self.inner.list_tables().await
    }

    async fn list_tables_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        self.inner.list_tables_controlled(control).await
    }

    async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
        self.inner.list_views().await
    }

    async fn list_views_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        self.inner.list_views_controlled(control).await
    }

    async fn list_objects(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        self.inner.list_objects(kind, schema).await
    }

    async fn list_objects_controlled(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
        control: &OperationControl,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        self.inner.list_objects_controlled(kind, schema, control).await
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        self.inner.fetch_columns(schema, table).await
    }

    async fn fetch_columns_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ColumnInfo>, DriverError> {
        self.inner.fetch_columns_controlled(schema, table, control).await
    }

    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        self.inner.fetch_rows(schema, table, offset, limit).await
    }

    async fn fetch_rows_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        self.inner
            .fetch_rows_controlled(schema, table, offset, limit, control)
            .await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        self.inner.query(sql).await
    }

    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        self.inner.query_controlled(sql, control).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        self.inner.query_params(sql, params).await
    }

    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        self.inner.query_params_controlled(sql, params, control).await
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        self.inner.execute(sql).await
    }

    async fn execute_controlled(&self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        self.inner.execute_controlled(sql, control).await
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        self.inner.execute_params(sql, params).await
    }

    async fn execute_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        self.inner.execute_params_controlled(sql, params, control).await
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.inner.execute_in_transaction(statements).await
    }

    async fn execute_in_transaction_controlled(
        &self,
        statements: &[(String, Vec<Value>)],
        control: &OperationControl,
    ) -> Result<Vec<u64>, DriverError> {
        self.inner.execute_in_transaction_controlled(statements, control).await
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        self.inner.fetch_indexes(schema, table).await
    }

    async fn fetch_indexes_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<IndexInfo>, DriverError> {
        self.inner.fetch_indexes_controlled(schema, table, control).await
    }

    async fn fetch_foreign_keys(&self, schema: Option<&str>, table: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        self.inner.fetch_foreign_keys(schema, table).await
    }

    async fn fetch_foreign_keys_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        self.inner.fetch_foreign_keys_controlled(schema, table, control).await
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        self.inner.begin().await
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        self.inner.server_version().await
    }

    async fn ping(&self) -> Result<(), DriverError> {
        self.inner.ping().await
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq)]
struct SessionKey {
    driver_id: String,
    host: String,
    port: u16,
    socket_dir: Option<PathBuf>,
    database: String,
    username: String,
    tls_mode: TlsMode,
    tls_root_cert: Option<PathBuf>,
    auth_mode: AuthMode,
    ssh: Option<SavedSshConfig>,
    material: [u8; 32],
}

impl SessionKey {
    fn from_saved(saved: &SavedConnection, material: [u8; 32]) -> Self {
        Self {
            driver_id: saved.driver_id.clone(),
            host: saved.host.clone(),
            port: saved.port,
            socket_dir: saved.socket_dir.clone(),
            database: saved.database.clone(),
            username: saved.username.clone(),
            tls_mode: saved.effective_tls_mode(),
            tls_root_cert: saved.tls_root_cert.clone(),
            auth_mode: saved.auth_mode,
            ssh: saved.ssh.clone(),
            material,
        }
    }
}

pub struct DaemonProvider {
    registry: Arc<DriverRegistry>,
    policy: Arc<PolicyConfig>,
    audit: Arc<dyn tablepro_policy::AuditSink>,
    audit_state: Arc<AuditState>,
    approval: Arc<dyn tablepro_policy::ApprovalSink>,
    sessions: Mutex<HashMap<Uuid, OpenSession>>,
    session_locks: Mutex<HashMap<Uuid, Arc<tokio::sync::Mutex<()>>>>,
    ssh: tablepro_transport::SshEnvironment,
}

#[async_trait]
impl ConnectionProvider for DaemonProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        load_connections().await.map_err(|e| e.to_string())
    }

    async fn connection(&self, connection_id: Uuid, principal: Principal) -> Result<Arc<dyn Connection>, String> {
        let saved = load_connections()
            .await
            .map_err(|e| e.to_string())?
            .into_iter()
            .find(|c| c.id == connection_id)
            .ok_or_else(|| format!("connection {connection_id} not found"))?;

        let raw = self.open_session_for(&saved, principal.clone()).await?;
        Ok(self.guarded(&saved, principal, raw))
    }
}

impl DaemonProvider {
    pub fn new(
        registry: Arc<DriverRegistry>,
        policy: Arc<PolicyConfig>,
        audit: Arc<dyn tablepro_policy::AuditSink>,
        audit_state: Arc<AuditState>,
        approval: Arc<dyn tablepro_policy::ApprovalSink>,
    ) -> Self {
        Self {
            registry,
            policy,
            audit,
            audit_state,
            approval,
            sessions: Mutex::new(HashMap::new()),
            session_locks: Mutex::new(HashMap::new()),
            ssh: tablepro_transport::SshEnvironment::builtin(AGENT_UNKNOWN_HOST_KEY),
        }
    }

    fn new_session(&self, key: SessionKey, connection: Arc<dyn Connection>) -> OpenSession {
        OpenSession {
            key,
            connection,
            audit_state: Arc::new(self.audit_state.new_connection_generation()),
            retired: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    fn session_retirement(&self, id: Uuid, connection: &Arc<dyn Connection>) -> Arc<std::sync::atomic::AtomicBool> {
        self.sessions
            .lock()
            .ok()
            .and_then(|sessions| {
                sessions
                    .get(&id)
                    .filter(|session| Arc::ptr_eq(&session.connection, connection))
                    .map(|session| session.retired.clone())
            })
            .unwrap_or_default()
    }

    fn session_audit_state(&self, id: Uuid, connection: &Arc<dyn Connection>) -> Arc<AuditState> {
        self.sessions
            .lock()
            .ok()
            .and_then(|sessions| {
                sessions
                    .get(&id)
                    .filter(|session| Arc::ptr_eq(&session.connection, connection))
                    .map(|session| session.audit_state.clone())
            })
            .unwrap_or_else(|| Arc::new(self.audit_state.new_connection_generation()))
    }

    fn guarded(&self, saved: &SavedConnection, principal: Principal, raw: Arc<dyn Connection>) -> Arc<dyn Connection> {
        let ctx = GuardContext {
            connection_id: saved.id,
            connection_name: saved.name.clone(),
            driver_id: saved.driver_id.clone(),
            environment: saved.environment,
            read_only: saved.read_only,
            principal,
            policy: self.policy.clone(),
            approval: self.approval.clone(),
            audit: self.audit.clone(),
            audit_state: self.session_audit_state(saved.id, &raw),
        };
        let fault = Arc::new(SessionFaultSink {
            retired: self.session_retirement(saved.id, &raw),
        });
        Arc::new(PolicyGuard::new(raw, ctx).with_fault_sink(fault))
    }

    pub fn with_system_openssh(mut self, openssh: tablepro_transport::OpenSshEnvironment) -> Self {
        self.ssh.openssh = Some(openssh);
        self
    }

    #[cfg(test)]
    async fn open_session(&self, saved: &SavedConnection) -> Result<Arc<dyn Connection>, String> {
        self.open_session_for(saved, Principal::human_gui()).await
    }

    async fn open_session_for(
        &self,
        saved: &SavedConnection,
        principal: Principal,
    ) -> Result<Arc<dyn Connection>, String> {
        let session_lock = self.session_lock(saved.id)?;
        let _open = session_lock.lock_owned().await;
        let material = match tablepro_transport::session_material_digest(saved).await {
            Ok(material) => material,
            Err(error) => return Err(error.to_string()),
        };
        let key = SessionKey::from_saved(saved, material);
        let cached = self.cached_connection(saved.id, &key)?;
        if let Some(connection) = cached {
            let healthy = ping_is_healthy(connection.ping(), SESSION_PING_TIMEOUT).await;
            let retired = self
                .session_retirement(saved.id, &connection)
                .load(std::sync::atomic::Ordering::Acquire);
            if healthy && !retired && self.session_is_current(saved.id, &key, &connection)? {
                return Ok(connection);
            }
            self.remove_session(saved.id, &key, &connection)?;
        }

        let connection = self.connect_session(saved, principal).await?;
        let material = match tablepro_transport::session_material_digest(saved).await {
            Ok(material) => material,
            Err(error) => {
                drop(connection);
                return Err(error.to_string());
            }
        };
        let key = SessionKey::from_saved(saved, material);
        self.sessions
            .lock()
            .map_err(|_| "session cache unavailable".to_string())?
            .insert(saved.id, self.new_session(key, connection.clone()));
        Ok(connection)
    }

    async fn connect_session(
        &self,
        saved: &SavedConnection,
        principal: Principal,
    ) -> Result<Arc<dyn Connection>, String> {
        let driver = self
            .registry
            .get(&saved.driver_id)
            .ok_or_else(|| format!("driver {} not registered", saved.driver_id))?;
        let ssh = tablepro_transport::saved_ssh_route(saved)
            .await
            .map_err(|e| e.to_string())?;
        let mut opts = tablepro_transport::connect_options_for(saved)
            .await
            .map_err(|e| e.to_string())?;
        opts.application_name = Some("BookiE agent".into());
        let ssh_environment = self
            .ssh
            .clone()
            .with_audit(tablepro_transport::TransportAuditContext::new(
                self.audit.clone(),
                self.audit_state.clone(),
                principal,
                saved.id,
                saved.name.clone(),
                saved.environment,
                saved.driver_id.clone(),
            ));
        let (raw, tunnel) = tablepro_transport::establish(driver.as_ref(), opts, ssh, &ssh_environment)
            .await
            .map_err(|e| e.to_string())?;
        Ok(Arc::new(SessionConnection {
            inner: Arc::from(raw),
            _tunnel: tunnel,
        }))
    }

    fn cached_connection(&self, id: Uuid, key: &SessionKey) -> Result<Option<Arc<dyn Connection>>, String> {
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| "session cache unavailable".to_string())?;
        let stale = if sessions.get(&id).is_some_and(|session| session.key != *key) {
            sessions.remove(&id)
        } else {
            None
        };
        let connection = sessions.get(&id).map(|session| session.connection.clone());
        drop(stale);
        Ok(connection)
    }

    fn session_is_current(&self, id: Uuid, key: &SessionKey, connection: &Arc<dyn Connection>) -> Result<bool, String> {
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| "session cache unavailable".to_string())?;
        Ok(sessions
            .get(&id)
            .is_some_and(|session| session.key == *key && Arc::ptr_eq(&session.connection, connection)))
    }

    fn remove_session(&self, id: Uuid, key: &SessionKey, connection: &Arc<dyn Connection>) -> Result<(), String> {
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| "session cache unavailable".to_string())?;
        if sessions
            .get(&id)
            .is_some_and(|session| session.key == *key && Arc::ptr_eq(&session.connection, connection))
        {
            sessions.remove(&id);
        }
        Ok(())
    }

    fn session_lock(&self, id: Uuid) -> Result<Arc<tokio::sync::Mutex<()>>, String> {
        let mut locks = self
            .session_locks
            .lock()
            .map_err(|_| "session lock cache unavailable".to_string())?;
        Ok(locks
            .entry(id)
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone())
    }
}

async fn ping_is_healthy(
    ping: impl std::future::Future<Output = Result<(), tablepro_core::DriverError>>,
    timeout: Duration,
) -> bool {
    tokio::time::timeout(timeout, ping)
        .await
        .is_ok_and(|result| result.is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use drivers_sqlite::SqliteDriver;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, Environment};
    use tablepro_policy::{DenyApprovalSink, NullAuditSink};
    use tablepro_storage::SavedSshAuth;

    #[test]
    fn the_agent_never_adds_an_unknown_ssh_host_key() {
        assert_eq!(AGENT_UNKNOWN_HOST_KEY, tablepro_ssh::UnknownHostKey::Refuse);
    }

    fn saved_connection() -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Warehouse".into(),
            driver_id: "postgres".into(),
            host: "db.example".into(),
            port: 5432,
            socket_dir: None,
            database: "warehouse".into(),
            username: "reader".into(),
            use_tls: true,
            tls_mode: Some(TlsMode::VerifyFull),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: true,
            auth_mode: AuthMode::Password,
            environment: Environment::Prod,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    struct ProbeConnection {
        queries: Arc<AtomicUsize>,
        drops: Arc<AtomicUsize>,
    }

    impl Drop for ProbeConnection {
        fn drop(&mut self) {
            self.drops.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[async_trait]
    impl Connection for ProbeConnection {
        async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
            Ok(Vec::new())
        }

        async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
            Ok(Vec::new())
        }

        async fn fetch_rows(
            &self,
            _schema: Option<&str>,
            _table: &str,
            _offset: u64,
            _limit: u64,
        ) -> Result<QueryResult, DriverError> {
            Err(DriverError::Internal("unused probe operation".into()))
        }

        async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
            self.queries.fetch_add(1, Ordering::SeqCst);
            Err(DriverError::Internal("probe query dispatched".into()))
        }

        async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
            Err(DriverError::Internal("unused probe operation".into()))
        }

        async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
            Err(DriverError::Internal("unused probe operation".into()))
        }

        async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
            Err(DriverError::Internal("unused probe operation".into()))
        }

        async fn ping(&self) -> Result<(), DriverError> {
            Ok(())
        }

        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[test]
    fn session_key_changes_when_saved_transport_changes() {
        let original = saved_connection();
        let original_key = SessionKey::from_saved(&original, [0; 32]);
        let mut changed = original.clone();
        changed.host = "replacement.example".into();

        assert!(original_key != SessionKey::from_saved(&changed, [0; 32]));

        changed = original.clone();
        changed.socket_dir = Some(PathBuf::from("/run/postgresql"));

        assert!(original_key != SessionKey::from_saved(&changed, [0; 32]));
    }

    #[test]
    fn session_key_ignores_policy_only_changes() {
        let original = saved_connection();
        let original_key = SessionKey::from_saved(&original, [0; 32]);
        let mut changed = original.clone();
        changed.read_only = false;
        changed.environment = Environment::Dev;

        assert!(original_key == SessionKey::from_saved(&changed, [0; 32]));
    }

    #[test]
    fn session_key_changes_when_material_changes() {
        let saved = saved_connection();
        let original_key = SessionKey::from_saved(&saved, [1; 32]);

        assert!(original_key != SessionKey::from_saved(&saved, [2; 32]));
    }

    #[tokio::test]
    async fn cached_ping_is_bounded() {
        let ping = std::future::pending::<Result<(), DriverError>>();

        assert!(!ping_is_healthy(ping, Duration::from_millis(1)).await);
    }

    #[tokio::test]
    async fn retired_session_drops_after_final_issued_reference() {
        let saved = saved_connection();
        let key = SessionKey::from_saved(&saved, [0; 32]);
        let mut opts = ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        };
        opts.tls.mode = TlsMode::Disabled;
        let raw: Arc<dyn Connection> = Arc::from(SqliteDriver.connect(opts).await.expect("open test database"));
        let raw_lifetime = Arc::downgrade(&raw);
        let connection: Arc<dyn Connection> = Arc::new(SessionConnection {
            inner: raw,
            _tunnel: None,
        });
        let provider = DaemonProvider::new(
            Arc::new(DriverRegistry::new()),
            Arc::new(PolicyConfig::default()),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
            Arc::new(DenyApprovalSink),
        );
        provider.sessions.lock().expect("sessions").insert(
            saved.id,
            OpenSession {
                key: key.clone(),
                connection: connection.clone(),
                audit_state: Arc::new(AuditState::new()),
                retired: Default::default(),
            },
        );
        let issued = connection.clone();

        provider
            .remove_session(saved.id, &key, &connection)
            .expect("remove cached session");
        drop(connection);

        assert!(raw_lifetime.upgrade().is_some());

        drop(issued);

        assert!(raw_lifetime.upgrade().is_none());
    }

    #[tokio::test]
    async fn cached_session_is_dropped_when_material_changes() {
        let saved = saved_connection();
        let old_key = SessionKey::from_saved(&saved, [1; 32]);
        let new_key = SessionKey::from_saved(&saved, [2; 32]);
        let mut opts = ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        };
        opts.tls.mode = TlsMode::Disabled;
        let connection: Arc<dyn Connection> = Arc::from(SqliteDriver.connect(opts).await.expect("open test database"));
        let provider = DaemonProvider::new(
            Arc::new(DriverRegistry::new()),
            Arc::new(PolicyConfig::default()),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
            Arc::new(DenyApprovalSink),
        );
        provider.sessions.lock().expect("sessions").insert(
            saved.id,
            OpenSession {
                key: old_key,
                connection: connection.clone(),
                audit_state: Arc::new(AuditState::new()),
                retired: Default::default(),
            },
        );

        let cached = provider
            .cached_connection(saved.id, &new_key)
            .expect("inspect cache after material rotation");
        assert!(cached.is_none());
        assert!(provider.sessions.lock().expect("sessions").get(&saved.id).is_none());
    }

    struct RotatingCaDriver {
        ca_path: PathBuf,
        rotated_bytes: &'static [u8],
    }

    #[async_trait]
    impl DatabaseDriver for RotatingCaDriver {
        fn id(&self) -> &'static str {
            "sqlite"
        }

        fn display_name(&self) -> &'static str {
            "Rotating CA test driver"
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            std::fs::write(&self.ca_path, self.rotated_bytes).expect("rotate the ca file mid-connect");
            SqliteDriver.connect(opts).await
        }
    }

    #[tokio::test]
    async fn a_key_material_rotation_during_connect_is_not_cached_under_the_stale_digest() {
        let directory = tempfile::tempdir().expect("temp directory");
        let ca_path = directory.path().join("ca.pem");
        std::fs::write(&ca_path, b"material-before-connect").expect("write initial ca material");

        let mut saved = saved_connection();
        saved.driver_id = "sqlite".into();
        saved.database = ":memory:".into();
        saved.tls_root_cert = Some(ca_path.clone());
        saved.ssh = None;

        let mut registry = DriverRegistry::new();
        registry.register(Arc::new(RotatingCaDriver {
            ca_path: ca_path.clone(),
            rotated_bytes: b"material-after-connect",
        }));
        let provider = DaemonProvider::new(
            Arc::new(registry),
            Arc::new(PolicyConfig::default()),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
            Arc::new(DenyApprovalSink),
        );

        provider
            .open_session(&saved)
            .await
            .expect("open session across rotation");

        let post_connect_material = tablepro_transport::session_material_digest(&saved)
            .await
            .expect("digest after the rotation");
        let current_key = SessionKey::from_saved(&saved, post_connect_material);
        let sessions = provider.sessions.lock().expect("sessions");
        let cached = &sessions.get(&saved.id).expect("a session was cached").key;
        assert!(
            *cached == current_key,
            "the cached session key must reflect the material actually used to connect, \
             not a digest read before the key rotated"
        );
    }

    #[tokio::test]
    async fn a_material_lookup_failure_does_not_reuse_a_healthy_cached_connection() {
        let mut saved = saved_connection();
        saved.driver_id = "sqlite".into();
        saved.ssh = Some(SavedSshConfig {
            hop_id: uuid::Uuid::new_v4(),
            credential_revision: 0,
            host: "bastion".into(),
            port: 22,
            username: "tunnel".into(),
            auth: SavedSshAuth::PrivateKey {
                path: "/nonexistent/tablepro-test-key".into(),
                has_passphrase: false,
            },
            jump: None,
            client: Default::default(),
            agent: false,
        });
        let key = SessionKey::from_saved(&saved, [0; 32]);
        let queries = Arc::new(AtomicUsize::new(0));
        let drops = Arc::new(AtomicUsize::new(0));
        let connection: Arc<dyn Connection> = Arc::new(ProbeConnection {
            queries: queries.clone(),
            drops: drops.clone(),
        });
        let provider = DaemonProvider::new(
            Arc::new(DriverRegistry::new()),
            Arc::new(PolicyConfig::default()),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
            Arc::new(DenyApprovalSink),
        );
        provider.sessions.lock().expect("sessions").insert(
            saved.id,
            OpenSession {
                key,
                connection: connection.clone(),
                audit_state: Arc::new(AuditState::new()),
                retired: Default::default(),
            },
        );

        let result = provider.open_session(&saved).await;
        if let Ok(connection) = &result {
            let _ = connection.query("SELECT 1").await;
        }
        assert!(result.is_err());
        assert_eq!(queries.load(Ordering::SeqCst), 0);
        assert!(provider.sessions.lock().expect("sessions").contains_key(&saved.id));
    }

    struct RemovingCaDriver {
        ca_path: PathBuf,
        queries: Arc<AtomicUsize>,
        drops: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl DatabaseDriver for RemovingCaDriver {
        fn id(&self) -> &'static str {
            "sqlite"
        }

        fn display_name(&self) -> &'static str {
            "Removing CA test driver"
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            std::fs::remove_file(&self.ca_path).expect("remove ca material during connect");
            let _ = opts;
            Ok(Box::new(ProbeConnection {
                queries: self.queries.clone(),
                drops: self.drops.clone(),
            }))
        }
    }

    #[tokio::test]
    async fn a_material_lookup_failure_after_connect_discards_the_new_connection() {
        let directory = tempfile::tempdir().expect("temp directory");
        let ca_path = directory.path().join("ca.pem");
        std::fs::write(&ca_path, b"material-before-connect").expect("write initial ca material");
        let mut saved = saved_connection();
        saved.driver_id = "sqlite".into();
        saved.database = ":memory:".into();
        saved.tls_root_cert = Some(ca_path.clone());
        saved.ssh = None;

        let mut registry = DriverRegistry::new();
        let queries = Arc::new(AtomicUsize::new(0));
        let drops = Arc::new(AtomicUsize::new(0));
        registry.register(Arc::new(RemovingCaDriver {
            ca_path,
            queries: queries.clone(),
            drops: drops.clone(),
        }));
        let provider = DaemonProvider::new(
            Arc::new(registry),
            Arc::new(PolicyConfig::default()),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
            Arc::new(DenyApprovalSink),
        );

        assert!(provider.open_session(&saved).await.is_err());
        assert_eq!(queries.load(Ordering::SeqCst), 0);
        assert_eq!(drops.load(Ordering::SeqCst), 1);
        assert!(provider.sessions.lock().expect("sessions").get(&saved.id).is_none());
    }

    #[tokio::test]
    async fn a_healthy_cached_connection_is_reused_when_material_is_verified() {
        let mut saved = saved_connection();
        saved.driver_id = "sqlite".into();
        saved.database = ":memory:".into();
        saved.tls_root_cert = None;
        saved.ssh = None;
        let material = tablepro_transport::session_material_digest(&saved)
            .await
            .expect("digest valid material");
        let key = SessionKey::from_saved(&saved, material);
        let mut opts = ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        };
        opts.tls.mode = TlsMode::Disabled;
        let connection: Arc<dyn Connection> = Arc::from(SqliteDriver.connect(opts).await.expect("open test database"));
        let provider = DaemonProvider::new(
            Arc::new(DriverRegistry::new()),
            Arc::new(PolicyConfig::default()),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
            Arc::new(DenyApprovalSink),
        );
        provider.sessions.lock().expect("sessions").insert(
            saved.id,
            OpenSession {
                key,
                connection: connection.clone(),
                audit_state: Arc::new(AuditState::new()),
                retired: Default::default(),
            },
        );

        let reused = provider
            .open_session(&saved)
            .await
            .expect("verified healthy connection is reusable");
        assert!(Arc::ptr_eq(&reused, &connection));
    }
}

#[cfg(test)]
mod session_tests;

#[cfg(test)]
mod audit_isolation_tests;
