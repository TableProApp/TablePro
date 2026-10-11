use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::classify::StatementFacts;
use crate::principal::Principal;
use tablepro_core::Environment;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalRequest {
    pub principal: Principal,
    pub environment: Environment,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub sql: String,
    pub facts: StatementFacts,
    pub rule: String,
    pub reason: String,
    pub preview: Option<String>,
    pub estimated_rows: Option<u64>,
    /// Runtime-only cancellation scope for interactive approval UI.
    #[serde(skip)]
    pub cancellation: Option<CancellationToken>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalOutcome {
    AllowOnce,
    Deny,
}

#[async_trait]
pub trait ApprovalSink: Send + Sync {
    async fn request(&self, req: ApprovalRequest) -> ApprovalOutcome;
}

/// Always allows. Tests may use this to isolate policy decisions from UI.
pub struct AutoApproveSink;

#[async_trait]
impl ApprovalSink for AutoApproveSink {
    async fn request(&self, _req: ApprovalRequest) -> ApprovalOutcome {
        ApprovalOutcome::AllowOnce
    }
}

/// Always denies RequireApproval. Default for headless agentd without a
/// configured interactive strategy.
pub struct DenyApprovalSink;

#[async_trait]
impl ApprovalSink for DenyApprovalSink {
    async fn request(&self, _req: ApprovalRequest) -> ApprovalOutcome {
        ApprovalOutcome::Deny
    }
}
