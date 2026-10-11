use super::*;

#[tokio::test]
async fn open_session_is_refused() {
    let conn = ClickhouseConnection {
        client: clickhouse::Client::default(),
        database: "default".into(),
    };
    assert!(matches!(conn.open_session().await, Err(DriverError::Unsupported(_))));
}

#[test]
fn decimal_preservation_never_passes_through_float_or_rounds() {
    for text in [
        "12345678901234567890.12345678",
        "0.123456789012345678901234567891",
        "1234567890123456789012345678901234567890.123456789",
    ] {
        for raw in [
            serde_json::from_str(text).unwrap(),
            serde_json::Value::String(text.into()),
        ] {
            let value = json_to_value(raw, "Decimal256(30)");
            let actual = match value {
                Value::Decimal(value) => value.to_string(),
                Value::Text(value) => value,
                other => panic!("unexpected value: {other:?}"),
            };
            assert_eq!(actual, text);
        }
    }
}

#[test]
fn clickhouse_response_rejects_column_type_count_mismatch() {
    let result = response_columns(vec!["a".into(), "b".into()], vec!["UInt8".into()]);
    assert!(matches!(result, Err(DriverError::Internal(_))));
}

#[test]
fn clickhouse_response_rejects_row_width_mismatch_instead_of_inventing_nulls() {
    let columns = response_columns(vec!["a".into(), "b".into()], vec!["UInt8".into(), "UInt8".into()]).unwrap();
    for raw in [
        vec![serde_json::json!(1)],
        vec![serde_json::json!(1), serde_json::json!(2), serde_json::json!(3)],
    ] {
        let result = response_row(raw, &columns);
        assert!(matches!(result, Err(DriverError::Internal(_))));
    }
}

#[test]
fn clickhouse_terminal_exception_row_is_an_error_not_partial_success() {
    let exception = serde_json::json!(
        "Code: 394. DB::Exception: Query was cancelled. (QUERY_WAS_CANCELLED) (version 24.8.14.39 (official build))"
    );
    assert_eq!(
        exception_row_message(std::slice::from_ref(&exception)),
        exception.as_str()
    );
    assert_eq!(
        exception_row_message(&[serde_json::json!("Code: this is ordinary user data")]),
        None
    );
    assert_eq!(exception_row_message(&[serde_json::json!("Code: 394")]), None);
    for malformed in [
        "Code: invalid. DB::Exception: Query was cancelled. (version 24.8.14.39 (official build))",
        "Code: 394. SomeException: Query was cancelled. (version 24.8.14.39 (official build))",
        "Code: 394. DB::Failure: Query was cancelled. (version 24.8.14.39 (official build))",
        "Code: 394. DB::Exception: Query was cancelled. (24.8.14.39 (official build))",
        "Code: 394. DB::Exception: Query was cancelled. (version 24.8.14.39 (official build)",
    ] {
        assert_eq!(
            exception_row_message(&[serde_json::json!(malformed)]),
            None,
            "{malformed}"
        );
    }
}

#[test]
fn clickhouse_response_preserves_explicit_null_cells() {
    let columns = response_columns(
        vec!["a".into(), "b".into()],
        vec!["Nullable(UInt8)".into(), "UInt8".into()],
    )
    .unwrap();
    assert_eq!(
        response_row(vec![serde_json::Value::Null, serde_json::json!(7)], &columns).unwrap(),
        vec![Value::Null, Value::Int(7)]
    );
}

#[test]
fn the_sorting_key_is_declared_but_foreign_keys_are_not() {
    let d = ClickhouseDriver;
    let source = include_str!("lib.rs");
    assert!(d.supports_index_metadata());
    assert!(source.contains(&["async fn ", "fetch_indexes("].concat()));
    assert!(!d.supports_foreign_key_metadata());
}

#[test]
fn driver_metadata() {
    let d = ClickhouseDriver;
    assert_eq!(d.id(), "clickhouse");
    assert_eq!(d.display_name(), "ClickHouse");
    assert_eq!(d.default_port(), 8123);
    assert_eq!(d.default_database(), "default");
    assert_eq!(d.default_username(), "default");
    assert_ne!(
        (d.default_port(), d.default_database(), d.default_username()),
        (5432, "postgres", "postgres")
    );
    assert!(!d.reports_rows_affected());
}

#[test]
fn qualify_escapes_backticks() {
    assert_eq!(qualify("db", "users"), "`db`.`users`");
    assert_eq!(qualify("db", "a`b"), "`db`.`a``b`");
}

