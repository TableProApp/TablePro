#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_cat_infers_array_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_cat")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_cat_shadow")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_domain_array_cat_shadow.state AS ENUM ('shadow')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_cat.state AS ENUM \
             ('ready', 'paused', 'NULL', '', 'comma,label', 'quote\"label', 'backslash\\label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_cat.state_domain \
             AS value_contract_domain_array_cat.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_cat.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_cat.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_cat.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, 'NULL'), (4, ''), (5, NULL)",
        )
        .await
        .unwrap();

    let schema = "value_contract_domain_array_cat";
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_domain_array_cat_shadow, public")
        .await
        .unwrap();
    let cases = [
        (
            Value::Text(r#"{"paused"}"#.into()),
            r#"'{"paused"}'::value_contract_domain_array_cat.state[]"#,
        ),
        (
            Value::Text(r#"{"NULL","","comma,label","quote\"label","backslash\\label"}"#.into()),
            r#"'{"NULL","","comma,label","quote\"label","backslash\\label"}'::value_contract_domain_array_cat.state[]"#,
        ),
        (
            Value::Text(r#"{"ready",NULL}"#.into()),
            r#"'{"ready",NULL}'::value_contract_domain_array_cat.state[]"#,
        ),
        (
            Value::Text("{}".into()),
            "'{}'::value_contract_domain_array_cat.state[]",
        ),
        (
            Value::Null,
            "NULL::value_contract_domain_array_cat.state[]",
        ),
    ];
    for (parameter, native_array) in cases {
        let native = transaction
            .query(&format!(
                "SELECT id, array_to_json(array_cat(ARRAY[status::{schema}.state], \
                 {native_array}))::text FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let result = transaction
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_cat(ARRAY[status::{schema}.state], $1))::text, \
                     pg_typeof($1)::text, pg_typeof(array_cat(ARRAY[status::{schema}.state], $1))::text \
                     FROM {schema}.rows ORDER BY id"
                ),
                &[parameter],
            )
            .await
            .unwrap();
        let expected = native
            .rows
            .into_iter()
            .map(|row| {
                vec![row[0].clone(), row[1].clone(), Value::Text(array_type.clone()), Value::Text(array_type.clone())]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "array_cat parameter {native_array}");
    }
    transaction.rollback().await.unwrap();
}
