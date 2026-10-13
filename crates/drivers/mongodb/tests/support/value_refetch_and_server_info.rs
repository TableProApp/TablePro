use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Document, doc, oid::ObjectId};
use tablepro_core::{DatabaseDriver, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn the_server_answers_a_ping_and_reports_its_version() {
    let (_container, host, port) = super::start_mongo().await;
    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();

    connection.ping().await.unwrap();

    let version = connection.server_version().await.unwrap().expect("a version string");
    assert!(version.starts_with("MongoDB 7"), "{version}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_full_value_of_one_field_is_refetched_by_its_native_id() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = client.database("appdb").collection::<Document>("records");
    let with_payload = ObjectId::new();
    let without_payload = ObjectId::new();
    let long = "y".repeat(20_000);
    collection
        .insert_many([
            doc! { "_id": with_payload, "payload": long.clone(), "count": 5_i32 },
            doc! { "_id": without_payload, "count": 6_i32 },
        ])
        .await
        .unwrap();
    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let query = "SELECT \"payload\" FROM \"appdb\".\"records\" WHERE \"_id\" = ?";
    let key = |id: ObjectId| Value::Json(serde_json::json!({ "$oid": id.to_hex() }));

    let found = connection.query_params(query, &[key(with_payload)]).await.unwrap();
    assert_eq!(
        found.rows,
        vec![vec![Value::Text(long)]],
        "the whole value, not a preview"
    );
    assert_eq!(found.columns[0].name, "payload");
    assert_eq!(found.columns[0].data_type.to_ascii_lowercase(), "string");
    assert!(!found.truncated);

    let absent = connection.query_params(query, &[key(ObjectId::new())]).await.unwrap();
    assert!(absent.rows.is_empty(), "an unknown id is an empty result");

    let missing_field = connection.query_params(query, &[key(without_payload)]).await;
    assert!(
        missing_field.is_err(),
        "a document without the field is reported, not read as NULL"
    );
}
