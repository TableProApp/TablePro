#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ColumnInfo, Connection, DriverError, ExecResult, ForeignKeyInfo, IndexInfo, OperationControl, QueryResult,
    QueryResultBatch, TableInfo, Value,
};
use tablepro_policy::Principal;
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use tablepro_mcp::{ConnectionProvider, McpBridge, McpLimits, TokenPermissions, TokenStore};

/// Integration-style test: every tool path that touches a connection must
/// go through the provider (which in production wraps PolicyGuard) and
/// leave a journalled policy decision when PolicyGuard is used.
#[tokio::test]
async fn tool_path_requires_provider_and_token() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let conn_id = Uuid::nil();
    let (_meta, plain) = store
        .issue("test".into(), TokenPermissions::ReadWrite, vec![conn_id], None)
        .unwrap();

    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plain).unwrap();

    let result = bridge.execute_query(&token, conn_id, "SELECT 1").await;
    assert!(
        provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst) >= 1,
        "provider.connection must be called; result={result:?}"
    );
    assert!(result.is_ok(), "stub query should succeed: {result:?}");

    // Without a token, authenticate fails — no further connection touch.
    assert!(bridge.authenticate("bad-token").is_err());
}

#[tokio::test]
async fn write_without_tools_write_scope_denied() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let conn_id = Uuid::nil();
    let (_meta, plain) = store
        .issue("ro".into(), TokenPermissions::ReadOnly, vec![conn_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider, store);
    let token = bridge.authenticate(&plain).unwrap();
    let err = bridge
        .execute_write(&token, conn_id, "DELETE FROM t", false)
        .await
        .unwrap_err();
    assert!(err.contains("scope") || err.contains("tools"), "{err}");
}

#[tokio::test]
async fn empty_allowlist_denies_connection_access() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let (_meta, plain) = store
        .issue("open".into(), TokenPermissions::ReadWrite, vec![], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plain).unwrap();
    let err = bridge.execute_query(&token, Uuid::nil(), "SELECT 1").await.unwrap_err();
    assert!(err.contains("allowlist"), "empty allowlist must fail closed: {err}");
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn read_only_token_cannot_call_administrative_function() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue(
            "read-only".into(),
            TokenPermissions::ReadOnly,
            vec![connection_id],
            None,
        )
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();

    let error = bridge
        .execute_query(&token, connection_id, "SELECT pg_terminate_backend(42)")
        .await
        .unwrap_err();

    assert!(
        error.contains("scope"),
        "administrative query must require write scope: {error}"
    );
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_read_only_token_is_refused_a_delete_before_a_connection_opens() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue(
            "read-only".into(),
            TokenPermissions::ReadOnly,
            vec![connection_id],
            None,
        )
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();

    let error = bridge
        .execute_query(&token, connection_id, "DELETE FROM t WHERE id = 1")
        .await
        .unwrap_err();

    assert!(error.contains("scope"), "DELETE is a write: {error}");
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

/// H7: execute_write defaults to preview=true (run in a transaction, report,
/// roll back). execute_query must not be a second, unpreviewed path to the
/// same write for a token that already holds tools:write scope.
#[tokio::test]
async fn a_write_scoped_token_cannot_use_execute_query_to_skip_the_preview_workflow() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("writer".into(), TokenPermissions::ReadWrite, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();

    let error = bridge
        .execute_query(&token, connection_id, "DELETE FROM t WHERE id = 1 RETURNING *")
        .await
        .unwrap_err();

    assert!(
        error.contains("execute_write"),
        "must steer the caller to execute_write: {error}"
    );
    assert_eq!(
        provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "must refuse before ever touching the connection"
    );
}

#[tokio::test]
async fn execute_query_preserves_additional_result_sets_in_order() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("reader".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::with_result_sets(vec![
        QueryResult {
            columns: vec![column("first_set")],
            rows: vec![vec![Value::Int(1)]],
            truncated: false,
        },
        QueryResult {
            columns: vec![column("second_set")],
            rows: vec![vec![Value::Text("later".into())]],
            truncated: false,
        },
    ]));
    let bridge = McpBridge::new(provider, store);
    let token = bridge.authenticate(&plaintext).unwrap();
    let output = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "execute_query",
        serde_json::json!({"connection_id": connection_id.to_string(), "sql": "SELECT 1"}),
    )
    .await
    .expect("read returns all result sets");

    assert_eq!(output["columns"], serde_json::json!(["first_set"]));
    assert_eq!(output["rows"], serde_json::json!([[1]]));
    assert_eq!(
        output["additional_result_sets"],
        serde_json::json!([{"columns": ["second_set"], "rows": [["later"]], "truncated": false}])
    );
    assert_eq!(output["truncated"], false);
}

