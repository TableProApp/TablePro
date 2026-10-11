#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! The MCP HTTP endpoint is loopback-only. A non-local bind host must be
//! refused before a socket is opened, so no routable interface is ever
//! exposed.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::Connection;
use tablepro_mcp::{ConnectionProvider, McpBridge, McpServerConfig, TokenStore, serve_streamable_http};
use tablepro_policy::Principal;
use tablepro_storage::SavedConnection;
use uuid::Uuid;

struct RefusingProvider;

#[async_trait]
impl ConnectionProvider for RefusingProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        Ok(Vec::new())
    }

    async fn connection(&self, _: Uuid, _: Principal) -> Result<Arc<dyn Connection>, String> {
        Err("no connection in this test".into())
    }
}

fn bridge(dir: &tempfile::TempDir) -> Arc<McpBridge> {
    let tokens = Arc::new(TokenStore::open(dir.path().join("tokens.json")).expect("token store"));
    Arc::new(McpBridge::new(Arc::new(RefusingProvider), tokens))
}

#[tokio::test]
async fn a_non_local_bind_host_is_refused_and_nothing_listens() {
    let dir = tempfile::TempDir::new().expect("temporary token directory");
    let port = 17999;

    for host in ["0.0.0.0", "::", "[::]", "192.168.1.10", "example.com", "127.0.0.1.evil"] {
        let config = McpServerConfig {
            bind_host: host.into(),
            bind_port: port,
        };
        let error = serve_streamable_http(bridge(&dir), config).await.expect_err(host);
        assert!(error.contains("refusing to bind"), "{host}: {error}");
    }

    assert!(
        tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_err(),
        "a refused bind must leave nothing listening"
    );
}

#[tokio::test]
async fn a_loopback_bind_host_keeps_serving() {
    let dir = tempfile::TempDir::new().expect("temporary token directory");
    for host in ["127.0.0.1", "localhost", "::1", "[::1]"] {
        let config = McpServerConfig {
            bind_host: host.into(),
            bind_port: 0,
        };
        let served = tokio::time::timeout(
            std::time::Duration::from_millis(250),
            serve_streamable_http(bridge(&dir), config),
        )
        .await;
        assert!(served.is_err(), "{host} must be accepted and keep serving: {served:?}");
    }
}
