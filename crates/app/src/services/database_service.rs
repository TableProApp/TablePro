use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Environment};
use tablepro_policy::{
    AuditAdministrativeAction, AuditEvent, AuditRecordPhase, AuditState, AuditTerminalStatus, DenyApprovalSink,
    GuardContext, NullAuditSink, PolicyConfig, PolicyGuard, Principal, load_from_path,
};
use tablepro_storage::AuditJournal;
use tablepro_transport::{OpenSshEnvironment, SshEnvironment, SshRoute, Tunnel};

use super::config_io::xdg_config_path;
use super::connection_monitor;

fn load_policy() -> Result<PolicyConfig, String> {
    let path = xdg_config_path("policy.toml").ok_or("neither XDG_CONFIG_HOME nor HOME is set")?;
    load_policy_file(&path)
}

fn load_policy_file(path: &std::path::Path) -> Result<PolicyConfig, String> {
    if !path.exists() {
        return Ok(PolicyConfig::default());
    }
    load_from_path(path)
}

/// Opaque identity of the underlying session, independent of the fresh
/// PolicyGuard allocated for each request. It grants no database access.
#[derive(Debug, Clone)]
pub struct ConnectionIdentity(std::sync::Weak<dyn Connection>);

impl PartialEq for ConnectionIdentity {
    fn eq(&self, other: &Self) -> bool {
        self.0.ptr_eq(&other.0)
    }
}
impl Eq for ConnectionIdentity {}

pub(super) struct EntryInner {
    pub(super) connection: Arc<dyn Connection>,
    pub(super) tunnel: Option<Tunnel>,
    pub(super) health: ConnectionHealth,
    pub(super) audit_state: Arc<AuditState>,
}

#[derive(Debug, Clone)]
pub struct ConnectionMetadata {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
    pub environment: Environment,
    pub read_only: bool,
    pub server_version: Option<String>,
    pub query_timeout_secs: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionHealth {
    Healthy,
    Reconnecting { attempt: u32 },
    Failed { reason: String },
}

pub struct ReconnectParams {
    pub driver: Arc<dyn DatabaseDriver>,
    pub opts: ConnectOptions,
    pub ssh: Option<SshRoute>,
    pub environment: SshEnvironment,
}

/// Builds the same audited policy wrapper used by active connections for
/// connection bootstrap reads. A candidate is not registered yet, but its
/// metadata reads still belong to the durable audit journal.
#[derive(Clone)]
pub struct CandidateGuardFactory {
    policy: Arc<PolicyConfig>,
    approval: Arc<dyn tablepro_policy::ApprovalSink>,
    audit: Arc<dyn tablepro_policy::AuditSink>,
    audit_state: Arc<AuditState>,
}

impl CandidateGuardFactory {
    pub fn guard(
        &self,
        connection: Arc<dyn Connection>,
        metadata: &ConnectionMetadata,
        principal: Principal,
    ) -> PolicyGuard {
        PolicyGuard::new(
            connection,
            GuardContext {
                connection_id: metadata.id,
                connection_name: metadata.name.clone(),
                driver_id: metadata.driver_id.clone(),
                environment: metadata.environment,
                read_only: metadata.read_only,
                principal,
                policy: self.policy.clone(),
                approval: self.approval.clone(),
                audit: self.audit.clone(),
                audit_state: Arc::new(self.audit_state.new_connection_generation()),
            },
        )
    }
}

struct Entry {
    inner: Arc<Mutex<EntryInner>>,
    metadata: ConnectionMetadata,
    read_only: bool,
    environment: Environment,
    cancel: CancellationToken,
    fault: Arc<Notify>,
    _monitor: tokio::task::JoinHandle<()>,
}

/// A driver that panicked left the connection's protocol state
/// unverified, so the next statement on it cannot be trusted. Waking the
/// monitor replaces it instead of waiting for the ping interval to
/// notice, which it may not: a desynchronised connection can still
/// answer a ping.
struct EntryFaultSink {
    connection_id: Uuid,
    fault: Arc<Notify>,
}

impl tablepro_policy::ConnectionFaultSink for EntryFaultSink {
    fn connection_became_unusable(&self, operation: &str) {
        tracing::warn!(
            connection_id = %self.connection_id,
            operation,
            "driver stopped mid-operation; replacing the connection"
        );
        self.fault.notify_one();
    }
}

struct AuditRuntime {
    sink: Arc<dyn tablepro_policy::AuditSink>,
    available: bool,
    state: Arc<AuditState>,
}

impl AuditRuntime {
    fn open_default() -> Self {
        Self::from_journal(AuditJournal::open_default())
    }