#[test]
fn datetime64_parameter_values_outside_the_nine_digit_range_are_refused() {
    let below = chrono::NaiveDate::from_ymd_opt(1899, 12, 31)
        .unwrap()
        .and_hms_nano_opt(23, 59, 59, 999_999_999)
        .unwrap();
    let above = chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
        .unwrap()
        .and_hms_nano_opt(23, 47, 16, 854_775_808)
        .unwrap();
    assert!(matches!(
        literal(&Value::DateTime(below)),
        Err(DriverError::Unsupported(_))
    ));
    assert!(matches!(
        literal(&Value::TimestampTz(above.and_utc())),
        Err(DriverError::Unsupported(_))
    ));
}

#[test]
fn datetime64_nine_digit_range_edges_remain_representable() {
    let lower = chrono::NaiveDate::from_ymd_opt(1900, 1, 1)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap();
    let upper = chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
        .unwrap()
        .and_hms_nano_opt(23, 47, 16, 854_775_807)
        .unwrap();
    assert!(literal(&Value::DateTime(lower)).is_ok());
    assert!(literal(&Value::TimestampTz(upper.and_utc())).is_ok());
}

#[test]
fn datetime64_parameters_use_a_wider_exact_scale_when_subseconds_are_zero() {
    let stamp = chrono::NaiveDate::from_ymd_opt(2299, 12, 31)
        .unwrap()
        .and_hms_opt(23, 59, 59)
        .unwrap();
    assert_eq!(
        literal(&Value::DateTime(stamp)).unwrap(),
        "toDateTime64('2299-12-31 23:59:59', 0)"
    );
}

#[test]
fn base_type_strips_arguments_and_wrappers() {
    assert_eq!(base_type("String"), "String");
    assert_eq!(base_type("Decimal(9, 2)"), "Decimal");
    assert_eq!(base_type("DateTime64(3, 'UTC')"), "DateTime64");
    assert_eq!(base_type("FixedString(16)"), "FixedString");
    assert_eq!(base_type("Nullable(Decimal(18, 4))"), "Decimal");
    assert_eq!(base_type("LowCardinality(Nullable(String))"), "String");
    assert_eq!(base_type("Array(Nullable(String))"), "Array");
    assert_eq!(base_type("Map(String, UInt64)"), "Map");
}

#[test]
fn nullability_survives_low_cardinality() {
    assert!(!type_is_nullable("String"));
    assert!(type_is_nullable("Nullable(String)"));
    assert!(type_is_nullable("LowCardinality(Nullable(String))"));
    assert!(!type_is_nullable("LowCardinality(String)"));
    // The inner Nullable belongs to the element, not the column.
    assert!(!type_is_nullable("Array(Nullable(String))"));
}

#[test]
fn parameterised_types_decode_to_typed_values() {
    assert_eq!(
        json_to_value(serde_json::json!("12.34"), "Decimal(9, 2)"),
        Value::Decimal("12.34".parse().unwrap())
    );
    assert_eq!(
        json_to_value(serde_json::json!("2024-06-15 08:30:00.123"), "DateTime64(3)"),
        Value::DateTime(
            chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
                .unwrap()
                .and_hms_milli_opt(8, 30, 0, 123)
                .unwrap()
        )
    );
    assert_eq!(
        json_to_value(serde_json::json!("abc"), "LowCardinality(Nullable(String))"),
        Value::Text("abc".into())
    );
    assert_eq!(
        json_to_value(serde_json::json!("2024-06-15 08:30:00"), "DateTime"),
        Value::DateTime(
            chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
                .unwrap()
                .and_hms_opt(8, 30, 0)
                .unwrap()
        )
    );
}

#[test]
fn json_to_value_maps_common_types() {
    assert_eq!(json_to_value(serde_json::json!(true), "Bool"), Value::Bool(true));
    assert_eq!(json_to_value(serde_json::json!(1), "Bool"), Value::Bool(true));
    assert_eq!(json_to_value(serde_json::json!(0), "Bool"), Value::Bool(false));
    assert_eq!(json_to_value(serde_json::json!(42), "Int64"), Value::Int(42));
    assert_eq!(json_to_value(serde_json::json!(1.25), "Float32"), Value::Float(1.25));
    assert_eq!(json_to_value(serde_json::json!("-2.5"), "Float64"), Value::Float(-2.5));
    assert_eq!(
        json_to_value(serde_json::json!("hello"), "String"),
        Value::Text("hello".into())
    );
    let uuid = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
    assert_eq!(
        json_to_value(serde_json::json!(uuid.to_string()), "UUID"),
        Value::Uuid(uuid)
    );
    assert_eq!(json_to_value(serde_json::Value::Null, "Nullable(String)"), Value::Null);
    assert_eq!(
        json_to_value(serde_json::json!("2024-06-15"), "Date"),
        Value::Date(chrono::NaiveDate::from_ymd_opt(2024, 6, 15).unwrap())
    );
    assert_eq!(
        json_to_value(serde_json::json!([1, 2]), "Array(UInt8)"),
        Value::Json(serde_json::json!([1, 2]))
    );
}

