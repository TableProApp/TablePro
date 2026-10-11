#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use drivers_duckdb::DuckdbDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Value};

#[path = "support/ubigint_array.rs"]
mod bigint_array;
#[path = "support/ubigint_map.rs"]
mod bigint_map;
#[path = "support/ubigint_struct.rs"]
mod bigint_struct;
#[path = "support/extended_timestamptz.rs"]
mod extended_timestamptz;
#[path = "support/uhugeint_fixed_array.rs"]
mod fixed_uhugeint_array;
#[path = "support/interval_csv_import.rs"]
mod interval_csv_import;
#[path = "support/nested_collection_refusal.rs"]
mod nested_collection_refusal;
#[path = "support/rust_decimal_boundaries.rs"]
mod rust_decimal_boundaries;
#[path = "support/submicro_parameter_expression.rs"]
mod submicro_parameter_expression;
#[path = "support/uhugeint_union.rs"]
mod uhugeint_union;
#[path = "support/uuid_mixed_projection.rs"]
mod uuid_mixed_projection;
#[path = "../../../core/tests/support/value_contract.rs"]
mod value_contract;

#[tokio::test]
async fn value_contract_preserves_scalar_boundaries_through_parameters_and_exports() {
    let connection = DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    value_contract::assert_scalar_contract(connection.as_ref(), "duckdb").await;
}

#[tokio::test]
async fn query_with_zero_rows_preserves_column_metadata_and_completeness() {
    let connection = native_connection().await;
    let result = connection
        .query("SELECT 42::HUGEINT AS amount, 'payload'::VARCHAR AS label WHERE false")
        .await
        .unwrap();

    assert!(result.rows.is_empty());
    assert!(!result.truncated);
    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        vec!["amount", "label"]
    );
    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        vec!["Decimal128(38, 0)", "Utf8"]
    );
    let native_types = connection
        .query("SELECT typeof(42::HUGEINT), typeof('payload'::VARCHAR)")
        .await
        .unwrap();
    assert_eq!(
        native_types.rows,
        vec![vec![Value::Text("HUGEINT".into()), Value::Text("VARCHAR".into())]]
    );
}

#[tokio::test]
async fn fetch_columns_reports_composite_primary_key_columns() {
    let connection = native_connection().await;
    connection
        .execute(
            "CREATE TABLE composite_keys (tenant INTEGER, item INTEGER, label VARCHAR, \
             PRIMARY KEY (tenant, item))",
        )
        .await
        .unwrap();

    let oracle = connection
        .query(
            "SELECT constraint_column_names::VARCHAR FROM duckdb_constraints() \
             WHERE table_name = 'composite_keys' AND constraint_type = 'PRIMARY KEY'",
        )
        .await
        .unwrap();
    assert_eq!(oracle.rows, vec![vec![Value::Text("[tenant, item]".into())]]);

    let columns = connection.fetch_columns(None, "composite_keys").await.unwrap();
    assert_eq!(
        columns
            .iter()
            .map(|column| (column.name.as_str(), column.primary_key))
            .collect::<Vec<_>>(),
        vec![("tenant", true), ("item", true), ("label", false)]
    );
}

#[tokio::test]
async fn query_preserves_duplicate_column_names_and_row_order() {
    let connection = native_connection().await;
    let result = connection
        .query("SELECT 17 AS duplicate, 'second' AS duplicate UNION ALL SELECT 23, 'fourth'")
        .await
        .unwrap();

    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        vec!["duplicate", "duplicate"]
    );
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(17), Value::Text("second".into())],
            vec![Value::Int(23), Value::Text("fourth".into())],
        ]
    );
    assert!(!result.truncated);
}

#[tokio::test]
async fn query_truncates_when_result_memory_budget_is_exceeded() {
    let connection = native_connection().await;
    let cap = tablepro_core::MAX_QUERY_ROWS;

    let over = connection
        .query(&format!("SELECT i FROM range({}) AS t(i)", cap + 1))
        .await
        .unwrap();
    assert!(!over.rows.is_empty());
    assert!(over.rows.len() < cap, "decoded memory budget binds before row cap");
    assert_eq!(over.rows.first(), Some(&vec![Value::Int(0)]));
    assert_eq!(over.rows.last(), Some(&vec![Value::Int((over.rows.len() - 1) as i64)]));
    assert!(over.truncated, "remaining server rows must be reported");
}

async fn native_connection() -> Box<dyn Connection> {
    DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap()
}

