#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_array_generate_subscripts_requires_qualified_cast_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_array_subscripts")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_array_subscripts_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_array_subscripts.state \
             AS ENUM ('ready', 'NULL', '', '東京', 'comma,label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_array_subscripts_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_array_subscripts";
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_array_subscripts_shadow, public")
        .await
        .unwrap();

    for (parameter, native_array) in [
        (
            Value::Text(r#"[0:1][2:3]={{"NULL",NULL},{"東京","comma,label"}}"#.into()),
            format!(r#"'[0:1][2:3]={{{{"NULL",NULL}},{{"東京","comma,label"}}}}'::{array_type}"#),
        ),
        (
            Value::Text(r#"{"",ready}"#.into()),
            format!(r#"'{{"",ready}}'::{array_type}"#),
        ),
        (Value::Text("{}".into()), format!("'{{}}'::{array_type}")),
        (Value::Null, format!("NULL::{array_type}")),
    ] {
        transaction
            .execute("SAVEPOINT untyped_generate_subscripts")
            .await
            .unwrap();
        let untyped = transaction
            .query_params(
                "SELECT subscript FROM generate_subscripts($1, 1) AS indices(subscript)",
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("generate_subscripts has no typed argument to infer the enum array");
        assert!(
            matches!(&untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
            "expected unresolved-polymorphic-type SQLSTATE 42804, got {untyped:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT untyped_generate_subscripts")
            .await
            .unwrap();

        for dimension in [1, 2] {
            for reverse in [false, true] {
                let native_subscripts = transaction
                    .query(&format!(
                        "SELECT array_agg(subscript)::text \
                         FROM generate_subscripts({native_array}, {dimension}, {reverse}) \
                         AS indices(subscript)"
                    ))
                    .await
                    .unwrap();
                let subscripts = transaction
                    .query_params(
                        &format!(
                            "SELECT array_agg(subscript)::text \
                             FROM generate_subscripts($1::{array_type}, {dimension}, {reverse}) \
                             AS indices(subscript)"
                        ),
                        std::slice::from_ref(&parameter),
                    )
                    .await
                    .unwrap();
                assert_eq!(
                    subscripts.rows, native_subscripts.rows,
                    "dimension {dimension}, reverse {reverse}, array {parameter:?}"
                );
            }
        }

        let native_type_and_bytes = transaction
            .query(&format!(
                "SELECT pg_typeof({native_array})::text, \
                 encode(array_send({native_array}), 'hex')"
            ))
            .await
            .unwrap();
        let type_and_bytes = transaction
            .query_params(
                &format!(
                    "SELECT pg_typeof($1::{array_type})::text, \
                     encode(array_send($1::{array_type}), 'hex')"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(type_and_bytes.rows, native_type_and_bytes.rows);
    }

    transaction
        .execute("SAVEPOINT shadow_only_generate_subscripts_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!(
                "SELECT subscript FROM generate_subscripts($1::{array_type}, 1) \
                 AS indices(subscript)"
            ),
            &[Value::Text(r#"{"shadow-only"}"#.into())],
        )
        .await
        .expect_err("a label defined only by the shadow enum must be rejected");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT shadow_only_generate_subscripts_label")
        .await
        .unwrap();
    transaction.rollback().await.unwrap();
}
