#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn nested_json_and_mql_filters_match_dotted_fields_and_array_elements() {
    use futures::TryStreamExt;
    use mongodb::bson::{Document, doc};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client.database("appdb").collection::<Document>("nested_filters");
    collection
        .insert_many([
            doc! {
                "_id": 1,
                "profile": { "region": "eu", "team": "core" },
                "scores": [2, 8],
                "orders": [{ "sku": "a", "qty": 2 }, { "sku": "b", "qty": 1 }],
                "active": true,
            },
            doc! {
                "_id": 2,
                "profile": { "region": "us", "team": "core" },
                "scores": [8],
                "orders": [{ "sku": "a", "qty": 1 }, { "sku": "b", "qty": 2 }],
                "active": true,
            },
            doc! {
                "_id": 3,
                "profile": { "region": "eu", "team": "ops" },
                "scores": [4],
                "orders": [{ "sku": "b", "qty": 2 }],
                "active": false,
            },
            doc! {
                "_id": 4,
                "profile": { "region": "eu", "team": "core" },
                "scores": [9],
                "orders": [{ "sku": "a", "qty": 2 }],
                "active": true,
            },
        ])
        .await
        .expect("seed nested documents and non-matching controls");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let filter =
        r#"{"profile.region":"eu","profile.team":"core","active":true,"scores":{"$elemMatch":{"$gte":7,"$lt":9}}}"#;
    let queries = [filter.to_string(), format!("db.nested_filters.find({filter})")];
    for query in queries {
        let result = connection.query(&query).await.expect("run nested filter");
        let id_index = result
            .columns
            .iter()
            .position(|column| column.name == "_id")
            .expect("_id metadata");
        let ids = result.rows.iter().map(|row| row[id_index].clone()).collect::<Vec<_>>();
        assert_eq!(ids, vec![Value::Int(1)], "query: {query}");
    }

    // Document 2 has the matching SKU and quantity in different array
    // elements. Dotted predicates can match it; $elemMatch must not.
    let filter = r#"{"orders":{"$elemMatch":{"sku":"a","qty":{"$gte":2}}}}"#;
    let native_filter = doc! { "orders": { "$elemMatch": { "sku": "a", "qty": { "$gte": 2 } } } };
    let native_matches = collection
        .find(native_filter)
        .sort(doc! { "_id": 1 })
        .await
        .expect("run native nested-array oracle")
        .try_collect::<Vec<Document>>()
        .await
        .expect("collect native nested-array oracle");
    let native_ids = native_matches
        .iter()
        .map(|document| i64::from(document.get_i32("_id").expect("native id")))
        .collect::<Vec<_>>();
    assert_eq!(native_ids, vec![1, 4]);

    for query in [filter.to_string(), format!("db.nested_filters.find({filter})")] {
        let result = connection.query(&query).await.expect("run nested-array filter");
        let id_index = result
            .columns
            .iter()
            .position(|column| column.name == "_id")
            .expect("_id metadata");
        let ids = result.rows.iter().map(|row| row[id_index].clone()).collect::<Vec<_>>();
        assert_eq!(ids, vec![Value::Int(1), Value::Int(4)], "query: {query}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn null_filters_distinguish_missing_and_explicit_null_like_native_mongodb() {
    use futures::TryStreamExt;
    use mongodb::bson::{Bson, Document, doc};

    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client.database("appdb").collection::<Document>("null_filter_contract");
    collection
        .insert_many([
            doc! { "_id": 1_i32 },
            doc! { "_id": 2_i32, "profile": {} },
            doc! { "_id": 3_i32, "profile": { "region": Bson::Null } },
            doc! { "_id": 4_i32, "profile": { "region": "eu" } },
        ])
        .await
        .expect("seed missing, explicit-null and ordinary nested values");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let cases = [
        (
            doc! { "profile.region": Bson::Null },
            r#"{"profile.region":null}"#,
            vec![1, 2, 3],
        ),
        (
            doc! { "profile.region": { "$exists": false } },
            r#"{"profile.region":{"$exists":false}}"#,
            vec![1, 2],
        ),
        (
            doc! { "profile.region": { "$type": "null" } },
            r#"{"profile.region":{"$type":"null"}}"#,
            vec![3],
        ),
    ];

    for (native_filter, filter, expected_ids) in cases {
        let native = collection
            .find(native_filter)
            .sort(doc! { "_id": 1 })
            .await
            .expect("run native filter oracle")
            .try_collect::<Vec<Document>>()
            .await
            .expect("collect native filter oracle");
        let native_ids = native
            .iter()
            .map(|document| i64::from(document.get_i32("_id").expect("native id")))
            .collect::<Vec<_>>();
        assert_eq!(native_ids, expected_ids, "native filter: {filter}");

        for query in [filter.to_string(), format!("db.null_filter_contract.find({filter})")] {
            let result = connection.query(&query).await.expect("run null filter");
            let id_index = result
                .columns
                .iter()
                .position(|column| column.name == "_id")
                .expect("_id metadata");
            let ids = result
                .rows
                .iter()
                .map(|row| match row.get(id_index) {
                    Some(Value::Int(id)) => *id,
                    other => panic!("unexpected MongoDB _id value: {other:?}"),
                })
                .collect::<Vec<_>>();
            assert_eq!(ids, native_ids, "query: {query}");
        }
    }
}