    #[cfg(test)]
    fn open_path(path: std::path::PathBuf) -> Self {
        Self::from_journal(AuditJournal::open_validated(path))
    }

    fn from_journal(result: Result<AuditJournal, tablepro_storage::StorageError>) -> Self {
        match result {
            Ok(journal) => {
                let has_unresolved_writes = journal.recovery().has_unresolved_writes();
                if has_unresolved_writes {
                    tracing::error!(
                        operations = journal.recovery().unresolved_operation_ids().len(),
                        "unresolved audit operations detected; governed writes remain disabled"
                    );
                }
                let state = if has_unresolved_writes {
                    AuditState::with_governed_writes_disabled()
                } else {
                    AuditState::new()
                };
                Self {
                    sink: Arc::new(journal),
                    available: true,
                    state: Arc::new(state),
                }
            }
            Err(error) => {
                tracing::error!(%error, "audit journal unavailable; MCP and governed writes are disabled");
                Self::unavailable()
            }
        }
    }

    fn unavailable() -> Self {
        Self {
            sink: Arc::new(NullAuditSink),
            available: false,
            state: Arc::new(AuditState::with_governed_writes_disabled()),
        }
    }
}

pub struct DatabaseService {
    connections: Mutex<HashMap<Uuid, Entry>>,
    policy: Mutex<Arc<PolicyConfig>>,
    audit: Arc<dyn tablepro_policy::AuditSink>,
    audit_available: bool,
    policy_available: bool,
    audit_state: Arc<AuditState>,
    approval: Mutex<Arc<dyn tablepro_policy::ApprovalSink>>,
    ssh_environment: Mutex<SshEnvironment>,
    #[cfg(test)]
    _audit_temp_dir: Option<tempfile::TempDir>,
}

impl DatabaseService {
    pub fn new() -> Self {
        let audit = AuditRuntime::open_default();
        Self::with_audit(
            audit,
            #[cfg(test)]
            None,
        )
    }

    #[cfg(test)]
    pub(crate) fn new_isolated() -> Self {
        let audit_temp_dir = tempfile::tempdir().expect("temporary audit directory");
        let audit = AuditRuntime::open_path(audit_temp_dir.path().join("audit.jsonl"));
        Self::with_audit(audit, Some(audit_temp_dir))
    }

    fn with_audit(audit: AuditRuntime, #[cfg(test)] audit_temp_dir: Option<tempfile::TempDir>) -> Self {
        let (policy, policy_available) = match load_policy() {
            Ok(policy) => (Arc::new(policy), true),
            Err(error) => {
                tracing::error!(
                    error = %error,
                    "policy file could not be loaded; using defaults and disabling MCP"
                );
                (Arc::new(PolicyConfig::default()), false)
            }
        };
        Self {
            connections: Mutex::new(HashMap::new()),
            policy: Mutex::new(policy),
            audit: audit.sink,
            audit_available: audit.available,
            policy_available,
            audit_state: audit.state,
            approval: Mutex::new(Arc::new(DenyApprovalSink)),
            ssh_environment: Mutex::new(SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Refuse)),
            #[cfg(test)]
            _audit_temp_dir: audit_temp_dir,
        }
    }

    pub fn audit_available(&self) -> bool {
        self.audit_available
    }

    pub fn policy_available(&self) -> bool {
        self.policy_available
    }

    pub async fn audit_administrative_action(
        &self,
        operation_id: Uuid,
        action: AuditAdministrativeAction,
        phase: AuditRecordPhase,
        terminal_status: AuditTerminalStatus,
        affected_count: usize,
        duration_ms: Option<u64>,
    ) -> Result<(), tablepro_policy::AuditError> {
        let event = AuditEvent::administrative_action(
            operation_id,
            action,
            phase,
            terminal_status,
            affected_count,
            duration_ms,
        );
        match self.audit.record(event).await {
            Ok(()) => Ok(()),
            Err(error) => {
                self.audit_state.disable_after_audit_failure();
                Err(error)
            }
        }
    }

