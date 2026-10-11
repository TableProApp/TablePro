#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;
use tablepro_core::{Connection, Environment, Value};
use tablepro_mcp::{ConnectionProvider, McpBridge, McpToken, TokenPermissions, TokenStore, dispatch};
use tablepro_policy::{AuditSink, AuditState, DenyApprovalSink, GuardContext, PolicyConfig, PolicyGuard, Principal};
use tablepro_release_tests::Fixture;
use tablepro_storage::{AuditJournal, SavedConnection};
use uuid::Uuid;

struct FixtureProvider {
    connection: Arc<dyn Connection>,
    connection_id: Uuid,
    read_only: bool,
    journal: Arc<AuditJournal>,
    audit_state: Arc<AuditState>,
    _journal_dir: tempfile::TempDir,
}

impl FixtureProvider {
    async fn open(read_only: bool) -> (Arc<Self>, Uuid) {
        let fixture = Fixture::from_env();
        let connection: Arc<dyn Connection> = Arc::from(fixture.connect_verified().await);
        let journal_dir = tempfile::TempDir::new().expect("temporary audit journal directory");
        let journal =
            AuditJournal::open_validated(journal_dir.path().join("audit.jsonl")).expect("open fixture audit journal");
        let connection_id = Uuid::new_v4();
        let provider = Arc::new(Self {
            connection,
            connection_id,
            read_only,
            journal: Arc::new(journal),
            audit_state: Arc::new(AuditState::new()),
            _journal_dir: journal_dir,
        });
        (provider, connection_id)
    }
}

#[async_trait]
impl ConnectionProvider for FixtureProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        Ok(vec![SavedConnection {
            id: self.connection_id,
            name: "postgres-release-fixture".into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5433,
            socket_dir: None,
            database: "tablepro".into(),
            username: "tablepro".into(),
            use_tls: true,
            tls_mode: None,
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: self.read_only,
            auth_mode: Default::default(),
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }])
    }

    async fn connection(&self, connection_id: Uuid, principal: Principal) -> Result<Arc<dyn Connection>, String> {
        let context = GuardContext {
            connection_id,
            connection_name: "postgres-release-fixture".into(),
            driver_id: "postgres".into(),
            environment: Environment::Local,
            read_only: self.read_only,
            principal,
            policy: Arc::new(PolicyConfig::default()),
            approval: Arc::new(DenyApprovalSink),
            audit: self.journal.clone() as Arc<dyn AuditSink>,
            audit_state: self.audit_state.clone(),
        };
        Ok(Arc::new(PolicyGuard::new(self.connection.clone(), context)) as Arc<dyn Connection>)
    }
}

struct Harness {
    bridge: McpBridge,
    token: McpToken,
    connection_id: Uuid,
    provider: Arc<FixtureProvider>,
    _token_dir: tempfile::TempDir,
}

impl Harness {
    async fn open(permissions: TokenPermissions, read_only: bool) -> Self {
        let (provider, connection_id) = FixtureProvider::open(read_only).await;
        let token_dir = tempfile::TempDir::new().expect("temporary token directory");
        let store = Arc::new(TokenStore::open(token_dir.path().join("tokens.json")).expect("open token store"));
        let (_metadata, plaintext) = store
            .issue("release".into(), permissions, vec![connection_id], None)
            .expect("issue a fixture token");
        let bridge = McpBridge::new(provider.clone(), store);
        let token = bridge.authenticate(&plaintext).expect("authenticate the fixture token");
        Self {
            bridge,
            token,
            connection_id,
            provider,
            _token_dir: token_dir,
        }
    }

    async fn call(&self, tool: &str, args: serde_json::Value) -> Result<serde_json::Value, String> {
        dispatch(&self.bridge, &self.token, tool, args).await
    }

    async fn item_count(&self) -> i64 {
        item_count(&self.provider).await
    }
}

