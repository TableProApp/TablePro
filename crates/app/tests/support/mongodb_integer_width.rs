use super::parse_input_for_driver;
use tablepro_core::{ColumnInfo, Value};

fn column(data_type: &str, nullable: bool) -> ColumnInfo {
    ColumnInfo {
        name: "x".into(),
        data_type: data_type.into(),
        nullable,
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

#[test]
fn value_contract_mongodb_integer_parser_preserves_int32_and_int64_widths() {
    let int32 = column("int", false);
    for value in [i32::MIN, i32::MAX] {
        assert_eq!(
            parse_input_for_driver(&value.to_string(), Some(&int32), "mongodb").unwrap(),
            Value::Json(serde_json::json!({"$numberInt": value.to_string()}))
        );
    }
    for value in [i64::from(i32::MIN) - 1, i64::from(i32::MAX) + 1] {
        assert!(
            parse_input_for_driver(&value.to_string(), Some(&int32), "mongodb").is_err(),
            "Int32 overflow {value} must be refused"
        );
    }

    let int64 = column("long", false);
    for value in [i64::MIN, 9_007_199_254_740_993, i64::MAX] {
        assert_eq!(
            parse_input_for_driver(&value.to_string(), Some(&int64), "mongodb").unwrap(),
            Value::Int(value),
            "BSON Int64 value {value} must remain exact"
        );
    }
    assert_eq!(
        parse_input_for_driver("42", Some(&int32), "postgres").unwrap(),
        Value::Int(42),
        "MongoDB width markers must not affect other drivers"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_int32_grid_edit_preserves_integer_width() {
    use mongodb::bson::{doc, oid::ObjectId};
    use tablepro_core::{ConnectOptions, DatabaseDriver};
    use testcontainers::ImageExt;
    use testcontainers_modules::mongo::Mongo;
    use testcontainers_modules::testcontainers::runners::AsyncRunner;

    let container = Mongo::default().with_tag("7").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = native
        .database("appdb")
        .collection::<mongodb::bson::Document>("integer_width_edits");
    let row_id = ObjectId::new();
    collection
        .insert_one(doc! {
            "_id": row_id,
            "small": mongodb::bson::Bson::Int32(41),
            "wide": mongodb::bson::Bson::Int64(9_007_199_254_740_993),
        })
        .await
        .unwrap();

    let connection = drivers_mongodb::MongodbDriver
        .connect(ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    let before = connection.query("db.integer_width_edits.find({})").await.unwrap();
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let small_index = before.columns.iter().position(|column| column.name == "small").unwrap();
    let wide_index = before.columns.iter().position(|column| column.name == "wide").unwrap();
    assert_eq!(before.columns[small_index].data_type, "int");
    assert_eq!(before.columns[wide_index].data_type, "long");

    let overflow = parse_input_for_driver("2147483648", Some(&before.columns[small_index]), "mongodb");
    assert!(overflow.is_err(), "Int32 overflow must be rejected before writing");
    let unchanged = collection.find_one(doc! { "_id": row_id }).await.unwrap().unwrap();
    assert_eq!(unchanged.get("small"), Some(&mongodb::bson::Bson::Int32(41)));
    let small = parse_input_for_driver("42", Some(&before.columns[small_index]), "mongodb").unwrap();
    let wide = parse_input_for_driver("9007199254740995", Some(&before.columns[wide_index]), "mongodb").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "integer_width_edits",
        &before.columns,
        &[(small_index, small), (wide_index, wide)],
        &[before.rows[0][id_index].clone()],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let after = connection.query("db.integer_width_edits.find({})").await.unwrap();
    assert_eq!(after.rows[0][id_index], before.rows[0][id_index]);
    assert_eq!(after.rows[0][small_index], Value::Int(42));
    assert_eq!(after.rows[0][wide_index], Value::Int(9_007_199_254_740_995));
    let persisted = collection.find_one(doc! { "_id": row_id }).await.unwrap().unwrap();
    assert_eq!(
        persisted.get("small"),
        Some(&mongodb::bson::Bson::Int32(42)),
        "editing BSON int must preserve its native Int32 width"
    );
    assert_eq!(
        persisted.get("wide"),
        Some(&mongodb::bson::Bson::Int64(9_007_199_254_740_995)),
        "editing BSON long must preserve its native Int64 width"
    );
}
