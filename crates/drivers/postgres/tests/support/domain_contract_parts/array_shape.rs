#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_array_shape_functions_preserve_bounds_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_array_shape")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_array_shape_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_array_shape.state \
             AS ENUM ('ready', 'NULL', '', '東京', 'comma,label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_array_shape_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_array_shape";
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_array_shape_shadow, public")
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
            .execute("SAVEPOINT untyped_array_shape")
            .await
            .unwrap();
        let untyped = transaction
            .query_params(
                "SELECT array_dims($1), array_ndims($1), array_length($1, 1), \
                 cardinality($1)",
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("array shape functions have no typed argument for an unknown array");
        assert!(
            matches!(&untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
            "expected unresolved-polymorphic-type SQLSTATE 42804, got {untyped:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT untyped_array_shape")
            .await
            .unwrap();

        let native_shape = transaction
            .query(&format!(
                "SELECT array_dims({native_array})::text, array_ndims({native_array}), \
                 array_length({native_array}, 1), array_length({native_array}, 2), \
                 array_lower({native_array}, 1), array_upper({native_array}, 1), \
                 array_lower({native_array}, 2), array_upper({native_array}, 2), \
                 cardinality({native_array}), pg_typeof({native_array})::text, \
                 encode(array_send({native_array}), 'hex')"
            ))
            .await
            .unwrap();
        let shape = transaction
            .query_params(
                &format!(
                    "SELECT array_dims($1::{array_type})::text, \
                     array_ndims($1::{array_type}), \
                     array_length($1::{array_type}, 1), array_length($1::{array_type}, 2), \
                     array_lower($1::{array_type}, 1), array_upper($1::{array_type}, 1), \
                     array_lower($1::{array_type}, 2), array_upper($1::{array_type}, 2), \
                     cardinality($1::{array_type}), pg_typeof($1::{array_type})::text, \
                     encode(array_send($1::{array_type}), 'hex')"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(shape.rows, native_shape.rows, "shape for {parameter:?}");
    }

    transaction
        .execute("SAVEPOINT shadow_only_array_shape_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!(
                "SELECT array_ndims($1::{array_type})"
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
        .execute("ROLLBACK TO SAVEPOINT shadow_only_array_shape_label")
        .await
        .unwrap();
    transaction.rollback().await.unwrap();
}
