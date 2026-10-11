#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_uuid_array_preserves_values_and_wire_bytes() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let schema = "domain_uuid_array";
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    connection
        .execute(&format!(
            "CREATE DOMAIN {schema}.token AS uuid \
             CHECK (VALUE <> '00000000-0000-0000-0000-000000000000'::uuid)"
        ))
        .await
        .unwrap();
    let values = format!(
        "(1, NULL::{schema}.token[]), (2, ARRAY[]::{schema}.token[]), \
         (3, ARRAY['123e4567-e89b-12d3-a456-426614174000'::{schema}.token, \
                   NULL::{schema}.token, \
                   '00000000-0000-0000-0000-000000000001'::{schema}.token])"
    );
    let result = connection
        .query(&format!(
            "SELECT tokens FROM (VALUES {values}) AS source(id, tokens) ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, format!("{schema}.token[]"));
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Null],
            vec![Value::Text("{}".into())],
            vec![Value::Text(
                "{\"123e4567-e89b-12d3-a456-426614174000\",NULL,\"00000000-0000-0000-0000-000000000001\"}".into()
            )],
        ]
    );

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(tokens)::text, array_to_json(tokens)::text, \
                    encode(array_send(tokens), 'hex') \
             FROM (VALUES {values}) AS source(id, tokens) ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(format!("{schema}.token[]")));
    let bound = connection
        .query_params(
            &format!(
                "SELECT array_to_json($1::text::{schema}.token[])::text, \
                        encode(array_send($1::text::{schema}.token[]), 'hex')"
            ),
            std::slice::from_ref(&result.rows[2][0]),
        )
        .await
        .unwrap();
    assert_eq!(bound.rows[0][0], native.rows[2][1]);
    assert_eq!(bound.rows[0][1], native.rows[2][2]);

    connection
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, tokens {schema}.token[])"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {schema}.rows VALUES \
             (1, ARRAY['123e4567-e89b-12d3-a456-426614174000'::{schema}.token, NULL]), \
             (2, ARRAY['00000000-0000-0000-0000-000000000001'::{schema}.token])"
        ))
        .await
        .unwrap();
    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: "token".into()
        })
    );
    let sibling = connection
        .query(&format!(
            "SELECT encode(array_send(tokens), 'hex') FROM {schema}.rows WHERE id = 2"
        ))
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let edit = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, result.rows[2][0].clone())],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        edit.0.contains("::text::\"domain_uuid_array\".\"token\"[]"),
        "{}",
        edit.0
    );
    connection.execute_params(&edit.0, &edit.1).await.unwrap();
    let stored = connection
        .query(&format!(
            "SELECT id, pg_typeof(tokens)::text, array_to_json(tokens)::text, \
                    encode(array_send(tokens), 'hex') \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(stored.rows[0][1..], native.rows[2]);
    assert_eq!(stored.rows[1][3], sibling);

    let invalid = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("{00000000-0000-0000-0000-000000000000}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection.execute_in_transaction(&[invalid]).await.unwrap_err();
    let cause = match &error {
        tablepro_core::DriverError::Transaction { source, .. }
        | tablepro_core::DriverError::TransactionRollbackFailed { source, .. } => source.as_ref(),
        other => other,
    };
    assert!(
        matches!(cause, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "23514"),
        "{error:?}"
    );
    assert_eq!(
        connection
            .query(&format!(
                "SELECT pg_typeof(tokens)::text, array_to_json(tokens)::text, \
                        encode(array_send(tokens), 'hex') \
                 FROM {schema}.rows WHERE id = 1"
            ))
            .await
            .unwrap()
            .rows[0],
        native.rows[2]
    );
    assert_eq!(
        connection
            .query(&format!(
                "SELECT encode(array_send(tokens), 'hex') FROM {schema}.rows WHERE id = 2"
            ))
            .await
            .unwrap()
            .rows[0][0],
        sibling
    );
}