#[tokio::test]
async fn mcp_row_cap_is_shared_across_result_sets() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("reader".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::with_result_sets(vec![
        QueryResult {
            columns: vec![column("first_set")],
            rows: vec![vec![Value::Int(1)]],
            truncated: false,
        },
        QueryResult {
            columns: vec![column("second_set")],
            rows: vec![vec![Value::Int(2)], vec![Value::Int(3)]],
            truncated: false,
        },
    ]));
    let bridge = McpBridge::with_limits(
        provider,
        store,
        McpLimits {
            requests_per_minute: 120,
            max_rows: 2,
            query_timeout_secs: 30,
        },
    );
    let token = bridge.authenticate(&plaintext).unwrap();
    let output = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "execute_query",
        serde_json::json!({"connection_id": connection_id.to_string(), "sql": "SELECT 1"}),
    )
    .await
    .expect("capped read returns its admitted rows");

    assert_eq!(output["rows"], serde_json::json!([[1]]));
    assert_eq!(
        output["additional_result_sets"],
        serde_json::json!([{"columns": ["second_set"], "rows": [[2]], "truncated": true}])
    );
    assert_eq!(output["truncated"], true);
}

#[tokio::test]
async fn json_export_keeps_multiple_result_sets_and_csv_refuses_them() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("reader".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::with_result_sets(vec![
        QueryResult {
            columns: vec![column("first_set")],
            rows: vec![vec![Value::Int(1)]],
            truncated: false,
        },
        QueryResult {
            columns: vec![column("second_set")],
            rows: vec![vec![Value::Int(2)]],
            truncated: false,
        },
    ]));
    let bridge = McpBridge::new(provider, store);
    let token = bridge.authenticate(&plaintext).unwrap();
    let args = |format| {
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": "SELECT 1",
            "format": format,
        })
    };
    let json = tablepro_mcp::dispatch(&bridge, &token, "export_data", args("json"))
        .await
        .expect("JSON represents every set");
    assert_eq!(json["additional_result_sets"][0]["rows"], serde_json::json!([[2]]));

    let csv_error = tablepro_mcp::dispatch(&bridge, &token, "export_data", args("csv"))
        .await
        .unwrap_err();
    assert!(csv_error.contains("multiple result sets"), "{csv_error}");
}

#[tokio::test]
async fn guarded_tool_path_journals_policy_decision() {
    use tablepro_core::Environment;
    use tablepro_policy::{AuditSink, AuditState, AutoApproveSink, GuardContext, PolicyConfig, PolicyGuard, Principal};
    use tablepro_storage::AuditJournal;

    let dir = tempfile::TempDir::new().unwrap();
    let journal_path = dir.path().join("audit.jsonl");
    let journal = Arc::new(AuditJournal::open_validated(journal_path.clone()).unwrap());
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let conn_id = Uuid::new_v4();
    let (_meta, plain) = store
        .issue("test".into(), TokenPermissions::ReadWrite, vec![conn_id], None)
        .unwrap();

    struct GuardedProvider {
        journal: Arc<AuditJournal>,
        calls: std::sync::atomic::AtomicUsize,
        connection_id: Uuid,
    }

    #[async_trait]
    impl ConnectionProvider for GuardedProvider {
        async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
            Ok(vec![RecordingProvider::with_driver("sqlite").saved(self.connection_id)])
        }
        async fn connection(&self, connection_id: Uuid, principal: Principal) -> Result<Arc<dyn Connection>, String> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let raw: Arc<dyn Connection> = Arc::new(StubConn {
                sql_log: Arc::new(std::sync::Mutex::new(Vec::new())),
                page_log: Arc::new(std::sync::Mutex::new(Vec::new())),
                result: QueryResult {
                    columns: vec![],
                    rows: vec![vec![Value::Int(1)]],
                    truncated: false,
                },
                result_sets: None,
            });
            let ctx = GuardContext {
                connection_id,
                connection_name: "test".into(),
                driver_id: "sqlite".into(),
                environment: Environment::Local,
                read_only: false,
                principal,
                policy: Arc::new(PolicyConfig::default()),
                approval: Arc::new(AutoApproveSink),
                audit: self.journal.clone() as Arc<dyn AuditSink>,
                audit_state: Arc::new(AuditState::new()),
            };
            Ok(Arc::new(PolicyGuard::new(raw, ctx)) as Arc<dyn Connection>)
        }
    }

    let provider = Arc::new(GuardedProvider {
        journal: journal.clone(),
        calls: std::sync::atomic::AtomicUsize::new(0),
        connection_id: conn_id,
    });
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plain).unwrap();
    let _ = bridge
        .execute_query(&token, conn_id, "SELECT 1")
        .await
        .expect("select through guard");
    assert!(provider.calls.load(std::sync::atomic::Ordering::SeqCst) >= 1);
    let text = std::fs::read_to_string(&journal_path).unwrap_or_default();
    assert!(
        !text.trim().is_empty(),
        "expected at least one journalled policy decision, got empty journal"
    );

    let refused = bridge
        .execute_query(&token, conn_id, "BEGIN")
        .await
        .expect_err("a lone BEGIN cannot hold a transaction on a shared connection");
    assert!(refused.contains("transaction"), "{refused}");
    let text = std::fs::read_to_string(&journal_path).unwrap_or_default();
    assert!(
        text.contains("transaction_control_needs_session"),
        "the refusal must be journalled"
    );
}

