use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Binary, Bson, Document, doc, oid::ObjectId, spec::BinarySubtype};
use tablepro_core::{DatabaseDriver, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn keyset_page_query_reads_rows_after_the_native_id_cursor() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    client
        .database("appdb")
        .collection::<Document>("keyset_page")
        .insert_many([
            doc! { "_id": 104, "value": "fourth" },
            doc! { "_id": 101, "value": "first" },
            doc! { "_id": 103, "value": "third" },
            doc! { "_id": 102, "value": "second" },
        ])
        .await
        .expect("seed keyset page");

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"keyset_page\" WHERE \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Int(100)],
        )
        .await
        .unwrap();

    assert_eq!(page.rows.len(), 2);
    assert_eq!(page.rows[0][0], Value::Int(101));
    assert_eq!(page.rows[1][0], Value::Int(102));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn filtered_offset_pages_keep_filters_with_and_without_parameters() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    client
        .database("appdb")
        .collection::<Document>("filtered_offset")
        .insert_many([
            doc! { "_id": 1, "group": "keep", "rank": 1, "value": Bson::Null },
            doc! { "_id": 2, "group": "skip", "rank": 2 },
            doc! { "_id": 3, "group": "keep", "rank": 3, "value": Bson::Null },
            doc! { "_id": 4, "group": "keep", "rank": 4, "value": "present" },
        ])
        .await
        .unwrap();

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let filtered = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"group\" = ? LIMIT 1 OFFSET 1",
            &[Value::Text("keep".into())],
        )
        .await
        .unwrap();
    assert_eq!(filtered.rows.len(), 1);
    assert_eq!(filtered.rows[0][0], Value::Int(3));

    let alternatives = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE (\"group\" = ? OR \"group\" = ?) LIMIT 3 OFFSET 0",
            &[Value::Text("keep".into()), Value::Text("skip".into())],
        )
        .await
        .unwrap();
    assert_eq!(alternatives.rows.len(), 3);
    assert_eq!(alternatives.rows[0][0], Value::Int(1));
    assert_eq!(alternatives.rows[1][0], Value::Int(2));
    assert_eq!(alternatives.rows[2][0], Value::Int(3));

    let greater_than = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"rank\" > ? LIMIT 2 OFFSET 0",
            &[Value::Int(2)],
        )
        .await
        .unwrap();
    assert_eq!(greater_than.rows.len(), 2);
    assert_eq!(greater_than.rows[0][0], Value::Int(3));
    assert_eq!(greater_than.rows[1][0], Value::Int(4));

    let not_equal = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"rank\" != ? LIMIT 3 OFFSET 0",
            &[Value::Int(2)],
        )
        .await
        .unwrap();
    assert_eq!(not_equal.rows.len(), 3);
    assert_eq!(
        not_equal.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(1), &Value::Int(3), &Value::Int(4)]
    );

    let null_or_missing_not_equal = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"value\" != ? LIMIT 2 OFFSET 0",
            &[Value::Text("present".into())],
        )
        .await
        .unwrap();
    assert!(null_or_missing_not_equal.rows.is_empty());

    let in_values = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"rank\" IN (?, ?) LIMIT 2 OFFSET 0",
            &[Value::Int(2), Value::Int(4)],
        )
        .await
        .unwrap();
    assert_eq!(in_values.rows.len(), 2);
    assert_eq!(in_values.rows[0][0], Value::Int(2));
    assert_eq!(in_values.rows[1][0], Value::Int(4));

    let not_in_values = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"rank\" NOT IN (?, ?) LIMIT 2 OFFSET 0",
            &[Value::Int(2), Value::Int(3)],
        )
        .await
        .unwrap();
    assert_eq!(not_in_values.rows.len(), 2);
    assert_eq!(not_in_values.rows[0][0], Value::Int(1));
    assert_eq!(not_in_values.rows[1][0], Value::Int(4));

    let not_in_with_null = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"rank\" NOT IN (?, ?) LIMIT 2 OFFSET 0",
            &[Value::Int(2), Value::Json(serde_json::Value::Null)],
        )
        .await
        .unwrap();
    assert!(not_in_with_null.rows.is_empty());

    let between = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"rank\" BETWEEN ? AND ? LIMIT 2 OFFSET 0",
            &[Value::Int(2), Value::Int(3)],
        )
        .await
        .unwrap();
    assert_eq!(between.rows.len(), 2);
    assert_eq!(between.rows[0][0], Value::Int(2));
    assert_eq!(between.rows[1][0], Value::Int(3));

    let nulls = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"value\" IS NULL LIMIT 2 OFFSET 0",
            &[],
        )
        .await
        .unwrap();
    let value_index = nulls.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(nulls.rows.len(), 2);
    assert_eq!(nulls.rows[0][0], Value::Int(1));
    assert_eq!(nulls.rows[0][value_index], Value::Json(serde_json::Value::Null));
    assert_eq!(nulls.rows[1][0], Value::Int(3));
    assert_eq!(nulls.rows[1][value_index], Value::Json(serde_json::Value::Null));

    let present = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_offset\" WHERE \"value\" IS NOT NULL LIMIT 2 OFFSET 0",
            &[],
        )
        .await
        .unwrap();
    let value_index = present
        .columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    assert_eq!(present.rows.len(), 1);
    assert_eq!(present.rows[0][0], Value::Int(4));
    assert_eq!(present.rows[0][value_index], Value::Json(serde_json::json!("present")));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn filtered_keyset_page_keeps_the_filter_and_cursor() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    client
        .database("appdb")
        .collection::<Document>("filtered_keyset")
        .insert_many([
            doc! { "_id": 104, "group": "keep", "rank": 4, "region": "east" },
            doc! { "_id": 101, "group": "keep", "rank": 1, "region": "east" },
            doc! { "_id": 103, "group": "keep", "rank": 3, "region": "east" },
            doc! { "_id": 102, "group": "skip", "rank": 2, "region": "east" },
            doc! { "_id": 105, "group": "keep", "rank": 5, "region": "west" },
        ])
        .await
        .unwrap();

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"group\" = ? AND \"region\" = ? AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Text("keep".into()), Value::Text("east".into()), Value::Int(1)],
        )
        .await
        .unwrap();

    assert_eq!(page.rows.len(), 2);
    assert_eq!(
        page.rows[0],
        vec![
            Value::Int(101),
            Value::Text("keep".into()),
            Value::Int(1),
            Value::Text("east".into())
        ]
    );
    assert_eq!(
        page.rows[1],
        vec![
            Value::Int(103),
            Value::Text("keep".into()),
            Value::Int(3),
            Value::Text("east".into())
        ]
    );

    let compared = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"rank\" > ? AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Int(2), Value::Int(101)],
        )
        .await
        .unwrap();
    assert_eq!(
        compared.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(103), &Value::Int(104)]
    );

    let repeated_field = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"rank\" > ? AND \"rank\" < ? AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Int(1), Value::Int(5), Value::Int(101)],
        )
        .await
        .unwrap();
    assert_eq!(
        repeated_field.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(102), &Value::Int(103)]
    );

    let ranged = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"rank\" BETWEEN ? AND ? AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Int(2), Value::Int(4), Value::Int(101)],
        )
        .await
        .unwrap();
    assert_eq!(
        ranged.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(102), &Value::Int(103)]
    );

    let not_equal = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"group\" != ? AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Text("skip".into()), Value::Int(101)],
        )
        .await
        .unwrap();
    assert_eq!(
        not_equal.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(103), &Value::Int(104)]
    );

    let excluded_members = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"group\" NOT IN (?) AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Text("skip".into()), Value::Int(101)],
        )
        .await
        .unwrap();
    assert_eq!(
        excluded_members.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(103), &Value::Int(104)]
    );

    let members = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE \"group\" IN (?) AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Text("keep".into()), Value::Int(101)],
        )
        .await
        .unwrap();
    assert_eq!(
        members.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(103), &Value::Int(104)]
    );

    let alternatives = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"filtered_keyset\" WHERE (\"group\" = ? OR \"group\" = ?) AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Text("skip".into()), Value::Text("keep".into()), Value::Int(102)],
        )
        .await
        .unwrap();
    assert_eq!(
        alternatives.rows.iter().map(|row| &row[0]).collect::<Vec<_>>(),
        [&Value::Int(103), &Value::Int(104)]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn null_filtered_keyset_page_excludes_missing_fields() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    client
        .database("appdb")
        .collection::<Document>("null_filtered_keyset")
        .insert_many([
            doc! { "_id": 1, "value": Bson::Null },
            doc! { "_id": 2 },
            doc! { "_id": 3, "value": Bson::Null },
        ])
        .await
        .unwrap();

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"null_filtered_keyset\" WHERE \"value\" IS NULL AND \"_id\" > ? LIMIT 2 OFFSET 0",
            &[Value::Int(1)],
        )
        .await
        .unwrap();

    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0][0], Value::Int(3));
    assert_eq!(page.rows[0][1], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pattern_keyset_filters_match_like_wildcards_without_matching_nulls() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    client
        .database("appdb")
        .collection::<Document>("pattern_keyset")
        .insert_many([
            doc! { "_id": 1, "label": "keep" },
            doc! { "_id": 2, "label": "skip" },
            doc! { "_id": 3, "label": "Keep" },
            doc! { "_id": 4, "label": "kAep" },
            doc! { "_id": 5, "label": "literal%keep" },
            doc! { "_id": 6, "label": Bson::Null },
            doc! { "_id": 7 },
        ])
        .await
        .unwrap();

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let cases = [
        (
            "SELECT * FROM \"appdb\".\"pattern_keyset\" WHERE \"label\" LIKE ? AND \"_id\" > ? LIMIT 20 OFFSET 0",
            "k__p",
            &[1, 4][..],
        ),
        (
            "SELECT * FROM \"appdb\".\"pattern_keyset\" WHERE \"label\" ILIKE ? AND \"_id\" > ? LIMIT 20 OFFSET 0",
            "K__P",
            &[1, 3, 4][..],
        ),
        (
            "SELECT * FROM \"appdb\".\"pattern_keyset\" WHERE \"label\" NOT ILIKE ? AND \"_id\" > ? LIMIT 20 OFFSET 0",
            "K__P",
            &[2, 5][..],
        ),
        (
            "SELECT * FROM \"appdb\".\"pattern_keyset\" WHERE \"label\" LIKE ? AND \"_id\" > ? LIMIT 20 OFFSET 0",
            r"literal\%keep",
            &[5][..],
        ),
        (
            "SELECT * FROM \"appdb\".\"pattern_keyset\" WHERE \"label\" LIKE ? ESCAPE '!' AND \"_id\" > ? LIMIT 20 OFFSET 0",
            "literal!%keep",
            &[5][..],
        ),
        (
            "SELECT * FROM \"appdb\".\"pattern_keyset\" WHERE \"label\" NOT LIKE ? AND \"_id\" > ? LIMIT 20 OFFSET 0",
            "k__p",
            &[2, 3, 5][..],
        ),
    ];
    for (sql, pattern, expected) in cases {
        let page = connection
            .query_params(sql, &[Value::Text(pattern.into()), Value::Int(0)])
            .await
            .unwrap();
        let actual = page.rows.iter().map(|row| row[0].clone()).collect::<Vec<_>>();
        let expected = expected.iter().copied().map(Value::Int).collect::<Vec<_>>();
        assert_eq!(actual, expected);
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn keyset_page_query_binds_object_id_cursor_values() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let first = ObjectId::parse_str("000000000000000000000001").unwrap();
    let second = ObjectId::parse_str("000000000000000000000002").unwrap();
    let third = ObjectId::parse_str("000000000000000000000003").unwrap();
    client
        .database("appdb")
        .collection::<Document>("keyset_oid")
        .insert_many([doc! { "_id": third }, doc! { "_id": first }, doc! { "_id": second }])
        .await
        .unwrap();

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"keyset_oid\" WHERE \"_id\" > ? LIMIT 1 OFFSET 0",
            &[Value::Json(Bson::ObjectId(first).into_canonical_extjson())],
        )
        .await
        .unwrap();

    assert_eq!(page.rows.len(), 1);
    assert_eq!(
        page.rows[0][0],
        Value::Json(Bson::ObjectId(second).into_canonical_extjson())
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn keyset_page_query_keeps_mixed_bson_id_types_in_sort_order() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let object_id = ObjectId::parse_str("000000000000000000000001").unwrap();
    client
        .database("appdb")
        .collection::<Document>("keyset_mixed_ids")
        .insert_many([
            doc! { "_id": 1, "value": "number" },
            doc! { "_id": "middle", "value": "string" },
            doc! { "_id": object_id, "value": "object id" },
        ])
        .await
        .unwrap();
    let explain = client
        .database("appdb")
        .run_command(doc! {
            "explain": {
                "find": "keyset_mixed_ids",
                "filter": { "$expr": { "$gt": ["$_id", { "$literal": 1 }] } },
                "sort": { "_id": 1 },
                "limit": 1,
            },
            "verbosity": "queryPlanner",
        })
        .await
        .unwrap();
    assert!(explain.to_string().contains("IXSCAN"), "{explain:?}");

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"keyset_mixed_ids\" WHERE \"_id\" > ? LIMIT 1 OFFSET 0",
            &[Value::Int(1)],
        )
        .await
        .unwrap();

    assert_eq!(page.rows.len(), 1);
    assert_eq!(
        page.rows[0][0],
        Value::Json(Bson::String("middle".into()).into_canonical_extjson())
    );
    let next_page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"keyset_mixed_ids\" WHERE \"_id\" > ? LIMIT 1 OFFSET 0",
            &[Value::Json(Bson::String("middle".into()).into_canonical_extjson())],
        )
        .await
        .unwrap();
    assert_eq!(next_page.rows.len(), 1);
    assert_eq!(
        next_page.rows[0][0],
        Value::Json(Bson::ObjectId(object_id).into_canonical_extjson())
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn keyset_page_query_binds_binary_uuid_cursor_values() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let first = Binary {
        subtype: BinarySubtype::Uuid,
        bytes: vec![0; 16],
    };
    let second = Binary {
        subtype: BinarySubtype::Uuid,
        bytes: vec![1; 16],
    };
    let third = Binary {
        subtype: BinarySubtype::Uuid,
        bytes: vec![2; 16],
    };
    client
        .database("appdb")
        .collection::<Document>("keyset_uuid")
        .insert_many([
            doc! { "_id": Bson::Binary(third) },
            doc! { "_id": Bson::Binary(first.clone()) },
            doc! { "_id": Bson::Binary(second.clone()) },
        ])
        .await
        .unwrap();

    let connection = MongodbDriver.connect(super::opts(&host, port, "appdb")).await.unwrap();
    let page = connection
        .query_params(
            "SELECT * FROM \"appdb\".\"keyset_uuid\" WHERE \"_id\" > ? LIMIT 1 OFFSET 0",
            &[Value::Json(Bson::Binary(first).into_canonical_extjson())],
        )
        .await
        .unwrap();

    assert_eq!(page.rows.len(), 1);
    assert_eq!(
        page.rows[0][0],
        Value::Json(Bson::Binary(second).into_canonical_extjson())
    );
}