async fn item_count(provider: &FixtureProvider) -> i64 {
    let result = provider
        .connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("count release_items");
    match result.rows[0].first() {
        Some(Value::Int(count)) => *count,
        other => panic!("unexpected count value: {other:?}"),
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_read_scoped_agent_cannot_read_a_query_plan() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;

    let out = harness
        .call(
            "explain_query",
            json!({"connection_id": harness.connection_id.to_string(), "sql": "SELECT * FROM release_items WHERE amount > 5"}),
        )
        .await
        .expect("the explain tool returns its response with plan rows masked");

    let plan = out
        .get("plan_rows")
        .and_then(|v| v.as_array())
        .expect("plan_rows array");
    let text = plan.iter().map(|row| row.to_string()).collect::<String>();
    assert!(
        !text.contains("Scan"),
        "read-scoped agents must not see plan details: {text}"
    );
    assert!(text.contains("REDACTED"), "plan details should be masked: {text}");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn explain_analyze_is_denied_and_leaves_the_table_intact() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;
    let before = harness.item_count().await;

    let error = harness
        .call(
            "explain_query",
            json!({"connection_id": harness.connection_id.to_string(), "sql": "ANALYZE DELETE FROM release_items"}),
        )
        .await
        .expect_err("explain analyze executes the delete and must be refused");

    assert!(error.contains("scope"), "expected a scope denial: {error}");
    assert_eq!(harness.item_count().await, before, "no row may be deleted");
    assert_eq!(before, 3);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn explain_analyze_stays_denied_on_a_read_only_connection_with_write_scope() {
    let harness = Harness::open(TokenPermissions::ReadWrite, true).await;
    let before = harness.item_count().await;

    let error = harness
        .call(
            "explain_query",
            json!({"connection_id": harness.connection_id.to_string(), "sql": "ANALYZE DELETE FROM release_items"}),
        )
        .await
        .expect_err("a read-only connection must refuse an analyzing plan of a write");

    assert!(!error.is_empty());
    assert_eq!(harness.item_count().await, before, "no row may be deleted");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn csv_export_escapes_values_read_from_the_database() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;

    let out = harness
        .call(
            "export_data",
            json!({
                "connection_id": harness.connection_id.to_string(),
                "sql": "SELECT 'a,b\"c' || chr(10) || 'd' AS note, 'ok' AS plain",
                "format": "csv",
            }),
        )
        .await
        .expect("csv export");

    let content = out.get("content").and_then(|v| v.as_str()).expect("csv content");
    assert_eq!(content, "note,plain\n\"a,b\"\"c\nd\",ok\n");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_read_scoped_agent_cannot_run_a_write_through_execute_query() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;
    let before = harness.item_count().await;

    let error = harness
        .bridge
        .execute_query(
            &harness.token,
            harness.connection_id,
            "DELETE FROM release_items WHERE id = 1",
        )
        .await
        .expect_err("a read-scoped token must not delete rows");

    assert!(error.contains("scope"), "expected a scope denial: {error}");
    assert_eq!(harness.item_count().await, before, "no row may be deleted");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_denied_agent_write_is_journalled() {
    let harness = Harness::open(TokenPermissions::ReadWrite, true).await;

    let error = harness
        .bridge
        .execute_write(
            &harness.token,
            harness.connection_id,
            "DELETE FROM release_items WHERE id = 1",
            false,
        )
        .await
        .expect_err("a read-only connection must refuse the delete");
    assert!(!error.is_empty());

    let entries = harness
        .provider
        .journal
        .recent(16)
        .await
        .expect("read the audit journal");
    assert!(!entries.is_empty(), "a denied write must leave an audit record");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_read_scoped_agent_reads_table_metadata_a_count_and_a_page() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;
    let expected = harness.item_count().await;

    let schema = harness
        .call(
            "table_schema",
            json!({"connection_id": harness.connection_id.to_string(), "schema": "public", "table": "release_items"}),
        )
        .await
        .expect("a read-scoped token may read table metadata");
    let columns = schema.get("columns").and_then(|v| v.as_array()).expect("columns");
    assert!(columns.iter().any(|c| c["name"] == "id"), "{schema}");
    assert_eq!(schema["primary_key"], json!(["id"]));

    let count = harness
        .call(
            "count_rows",
            json!({"connection_id": harness.connection_id.to_string(), "schema": "public", "table": "release_items"}),
        )
        .await
        .expect("a read-scoped token may count rows");
    assert_eq!(count["row_count"], json!(expected));
    assert_eq!(count["exact"], json!(true));

    let page = harness
        .call(
            "browse_table",
            json!({
                "connection_id": harness.connection_id.to_string(),
                "schema": "public",
                "table": "release_items",
                "offset": 1,
                "limit": 1,
            }),
        )
        .await
        .expect("a read-scoped token may browse a page");
    assert_eq!(page["offset"], json!(1));
    assert_eq!(page["rows"].as_array().expect("rows").len(), 1);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_metadata_tool_is_refused_for_a_connection_outside_the_allowlist() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;
    let unlisted = Uuid::new_v4().to_string();

    for tool in ["table_schema", "count_rows", "browse_table"] {
        let error = harness
            .call(tool, json!({"connection_id": unlisted, "table": "release_items"}))
            .await
            .expect_err(tool);
        assert!(
            error.contains("not allowed to access this connection"),
            "{tool}: {error}"
        );
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_hostile_table_name_cannot_inject_sql_through_a_metadata_tool() {
    let harness = Harness::open(TokenPermissions::ReadOnly, false).await;
    let before = harness.item_count().await;

    let error = harness
        .call(
            "count_rows",
            json!({
                "connection_id": harness.connection_id.to_string(),
                "table": "release_items\"; DROP TABLE release_items; --",
            }),
        )
        .await
        .expect_err("a quoted identifier must reach the engine as one name");

    assert!(!error.is_empty());
    assert_eq!(harness.item_count().await, before, "no table may be dropped");
}
