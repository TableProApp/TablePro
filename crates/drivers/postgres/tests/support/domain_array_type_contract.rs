#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_array_preserves_native_values_and_wire_bytes() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let schema = "domain_over_array";
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    connection
        .execute(&format!(
            "CREATE DOMAIN {schema}.small_ints AS integer[] CHECK (cardinality(VALUE) <= 4)"
        ))
        .await
        .unwrap();

    connection
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, items {schema}.small_ints)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {schema}.rows VALUES \
             (1, '[0:2]={{1,NULL,3}}'::{schema}.small_ints), \
             (2, NULL), (3, '{{}}'), (4, '{{}}')"
        ))
        .await
        .unwrap();
    let result = connection
        .query(&format!("SELECT items FROM {schema}.rows ORDER BY id"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, format!("{schema}.small_ints"));
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Text(r#"[0:2]={"1",NULL,"3"}"#.into())],
            vec![Value::Null],
            vec![Value::Text("{}".into())],
            vec![Value::Text("{}".into())],
        ]
    );

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof(items)::text, items::text, array_to_json(items)::text, \
                    encode(array_send(items), 'hex') \
             FROM {schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text(format!("{schema}.small_ints")));
    assert_eq!(oracle.rows[0][1], Value::Text("[0:2]={1,NULL,3}".into()));
    assert_eq!(oracle.rows[0][2], Value::Text("[1,null,3]".into()));

    let rebound = connection
        .query_params(
            &format!(
                "SELECT pg_typeof($1::text::{schema}.small_ints)::text, \
                        array_to_json($1::text::{schema}.small_ints)::text, \
                        encode(array_send($1::text::{schema}.small_ints), 'hex')"
            ),
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][0]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][2], oracle.rows[0][3]);
    let direct_update = connection
        .query_params(
            &format!(
                "UPDATE {schema}.rows SET items = $1::text::{schema}.small_ints \
                 WHERE id = $2 RETURNING items::text, encode(array_send(items), 'hex')"
            ),
            &[Value::Text("[0:2]={2,4,NULL}".into()), Value::Int(4)],
        )
        .await
        .unwrap();
    assert_eq!(direct_update.rows[0][0], Value::Text("[0:2]={2,4,NULL}".into()));

    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    let edit = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, result.rows[0][0].clone(), Value::Text("[0:2]={2,4,NULL}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        edit.0,
        format!(
            "UPDATE \"{schema}\".\"rows\" SET \"items\" = $1::text::\"{schema}\".\"small_ints\" WHERE \"id\" = $2 AND \"items\" IS NOT DISTINCT FROM $3::text::\"{schema}\".\"small_ints\""
        )
    );
    assert_eq!(
        edit.1,
        vec![
            Value::Text("[0:2]={2,4,NULL}".into()),
            Value::Int(1),
            result.rows[0][0].clone(),
        ]
    );
    connection.execute_params(&edit.0, &edit.1).await.unwrap();
    let null_to_empty = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Null, Value::Text("{}".into()))],
        &[Value::Int(2)],
    )
    .unwrap();
    assert_eq!(
        null_to_empty.0,
        format!(
            "UPDATE \"{schema}\".\"rows\" SET \"items\" = $1::text::\"{schema}\".\"small_ints\" WHERE \"id\" = $2 AND \"items\" IS NOT DISTINCT FROM $3::text::\"{schema}\".\"small_ints\""
        )
    );
    assert_eq!(
        null_to_empty.1,
        vec![Value::Text("{}".into()), Value::Int(2), Value::Null]
    );
    connection
        .execute_params(&null_to_empty.0, &null_to_empty.1)
        .await
        .unwrap();
    let stored = connection
        .query(&format!(
            "SELECT id, pg_typeof(items)::text, items::text, array_to_json(items)::text, \
                    encode(array_send(items), 'hex') \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(stored.rows[0][1], Value::Text(format!("{schema}.small_ints")));
    assert_eq!(stored.rows[0][2], Value::Text("[0:2]={2,4,NULL}".into()));
    assert_eq!(stored.rows[0][3], Value::Text("[2,4,null]".into()));
    assert_eq!(stored.rows[1][1], Value::Text(format!("{schema}.small_ints")));
    assert_eq!(stored.rows[1][2], Value::Text("{}".into()));
    assert_eq!(stored.rows[1][3], Value::Text("[]".into()));
    assert_eq!(stored.rows[2][2], Value::Text("{}".into()));
    assert_eq!(stored.rows[1][4], stored.rows[2][4]);

    let invalid = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(
            1,
            Value::Text("[0:2]={2,4,NULL}".into()),
            Value::Text("{1,2,3,4,5}".into()),
        )],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection.execute_params(&invalid.0, &invalid.1).await.unwrap_err();
    assert!(
        matches!(&error, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "23514"),
        "domain check must refuse an oversized array: {error:?}"
    );
    let after_refusal = connection
        .query(&format!(
            "SELECT encode(array_send(items), 'hex') FROM {schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    assert_eq!(after_refusal.rows[0][0], stored.rows[0][4]);
}
