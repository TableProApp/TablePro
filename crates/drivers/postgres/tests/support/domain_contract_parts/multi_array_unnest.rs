#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_multi_array_unnest_pads_nulls_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_multi_unnest")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_multi_unnest_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_multi_unnest.state \
             AS ENUM ('ready', 'NULL', '')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_multi_unnest_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_multi_unnest";
    let enum_type = format!("{schema}.state");
    let enum_array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_multi_unnest_shadow, public")
        .await
        .unwrap();

    let cases = [
        (
            Value::Text(r#"[0:2]={"NULL",NULL,""}"#.into()),
            format!(r#"'[0:2]={{"NULL",NULL,""}}'::{enum_array_type}"#),
            Value::Text("{7,9}".into()),
            "'{7,9}'::integer[]".to_owned(),
            vec![
                (Some("NULL"), Some(7)),
                (None, Some(9)),
                (Some(""), None),
            ],
        ),
        (
            Value::Text(r#"{"ready"}"#.into()),
            format!(r#"'{{"ready"}}'::{enum_array_type}"#),
            Value::Text("{7,9}".into()),
            "'{7,9}'::integer[]".to_owned(),
            vec![(Some("ready"), Some(7)), (None, Some(9))],
        ),
        (
            Value::Null,
            format!("NULL::{enum_array_type}"),
            Value::Text("{7,9}".into()),
            "'{7,9}'::integer[]".to_owned(),
            vec![(None, Some(7)), (None, Some(9))],
        ),
        (
            Value::Text(r#"{"ready","NULL"}"#.into()),
            format!(r#"'{{"ready","NULL"}}'::{enum_array_type}"#),
            Value::Null,
            "NULL::integer[]".to_owned(),
            vec![(Some("ready"), None), (Some("NULL"), None)],
        ),
        (
            Value::Text(r#"[0:1][-1:0]={{ready,"NULL"},{NULL,""}}"#.into()),
            format!(r#"'[0:1][-1:0]={{{{ready,"NULL"}},{{NULL,""}}}}'::{enum_array_type}"#),
            Value::Text("{100}".into()),
            "'{100}'::integer[]".to_owned(),
            vec![
                (Some("ready"), Some(100)),
                (Some("NULL"), None),
                (None, None),
                (Some(""), None),
            ],
        ),
        (
            Value::Text("{}".into()),
            format!("'{{}}'::{enum_array_type}"),
            Value::Text("{10,20}".into()),
            "'{10,20}'::integer[]".to_owned(),
            vec![(None, Some(10)), (None, Some(20))],
        ),
        (
            Value::Text("{}".into()),
            format!("'{{}}'::{enum_array_type}"),
            Value::Text("{}".into()),
            "'{}'::integer[]".to_owned(),
            vec![],
        ),
    ];

    for (enum_parameter, native_enum_array, integer_parameter, native_integer_array, expected)
        in cases
    {
        transaction
            .execute("SAVEPOINT untyped_multi_array_unnest")
            .await
            .unwrap();
        let untyped = transaction
            .query_params(
                "SELECT enum_value, integer_value \
                 FROM unnest($1, $2) AS values(enum_value, integer_value)",
                &[enum_parameter.clone(), integer_parameter.clone()],
            )
            .await
            .expect_err("multi-array unnest needs typed polymorphic array arguments");
        assert!(
            matches!(&untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42725"),
            "expected ambiguous-function SQLSTATE 42725, got {untyped:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT untyped_multi_array_unnest")
            .await
            .unwrap();

        let native = transaction
            .query(&format!(
                "SELECT ordinality, enum_value::text, integer_value, \
                 pg_typeof(enum_value)::text, pg_typeof(integer_value)::text \
                 FROM unnest({native_enum_array}, {native_integer_array}) \
                 WITH ORDINALITY AS values(enum_value, integer_value, ordinality) \
                 ORDER BY ordinality"
            ))
            .await
            .unwrap();
        let result = transaction
            .query_params(
                &format!(
                    "SELECT ordinality, enum_value::text, integer_value, \
                     pg_typeof(enum_value)::text, pg_typeof(integer_value)::text \
                     FROM unnest($1::{enum_array_type}, $2::integer[]) \
                     WITH ORDINALITY AS values(enum_value, integer_value, ordinality) \
                     ORDER BY ordinality"
                ),
                &[enum_parameter, integer_parameter],
            )
            .await
            .unwrap();
        assert_eq!(result.rows, native.rows);

        let expected_rows = expected
            .into_iter()
            .enumerate()
            .map(|(index, (enum_value, integer_value))| {
                vec![
                    Value::Int(index as i64 + 1),
                    enum_value.map_or(Value::Null, |value| Value::Text(value.into())),
                    integer_value.map_or(Value::Null, Value::Int),
                    Value::Text(enum_type.clone()),
                    Value::Text("integer".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected_rows);
    }

    transaction
        .execute("SAVEPOINT shadow_only_multi_array_unnest_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!(
                "SELECT * FROM unnest($1::{enum_array_type}, $2::integer[])"
            ),
            &[Value::Text(r#"{"shadow-only"}"#.into()), Value::Text("{1}".into())],
        )
        .await
        .expect_err("a shadow-only enum label must not resolve for the target array");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT shadow_only_multi_array_unnest_label")
        .await
        .unwrap();
    transaction.rollback().await.unwrap();
}