#[tokio::test]
async fn value_contract_native_temporals_round_trip_parameters_and_sql() {
    let connection = native_connection().await;
    for (kind, text) in [
        ("DATE", "1969-12-31"),
        ("DATE", "2000-02-29"),
        ("DATE", "10000-01-01"),
        ("DATE", "1000000-01-01"),
        ("DATE", "0001-01-01 (BC)"),
        ("DATE", "0002-12-31 (BC)"),
        ("TIME", "24:00:00"),
        ("TIME", "23:59:59.123456"),
        ("TIME", "00:00:00"),
        ("TIMESTAMP_S", "1969-12-31 23:59:59"),
        ("TIMESTAMP_MS", "1969-12-31 23:59:59.999"),
        ("TIMESTAMP", "1969-12-31 23:59:59.999999"),
        ("TIMESTAMP", "100000-01-02 03:04:05.123456"),
        ("TIMESTAMP", "0001-01-01 (BC) 00:00:00"),
        ("TIMESTAMP_NS", "1969-12-31 23:59:59.999999999"),
        ("TIMESTAMP_NS", "2026-09-27 12:34:56.123456789"),
        ("TIMESTAMPTZ", "2026-09-27 12:34:56.123456+05:30"),
        ("DATE", "infinity"),
        ("DATE", "-infinity"),
        ("TIMESTAMP", "infinity"),
        ("TIMESTAMP", "-infinity"),
    ] {
        let source = format!("CAST('{text}' AS {kind})");
        let result = connection.query(&format!("SELECT {source}")).await.unwrap();
        let value = &result.rows[0][0];
        assert!(!matches!(value, Value::Undecodable(_)), "{kind}: {value:?}");
        if kind == "TIMESTAMPTZ" {
            assert!(matches!(value, Value::TimestampTz(_)));
        }
        let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", value).unwrap();
        let round_trip = connection
            .query(&format!(
                "SELECT CAST(CAST({literal} AS {kind}) AS VARCHAR) = CAST({source} AS VARCHAR)"
            ))
            .await
            .unwrap();
        assert_eq!(round_trip.rows, vec![vec![Value::Bool(true)]], "{kind}: {value:?}");
        let bound = connection
            .query_params(
                &format!("SELECT CAST(CAST(? AS {kind}) AS VARCHAR) = CAST({source} AS VARCHAR)"),
                std::slice::from_ref(value),
            )
            .await
            .unwrap();
        assert_eq!(bound.rows, vec![vec![Value::Bool(true)]], "bound {kind}: {value:?}");
    }
}

#[tokio::test]
async fn value_contract_submicro_temporals_bind_as_exact_text() {
    let connection = native_connection().await;
    let time = chrono::NaiveTime::from_hms_nano_opt(12, 34, 56, 123_456_789).unwrap();
    let timestamp =
        chrono::NaiveDateTime::parse_from_str("1969-12-31 23:59:59.123456789", "%Y-%m-%d %H:%M:%S%.f").unwrap();
    let timestamp_tz = chrono::DateTime::parse_from_rfc3339("2026-09-27T12:34:56.123456789+05:30")
        .unwrap()
        .to_utc();
    let values = [
        Value::Time(time),
        Value::DateTime(timestamp),
        Value::TimestampTz(timestamp_tz),
    ];

    let types = connection
        .query_params("SELECT typeof(?), typeof(?), typeof(?)", &values)
        .await
        .unwrap();
    assert_eq!(
        types.rows,
        vec![vec![
            Value::Text("VARCHAR".into()),
            Value::Text("VARCHAR".into()),
            Value::Text("VARCHAR".into()),
        ]],
        "these values exceed DuckDB's lossless bound temporal precision"
    );

    let echoed = connection.query_params("SELECT ?, ?, ?", &values).await.unwrap();
    assert_eq!(
        echoed.rows,
        vec![vec![
            Value::Text("12:34:56.123456789".into()),
            Value::Text("1969-12-31 23:59:59.123456789".into()),
            Value::Text("2026-09-27T07:04:56.123456789+00:00".into()),
        ]],
        "submicro parameters must retain every digit and the UTC instant"
    );
}

