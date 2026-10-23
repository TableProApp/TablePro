use std::sync::Arc;

use tablepro_session::Session;
use tablepro_storage::{ConnectionListState, ConnectionStore, SavedConnection};
use uuid::Uuid;

use crate::mcp_host::McpHost;
use crate::tool_error::ToolError;

/// What every tool reads: the saved connections as the store holds them
/// now, and the app.
#[derive(Clone)]
pub struct ToolContext {
    pub host: Arc<dyn McpHost>,
    pub connections: ConnectionStore,
}

impl ToolContext {
    /// Every saved connection a client may know about. A blocked one is
    /// left out, as if it did not exist.
    pub fn visible_connections(&self) -> Result<Vec<SavedConnection>, ToolError> {
        match self.connections.snapshot().state {
            ConnectionListState::Ready(list) => Ok(list
                .iter()
                .filter(|connection| !connection.external_access.is_blocked())
                .cloned()
                .collect()),
            ConnectionListState::Loading => Err(ToolError::Internal(
                "TablePro is still reading the saved connections; try again in a moment".to_owned(),
            )),
            ConnectionListState::Unavailable(_) => Err(ToolError::Internal(
                "TablePro cannot read its saved connections; the app shows why".to_owned(),
            )),
        }
    }

    /// The saved connection a tool names, read again for each call so a
    /// level the user changed a moment ago applies.
    pub fn connection(&self, id: &str) -> Result<SavedConnection, ToolError> {
        let parsed = Uuid::parse_str(id.trim())
            .map_err(|_| ToolError::InvalidArgument(format!("{id} is not a connection id from list_connections")))?;
        self.visible_connections()?
            .into_iter()
            .find(|connection| connection.id == parsed)
            .ok_or_else(|| ToolError::NotFound(format!("no connection has the id {parsed}")))
    }

    pub async fn session(&self, connection: &SavedConnection) -> Result<Arc<Session>, ToolError> {
        match self.host.session(connection.id).await {
            Some(session) if !session.is_shut_down() => Ok(session),
            _ => Err(ToolError::NotConnected(format!(
                "“{}” is not open in TablePro; call connect to open it",
                connection.name
            ))),
        }
    }
}
