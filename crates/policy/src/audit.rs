use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tablepro_core::Environment;
use thiserror::Error;
use uuid::Uuid;

use crate::classify::StatementClass;
use crate::principal::Principal;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AuditError {
    #[error("audit sink is unavailable: {0}")]
    Unavailable(String),
    #[error("audit record could not be persisted: {0}")]
    Persistence(String),
    #[error("audit journal is corrupt: {0}")]
    Corrupt(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditRecordPhase {
    Intent,
    Outcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditOperationClass {
    Read,
    Mutation,
    Ddl,
    Administrative,
    TransactionCommit,
    TransactionRollback,
    UnknownWrite,
}

impl AuditOperationClass {
    pub fn from_statement(class: StatementClass, writes: bool) -> Self {
        match class {
            StatementClass::Select if !writes => Self::Read,
            StatementClass::Insert | StatementClass::Update | StatementClass::Delete => Self::Mutation,
            StatementClass::Ddl => Self::Ddl,
            StatementClass::Administrative => Self::Administrative,
            StatementClass::Transaction if !writes => Self::Read,
            StatementClass::Other | StatementClass::Unparseable if writes => Self::UnknownWrite,
            _ if writes => Self::UnknownWrite,
            _ => Self::Read,
        }
    }

    pub fn is_write(self) -> bool {
        !matches!(self, Self::Read)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditApprovalOutcome {
    NotRequired,
    Approved,
    Denied,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "state", content = "detail")]
pub enum AuditPreviewState {
    NotRequested,
    Available(String),
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditTerminalStatus {
    Pending,
    Succeeded,
    Failed,
    Denied,
    Cancelled,
    TimedOut,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditTransactionOutcome {
    NotApplicable,
    Pending,
    Committed,
    RolledBack,
    Failed,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditErrorCategory {
    Policy,
    Audit,
    Connection,
    Authentication,
    Tls,
    Query,
    ReadOnly,
    Unsupported,
    Internal,
    Transaction,
    Cancelled,
    Timeout,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditTransportClient {
    BuiltinSsh,
    SystemOpenSsh,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditTransportOutcome {
    Connected,
    HostKeyRefused,
    HostKeyChanged,
    HostKeyRevoked,
    AuthenticationFailed,
    Cancelled,
    TimedOut,
    TlsFailed,
    ConnectionFailed,
    OtherFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditTransportMetadata {
    pub client: AuditTransportClient,
    pub outcome: AuditTransportOutcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditAdministrativeAction {
    ConnectionBundleExport,
    ConnectionBundleImport,
}

impl AuditAdministrativeAction {
    fn code(self) -> &'static str {
        match self {
            Self::ConnectionBundleExport => "connection_bundle_export",
            Self::ConnectionBundleImport => "connection_bundle_import",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditAdministrativeMetadata {
    pub action: AuditAdministrativeAction,
    pub affected_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEvent {
    pub timestamp: DateTime<Utc>,
    pub operation_id: Uuid,
    pub batch_id: Option<Uuid>,
    pub phase: AuditRecordPhase,
    pub principal: Principal,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub environment: Environment,
    pub driver_id: String,
    pub operation_class: AuditOperationClass,
    pub redacted_sql: String,
    pub sql_hash: String,
    pub targets: Vec<String>,
    pub decision_rule: String,
    pub approval_outcome: AuditApprovalOutcome,
    pub preview_state: AuditPreviewState,
    pub terminal_status: AuditTerminalStatus,
    pub transaction_outcome: AuditTransactionOutcome,
    pub error_category: Option<AuditErrorCategory>,
    pub error: Option<String>,
    pub rows_affected: Option<u64>,
    pub duration_ms: Option<u64>,
    /// Present only for a terminal SSH connection-attempt record. Missing on
    /// older journals; ignored by older readers, so the journal wire format
    /// remains forward compatible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport_attempt: Option<AuditTransportMetadata>,
    /// Present only for process-wide administrative operations. These use a
    /// nil `connection_id` and deliberately omit paths, connection names and
    /// credential material.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub administrative_action: Option<AuditAdministrativeMetadata>,
}

impl AuditEvent {
    pub fn administrative_action(
        operation_id: Uuid,
        action: AuditAdministrativeAction,
        phase: AuditRecordPhase,
        terminal_status: AuditTerminalStatus,
        affected_count: usize,
        duration_ms: Option<u64>,
    ) -> Self {
        Self {
            timestamp: chrono::Utc::now(),
            operation_id,
            batch_id: None,
            phase,
            principal: Principal::human_gui(),
            connection_id: Uuid::nil(),
            connection_name: "local_settings".into(),
            environment: Environment::Local,
            driver_id: "bookie".into(),
            operation_class: AuditOperationClass::Administrative,
            redacted_sql: "[NOT_APPLICABLE]".into(),
            sql_hash: hex::encode(Sha256::digest(action.code().as_bytes())),
            targets: Vec::new(),
            decision_rule: action.code().into(),
            approval_outcome: AuditApprovalOutcome::NotRequired,
            preview_state: AuditPreviewState::NotRequested,
            terminal_status,
            transaction_outcome: AuditTransactionOutcome::NotApplicable,
            error_category: None,
            error: None,
            rows_affected: None,
            duration_ms,
            transport_attempt: None,
            administrative_action: Some(AuditAdministrativeMetadata {
                action,
                affected_count: affected_count.min(u64::MAX as usize) as u64,
            }),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn transport_attempt(
        operation_id: Uuid,
        principal: Principal,
        connection_id: Uuid,
        connection_name: String,
        environment: Environment,
        driver_id: String,
        client: AuditTransportClient,
        outcome: AuditTransportOutcome,
        terminal_status: AuditTerminalStatus,
        error_category: Option<AuditErrorCategory>,
        duration_ms: u64,
    ) -> Self {
        Self {
            timestamp: chrono::Utc::now(),
            operation_id,
            batch_id: None,
            phase: AuditRecordPhase::Outcome,
            principal: principal.sanitized(),
            connection_id,
            connection_name,
            environment,
            driver_id,
            operation_class: AuditOperationClass::Administrative,
            redacted_sql: "[NOT_APPLICABLE]".into(),
            sql_hash: hex::encode(Sha256::digest(b"transport_attempt")),
            targets: Vec::new(),
            decision_rule: "transport_attempt".into(),
            approval_outcome: AuditApprovalOutcome::NotRequired,
            preview_state: AuditPreviewState::NotRequested,
            terminal_status,
            transaction_outcome: AuditTransactionOutcome::NotApplicable,
            error_category,
            error: error_category.map(sanitized_transport_error),
            rows_affected: None,
            duration_ms: Some(duration_ms),
            transport_attempt: Some(AuditTransportMetadata { client, outcome }),
            administrative_action: None,
        }
    }
}

fn sanitized_transport_error(category: AuditErrorCategory) -> String {
    match category {
        AuditErrorCategory::Authentication => "ssh_host_key_or_authentication_refused",
        AuditErrorCategory::Cancelled => "connection_attempt_cancelled",
        AuditErrorCategory::Timeout => "connection_attempt_timed_out",
        AuditErrorCategory::Tls => "tls_verification_failed",
        AuditErrorCategory::Connection => "transport_connection_failed",
        AuditErrorCategory::Unsupported => "transport_unsupported",
        _ => "transport_attempt_failed",
    }
    .into()
}

#[async_trait]
pub trait AuditSink: Send + Sync {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError>;
}

pub struct NullAuditSink;

#[async_trait]
impl AuditSink for NullAuditSink {
    async fn record(&self, _event: AuditEvent) -> Result<(), AuditError> {
        Err(AuditError::Unavailable("no audit sink configured".into()))
    }
}

#[derive(Debug, Default)]
pub struct AuditState {
    globally_disabled: std::sync::Arc<AtomicBool>,
    connection_uncertain: AtomicBool,
}

impl AuditState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_governed_writes_disabled() -> Self {
        let state = Self::new();
        state.disable_globally();
        state
    }

    pub fn governed_writes_disabled(&self) -> bool {
        self.globally_disabled.load(Ordering::Acquire) || self.connection_uncertain.load(Ordering::Acquire)
    }

    pub(crate) fn disable_governed_writes(&self) {
        self.connection_uncertain.store(true, Ordering::Release);
    }

    pub(crate) fn disable_globally(&self) {
        self.globally_disabled.store(true, Ordering::Release);
    }

    /// Fail closed after an audit record cannot be persisted outside a guarded operation.
    pub fn disable_after_audit_failure(&self) {
        self.disable_globally();
    }

    /// Share journal-wide failure state with a clean connection generation.
    /// Call only after establishing a replacement connection; old guards keep
    /// their original state and cannot disable the replacement later.
    pub fn new_connection_generation(&self) -> Self {
        Self {
            globally_disabled: self.globally_disabled.clone(),
            connection_uncertain: AtomicBool::new(false),
        }
    }

    pub(crate) fn pending_write(&self) -> PendingWrite<'_> {
        PendingWrite {
            state: self,
            armed: true,
        }
    }
}

pub(crate) struct PendingWrite<'a> {
    state: &'a AuditState,
    armed: bool,
}

impl PendingWrite<'_> {
    pub(crate) fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for PendingWrite<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.state.disable_governed_writes();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uncertainty_is_scoped_to_a_connection_generation_but_journal_failure_is_global() {
        let journal = AuditState::new();
        let connection_a = journal.new_connection_generation();
        let connection_b = journal.new_connection_generation();

        connection_a.disable_governed_writes();
        assert!(connection_a.governed_writes_disabled());
        assert!(!connection_b.governed_writes_disabled());

        let replacement_a = connection_a.new_connection_generation();
        connection_a.disable_governed_writes(); // A late callback from the retired generation.
        assert!(!replacement_a.governed_writes_disabled());

        journal.disable_globally();
        assert!(connection_b.governed_writes_disabled());
        assert!(replacement_a.governed_writes_disabled());
    }

    #[test]
    fn transport_records_are_terminal_and_older_records_without_transport_metadata_load() {
        let event = AuditEvent::transport_attempt(
            Uuid::new_v4(),
            Principal::human_gui(),
            Uuid::new_v4(),
            "local db".into(),
            Environment::Local,
            "postgres".into(),
            AuditTransportClient::BuiltinSsh,
            AuditTransportOutcome::Connected,
            AuditTerminalStatus::Succeeded,
            None,
            4,
        );
        assert_eq!(event.phase, AuditRecordPhase::Outcome);
        assert_eq!(
            event.transport_attempt.unwrap().client,
            AuditTransportClient::BuiltinSsh
        );
        let mut old_record = serde_json::to_value(event).expect("serialize event");
        old_record
            .as_object_mut()
            .expect("event object")
            .remove("transport_attempt");
        let decoded: AuditEvent = serde_json::from_value(old_record).expect("load old journal record");
        assert!(decoded.transport_attempt.is_none());
    }

    #[test]
    fn administrative_audit_metadata_is_aggregate_and_backward_compatible() {
        let event = AuditEvent::administrative_action(
            Uuid::new_v4(),
            AuditAdministrativeAction::ConnectionBundleImport,
            AuditRecordPhase::Outcome,
            AuditTerminalStatus::Succeeded,
            3,
            Some(12),
        );
        assert_eq!(event.connection_id, Uuid::nil());
        assert_eq!(event.operation_class, AuditOperationClass::Administrative);
        assert_eq!(event.rows_affected, None);
        assert_eq!(
            event.administrative_action,
            Some(AuditAdministrativeMetadata {
                action: AuditAdministrativeAction::ConnectionBundleImport,
                affected_count: 3,
            })
        );

        let mut older = serde_json::to_value(event).expect("serialize event");
        older
            .as_object_mut()
            .expect("event object")
            .remove("administrative_action");
        let decoded: AuditEvent = serde_json::from_value(older).expect("load record without admin metadata");
        assert!(decoded.administrative_action.is_none());
    }

    #[test]
    fn sanitized_agent_principal_does_not_retain_its_token() {
        let secret = "agent-token-do-not-log";
        let principal = Principal::Agent {
            token: secret.into(),
            client: None,
            model: None,
        }
        .sanitized();
        assert!(
            !serde_json::to_string(&principal)
                .expect("serialize principal")
                .contains(secret)
        );
    }
}
