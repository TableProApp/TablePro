use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::dialect::SqlDialect;
use tablepro_session::Session;
use tablepro_storage::SavedConnection;
use tablepro_storage::query_history::NewEntry;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// What the server needs from the app. Sessions belong to windows, so
/// the server reaches a connection only through the window that has it
/// open, and asks the user only through the app.
#[async_trait]
pub trait McpHost: Send + Sync + 'static {
    /// The session of the window that has this saved connection open.
    async fn session(&self, id: Uuid) -> Option<Arc<Session>>;

    /// Which saved connections a window has open.
    async fn open_connections(&self) -> Vec<Uuid>;

    /// Open the saved connection in a window, as the picker does, and
    /// wait a while for its session.
    async fn open(&self, connection: SavedConnection) -> OpenOutcome;

    /// Ask the user, in the window of the connection, whether a client's
    /// write may run. False when they decline, when the window is gone,
    /// and when `approval.cancel` fires first.
    async fn approve(&self, approval: WriteApproval) -> bool;

    /// Put a statement a client ran in the query history, under the same
    /// rules as the editor's runs.
    async fn record(&self, entry: NewEntry, dialect: Arc<dyn SqlDialect>);
}

pub enum OpenOutcome {
    Open(Arc<Session>),
    /// Still connecting, or waiting for the user in its window: a
    /// password, a host key or a file.
    Connecting,
    /// The connect failed or the user stopped it.
    Closed,
}

impl std::fmt::Debug for OpenOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Open(session) => f.debug_tuple("Open").field(&session.id()).finish(),
            Self::Connecting => f.write_str("Connecting"),
            Self::Closed => f.write_str("Closed"),
        }
    }
}

/// A write a client asked for, as the user is asked about it.
#[derive(Debug, Clone)]
pub struct WriteApproval {
    pub connection_id: Uuid,
    pub connection_name: String,
    pub sql: String,
    /// Drops, empties or rewrites a whole table.
    pub destructive: bool,
    /// Fires when the client goes away, which takes the question down.
    pub cancel: CancellationToken,
}
