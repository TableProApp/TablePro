mod app_bridge;
mod mcp_service;
pub(crate) mod open_sessions;
#[cfg(any(windows, test))]
pub(crate) mod token_target;

use std::sync::Arc;
use std::sync::atomic::AtomicU64;

pub(crate) use app_bridge::{ActiveProject, AppBridge, HistoryAccess};
pub use app_bridge::{McpAppHost, McpWriteRequest};
pub(crate) use mcp_service::StoredTokens;
pub use mcp_service::{McpListener, McpService, McpStatusTag, SeenClientInfo};
use tablepro_mcp::ToolContext;

use crate::core_handle::Core;
use crate::error::CoreError;

#[uniffi::export]
impl Core {
    // Off until `apply`; its tools reach the sessions `connect_saved` opened, and the app through `host`.
    pub fn mcp_server(
        &self,
        host: Box<dyn McpAppHost>,
        listener: Box<dyn McpListener>,
    ) -> Result<Arc<McpService>, CoreError> {
        let connections = self.connection_store()?;
        // Read before a client asks, which would otherwise find the list still loading.
        let reader = connections.clone();
        drop(self.tasks.spawn_blocking_task(move || {
            if let Err(error) = reader.load_blocking() {
                tracing::warn!(%error, "the MCP server could not read the saved connections");
            }
        }));
        let project = app_bridge::ActiveProject::default();
        let bridge = app_bridge::AppBridge {
            app: Arc::from(host),
            sessions: self.open_sessions(),
            tasks: self.tasks.clone(),
            history: self.history_access(),
            requests: AtomicU64::new(1),
            project: project.clone(),
        };
        let context = ToolContext {
            host: Arc::new(bridge),
            connections,
        };
        Ok(Arc::new(McpService::new(
            self.tasks.clone(),
            self.mcp_tokens(),
            context,
            self.client_version(),
            Arc::from(listener),
            project,
        )))
    }
}

// The address and port a fresh install's server listens on, the other apps' as well.
#[uniffi::export]
pub fn mcp_default_port() -> u16 {
    tablepro_mcp::DEFAULT_PORT
}

// What a client's configuration names: the server's address on 127.0.0.1.
#[uniffi::export]
pub fn mcp_address(port: u16) -> String {
    format!("http://127.0.0.1:{port}{}", tablepro_mcp::MCP_PATH)
}