#[test]
fn clickhouse_enum_values_decode_as_exact_labels_and_keep_sql_null_distinct() {
    let enum16 = "Nullable(Enum16('NULL' = 0, 'high' = 32767))";
    assert_eq!(
        json_to_value(serde_json::json!("NULL"), enum16),
        Value::Text("NULL".into())
    );
    assert_eq!(
        json_to_value(serde_json::json!("high"), enum16),
        Value::Text("high".into())
    );
    assert_eq!(json_to_value(serde_json::Value::Null, enum16), Value::Null);
}

#[test]
fn clickhouse_json_row_preserves_wide_integer_tokens_exactly() {
    let raw: Vec<serde_json::Value> = query::parse_line(
            br#"[-170141183460469231731687303715884105728,170141183460469231731687303715884105727,340282366920938463463374607431768211455]"#,
        )
        .unwrap();
    let columns = response_columns(
        ["signed_min", "signed_max", "unsigned_max"].map(str::to_owned).into(),
        ["Int128", "Int128", "UInt128"].map(str::to_owned).into(),
    )
    .unwrap();

    assert_eq!(
        response_row(raw, &columns).unwrap(),
        [
            Value::Text("-170141183460469231731687303715884105728".into()),
            Value::Text("170141183460469231731687303715884105727".into()),
            Value::Text("340282366920938463463374607431768211455".into()),
        ]
    );
}

#[test]
fn bind_question_marks() {
    let sql = bind_placeholders(
        "ALTER TABLE t UPDATE a = ? WHERE id = ?",
        &[Value::Text("x".into()), Value::Int(1)],
    )
    .unwrap();
    assert_eq!(sql, "ALTER TABLE t UPDATE a = 'x' WHERE id = 1");
}

#[test]
fn bind_dollar_placeholders() {
    let sql = bind_placeholders(
        "ALTER TABLE t UPDATE a = $1 WHERE id = $2",
        &[Value::Text("x".into()), Value::Int(1)],
    )
    .unwrap();
    assert_eq!(sql, "ALTER TABLE t UPDATE a = 'x' WHERE id = 1");
}

#[test]
fn placeholders_inside_literals_are_left_alone() {
    let sql = bind_placeholders("SELECT * FROM t WHERE note = 'what? $1' AND id = ?", &[Value::Int(7)]).unwrap();
    assert_eq!(sql, "SELECT * FROM t WHERE note = 'what? $1' AND id = 7");
}

#[test]
fn placeholders_inside_comments_and_identifiers_are_left_alone() {
    let sql = bind_placeholders(
        "SELECT `we?rd`, /* $1 ? */ x -- ?\n FROM t WHERE id = ?",
        &[Value::Int(3)],
    )
    .unwrap();
    assert_eq!(sql, "SELECT `we?rd`, /* $1 ? */ x -- ?\n FROM t WHERE id = 3");
}

#[test]
fn escaped_quote_does_not_end_a_literal() {
    let sql = bind_placeholders("SELECT * FROM t WHERE a = 'it''s ?' AND b = ?", &[Value::Int(1)]).unwrap();
    assert_eq!(sql, "SELECT * FROM t WHERE a = 'it''s ?' AND b = 1");

    let sql = bind_placeholders("SELECT * FROM t WHERE a = 'it\\'s ?' AND b = ?", &[Value::Int(1)]).unwrap();
    assert_eq!(sql, "SELECT * FROM t WHERE a = 'it\\'s ?' AND b = 1");
}

#[test]
fn unreferenced_parameter_is_an_error() {
    let err = bind_placeholders("SELECT * FROM t WHERE id = ?", &[Value::Int(1), Value::Int(2)]).unwrap_err();
    assert!(matches!(err, DriverError::Internal(_)));
}

