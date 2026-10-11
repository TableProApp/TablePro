use super::grid_render::column_layout_matches;
use super::value_parse::parse_input_for_grid_cell;
use super::{
    BrowsePageRequest, PageRequestTracker, RowCountRequestTracker, columns_for_browse_page, projection_for_loaded_page,
};
use tablepro_core::{ColumnInfo, QueryResult, Value};
use uuid::Uuid;

fn column(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn assert_cell_read_only(column: &ColumnInfo, value: &Value) {
    assert!(!crate::ui::grid::cell_allows_inline_edit(column, value));
}

#[test]
fn only_the_latest_browse_page_request_is_accepted() {
    let tracker = PageRequestTracker::default();
    let older = tracker.begin(0);
    let newer = tracker.begin(0);

    assert!(!tracker.accepts(older, 0));
    assert!(tracker.accepts(newer, 0));
}

#[test]
fn an_empty_page_uses_full_schema_headers_without_a_sparse_row_map() {
    let result = QueryResult {
        columns: Vec::new(),
        rows: Vec::new(),
        truncated: false,
    };
    assert_eq!(projection_for_loaded_page(&result, Some(vec![0, 2])), None);
}

#[test]
fn sqlite_grid_parses_unknown_numeric_affinity_values_without_losing_precision() {
    let enum_column = column("value", "ENUM", false);
    assert_eq!(
        parse_input_for_grid_cell("queued", Some(&enum_column), "sqlite", None),
        Ok(Value::Text("queued".into()))
    );
    assert_eq!(
        parse_input_for_grid_cell("3.5", Some(&enum_column), "sqlite", None),
        Ok(Value::Decimal(rust_decimal::Decimal::new(35, 1)))
    );
    for unsafe_number in ["1e999", "1e-400", "0.123456789012345678901234567890123"] {
        assert!(
            parse_input_for_grid_cell(unsafe_number, Some(&enum_column), "sqlite", None).is_err(),
            "unsafe SQLite NUMERIC-affinity input must be refused: {unsafe_number}"
        );
    }
    assert_eq!(
        parse_input_for_grid_cell("3.5", Some(&enum_column), "postgres", None),
        Ok(Value::Text("3.5".into()))
    );
}

#[test]
fn only_the_latest_row_count_request_is_accepted() {
    let tracker = RowCountRequestTracker::default();
    let older = tracker.begin();
    let newer = tracker.begin();

    assert!(!tracker.accepts(older));
    assert!(tracker.accepts(newer));
}

#[test]
fn browse_page_response_must_match_the_current_offset() {
    let tracker = PageRequestTracker::default();
    let request = tracker.begin(100);
    let same_id_wrong_offset = BrowsePageRequest {
        id: request.id,
        offset: 100,
    };

    assert!(!tracker.accepts(same_id_wrong_offset, 200));
    assert_ne!(request.id, Uuid::nil());
}

#[test]
fn mongodb_page_schema_updates_late_fields_and_mixed_types_before_grid_editing() {
    let loaded = vec![column("_id", "ObjectId", true), column("value", "string", false)];
    let page_columns = vec![
        column("_id", "ObjectId", true),
        column("value", "mixed", false),
        column("late_field", "Decimal128", false),
    ];
    let page = QueryResult {
        columns: page_columns.clone(),
        rows: vec![vec![
            Value::Uuid(Uuid::new_v4()),
            Value::Json(serde_json::json!({"$numberDecimal": "1.25"})),
            Value::Text("late".into()),
        ]],
        truncated: false,
    };

    let effective = columns_for_browse_page("mongodb", &loaded, Some(&page));
    assert_eq!(effective, page_columns);
    assert_eq!(effective[1].data_type, "mixed");
    assert_eq!(effective[2].name, "late_field");
    assert!(
        !column_layout_matches(&loaded, &effective),
        "new page metadata must rebuild cached factories and editability"
    );
    let text_value = Value::Text("ordinary text on the mixed page".into());
    assert!(crate::ui::grid::cell_allows_inline_edit(&loaded[1], &text_value));
    assert!(
        !crate::ui::grid::cell_allows_inline_edit(&effective[1], &text_value),
        "page-discovered mixed BSON types must make the same text cell read-only"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_collection_wide_mixed_metadata_refuses_edit() {
    use tablepro_core::OperationControl;

    let (_container, connection, collection, decimal) = mongodb_late_mixed_page_fixture().await;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let loaded_columns = connection
        .fetch_columns_controlled(None, "page_mixed_edit_contract", &control)
        .await
        .unwrap();
    let loaded_value_index = loaded_columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(loaded_columns[loaded_value_index].data_type, "mixed");

    let page = connection
        .fetch_rows_controlled(None, "page_mixed_edit_contract", 0, 1, &control)
        .await
        .unwrap();
    let effective_columns = columns_for_browse_page("mongodb", &loaded_columns, Some(&page));
    let value_index = effective_columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    let id_index = effective_columns
        .iter()
        .position(|column| column.name == "_id")
        .unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0][id_index], Value::Int(0));
    assert_eq!(effective_columns[value_index].data_type, "mixed");
    assert!(column_layout_matches(&loaded_columns, &effective_columns));
    assert_cell_read_only(&effective_columns[value_index], &page.rows[0][value_index]);

    let later_page = connection
        .fetch_rows_controlled(None, "page_mixed_edit_contract", 50, 1, &control)
        .await
        .unwrap();
    let later_columns = columns_for_browse_page("mongodb", &loaded_columns, Some(&later_page));
    let later_value_index = later_columns.iter().position(|column| column.name == "value").unwrap();
    let later_id_index = later_columns.iter().position(|column| column.name == "_id").unwrap();
    assert_eq!(later_page.rows[0][later_id_index], Value::Int(50));
    assert_eq!(
        later_page.rows[0][later_value_index],
        Value::Json(serde_json::json!({"$numberDecimal": decimal.to_string()}))
    );
    assert_eq!(later_columns[later_value_index].data_type, "mixed");
    assert!(column_layout_matches(&loaded_columns, &later_columns));
    assert_cell_read_only(
        &later_columns[later_value_index],
        &later_page.rows[0][later_value_index],
    );

    let persisted = collection
        .find_one(mongodb::bson::doc! { "_id": 50 })
        .await
        .unwrap()
        .unwrap();
    assert_eq!(persisted.get("_id"), Some(&mongodb::bson::Bson::Int32(50)));
    assert_eq!(persisted.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_off_page_type_change_during_census_refuses_edit() {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::OperationControl;

    let (_container, native, collection, connection) = mongodb_census_race_fixture().await;

    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "times": 1 },
            "data": {
                "failCommands": ["getMore"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .unwrap();
    let page_connection = connection.clone();
    let page_task = tokio::spawn(async move {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        page_connection
            .fetch_rows_controlled(None, "page_census_race", 0, 2, &control)
            .await
    });

    assert!(wait_for_mongodb_command(&native, "getMore").await);

    let decimal: Decimal128 = "12345678901234567890.1234567890123".parse().unwrap();
    collection
        .update_one(doc! { "_id": 127 }, doc! { "$set": { "value": decimal } })
        .await
        .unwrap();
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .unwrap();
    let page = tokio::time::timeout(std::time::Duration::from_secs(6), page_task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    assert_mongodb_census_race_page(&page);

    let changed = collection.find_one(doc! { "_id": 127 }).await.unwrap().unwrap();
    let sibling = collection.find_one(doc! { "_id": 1 }).await.unwrap().unwrap();
    assert_eq!(changed.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
    assert_eq!(
        sibling.get("value"),
        Some(&mongodb::bson::Bson::String("sibling".into()))
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_census_is_not_a_snapshot_for_already_read_documents() {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::OperationControl;

    let (_container, native, collection, connection) = mongodb_census_race_fixture().await;

    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "times": 1 },
            "data": {
                "failCommands": ["getMore"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .unwrap();
    let page_connection = connection.clone();
    let page_task = tokio::spawn(async move {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        page_connection
            .fetch_rows_controlled(None, "page_census_race", 0, 2, &control)
            .await
    });

    assert!(wait_for_mongodb_command(&native, "getMore").await);
    let decimal: Decimal128 = "12345678901234567890.1234567890123".parse().unwrap();
    collection
        .update_one(doc! { "_id": 0 }, doc! { "$set": { "value": decimal } })
        .await
        .unwrap();
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .unwrap();
    let page = tokio::time::timeout(std::time::Duration::from_secs(6), page_task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    let id_index = page.columns.iter().position(|column| column.name == "_id").unwrap();
    let first_row = page.rows.iter().find(|row| row[id_index] == Value::Int(0)).unwrap();
    assert_eq!(page.columns[value_index].data_type, "string");
    assert_eq!(first_row[value_index], Value::Text("before".into()));
    let persisted = collection.find_one(doc! { "_id": 0 }).await.unwrap().unwrap();
    assert_eq!(persisted.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
    // MongoDB does not give this collection scan snapshot semantics. The
    // cursor returns the value it read before the concurrent update.
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_browse_uses_a_bounded_sample_and_page_find() {
    use tablepro_core::OperationControl;

    let (_container, native, _collection, connection) = mongodb_census_race_fixture().await;
    let before = mongodb_find_command_count(&native).await;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
    let page = connection
        .fetch_rows_controlled(None, "page_census_race", 0, 1, &control)
        .await
        .unwrap();
    let after = mongodb_find_command_count(&native).await;
    assert_eq!(after - before, 2, "bounded schema sample and page use separate finds");
    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(page.columns[value_index].data_type, "string");
    assert_eq!(page.rows[0][value_index], Value::Text("before".into()));
}

async fn mongodb_find_command_count(native: &mongodb::Client) -> i64 {
    native
        .database("admin")
        .run_command(mongodb::bson::doc! { "serverStatus": 1 })
        .await
        .unwrap()
        .get_document("metrics")
        .unwrap()
        .get_document("commands")
        .unwrap()
        .get_document("find")
        .unwrap()
        .get_i64("total")
        .unwrap()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_run_find_merges_page_types_and_exports_materialized_values() {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::OperationControl;

    let (_container, native, collection, connection) = mongodb_census_race_fixture().await;
    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "skip": 1 },
            "data": {
                "failCommands": ["find"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .unwrap();
    let page_connection = connection.clone();
    let query_task = tokio::spawn(async move {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        page_connection
            .query_controlled("db.page_census_race.find({\"_id\":0})", &control)
            .await
    });

    assert!(wait_for_mongodb_command(&native, "find").await);
    let decimal: Decimal128 = "12345678901234567890.1234567890123".parse().unwrap();
    collection
        .update_one(doc! { "_id": 0 }, doc! { "$set": { "value": decimal } })
        .await
        .unwrap();
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .unwrap();
    let result = tokio::time::timeout(std::time::Duration::from_secs(6), query_task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    let value_index = result.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(result.columns[value_index].data_type, "mixed");
    assert_eq!(
        result.rows[0][value_index],
        Value::Json(serde_json::json!({ "$numberDecimal": decimal.to_string() }))
    );

    assert_decimal_export_formats(&result, &decimal.to_string());
}

fn assert_decimal_export_formats(result: &QueryResult, decimal: &str) {
    let temp = tempfile::tempdir().unwrap();
    for (format, extension) in [
        (tablepro_core::export::ResultFormat::Csv, "csv"),
        (tablepro_core::export::ResultFormat::Json, "json"),
    ] {
        let path = temp.path().join(format!("result.{extension}"));
        let csv = tablepro_core::export::CsvOptions::default();
        let export = tablepro_core::export::ResultExport {
            format,
            csv: &csv,
            sql: None,
        };
        tablepro_core::export::write_result_file(&path, result, &export, || false, |_| {}).unwrap();
        let contents = std::fs::read_to_string(path).unwrap();
        assert!(contents.contains("$numberDecimal"), "{extension}: {contents}");
        assert!(contents.contains(decimal), "{extension}: {contents}");
    }
}

async fn mongodb_census_race_fixture() -> (
    testcontainers::ContainerAsync<testcontainers_modules::mongo::Mongo>,
    mongodb::Client,
    mongodb::Collection<mongodb::bson::Document>,
    std::sync::Arc<dyn tablepro_core::Connection>,
) {
    use mongodb::bson::{Document, doc};
    use tablepro_core::DatabaseDriver;
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mongo::Mongo;

    let container = Mongo::default()
        .with_tag("7")
        .with_cmd(["mongod", "--setParameter", "enableTestCommands=1", "--bind_ip_all"])
        .start()
        .await
        .unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = native.database("appdb").collection::<Document>("page_census_race");
    let documents = (0..150)
        .map(|id| doc! { "_id": id, "value": if id == 0 { "before" } else { "sibling" } })
        .collect::<Vec<_>>();
    collection.insert_many(documents).await.unwrap();
    let connection = drivers_mongodb::MongodbDriver
        .connect(tablepro_core::ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            tls: tablepro_core::TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap()
        .into();
    (container, native, collection, connection)
}

async fn wait_for_mongodb_command(native: &mongodb::Client, name: &str) -> bool {
    use mongodb::bson::doc;

    for _ in 0..40 {
        let current = native
            .database("admin")
            .run_command(doc! { "currentOp": 1, "$all": true })
            .await
            .unwrap();
        let command_blocked = current
            .get_array("inprog")
            .unwrap()
            .iter()
            .filter_map(|operation| operation.as_document())
            .filter_map(|operation| operation.get_document("command").ok())
            .any(|command| {
                if name == "find" {
                    command.get_str(name).ok() == Some("page_census_race")
                } else {
                    command.contains_key(name) && command.get_str("collection").ok() == Some("page_census_race")
                }
            });
        if command_blocked {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    false
}

fn assert_mongodb_census_race_page(page: &QueryResult) {
    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    let id_index = page.columns.iter().position(|column| column.name == "_id").unwrap();
    assert_eq!(page.rows.len(), 2);
    let first_row = page.rows.iter().find(|row| row[id_index] == Value::Int(0)).unwrap();
    let sibling_row = page.rows.iter().find(|row| row[id_index] == Value::Int(1)).unwrap();
    assert_eq!(
        first_row[value_index],
        Value::Json(serde_json::json!("before")),
        "the page row must retain the value read from the cursor"
    );
    assert_eq!(sibling_row[value_index], Value::Json(serde_json::json!("sibling")));
    assert_eq!(page.columns[value_index].data_type, "mixed");
    assert_cell_read_only(&page.columns[value_index], &first_row[value_index]);
}

async fn mongodb_late_mixed_page_fixture() -> (
    testcontainers::ContainerAsync<testcontainers_modules::mongo::Mongo>,
    Box<dyn tablepro_core::Connection>,
    mongodb::Collection<mongodb::bson::Document>,
    mongodb::bson::Decimal128,
) {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::DatabaseDriver;
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mongo::Mongo;

    let container = Mongo::default().with_tag("7").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("page_mixed_edit_contract");
    let decimal_text = "12345678901234567890.1234567890123";
    let decimal = decimal_text.parse::<Decimal128>().unwrap();
    let mut docs = (0..50)
        .map(|index| doc! { "_id": index, "value": "ordinary text" })
        .collect::<Vec<_>>();
    docs.push(doc! { "_id": 50, "value": decimal });
    collection.insert_many(docs).await.unwrap();

    let connection = drivers_mongodb::MongodbDriver
        .connect(tablepro_core::ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            tls: tablepro_core::TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    (container, connection, collection, decimal)
}

#[test]
fn page_metadata_does_not_replace_schema_for_other_drivers() {
    let loaded = vec![column("value", "numeric", false)];
    let page = QueryResult {
        columns: vec![column("value", "text", false)],
        rows: Vec::new(),
        truncated: false,
    };
    assert_eq!(columns_for_browse_page("postgres", &loaded, Some(&page)), loaded);
}

#[test]
fn same_count_type_change_invalidates_cached_grid_factories() {
    let rendered = vec![column("value", "string", false)];
    let current = vec![column("value", "mixed", false)];
    assert!(!column_layout_matches(&rendered, &current));
    assert!(column_layout_matches(&current, &current));
}
