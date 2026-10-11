#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_array_to_string_preserves_labels_and_nulls_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_to_string")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_to_string_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_array_to_string.state \
             AS ENUM ('ready', 'NULL', '', 'comma,label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_array_to_string_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_enum_array_to_string";
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(
            "SET LOCAL search_path TO value_contract_enum_array_to_string_shadow, public",
        )
        .await
        .unwrap();

    for (parameter, native_array, expected_without_null_marker, expected_with_null_marker) in [
        (
            Value::Text(r#"[0:4]={ready,"NULL","","comma,label",NULL}"#.into()),
            format!(r#"'[0:4]={{ready,"NULL","","comma,label",NULL}}'::{array_type}"#),
            Some("ready|NULL||comma,label"),
            Some("ready|NULL||comma,label|<sql-null>"),
        ),
        (
            Value::Text(r#"[1:2][1:2]={{ready,"NULL"},{"",NULL}}"#.into()),
            format!(r#"'[1:2][1:2]={{{{ready,"NULL"}},{{"",NULL}}}}'::{array_type}"#),
            Some("ready|NULL|"),
            Some("ready|NULL||<sql-null>"),
        ),
        (
            Value::Text("{}".into()),
            format!("'{{}}'::{array_type}"),
            Some(""),
            Some(""),
        ),
        (
            Value::Null,
            format!("NULL::{array_type}"),
            None,
            None,
        ),
    ] {
        transaction
            .execute("SAVEPOINT untyped_array_to_string")
            .await
            .unwrap();
        let untyped = transaction
            .query_params(
                "SELECT array_to_string($1, '|')",
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("array_to_string needs a typed enum array argument");
        assert!(
            matches!(&untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
            "expected unresolved-polymorphic-type SQLSTATE 42804, got {untyped:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT untyped_array_to_string")
            .await
            .unwrap();

        let native = transaction
            .query(&format!(
                "SELECT array_to_string({native_array}, '|'), \
                 array_to_string({native_array}, '|', '<sql-null>'), \
                 pg_typeof({native_array})::text, \
                 encode(array_send({native_array}), 'hex')"
            ))
            .await
            .unwrap();
        assert_eq!(
            native.rows[0][0],
            expected_without_null_marker.map_or(Value::Null, |value| Value::Text(value.into())),
            "array_to_string without a SQL NULL marker for {parameter:?}"
        );
        assert_eq!(
            native.rows[0][1],
            expected_with_null_marker.map_or(Value::Null, |value| Value::Text(value.into())),
            "array_to_string with a SQL NULL marker for {parameter:?}"
        );

        let result = transaction
            .query_params(
                &format!(
                    "SELECT array_to_string($1::{array_type}, '|'), \
                     array_to_string($1::{array_type}, '|', '<sql-null>'), \
                     pg_typeof($1::{array_type})::text, \
                     encode(array_send($1::{array_type}), 'hex')"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(result.rows, native.rows, "array {parameter:?}");
    }

    transaction
        .execute("SAVEPOINT shadow_only_array_to_string_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!(
                "SELECT array_to_string($1::{array_type}, '|')"
            ),
            &[Value::Text(r#"{"shadow-only"}"#.into())],
        )
        .await
        .expect_err("a shadow-only enum label must not resolve through search_path");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT shadow_only_array_to_string_label")
        .await
        .unwrap();
    transaction.rollback().await.unwrap();
}