#[test]
fn missing_parameter_is_an_error() {
    let err = bind_placeholders("SELECT * FROM t WHERE a = ? AND b = ?", &[Value::Int(1)]).unwrap_err();
    assert!(matches!(err, DriverError::Internal(_)));

    let err = bind_placeholders("SELECT * FROM t WHERE a = $3", &[Value::Int(1)]).unwrap_err();
    assert!(matches!(err, DriverError::Internal(_)));
}

#[test]
fn text_literals_escape_quotes_and_backslashes() {
    assert_eq!(literal(&Value::Text("it's \\ ok".into())).unwrap(), "'it\\'s \\\\ ok'");
    assert_eq!(
        literal(&Value::Bytes(vec![0x00, 0xff, 0x0a])).unwrap(),
        "unhex('00ff0a')"
    );
}

#[test]
fn non_finite_floats_use_clickhouse_spellings() {
    assert_eq!(literal(&Value::Float(f64::NAN)).unwrap(), "nan");
    assert_eq!(literal(&Value::Float(f64::INFINITY)).unwrap(), "inf");
    assert_eq!(literal(&Value::Float(f64::NEG_INFINITY)).unwrap(), "-inf");
}

#[test]
fn decimal_literals_keep_their_scale() {
    assert_eq!(
        literal(&Value::Decimal("12.3400".parse().unwrap())).unwrap(),
        "toDecimal128('12.3400', 4)"
    );
}

#[test]
fn question_marks_are_escaped_for_the_client_template() {
    assert_eq!(
        escape_bind_markers("SELECT * FROM t WHERE note = 'what?'"),
        "SELECT * FROM t WHERE note = 'what??'"
    );
    // `?fields` is the crate's other marker; escaping covers it too.
    assert_eq!(escape_bind_markers("SELECT ?fields FROM t"), "SELECT ??fields FROM t");
    assert_eq!(escape_bind_markers("SELECT 1"), "SELECT 1");
}

#[test]
fn key_expression_splits_at_top_level_only() {
    assert_eq!(split_key_expression("id"), vec!["id"]);
    assert_eq!(split_key_expression("`a`, `b`"), vec!["a", "b"]);
    assert_eq!(split_key_expression("toYYYYMM(d), id"), vec!["toYYYYMM(d)", "id"]);
    assert!(split_key_expression("").is_empty());
}

#[test]
fn map_error_classifies_auth() {
    let err = map_clickhouse_error(clickhouse::error::Error::BadResponse(
        "Code: 516. Authentication failed: password is incorrect".into(),
    ));
    assert!(matches!(err, DriverError::AuthFailed));
}

#[test]
fn server_error_mentioning_certificate_stays_a_query_error() {
    let err = map_clickhouse_error(clickhouse::error::Error::BadResponse(
        "Code: 47. Unknown identifier: certificate".into(),
    ));
    assert!(matches!(err, DriverError::Query { .. }));
}

#[test]
fn nested_certificate_name_mismatch_is_tls() {
    let err = clickhouse::error::Error::Network(Box::new(std::io::Error::other(
        "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
    )));
    let mapped = map_clickhouse_error(err);
    assert!(matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate")));
}

#[test]
fn connect_error_text_during_connect_is_connection_refused() {
    for message in ["connection refused", "connect error: network unreachable"] {
        let err = clickhouse::error::Error::Network(Box::new(std::io::Error::other(message)));
        assert!(
            matches!(map_clickhouse_connect_error(err, false), DriverError::ConnectionRefused),
            "connect failure {message:?} must remain distinct from established disconnects"
        );
    }
}

#[test]
fn connection_refusal_during_an_operation_is_disconnected() {
    let err = clickhouse::error::Error::Network(Box::new(std::io::Error::from(std::io::ErrorKind::ConnectionRefused)));
    assert!(matches!(map_clickhouse_error(err), DriverError::Disconnected));
}

#[test]
fn verifying_connect_does_not_report_a_hostname_mismatch_as_a_drop() {
    let err = clickhouse::error::Error::Network(Box::new(std::io::Error::other("connection closed unexpectedly")));
    assert!(matches!(map_clickhouse_error(err), DriverError::Disconnected));
    let err = clickhouse::error::Error::Network(Box::new(std::io::Error::other("connection closed unexpectedly")));
    let mapped = map_clickhouse_connect_error(err, true);
    assert!(
        matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate") && detail.contains("hostname"))
    );
}

#[test]
fn a_verifying_connect_timeout_stays_disconnected_instead_of_a_fabricated_tls_mismatch() {
    let err = clickhouse::error::Error::TimedOut;
    let mapped = map_clickhouse_connect_error(err, true);
    assert!(matches!(mapped, DriverError::Disconnected));
}
