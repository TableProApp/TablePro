#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_bytea_array_preserves_binary_values_and_wire_bytes() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let schema = "domain_bytea_array";
    let shadow_schema = "domain_bytea_array_shadow";
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    connection
        .execute(&format!("CREATE SCHEMA {shadow_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE DOMAIN {schema}.payload AS bytea CHECK (octet_length(VALUE) <= 4)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE DOMAIN {shadow_schema}.payload AS bytea CHECK (octet_length(VALUE) <= 1)"
        ))
        .await
        .unwrap();

    let populated = format!(
        "ARRAY[decode('00ff275c','hex')::{schema}.payload, \
         decode('','hex')::{schema}.payload, NULL::{schema}.payload]"
    );
    let result = connection
        .query(&format!(
            "SELECT {populated}, NULL::{schema}.payload[], ARRAY[]::{schema}.payload[]"
        ))
        .await
        .unwrap();
    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        [
            "domain_bytea_array.payload[]",
            "domain_bytea_array.payload[]",
            "domain_bytea_array.payload[]",
        ]
    );
    assert_eq!(result.rows[0][1], Value::Null);
    assert_eq!(result.rows[0][2], Value::Text("{}".into()));

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(items)::text, items::text, array_to_json(items)::text, \
                    encode(array_send(items), 'hex') \
             FROM (SELECT {populated} AS items) AS source"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(format!("{schema}.payload[]")));
    assert_eq!(result.rows[0][0], native.rows[0][1]);

    let elements = connection
        .query(&format!(
            "SELECT ord::bigint, encode(element, 'hex') \
             FROM unnest({populated}) WITH ORDINALITY AS items(element, ord) ORDER BY ord"
        ))
        .await
        .unwrap();
    assert_eq!(
        elements.rows,
        vec![
            vec![Value::Int(1), Value::Text("00ff275c".into())],
            vec![Value::Int(2), Value::Text(String::new())],
            vec![Value::Int(3), Value::Null],
        ]
    );

    let bound = connection
        .query_params(
            &format!(
                "SELECT pg_typeof($1::text::{schema}.payload[])::text, \
                        array_to_json($1::text::{schema}.payload[])::text, \
                        encode(array_send($1::text::{schema}.payload[]), 'hex')"
            ),
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(bound.rows[0][0], native.rows[0][0]);
    assert_eq!(bound.rows[0][1], native.rows[0][2]);
    assert_eq!(bound.rows[0][2], native.rows[0][3]);

    for (value, expression) in [
        (&result.rows[0][1], format!("NULL::{schema}.payload[]")),
        (&result.rows[0][2], format!("ARRAY[]::{schema}.payload[]")),
    ] {
        let oracle = connection
            .query(&format!(
                "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                        encode(array_send({expression}), 'hex')"
            ))
            .await
            .unwrap();
        let rebound = connection
            .query_params(
                &format!(
                    "SELECT pg_typeof($1::text::{schema}.payload[])::text, \
                            array_to_json($1::text::{schema}.payload[])::text, \
                            encode(array_send($1::text::{schema}.payload[]), 'hex')"
                ),
                std::slice::from_ref(value),
            )
            .await
            .unwrap();
        assert_eq!(rebound.rows[0], oracle.rows[0]);
    }

    connection
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, payloads {schema}.payload[])"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {schema}.rows VALUES \
             (1, ARRAY[decode('0102','hex')::{schema}.payload, NULL]), \
             (2, ARRAY[decode('aabb','hex')::{schema}.payload])"
        ))
        .await
        .unwrap();
    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    let sibling_before = connection
        .query(&format!(
            "SELECT encode(array_send(payloads), 'hex') FROM {schema}.rows WHERE id = 2"
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
        &[(1, result.rows[0][0].clone())],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        edit.0.contains("::text::\"domain_bytea_array\".\"payload\"[]"),
        "{}",
        edit.0
    );
    connection.execute_params(&edit.0, &edit.1).await.unwrap();
    let stored = connection
        .query(&format!(
            "SELECT id, pg_typeof(payloads)::text, array_to_json(payloads)::text, \
                    encode(array_send(payloads), 'hex') \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(stored.rows[0][1], native.rows[0][0]);
    assert_eq!(stored.rows[0][2], native.rows[0][2]);
    assert_eq!(stored.rows[0][3], native.rows[0][3]);
    assert_eq!(stored.rows[1][3], sibling_before);

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET search_path TO {shadow_schema}"))
        .await
        .unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows[0][0],
        Value::Text(shadow_schema.into())
    );
    transaction.execute("SAVEPOINT shadow_domain_check").await.unwrap();
    let shadow_rejection = transaction
        .query(&format!("SELECT decode('00ff275c', 'hex')::{shadow_schema}.payload"))
        .await
        .unwrap_err();
    assert!(
        matches!(
            &shadow_rejection,
            tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "23514"
        ),
        "{shadow_rejection:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT shadow_domain_check")
        .await
        .unwrap();
    assert!(edit.0.contains("::text::\"domain_bytea_array\".\"payload\"[]"));
    transaction.execute_params(&edit.0, &edit.1).await.unwrap();
    let shadowed_path_stored = transaction
        .query(&format!(
            "SELECT id, pg_typeof(payloads)::text, array_to_json(payloads)::text, \
                    encode(array_send(payloads), 'hex') \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(shadowed_path_stored.rows, stored.rows);
    transaction.commit().await.unwrap();

    let invalid = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text(r#"{"\\x0011223344"}"#.into()))],
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
    let after_refusal = connection
        .query(&format!(
            "SELECT id, pg_typeof(payloads)::text, array_to_json(payloads)::text, \
                    encode(array_send(payloads), 'hex') \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(after_refusal.rows, stored.rows);
}
