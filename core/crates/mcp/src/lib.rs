//! The MCP server: tools that let a client on this computer reach the
//! connections the user has open in TablePro, over HTTP on 127.0.0.1.
//!
//! Free of GTK. The app supplies an `McpHost`, which finds a connection's
//! session through its window and asks the user about writes there.

mod access_token;
mod browse_request;
mod collected_results;
mod connection_tools;
mod mcp_host;
mod mcp_server;
mod query_tools;
mod schema_tools;
mod token_vault;
mod tool_args;
mod tool_context;
mod tool_error;
mod tool_server;

pub use access_token::{AccessToken, TokenError};
pub use mcp_host::{McpHost, OpenOutcome, WriteApproval};
pub use mcp_server::{MCP_PATH, McpServer, StartError};
pub use query_tools::{DEFAULT_ROWS, DEFAULT_TIMEOUT_SECONDS, MAX_QUERY_BYTES, MAX_ROWS, MAX_TIMEOUT_SECONDS};
pub use token_vault::{ObtainError, TokenVault, obtain_token, replace_token};
pub use tool_context::ToolContext;
pub use tool_server::catalog;

/// The port a fresh install listens on, the macOS app's as well.
pub const DEFAULT_PORT: u16 = 23508;