#[tokio::test]
async fn explain_uses_the_connection_engine_plan_form() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("ro".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::with_driver("sqlite"));
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();

    tablepro_mcp::dispatch(
        &bridge,
        &token,
        "explain_query",
        serde_json::json!({"connection_id": connection_id.to_string(), "sql": "SELECT 1"}),
    )
    .await
    .expect("a read-scoped token may read a query plan");

    assert_eq!(provider.executed_sql(), vec!["EXPLAIN QUERY PLAN SELECT 1".to_string()]);
}

#[tokio::test]
async fn explain_analyze_still_requires_write_scope() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("ro".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();

    let error = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "explain_query",
        serde_json::json!({"connection_id": connection_id.to_string(), "sql": "ANALYZE DELETE FROM t"}),
    )
    .await
    .unwrap_err();

    assert!(error.contains("scope"), "explain analyze executes the write: {error}");
    assert!(provider.executed_sql().is_empty());
}

#[tokio::test]
async fn explain_is_refused_for_engines_without_a_plan_statement() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("ro".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::with_driver("mongodb"));
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();

    let error = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "explain_query",
        serde_json::json!({"connection_id": connection_id.to_string(), "sql": "SELECT 1"}),
    )
    .await
    .unwrap_err();

    assert!(error.contains("not supported"), "{error}");
    assert!(provider.executed_sql().is_empty());
}

#[tokio::test]
async fn csv_export_escapes_separators_quotes_and_newlines() {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let connection_id = Uuid::nil();
    let (_metadata, plaintext) = store
        .issue("ro".into(), TokenPermissions::ReadOnly, vec![connection_id], None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::with_result(QueryResult {
        columns: vec![column("note"), column("plain")],
        rows: vec![vec![Value::Text("a,b\"c\nd".into()), Value::Text("ok".into())]],
        truncated: false,
    }));
    let bridge = McpBridge::new(provider, store);
    let token = bridge.authenticate(&plaintext).unwrap();

    let out = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "export_data",
        serde_json::json!({"connection_id": connection_id.to_string(), "sql": "SELECT 1", "format": "csv"}),
    )
    .await
    .expect("csv export");

    let content = out.get("content").and_then(|v| v.as_str()).unwrap();
    assert_eq!(content, "note,plain\n\"a,b\"\"c\nd\",ok\n");
    assert_eq!(out["null_marker"], "\\N");
}

async fn read_only_harness(
    allowlist: Vec<Uuid>,
) -> (
    Arc<RecordingProvider>,
    McpBridge,
    tablepro_mcp::McpToken,
    tempfile::TempDir,
) {
    let dir = tempfile::TempDir::new().unwrap();
    let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
    let (_metadata, plaintext) = store
        .issue("ro".into(), TokenPermissions::ReadOnly, allowlist, None)
        .unwrap();
    let provider = Arc::new(RecordingProvider::default());
    let bridge = McpBridge::new(provider.clone(), store);
    let token = bridge.authenticate(&plaintext).unwrap();
    (provider, bridge, token, dir)
}

