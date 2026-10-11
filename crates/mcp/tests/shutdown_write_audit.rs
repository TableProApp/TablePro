#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! MCP shutdown must never truncate a write's audit trail. Production
//! (`tablepro-app`'s `RunningMcpServer`) runs the streamable-HTTP server on a
//! dedicated single-thread runtime and drops that runtime once
//! `serve_streamable_http_until` returns. If a write is still in flight when
//! that happens, its future is dropped mid-poll, and unless it has already
//! reached `PolicyGuard`'s terminal audit write, the journal is left with an
//! intent and no outcome. This test reproduces that exact shape: a real
//! current-thread runtime on its own OS thread, a real HTTP request, and a
//! connection that only resolves some time after observing cancellation.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    ColumnInfo, Connection, DriverError, Environment, ExecResult, ForeignKeyInfo, IndexInfo, OperationControl,
    QueryResult, TableInfo, Transaction, Value,
};
use tablepro_mcp::{ConnectionProvider, McpBridge, McpServerConfig, TokenPermissions, TokenStore};
use tablepro_policy::{
    AuditError, AuditEvent, AuditRecordPhase, AuditSink, AuditState, AuditTerminalStatus, GuardContext, PolicyConfig,
    PolicyGuard, Principal, WritePolicy,
};
use tablepro_storage::SavedConnection;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

struct RecordingAuditSink {
    events: Mutex<Vec<AuditEvent>>,
}

impl RecordingAuditSink {
    fn new() -> Self {
        Self {
            events: Mutex::new(Vec::new()),
        }
    }
}

#[async_trait]
impl AuditSink for RecordingAuditSink {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        self.events.lock().expect("event lock").push(event);
        Ok(())
    }
}

struct SlowCancelConnection;

#[async_trait]
impl Connection for SlowCancelConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        std::future::pending().await
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        std::future::pending().await
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        std::future::pending().await
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        std::future::pending().await
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        std::future::pending().await
    }

    async fn execute_controlled(&self, _: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        control.cancellation_token().cancelled().await;
        tokio::time::sleep(Duration::from_millis(6_500)).await;
        Err(DriverError::Cancelled)
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        std::future::pending().await
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        std::future::pending().await
    }

    async fn fetch_indexes(&self, _: Option<&str>, _: &str) -> Result<Vec<IndexInfo>, DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_foreign_keys(&self, _: Option<&str>, _: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        Ok(Vec::new())
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Err(DriverError::Unsupported("preview is not exercised by this test".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct GuardedProvider {
    connection_id: Uuid,
    policy: Arc<PolicyConfig>,
    audit: Arc<RecordingAuditSink>,
    audit_state: Arc<AuditState>,
}

#[async_trait]
impl ConnectionProvider for GuardedProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        Ok(Vec::new())
    }

    async fn connection(&self, connection_id: Uuid, principal: Principal) -> Result<Arc<dyn Connection>, String> {
        if connection_id != self.connection_id {
            return Err("connection not found".into());
        }
        let context = GuardContext {
            connection_id,
            connection_name: "shutdown-test".into(),
            driver_id: "postgres".into(),
            environment: Environment::Local,
            read_only: false,
            principal,
            policy: self.policy.clone(),
            approval: Arc::new(tablepro_policy::AutoApproveSink),
            audit: self.audit.clone(),
            audit_state: self.audit_state.clone(),
        };
        Ok(Arc::new(PolicyGuard::new(Arc::new(SlowCancelConnection), context)))
    }
}

fn wait_for_listening(addr: &str) {
    for _ in 0..200 {
        if TcpStream::connect(addr).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("the MCP HTTP server never started listening on {addr}");
}

#[test]
fn shutdown_during_a_write_still_records_a_terminal_audit_outcome() {
    let dir = tempfile::TempDir::new().expect("temporary token directory");
    let connection_id = Uuid::new_v4();
    let tokens = Arc::new(TokenStore::open(dir.path().join("tokens.json")).expect("token store"));
    let (_metadata, plaintext) = tokens
        .issue(
            "shutdown-test".into(),
            TokenPermissions::ReadWrite,
            vec![connection_id],
            None,
        )
        .expect("issue a read-write token");

    let audit = Arc::new(RecordingAuditSink::new());
    let audit_state = Arc::new(AuditState::new());
    let mut policy = PolicyConfig::default();
    policy.environments.entry("local".into()).or_default().agent_writes = Some(WritePolicy::Allow);
    let provider = Arc::new(GuardedProvider {
        connection_id,
        policy: Arc::new(policy),
        audit: audit.clone(),
        audit_state,
    });

    let shutdown = CancellationToken::new();
    let mut bridge = McpBridge::with_shutdown_token(provider, tokens, shutdown.clone());
    bridge.query_timeout_secs = 8;
    let bridge = Arc::new(bridge);

    let bind_port = 18773;
    let addr = format!("127.0.0.1:{bind_port}");
    let config = McpServerConfig {
        bind_host: "127.0.0.1".into(),
        bind_port,
    };

    let server_shutdown = shutdown.clone();
    let server_thread = std::thread::Builder::new()
        .name("mcp-shutdown-test".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("nested current-thread runtime");
            rt.block_on(async move {
                let _ = tablepro_mcp::serve_streamable_http_until(bridge, config, server_shutdown).await;
            });
        })
        .expect("spawn the mcp server thread");

    wait_for_listening(&addr);

    let request_addr = addr.clone();
    let write_thread = std::thread::spawn(move || {
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "execute_write",
                "arguments": {
                    "connection_id": connection_id.to_string(),
                    "sql": "INSERT INTO jobs(id) VALUES (1)",
                    "preview": false,
                    "token": plaintext,
                }
            }
        })
        .to_string();
        let request = format!(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let mut stream = TcpStream::connect(&request_addr).expect("connect to the mcp server");
        stream.write_all(request.as_bytes()).expect("send the write request");
        let mut response = String::new();
        let _ = stream.read_to_string(&mut response);
    });

    std::thread::sleep(Duration::from_millis(300));
    shutdown.cancel();

    server_thread.join().expect("the mcp server thread must not panic");
    let _ = write_thread.join();

    let events = audit.events.lock().expect("event lock");
    let intents = events.iter().filter(|e| e.phase == AuditRecordPhase::Intent).count();
    let outcomes = events
        .iter()
        .filter(|e| e.phase == AuditRecordPhase::Outcome)
        .collect::<Vec<_>>();
    assert_eq!(
        intents,
        outcomes.len(),
        "a write interrupted by MCP shutdown must not leave an audit intent without a terminal outcome: {events:?}"
    );
    assert!(
        outcomes.iter().all(|e| matches!(
            e.terminal_status,
            AuditTerminalStatus::Cancelled | AuditTerminalStatus::Unknown
        )),
        "{outcomes:?}"
    );
}
