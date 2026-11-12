use std::sync::Arc;

use tablepro_core::dialect::DatabaseLayout;
use tablepro_session::{OperationKind, Session};
use tablepro_storage::{ConnectionList, ConnectionListState, ConnectionStore, SavedConnection};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::mcp_host::McpHost;
use crate::tool_error::ToolError;

pub(crate) struct HeldSession {
    pub session: Arc<Session>,
    // None for the connection's own database.
    pub database: Option<String>,
}

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
        Ok(self.visible_library()?.0)
    }

    /// One snapshot, so each connection's group is the one it had there.
    pub fn visible_library(&self) -> Result<(Vec<SavedConnection>, ConnectionList), ToolError> {
        match self.connections.snapshot().state {
            ConnectionListState::Ready(list) => Ok((
                list.connections
                    .iter()
                    .filter(|connection| !connection.external_access.is_blocked())
                    .cloned()
                    .collect(),
                list,
            )),
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

    // Never opens a database: one the user did not open in TablePro stays closed to clients.
    pub(crate) async fn held_session(
        &self,
        connection: &SavedConnection,
        database: Option<&str>,
        cancel: &CancellationToken,
    ) -> Result<HeldSession, ToolError> {
        let own = self.session(connection).await?;
        let Some(database) = database else {
            return Ok(HeldSession {
                session: own,
                database: None,
            });
        };
        if database.is_empty() {
            return Err(ToolError::InvalidArgument(
                "database is empty; omit it for the connection's own database".to_owned(),
            ));
        }
        if own.database() == Some(database) {
            return Ok(HeldSession {
                session: own,
                database: None,
            });
        }
        if let Some(session) = self.host.session_in(connection.id, database).await
            && !session.is_shut_down()
        {
            return Ok(HeldSession {
                session,
                database: Some(database.to_owned()),
            });
        }
        if own.database().is_none() && opened_in(&own, database, cancel).await {
            return Ok(HeldSession {
                session: own,
                database: None,
            });
        }
        Err(not_held(
            &connection.name,
            database,
            own.current_dialect().map(|dialect| dialect.database_layout()),
        ))
    }
}

// A connection saved without a database opens the login's default, which only the server can name.
async fn opened_in(session: &Session, database: &str, cancel: &CancellationToken) -> bool {
    session
        .run_cancellable(OperationKind::Metadata, cancel, |lease, call| async move {
            Ok(lease.list_databases(call).await?)
        })
        .await
        .is_ok_and(|listed| listed.iter().any(|own| own.is_default && own.name == database))
}

fn not_held(connection: &str, database: &str, layout: Option<DatabaseLayout>) -> ToolError {
    match layout {
        Some(DatabaseLayout::Single) => ToolError::Unsupported(format!(
            "“{connection}” reaches one database, so it has no “{database}”"
        )),
        Some(DatabaseLayout::AsSchemas) => ToolError::InvalidArgument(format!(
            "on “{connection}” the database “{database}” is a schema of the connection: pass it as schema, or \
qualify the names in the query"
        )),
        Some(DatabaseLayout::WithSchemas) | None => ToolError::NotConnected(format!(
            "the database “{database}” of “{connection}” is not open in TablePro; the user can open it with \
Open Database… on the connection in TablePro, then call again"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_database_not_held_says_what_reaches_it_on_each_engine() {
        let codes = [
            (Some(DatabaseLayout::WithSchemas), "not_connected"),
            (None, "not_connected"),
            (Some(DatabaseLayout::AsSchemas), "invalid_argument"),
            (Some(DatabaseLayout::Single), "unsupported"),
        ];

        for (layout, code) in codes {
            let refused = not_held("prod", "analytics", layout);

            assert_eq!(refused.code(), code, "{layout:?}");
            assert!(refused.message().contains("analytics"), "{}", refused.message());
        }
        assert!(
            not_held("prod", "analytics", Some(DatabaseLayout::WithSchemas))
                .message()
                .contains("Open Database…")
        );
    }
}