#[tokio::test]
async fn table_schema_reads_columns_keys_and_indexes_with_read_scope_only() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let out = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "table_schema",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "schema": "public", "table": "items"}),
    )
    .await
    .expect("a read-scoped token may read table metadata");

    assert_eq!(out["primary_key"], serde_json::json!(["id"]));
    assert_eq!(out["columns"].as_array().unwrap().len(), 2);
    assert_eq!(out["indexes"][0]["name"], "items_pkey");
    assert_eq!(out["foreign_keys"][0]["ref_table"], "notes");
    assert!(provider.executed_sql().is_empty(), "metadata must not run free SQL");
}

#[tokio::test]
async fn describe_table_refuses_an_invalid_identifier_without_opening_a_connection() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let error = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "describe_table",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "table": "items\nitems"}),
    )
    .await
    .unwrap_err();

    assert!(error.contains("control characters"), "{error}");
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn table_schema_is_denied_for_a_connection_outside_the_allowlist() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let error = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "table_schema",
        serde_json::json!({"connection_id": Uuid::max().to_string(), "table": "items"}),
    )
    .await
    .unwrap_err();

    assert!(error.contains("not allowed to access this connection"), "{error}");
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn count_rows_counts_a_quoted_target_with_read_scope_only() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let out = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "count_rows",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "schema": "public", "table": "it\"ems"}),
    )
    .await
    .expect("a read-scoped token may count rows");

    assert_eq!(out["row_count"], 1);
    assert_eq!(out["exact"], true);
    assert_eq!(
        provider.executed_sql(),
        vec!["SELECT COUNT(*) AS row_count FROM \"public\".\"it\"\"ems\"".to_string()]
    );
}

#[tokio::test]
async fn count_rows_is_denied_for_a_token_with_an_empty_allowlist() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![]).await;

    let error = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "count_rows",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "table": "items"}),
    )
    .await
    .unwrap_err();

    assert!(error.contains("allowlist"), "{error}");
    assert!(provider.executed_sql().is_empty());
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn browse_table_pages_within_the_row_limit() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let page = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "browse_table",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "table": "items", "offset": 10, "limit": 3}),
    )
    .await
    .expect("a read-scoped token may browse a page");
    assert_eq!(page["offset"], 10);
    assert_eq!(page["rows"], serde_json::json!([[10], [11], [12]]));
    assert_eq!(page["truncated"], false);

    let capped = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "browse_table",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "table": "items", "limit": 100_000}),
    )
    .await
    .expect("an oversized page is capped, not refused");
    assert_eq!(capped["rows"].as_array().unwrap().len(), 500);
    assert_eq!(capped["truncated"], true);

    assert_eq!(provider.requested_pages(), vec![(10, 3), (0, 500)]);
}

#[tokio::test]
async fn browse_table_refuses_a_negative_page_and_an_unlisted_connection() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let bad_offset = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "browse_table",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "table": "items", "offset": -5}),
    )
    .await
    .unwrap_err();
    assert!(bad_offset.contains("non-negative"), "{bad_offset}");

    let denied = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "browse_table",
        serde_json::json!({"connection_id": Uuid::max().to_string(), "table": "items"}),
    )
    .await
    .unwrap_err();
    assert!(denied.contains("not allowed to access this connection"), "{denied}");

    assert!(provider.requested_pages().is_empty());
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

