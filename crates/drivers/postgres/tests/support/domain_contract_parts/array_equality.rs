#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_equality_infers_parameter_and_bounds() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_equality")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_equality_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_equality_shadow.state AS ENUM ('shadow')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_equality.state AS ENUM \
             ('ready', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_equality.state_domain \
             AS value_contract_domain_array_equality.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_equality.rows \
             (id INT PRIMARY KEY, labels value_contract_domain_array_equality.state_domain[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_equality.rows VALUES \
             (1, ARRAY['ready'::value_contract_domain_array_equality.state_domain, \
                       'paused'::value_contract_domain_array_equality.state_domain]), \
             (2, ARRAY['ready'::value_contract_domain_array_equality.state_domain, \
                       'paused'::value_contract_domain_array_equality.state_domain]), \
             (3, '[0:1]={ready,paused}'::value_contract_domain_array_equality.state_domain[]), \
             (4, '{}'::value_contract_domain_array_equality.state_domain[]), \
             (5, NULL), \
             (6, ARRAY['ready'::value_contract_domain_array_equality.state_domain, \
                       NULL::value_contract_domain_array_equality.state_domain])",
        )
        .await
        .unwrap();

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(
            "SET LOCAL search_path TO value_contract_domain_array_equality_shadow, public",
        )
        .await
        .unwrap();
    let cases = [
        (
            Value::Text(r#"{"ready","paused"}"#.into()),
            r#"'{"ready","paused"}'::value_contract_domain_array_equality.state_domain[]"#,
            [Some(true), Some(true), Some(false), Some(false), None, Some(false)],
        ),
        (
            Value::Text("[0:1]={ready,paused}".into()),
            "'[0:1]={ready,paused}'::value_contract_domain_array_equality.state_domain[]",
            [Some(false), Some(false), Some(true), Some(false), None, Some(false)],
        ),
        (
            Value::Text("{}".into()),
            "'{}'::value_contract_domain_array_equality.state_domain[]",
            [Some(false), Some(false), Some(false), Some(true), None, Some(false)],
        ),
        (
            Value::Null,
            "NULL::value_contract_domain_array_equality.state_domain[]",
            [None, None, None, None, None, None],
        ),
        (
            Value::Text(r#"{"ready",NULL}"#.into()),
            r#"'{"ready",NULL}'::value_contract_domain_array_equality.state_domain[]"#,
            [Some(false), Some(false), Some(false), Some(false), None, Some(true)],
        ),
    ];
    for (parameter, native_array, expected_equality) in cases {
        let native = transaction
            .query(&format!(
                "SELECT id, labels = {native_array}, labels <> {native_array}, \
                 labels < {native_array}, labels <= {native_array}, \
                 labels > {native_array}, labels >= {native_array}, \
                 encode(array_send({native_array}), 'hex') \
                 FROM value_contract_domain_array_equality.rows ORDER BY id"
            ))
            .await
            .unwrap();
        for (row, equal) in native.rows.iter().zip(expected_equality) {
            assert_eq!(
                row[1],
                equal.map(Value::Bool).unwrap_or(Value::Null),
                "native equality for {native_array}"
            );
        }
        let expected_values = expected_equality
            .into_iter()
            .enumerate()
            .map(|(index, _)| {
                let row = &native.rows[index];
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    row[2].clone(),
                    row[3].clone(),
                    row[4].clone(),
                    row[5].clone(),
                    row[6].clone(),
                    row[7].clone(),
                    Value::Text("value_contract_domain_array_equality.state_domain[]".into()),
                ]
            })
            .collect::<Vec<_>>();

        let result = transaction
            .query_params(
                "SELECT id, labels = $1, labels <> $1, labels < $1, labels <= $1, \
                 labels > $1, labels >= $1, encode(array_send($1), 'hex'), \
                 pg_typeof($1)::text \
                 FROM value_contract_domain_array_equality.rows ORDER BY id",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(result.rows, expected_values, "array equality with {parameter:?}");
    }
    transaction.rollback().await.unwrap();
}
