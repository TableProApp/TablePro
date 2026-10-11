use super::*;
use ::mongodb::bson::{Binary, Bson, doc, oid::ObjectId, spec::BinarySubtype};
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Value};
use testcontainers::ImageExt;
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mongo::Mongo;

async fn start_server() -> (testcontainers::ContainerAsync<Mongo>, String, u16) {
    let container = Mongo::default().with_tag("7").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    (container, host, port)
}

async fn native_values(
    host: &str,
    port: u16,
) -> (::mongodb::Client, ObjectId, String, Vec<u8>, ::mongodb::bson::Document) {
    let client = ::mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let id = ObjectId::new();
    let text = "x".repeat(9_000);
    let bytes: Vec<u8> = (0..9_000).map(|index| (index % 251) as u8).collect();
    let structured = doc! { "nested": "j".repeat(9_000) };
    client
        .database("appdb")
        .collection::<::mongodb::bson::Document>("value_preview_records")
        .insert_one(doc! {
            "_id": id,
            "payload": &text,
            "blob": Binary { subtype: BinarySubtype::Generic, bytes: bytes.clone() },
            "structured": structured.clone(),
        })
        .await
        .unwrap();
    (client, id, text, bytes, structured)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mongodb_guarded_refetch_preserves_long_text_and_binary_values() {
    let (_container, host, port) = start_server().await;
    let (native, id, text, bytes, structured) = native_values(&host, port).await;
    let connection: std::sync::Arc<dyn Connection> = std::sync::Arc::from(
        drivers_mongodb::MongodbDriver
            .connect(ConnectOptions {
                host,
                port,
                database: "appdb".into(),
                ..Default::default()
            })
            .await
            .unwrap(),
    );
    let control = crate::services::operation_control::bounded(30);
    let columns = connection
        .fetch_columns_controlled(Some("appdb"), "value_preview_records", &control)
        .await
        .unwrap();
    let key = Value::Json(Bson::ObjectId(id).into_canonical_extjson());
    let target = BrowseTarget {
        driver_id: "mongodb",
        schema: Some("appdb"),
        table: "value_preview_records",
        columns: &columns,
        filter: &tablepro_core::FilterSet::default(),
        hidden_columns: None,
    };
    assert_refetched_value(
        &target,
        &connection,
        &control,
        &key,
        "payload",
        Value::Text(text.clone()),
    )
    .await;
    assert_refetched_value(
        &target,
        &connection,
        &control,
        &key,
        "blob",
        Value::Bytes(bytes.clone()),
    )
    .await;
    assert_refetched_value(
        &target,
        &connection,
        &control,
        &key,
        "structured",
        Value::Json(Bson::Document(structured.clone()).into_canonical_extjson()),
    )
    .await;

    assert_native_values(&native, id, &text, &bytes, &structured).await;
}

async fn assert_native_values(
    native: &::mongodb::Client,
    id: ObjectId,
    text: &str,
    bytes: &[u8],
    structured: &::mongodb::bson::Document,
) {
    let stored = native
        .database("appdb")
        .collection::<::mongodb::bson::Document>("value_preview_records")
        .find_one(doc! { "_id": id })
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.get_str("payload").unwrap(), text);
    assert_eq!(stored.get_binary_generic("blob").unwrap().as_slice(), bytes);
    assert_eq!(stored.get_document("structured").unwrap(), structured);
}

async fn assert_refetched_value(
    target: &BrowseTarget<'_>,
    connection: &std::sync::Arc<dyn Connection>,
    control: &tablepro_core::OperationControl,
    key: &Value,
    name: &str,
    expected: Value,
) {
    let index = target.columns.iter().position(|column| column.name == name).unwrap();
    let query = target.value_query(index, std::slice::from_ref(key)).unwrap();
    let result = guarded_value_refetch(connection.clone(), "mongodb", &query, control).await;
    assert_eq!(result.rows, vec![vec![expected]]);
}
