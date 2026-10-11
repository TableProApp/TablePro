use drivers_mongodb::MongodbDriver;
use tablepro_core::{DatabaseDriver, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_preserves_numbers_and_text_through_json_commands() {
    let (_container, host, port) = super::start_mongo().await;
    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let corpus: serde_json::Value =
        serde_json::from_str(include_str!("../../../../../testdata/value-contract.json")).unwrap();
    let mut cases = vec![(serde_json::Value::Null, Value::Null)];
    for text in corpus["integers"].as_array().unwrap() {
        let number: i64 = text.as_str().unwrap().parse().unwrap();
        cases.push((serde_json::json!(number), Value::Int(number)));
    }
    for text in corpus["floats"].as_array().unwrap() {
        let number: f64 = text.as_str().unwrap().parse().unwrap();
        cases.push((serde_json::json!(number), Value::Float(number)));
    }
    for text in corpus["texts"].as_array().unwrap() {
        cases.push((text.clone(), Value::Text(text.as_str().unwrap().into())));
    }
    let long = "x".repeat(corpus["long_text_bytes"].as_u64().unwrap() as usize);
    cases.push((serde_json::json!(&long), Value::Text(long)));
    for (id, (input, expected)) in cases.into_iter().enumerate() {
        let document = serde_json::json!({"_id": id, "value": input});
        connection
            .execute(&format!("db.values.insertOne({document})"))
            .await
            .unwrap();
        let query = format!("db.values.find({{\"_id\":{id}}})");
        let result = connection.query(&query).await.unwrap();
        let column = result.columns.iter().position(|column| column.name == "value").unwrap();
        assert_eq!(result.rows.len(), 1);
        let expected = if result.columns[column].data_type == "mixed" {
            let bson = match &expected {
                Value::Null => mongodb::bson::Bson::Null,
                Value::Bool(value) => mongodb::bson::Bson::Boolean(*value),
                Value::Int(value) => mongodb::bson::Bson::Int64(*value),
                Value::Float(value) => mongodb::bson::Bson::Double(*value),
                Value::Text(value) => mongodb::bson::Bson::String(value.clone()),
                value => panic!("unexpected value-contract case: {value:?}"),
            };
            Value::Json(bson.into_canonical_extjson())
        } else {
            expected
        };
        assert_eq!(result.rows[0][column], expected);
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_missing_fields_remain_distinct_from_bson_null() {
    use mongodb::bson::{Bson, Document, doc};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect direct BSON fixture client");
    let collection = client.database("appdb").collection::<Document>("sparse_values");
    collection
        .insert_many([doc! { "_id": 1, "value": Bson::Null }, doc! { "_id": 2 }])
        .await
        .expect("insert explicit-null and missing-field documents");

    let explicit_null = collection.find_one(doc! { "_id": 1 }).await.unwrap().unwrap();
    let missing = collection.find_one(doc! { "_id": 2 }).await.unwrap().unwrap();
    assert_eq!(explicit_null.get("value"), Some(&Bson::Null));
    assert!(!missing.contains_key("value"));

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let result = connection.query("db.sparse_values.find({})").await.unwrap();
    let id_column = result.columns.iter().position(|column| column.name == "_id").unwrap();
    let value_column = result.columns.iter().position(|column| column.name == "value").unwrap();
    let value_for = |id| {
        result
            .rows
            .iter()
            .find(|row| row[id_column] == Value::Int(id))
            .map(|row| &row[value_column])
            .unwrap()
    };

    assert_eq!(value_for(1), &Value::Null);
    assert_eq!(
        value_for(2),
        &Value::Undecodable("missing BSON field".into()),
        "a missing field must not become an editable explicit BSON null"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn nested_bson_special_values_keep_exact_extended_json_types() {
    use mongodb::bson::{Binary, DateTime, Decimal128, doc, spec::BinarySubtype};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect direct BSON fixture client");
    let document = doc! {
        "_id": "special",
        "decimal_min": "1E-6176".parse::<Decimal128>().unwrap(),
        "decimal_max": "9.999999999999999999999999999999999E+6144"
            .parse::<Decimal128>()
            .unwrap(),
        "date_min": DateTime::from_millis(i64::MIN),
        "date_max": DateTime::from_millis(i64::MAX),
        "uuid_binary": Binary { subtype: BinarySubtype::Uuid, bytes: (0..16).collect() },
        "user_binary": Binary { subtype: BinarySubtype::UserDefined(0x80), bytes: vec![0, 255, 65] },
        "nested": {
            "amount": "1234567890123456789.123456789012345"
                .parse::<Decimal128>()
                .unwrap(),
            "blob": Binary { subtype: BinarySubtype::Generic, bytes: vec![0, 255, 65] },
            "when": DateTime::from_millis(1_234_567_890_123),
            "large_integer": mongodb::bson::Bson::Int64(9_007_199_254_740_993),
            "explicit_null": mongodb::bson::Bson::Null,
            "unicode": "数据库🙂 — café",
        },
    };
    client
        .database("appdb")
        .collection::<mongodb::bson::Document>("special_values")
        .insert_one(document)
        .await
        .expect("insert exact BSON fixture");

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let result = connection
        .query(r#"db.special_values.find({"_id":"special"})"#)
        .await
        .expect("read exact BSON fixture");
    let nested = result
        .columns
        .iter()
        .position(|column| column.name == "nested")
        .unwrap();
    let column = |name: &str| result.columns.iter().position(|column| column.name == name).unwrap();
    assert_eq!(result.rows.len(), 1);
    assert_eq!(result.rows[0][column("decimal_min")], Value::Text("1E-6176".into()));
    assert_eq!(
        result.rows[0][column("decimal_max")],
        Value::Text("9.999999999999999999999999999999999E+6144".into())
    );
    for millis in [i64::MIN, i64::MAX] {
        let name = if millis < 0 { "date_min" } else { "date_max" };
        assert_eq!(
            result.rows[0][column(name)],
            Value::Json(serde_json::json!({"$date": {"$numberLong": millis.to_string()}}))
        );
    }
    for (name, expected) in [
        (
            "uuid_binary",
            serde_json::json!({"$binary": {"base64": "AAECAwQFBgcICQoLDA0ODw==", "subType": "04"}}),
        ),
        (
            "user_binary",
            serde_json::json!({"$binary": {"base64": "AP9B", "subType": "80"}}),
        ),
    ] {
        assert_eq!(result.rows[0][column(name)], Value::Json(expected));
    }
    assert_eq!(
        result.rows[0][nested],
        Value::Json(serde_json::json!({
            "amount": {"$numberDecimal": "1234567890123456789.123456789012345"},
            "blob": {"$binary": {"base64": "AP9B", "subType": "00"}},
            "when": {"$date": {"$numberLong": "1234567890123"}},
            "large_integer": {"$numberLong": "9007199254740993"},
            "explicit_null": null,
            "unicode": "数据库🙂 — café",
        }))
    );

    let exported: serde_json::Value =
        serde_json::from_str(&tablepro_core::export::render_json(&result.columns, &result.rows))
            .expect("parse JSON export");
    assert_eq!(
        exported[0]["nested"],
        serde_json::json!({
            "amount": {"$numberDecimal": "1234567890123456789.123456789012345"},
            "blob": {"$binary": {"base64": "AP9B", "subType": "00"}},
            "when": {"$date": {"$numberLong": "1234567890123"}},
            "large_integer": {"$numberLong": "9007199254740993"},
            "explicit_null": null,
            "unicode": "数据库🙂 — café",
        }),
        "JSON export must keep BSON extended types nested"
    );
    assert_eq!(
        exported[0]["uuid_binary"],
        serde_json::json!({"$binary": {"base64": "AAECAwQFBgcICQoLDA0ODw==", "subType": "04"}}),
        "JSON export must keep the UUID binary subtype"
    );

    let csv_output = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let mut csv_reader = csv::Reader::from_reader(csv_output.as_bytes());
    let headers = csv_reader.headers().expect("CSV headers").clone();
    let record = csv_reader.records().next().expect("CSV row").expect("valid CSV row");
    let nested_index = headers.iter().position(|header| header == "nested").unwrap();
    let nested_csv: serde_json::Value = serde_json::from_str(&record[nested_index]).expect("nested JSON in CSV");
    assert_eq!(
        nested_csv, exported[0]["nested"],
        "CSV quoting must preserve nested BSON JSON"
    );

    let reimported = serde_json::json!({
        "_id": "reimported",
        "nested": exported[0]["nested"].clone(),
    });
    connection
        .execute(&format!("db.special_values_copy.insertOne({reimported})"))
        .await
        .expect("re-import exported nested Extended JSON");
    let persisted = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("special_values_copy")
        .find_one(doc! { "_id": "reimported" })
        .await
        .expect("read re-imported document")
        .expect("re-imported document exists");
    assert_eq!(
        persisted.get_document("nested").unwrap(),
        &doc! {
            "amount": "1234567890123456789.123456789012345".parse::<Decimal128>().unwrap(),
            "blob": Binary { subtype: BinarySubtype::Generic, bytes: vec![0, 255, 65] },
            "when": DateTime::from_millis(1_234_567_890_123),
            "large_integer": mongodb::bson::Bson::Int64(9_007_199_254_740_993),
            "explicit_null": mongodb::bson::Bson::Null,
            "unicode": "数据库🙂 — café",
        },
        "re-import must reconstruct Decimal128, binary subtype, BSON date and Int64 while keeping null and Unicode"
    );

    let directory = tempfile::tempdir().expect("temporary export directory");
    let workbook_path = directory.path().join("mongo-values.xlsx");
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
    .expect("export MongoDB result to XLSX");
    let nested_cell = super::xlsx_shared_cell_text(&workbook_path, nested, 2).expect("read nested XLSX cell");
    if let Some(marker) = missing_nested_xlsx_marker(&nested_cell) {
        panic!("nested XLSX cell missing {marker}: {nested_cell}");
    }
    assert_eq!(nested_cell, exported[0]["nested"].to_string());
}

const NESTED_XLSX_DECIMAL: &str = r#""$numberDecimal":"1234567890123456789.123456789012345""#;
const NESTED_XLSX_DATE: &str = r#""$date":{"$numberLong":"1234567890123"}"#;
const NESTED_XLSX_BINARY: &str = r#""subType":"00""#;

fn missing_nested_xlsx_marker(cell: &str) -> Option<&'static str> {
    [NESTED_XLSX_DECIMAL, NESTED_XLSX_DATE, NESTED_XLSX_BINARY]
        .into_iter()
        .find(|marker| !cell.contains(marker))
}
fn json_column(name: &str) -> tablepro_core::ColumnInfo {
    tablepro_core::ColumnInfo {
        name: name.into(),
        data_type: "json".into(),
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

fn nested_extended_json(include_date: bool, include_binary: bool) -> serde_json::Value {
    let mut nested = serde_json::Map::new();
    nested.insert(
        "amount".into(),
        serde_json::json!({"$numberDecimal": "1234567890123456789.123456789012345"}),
    );
    if include_binary {
        nested.insert(
            "blob".into(),
            serde_json::json!({"$binary": {"base64": "AP9B", "subType": "00"}}),
        );
    }
    if include_date {
        nested.insert(
            "when".into(),
            serde_json::json!({"$date": {"$numberLong": "1234567890123"}}),
        );
    }
    serde_json::Value::Object(nested)
}

fn write_nested_xlsx(nested: serde_json::Value) -> (tempfile::TempDir, std::path::PathBuf) {
    let result = tablepro_core::QueryResult {
        columns: ["date_max", "uuid_binary", "user_binary", "nested"]
            .into_iter()
            .map(json_column)
            .collect(),
        rows: vec![vec![
            Value::Json(serde_json::json!({"$date": {"$numberLong": i64::MAX.to_string()}})),
            Value::Json(serde_json::json!({"$binary": {"base64": "AAECAwQFBgcICQoLDA0ODw==", "subType": "04"}})),
            Value::Json(serde_json::json!({"$binary": {"base64": "AP9B", "subType": "80"}})),
            Value::Json(nested),
        ]],
        truncated: false,
    };
    let directory = tempfile::tempdir().expect("temporary export directory");
    let path = directory.path().join("mongo-values.xlsx");
    tablepro_core::export::write_result_file(
        &path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .expect("export nested fixture to XLSX");
    (directory, path)
}

#[test]
fn xlsx_nested_cell_requires_its_own_date_and_binary_markers() {
    let (_full_dir, full_path) = write_nested_xlsx(nested_extended_json(true, true));
    let nested_cell = super::xlsx_shared_cell_text(&full_path, 3, 2).expect("nested cell");
    assert_eq!(missing_nested_xlsx_marker(&nested_cell), None, "{nested_cell}");
    assert!(!nested_cell.contains(r#""subType":"04""#), "{nested_cell}");
    assert!(!nested_cell.contains(r#""subType":"80""#), "{nested_cell}");
    let top_level_date = super::xlsx_shared_cell_text(&full_path, 0, 2).expect("top-level date cell");
    assert!(top_level_date.contains("$numberLong"), "{top_level_date}");
    assert!(!top_level_date.contains("1234567890123"), "{top_level_date}");

    let (_dropped_date_dir, dropped_date_path) = write_nested_xlsx(nested_extended_json(false, true));
    let dropped_date_cell = super::xlsx_shared_cell_text(&dropped_date_path, 3, 2).expect("nested cell without date");
    assert_eq!(missing_nested_xlsx_marker(&dropped_date_cell), Some(NESTED_XLSX_DATE));
    assert!(dropped_date_cell.contains(NESTED_XLSX_DECIMAL), "{dropped_date_cell}");
    assert!(dropped_date_cell.contains(NESTED_XLSX_BINARY), "{dropped_date_cell}");
    let dropped_date_workbook =
        super::read_zip_text(&dropped_date_path, "xl/sharedStrings.xml").expect("shared strings");
    assert!(dropped_date_workbook.contains("$numberLong"), "{dropped_date_workbook}");
    assert!(
        dropped_date_workbook.contains(r#""subType":"04""#),
        "{dropped_date_workbook}"
    );
    assert!(
        dropped_date_workbook.contains(r#""subType":"80""#),
        "{dropped_date_workbook}"
    );

    let (_dropped_binary_dir, dropped_binary_path) = write_nested_xlsx(nested_extended_json(true, false));
    let dropped_binary_cell =
        super::xlsx_shared_cell_text(&dropped_binary_path, 3, 2).expect("nested cell without binary");
    assert_eq!(
        missing_nested_xlsx_marker(&dropped_binary_cell),
        Some(NESTED_XLSX_BINARY)
    );
    assert!(dropped_binary_cell.contains(NESTED_XLSX_DATE), "{dropped_binary_cell}");
    let dropped_binary_workbook =
        super::read_zip_text(&dropped_binary_path, "xl/sharedStrings.xml").expect("shared strings");
    assert!(
        dropped_binary_workbook.contains(r#""subType":"04""#),
        "{dropped_binary_workbook}"
    );
    assert!(
        dropped_binary_workbook.contains(r#""subType":"80""#),
        "{dropped_binary_workbook}"
    );
    assert!(
        dropped_binary_workbook.contains("$numberLong"),
        "{dropped_binary_workbook}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_nested_and_max_key_grid_edit_writes_extended_json_back_as_native_bson() {
    use mongodb::bson::{
        Binary, DateTime, Decimal128, JavaScriptCodeWithScope, Regex, Timestamp, doc, oid::ObjectId,
        spec::BinarySubtype,
    };

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let id = ObjectId::new();
    client
        .database("appdb")
        .collection::<mongodb::bson::Document>("nested_edits")
        .insert_one(doc! {
            "_id": id,
            "payload": doc! { "before": true },
            "items": vec![doc! { "before": true }],
            "cluster_time": Timestamp { time: 41, increment: 7 },
            "pattern": Regex { pattern: "before".into(), options: "i".into() },
            "script": JavaScriptCodeWithScope {
                code: "return before;".into(),
                scope: doc! { "value": 1_i64 },
            },
            "symbol": mongodb::bson::Bson::Symbol("before".into()),
            "floor": mongodb::bson::Bson::MinKey,
            "ceiling": mongodb::bson::Bson::MaxKey,
            "uuid_binary": Binary { subtype: BinarySubtype::Uuid, bytes: (0..16).collect() },
        })
        .await
        .expect("seed editable nested document");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.nested_edits.find({})")
        .await
        .expect("read before edit");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let payload_index = before
        .columns
        .iter()
        .position(|column| column.name == "payload")
        .unwrap();
    assert_eq!(before.columns[payload_index].data_type, "object");
    let items_index = before.columns.iter().position(|column| column.name == "items").unwrap();
    assert_eq!(before.columns[items_index].data_type, "array");
    let timestamp_index = before
        .columns
        .iter()
        .position(|column| column.name == "cluster_time")
        .unwrap();
    assert_eq!(before.columns[timestamp_index].data_type, "bsonTimestamp");
    let regex_index = before
        .columns
        .iter()
        .position(|column| column.name == "pattern")
        .unwrap();
    assert_eq!(before.columns[regex_index].data_type, "regex");
    let script_index = before
        .columns
        .iter()
        .position(|column| column.name == "script")
        .unwrap();
    assert_eq!(before.columns[script_index].data_type, "javascriptwithscope");
    let symbol_index = before
        .columns
        .iter()
        .position(|column| column.name == "symbol")
        .unwrap();
    assert_eq!(before.columns[symbol_index].data_type, "symbol");
    let min_key_index = before.columns.iter().position(|column| column.name == "floor").unwrap();
    assert_eq!(before.columns[min_key_index].data_type, "minkey");
    let max_key_index = before
        .columns
        .iter()
        .position(|column| column.name == "ceiling")
        .unwrap();
    assert_eq!(before.columns[max_key_index].data_type, "maxkey");
    let uuid_binary_index = before
        .columns
        .iter()
        .position(|column| column.name == "uuid_binary")
        .unwrap();
    assert_eq!(before.columns[uuid_binary_index].data_type, "binData-subtype-04");

    let edited = serde_json::json!({
        "amount": {"$numberDecimal": "1234567890123456789.123456789012345"},
        "when": {"$date": {"$numberLong": "1234567890123"}},
        "binary": {"$binary": {"base64": "AP9B", "subType": "80"}},
    });
    let edited_items = serde_json::json!([{"ordinal": {"$numberLong": "7"}}]);
    let edited_timestamp = serde_json::json!({"$timestamp": {"t": 53, "i": 11}});
    let edited_regex = serde_json::json!({"$regularExpression": {"pattern": "after", "options": "m"}});
    let edited_script = serde_json::json!({
        "$code": "return after;",
        "$scope": {"value": {"$numberLong": "9"}},
    });
    let edited_symbol = serde_json::json!({"$symbol": "after"});
    let edited_min_key = serde_json::json!({"$minKey": 1});
    let edited_max_key = serde_json::json!({"$maxKey": 1});
    let edited_uuid_binary = serde_json::json!({
        "$binary": { "base64": "EBESExQVFhcYGRobHB0eHw==", "subType": "04" }
    });
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "nested_edits",
        &before.columns,
        &[
            (payload_index, Value::Json(edited.clone())),
            (items_index, Value::Json(edited_items.clone())),
            (timestamp_index, Value::Json(edited_timestamp)),
            (regex_index, Value::Json(edited_regex)),
            (script_index, Value::Json(edited_script.clone())),
            (symbol_index, Value::Json(edited_symbol.clone())),
            (min_key_index, Value::Json(edited_min_key)),
            (max_key_index, Value::Json(edited_max_key)),
            (uuid_binary_index, Value::Json(edited_uuid_binary.clone())),
        ],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build grid row update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply nested grid edit");

    let after = connection
        .query("db.nested_edits.find({})")
        .await
        .expect("read after edit");
    assert_eq!(after.rows[0][payload_index], Value::Json(edited));
    assert_eq!(after.rows[0][items_index], Value::Json(edited_items));
    assert_eq!(after.rows[0][script_index], Value::Json(edited_script));
    assert_eq!(after.rows[0][symbol_index], Value::Json(edited_symbol));
    assert_eq!(after.rows[0][uuid_binary_index], Value::Json(edited_uuid_binary));

    let persisted = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("nested_edits")
        .find_one(doc! { "_id": id })
        .await
        .expect("read native persisted BSON")
        .expect("document exists");
    let decimal: Decimal128 = "1234567890123456789.123456789012345".parse().unwrap();
    assert_eq!(
        persisted.get_document("payload").unwrap(),
        &doc! {
            "amount": decimal,
            "when": DateTime::from_millis(1_234_567_890_123),
            "binary": Binary { subtype: BinarySubtype::UserDefined(0x80), bytes: vec![0, 255, 65] },
        }
    );
    assert_eq!(
        persisted.get("cluster_time"),
        Some(&mongodb::bson::Bson::Timestamp(Timestamp {
            time: 53,
            increment: 11
        }))
    );
    assert_eq!(
        persisted.get("pattern"),
        Some(&mongodb::bson::Bson::RegularExpression(Regex {
            pattern: "after".into(),
            options: "m".into()
        }))
    );
    assert_eq!(
        persisted.get("script"),
        Some(&mongodb::bson::Bson::JavaScriptCodeWithScope(JavaScriptCodeWithScope {
            code: "return after;".into(),
            scope: doc! { "value": 9_i64 },
        }))
    );
    assert_eq!(
        persisted.get("symbol"),
        Some(&mongodb::bson::Bson::Symbol("after".into()))
    );
    assert_eq!(persisted.get("floor"), Some(&mongodb::bson::Bson::MinKey));
    assert_eq!(persisted.get("ceiling"), Some(&mongodb::bson::Bson::MaxKey));
    assert_eq!(
        persisted.get("uuid_binary"),
        Some(&mongodb::bson::Bson::Binary(Binary {
            subtype: BinarySubtype::Uuid,
            bytes: (16..32).collect(),
        }))
    );
    assert_eq!(
        persisted.get_array("items").unwrap(),
        &vec![mongodb::bson::Bson::Document(doc! { "ordinal": 7_i64 })]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_undefined_grid_edit_preserves_native_bson() {
    use mongodb::bson::{Bson, doc, oid::ObjectId};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let id = ObjectId::new();
    client
        .database("appdb")
        .collection::<mongodb::bson::Document>("undefined_edits")
        .insert_one(doc! { "_id": id, "value": Bson::Undefined })
        .await
        .expect("seed BSON Undefined value");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.undefined_edits.find({})")
        .await
        .expect("read before edit");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let value_index = before.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(before.columns[value_index].data_type, "undefined");
    let marker = Value::Json(serde_json::json!({ "$undefined": true }));
    assert_eq!(before.rows[0][value_index], marker);

    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "undefined_edits",
        &before.columns,
        &[(value_index, marker.clone())],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build Undefined grid update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply Undefined grid edit");

    let after = connection
        .query("db.undefined_edits.find({})")
        .await
        .expect("read after edit");
    assert_eq!(after.rows[0][value_index], marker);
    let persisted = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("undefined_edits")
        .find_one(doc! { "_id": id })
        .await
        .expect("read native persisted BSON")
        .expect("document exists");
    assert_eq!(persisted.get("value"), Some(&Bson::Undefined));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_javascript_code_grid_edit_preserves_native_bson() {
    use mongodb::bson::{Bson, doc};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("javascript_edits");
    collection
        .insert_one(doc! {
            "_id": "source",
            "value": Bson::JavaScriptCode("return before;".into()),
        })
        .await
        .expect("seed BSON JavaScript code");

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let before = connection
        .query("db.javascript_edits.find({})")
        .await
        .expect("read before edit");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let value_index = before.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(before.columns[value_index].data_type, "javascript");
    let marker = Value::Json(serde_json::json!({ "$code": "return after;" }));
    assert_eq!(
        before.rows[0][value_index],
        Value::Json(serde_json::json!({ "$code": "return before;" }))
    );

    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "javascript_edits",
        &before.columns,
        &[(value_index, marker.clone())],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build JavaScript code grid update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply JavaScript code grid edit");

    let after = connection
        .query("db.javascript_edits.find({})")
        .await
        .expect("read after edit");
    assert_eq!(after.rows[0][value_index], marker);
    let persisted = collection
        .find_one(doc! { "_id": "source" })
        .await
        .expect("read native persisted BSON")
        .expect("source document exists");
    assert_eq!(
        persisted.get("value"),
        Some(&Bson::JavaScriptCode("return after;".into()))
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_db_pointer_grid_edit_preserves_native_bson() {
    use mongodb::bson::{Bson, doc};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("dbpointer_edits");
    let before_pointer = Bson::try_from(serde_json::json!({
        "$dbPointer": {
            "$ref": "legacy.before",
            "$id": { "$oid": "0123456789abcdef01234567" }
        }
    }))
    .expect("construct initial BSON DbPointer");
    let after_pointer = Bson::try_from(serde_json::json!({
        "$dbPointer": {
            "$ref": "legacy.after",
            "$id": { "$oid": "fedcba987654321001234567" }
        }
    }))
    .expect("construct edited BSON DbPointer");
    collection
        .insert_one(doc! { "_id": "source", "value": before_pointer })
        .await
        .expect("seed BSON DbPointer");

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let before = connection
        .query("db.dbpointer_edits.find({})")
        .await
        .expect("read before edit");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let value_index = before.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(before.columns[value_index].data_type, "dbpointer");
    assert_eq!(
        before.rows[0][value_index],
        Value::Json(
            Bson::try_from(serde_json::json!({
                "$dbPointer": {
                    "$ref": "legacy.before",
                    "$id": { "$oid": "0123456789abcdef01234567" }
                }
            }))
            .unwrap()
            .into_canonical_extjson()
        )
    );

    let edited_marker = Value::Json(after_pointer.clone().into_canonical_extjson());
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "dbpointer_edits",
        &before.columns,
        &[(value_index, edited_marker.clone())],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build DbPointer grid update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply DbPointer grid edit");

    let after = connection
        .query("db.dbpointer_edits.find({})")
        .await
        .expect("read after edit");
    assert_eq!(after.rows[0][value_index], edited_marker);
    let persisted = collection
        .find_one(doc! { "_id": "source" })
        .await
        .expect("read native persisted BSON")
        .expect("source document exists");
    assert_eq!(persisted.get("value"), Some(&after_pointer));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_generic_binary_grid_edit_preserves_native_bson() {
    use mongodb::bson::{Binary, Bson, doc, oid::ObjectId, spec::BinarySubtype};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("binary_grid_edits");
    let row_id = ObjectId::new();
    collection
        .insert_one(doc! {
            "_id": row_id,
            "payload": Binary { subtype: BinarySubtype::Generic, bytes: vec![0, 255, 65] },
        })
        .await
        .expect("seed generic BSON binary");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.binary_grid_edits.find({})")
        .await
        .expect("read before edit");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let payload_index = before
        .columns
        .iter()
        .position(|column| column.name == "payload")
        .unwrap();
    assert_eq!(before.columns[payload_index].data_type, "binData-subtype-00");
    assert_eq!(before.rows[0][payload_index], Value::Bytes(vec![0, 255, 65]));

    let edited = vec![255, 0, 66, 128];
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "binary_grid_edits",
        &before.columns,
        &[(payload_index, Value::Bytes(edited.clone()))],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build generic binary grid update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply generic binary grid edit");

    let after = connection
        .query("db.binary_grid_edits.find({})")
        .await
        .expect("read after edit");
    assert_eq!(after.rows[0][payload_index], Value::Bytes(edited.clone()));
    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted BSON")
        .expect("source document exists");
    assert_eq!(
        persisted.get("payload"),
        Some(&Bson::Binary(Binary {
            subtype: BinarySubtype::Generic,
            bytes: edited,
        }))
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_binary_subtypes_survive_native_grid_edits() {
    use mongodb::bson::{Binary, Bson, Document, doc, oid::ObjectId, spec::BinarySubtype};

    let subtypes = [
        ("generic", BinarySubtype::Generic, "00"),
        ("function", BinarySubtype::Function, "01"),
        ("binary_old", BinarySubtype::BinaryOld, "02"),
        ("uuid_old", BinarySubtype::UuidOld, "03"),
        ("uuid", BinarySubtype::Uuid, "04"),
        ("md5", BinarySubtype::Md5, "05"),
        ("encrypted", BinarySubtype::Encrypted, "06"),
        ("sensitive", BinarySubtype::Sensitive, "08"),
        ("vector", BinarySubtype::Vector, "09"),
        ("reserved", BinarySubtype::Reserved(0x0a), "0a"),
        ("user_defined", BinarySubtype::UserDefined(0x80), "80"),
    ];
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<Document>("binary_subtype_grid_edits");
    let row_id = ObjectId::new();
    let mut seed = doc! { "_id": row_id };
    for (field, subtype, _) in subtypes {
        seed.insert(
            field,
            Bson::Binary(Binary {
                subtype,
                bytes: vec![1, 2, 3],
            }),
        );
    }
    collection
        .insert_one(seed)
        .await
        .expect("seed every BSON binary subtype");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.binary_subtype_grid_edits.find({})")
        .await
        .expect("read before edits");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let edited_bytes = vec![0, 255, 65];
    let edits: Vec<_> = subtypes
        .iter()
        .map(|(field, subtype, code)| {
            let index = before.columns.iter().position(|column| column.name == *field).unwrap();
            assert_eq!(before.columns[index].data_type, format!("binData-subtype-{code}"));
            let value = if *subtype == BinarySubtype::Generic {
                Value::Bytes(edited_bytes.clone())
            } else {
                Value::Json(serde_json::json!({
                    "$binary": { "base64": "AP9B", "subType": code }
                }))
            };
            (index, value)
        })
        .collect();
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "binary_subtype_grid_edits",
        &before.columns,
        &edits,
        &[before.rows[0][id_index].clone()],
    )
    .expect("build one keyed update across binary subtype markers");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply binary subtype grid edits");

    let after = connection
        .query("db.binary_subtype_grid_edits.find({})")
        .await
        .expect("read after edits");
    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted BSON")
        .expect("seed row remains present");
    for (field, subtype, code) in subtypes {
        let index = after.columns.iter().position(|column| column.name == field).unwrap();
        let expected = if subtype == BinarySubtype::Generic {
            Value::Bytes(edited_bytes.clone())
        } else {
            Value::Json(serde_json::json!({
                "$binary": { "base64": "AP9B", "subType": code }
            }))
        };
        assert_eq!(after.rows[0][index], expected, "driver result for {field}");
        assert_eq!(
            persisted.get(field),
            Some(&Bson::Binary(Binary {
                subtype,
                bytes: edited_bytes.clone(),
            })),
            "native subtype and bytes for {field}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_server_generated_bson_column_survives_grid_edit() {
    use mongodb::bson::{Binary, Bson, DateTime, Document, doc, oid::ObjectId, spec::BinarySubtype};

    async fn time_series_column(client: &mongodb::Client, name: &str, readings: [i32; 5]) -> Binary {
        use futures::TryStreamExt;

        let database = client.database("appdb");
        database
            .run_command(doc! {
                "create": name,
                "timeseries": { "timeField": "measured_at", "metaField": "sensor" }
            })
            .await
            .expect("create time-series collection");
        // Cross a bucket's one-hour time span, then write into the closed
        // first bucket again so MongoDB reopens and compresses its BSONColumn.
        let offsets = [0_i64, 1_800_000, 7_200_000, 7_201_000, 600_000];
        database
            .collection::<Document>(name)
            .insert_many(offsets.into_iter().zip(readings).map(|(offset, reading)| {
                doc! {
                    "measured_at": DateTime::from_millis(1_700_000_000_000 + offset),
                    "sensor": "test-sensor",
                    "reading": reading,
                }
            }))
            .await
            .expect("insert measurements for server-generated BSONColumn");
        let buckets = database.collection::<Document>(&format!("system.buckets.{name}"));
        for _ in 0..40 {
            let mut cursor = buckets.find(doc! {}).await.expect("find generated time-series buckets");
            while let Some(bucket) = cursor.try_next().await.expect("read time-series bucket") {
                let data = bucket.get_document("data").expect("bucket data");
                if let Some(Bson::Binary(column)) = data.get("reading")
                    && column.subtype == BinarySubtype::Column
                {
                    return column.clone();
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("MongoDB did not compress a closed time-series bucket to BSONColumn");
    }

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let original = time_series_column(&client, "column_source", [10, 20, 30, 40, 15]).await;
    let replacement = time_series_column(&client, "column_replacement", [11, 22, 33, 44, 16]).await;
    assert_ne!(original.bytes, replacement.bytes, "source payloads differ");

    let collection = client.database("appdb").collection::<Document>("column_grid_edits");
    let row_id = ObjectId::new();
    collection
        .insert_one(doc! { "_id": row_id, "payload": original.clone() })
        .await
        .expect("store a server-generated BSONColumn value");
    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.column_grid_edits.find({})")
        .await
        .expect("read source BSONColumn");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let payload_index = before
        .columns
        .iter()
        .position(|column| column.name == "payload")
        .unwrap();
    let edited_marker = Bson::Binary(replacement.clone()).into_canonical_extjson();
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "column_grid_edits",
        &before.columns,
        &[(payload_index, Value::Json(edited_marker.clone()))],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build BSONColumn grid update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply valid server-generated BSONColumn edit");

    let after = connection
        .query("db.column_grid_edits.find({})")
        .await
        .expect("read edited BSONColumn");
    assert_eq!(after.rows[0][payload_index], Value::Json(edited_marker));
    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted BSON")
        .expect("edited row remains present");
    assert_eq!(persisted.get("payload"), Some(&Bson::Binary(replacement)));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_object_id_grid_edit_preserves_native_bson() {
    use mongodb::bson::{Bson, doc, oid::ObjectId};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("object_id_edits");
    let row_id = ObjectId::parse_str("0123456789abcdef01234567").unwrap();
    let before_value = ObjectId::parse_str("111111111111111111111111").unwrap();
    let after_value = ObjectId::parse_str("fedcba987654321001234567").unwrap();
    collection
        .insert_one(doc! { "_id": row_id, "reference": before_value })
        .await
        .expect("seed ObjectId regular field");

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let before = connection
        .query("db.object_id_edits.find({})")
        .await
        .expect("read before ObjectId edit");
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let value_index = before
        .columns
        .iter()
        .position(|column| column.name == "reference")
        .unwrap();
    assert_eq!(before.columns[value_index].data_type, "ObjectId");
    assert_eq!(
        before.rows[0][value_index],
        Value::Json(serde_json::json!({"$oid": before_value.to_hex()}))
    );

    let edited = Value::Json(serde_json::json!({"$oid": after_value.to_hex()}));
    let (statement, params) = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "object_id_edits",
        &before.columns,
        &[(value_index, edited.clone())],
        &[before.rows[0][id_index].clone()],
    )
    .expect("build ObjectId keyed grid update");
    connection
        .execute_in_transaction(&[(statement, params)])
        .await
        .expect("apply ObjectId grid edit");

    let after = connection
        .query("db.object_id_edits.find({})")
        .await
        .expect("read after ObjectId edit");
    assert_eq!(
        after.rows[0][id_index], before.rows[0][id_index],
        "row identity changed"
    );
    assert_eq!(after.rows[0][value_index], edited);

    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted BSON")
        .expect("edited row still exists");
    assert_eq!(persisted.get("_id"), Some(&Bson::ObjectId(row_id)));
    assert_eq!(persisted.get("reference"), Some(&Bson::ObjectId(after_value)));
}
