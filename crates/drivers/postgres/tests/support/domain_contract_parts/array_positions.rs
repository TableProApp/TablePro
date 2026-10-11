#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_positions_infers_scalar_parameter_and_matches_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_positions")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_positions_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_positions_shadow.state AS ENUM ('shadow')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_positions.state AS ENUM \
             ('ready', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_positions.state_domain \
             AS value_contract_domain_array_positions.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_positions.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_positions.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_positions.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();

    let schema = "value_contract_domain_array_positions";
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(
            "SET LOCAL search_path TO value_contract_domain_array_positions_shadow, public",
        )
        .await
        .unwrap();
    let cases = [
        (
            Value::Text("paused".into()),
            "'paused'::value_contract_domain_array_positions.state",
            ["[]", "[1,4]", "[]"],
        ),
        (
            Value::Null,
            "NULL::value_contract_domain_array_positions.state",
            ["[3]", "[3]", "[1,3,4]"],
        ),
    ];
    for (parameter, native_value, positions) in cases {
        let native = transaction
            .query(&format!(
                "SELECT id, array_to_json(array_positions(\
                 ARRAY[status::{schema}.state, 'ready'::{schema}.state, \
                 NULL::{schema}.state, status::{schema}.state], {native_value}))::text \
                 FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            positions
                .into_iter()
                .enumerate()
                .map(|(index, positions)| {
                    vec![
                        Value::Int(index as i64 + 1),
                        Value::Text(positions.into()),
                    ]
                })
                .collect::<Vec<_>>(),
            "native array_positions with {parameter:?}"
        );
        let result = transaction
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_positions(\
                     ARRAY[status::{schema}.state, 'ready'::{schema}.state, \
                     NULL::{schema}.state, status::{schema}.state], $1))::text, \
                     pg_typeof($1)::text, pg_typeof(array_positions(\
                     ARRAY[status::{schema}.state, 'ready'::{schema}.state, \
                     NULL::{schema}.state, status::{schema}.state], $1))::text \
                     FROM {schema}.rows ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        let expected = native
            .rows
            .into_iter()
            .map(|row| {
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    Value::Text(format!("{schema}.state")),
                    Value::Text("integer[]".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "array_positions with {parameter:?}");
    }
    transaction.rollback().await.unwrap();
}
