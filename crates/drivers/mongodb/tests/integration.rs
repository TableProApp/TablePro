#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
#[path = "support/disconnection.rs"]
mod disconnection;
#[path = "support/hostile_scram.rs"]
mod hostile_scram;
#[path = "../../shared/server_restart.rs"]
mod server_restart;

use drivers_mongodb::MongodbDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, TlsConfig, Value};
use testcontainers::core::IntoContainerPort;
use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::mongo::Mongo;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

/// The module's own default tag is MongoDB 5.0.6, which is long out of
/// support and is not the server this driver is verified against. Pin the
/// same major the TLS fixture uses so both tiers exercise one version.
const MONGO_TAG: &str = "7";

async fn start_mongo() -> (ContainerAsync<Mongo>, String, u16) {
    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .start()
        .await
        .expect("start mongo container");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    (container, host, port)
}

fn opts(host: &str, port: u16, database: &str) -> ConnectOptions {
    ConnectOptions {
        host: host.to_string(),
        port,
        database: database.to_string(),
        username: String::new(),
        password: secrecy::SecretString::new(String::new().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    }
}

#[tokio::test]
async fn an_unavailable_mongodb_server_is_classified_as_connection_refused() {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);

    let error = match MongodbDriver.connect(opts("127.0.0.1", port, "appdb")).await {
        Ok(_) => panic!("an unused local port must not accept MongoDB connections"),
        Err(error) => error,
    };
    assert!(matches!(error, DriverError::ConnectionRefused), "{error:?}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn wrong_mongodb_credentials_are_classified_as_auth_failed() {
    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .with_env_var("MONGO_INITDB_ROOT_USERNAME", "tablepro")
        .with_env_var("MONGO_INITDB_ROOT_PASSWORD", "correct-password")
        .start()
        .await
        .expect("start authenticated MongoDB");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    let mut connection_options = opts(&host, port, "admin");
    connection_options.username = "tablepro".into();
    connection_options.password = secrecy::SecretString::new("wrong-password".to_string().into());

    let mut valid_options = connection_options.clone();
    valid_options.password = secrecy::SecretString::new("correct-password".to_string().into());
    let ready = tokio::time::timeout(std::time::Duration::from_secs(120), async {
        loop {
            match MongodbDriver.connect(valid_options.clone()).await {
                Ok(connection) => break connection,
                Err(DriverError::ConnectionRefused) => {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                Err(error) => panic!("valid MongoDB credentials failed during readiness: {error:?}"),
            }
        }
    })
    .await
    .expect("authenticated MongoDB must become ready within 120 seconds");
    drop(ready);

    let error = match MongodbDriver.connect(connection_options).await {
        Ok(_) => panic!("incorrect credentials must not connect"),
        Err(error) => error,
    };
    assert!(matches!(error, DriverError::AuthFailed), "{error:?}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_lost_mongodb_server_is_reported_as_disconnected() {
    let port_probe = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = port_probe.local_addr().unwrap().port();
    drop(port_probe);
    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .with_mapped_port(port, 27017.tcp())
        .start()
        .await
        .expect("start MongoDB on a stable host port");
    let host = container.get_host().await.expect("host").to_string();
    let options = opts(&host, port, "appdb");
    let connection = MongodbDriver.connect(options.clone()).await.expect("connect");
    connection
        .list_tables()
        .await
        .expect("initial operation confirms server is reachable");

    container.stop().await.expect("stop MongoDB server");
    let error = connection
        .list_tables()
        .await
        .expect_err("an operation after server loss must fail");
    assert!(
        matches!(error, DriverError::Disconnected),
        "loss of an established MongoDB server must be reported as disconnected, got {error:?}"
    );

    container.start().await.expect("restart MongoDB server");
    let recovered = tokio::time::timeout(std::time::Duration::from_secs(60), async {
        server_restart::retry_operation("MongoDB", || async { connection.list_tables().await }).await
    })
    .await
    .expect("MongoDB client recovery must finish within one minute")
    .expect("the existing MongoDB client reconnects after the server restarts");
    assert!(
        recovered.is_empty(),
        "the restarted test database should have no collections"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connection_loss_during_cursor_get_more_fails_the_whole_query() {
    use mongodb::bson::{Document, doc};

    // Skip the bounded sample's getMore, then close the query page's getMore.
    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .with_cmd(["mongod", "--setParameter", "enableTestCommands=1", "--bind_ip_all"])
        .start()
        .await
        .expect("start MongoDB with test failpoints enabled");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    let options = opts(&host, port, "appdb");
    let connection = MongodbDriver.connect(options).await.expect("connect");

    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("native MongoDB client");
    let documents: Vec<Document> = (0..150)
        .map(|index| doc! { "sequence": index, "payload": format!("row-{index}") })
        .collect();
    client
        .database("appdb")
        .collection::<Document>("disconnect_cursor")
        .insert_many(documents)
        .await
        .expect("seed more rows than MongoDB's initial cursor batch");

    client
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "skip": 1, "times": 1 },
            "data": { "failCommands": ["getMore"], "closeConnection": true }
        })
        .await
        .expect("arm one-shot getMore connection loss");

    let error = connection
        .query("db.disconnect_cursor.find({})")
        .await
        .expect_err("cursor loss after the first batch must reject the query");
    assert!(
        matches!(error, DriverError::Disconnected),
        "mid-cursor MongoDB connection loss must be Disconnected, got {error:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cancelled_mongodb_read_leaves_the_client_usable() {
    use mongodb::bson::doc;

    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .with_cmd(["mongod", "--setParameter", "enableTestCommands=1", "--bind_ip_all"])
        .start()
        .await
        .expect("start MongoDB with test failpoints enabled");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    let connection: std::sync::Arc<dyn tablepro_core::Connection> = MongodbDriver
        .connect(opts(&host, port, "appdb"))
        .await
        .expect("connect")
        .into();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("native MongoDB client");
    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "times": 1 },
            "data": {
                "failCommands": ["listCollections"],
                "blockConnection": true,
                "blockTimeMS": 5_000
            }
        })
        .await
        .expect("block one listCollections response");

    let token = tokio_util::sync::CancellationToken::new();
    let control = tablepro_core::OperationControl::new(token.clone(), None);
    let running = connection.clone();
    let task = tokio::spawn(async move { running.list_tables_controlled(&control).await });
    let mut blocked_on_server = false;
    for _ in 0..100 {
        let current = native
            .database("admin")
            .run_command(doc! { "currentOp": 1, "$all": true })
            .await
            .expect("inspect in-flight listCollections operation");
        blocked_on_server = current
            .get_array("inprog")
            .expect("currentOp returns active operations")
            .iter()
            .filter_map(|operation| operation.as_document())
            .filter_map(|operation| operation.get_document("command").ok())
            .any(|command| command.contains_key("listCollections"));
        if blocked_on_server {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(
        blocked_on_server,
        "the MongoDB failpoint must hold listCollections before cancellation"
    );
    token.cancel();

    let error = tokio::time::timeout(std::time::Duration::from_secs(2), task)
        .await
        .expect("cancelled MongoDB operation must return promptly")
        .expect("operation task")
        .expect_err("the blocked operation must be cancelled");
    assert!(
        matches!(error, DriverError::OperationOutcomeUnknown { ref source } if matches!(**source, DriverError::Cancelled)),
        "cancelling an in-flight read must remain distinct from disconnect: {error:?}"
    );

    let tables = tokio::time::timeout(std::time::Duration::from_secs(10), connection.list_tables())
        .await
        .expect("later MongoDB operation must not hang")
        .expect("the same MongoDB client remains usable after cancellation");
    assert!(
        tables.is_empty(),
        "the test database starts with no collections: {tables:?}"
    );
}

async fn seeded_connection(host: &str, port: u16) -> Box<dyn tablepro_core::Connection> {
    let conn = MongodbDriver.connect(opts(host, port, "appdb")).await.expect("connect");
    conn.execute(r#"db.people.insertOne({"name": "ada", "team": "core"})"#)
        .await
        .expect("seed ada");
    conn.execute(r#"db.people.insertOne({"name": "grace", "team": "core"})"#)
        .await
        .expect("seed grace");
    conn.execute(r#"db.people.insertOne({"name": "alan", "team": "ops"})"#)
        .await
        .expect("seed alan");
    conn
}

fn column_values(result: &tablepro_core::QueryResult, column: &str) -> Vec<String> {
    let index = result
        .columns
        .iter()
        .position(|c| c.name == column)
        .unwrap_or_else(|| panic!("column {column} missing from {:?}", result.columns));
    result
        .rows
        .iter()
        .filter_map(|row| match row.get(index) {
            Some(Value::Text(text)) => Some(text.clone()),
            Some(Value::Json(json)) => Some(json.to_string().trim_matches('"').to_string()),
            _ => None,
        })
        .collect()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_inserted_document_is_listed_browsed_and_found() {
    let (_container, host, port) = start_mongo().await;
    let conn = seeded_connection(&host, port).await;

    let collections = conn.list_tables().await.expect("list collections");
    assert!(
        collections.iter().any(|c| c.name == "people"),
        "the seeded collection must be listed: {collections:?}"
    );

    let browsed = conn.fetch_rows(None, "people", 0, 10).await.expect("browse people");
    assert_eq!(browsed.rows.len(), 3, "browse must return every seeded document");

    let found = conn
        .query(r#"db.people.find({"team": "core"})"#)
        .await
        .expect("find by filter");
    let mut names = column_values(&found, "name");
    names.sort();
    assert_eq!(names, vec!["ada".to_string(), "grace".to_string()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_filtered_delete_removes_only_the_matching_documents() {
    let (_container, host, port) = start_mongo().await;
    let conn = seeded_connection(&host, port).await;

    let deleted = conn
        .execute(r#"db.people.deleteMany({"team": "ops"})"#)
        .await
        .expect("delete ops");
    assert_eq!(deleted.rows_affected, 1, "only the ops document matches");

    let remaining = conn.fetch_rows(None, "people", 0, 10).await.expect("browse people");
    assert_eq!(remaining.rows.len(), 2, "the core documents must survive");
    let mut names = column_values(&remaining, "name");
    names.sort();
    assert_eq!(names, vec!["ada".to_string(), "grace".to_string()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_aggregate_pipeline_groups_documents() {
    let (_container, host, port) = start_mongo().await;
    let conn = seeded_connection(&host, port).await;

    let result = conn
        .query(r#"db.people.aggregate([{"$group": {"_id": "$team", "total": {"$sum": 1}}}])"#)
        .await
        .expect("aggregate by team");

    assert_eq!(result.rows.len(), 2, "core and ops must each produce a group");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_dropped_collection_stops_being_listed() {
    let (_container, host, port) = start_mongo().await;
    let conn = seeded_connection(&host, port).await;

    conn.execute("DROP TABLE people").await.expect("drop people");

    let collections = conn.list_tables().await.expect("list collections");
    assert!(
        !collections.iter().any(|c| c.name == "people"),
        "the dropped collection must disappear: {collections:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_unsupported_statement_is_refused_rather_than_silently_ignored() {
    let (_container, host, port) = start_mongo().await;
    let conn = seeded_connection(&host, port).await;

    let error = conn
        .execute("UPDATE people SET name = 'x'")
        .await
        .expect_err("the driver documents insertOne/deleteMany/DROP TABLE only");
    let message = format!("{error}");
    assert!(
        message.contains("insertOne") || message.contains("unsupported"),
        "the refusal must say what is supported, got: {message}"
    );

    let survivors = conn.fetch_rows(None, "people", 0, 10).await.expect("browse people");
    assert_eq!(survivors.rows.len(), 3, "a refused statement must change nothing");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn browsing_a_missing_collection_is_empty_rather_than_an_error() {
    let (_container, host, port) = start_mongo().await;
    let conn = seeded_connection(&host, port).await;

    let browsed = conn
        .fetch_rows(None, "absent", 0, 10)
        .await
        .expect("browsing an absent collection must not fail");
    assert!(browsed.rows.is_empty(), "an absent collection has no rows");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mixed_string_and_decimal128_columns_keep_values_and_refuse_lossy_edit_metadata() {
    use mongodb::bson::{Decimal128, doc};

    let (_container, host, port) = start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("mixed_values");
    let decimal = "12345678901234567890.1234567890123".parse::<Decimal128>().unwrap();
    collection
        .insert_many([
            doc! { "_id": "text", "value": "12345678901234567890.1234567890123" },
            doc! { "_id": "decimal", "value": decimal },
        ])
        .await
        .expect("seed mixed native BSON types");

    let connection = MongodbDriver.connect(opts(&host, port, "appdb")).await.unwrap();
    let columns = connection.fetch_columns(None, "mixed_values").await.unwrap();
    let value_column = columns.iter().find(|column| column.name == "value").unwrap();
    assert_eq!(value_column.data_type, "mixed");

    let result = connection
        .query("db.mixed_values.find({})")
        .await
        .expect("read mixed BSON values");
    let value_index = result.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(result.columns[value_index].data_type, "mixed");
    assert_eq!(result.rows.len(), 2);
    assert!(
        result
            .rows
            .iter()
            .all(|row| matches!(&row[value_index], Value::Json(_))),
        "mixed BSON scalar values must retain canonical Extended JSON types"
    );

    let persisted = collection
        .find_one(doc! { "_id": "decimal" })
        .await
        .expect("read native Decimal128")
        .expect("decimal fixture exists");
    assert_eq!(persisted.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
    let persisted_text = collection
        .find_one(doc! { "_id": "text" })
        .await
        .expect("read native string")
        .expect("string fixture exists");
    assert_eq!(
        persisted_text.get("value"),
        Some(&mongodb::bson::Bson::String(decimal.to_string()))
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mixed_string_decimal128_exports_preserve_bson_kind() {
    use mongodb::bson::{Decimal128, doc};

    let (_container, host, port) = start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("mixed_export_values");
    let decimal_text = "12345678901234567890.1234567890123";
    let decimal = decimal_text.parse::<Decimal128>().unwrap();
    collection
        .insert_many([
            doc! { "_id": "text", "value": decimal_text },
            doc! { "_id": "decimal", "value": decimal },
        ])
        .await
        .expect("seed mixed BSON types");

    let connection = MongodbDriver.connect(opts(&host, port, "appdb")).await.unwrap();
    let result = connection
        .query("db.mixed_export_values.find({})")
        .await
        .expect("read mixed BSON values");
    assert_eq!(
        result
            .columns
            .iter()
            .find(|column| column.name == "value")
            .unwrap()
            .data_type,
        "mixed"
    );

    let mut bytes = Vec::new();
    tablepro_core::export::write_csv_header(&mut bytes, &result.columns).unwrap();
    for row in &result.rows {
        tablepro_core::export::write_csv_row(&mut bytes, row).unwrap();
    }
    let mut csv = csv::Reader::from_reader(bytes.as_slice());
    let headers = csv.headers().unwrap().clone();
    let id_index = headers.iter().position(|header| header == "_id").unwrap();
    let value_index = headers.iter().position(|header| header == "value").unwrap();
    let records = csv
        .records()
        .map(|record| {
            let record = record.unwrap();
            (record[id_index].to_string(), record[value_index].to_string())
        })
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(
        records.get("text").unwrap(),
        &serde_json::to_string(decimal_text).unwrap()
    );
    assert_eq!(
        records.get("decimal").unwrap(),
        &format!(r#"{{"$numberDecimal":"{decimal_text}"}}"#),
        "CSV must retain the BSON Decimal128 marker in a mixed-type column"
    );

    let json: serde_json::Value =
        serde_json::from_str(&tablepro_core::export::render_json(&result.columns, &result.rows)).unwrap();
    let json_rows = json.as_array().unwrap();
    let value_for_id = |id: &str| {
        json_rows
            .iter()
            .find(|row| row["_id"] == id)
            .unwrap()
            .get("value")
            .unwrap()
            .clone()
    };
    assert_eq!(value_for_id("text"), serde_json::json!(decimal_text));
    assert_eq!(
        value_for_id("decimal"),
        serde_json::json!({"$numberDecimal": decimal_text})
    );

    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("mixed-bson.xlsx");
    tablepro_core::export::write_result_file(
        &workbook_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let value_column = result.columns.iter().position(|column| column.name == "value").unwrap();
    let workbook_values = (2..=3)
        .map(|row| xlsx_shared_cell_text(&workbook_path, value_column, row).unwrap())
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(
        workbook_values,
        [
            serde_json::to_string(decimal_text).unwrap(),
            format!(r#"{{"$numberDecimal":"{decimal_text}"}}"#)
        ]
        .into_iter()
        .collect()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn decimal128_csv_round_trip_through_typed_grid_edit_keeps_native_bson() {
    use mongodb::bson::{Decimal128, doc};

    let (_container, host, port) = start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("decimal_csv_round_trip");
    let decimal = "12345678901234567890.1234".parse::<Decimal128>().unwrap();
    collection
        .insert_one(doc! { "_id": "source", "amount": decimal })
        .await
        .expect("seed native Decimal128");

    let connection = MongodbDriver.connect(opts(&host, port, "appdb")).await.unwrap();
    let result = connection
        .query("db.decimal_csv_round_trip.find({})")
        .await
        .expect("read source Decimal128");
    let id_index = result.columns.iter().position(|column| column.name == "_id").unwrap();
    let amount_index = result
        .columns
        .iter()
        .position(|column| column.name == "amount")
        .unwrap();
    assert_eq!(result.columns[amount_index].data_type, "decimal");
    assert_eq!(result.rows[0][amount_index], Value::Text(decimal.to_string()));

    let csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let import_columns = [result.columns[id_index].clone(), result.columns[amount_index].clone()];
    let imported =
        tablepro_core::import::row_to_values(&sheet.rows[0], &[Some(0), Some(1)], &import_columns, &import_options, 2)
            .unwrap();
    assert!(matches!(imported[1], Value::Decimal(_)), "{:?}", imported[1]);

    let mut columns = result.columns.clone();
    columns[id_index].primary_key = true;
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "decimal_csv_round_trip",
        &columns,
        &[(amount_index, imported[1].clone())],
        &[imported[0].clone()],
    )
    .unwrap();
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply typed imported edit");

    let persisted = collection
        .find_one(doc! { "_id": "source" })
        .await
        .expect("read persisted Decimal128")
        .expect("source document exists");
    assert_eq!(persisted.get("amount"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn negative_decimal128_csv_formula_marker_round_trips_as_native_decimal128() {
    use mongodb::bson::{Decimal128, doc};

    let (_container, host, port) = start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("negative_decimal_csv_round_trip");
    let decimal = "-123.45".parse::<Decimal128>().unwrap();
    collection
        .insert_one(doc! { "_id": "source", "amount": decimal })
        .await
        .expect("seed negative Decimal128");

    let connection = MongodbDriver.connect(opts(&host, port, "appdb")).await.unwrap();
    let result = connection
        .query("db.negative_decimal_csv_round_trip.find({})")
        .await
        .expect("read source Decimal128");
    let id_index = result.columns.iter().position(|column| column.name == "_id").unwrap();
    let amount_index = result
        .columns
        .iter()
        .position(|column| column.name == "amount")
        .unwrap();
    assert_eq!(result.columns[amount_index].data_type, "decimal");

    let csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    assert!(csv.contains("\"'-123.45\""), "{csv}");
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let import_columns = [result.columns[id_index].clone(), result.columns[amount_index].clone()];
    let imported =
        tablepro_core::import::row_to_values(&sheet.rows[0], &[Some(0), Some(1)], &import_columns, &import_options, 2)
            .expect("valid formula marker is removed for the typed decimal column");
    assert!(matches!(imported[1], Value::Decimal(_)), "{:?}", imported[1]);

    let mut columns = result.columns.clone();
    columns[id_index].primary_key = true;
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "negative_decimal_csv_round_trip",
        &columns,
        &[(amount_index, imported[1].clone())],
        &[imported[0].clone()],
    )
    .unwrap();
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply typed imported edit");

    let persisted = collection
        .find_one(doc! { "_id": "source" })
        .await
        .expect("read persisted Decimal128")
        .expect("source document exists");
    assert_eq!(persisted.get("amount"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bounded_metadata_sample_merges_types_from_the_requested_page() {
    use mongodb::bson::{Decimal128, doc};

    let (_container, host, port) = start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("late_mixed_values");
    let decimal_text = "12345678901234567890.1234567890123";
    let decimal = decimal_text.parse::<Decimal128>().unwrap();
    let mut docs = (0..128)
        .map(|index| doc! { "_id": index, "value": decimal_text })
        .collect::<Vec<_>>();
    docs.push(doc! { "_id": 128, "value": decimal });
    collection
        .insert_many(docs)
        .await
        .expect("seed metadata sample and page");

    let connection = MongodbDriver.connect(opts(&host, port, "appdb")).await.unwrap();
    let page = connection.fetch_rows(None, "late_mixed_values", 0, 1).await.unwrap();
    let id_index = page.columns.iter().position(|column| column.name == "_id").unwrap();
    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0][id_index], Value::Int(0));
    assert_eq!(page.columns[value_index].data_type, "string");
    assert_eq!(page.rows[0][value_index], Value::Text(decimal_text.into()));

    let query_page = connection
        .query("db.late_mixed_values.find({}).limit(1)")
        .await
        .unwrap();
    let query_value_index = query_page
        .columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    assert_eq!(query_page.columns[query_value_index].data_type, "string");
    assert_eq!(query_page.rows[0][query_value_index], Value::Text(decimal_text.into()));

    let late_page = connection.fetch_rows(None, "late_mixed_values", 128, 1).await.unwrap();
    let late_id_index = late_page
        .columns
        .iter()
        .position(|column| column.name == "_id")
        .unwrap();
    let late_value_index = late_page
        .columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    assert_eq!(late_page.rows[0][late_id_index], Value::Int(128));
    assert_eq!(late_page.columns[late_value_index].data_type, "mixed");
    assert_eq!(
        late_page.rows[0][late_value_index],
        Value::Json(serde_json::json!({"$numberDecimal": decimal_text}))
    );

    let late_query = connection
        .query("db.late_mixed_values.find({}).skip(128).limit(1)")
        .await
        .unwrap();
    let late_query_value_index = late_query
        .columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    assert_eq!(
        late_query.rows[0][late_query_value_index],
        Value::Json(serde_json::json!({"$numberDecimal": decimal_text}))
    );

    let persisted = collection
        .find_one(doc! { "_id": 128 })
        .await
        .expect("read late native value")
        .expect("late collection document exists");
    assert_eq!(persisted.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn browse_pages_use_stable_id_order_and_zero_limit_returns_no_rows() {
    use mongodb::bson::doc;

    let (_container, host, port) = start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    client
        .database("appdb")
        .collection::<mongodb::bson::Document>("out_of_order")
        .insert_many([
            doc! { "_id": 3, "value": "third" },
            doc! { "_id": 1, "value": "first" },
            doc! { "_id": 2, "value": "second" },
        ])
        .await
        .expect("seed out-of-order documents");

    let connection = MongodbDriver.connect(opts(&host, port, "appdb")).await.unwrap();
    let page = connection.fetch_rows(None, "out_of_order", 1, 1).await.unwrap();
    let id_index = page.columns.iter().position(|column| column.name == "_id").unwrap();
    assert_eq!(page.rows[0][id_index], Value::Int(2));
    assert_eq!(page.rows[0], vec![Value::Int(2), Value::Text("second".into())]);

    let empty = connection.fetch_rows(None, "out_of_order", 0, 0).await.unwrap();
    assert!(empty.rows.is_empty());
}

fn excel_column_name(index: usize) -> String {
    let mut letters = Vec::new();
    let mut remainder = index;
    loop {
        let offset = u8::try_from(remainder % 26).unwrap();
        letters.push(char::from(b'A' + offset));
        if remainder < 26 {
            break;
        }
        remainder = remainder / 26 - 1;
    }
    letters.iter().rev().collect()
}

fn unescape_xml(text: &str) -> String {
    let mut decoded = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        decoded.push_str(&rest[..amp]);
        let Some(end) = rest[amp..].find(';') else {
            decoded.push_str(&rest[amp..]);
            return decoded;
        };
        let entity = &rest[amp..=amp + end];
        decoded.push_str(match entity {
            "&amp;" => "&",
            "&lt;" => "<",
            "&gt;" => ">",
            "&quot;" => "\"",
            "&apos;" => "'",
            _ => entity,
        });
        rest = &rest[amp + end + 1..];
    }
    decoded.push_str(rest);
    decoded
}

fn xml_text_content(entry: &str) -> String {
    let mut text = String::new();
    let mut rest = entry;
    while let Some(start) = rest.find("<t") {
        let from_tag = &rest[start..];
        let Some(gt) = from_tag.find('>') else {
            break;
        };
        if from_tag[..gt].ends_with('/') {
            rest = &from_tag[gt + 1..];
            continue;
        }
        let after = &from_tag[gt + 1..];
        let Some(close) = after.find("</t>") else {
            break;
        };
        text.push_str(&unescape_xml(&after[..close]));
        rest = &after[close + 4..];
    }
    text
}

fn worksheet_cell<'a>(sheet: &'a str, reference: &str) -> Option<&'a str> {
    let token = format!("r=\"{reference}\"");
    let at = sheet.find(&token)?;
    let start = sheet[..at].rfind("<c ")?;
    let end = sheet[at..].find("</c>")? + at + "</c>".len();
    Some(&sheet[start..end])
}

fn shared_string_index(element: &str) -> Option<usize> {
    let start = element.find("<v>")? + "<v>".len();
    let end = start + element[start..].find("</v>")?;
    element[start..end].trim().parse().ok()
}

fn shared_string_at(strings: &str, index: usize) -> Option<String> {
    let entry = strings.split("<si>").nth(index + 1)?;
    let end = entry.find("</si>").unwrap_or(entry.len());
    Some(xml_text_content(&entry[..end]))
}

fn read_zip_text(path: &std::path::Path, name: &str) -> Result<String, String> {
    let file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|error| error.to_string())?;
    let mut entry = archive.by_name(name).map_err(|error| format!("{name}: {error}"))?;
    let mut text = String::new();
    std::io::Read::read_to_string(&mut entry, &mut text).map_err(|error| error.to_string())?;
    Ok(text)
}

fn xlsx_shared_cell_text(path: &std::path::Path, column: usize, row: u32) -> Result<String, String> {
    let sheet = read_zip_text(path, "xl/worksheets/sheet1.xml")?;
    let strings = read_zip_text(path, "xl/sharedStrings.xml")?;
    let reference = format!("{}{row}", excel_column_name(column));
    let element = worksheet_cell(&sheet, &reference).ok_or_else(|| format!("missing cell {reference}"))?;
    if !element.contains("t=\"s\"") {
        return Err(format!("cell {reference} is not a shared string: {element}"));
    }
    let index =
        shared_string_index(element).ok_or_else(|| format!("cell {reference} has no string index: {element}"))?;
    shared_string_at(&strings, index).ok_or_else(|| format!("shared string {index} missing"))
}

#[path = "support/census_cost.rs"]
mod census_cost;

#[path = "support/browse_keyset.rs"]
mod browse_keyset;

#[path = "support/census_cancellation.rs"]
mod census_cancellation;

#[path = "support/nested_filters.rs"]
mod nested_filters;

#[path = "support/run_find_late_type_contract.rs"]
mod run_find_late_type_contract;

#[path = "support/query_budget_contract.rs"]
mod query_budget_contract;

#[path = "support/database_listing.rs"]
mod database_listing;
#[path = "support/value_contracts.rs"]
mod value_contracts;

#[path = "support/stale_grid_edit_contract.rs"]
mod stale_grid_edit_contract;

#[path = "support/stale_grid_delete_contract.rs"]
mod stale_grid_delete_contract;
