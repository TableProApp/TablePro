//! In-process MCP server for the GTK app. Agents talk to the same
//! policy-gated connections the UI uses.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::Connection;
use tablepro_mcp::{ConnectionProvider, McpBridge, McpServerConfig, TokenPermissions, TokenStore};
use tablepro_policy::Principal;
use tablepro_storage::{SavedConnection, load_connections, store_mcp_token};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::database_service::DatabaseService;

struct AppConnectionProvider {
    database: Arc<DatabaseService>,
}

#[async_trait]
impl ConnectionProvider for AppConnectionProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        load_connections().await.map_err(|e| e.to_string())
    }

    async fn connection(&self, connection_id: Uuid, principal: Principal) -> Result<Arc<dyn Connection>, String> {
        let svc = &self.database;
        let conn = match &principal {
            Principal::Human { .. } => svc.get(connection_id),
            _ => svc.handle(connection_id, principal),
        };
        conn.ok_or_else(|| format!("connection {connection_id} is not open in the app"))
    }
}

/// Start the loopback MCP HTTP server.
pub struct RunningMcpServer {
    pub bridge: Arc<McpBridge>,
    shutdown: CancellationToken,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl RunningMcpServer {
    pub fn shutdown(mut self) {
        self.shutdown.cancel();
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            tracing::warn!("MCP server thread panicked during shutdown");
        }
    }
}

pub fn start_background(database: Arc<DatabaseService>) -> Option<RunningMcpServer> {
    if !database.audit_available() {
        tracing::error!("MCP server disabled because the required audit journal is unavailable");
        return None;
    }
    if !database.policy_available() {
        tracing::error!("MCP server disabled because the policy file could not be loaded");
        return None;
    }
    let tokens = match TokenStore::open_default() {
        Ok(t) => Arc::new(t),
        Err(e) => {
            tracing::warn!(error = %e, "MCP token store unavailable");
            return None;
        }
    };
    let shutdown = CancellationToken::new();
    let bridge = Arc::new(McpBridge::with_shutdown_token(
        Arc::new(AppConnectionProvider { database }),
        tokens,
        shutdown.clone(),
    ));
    let bridge_http = bridge.clone();
    let test_port = std::env::var("TABLEPRO_TEST_MCP_HTTP_PORT").ok();
    let config = server_config(test_port.as_deref());
    let server_shutdown = shutdown.clone();
    tracing::info!(host = %config.bind_host, port = config.bind_port, "MCP HTTP server starting");
    let thread = match std::thread::Builder::new().name("tablepro-mcp".into()).spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(e) => {
                tracing::warn!(error = %e, "MCP runtime unavailable; MCP HTTP server not started");
                return;
            }
        };
        rt.block_on(async move {
            if let Err(e) = tablepro_mcp::serve_streamable_http_until(bridge_http, config, server_shutdown).await {
                tracing::warn!(error = %e, "MCP HTTP server stopped");
            }
        });
    }) {
        Ok(thread) => thread,
        Err(error) => {
            tracing::warn!(%error, "MCP server thread unavailable");
            return None;
        }
    };
    Some(RunningMcpServer {
        bridge,
        shutdown,
        thread: Some(thread),
    })
}

fn server_config(test_port: Option<&str>) -> McpServerConfig {
    let mut config = McpServerConfig::default();
    if let Some(port) = test_port
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|port| *port > 0)
    {
        config.bind_port = port;
    }
    config
}

/// Issue a token, store plaintext in libsecret, return plaintext once.
pub async fn issue_token(
    bridge: Option<&Arc<McpBridge>>,
    name: String,
    permissions: TokenPermissions,
    connection_allowlist: Vec<Uuid>,
) -> Result<(Uuid, String), String> {
    let bridge = bridge.ok_or_else(|| "MCP server is not running".to_string())?;
    let (meta, plaintext) = bridge
        .tokens()
        .issue(name.clone(), permissions, connection_allowlist, None)?;
    if let Err(e) = store_mcp_token(meta.id, &plaintext, &format!("TablePro MCP: {name}")).await {
        tracing::warn!(error = %e, "failed to store MCP token in libsecret");
    }
    Ok((meta.id, plaintext))
}

pub fn revoke_token(bridge: Option<&Arc<McpBridge>>, id: Uuid) -> Result<(), String> {
    let bridge = bridge.ok_or_else(|| "MCP server is not running".to_string())?;
    bridge.tokens().revoke(id)?;
    relm4::spawn(async move {
        if let Err(e) = tablepro_storage::delete_mcp_token(id).await {
            tracing::warn!(error = %e, "failed to delete MCP token from libsecret");
        }
    });
    Ok(())
}

pub fn list_tokens(bridge: Option<&Arc<McpBridge>>) -> Vec<tablepro_mcp::McpToken> {
    bridge.map(|b| b.tokens().list()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::server_config;

    #[test]
    fn test_mcp_port_override_accepts_only_nonzero_u16_values() {
        assert_eq!(server_config(Some("23456")).bind_port, 23456);
        assert_eq!(server_config(Some("0")).bind_port, 17432);
        assert_eq!(server_config(Some("65536")).bind_port, 17432);
        assert_eq!(server_config(None).bind_port, 17432);
    }
}
