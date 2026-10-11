#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;

use async_trait::async_trait;
use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Binary, Bson, DateTime, Document, doc, spec::BinarySubtype};
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Environment, TlsConfig};
use tablepro_mcp::{ConnectionProvider, McpBridge, TokenPermissions, TokenStore};
use tablepro_policy::Principal;
use tablepro_storage::SavedConnection;
use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::{mongo::Mongo, testcontainers::runners::AsyncRunner};
use uuid::Uuid;

const MONGO_TAG: &str = "7";

async fn start_mongo() -> (ContainerAsync<Mongo>, String, u16) {
    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .start()
        .await
        .expect("start MongoDB fixture");
    let host = container.get_host().await.expect("MongoDB host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("MongoDB port");
    (container, host, port)
}

fn mongo_options(host: &str, port: u16) -> ConnectOptions {
    ConnectOptions {
        host: host.into(),
        port,
        database: "appdb".into(),
        username: String::new(),
        password: secrecy::SecretString::new(String::new().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    }
}

struct MongoProvider {
    connection_id: Uuid,
    saved: SavedConnection,
    connection: Arc<dyn Connection>,
}

#[async_trait]
impl ConnectionProvider for MongoProvider {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String> {
        Ok(vec![self.saved.clone()])
    }

    async fn connection(&self, connection_id: Uuid, _principal: Principal) -> Result<Arc<dyn Connection>, String> {
        (connection_id == self.connection_id)
            .then(|| self.connection.clone())
            .ok_or_else(|| "unexpected MongoDB connection id".into())
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mongodb_extended_json_survives_the_mcp_query_tool_round_trip() {
    let (_container, host, port) = start_mongo().await;
    let connection = MongodbDriver
        .connect(mongo_options(&host, port))
        .await
        .expect("connect MongoDB driver");
    connection
        .execute(
            r#"db.values.insertOne({"_id":"special","nested":{"amount":{"$numberDecimal":"1234567890123456789.123456789012345"},"when":{"$date":{"$numberLong":"1234567890123"}},"binary":{"$binary":{"base64":"AP9B","subType":"80"}},"large_integer":{"$numberLong":"9007199254740993"},"explicit_null":null,"unicode":"数据库🙂 — café"}})"#,
        )
        .await
        .expect("seed Extended JSON document");

    let native_client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native BSON oracle");
    let stored = native_client
        .database("appdb")
        .collection::<Document>("values")
        .find_one(doc! { "_id": "special" })
        .await
        .expect("read seeded document with native driver")
        .expect("seeded document exists");
    assert_eq!(
        stored.get("nested"),
        Some(&Bson::Document(doc! {
            "amount": Bson::Decimal128("1234567890123456789.123456789012345".parse().unwrap()),
            "when": Bson::DateTime(DateTime::from_millis(1_234_567_890_123)),
            "binary": Bson::Binary(Binary {
                subtype: BinarySubtype::UserDefined(0x80),
                bytes: vec![0, 255, 65],
            }),
            "large_integer": Bson::Int64(9_007_199_254_740_993),
            "explicit_null": Bson::Null,
            "unicode": "数据库🙂 — café",
        })),
        "seed must contain the intended native BSON types before MCP reads it"
    );

    let connection_id = Uuid::new_v4();
    let saved = SavedConnection {
        id: connection_id,
        name: "MongoDB fixture".into(),
        driver_id: "mongodb".into(),
        host: host.clone(),
        port,
        socket_dir: None,
        database: "appdb".into(),
        username: String::new(),
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
    let provider = Arc::new(MongoProvider {
        connection_id,
        saved,
        connection: Arc::from(connection),
    });
    let directory = tempfile::tempdir().expect("token directory");
    let tokens = Arc::new(TokenStore::open(directory.path().join("tokens.json")).expect("token store"));
    let (_metadata, plaintext) = tokens
        .issue(
            "MongoDB round trip".into(),
            TokenPermissions::ReadOnly,
            vec![connection_id],
            None,
        )
        .expect("issue read-only MCP token");
    let bridge = McpBridge::new(provider, tokens);
    let token = bridge.authenticate(&plaintext).expect("authenticate MCP token");

    let response = tablepro_mcp::dispatch(
        &bridge,
        &token,
        "browse_table",
        serde_json::json!({
            "connection_id": connection_id.to_string(),
            "table": "values",
            "offset": 0,
            "limit": 10,
        }),
    )
    .await
    .expect("dispatch MCP query");
    assert_eq!(
        response["rows"][0][1],
        serde_json::json!({
            "amount": {"$numberDecimal": "1234567890123456789.123456789012345"},
            "when": {"$date": {"$numberLong": "1234567890123"}},
            "binary": {"$binary": {"base64": "AP9B", "subType": "80"}},
            "large_integer": {"$numberLong": "9007199254740993"},
            "explicit_null": null,
            "unicode": "数据库🙂 — café",
        }),
        "MCP must return the original nested Extended JSON markers"
    );
}
