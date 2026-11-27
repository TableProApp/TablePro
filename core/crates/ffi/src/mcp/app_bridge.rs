use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tablepro_core::dialect::SqlDialect;
use tablepro_mcp::{McpHost, OpenOutcome, WriteApproval};
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;
use tablepro_storage::query_history::NewEntry;
use tablepro_storage::{ConnectionStore, SavedConnection, StoragePaths};
use tokio::sync::OnceCell;
use uuid::Uuid;

use crate::history::QueryHistoryStore;
use crate::mcp::open_sessions::OpenSessions;

// Long enough for a saved password and the server's answer, short enough for a client, as on Linux.
const OPEN_WAIT: Duration = Duration::from_secs(10);
const OPEN_POLL: Duration = Duration::from_millis(200);

// The core calls each on a thread it lets block, so the app may wait on its UI thread for the answer.
#[uniffi::export(callback_interface)]
pub trait McpAppHost: Send + Sync {
    // As Connect opens it; false when the app will not, as for a workspace whose connect failed.
    fn open_connection(&self, connection_id: String) -> bool;

    // A connect of it is in flight, or waits for the user in its workspace: a password, a host key.
    fn is_connecting(&self, connection_id: String) -> bool;

    // Asked in the connection's window; false when the window is gone, and once `withdraw` names the request.
    fn approve(&self, request: McpWriteRequest) -> bool;

    // The client went away, so its question comes down unanswered.
    fn withdraw(&self, request_id: u64);
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct McpWriteRequest {
    pub id: u64,
    pub connection_id: String,
    pub connection_name: String,
    // Another of the server's databases the app has open beside the connection; None for the connection's own.
    pub database: Option<String>,
    pub sql: String,
    // Drops, empties or rewrites a whole table.
    pub destructive: bool,
}

pub(crate) struct AppBridge {
    pub(crate) app: Arc<dyn McpAppHost>,
    pub(crate) sessions: Arc<OpenSessions>,
    pub(crate) tasks: Tasks,
    pub(crate) history: HistoryAccess,
    pub(crate) requests: AtomicU64,
    pub(crate) project: ActiveProject,
}

// The project the app shows, which the app sets on each switch and every tool call reads.
#[derive(Clone, Default)]
pub(crate) struct ActiveProject(Arc<Mutex<Option<Uuid>>>);

impl ActiveProject {
    pub(crate) fn get(&self) -> Option<Uuid> {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn set(&self, project: Option<Uuid>) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = project;
    }
}

// The core's one history store, opened by whichever of the app and the server reads it first.
#[derive(Clone)]
pub(crate) struct HistoryAccess {
    pub(crate) paths: Option<StoragePaths>,
    pub(crate) store: Arc<OnceCell<Arc<QueryHistoryStore>>>,
    pub(crate) connections: Option<ConnectionStore>,
}

impl AppBridge {
    async fn ask<T: Send + 'static>(&self, call: impl FnOnce(&dyn McpAppHost) -> T + Send + 'static) -> Option<T> {
        let app = self.app.clone();
        match self.tasks.spawn_blocking_task(move || call(app.as_ref())).await {
            Ok(answer) => Some(answer),
            Err(failure) => {
                tracing::warn!(%failure, "the app's answer to the MCP server failed");
                None
            }
        }
    }
}

#[async_trait]
impl McpHost for AppBridge {
    async fn session(&self, id: Uuid) -> Option<Arc<Session>> {
        self.sessions.get(id, None)
    }

    // Only a database the app opened beside the connection; a client never opens one.
    async fn session_in(&self, id: Uuid, database: &str) -> Option<Arc<Session>> {
        self.sessions.get(id, Some(database))
    }

    async fn open_connections(&self) -> Vec<Uuid> {
        self.sessions.ids()
    }

    async fn open(&self, connection: SavedConnection) -> OpenOutcome {
        let id = connection.id;
        if let Some(session) = self.sessions.get(id, None) {
            return OpenOutcome::Open(session);
        }
        if !self
            .ask(move |app| app.open_connection(id.to_string()))
            .await
            .unwrap_or(false)
        {
            return OpenOutcome::Closed;
        }
        let deadline = Instant::now() + OPEN_WAIT;
        loop {
            if let Some(session) = self.sessions.get(id, None) {
                return OpenOutcome::Open(session);
            }
            let connecting = self
                .ask(move |app| app.is_connecting(id.to_string()))
                .await
                .unwrap_or(false);
            if !connecting {
                // The connect may have ended with a session between the two looks.
                return self
                    .sessions
                    .get(id, None)
                    .map_or(OpenOutcome::Closed, OpenOutcome::Open);
            }
            if Instant::now() >= deadline {
                return OpenOutcome::Connecting;
            }
            tokio::time::sleep(OPEN_POLL).await;
        }
    }

    async fn approve(&self, approval: WriteApproval) -> bool {
        if approval.cancel.is_cancelled() {
            return false;
        }
        let id = self.requests.fetch_add(1, Ordering::Relaxed);
        let request = McpWriteRequest {
            id,
            connection_id: approval.connection_id.to_string(),
            connection_name: approval.connection_name,
            database: approval.database,
            sql: approval.sql,
            destructive: approval.destructive,
        };
        let asking = self.ask(move |app| app.approve(request));
        // The question is handed over first, so the app hears of every withdrawal after its question, never alone.
        tokio::select! {
            biased;
            answer = asking => answer.unwrap_or(false),
            () = approval.cancel.cancelled() => {
                // The question's own call ends once the app has taken it down.
                let app = self.app.clone();
                drop(self.tasks.spawn_blocking_task(move || app.withdraw(id)));
                false
            }
        }
    }

    fn active_project(&self) -> Option<Uuid> {
        self.project.get()
    }

    async fn record(&self, entry: NewEntry, dialect: Arc<dyn SqlDialect>) {
        if let Some(store) = self.history.store(&self.tasks).await {
            store.record_entry(entry, dialect).await;
        }
    }
}

impl HistoryAccess {
    async fn store(&self, tasks: &Tasks) -> Option<Arc<QueryHistoryStore>> {
        let paths = self.paths.clone()?;
        let tasks = tasks.clone();
        let connections = self.connections.clone();
        match self
            .store
            .get_or_try_init(|| QueryHistoryStore::open(paths, tasks, connections))
            .await
        {
            Ok(store) => Some(store.clone()),
            Err(error) => {
                tracing::warn!(%error, "could not open the query history for an MCP client's statement");
                None
            }
        }
    }
}
