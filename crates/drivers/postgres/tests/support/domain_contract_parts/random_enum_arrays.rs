#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_array_sample_and_shuffle_preserve_multisets_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_random_arrays")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_random_arrays_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_random_arrays.state \
             AS ENUM ('ready', 'NULL', '')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_random_arrays_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_random_arrays";
    let enum_type = format!("{schema}.state");
    let array_type = format!("{enum_type}[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_random_arrays_shadow, public")
        .await
        .unwrap();

    let input = Value::Text(r#"[0:5]={ready,ready,"NULL",NULL,"",ready}"#.into());
    let native_array = format!(r#"'[0:5]={{ready,ready,"NULL",NULL,"",ready}}'::{array_type}"#);
    transaction
        .execute("SAVEPOINT untyped_array_sample")
        .await
        .unwrap();
    let untyped_sample = transaction
        .query_params("SELECT array_sample($1, 2)", std::slice::from_ref(&input))
        .await
        .expect_err("array_sample needs an explicitly typed enum array");
    assert!(
        matches!(&untyped_sample, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
        "expected unresolved-polymorphic-type SQLSTATE 42804, got {untyped_sample:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT untyped_array_sample")
        .await
        .unwrap();

    transaction
        .execute("SAVEPOINT untyped_array_shuffle")
        .await
        .unwrap();
    let untyped_shuffle = transaction
        .query_params("SELECT array_shuffle($1)", std::slice::from_ref(&input))
        .await
        .expect_err("array_shuffle needs an explicitly typed enum array");
    assert!(
        matches!(&untyped_shuffle, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
        "expected unresolved-polymorphic-type SQLSTATE 42804, got {untyped_shuffle:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT untyped_array_shuffle")
        .await
        .unwrap();

    for sample_size in [0, 1, 3, 6] {
        for _ in 0..24 {
            let sampled = transaction
                .query_params(
                    &format!(
                        "SELECT cardinality(sampled), \
                         NOT EXISTS ( \
                           SELECT 1 FROM ( \
                             SELECT item, count(*) AS selected_count \
                             FROM unnest(sampled) AS selected(item) GROUP BY item \
                           ) AS selected \
                           WHERE selected_count > ( \
                             SELECT count(*) FROM unnest($1::{array_type}) AS source(item) \
                             WHERE source.item IS NOT DISTINCT FROM selected.item \
                           ) \
                         ), \
                         pg_typeof(sampled)::text, array_ndims(sampled), \
                         array_length(sampled, 1), array_dims(sampled)::text, \
                         array_lower(sampled, 1), array_upper(sampled, 1) \
                         FROM (SELECT array_sample($1::{array_type}, {sample_size}) \
                               AS sampled) AS result"
                    ),
                    std::slice::from_ref(&input),
                )
                .await
                .unwrap();
            let native_shape = transaction
                .query(&format!(
                    "SELECT pg_typeof(sampled)::text, array_ndims(sampled), \
                     array_length(sampled, 1), array_dims(sampled)::text, \
                     array_lower(sampled, 1), array_upper(sampled, 1) \
                     FROM (SELECT array_sample({native_array}, {sample_size}) \
                           AS sampled) AS result"
                ))
                .await
                .unwrap();
            let row = &sampled.rows[0];
            assert_eq!(row[0], Value::Int(sample_size));
            assert_eq!(row[1], Value::Bool(true), "sample must be an input multiset subset");
            assert_eq!(row[2], Value::Text(array_type.clone()));
            if sample_size == 0 {
                assert_eq!(row[3], Value::Null);
                assert_eq!(row[4], Value::Null);
                assert_eq!(row[5], Value::Null);
            } else {
                assert_eq!(row[3], Value::Int(1));
                assert_eq!(row[4], Value::Int(sample_size));
            }
            assert_eq!(&row[2..], native_shape.rows[0].as_slice());
        }
    }

    for _ in 0..32 {
        let shuffled = transaction
            .query_params(
                &format!(
                    "SELECT cardinality(shuffled), \
                     (SELECT COALESCE(jsonb_agg(item::text ORDER BY item::text NULLS FIRST), '[]'::jsonb) \
                      FROM unnest(shuffled) AS result(item)) = \
                     (SELECT COALESCE(jsonb_agg(item::text ORDER BY item::text NULLS FIRST), '[]'::jsonb) \
                      FROM unnest($1::{array_type}) AS source(item)), \
                     pg_typeof(shuffled)::text, array_ndims(shuffled), \
                     array_length(shuffled, 1), array_dims(shuffled)::text, \
                     array_lower(shuffled, 1), array_upper(shuffled, 1) \
                     FROM (SELECT array_shuffle($1::{array_type}) AS shuffled) AS result"
                ),
                std::slice::from_ref(&input),
            )
            .await
            .unwrap();
        let native_shape = transaction
            .query(&format!(
                "SELECT pg_typeof(shuffled)::text, array_ndims(shuffled), \
                 array_length(shuffled, 1), array_dims(shuffled)::text, \
                 array_lower(shuffled, 1), array_upper(shuffled, 1) \
                 FROM (SELECT array_shuffle({native_array}) AS shuffled) AS result"
            ))
            .await
            .unwrap();
        let row = &shuffled.rows[0];
        assert_eq!(row[0], Value::Int(6));
        assert_eq!(row[1], Value::Bool(true), "shuffle must preserve the full multiset");
        assert_eq!(row[2], Value::Text(array_type.clone()));
        assert_eq!(row[3], Value::Int(1));
        assert_eq!(row[4], Value::Int(6));
        assert_eq!(&row[2..], native_shape.rows[0].as_slice());
    }

    let multidimensional = r#"[0:1][4:5]={{ready,"NULL"},{NULL,""}}"#;
    for (function, expression, count, expected_json) in [
        (
            "array_sample",
            format!("array_sample($1::{array_type}, 1)"),
            1,
            vec![r#"[["ready","NULL"]]"#, r#"[[null,""]]"#],
        ),
        (
            "array_shuffle",
            format!("array_shuffle($1::{array_type})"),
            2,
            vec![
                r#"[["ready","NULL"],[null,""]]"#,
                r#"[[null,""],["ready","NULL"]]"#,
            ],
        ),
    ] {
        for _ in 0..24 {
            let result = transaction
                .query_params(
                    &format!(
                        "SELECT array_to_json(result)::text, array_ndims(result), \
                         array_length(result, 1), array_length(result, 2), \
                         pg_typeof(result)::text \
                         FROM (SELECT {expression} AS result) AS sampled"
                    ),
                    &[Value::Text(multidimensional.into())],
                )
                .await
                .unwrap();
            let row = &result.rows[0];
            assert!(
                expected_json.contains(&match &row[0] {
                    Value::Text(value) => value.as_str(),
                    other => panic!("expected JSON text, got {other:?}"),
                }),
                "{function} must select/shuffle whole first-dimension slices: {row:?}"
            );
            assert_eq!(row[1], Value::Int(2));
            assert_eq!(row[2], Value::Int(count));
            assert_eq!(row[3], Value::Int(2));
            assert_eq!(row[4], Value::Text(array_type.clone()));
        }
    }

    for (function, query) in [
        (
            "array_sample",
            format!("SELECT array_sample('{{}}'::{array_type}, 0)"),
        ),
        (
            "array_shuffle",
            format!("SELECT array_shuffle('{{}}'::{array_type})"),
        ),
    ] {
        let empty = transaction.query(&query).await.unwrap();
        assert_eq!(empty.rows, vec![vec![Value::Text("{}".into())]], "{function}");
    }

    for (function, expression) in [
        ("array_sample", format!("array_sample($1::{array_type}, 1)")),
        ("array_shuffle", format!("array_shuffle($1::{array_type})")),
    ] {
        let null_result = transaction
            .query_params(
                &format!("SELECT {expression} IS NULL, pg_typeof({expression})::text"),
                &[Value::Null],
            )
            .await
            .unwrap();
        assert_eq!(
            null_result.rows,
            vec![vec![Value::Bool(true), Value::Text(array_type.clone())]],
            "{function} with a SQL NULL array"
        );
    }

    transaction
        .execute("SAVEPOINT oversized_array_sample")
        .await
        .unwrap();
    let oversized = transaction
        .query_params(
            &format!("SELECT array_sample($1::{array_type}, 7)"),
            std::slice::from_ref(&input),
        )
        .await
        .expect_err("array_sample cannot request more items than the first dimension");
    assert!(
        matches!(&oversized, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22023"),
        "expected invalid-parameter SQLSTATE 22023, got {oversized:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT oversized_array_sample")
        .await
        .unwrap();

    transaction
        .execute("SAVEPOINT shadow_only_random_array_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!("SELECT array_shuffle($1::{array_type})"),
            &[Value::Text(r#"{"shadow-only"}"#.into())],
        )
        .await
        .expect_err("a shadow-only enum label must not resolve for the target array");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT shadow_only_random_array_label")
        .await
        .unwrap();
    transaction.rollback().await.unwrap();
}