    /// Whether a prior governed operation has an unresolved outcome.  The UI
    /// uses this to stop a connection transition after cancelling running
    /// work: switching databases must not hide a newly ambiguous write.
    pub fn governed_writes_disabled(&self, id: Uuid) -> bool {
        if self.audit_state.governed_writes_disabled() {
            return true;
        }
        self.connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&id)
            .and_then(|entry| {
                entry
                    .inner
                    .lock()
                    .ok()
                    .map(|inner| inner.audit_state.governed_writes_disabled())
            })
            .unwrap_or(false)
    }

    pub fn ssh_environment(&self) -> SshEnvironment {
        self.ssh_environment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    pub fn ssh_environment_for_connection(
        &self,
        saved: &tablepro_storage::SavedConnection,
        principal: tablepro_policy::Principal,
    ) -> SshEnvironment {
        self.ssh_environment()
            .with_audit(tablepro_transport::TransportAuditContext::new(
                self.audit.clone(),
                self.audit_state.clone(),
                principal,
                saved.id,
                saved.name.clone(),
                saved.environment,
                saved.driver_id.clone(),
            ))
    }

    pub fn transport_audit_factory(&self) -> tablepro_transport::TransportAuditFactory {
        tablepro_transport::TransportAuditFactory::new(self.audit.clone(), self.audit_state.clone())
    }

    pub fn candidate_guard_factory(&self) -> CandidateGuardFactory {
        CandidateGuardFactory {
            policy: self
                .policy
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone(),
            approval: self
                .approval
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone(),
            audit: self.audit.clone(),
            audit_state: self.audit_state.clone(),
        }
    }

    pub fn enable_system_openssh(&self, openssh: OpenSshEnvironment) {
        self.ssh_environment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .openssh = Some(openssh);
    }

    pub fn enable_builtin_ssh_prompter(&self, prompter: Arc<dyn tablepro_ssh::openssh::Prompter>) {
        self.ssh_environment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .set_builtin_prompter(prompter);
    }

    pub fn set_approval_sink(&self, sink: Arc<dyn tablepro_policy::ApprovalSink>) {
        *self.approval.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = sink;
    }

    pub fn reload_policy(&self) -> Result<(), String> {
        let next = load_policy()?;
        *self.policy.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Arc::new(next);
        tracing::info!("policy reloaded");
        Ok(())
    }

    /// Whether some window already owns the saved connection `id`. Callers
    /// must check this before activating: two windows opening the same
    /// saved connection would otherwise silently overwrite each other's
    /// entry, so a caller that steals a live entry can leave the other
    /// window's connection handle answering for a session it no longer
    /// owns.
    pub fn is_active(&self, id: Uuid) -> bool {
        self.connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains_key(&id)
    }

    /// Register a fully validated connection and give it focus. Callers must
    /// prepare the connection before this method: activation itself does no
    /// I/O and is the final step of a connection switch. Activation is
    /// additive. A caller that means to replace a connection closes the
    /// previous one itself, so ownership is never dropped as a side effect
    /// of opening something else.
    ///
    /// Returns `false` without registering anything when `id` is already
    /// active. `connection` and `tunnel` are dropped in that case -- this
    /// consumes them either way, so refusal alone is enough to close them.
    #[cfg(test)]
    #[must_use]
    pub fn activate(
        &self,
        id: Uuid,
        metadata: ConnectionMetadata,
        connection: Box<dyn Connection>,
        tunnel: Option<Tunnel>,
        read_only: bool,
        params: ReconnectParams,
    ) -> bool {
        self.activate_shared(id, metadata, Arc::from(connection), tunnel, read_only, params)
    }

    pub(crate) fn activate_shared(
        &self,
        id: Uuid,
        metadata: ConnectionMetadata,
        connection: Arc<dyn Connection>,
        tunnel: Option<Tunnel>,
        read_only: bool,
        params: ReconnectParams,
    ) -> bool {
        let mut connections = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if connections.contains_key(&id) {
            return false;
        }
        let fault = Arc::new(Notify::new());
        connection.attach_fault_notify(Arc::clone(&fault));
        let arc = connection;
        let environment = metadata.environment;
        let inner = Arc::new(Mutex::new(EntryInner {
            connection: arc,
            tunnel,
            health: ConnectionHealth::Healthy,
            audit_state: Arc::new(self.audit_state.new_connection_generation()),
        }));
        let cancel = CancellationToken::new();
        let monitor = tokio::spawn(connection_monitor::run(
            inner.clone(),
            params,
            cancel.clone(),
            fault.clone(),
        ));
        let entry = Entry {
            inner,
            metadata,
            read_only,
            environment,
            cancel,
            fault,
            _monitor: monitor,
        };
        connections.insert(id, entry);
        true
    }

    pub fn metadata(&self, id: Uuid) -> Option<ConnectionMetadata> {
        let entries = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.get(&id).map(|e| e.metadata.clone())
    }

    pub fn all_connections(&self) -> Vec<ConnectionMetadata> {
        let entries = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut out: Vec<_> = entries.values().map(|e| e.metadata.clone()).collect();
        out.sort_by_key(|connection| connection.name.to_lowercase());
        out
    }

    /// Policy-gated handle. Raw connections are not exposed; the returned
    /// `Arc<dyn Connection>` is always a [`PolicyGuard`].
    pub fn handle(&self, id: Uuid, principal: Principal) -> Option<Arc<dyn Connection>> {
        self.handle_with_identity(id, principal).map(|(handle, _)| handle)
    }

    /// The same guarded handle as [`handle`], kept as its concrete type so
    /// a caller can open a scoped bulk insert on it. It is the same
    /// `PolicyGuard`; nothing here reaches the driver underneath.
    pub fn guard(&self, id: Uuid, principal: Principal) -> Option<Arc<PolicyGuard>> {
        self.guard_with_identity(id, principal)
            .map(|(guard, _)| Arc::new(guard))
    }

    fn handle_with_identity(
        &self,
        id: Uuid,
        principal: Principal,
    ) -> Option<(Arc<dyn Connection>, ConnectionIdentity)> {
        let (guard, identity) = self.guard_with_identity(id, principal)?;
        Some((Arc::new(guard) as Arc<dyn Connection>, identity))
    }

    fn guard_with_identity(&self, id: Uuid, principal: Principal) -> Option<(PolicyGuard, ConnectionIdentity)> {
        let entries = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries.get(&id)?;
        let inner = entry.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let policy = self
            .policy
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let approval = self
            .approval
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let ctx = GuardContext {
            connection_id: entry.metadata.id,
            connection_name: entry.metadata.name.clone(),
            driver_id: entry.metadata.driver_id.clone(),
            environment: entry.environment,
            read_only: entry.read_only,
            principal,
            policy,
            approval,
            audit: self.audit.clone(),
            audit_state: inner.audit_state.clone(),
        };
        let fault = Arc::new(EntryFaultSink {
            connection_id: entry.metadata.id,
            fault: entry.fault.clone(),
        });
        Some((
            PolicyGuard::new(inner.connection.clone(), ctx).with_fault_sink(fault),
            ConnectionIdentity(Arc::downgrade(&inner.connection)),
        ))
    }

    /// Alias for [`handle`] with the human GUI principal.
    pub fn get(&self, id: Uuid) -> Option<Arc<dyn Connection>> {
        self.handle(id, Principal::human_gui())
    }

    pub fn get_with_identity(&self, id: Uuid) -> Option<(Arc<dyn Connection>, ConnectionIdentity)> {
        self.handle_with_identity(id, Principal::human_gui())
    }

    pub fn identity(&self, id: Uuid) -> Option<ConnectionIdentity> {
        let entries = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries.get(&id)?;
        let inner = entry.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        Some(ConnectionIdentity(Arc::downgrade(&inner.connection)))
    }

    pub fn health(&self, id: Uuid) -> Option<ConnectionHealth> {
        let entries = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = entries.get(&id)?;
        let inner = entry.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        Some(inner.health.clone())
    }

    pub fn close(&self, id: Uuid) {
        let mut entries = self
            .connections
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(entry) = entries.remove(&id) {
            entry.cancel.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::DatabaseDriver;

    #[test]
    fn policy_file_is_read_from_the_build_profile_config_directory() {
        let path = xdg_config_path("policy.toml").unwrap();
        let expected = std::path::Path::new(crate::config::storage_dir_name()).join("policy.toml");
        assert!(path.ends_with(expected));
    }

    #[test]
    fn a_missing_policy_file_uses_defaults_and_an_invalid_one_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("policy.toml");
        assert!(load_policy_file(&path).is_ok());
        std::fs::write(&path, "[environments.nowhere]\n").unwrap();
        assert!(load_policy_file(&path).is_err());
    }

    #[test]
    fn separate_instances_do_not_share_connections() {
        let a = DatabaseService::new();
        let b = DatabaseService::new();
        let id = Uuid::new_v4();
        assert!(!a.is_active(id));
        assert!(!b.is_active(id));
    }

    #[test]
    fn unavailable_audit_runtime_disables_governed_writes() {
        let audit = AuditRuntime::unavailable();

        assert!(!audit.available);
        assert!(audit.state.governed_writes_disabled());
    }

    async fn open_memory_connection(service: &DatabaseService, name: &str) -> Uuid {
        let driver: Arc<dyn DatabaseDriver> = Arc::new(drivers_sqlite::SqliteDriver);
        let id = Uuid::new_v4();
        let options = ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        };
        let connection = driver.connect(options.clone()).await.expect("sqlite connection");
        let activated = service.activate(
            id,
            ConnectionMetadata {
                id,
                name: name.into(),
                driver_id: "sqlite".into(),
                environment: Environment::Local,
                read_only: false,
                server_version: None,
                query_timeout_secs: None,
            },
            connection,
            None,
            false,
            ReconnectParams {
                driver,
                opts: options,
                ssh: None,
                environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
            },
        );
        assert!(activated, "the id is freshly generated, so activation must succeed");
        id
    }

    #[tokio::test]
    async fn candidate_catalog_reads_use_the_durable_policy_audit_journal() {
        let service = DatabaseService::new_isolated();
        let driver: Arc<dyn DatabaseDriver> = Arc::new(drivers_sqlite::SqliteDriver);
        let connection: Arc<dyn Connection> = Arc::from(
            driver
                .connect(ConnectOptions {
                    database: ":memory:".into(),
                    ..Default::default()
                })
                .await
                .expect("sqlite connection"),
        );
        let metadata = ConnectionMetadata {
            id: Uuid::new_v4(),
            name: "candidate".into(),
            driver_id: "sqlite".into(),
            environment: Environment::Prod,
            read_only: true,
            server_version: None,
            query_timeout_secs: None,
        };
        let guard = service
            .candidate_guard_factory()
            .guard(connection, &metadata, Principal::human_gui());

        guard.list_tables().await.expect("guarded table listing");
        guard.list_views().await.expect("guarded view listing");

        let journal = service._audit_temp_dir.as_ref().unwrap().path().join("audit.jsonl");
        let lines = std::fs::read_to_string(journal).expect("audit journal exists");
        let events: Vec<serde_json::Value> = lines.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
        let metadata_events: Vec<_> = events
            .iter()
            .filter(|record| record["event"]["decision_rule"] == "metadata_read")
            .collect();
        assert_eq!(
            metadata_events.len(),
            4,
            "two metadata reads each have intent and outcome"
        );
        assert!(metadata_events.iter().all(|record| {
            record["event"]["connection_id"] == metadata.id.to_string()
                && record["event"]["connection_name"] == "candidate"
        }));
        let successful_outcomes = metadata_events
            .iter()
            .filter(|record| record["event"]["phase"] == "outcome" && record["event"]["terminal_status"] == "succeeded")
            .count();
        assert_eq!(successful_outcomes, 2);
    }

    #[tokio::test]
    async fn administrative_bundle_audit_writes_sanitized_intent_and_outcome_pair() {
        let service = DatabaseService::new_isolated();
        let operation_id = Uuid::new_v4();

        service
            .audit_administrative_action(
                operation_id,
                AuditAdministrativeAction::ConnectionBundleImport,
                AuditRecordPhase::Intent,
                AuditTerminalStatus::Pending,
                3,
                None,
            )
            .await
            .expect("durable administrative intent");
        service
            .audit_administrative_action(
                operation_id,
                AuditAdministrativeAction::ConnectionBundleImport,
                AuditRecordPhase::Outcome,
                AuditTerminalStatus::Succeeded,
                3,
                Some(12),
            )
            .await
            .expect("durable administrative outcome");

        let journal = service._audit_temp_dir.as_ref().unwrap().path().join("audit.jsonl");
        let contents = std::fs::read_to_string(journal).expect("audit journal exists");
        let records: Vec<serde_json::Value> = contents
            .lines()
            .map(|line| serde_json::from_str(line).expect("journal record is valid JSON"))
            .collect();
        assert_eq!(records.len(), 2);
        for (record, phase) in records.iter().zip(["intent", "outcome"]) {
            let event = &record["event"];
            assert_eq!(event["operation_id"], operation_id.to_string());
            assert_eq!(event["phase"], phase);
            assert_eq!(event["operation_class"], "administrative");
            assert_eq!(event["connection_id"], Uuid::nil().to_string());
            assert_eq!(event["connection_name"], "local_settings");
            assert_eq!(event["driver_id"], "bookie");
            assert_eq!(event["administrative_action"]["action"], "connection_bundle_import");
            assert_eq!(event["administrative_action"]["affected_count"], 3);
            assert!(event.get("transport_attempt").is_none_or(serde_json::Value::is_null));
            let encoded = event.to_string();
            for forbidden in ["/tmp/private-bundle", "connection-secret", "private-key-material"] {
                assert!(!encoded.contains(forbidden));
            }
        }
        assert_eq!(records[1]["event"]["terminal_status"], "succeeded");
    }

    #[tokio::test]
    async fn administrative_bundle_intent_fails_closed_when_audit_is_unavailable() {
        let audit_dir = tempfile::tempdir().expect("audit temp dir");
        let service = DatabaseService::with_audit(AuditRuntime::unavailable(), Some(audit_dir));

        let result = service
            .audit_administrative_action(
                Uuid::new_v4(),
                AuditAdministrativeAction::ConnectionBundleExport,
                AuditRecordPhase::Intent,
                AuditTerminalStatus::Pending,
                1,
                None,
            )
            .await;

        assert!(result.is_err());
        assert!(service.audit_state.governed_writes_disabled());
    }

    #[tokio::test]
    async fn candidate_metadata_read_refuses_when_its_audit_intent_cannot_be_written() {
        let audit_dir = tempfile::tempdir().expect("audit temp dir");
        let service = DatabaseService::with_audit(AuditRuntime::unavailable(), Some(audit_dir));
        let driver: Arc<dyn DatabaseDriver> = Arc::new(drivers_sqlite::SqliteDriver);
        let connection: Arc<dyn Connection> = Arc::from(
            driver
                .connect(ConnectOptions {
                    database: ":memory:".into(),
                    ..Default::default()
                })
                .await
                .expect("sqlite connection"),
        );
        let metadata = ConnectionMetadata {
            id: Uuid::new_v4(),
            name: "candidate".into(),
            driver_id: "sqlite".into(),
            environment: Environment::Prod,
            read_only: true,
            server_version: None,
            query_timeout_secs: None,
        };
        let guard = service
            .candidate_guard_factory()
            .guard(connection, &metadata, Principal::human_gui());

        let result = guard.list_tables().await;
        assert!(matches!(result, Err(tablepro_core::DriverError::PolicyDenied(_))));
    }

    #[tokio::test]
    async fn activation_is_additive_and_keeps_earlier_connections() {
        let service = DatabaseService::new();

        let first = open_memory_connection(&service, "first").await;
        assert_eq!(service.all_connections().len(), 1);

        let second = open_memory_connection(&service, "second").await;
        assert_eq!(service.all_connections().len(), 2);
        assert!(service.handle(first, Principal::human_gui()).is_some());
        assert!(service.handle(second, Principal::human_gui()).is_some());
    }

    #[tokio::test]
    async fn a_disabled_connection_does_not_block_writes_on_its_sibling() {
        let service = DatabaseService::new_isolated();
        let first = open_memory_connection(&service, "first").await;
        let second = open_memory_connection(&service, "second").await;
        let first_inner = service.connections.lock().unwrap().get(&first).unwrap().inner.clone();
        first_inner.lock().unwrap().audit_state = Arc::new(AuditState::with_governed_writes_disabled());

        assert!(service.governed_writes_disabled(first));
        assert!(!service.governed_writes_disabled(second));

        service.close(first);
        service.close(second);
    }

    /// H3: two windows opening the same saved connection must not let the
    /// second one silently steal the first's entry. Before this fix,
    /// `connections.insert(id, entry)` always overwrote, so window A's
    /// connection handle would silently start answering for window B's
    /// session, and A's original entry (and its reconnect-monitor task)
    /// leaked with no cancellation.
    #[tokio::test]
    async fn a_second_window_cannot_steal_an_already_active_connection() {
        let service = DatabaseService::new();
        let id = Uuid::new_v4();
        let driver: Arc<dyn DatabaseDriver> = Arc::new(drivers_sqlite::SqliteDriver);
        let options = ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        };
        let first_metadata = ConnectionMetadata {
            id,
            name: "window A".into(),
            driver_id: "sqlite".into(),
            environment: Environment::Local,
            read_only: false,
            server_version: None,
            query_timeout_secs: None,
        };
        let first_conn = driver.connect(options.clone()).await.expect("sqlite connection");
        assert!(service.activate(
            id,
            first_metadata,
            first_conn,
            None,
            false,
            ReconnectParams {
                driver: driver.clone(),
                opts: options.clone(),
                ssh: None,
                environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
            },
        ));

        let second_metadata = ConnectionMetadata {
            id,
            name: "window B".into(),
            driver_id: "sqlite".into(),
            environment: Environment::Local,
            read_only: false,
            server_version: None,
            query_timeout_secs: None,
        };
        let second_conn = driver.connect(options.clone()).await.expect("sqlite connection");
        let activated = service.activate(
            id,
            second_metadata,
            second_conn,
            None,
            false,
            ReconnectParams {
                driver,
                opts: options,
                ssh: None,
                environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
            },
        );

        assert!(
            !activated,
            "a second window must not overwrite the first window's entry"
        );
        assert_eq!(
            service.metadata(id).map(|m| m.name),
            Some("window A".into()),
            "window A's entry must survive the refused activation untouched"
        );
        assert!(service.is_active(id));
    }

    #[tokio::test]
    async fn closing_one_connection_leaves_every_other_connection_usable() {
        let service = DatabaseService::new();
        let first = open_memory_connection(&service, "first").await;
        let second = open_memory_connection(&service, "second").await;

        service.close(second);

        assert_eq!(service.all_connections().len(), 1);
        assert!(service.handle(second, Principal::human_gui()).is_none());
        let survivor = service.handle(first, Principal::human_gui()).expect("first survives");
        survivor.ping().await.expect("the surviving connection still answers");
    }

    #[tokio::test]
    async fn each_connection_keeps_its_own_metadata() {
        let service = DatabaseService::new();
        let first = open_memory_connection(&service, "first").await;
        let second = open_memory_connection(&service, "second").await;

        assert_eq!(service.metadata(first).map(|m| m.name), Some("first".to_string()));
        assert_eq!(service.metadata(second).map(|m| m.name), Some("second".to_string()));

        service.close(first);

        assert!(service.metadata(first).is_none());
        assert_eq!(service.metadata(second).map(|m| m.name), Some("second".to_string()));
    }
    #[tokio::test]
    async fn session_identity_survives_new_guards_but_changes_on_reconnect() {
        let service = DatabaseService::new();
        let id = open_memory_connection(&service, "identity").await;
        let (first_guard, first) = service.get_with_identity(id).unwrap();
        let (second_guard, second) = service.get_with_identity(id).unwrap();
        assert!(!Arc::ptr_eq(&first_guard, &second_guard));
        assert_eq!(first, second);
        let origin = crate::services::catalog::CatalogOrigin {
            id,
            identity: first.clone(),
        };
        assert!(origin.matches(Some(id), Some(&second)));
        assert!(!origin.matches(Some(Uuid::new_v4()), Some(&second)));
        let mut index = crate::ui::SchemaIndex::default();
        assert!(index.sync_connection(&first));
        index.set_columns("items", vec!["id".into()]);
        let request = index.request("items".into());
        assert!(!index.sync_connection(&second));
        assert!(index.knows_columns("items"));
        assert!(index.accepts(&request));
        let replacement = drivers_sqlite::SqliteDriver
            .connect(ConnectOptions {
                database: ":memory:".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        {
            let entries = service.connections.lock().unwrap();
            entries.get(&id).unwrap().inner.lock().unwrap().connection = Arc::from(replacement);
        }
        let current = service.identity(id).unwrap();
        assert_ne!(first, current);
        assert!(!origin.matches(Some(id), Some(&current)));
        assert!(index.sync_connection(&current));
        assert!(!index.accepts(&request));
        service.close(id);
        assert!(service.identity(id).is_none());
        assert!(!origin.matches(Some(id), None));
    }
}
