use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use tablepro_core::dialect::SqlDialect;
use tablepro_mcp::{McpHost, OpenOutcome, WriteApproval};
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;
use tablepro_storage::SavedConnection;
use tablepro_storage::query_history::NewEntry;
use uuid::Uuid;

// Asked in the assistant pane, on a thread the core lets block. Model B in ADR 0014:
// the in-app agent surfaces its write approvals here, not in the connection window.
#[uniffi::export(callback_interface)]
pub trait AiApprover: Send + Sync {
    fn approve(&self, request: AiWriteRequest) -> bool;

    // The reply ended before the question was answered, so its card comes down.
    fn withdraw(&self, request_id: u64);
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiWriteRequest {
    pub id: u64,
    pub connection_id: String,
    pub connection_name: String,
    // Another of the server's databases open beside the connection; None for its own.
    pub database: Option<String>,
    pub sql: String,
    // Drops, empties or rewrites a whole table.
    pub destructive: bool,
}

// The agent's tool host: the app's MCP bridge for every call, except a write's approval, which the
// agent routes to the assistant pane so the gate logic in execute_query stays the one home for it.
pub(crate) struct AgentHost {
    inner: Arc<dyn McpHost>,
    approver: Arc<dyn AiApprover>,
    tasks: Tasks,
    requests: AtomicU64,
}

impl AgentHost {
    pub(crate) fn new(inner: Arc<dyn McpHost>, approver: Arc<dyn AiApprover>, tasks: Tasks) -> Self {
        Self {
            inner,
            approver,
            tasks,
            requests: AtomicU64::new(1),
        }
    }
}

#[async_trait]
impl McpHost for AgentHost {
    async fn session(&self, id: Uuid) -> Option<Arc<Session>> {
        self.inner.session(id).await
    }

    async fn session_in(&self, id: Uuid, database: &str) -> Option<Arc<Session>> {
        self.inner.session_in(id, database).await
    }

    async fn open_connections(&self) -> Vec<Uuid> {
        self.inner.open_connections().await
    }

    fn active_project(&self) -> Option<Uuid> {
        self.inner.active_project()
    }

    async fn open(&self, connection: SavedConnection) -> OpenOutcome {
        self.inner.open(connection).await
    }

    async fn approve(&self, approval: WriteApproval) -> bool {
        if approval.cancel.is_cancelled() {
            return false;
        }
        let id = self.requests.fetch_add(1, Ordering::Relaxed);
        let request = AiWriteRequest {
            id,
            connection_id: approval.connection_id.to_string(),
            connection_name: approval.connection_name,
            database: approval.database,
            sql: approval.sql,
            destructive: approval.destructive,
        };
        let approver = self.approver.clone();
        let asking = {
            let approver = approver.clone();
            self.tasks.spawn_blocking_task(move || approver.approve(request))
        };
        tokio::select! {
            biased;
            answer = asking => answer.unwrap_or(false),
            () = approval.cancel.cancelled() => {
                // The question is taken down in the pane; its own blocking call then returns, ignored.
                drop(self.tasks.spawn_blocking_task(move || approver.withdraw(id)));
                false
            }
        }
    }

    async fn record(&self, entry: NewEntry, dialect: Arc<dyn SqlDialect>) {
        self.inner.record(entry, dialect).await;
    }
}
