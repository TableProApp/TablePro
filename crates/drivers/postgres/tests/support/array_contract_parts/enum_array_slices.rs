#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_slices_preserve_shape_and_rebind() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA enum_slice_contract").await.unwrap();
    connection
        .execute("CREATE TYPE enum_slice_contract.label AS ENUM ('ready', '', 'NULL', '東京')")
        .await
        .unwrap();

    let enum_type = "enum_slice_contract.label[]";
    let source = r#"'[0:1][2:4]={{ready,"",NULL},{NULL,"NULL",東京}}'::enum_slice_contract.label[]"#;
    let slices = connection
        .query(&format!(
            "WITH source(id, value) AS (VALUES \
                 (1, {source}), (2, NULL::{enum_type}), (3, '{{}}'::{enum_type})) \
             SELECT id, value[0:1][3:4] AS value FROM source ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(slices.columns[1].data_type, enum_type);
    assert_eq!(slices.rows[0][1], Value::Text(r#"{{"",NULL},{"NULL","東京"}}"#.into()));
    assert_eq!(slices.rows[1][1], Value::Null);
    assert_eq!(slices.rows[2][1], Value::Text("{}".into()));

    let native = connection
        .query(&format!(
            "WITH source(id, value) AS (VALUES \
                 (1, {source}), (2, NULL::{enum_type}), (3, '{{}}'::{enum_type})), \
             sliced AS (SELECT id, value[0:1][3:4] AS value FROM source) \
             SELECT id, pg_typeof(value)::text, array_dims(value), array_ndims(value), \
                    array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM sliced ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][1], Value::Text(enum_type.into()));
    assert_eq!(native.rows[0][2], Value::Text("[1:2][1:2]".into()));
    assert_eq!(native.rows[0][3], Value::Int(2));
    let Value::Text(native_json) = &native.rows[0][4] else {
        panic!("native array slice JSON oracle is not text: {:?}", native.rows[0][4]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!([["", null], ["NULL", "東京"]])
    );
    assert_eq!(native.rows[1][2], Value::Null);
    assert_eq!(native.rows[1][4], Value::Null);
    assert_eq!(native.rows[2][2], Value::Null);
    assert_eq!(native.rows[2][3], Value::Null);

    for (index, row) in slices.rows.iter().enumerate() {
        let rebound = connection
            .query_params(
                &format!(
                    "SELECT pg_typeof($1::text::{enum_type})::text, \
                            array_dims($1::text::{enum_type}), array_ndims($1::text::{enum_type}), \
                            array_to_json($1::text::{enum_type})::text, \
                            encode(array_send($1::text::{enum_type}), 'hex')"
                ),
                std::slice::from_ref(&row[1]),
            )
            .await
            .unwrap();
        assert_eq!(rebound.rows[0], native.rows[index][1..].to_vec());
    }
}
