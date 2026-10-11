#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_timestamptz_array_rebinding_preserves_instants_after_timezone_change() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("SET LOCAL TIME ZONE 'America/Los_Angeles'").await.unwrap();
    let expression = "ARRAY['2024-11-03 01:30:00-04', '2024-11-03 01:30:00-05', \
                      'infinity', '-infinity', NULL]::timestamptz[]";
    let result = transaction.query(&format!("SELECT {expression} AS value")).await.unwrap();
    assert_array_value("timestamptz[]", &result);
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("timestamptz[] result must remain exact array text: {:?}", result.rows[0][0]);
    };
    let original_wire = transaction
        .query(&format!("SELECT encode(array_send({expression}), 'hex')"))
        .await
        .unwrap();

    transaction.execute("SET LOCAL TIME ZONE 'UTC'").await.unwrap();
    let expected = transaction
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    let rebound = transaction
        .query_params(
            "SELECT pg_typeof($1::text::timestamptz[])::text, \
                    array_to_json($1::text::timestamptz[])::text, \
                    encode(array_send($1::text::timestamptz[]), 'hex')",
            std::slice::from_ref(&Value::Text(array_text.clone())),
        )
        .await
        .unwrap();
    assert_eq!(expected.rows[0][0], Value::Text("timestamp with time zone[]".into()));
    assert_eq!(rebound.rows, expected.rows);
    assert_eq!(original_wire.rows[0][0], expected.rows[0][2]);
    transaction.rollback().await.unwrap();
}
