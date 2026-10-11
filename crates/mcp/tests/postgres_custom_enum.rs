#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;

use async_trait::async_trait;
use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Environment, TlsConfig, Value};
use tablepro_mcp::{ConnectionProvider, McpBridge, TokenPermissions, TokenStore};
use tablepro_policy::Principal;
use tablepro_storage::SavedConnection;
use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::{postgres::Postgres, testcontainers::runners::AsyncRunner};
use uuid::Uuid;

const POSTGRES_TAG: &str = "16-alpine";

async fn start_postgres() -> (ContainerAsync<Postgres>, String, u16) {
    let container = Postgres::default()
        .with_tag(POSTGRES_TAG)
        .start()
        .await
        .expect("start PostgreSQL fixture");
    let host = container.get_host().await.expect("PostgreSQL host").to_string();
    let port = container.get_host_port_ipv4(5432).await.expect("PostgreSQL port");
    (container, host, port)
}

struct PostgresProvider {
    connection_id: Uuid,
    saved: SavedConnection,
    connection: Arc<dyn Connection>,
}

#[async_trait]
impl ConnectionProvider for PostgresProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        Ok(vec![self.saved.clone()])
    }

    async fn connection(&self, connection_id: Uuid, _principal: Principal) -> Result<Arc<dyn Connection>, String> {
        (connection_id == self.connection_id)
            .then(|| self.connection.clone())
            .ok_or_else(|| "unexpected PostgreSQL connection id".into())
    }
}

