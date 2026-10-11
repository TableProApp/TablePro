//! MCP server surface for TablePro Linux.
//!
//! Token scopes and connection allowlists answer **who** and **which
//! connections**. Every tool call then obtains a connection through a
//! [`ConnectionProvider`] that must return a policy-gated handle, so
//! **what SQL** still goes through `PolicyGuard`. There is no path to a
//! raw driver connection from this crate.

mod auth;
mod bridge;
mod rate_limit;
mod server;
mod tokens;
mod tools;

pub use auth::{McpScope, TokenPermissions, authorize_scopes};
pub use bridge::{ConnectionProvider, McpBridge, McpLimits, TableSchema};
pub use rate_limit::RateLimiter;
pub use server::{McpServerConfig, serve_stdio, serve_streamable_http, serve_streamable_http_until};
pub use tokens::{McpToken, TokenStore, generate_token};
pub use tools::{TOOL_NAMES, dispatch};
