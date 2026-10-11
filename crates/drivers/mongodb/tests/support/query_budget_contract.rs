use std::collections::BTreeSet;

use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Document, doc};
use tablepro_core::{DatabaseDriver, MAX_QUERY_RESULT_BYTES, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn find_and_aggregate_mark_results_truncated_at_the_shared_byte_budget() {
    let (_container, host, port) = super::start_mongo().await;
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = native.database("appdb").collection::<Document>("large_results");
    let payload = "x".repeat(5 * 1024 * 1024);
    let documents = (0..13)
        .map(|id| doc! { "_id": id, "payload": &payload })
        .collect::<Vec<_>>();
    collection.insert_many(documents).await.expect("seed large results");
    assert_eq!(collection.count_documents(doc! {}).await.unwrap(), 13);

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    for query in [
        "db.large_results.find({})",
        "db.large_results.aggregate([{\"$sort\":{\"_id\":1}}])",
    ] {
        let result = connection.query(query).await.expect("bounded query succeeds");
        assert!(result.truncated, "{query} must report omitted rows");
        assert_eq!(result.rows.len(), 12, "{query} must stop at the byte budget");
        let payload_column = result
            .columns
            .iter()
            .position(|column| column.name == "payload")
            .expect("payload column is retained");
        assert!(
            result
                .rows
                .iter()
                .all(|row| { matches!(row.get(payload_column), Some(Value::Text(value)) if value == &payload) }),
            "{query} must retain each admitted payload exactly"
        );
        let ids = result
            .rows
            .iter()
            .filter_map(|row| match row.first() {
                Some(Value::Int(id)) => Some(*id),
                _ => None,
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(ids.len(), 12, "{query} must retain distinct source rows");
        assert!(ids.iter().all(|id| (0..13).contains(id)));
        assert!(result.rows.len() * payload.len() <= MAX_QUERY_RESULT_BYTES);
    }

    collection.delete_many(doc! {}).await.unwrap();
    collection
        .insert_one(doc! { "_id": 99, "payload": "ready" })
        .await
        .unwrap();
    let usable = connection
        .query("db.large_results.find({})")
        .await
        .expect("a later query remains usable")
        .rows;
    assert_eq!(usable, vec![vec![Value::Int(99), Value::Text("ready".into())]]);
}