fn column(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

struct RecordingProvider {
    connection_calls: std::sync::atomic::AtomicUsize,
    driver_id: String,
    sql_log: Arc<std::sync::Mutex<Vec<String>>>,
    page_log: Arc<std::sync::Mutex<Vec<(u64, u64)>>>,
    result: QueryResult,
    result_sets: Option<Vec<QueryResult>>,
}

impl Default for RecordingProvider {
    fn default() -> Self {
        Self {
            connection_calls: std::sync::atomic::AtomicUsize::new(0),
            driver_id: "postgres".into(),
            sql_log: Arc::new(std::sync::Mutex::new(Vec::new())),
            page_log: Arc::new(std::sync::Mutex::new(Vec::new())),
            result: QueryResult {
                columns: vec![],
                rows: vec![vec![Value::Int(1)]],
                truncated: false,
            },
            result_sets: None,
        }
    }
}

impl RecordingProvider {
    fn with_driver(driver_id: &str) -> Self {
        Self {
            driver_id: driver_id.into(),
            ..Self::default()
        }
    }

    fn with_result(result: QueryResult) -> Self {
        Self {
            result,
            ..Self::default()
        }
    }

    fn with_result_sets(result_sets: Vec<QueryResult>) -> Self {
        Self {
            result_sets: Some(result_sets),
            ..Self::default()
        }
    }

    fn executed_sql(&self) -> Vec<String> {
        self.sql_log.lock().unwrap().clone()
    }

    fn requested_pages(&self) -> Vec<(u64, u64)> {
        self.page_log.lock().unwrap().clone()
    }

    fn saved(&self, connection_id: Uuid) -> SavedConnection {
        SavedConnection {
            id: connection_id,
            name: "stub".into(),
            driver_id: self.driver_id.clone(),
            host: "localhost".into(),
            port: 5432,
            socket_dir: None,
            database: "stub".into(),
            username: "stub".into(),
            use_tls: false,
            tls_mode: None,
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: false,
            auth_mode: Default::default(),
            environment: Default::default(),
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }
}

struct StubConn {
    sql_log: Arc<std::sync::Mutex<Vec<String>>>,
    page_log: Arc<std::sync::Mutex<Vec<(u64, u64)>>>,
    result: QueryResult,
    result_sets: Option<Vec<QueryResult>>,
}

#[async_trait]
impl Connection for StubConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }
    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        let mut id = column("id");
        id.primary_key = true;
        id.nullable = false;
        Ok(vec![id, column("note")])
    }
    async fn fetch_rows(&self, _: Option<&str>, _: &str, offset: u64, limit: u64) -> Result<QueryResult, DriverError> {
        self.page_log.lock().unwrap().push((offset, limit));
        Ok(QueryResult {
            columns: vec![column("id")],
            rows: (0..limit).map(|i| vec![Value::Int((offset + i) as i64)]).collect(),
            truncated: false,
        })
    }
    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        self.sql_log.lock().unwrap().push(sql.to_string());
        Ok(self.result.clone())
    }
    async fn query_result_sets_controlled(
        &self,
        sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        self.sql_log.lock().unwrap().push(sql.to_string());
        Ok(match &self.result_sets {
            Some(result_sets) => QueryResultBatch {
                truncated: result_sets.iter().any(|result| result.truncated),
                result_sets: result_sets.clone(),
            },
            None => QueryResultBatch::single(self.result.clone()),
        })
    }
    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::PolicyDenied("journalled deny".into()))
    }
    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Err(DriverError::PolicyDenied("journalled deny".into()))
    }
    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::PolicyDenied("journalled deny".into()))
    }
    async fn fetch_indexes(&self, _: Option<&str>, _: &str) -> Result<Vec<IndexInfo>, DriverError> {
        Ok(vec![IndexInfo {
            name: "items_pkey".into(),
            columns: vec!["id".into()],
            unique: true,
            primary: true,
            predicate: None,
        }])
    }
    async fn fetch_foreign_keys(&self, _: Option<&str>, _: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        Ok(vec![ForeignKeyInfo {
            name: "items_note_fkey".into(),
            columns: vec!["note".into()],
            ref_schema: Some("public".into()),
            ref_table: "notes".into(),
            ref_columns: vec!["id".into()],
            on_delete: Some("CASCADE".into()),
            on_update: None,
        }])
    }
    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl ConnectionProvider for RecordingProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        Ok(vec![self.saved(Uuid::nil()), self.saved(Uuid::max())])
    }
    async fn connection(&self, _connection_id: Uuid, _principal: Principal) -> Result<Arc<dyn Connection>, String> {
        self.connection_calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(Arc::new(StubConn {
            sql_log: self.sql_log.clone(),
            page_log: self.page_log.clone(),
            result: self.result.clone(),
            result_sets: self.result_sets.clone(),
        }))
    }
}

#[tokio::test]
async fn list_objects_is_denied_for_a_token_with_an_empty_allowlist() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![]).await;

    let error = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "list_objects",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "kind": "routine"}),
    )
    .await
    .unwrap_err();

    assert!(error.contains("allowlist"), "{error}");
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn list_objects_rejects_an_unknown_kind_and_a_hostile_schema_before_connecting() {
    let (provider, bridge, token, _dir) = read_only_harness(vec![Uuid::nil()]).await;

    let unknown = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "list_objects",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "kind": "table"}),
    )
    .await
    .unwrap_err();
    assert!(unknown.contains("unknown kind"), "{unknown}");

    let hostile = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "list_objects",
        serde_json::json!({"connection_id": Uuid::nil().to_string(), "kind": "routine", "schema": "a\u{0}b"}),
    )
    .await
    .unwrap_err();
    assert!(hostile.contains("control characters"), "{hostile}");
    assert_eq!(provider.connection_calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}
