#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_array_fill_preserves_type_bounds_and_nulls_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_fill")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_fill_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_array_fill.state \
             AS ENUM ('ready', 'NULL', '')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_array_fill_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_enum_array_fill";
    let enum_type = format!("{schema}.state");
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_enum_array_fill_shadow, public")
        .await
        .unwrap();

    for (parameter, native_value, dimensions, lower_bounds, expected_dims, expected_json) in [
        (
            Value::Text("ready".into()),
            format!("'ready'::{enum_type}"),
            "ARRAY[2, 2]",
            "ARRAY[0, -1]",
            Some("[0:1][-1:0]"),
            r#"[["ready","ready"],["ready","ready"]]"#,
        ),
        (
            Value::Text("NULL".into()),
            format!("'NULL'::{enum_type}"),
            "ARRAY[2, 2]",
            "ARRAY[0, -1]",
            Some("[0:1][-1:0]"),
            r#"[["NULL","NULL"],["NULL","NULL"]]"#,
        ),
        (
            Value::Text(String::new()),
            format!("''::{enum_type}"),
            "ARRAY[2]",
            "ARRAY[-2]",
            Some("[-2:-1]"),
            r#"["",""]"#,
        ),
        (
            Value::Null,
            format!("NULL::{enum_type}"),
            "ARRAY[2, 2]",
            "ARRAY[0, -1]",
            Some("[0:1][-1:0]"),
            "[[null,null],[null,null]]",
        ),
        (
            Value::Text("ready".into()),
            format!("'ready'::{enum_type}"),
            "ARRAY[0, 2]",
            "ARRAY[5, -1]",
            None,
            "[]",
        ),
    ] {
        transaction
            .execute("SAVEPOINT untyped_array_fill")
            .await
            .unwrap();
        let untyped = transaction
            .query_params(
                &format!("SELECT array_fill($1, {dimensions}, {lower_bounds})"),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("array_fill needs a typed element for polymorphic result resolution");
        assert!(
            matches!(&untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
            "expected unresolved-polymorphic-type SQLSTATE 42804, got {untyped:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT untyped_array_fill")
            .await
            .unwrap();

        let native_array = format!("array_fill({native_value}, {dimensions}, {lower_bounds})");
        let native = transaction
            .query(&format!(
                "SELECT array_dims({native_array})::text, array_ndims({native_array}), \
                 array_lower({native_array}, 1), array_upper({native_array}, 1), \
                 array_lower({native_array}, 2), array_upper({native_array}, 2), \
                 cardinality({native_array}), array_to_json({native_array})::text, \
                 pg_typeof({native_array})::text, encode(array_send({native_array}), 'hex')"
            ))
            .await
            .unwrap();
        let result = transaction
            .query_params(
                &format!(
                    "SELECT array_dims(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}))::text, \
                     array_ndims(array_fill($1::{enum_type}, {dimensions}, {lower_bounds})), \
                     array_lower(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}), 1), \
                     array_upper(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}), 1), \
                     array_lower(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}), 2), \
                     array_upper(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}), 2), \
                     cardinality(array_fill($1::{enum_type}, {dimensions}, {lower_bounds})), \
                     array_to_json(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}))::text, \
                     pg_typeof(array_fill($1::{enum_type}, {dimensions}, {lower_bounds}))::text, \
                     encode(array_send(array_fill($1::{enum_type}, {dimensions}, {lower_bounds})), 'hex')"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(result.rows, native.rows, "array_fill({parameter:?})");
        assert_eq!(
            native.rows[0][7],
            Value::Text(expected_json.into()),
            "array_fill JSON for {parameter:?}"
        );
        assert_eq!(native.rows[0][8], Value::Text(array_type.clone()));
        assert_eq!(
            native.rows[0][0],
            expected_dims.map_or(Value::Null, |dims| Value::Text(dims.into()))
        );
    }

    transaction
        .execute("SAVEPOINT shadow_only_array_fill_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!(
                "SELECT array_fill($1::{enum_type}, ARRAY[1])"
            ),
            &[Value::Text("shadow-only".into())],
        )
        .await
        .expect_err("a label defined only by the shadow enum must be rejected");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT shadow_only_array_fill_label")
        .await
        .unwrap();
    transaction.rollback().await.unwrap();
}
