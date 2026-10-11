#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use async_trait::async_trait;
use tablepro_core::{
    ColumnInfo, Connection, DriverError, Environment, ExecResult, ForeignKeyInfo, IndexInfo, QueryResult, TableInfo,
    Transaction, Value,
};
use tablepro_mcp::{ConnectionProvider, McpBridge, McpLimits, McpToken, TokenPermissions, TokenStore, dispatch};
use tablepro_policy::Principal;
use tablepro_storage::SavedConnection;
use uuid::Uuid;

#[derive(Clone, Copy, PartialEq, Eq)]
enum HangPhase {
    SavedConnections,
    Acquisition,
    ListTables,
    Columns,
    Indexes,
    ForeignKeys,
    Begin,
    ExecutionDeadline,
    Rollback,
}

struct HangingProvider {
    connection_id: Uuid,
    phase: HangPhase,
    entered: Arc<AtomicUsize>,
}

#[async_trait]
impl ConnectionProvider for HangingProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        if self.phase == HangPhase::SavedConnections {
            self.entered.fetch_add(1, Ordering::SeqCst);
            return std::future::pending().await;
        }
        Ok(vec![saved_connection(self.connection_id)])
    }

    async fn connection(&self, connection_id: Uuid, _: Principal) -> Result<Arc<dyn Connection>, String> {
        if connection_id != self.connection_id {
            return Err("connection not found".into());
        }
        if self.phase == HangPhase::Acquisition {
            self.entered.fetch_add(1, Ordering::SeqCst);
            return std::future::pending().await;
        }
        Ok(Arc::new(HangingConnection {
            phase: self.phase,
            entered: self.entered.clone(),
        }))
    }
}

struct HangingConnection {
    phase: HangPhase,
    entered: Arc<AtomicUsize>,
}

impl HangingConnection {
    async fn hang<T>(&self) -> Result<T, DriverError> {
        self.entered.fetch_add(1, Ordering::SeqCst);
        std::future::pending().await
    }
}