#[test]
fn pinned_duckdb_binding_api_truncates_nanosecond_temporals_to_microseconds() {
    use duckdb::types::{TimeUnit, Value as DuckdbValue};

    let connection = duckdb::Connection::open_in_memory().unwrap();
    let time = DuckdbValue::Time64(TimeUnit::Nanosecond, 45_296_123_456_789);
    let timestamp = DuckdbValue::Timestamp(TimeUnit::Nanosecond, 1_790_512_496_123_456_789);

    let (time_type, time_text): (String, String) = connection
        .query_row("SELECT typeof(?1), CAST(?1 AS VARCHAR)", [&time], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();
    let (timestamp_type, timestamp_text): (String, String) = connection
        .query_row("SELECT typeof(?1), CAST(?1 AS VARCHAR)", [&timestamp], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();

    assert_eq!(time_type, "TIME");
    assert_eq!(time_text, "12:34:56.123456");
    assert_eq!(timestamp_type, "TIMESTAMP");
    assert_eq!(timestamp_text, "2026-09-27 12:34:56.123456");
}

#[tokio::test]
async fn value_contract_enum_labels_and_unsupported_collections_are_explicit() {
    let connection = native_connection().await;
    connection
        .execute("CREATE TYPE mood AS ENUM ('', 'NULL', '東京')")
        .await
        .unwrap();
    let result = connection
        .query("SELECT ''::mood, 'NULL'::mood, '東京'::mood, NULL::mood")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("".into()),
            Value::Text("NULL".into()),
            Value::Text("東京".into()),
            Value::Null
        ]]
    );
    for label in ["", "NULL", "東京"] {
        let value = Value::Text(label.into());
        let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", &value).unwrap();
        let literal_result = connection
            .query(&format!("SELECT typeof({literal}::mood), {literal}::mood::VARCHAR"))
            .await
            .unwrap();
        assert!(
            matches!(&literal_result.rows[0][0], Value::Text(native_type) if native_type.starts_with("ENUM")),
            "{:?}",
            literal_result.rows
        );
        assert_eq!(literal_result.rows[0][1], Value::Text(label.into()));

        let bound_result = connection
            .query_params(
                "SELECT typeof(CAST(? AS mood)), CAST(? AS mood)::VARCHAR",
                &[value.clone(), value],
            )
            .await
            .unwrap();
        assert!(
            matches!(&bound_result.rows[0][0], Value::Text(native_type) if native_type.starts_with("ENUM")),
            "{:?}",
            bound_result.rows
        );
        assert_eq!(bound_result.rows[0][1], Value::Text(label.into()));
    }
    for expression in [
        "[1, NULL, 3]",
        "[1, 2]::INTEGER[2]",
        "{'a': 1}",
        "MAP(['a'], [1])",
        "union_value(a := 1)",
    ] {
        let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
        let value = &result.rows[0][0];
        assert!(matches!(value, Value::Undecodable(_)), "{expression}: {value:?}");
        assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
        assert!(
            connection
                .query_params("SELECT ?", std::slice::from_ref(value))
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn value_contract_nested_uhugeint_refuses_lossy_consumers() {
    let connection = native_connection().await;
    let expression = "[18446744073709551616::UHUGEINT]";
    let oracle = connection
        .query(&format!("SELECT typeof({expression}), ({expression})[1]::VARCHAR"))
        .await
        .unwrap();
    assert_eq!(
        oracle.rows,
        vec![vec![
            Value::Text("UHUGEINT[]".into()),
            Value::Text("18446744073709551616".into())
        ]]
    );

    let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
    let value = &result.rows[0][0];
    assert!(matches!(value, Value::Undecodable(_)), "{value:?}");
    assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
    assert!(
        connection
            .query_params("SELECT ?", std::slice::from_ref(value))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn value_contract_nested_uhugeint_struct_shapes_refuse_lossy_consumers() {
    let connection = native_connection().await;
    let wide = "18446744073709551616";
    let cases = [
        (
            format!("STRUCT_PACK(amount := {wide}::UHUGEINT)"),
            "STRUCT(amount UHUGEINT)",
            format!("{{'amount': {wide}}}"),
        ),
        (
            format!("[STRUCT_PACK(amount := {wide}::UHUGEINT)]"),
            "STRUCT(amount UHUGEINT)[]",
            format!("[{{'amount': {wide}}}]"),
        ),
    ];

    for (expression, expected_type, expected_text) in cases {
        let oracle = connection
            .query(&format!(
                "SELECT typeof(value), CAST(value AS VARCHAR) FROM (SELECT {expression} AS value) source"
            ))
            .await
            .unwrap();
        assert_eq!(
            oracle.rows,
            vec![vec![Value::Text(expected_type.into()), Value::Text(expected_text)]],
            "native oracle for {expression}"
        );

        let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
        let value = &result.rows[0][0];
        assert!(matches!(value, Value::Undecodable(_)), "{expression}: {value:?}");
        assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
        assert!(
            connection
                .query_params("SELECT ?", std::slice::from_ref(value))
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn value_contract_wide_map_refuses_lossy_consumers_with_native_oracle() {
    let connection = native_connection().await;
    let expression = "MAP(['alpha', 'beta'], [18446744073709551616::UHUGEINT, NULL]::UHUGEINT[])";
    let oracle = connection
        .query(&format!(
            "SELECT typeof(value), value::VARCHAR FROM (SELECT {expression} AS value) source"
        ))
        .await
        .unwrap();
    assert_eq!(
        oracle.rows,
        vec![vec![
            Value::Text("MAP(VARCHAR, UHUGEINT)".into()),
            Value::Text("{alpha=18446744073709551616, beta=NULL}".into()),
        ]]
    );

    let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
    let value = &result.rows[0][0];
    assert!(matches!(value, Value::Undecodable(_)), "{value:?}");
    assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
    assert!(
        connection
            .query_params("SELECT ?", std::slice::from_ref(value))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn value_contract_list_array_and_struct_refusals_keep_native_oracles() {
    let connection = native_connection().await;
    for (expression, expected_type, expected_json) in [
        ("[1, NULL, 3]", "INTEGER[]", "[1,null,3]"),
        ("[1, 2]::INTEGER[2]", "INTEGER[2]", "[1,2]"),
        ("{'a': 1}", "STRUCT(a INTEGER)", r#"{"a":1}"#),
        ("union_value(a := 1)", "UNION(a INTEGER)", r#"{"a":1}"#),
    ] {
        let oracle = connection
            .query(&format!(
                "SELECT typeof(value), to_json(value)::VARCHAR FROM (SELECT {expression} AS value) source"
            ))
            .await
            .unwrap();
        assert_eq!(
            oracle.rows,
            vec![vec![
                Value::Text(expected_type.into()),
                Value::Text(expected_json.into()),
            ]],
            "native oracle for {expression}"
        );

        let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
        let value = &result.rows[0][0];
        assert!(matches!(value, Value::Undecodable(_)), "{expression}: {value:?}");
        assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
        assert!(
            connection
                .query_params("SELECT ?", std::slice::from_ref(value))
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn value_contract_scalar_hugeints_preserve_exact_text_across_consumers() {
    let connection = native_connection().await;
    for (kind, text) in [
        ("HUGEINT", "-170141183460469231731687303715884105728"),
        ("HUGEINT", "170141183460469231731687303715884105727"),
        ("UBIGINT", "9223372036854775808"),
        ("UBIGINT", "18446744073709551615"),
        ("UHUGEINT", "340282366920938463463374607431768211455"),
    ] {
        let result = connection
            .query(&format!(
                "SELECT value, typeof(value) AS native_type, value::VARCHAR AS exact_text \
                 FROM (SELECT CAST('{text}' AS {kind}) AS value) source"
            ))
            .await
            .unwrap();
        assert_eq!(
            result.rows,
            vec![vec![
                Value::Text(text.into()),
                Value::Text(kind.into()),
                Value::Text(text.into()),
            ]]
        );

        let value = Value::Text(text.into());
        let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", &value).unwrap();
        let literal_result = connection
            .query(&format!("SELECT {literal}::{kind}::VARCHAR"))
            .await
            .unwrap();
        assert_eq!(literal_result.rows, vec![vec![Value::Text(text.into())]]);
        let bound_result = connection
            .query_params(&format!("SELECT CAST(? AS {kind})::VARCHAR"), &[value])
            .await
            .unwrap();
        assert_eq!(bound_result.rows, vec![vec![Value::Text(text.into())]]);
    }
}

#[tokio::test]
async fn value_contract_interval_components_round_trip_as_exact_text() {
    let connection = native_connection().await;
    let result = connection
        .query(
            "WITH source AS (SELECT INTERVAL '1 month 2 days 3 microseconds' AS value) \
             SELECT value, typeof(value), value::VARCHAR, date_part('month', value)::INTEGER, \
                    date_part('day', value)::INTEGER, date_part('microsecond', value)::BIGINT \
             FROM source",
        )
        .await
        .unwrap();

    let value = &result.rows[0][0];
    assert_eq!(value, &Value::Text("1 month 2 days 3 microseconds".into()));
    assert_eq!(result.rows[0][1], Value::Text("INTERVAL".into()));
    assert_eq!(result.rows[0][2], Value::Text("1 month 2 days 00:00:00.000003".into()));
    assert_eq!(result.rows[0][3], Value::Int(1));
    assert_eq!(result.rows[0][4], Value::Int(2));
    assert_eq!(result.rows[0][5], Value::Int(3));

    let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", value).unwrap();
    let literal_round_trip = connection
        .query(&format!("SELECT CAST({literal} AS INTERVAL)"))
        .await
        .unwrap();
    assert_eq!(literal_round_trip.rows, vec![vec![value.clone()]]);

    let bound_round_trip = connection
        .query_params("SELECT CAST(? AS INTERVAL)", std::slice::from_ref(value))
        .await
        .unwrap();
    assert_eq!(bound_round_trip.rows, vec![vec![value.clone()]]);
}

#[tokio::test]
async fn value_contract_interval_all_component_signs_round_trip_as_exact_text() {
    let connection = native_connection().await;
    let cases = [
        (
            -1,
            -2,
            -3,
            "-1 month -2 days -3 microseconds",
            "-1 month -2 days -00:00:00.000003",
        ),
        (
            -1,
            -2,
            3,
            "-1 month -2 days 3 microseconds",
            "-1 month -2 days 00:00:00.000003",
        ),
        (
            -1,
            2,
            -3,
            "-1 month 2 days -3 microseconds",
            "-1 month 2 days -00:00:00.000003",
        ),
        (
            -1,
            2,
            3,
            "-1 month 2 days 3 microseconds",
            "-1 month 2 days 00:00:00.000003",
        ),
        (
            1,
            -2,
            -3,
            "1 month -2 days -3 microseconds",
            "1 month -2 days -00:00:00.000003",
        ),
        (
            1,
            -2,
            3,
            "1 month -2 days 3 microseconds",
            "1 month -2 days 00:00:00.000003",
        ),
        (
            1,
            2,
            -3,
            "1 month 2 days -3 microseconds",
            "1 month 2 days -00:00:00.000003",
        ),
        (
            1,
            2,
            3,
            "1 month 2 days 3 microseconds",
            "1 month 2 days 00:00:00.000003",
        ),
    ];

    for (months, days, micros, expected_text, expected_native_text) in cases {
        let source = connection
            .query(&format!(
                "SELECT value, typeof(value), value::VARCHAR, \
                        date_part('month', value)::INTEGER, date_part('day', value)::INTEGER, \
                        date_part('microsecond', value)::BIGINT \
                 FROM (SELECT to_months({months}) + to_days({days}) + to_microseconds({micros}) AS value)"
            ))
            .await
            .unwrap();
        assert_eq!(
            source.rows,
            vec![vec![
                Value::Text(expected_text.into()),
                Value::Text("INTERVAL".into()),
                Value::Text(expected_native_text.into()),
                Value::Int(months),
                Value::Int(days),
                Value::Int(micros),
            ]],
            "months={months}, days={days}, micros={micros}"
        );

        let value = &source.rows[0][0];
        let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", value).unwrap();
        let literal_round_trip = connection
            .query(&format!(
                "SELECT typeof(CAST({literal} AS INTERVAL)), CAST({literal} AS INTERVAL)"
            ))
            .await
            .unwrap();
        assert_eq!(
            literal_round_trip.rows,
            vec![vec![Value::Text("INTERVAL".into()), value.clone()]],
            "SQL literal lost a component sign for months={months}, days={days}, micros={micros}"
        );

        let bound_round_trip = connection
            .query_params(
                "SELECT typeof(CAST(? AS INTERVAL)), CAST(? AS INTERVAL)",
                &[value.clone(), value.clone()],
            )
            .await
            .unwrap();
        assert_eq!(
            bound_round_trip.rows,
            vec![vec![Value::Text("INTERVAL".into()), value.clone()]],
            "bound text lost a component sign for months={months}, days={days}, micros={micros}"
        );
    }
}

#[tokio::test]
async fn value_contract_interval_component_extremes_round_trip_as_exact_text() {
    let connection = native_connection().await;
    for (expression, expected, native_text, years, residual_months, days, residual_micros) in [
        (
            "to_months(-2147483648) + to_days(2147483647) + to_microseconds(9223372036854775)",
            "-2147483648 months 2147483647 days 9223372036854775 microseconds",
            "-178956970 years -8 months 2147483647 days 2562047:47:16.854775",
            -178_956_970,
            -8,
            i32::MAX as i64,
            16_854_775,
        ),
        (
            "to_months(2147483647) + to_days(-2147483648) + to_microseconds(-9223372036854775)",
            "2147483647 months -2147483648 days -9223372036854775 microseconds",
            "178956970 years 7 months -2147483648 days -2562047:47:16.854775",
            178_956_970,
            7,
            i32::MIN as i64,
            -16_854_775,
        ),
    ] {
        let source = connection
            .query(&format!(
                "SELECT value, typeof(value), value::VARCHAR, date_part('year', value)::INTEGER, \
                        date_part('month', value)::INTEGER, \
                        date_part('day', value)::INTEGER, date_part('microsecond', value)::BIGINT \
                 FROM (SELECT {expression} AS value)"
            ))
            .await
            .unwrap();
        assert_eq!(
            source.rows,
            vec![vec![
                Value::Text(expected.into()),
                Value::Text("INTERVAL".into()),
                Value::Text(native_text.into()),
                Value::Int(years),
                Value::Int(residual_months),
                Value::Int(days),
                Value::Int(residual_micros),
            ]]
        );

        let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", &source.rows[0][0]).unwrap();
        let literal_round_trip = connection
            .query(&format!(
                "SELECT typeof(CAST({literal} AS INTERVAL)), CAST({literal} AS INTERVAL)"
            ))
            .await
            .unwrap();
        assert_eq!(
            literal_round_trip.rows,
            vec![vec![Value::Text("INTERVAL".into()), source.rows[0][0].clone()]]
        );

        let bound_round_trip = connection
            .query_params(
                "SELECT typeof(CAST(? AS INTERVAL)), CAST(? AS INTERVAL)",
                &[source.rows[0][0].clone(), source.rows[0][0].clone()],
            )
            .await
            .unwrap();
        assert_eq!(
            bound_round_trip.rows,
            vec![vec![Value::Text("INTERVAL".into()), source.rows[0][0].clone()]]
        );
    }
}

#[tokio::test]
async fn value_contract_interval_grid_edit_persists_native_components() {
    let connection = native_connection().await;
    connection
        .execute("CREATE TABLE interval_grid (id INTEGER PRIMARY KEY, span INTERVAL)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO interval_grid VALUES (1, INTERVAL '1 month 2 days 3 microseconds')")
        .await
        .unwrap();

    let primary_key_oracle = connection
        .query(
            "SELECT constraint_type, constraint_column_names::VARCHAR \
             FROM duckdb_constraints() WHERE table_name = 'interval_grid' \
                 AND constraint_type = 'PRIMARY KEY'",
        )
        .await
        .unwrap();
    assert_eq!(
        primary_key_oracle.rows,
        vec![vec![Value::Text("PRIMARY KEY".into()), Value::Text("[id]".into())]]
    );

    let columns = connection.fetch_columns(None, "interval_grid").await.unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    assert!(
        columns[id_index].primary_key,
        "DuckDB must expose its primary key for keyed grid edits"
    );
    let span_index = columns.iter().position(|column| column.name == "span").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "interval_grid",
        &columns,
        &[(span_index, Value::Text("-2 months 4 days -5 microseconds".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update.0, &update.1).await.unwrap();

    let saved = connection
        .query(
            "SELECT typeof(span), span::VARCHAR, date_part('month', span)::INTEGER, \
                    date_part('day', span)::INTEGER, date_part('microsecond', span)::BIGINT \
             FROM interval_grid WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![vec![
            Value::Text("INTERVAL".into()),
            Value::Text("-2 months 4 days -00:00:00.000005".into()),
            Value::Int(-2),
            Value::Int(4),
            Value::Int(-5),
        ]]
    );
}

#[tokio::test]
async fn value_contract_native_temporal_nulls_and_json_preserve_precision() {
    let connection = native_connection().await;
    for kind in [
        "DATE",
        "TIME",
        "TIMESTAMP_S",
        "TIMESTAMP_MS",
        "TIMESTAMP",
        "TIMESTAMP_NS",
        "TIMESTAMPTZ",
        "INTERVAL",
        "INTEGER[]",
    ] {
        assert_eq!(
            connection.query(&format!("SELECT NULL::{kind}")).await.unwrap().rows,
            vec![vec![Value::Null]]
        );
    }
    let result = connection
        .query("SELECT TIMESTAMP_NS '1969-12-31 23:59:59.999999999' AS stamp, TIME '23:59:59.123456' AS clock")
        .await
        .unwrap();
    let json = tablepro_core::export::render_json(&result.columns, &result.rows);
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        parsed,
        serde_json::json!([{"stamp": "1969-12-31 23:59:59.999999999", "clock": "23:59:59.123456"}])
    );
}

#[tokio::test]
async fn value_contract_decimal_parameters_and_results_stay_exact_numbers() {
    let connection = native_connection().await;
    let decimal = |text: &str| Value::Decimal(text.parse().unwrap());
    for (sql, parameter, expected) in [
        ("SELECT ? * 2", "2.5", "5.0"),
        ("SELECT ? + 1", "1000", "1001"),
        ("SELECT ?", "-0.00000001", "-0.00000001"),
        (
            "SELECT ?",
            "-99999999999999999999.99999999",
            "-99999999999999999999.99999999",
        ),
    ] {
        let result = connection.query_params(sql, &[decimal(parameter)]).await.unwrap();
        assert_eq!(result.rows, vec![vec![decimal(expected)]], "{sql} with {parameter}");
    }
    let result = connection
        .query("SELECT 12.340::DECIMAL(10,3), CAST('-1234567890123456789012345678.0123456789' AS DECIMAL(38,10))")
        .await
        .unwrap();
    assert!(matches!(&result.rows[0][0], Value::Decimal(value) if value.to_string() == "12.340"));
    assert_eq!(
        result.rows[0][1],
        Value::Text("-1234567890123456789012345678.0123456789".into())
    );
}

fn naive(text: &str) -> chrono::NaiveDateTime {
    chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f").unwrap()
}

fn bound_temporal_corpus() -> Vec<(Value, &'static str)> {
    let date = |text: &str| Value::Date(text.parse().unwrap());
    let time = |text: &str| Value::Time(text.parse().unwrap());
    vec![
        (date("2000-02-29"), "DATE '2000-02-29'"),
        (date("1969-12-31"), "DATE '1969-12-31'"),
        (date("0001-01-01"), "DATE '0001-01-01'"),
        (date("9999-12-31"), "DATE '9999-12-31'"),
        (time("23:59:59.123456"), "TIME '23:59:59.123456'"),
        (time("00:00:00"), "TIME '00:00:00'"),
        (
            Value::DateTime(naive("1969-12-31 23:59:59.999999")),
            "TIMESTAMP '1969-12-31 23:59:59.999999'",
        ),
        (
            Value::DateTime(naive("0001-01-01 00:00:00")),
            "TIMESTAMP '0001-01-01 00:00:00'",
        ),
        (
            Value::DateTime(naive("9999-12-31 23:59:59.999999")),
            "TIMESTAMP '9999-12-31 23:59:59.999999'",
        ),
    ]
}

#[tokio::test]
async fn value_contract_bound_temporals_are_typed_in_expressions() {
    let connection = native_connection().await;
    for (value, literal) in bound_temporal_corpus() {
        let expressions: &[&str] = match &value {
            Value::Date(_) => &["? + 1", "? + INTERVAL 1 DAY", "year(?)", "date_trunc('month', ?)"],
            Value::Time(_) => &["? + INTERVAL 1 SECOND", "hour(?)"],
            _ => &["? + INTERVAL 1 DAY", "year(?)", "date_trunc('month', ?)", "epoch_us(?)"],
        };
        for expression in expressions {
            let bound = connection
                .query_params(&format!("SELECT {expression}"), std::slice::from_ref(&value))
                .await
                .unwrap_or_else(|error| panic!("{expression} with {value:?}: {error}"));
            let inline = connection
                .query(&format!("SELECT {}", expression.replace('?', literal)))
                .await
                .unwrap();
            assert_eq!(bound.rows, inline.rows, "{expression} with {value:?}");
        }
        let echoed = connection
            .query_params("SELECT ?", std::slice::from_ref(&value))
            .await
            .unwrap();
        assert_eq!(echoed.rows, vec![vec![value.clone()]], "SELECT ? with {literal}");
    }
}

#[tokio::test]
async fn value_contract_bound_temporals_insert_and_read_back_exactly() {
    let connection = native_connection().await;
    connection.execute("SET TimeZone = 'Asia/Tokyo'").await.unwrap();
    connection
        .execute("CREATE TABLE stamps (id INTEGER, d DATE, t TIME, ts TIMESTAMP, ns TIMESTAMP_NS, tz TIMESTAMPTZ)")
        .await
        .unwrap();
    let rows = [
        (
            "1969-12-31",
            "23:59:59.999999",
            "1969-12-31 23:59:59.999999",
            "1969-12-31 23:59:59.999999999",
        ),
        (
            "0001-01-01",
            "00:00:00.000001",
            "0001-01-01 00:00:00.000001",
            "1677-09-22 00:00:00.000000001",
        ),
        (
            "9999-12-31",
            "12:00:00",
            "9999-12-31 23:59:59.999999",
            "2262-04-10 23:59:59.999999999",
        ),
        (
            "2026-09-27",
            "12:34:56.5",
            "2026-09-27 12:34:56.123456",
            "2026-09-27 12:34:56.123456",
        ),
    ];
    for (id, (date, time, stamp, nanos)) in rows.iter().enumerate() {
        let values = vec![
            Value::Int(id as i64),
            Value::Date(date.parse().unwrap()),
            Value::Time(time.parse().unwrap()),
            Value::DateTime(naive(stamp)),
            Value::DateTime(naive(nanos)),
            Value::TimestampTz(naive(stamp).and_utc()),
        ];
        connection
            .execute_params("INSERT INTO stamps VALUES (?, ?, ?, ?, ?, ?)", &values)
            .await
            .unwrap();
        let read = connection
            .query_params("SELECT * FROM stamps WHERE id = ?", &[Value::Int(id as i64)])
            .await
            .unwrap();
        assert_eq!(read.rows, vec![values], "row {id}");
    }
    connection
        .execute_params(
            "INSERT INTO stamps (id, d) VALUES (?, ?)",
            &[
                Value::Int(9),
                Value::Date(chrono::NaiveDate::from_ymd_opt(0, 1, 1).unwrap()),
            ],
        )
        .await
        .unwrap();
    assert_eq!(
        connection
            .query("SELECT d FROM stamps WHERE id = 9")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("0001-01-01 (BC)".into())]]
    );
}

#[tokio::test]
async fn value_contract_bound_timestamptz_keeps_its_instant_in_any_session_zone() {
    let connection = native_connection().await;
    for zone in ["UTC", "Asia/Tokyo", "America/Los_Angeles"] {
        connection.execute(&format!("SET TimeZone = '{zone}'")).await.unwrap();
        for (text, literal) in [
            (
                "2026-09-27T12:34:56.123456+05:30",
                "TIMESTAMPTZ '2026-09-27 12:34:56.123456+05:30'",
            ),
            (
                "1969-12-31T23:59:59.999999Z",
                "TIMESTAMPTZ '1969-12-31 23:59:59.999999+00'",
            ),
        ] {
            let value = Value::TimestampTz(chrono::DateTime::parse_from_rfc3339(text).unwrap().to_utc());
            let bound = connection
                .query_params(
                    &format!("SELECT CAST(? AS TIMESTAMPTZ) = {literal}, epoch_us(CAST(? AS TIMESTAMPTZ))"),
                    &[value.clone(), value.clone()],
                )
                .await
                .unwrap();
            let inline = connection
                .query(&format!("SELECT true, epoch_us({literal})"))
                .await
                .unwrap();
            assert_eq!(bound.rows, inline.rows, "{zone}: {text}");
        }
    }
}

#[tokio::test]
async fn value_contract_temporal_filter_parameters_keep_duckdb_column_precision_end_to_end() {
    use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where};

    let connection = native_connection().await;
    connection
        .execute("CREATE TABLE filter_ms (value TIMESTAMP_MS); INSERT INTO filter_ms VALUES (TIMESTAMP_MS '2026-09-30 12:34:56.123'), (TIMESTAMP_MS '2026-09-30 12:34:56.124')")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "filter_ms").await.unwrap();
    assert_eq!(columns[0].data_type.to_ascii_lowercase(), "timestamp_ms");

    let lossy = FilterSet {
        rules: vec![FilterRule {
            column: "value".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("2026-09-30 12:34:56.123000001".into())),
        }],
        ..Default::default()
    };
    assert!(build_filter_where("duckdb", &columns, &lossy).is_err());

    let exact = FilterSet {
        rules: vec![FilterRule {
            column: "value".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("2026-09-30 12:34:56.123000000".into())),
        }],
        ..Default::default()
    };
    let (predicate, params) = build_filter_where("duckdb", &columns, &exact).unwrap().unwrap();
    let result = connection
        .query_params(
            &format!("SELECT typeof(value), CAST(value AS VARCHAR) FROM filter_ms WHERE {predicate}"),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("TIMESTAMP_MS".into()),
            Value::Text("2026-09-30 12:34:56.123".into())
        ]]
    );

    connection
        .execute("CREATE TABLE filter_ns (value TIMESTAMP_NS); INSERT INTO filter_ns VALUES (TIMESTAMP_NS '2026-09-30 12:34:56.123456789')")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "filter_ns").await.unwrap();
    assert_eq!(columns[0].data_type.to_ascii_lowercase(), "timestamp_ns");
    let exact = FilterSet {
        rules: vec![FilterRule {
            column: "value".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("2026-09-30 12:34:56.123456789".into())),
        }],
        ..Default::default()
    };
    let (predicate, params) = build_filter_where("duckdb", &columns, &exact).unwrap().unwrap();
    let result = connection
        .query_params(
            &format!("SELECT typeof(value), CAST(value AS VARCHAR) FROM filter_ns WHERE {predicate}"),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("TIMESTAMP_NS".into()),
            Value::Text("2026-09-30 12:34:56.123456789".into())
        ]]
    );
}

#[tokio::test]
async fn value_contract_time_ns_filter_uses_exact_text_fallback() {
    use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where};

    let connection = native_connection().await;
    connection
        .execute("CREATE TABLE filter_time_ns (value TIME_NS); INSERT INTO filter_time_ns VALUES (TIME_NS '12:34:56.123456789')")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "filter_time_ns").await.unwrap();
    assert_eq!(columns[0].data_type.to_ascii_lowercase(), "time_ns");
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "value".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("12:34:56.123456789".into())),
        }],
        ..Default::default()
    };
    let (predicate, params) = build_filter_where("duckdb", &columns, &filter).unwrap().unwrap();
    let result = connection
        .query_params(
            &format!("SELECT typeof(value), CAST(value AS VARCHAR) FROM filter_time_ns WHERE {predicate}"),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("TIME_NS".into()),
            Value::Text("12:34:56.123456789".into())
        ]]
    );
}