fn mcp_context(
    connection: Arc<dyn Connection>,
    host: String,
    port: u16,
) -> (Uuid, McpBridge, tablepro_mcp::McpToken, tempfile::TempDir) {
    let connection_id = Uuid::new_v4();
    let saved = SavedConnection {
        id: connection_id,
        name: "PostgreSQL enum fixture".into(),
        driver_id: "postgres".into(),
        host,
        port,
        socket_dir: None,
        database: "postgres".into(),
        username: "postgres".into(),
        use_tls: false,
        tls_mode: None,
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: true,
        auth_mode: Default::default(),
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    };
    let provider = Arc::new(PostgresProvider {
        connection_id,
        saved,
        connection,
    });
    let directory = tempfile::tempdir().expect("token directory");
    let tokens = Arc::new(TokenStore::open(directory.path().join("tokens.json")).expect("token store"));
    let (_metadata, plaintext) = tokens
        .issue(
            "PostgreSQL enum round trip".into(),
            TokenPermissions::ReadOnly,
            vec![connection_id],
            None,
        )
        .expect("issue read-only MCP token");
    let bridge = McpBridge::new(provider, tokens);
    let token = bridge.authenticate(&plaintext).expect("authenticate MCP token");
    (connection_id, bridge, token, directory)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_custom_enum_labels_and_sql_null_survive_mcp_query_tool() {
    let (_container, host, port) = start_postgres().await;
    let connection = PgDriver
        .connect(ConnectOptions {
            host: host.clone(),
            port,
            database: "postgres".into(),
            username: "postgres".into(),
            password: secrecy::SecretString::new("postgres".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .expect("connect PostgreSQL driver");
    for sql in [
        "CREATE SCHEMA mcp_enum",
        "CREATE TYPE mcp_enum.state AS ENUM ('NULL', '', '東京🙂', 'ready', E'\\\\N', E'\\\\NN')",
        "CREATE TABLE mcp_enum.rows (id INT PRIMARY KEY, status mcp_enum.state)",
        "CREATE TABLE mcp_enum.target_rows (id INT PRIMARY KEY, status mcp_enum.state)",
        "INSERT INTO mcp_enum.rows VALUES (1, 'NULL'), (2, ''), (3, '東京🙂'), (4, NULL), (5, E'\\\\N'), (6, E'\\\\NN')",
    ] {
        connection.execute(sql).await.expect("seed enum fixture");
    }
    let target_columns = connection
        .fetch_columns(Some("mcp_enum"), "target_rows")
        .await
        .expect("fetch import target enum metadata");
    let connection: Arc<dyn Connection> = Arc::from(connection);

    let (connection_id, bridge, token, _directory) = mcp_context(connection.clone(), host, port);

    let sql = "SELECT id, status::text AS label, pg_typeof(status)::text AS native_type FROM mcp_enum.rows ORDER BY id";
    let response = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "execute_query",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": sql,
        }),
    )
    .await
    .expect("dispatch PostgreSQL enum query through MCP");

    assert_eq!(response["columns"], serde_json::json!(["id", "label", "native_type"]));
    assert_eq!(
        response["rows"],
        serde_json::json!([
            [1, "NULL", "mcp_enum.state"],
            [2, "", "mcp_enum.state"],
            [3, "東京🙂", "mcp_enum.state"],
            [4, null, "mcp_enum.state"],
            [5, "\\N", "mcp_enum.state"],
            [6, "\\NN", "mcp_enum.state"],
        ])
    );
    assert_eq!(response["truncated"], false);

    let json_export = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "export_data",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": sql,
            "format": "json",
        }),
    )
    .await
    .expect("export PostgreSQL enum rows as MCP JSON");
    assert_eq!(json_export["format"], "json");
    assert_eq!(json_export["columns"], response["columns"]);
    assert_eq!(json_export["rows"], response["rows"]);

    let csv_sql = "SELECT id, status::text AS status FROM mcp_enum.rows ORDER BY id";
    let csv_export = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "export_data",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": csv_sql,
            "format": "csv",
        }),
    )
    .await
    .expect("export PostgreSQL enum rows as MCP CSV");
    assert_eq!(csv_export["format"], "csv");
    assert_eq!(csv_export["null_marker"], "\\NNN");
    assert_eq!(
        csv_export["content"],
        "id,status\n1,NULL\n2,\"\"\n3,東京🙂\n4,\\NNN\n5,\\N\n6,\\NN\n"
    );

    let null_marker = csv_export["null_marker"].as_str().expect("CSV null marker");
    let content = csv_export["content"].as_str().expect("CSV content");
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker: null_marker.to_owned(),
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(content.as_bytes(), &import_options, None)
        .expect("read MCP CSV with its declared null marker");
    let mapping = [Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("mcp_enum"),
            table: "target_rows",
            columns: &target_columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .expect("plan native enum import from MCP CSV");
    for row in &plan.rows {
        connection
            .execute_params(&plan.statement, row)
            .await
            .expect("import MCP CSV row");
    }
    let restored = connection
        .query("SELECT id, status::text, pg_typeof(status)::text FROM mcp_enum.target_rows ORDER BY id")
        .await
        .expect("read native MCP CSV import");
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("mcp_enum.state".into())
            ],
            vec![
                Value::Int(2),
                Value::Text(String::new()),
                Value::Text("mcp_enum.state".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("東京🙂".into()),
                Value::Text("mcp_enum.state".into())
            ],
            vec![Value::Int(4), Value::Null, Value::Text("mcp_enum.state".into())],
            vec![
                Value::Int(5),
                Value::Text("\\N".into()),
                Value::Text("mcp_enum.state".into())
            ],
            vec![
                Value::Int(6),
                Value::Text("\\NN".into()),
                Value::Text("mcp_enum.state".into())
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_domain_over_enum_values_survive_mcp_query_export_and_csv_import() {
    let (_container, host, port) = start_postgres().await;
    let connection = PgDriver
        .connect(ConnectOptions {
            host: host.clone(),
            port,
            database: "postgres".into(),
            username: "postgres".into(),
            password: secrecy::SecretString::new("postgres".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .expect("connect PostgreSQL driver");
    for sql in [
        "CREATE SCHEMA mcp_domain_enum",
        "CREATE TYPE mcp_domain_enum.state AS ENUM ('NULL', '', '東京', 'ready')",
        "CREATE DOMAIN mcp_domain_enum.state_domain AS mcp_domain_enum.state",
        "CREATE TABLE mcp_domain_enum.rows (id INT PRIMARY KEY, status mcp_domain_enum.state_domain)",
        "CREATE TABLE mcp_domain_enum.target_rows (id INT PRIMARY KEY, status mcp_domain_enum.state_domain)",
        "INSERT INTO mcp_domain_enum.rows VALUES (1, 'NULL'), (2, ''), (3, '東京'), (4, NULL)",
    ] {
        connection.execute(sql).await.expect("seed domain enum fixture");
    }
    let target_columns = connection
        .fetch_columns(Some("mcp_domain_enum"), "target_rows")
        .await
        .expect("fetch domain import target metadata");
    assert_eq!(target_columns[1].enum_type.as_ref().unwrap().name, "state");
    let connection: Arc<dyn Connection> = Arc::from(connection);
    let (connection_id, bridge, token, _directory) = mcp_context(connection.clone(), host, port);

    let sql = "SELECT id, status, pg_typeof(status)::text AS native_type \
               FROM mcp_domain_enum.rows ORDER BY id";
    let response = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "execute_query",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": sql,
        }),
    )
    .await
    .expect("query PostgreSQL domain values through MCP");
    assert_eq!(
        response["rows"],
        serde_json::json!([
            [1, "NULL", "mcp_domain_enum.state_domain"],
            [2, "", "mcp_domain_enum.state_domain"],
            [3, "東京", "mcp_domain_enum.state_domain"],
            [4, null, "mcp_domain_enum.state_domain"],
        ])
    );
    assert_eq!(response["truncated"], false);

    let json_export = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "export_data",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": sql,
            "format": "json",
        }),
    )
    .await
    .expect("export domain values as MCP JSON");
    assert_eq!(json_export["rows"], response["rows"]);
    assert_eq!(json_export["format"], "json");

    let csv_sql = "SELECT id, status FROM mcp_domain_enum.rows ORDER BY id";
    let csv_export = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "export_data",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "sql": csv_sql,
            "format": "csv",
        }),
    )
    .await
    .expect("export domain values as MCP CSV");
    assert_eq!(csv_export["null_marker"], "\\N");
    assert_eq!(csv_export["content"], "id,status\n1,NULL\n2,\"\"\n3,東京\n4,\\N\n");

    let options = tablepro_core::import::CsvImportOptions {
        null_marker: csv_export["null_marker"].as_str().unwrap().into(),
        ..Default::default()
    };
    let content = csv_export["content"].as_str().unwrap();
    let sheet = tablepro_core::import::read_csv(content.as_bytes(), &options, None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("mcp_domain_enum"),
            table: "target_rows",
            columns: &target_columns,
            mapping: &[Some(0), Some(1)],
        },
        &sheet,
        &options,
    )
    .unwrap();
    for row in &plan.rows {
        connection
            .execute_params(&plan.statement, row)
            .await
            .expect("import domain MCP CSV row");
    }
    let restored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM mcp_domain_enum.target_rows ORDER BY id",
        )
        .await
        .expect("verify native MCP domain CSV import");
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("mcp_domain_enum.state_domain".into())
            ],
            vec![
                Value::Int(2),
                Value::Text(String::new()),
                Value::Text("mcp_domain_enum.state_domain".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("東京".into()),
                Value::Text("mcp_domain_enum.state_domain".into())
            ],
            vec![
                Value::Int(4),
                Value::Null,
                Value::Text("mcp_domain_enum.state_domain".into())
            ],
        ]
    );
}