#[async_trait]
impl Connection for HangingConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        if self.phase == HangPhase::ListTables {
            return self.hang().await;
        }
        Ok(Vec::new())
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        if self.phase == HangPhase::Columns {
            return self.hang().await;
        }
        Ok(Vec::new())
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_query_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_query_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_indexes(&self, _: Option<&str>, _: &str) -> Result<Vec<IndexInfo>, DriverError> {
        if self.phase == HangPhase::Indexes {
            return self.hang().await;
        }
        Ok(Vec::new())
    }

    async fn fetch_foreign_keys(&self, _: Option<&str>, _: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        if self.phase == HangPhase::ForeignKeys {
            return self.hang().await;
        }
        Ok(Vec::new())
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        if self.phase == HangPhase::Begin {
            return self.hang().await;
        }
        Ok(Box::new(HangingTransaction {
            phase: self.phase,
            entered: self.entered.clone(),
        }))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct HangingTransaction {
    phase: HangPhase,
    entered: Arc<AtomicUsize>,
}

#[async_trait]
impl Transaction for HangingTransaction {
    async fn query(&mut self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_query_result())
    }

    async fn execute(&mut self, _: &str) -> Result<ExecResult, DriverError> {
        if self.phase == HangPhase::ExecutionDeadline {
            self.entered.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }

    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        if self.phase == HangPhase::Rollback {
            self.entered.fetch_add(1, Ordering::SeqCst);
            return std::future::pending().await;
        }
        self.entered.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

struct Harness {
    bridge: McpBridge,
    token: McpToken,
    connection_id: Uuid,
    entered: Arc<AtomicUsize>,
    _directory: tempfile::TempDir,
}

fn harness(phase: HangPhase, permissions: TokenPermissions) -> Harness {
    let directory = tempfile::TempDir::new().unwrap();
    let connection_id = Uuid::new_v4();
    let tokens = Arc::new(TokenStore::open(directory.path().join("tokens.json")).unwrap());
    let (_, plaintext) = tokens
        .issue("timeout-bounds".into(), permissions, vec![connection_id], None)
        .unwrap();
    let token = tokens.authenticate(&plaintext).unwrap();
    let entered = Arc::new(AtomicUsize::new(0));
    let provider = Arc::new(HangingProvider {
        connection_id,
        phase,
        entered: entered.clone(),
    });
    let bridge = McpBridge::with_limits(
        provider,
        tokens,
        McpLimits {
            query_timeout_secs: 1,
            ..McpLimits::default()
        },
    );
    Harness {
        bridge,
        token,
        connection_id,
        entered,
        _directory: directory,
    }
}

#[tokio::test(start_paused = true)]
async fn query_timeout_bounds_saved_connection_listing() {
    let harness = harness(HangPhase::SavedConnections, TokenPermissions::ReadOnly);
    let error = harness.bridge.list_connections(&harness.token).await.unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(harness.entered.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn query_timeout_bounds_saved_connection_lookup() {
    let harness = harness(HangPhase::SavedConnections, TokenPermissions::ReadOnly);
    let error = harness
        .bridge
        .execute_query(&harness.token, harness.connection_id, "SELECT 1")
        .await
        .unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(harness.entered.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn query_timeout_bounds_connection_acquisition_after_dispatch() {
    let harness = harness(HangPhase::Acquisition, TokenPermissions::ReadOnly);
    let error = harness
        .bridge
        .execute_query(&harness.token, harness.connection_id, "SELECT 1")
        .await
        .unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(harness.entered.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn query_timeout_bounds_every_metadata_phase_after_dispatch() {
    for (phase, tool) in [
        (HangPhase::ListTables, "list_tables"),
        (HangPhase::Columns, "describe_table"),
        (HangPhase::Indexes, "table_schema"),
        (HangPhase::ForeignKeys, "table_schema"),
    ] {
        let harness = harness(phase, TokenPermissions::ReadOnly);
        let arguments = serde_json::json!({
            "connection_id": harness.connection_id.to_string(),
            "table": "items",
        });
        let error = dispatch(&harness.bridge, &harness.token, tool, arguments)
            .await
            .unwrap_err();
        assert!(error.contains("timed out"), "{tool}: {error}");
        assert_eq!(harness.entered.load(Ordering::SeqCst), 1, "{tool}");
    }
}

#[tokio::test(start_paused = true)]
async fn query_timeout_bounds_preview_begin_after_dispatch() {
    let harness = harness(HangPhase::Begin, TokenPermissions::ReadWrite);
    let error = harness
        .bridge
        .execute_write(&harness.token, harness.connection_id, "DELETE FROM items", true)
        .await
        .unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(harness.entered.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn preview_dispatches_rollback_after_execution_deadline_expiry() {
    let harness = harness(HangPhase::ExecutionDeadline, TokenPermissions::ReadWrite);
    let error = harness
        .bridge
        .execute_write(&harness.token, harness.connection_id, "DELETE FROM items", true)
        .await
        .unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(harness.entered.load(Ordering::SeqCst), 2);
}

#[tokio::test(start_paused = true)]
async fn query_timeout_bounds_preview_rollback_after_dispatch() {
    let harness = harness(HangPhase::Rollback, TokenPermissions::ReadWrite);
    let error = harness
        .bridge
        .execute_write(&harness.token, harness.connection_id, "DELETE FROM items", true)
        .await
        .unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(harness.entered.load(Ordering::SeqCst), 1);
    assert!(error.contains("rollback could not be confirmed"), "{error}");
}

fn empty_query_result() -> QueryResult {
    QueryResult {
        columns: Vec::new(),
        rows: Vec::new(),
        truncated: false,
    }
}

fn saved_connection(id: Uuid) -> SavedConnection {
    SavedConnection {
        id,
        name: "timeout-bounds".into(),
        driver_id: "postgres".into(),
        host: "localhost".into(),
        port: 5432,
        socket_dir: None,
        database: "timeout-bounds".into(),
        username: "timeout-bounds".into(),
        use_tls: false,
        tls_mode: None,
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: Default::default(),
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}