#[tokio::test]
async fn value_contract_timestamptz_filter_preserves_offset_origin_instant() {
    use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where};

    let connection = native_connection().await;
    connection
        .execute("CREATE TABLE filter_tz (value TIMESTAMPTZ); INSERT INTO filter_tz VALUES (TIMESTAMPTZ '2026-09-30 12:34:56.123456+05:30')")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "filter_tz").await.unwrap();
    assert_eq!(columns[0].data_type.to_ascii_lowercase(), "timestamp with time zone");

    let lossy = FilterSet {
        rules: vec![FilterRule {
            column: "value".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("2026-09-30T12:34:56.123456789+05:30".into())),
        }],
        ..Default::default()
    };
    assert!(build_filter_where("duckdb", &columns, &lossy).is_err());

    let exact = FilterSet {
        rules: vec![FilterRule {
            column: "value".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("2026-09-30T12:34:56.123456000+05:30".into())),
        }],
        ..Default::default()
    };
    let (predicate, params) = build_filter_where("duckdb", &columns, &exact).unwrap().unwrap();
    let result = connection
        .query_params(
            &format!("SELECT typeof(value), epoch_us(value) FROM filter_tz WHERE {predicate}"),
            &params,
        )
        .await
        .unwrap();
    let expected_epoch = chrono::DateTime::parse_from_rfc3339("2026-09-30T12:34:56.123456+05:30")
        .unwrap()
        .timestamp_micros();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("TIMESTAMP WITH TIME ZONE".into()),
            Value::Int(expected_epoch)
        ]]
    );
}
