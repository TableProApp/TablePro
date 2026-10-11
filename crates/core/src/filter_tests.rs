use super::*;

#[test]
fn value_contract_parser_preserves_boundaries_and_rejects_rounding() {
    let parse = |data_type: &'static str| move |text: &str| parse_value_for(&col("value", data_type), text).ok();
    crate::parser_contract::assert_numeric_parsers(parse("bigint"), parse("numeric"), parse("double precision"));
}

#[test]
fn decimal_preservation_rejects_a_filter_that_would_round() {
    assert!(parse_value_for(&col("amount", "numeric"), "0.123456789012345678901234567891").is_err());
}

#[test]
fn duckdb_temporal_filters_refuse_values_the_column_would_truncate() {
    let unrepresentable = [
        ("TIME", "12:34:56.123456789"),
        ("TIMESTAMP", "2026-09-30 12:34:56.123456789"),
        ("TIMESTAMP_S", "2026-09-30 12:34:56.123456789"),
        ("TIMESTAMP_MS", "2026-09-30 12:34:56.123456789"),
        ("TIMESTAMP WITH TIME ZONE", "2026-09-30T12:34:56.123456789Z"),
    ];
    for (data_type, text) in unrepresentable {
        let set = FilterSet {
            rules: vec![rule("value", FilterOp::Eq, Some(FilterValue::Single(text.into())))],
            ..Default::default()
        };
        let error = build_filter_where("duckdb", &[col("value", data_type)], &set)
            .expect_err("a filter must not silently coerce a sub-precision temporal value");
        assert!(error.to_string().contains("precision"), "{data_type}: {error}");
    }

    for (op, value) in [
        (
            FilterOp::Between,
            FilterValue::Pair("12:34:56.123456789".into(), "12:34:57".into()),
        ),
        (
            FilterOp::In,
            FilterValue::List(vec!["12:34:56".into(), "12:34:56.123456789".into()]),
        ),
    ] {
        let set = FilterSet {
            rules: vec![rule("value", op, Some(value))],
            ..Default::default()
        };
        assert!(build_filter_where("duckdb", &[col("value", "TIME")], &set).is_err());
    }

    let aligned = FilterSet {
        rules: vec![rule(
            "value",
            FilterOp::Eq,
            Some(FilterValue::Single("2026-09-30 12:34:56.123000000".into())),
        )],
        ..Default::default()
    };
    let (_, params) = build_filter_where("duckdb", &[col("value", "TIMESTAMP_MS")], &aligned)
        .expect("an exact millisecond filter builds")
        .unwrap();
    assert_eq!(
        params,
        vec![Value::DateTime(
            NaiveDate::from_ymd_opt(2026, 9, 30)
                .unwrap()
                .and_hms_nano_opt(12, 34, 56, 123_000_000)
                .unwrap()
        )]
    );

    let time_ns = FilterSet {
        rules: vec![rule(
            "value",
            FilterOp::Eq,
            Some(FilterValue::Single("12:34:56.123456789".into())),
        )],
        ..Default::default()
    };
    let (_, params) = build_filter_where("duckdb", &[col("value", "TIME_NS")], &time_ns)
        .expect("nanosecond TIME_NS filter preserves its full input")
        .unwrap();
    assert_eq!(params, vec![Value::Text("12:34:56.123456789".into())]);

    let timestamp_ns = FilterSet {
        rules: vec![rule(
            "value",
            FilterOp::Eq,
            Some(FilterValue::Single("2026-09-30 12:34:56.123456789".into())),
        )],
        ..Default::default()
    };
    let (_, params) = build_filter_where("duckdb", &[col("value", "TIMESTAMP_NS")], &timestamp_ns)
        .expect("nanosecond TIMESTAMP_NS filter preserves its full input")
        .unwrap();
    assert_eq!(
        params,
        vec![Value::DateTime(
            NaiveDate::from_ymd_opt(2026, 9, 30)
                .unwrap()
                .and_hms_nano_opt(12, 34, 56, 123_456_789)
                .unwrap()
        )]
    );
}

#[test]
fn an_equality_rule_parses_back_to_the_value_it_was_built_from() {
    let cases = [
        ("boolean", Value::Bool(true)),
        ("bigint", Value::Int(-9_007_199_254_740_993)),
        ("double precision", Value::Float(0.1)),
        ("numeric", Value::Decimal("12.3400".parse().unwrap())),
        ("text", Value::Text(" padded 'quoted' ".into())),
        ("date", Value::Date(NaiveDate::from_ymd_opt(2026, 9, 25).unwrap())),
        (
            "time",
            Value::Time(NaiveTime::from_hms_milli_opt(7, 8, 9, 250).unwrap()),
        ),
        (
            "timestamp",
            Value::DateTime(
                NaiveDate::from_ymd_opt(2026, 9, 25)
                    .unwrap()
                    .and_hms_micro_opt(1, 2, 3, 4)
                    .unwrap(),
            ),
        ),
        (
            "timestamptz",
            Value::TimestampTz(DateTime::from_timestamp(1_790_000_000, 5_000).unwrap()),
        ),
        ("uuid", Value::Uuid(Uuid::from_u128(7))),
    ];
    for (data_type, value) in cases {
        let rule = equality_rule("c", &value).unwrap();
        let Some(FilterValue::Single(text)) = &rule.value else {
            panic!("{data_type}: {rule:?}");
        };
        assert_eq!(
            parse_value_for(&col("c", data_type), text).unwrap(),
            value,
            "{data_type}"
        );
    }
}

#[test]
fn a_null_cell_filters_with_is_null_and_unfilterable_cells_offer_nothing() {
    assert_eq!(equality_rule("c", &Value::Null).unwrap().op, FilterOp::IsNull);
    assert!(equality_rule("c", &Value::Json(serde_json::json!({"a": 1}))).is_none());
    assert!(equality_rule("c", &Value::Bytes(vec![1])).is_none());
    assert!(equality_rule("c", &Value::Undecodable("xml".into())).is_none());
}

#[test]
fn narrowing_replaces_the_column_rule_and_keeps_the_others() {
    let mut set = FilterSet::default();
    set = set.narrowed_to(equality_rule("a", &Value::Int(1)).unwrap());
    set = set.narrowed_to(equality_rule("b", &Value::Int(2)).unwrap());
    set = set.narrowed_to(equality_rule("a", &Value::Int(3)).unwrap());

    let columns: Vec<&str> = set.rules.iter().map(|rule| rule.column.as_str()).collect();
    assert_eq!(columns, vec!["b", "a"]);
    assert_eq!(set.rules[1].value, Some(FilterValue::Single("3".into())));

    let or_set = FilterSet {
        combinator: Combinator::Or,
        rules: set.rules.clone(),
        extra_sql: Some("x > 1".into()),
    };
    let narrowed = or_set.narrowed_to(equality_rule("c", &Value::Null).unwrap());
    assert_eq!(narrowed.rules.len(), 1);
    assert_eq!(narrowed.combinator, Combinator::And);
    assert!(narrowed.extra_sql.is_none());
}

fn col(name: &str, data_type: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn rule(column: &str, op: FilterOp, value: Option<FilterValue>) -> FilterRule {
    FilterRule {
        column: column.into(),
        op,
        value,
    }
}

#[test]
fn postgres_pattern_search_casts_values_but_typed_comparisons_do_not() {
    for data_type in [
        "uuid",
        "mood",
        "integer",
        "numeric",
        "date",
        "json",
        "jsonb",
        "integer[]",
    ] {
        let columns = vec![col("value", data_type)];
        for op in [
            FilterOp::Contains,
            FilterOp::StartsWith,
            FilterOp::EndsWith,
            FilterOp::Like,
            FilterOp::NotLike,
            FilterOp::Ilike,
        ] {
            let set = FilterSet {
                rules: vec![rule("value", op, Some(FilterValue::Single("12".into())))],
                ..Default::default()
            };
            let (sql, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
            assert!(sql.starts_with("CAST(\"value\" AS text) "), "{data_type}: {sql}");
            assert!(matches!(params[0], Value::Text(_)));
        }
    }
    let columns = vec![col("value", "integer")];
    let set = FilterSet {
        rules: vec![rule("value", FilterOp::Eq, Some(FilterValue::Single("12".into())))],
        ..Default::default()
    };
    let (sql, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
    assert_eq!(sql, "\"value\" = $1");
    assert_eq!(params, vec![Value::Int(12)]);
}

#[test]
fn postgres_enum_filters_cast_values_to_the_schema_qualified_type() {
    let mut column = col("status", "value_contract_enum_schema.value_contract_status");
    column.enum_type = Some(crate::QualifiedTypeName {
        schema: "value_contract_enum_schema".into(),
        name: "value_contract_status".into(),
    });
    let columns = [column];
    let cases = [
        (
            FilterOp::Eq,
            FilterValue::Single("NULL".into()),
            "(\"status\"::\"value_contract_enum_schema\".\"value_contract_status\") = $1::\"value_contract_enum_schema\".\"value_contract_status\"",
            vec![Value::Text("NULL".into())],
        ),
        (
            FilterOp::NotEq,
            FilterValue::Single("NULL".into()),
            "(\"status\"::\"value_contract_enum_schema\".\"value_contract_status\") <> $1::\"value_contract_enum_schema\".\"value_contract_status\"",
            vec![Value::Text("NULL".into())],
        ),
        (
            FilterOp::Lt,
            FilterValue::Single("paused".into()),
            "(\"status\"::\"value_contract_enum_schema\".\"value_contract_status\") < $1::\"value_contract_enum_schema\".\"value_contract_status\"",
            vec![Value::Text("paused".into())],
        ),
        (
            FilterOp::In,
            FilterValue::List(vec!["NULL".into(), "東京".into()]),
            "(\"status\"::\"value_contract_enum_schema\".\"value_contract_status\") IN ($1::\"value_contract_enum_schema\".\"value_contract_status\", $2::\"value_contract_enum_schema\".\"value_contract_status\")",
            vec![Value::Text("NULL".into()), Value::Text("東京".into())],
        ),
        (
            FilterOp::Between,
            FilterValue::Pair("ready".into(), "paused".into()),
            "(\"status\"::\"value_contract_enum_schema\".\"value_contract_status\") BETWEEN $1::\"value_contract_enum_schema\".\"value_contract_status\" AND $2::\"value_contract_enum_schema\".\"value_contract_status\"",
            vec![Value::Text("ready".into()), Value::Text("paused".into())],
        ),
    ];
    for (op, value, expected_sql, expected_params) in cases {
        let set = FilterSet {
            rules: vec![rule("status", op, Some(value))],
            ..Default::default()
        };
        let (sql, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
        assert_eq!(sql, expected_sql);
        assert_eq!(params, expected_params);
    }
}

#[test]
fn postgres_enum_array_filters_cast_the_parameter_to_the_array_type() {
    let mut column = col("labels", "value_contract_enum_schema.value_contract_status[]");
    column.enum_type = Some(crate::QualifiedTypeName {
        schema: "value_contract_enum_schema".into(),
        name: "value_contract_status".into(),
    });
    let columns = [column];
    let set = FilterSet {
        rules: vec![rule(
            "labels",
            FilterOp::Eq,
            Some(FilterValue::Single(r#"{"NULL","",NULL}"#.into())),
        )],
        ..Default::default()
    };
    let (sql, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
    assert_eq!(
        sql,
        r#""labels" = $1::"value_contract_enum_schema"."value_contract_status"[]"#
    );
    assert_eq!(params, vec![Value::Text(r#"{"NULL","",NULL}"#.into())]);
}

#[test]
fn postgres_domain_enum_array_filters_cast_the_parameter_to_the_domain_array_type() {
    let mut column = col("labels", "value_contract_domain_array_label[]");
    column.enum_type = Some(crate::QualifiedTypeName {
        schema: "value_contract_domain_schema".into(),
        name: "value_contract_domain_array_label".into(),
    });
    let columns = [column];
    let literal = r#"{"NULL","",東京,NULL}"#;
    let set = FilterSet {
        rules: vec![rule("labels", FilterOp::Eq, Some(FilterValue::Single(literal.into())))],
        ..Default::default()
    };
    let (sql, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
    assert_eq!(
        sql,
        r#""labels" = $1::"value_contract_domain_schema"."value_contract_domain_array_label"[]"#
    );
    assert_eq!(params, vec![Value::Text(literal.into())]);
}

#[test]
fn empty_set_returns_none() {
    let result = build_filter_where("postgres", &[], &FilterSet::default()).unwrap();
    assert!(result.is_none());
}

#[test]
fn single_eq_no_parens() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("42".into())))],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"id\" = $1");
    assert_eq!(params, vec![Value::Int(42)]);
}

#[test]
fn multi_rule_wraps_in_parens() {
    let cols = vec![col("id", "integer"), col("name", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![
            rule("id", FilterOp::GtEq, Some(FilterValue::Single("10".into()))),
            rule("name", FilterOp::Eq, Some(FilterValue::Single("alice".into()))),
        ],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "(\"id\" >= $1 AND \"name\" = $2)");
    assert_eq!(params, vec![Value::Int(10), Value::Text("alice".into())]);
}

#[test]
fn or_combinator_swaps_joiner() {
    let cols = vec![col("a", "integer"), col("b", "integer")];
    let set = FilterSet {
        combinator: Combinator::Or,
        rules: vec![
            rule("a", FilterOp::Eq, Some(FilterValue::Single("1".into()))),
            rule("b", FilterOp::Eq, Some(FilterValue::Single("2".into()))),
        ],
        extra_sql: None,
    };
    let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "(\"a\" = $1 OR \"b\" = $2)");
}

#[test]
fn mysql_uses_question_marks_and_backticks() {
    let cols = vec![col("id", "int")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("7".into())))],
        extra_sql: None,
    };
    let (sql, _) = build_filter_where("mysql", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "`id` = ?");
}

#[test]
fn sqlite_uses_question_marks_and_double_quotes() {
    let cols = vec![col("id", "INTEGER")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("7".into())))],
        extra_sql: None,
    };
    let (sql, _) = build_filter_where("sqlite", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"id\" = ?");
}

#[test]
fn contains_wraps_with_percent_signs() {
    let cols = vec![col("name", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "name",
            FilterOp::Contains,
            Some(FilterValue::Single("ali".into())),
        )],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"name\" LIKE $1");
    assert_eq!(params, vec![Value::Text("%ali%".into())]);
}

#[test]
fn contains_escapes_user_wildcards() {
    // `50%` should match the literal text "50%" — not anything
    // ending in "50". escape_like backslash-escapes `%` and `_`.
    let cols = vec![col("note", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "note",
            FilterOp::Contains,
            Some(FilterValue::Single("50%".into())),
        )],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(params, vec![Value::Text("%50\\%%".into())]);
}

#[test]
fn ilike_keeps_postgres_native_keyword() {
    let cols = vec![col("name", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "name",
            FilterOp::Ilike,
            Some(FilterValue::Single("%alice%".into())),
        )],
        extra_sql: None,
    };
    let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert!(sql.contains("ILIKE"));
}

#[test]
fn ilike_falls_back_to_like_on_mysql() {
    let cols = vec![col("name", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "name",
            FilterOp::Ilike,
            Some(FilterValue::Single("%alice%".into())),
        )],
        extra_sql: None,
    };
    let (sql, _) = build_filter_where("mysql", &cols, &set).unwrap().unwrap();
    assert!(sql.contains(" LIKE "));
    assert!(!sql.contains("ILIKE"));
}

#[test]
fn is_null_emits_no_placeholder() {
    let cols = vec![col("optional", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("optional", FilterOp::IsNull, None)],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"optional\" IS NULL");
    assert!(params.is_empty());
}

#[test]
fn between_uses_two_placeholders() {
    let cols = vec![col("created", "date")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "created",
            FilterOp::Between,
            Some(FilterValue::Pair("2026-01-01".into(), "2026-12-31".into())),
        )],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"created\" BETWEEN $1 AND $2");
    assert_eq!(params.len(), 2);
    assert!(matches!(params[0], Value::Date(_)));
    assert!(matches!(params[1], Value::Date(_)));
}

#[test]
fn between_rejects_empty_bound() {
    let cols = vec![col("n", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "n",
            FilterOp::Between,
            Some(FilterValue::Pair("1".into(), "".into())),
        )],
        extra_sql: None,
    };
    let err = build_filter_where("postgres", &cols, &set).unwrap_err();
    assert!(matches!(err, BuildFilterError::BetweenMissingBound));
}

#[test]
fn in_emits_placeholder_per_element() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "id",
            FilterOp::In,
            Some(FilterValue::List(vec!["1".into(), "2".into(), "3".into()])),
        )],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"id\" IN ($1, $2, $3)");
    assert_eq!(params, vec![Value::Int(1), Value::Int(2), Value::Int(3)]);
}

#[test]
fn in_with_empty_list_rejected() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::In, Some(FilterValue::List(vec![])))],
        extra_sql: None,
    };
    let err = build_filter_where("postgres", &cols, &set).unwrap_err();
    assert!(matches!(err, BuildFilterError::EmptyInList));
}

#[test]
fn unknown_column_errors_with_name() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("nope", FilterOp::Eq, Some(FilterValue::Single("1".into())))],
        extra_sql: None,
    };
    let err = build_filter_where("postgres", &cols, &set).unwrap_err();
    assert!(matches!(err, BuildFilterError::UnknownColumn(n) if n == "nope"));
}

#[test]
fn missing_value_for_eq_errors() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::Eq, None)],
        extra_sql: None,
    };
    let err = build_filter_where("postgres", &cols, &set).unwrap_err();
    assert!(matches!(err, BuildFilterError::MissingValue(FilterOp::Eq)));
}

#[test]
fn invalid_int_input_errors() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("abc".into())))],
        extra_sql: None,
    };
    let err = build_filter_where("postgres", &cols, &set).unwrap_err();
    assert!(matches!(err, BuildFilterError::InvalidValue { .. }));
}

#[test]
fn parses_bool_yes_no() {
    let cols = vec![col("active", "boolean")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("active", FilterOp::Eq, Some(FilterValue::Single("yes".into())))],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(params, vec![Value::Bool(true)]);
}

#[test]
fn parses_uuid_value() {
    let cols = vec![col("id", "uuid")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "id",
            FilterOp::Eq,
            Some(FilterValue::Single("550e8400-e29b-41d4-a716-446655440000".into())),
        )],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert!(matches!(params[0], Value::Uuid(_)));
}

#[test]
fn parses_rfc3339_timestamptz() {
    let cols = vec![col("ts", "timestamp with time zone")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "ts",
            FilterOp::Gt,
            Some(FilterValue::Single("2026-04-29T08:30:00Z".into())),
        )],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert!(matches!(params[0], Value::TimestampTz(_)));
}

#[test]
fn json_column_takes_text_as_is() {
    // Filter on json column with `=` is exact-text comparison;
    // PG-specific containment (`@>`) is intentionally out of scope.
    let cols = vec![col("payload", "jsonb")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "payload",
            FilterOp::Eq,
            Some(FilterValue::Single("{\"a\":1}".into())),
        )],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(params, vec![Value::Text("{\"a\":1}".into())]);
}

#[test]
fn bytes_column_rejected() {
    let cols = vec![col("blob_col", "bytea")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "blob_col",
            FilterOp::Eq,
            Some(FilterValue::Single("anything".into())),
        )],
        extra_sql: None,
    };
    let err = build_filter_where("postgres", &cols, &set).unwrap_err();
    assert!(matches!(err, BuildFilterError::InvalidValue { .. }));
}

#[test]
fn placeholder_indices_continue_across_rules() {
    let cols = vec![col("a", "integer"), col("b", "integer"), col("c", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![
            rule("a", FilterOp::Eq, Some(FilterValue::Single("1".into()))),
            rule("b", FilterOp::Between, Some(FilterValue::Pair("2".into(), "3".into()))),
            rule("c", FilterOp::In, Some(FilterValue::List(vec!["4".into(), "5".into()]))),
        ],
        extra_sql: None,
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert!(sql.contains("$1"));
    assert!(sql.contains("$2"));
    assert!(sql.contains("$3"));
    assert!(sql.contains("$4"));
    assert!(sql.contains("$5"));
    assert_eq!(params.len(), 5);
}

#[test]
fn filter_set_serde_round_trips() {
    let original = FilterSet {
        combinator: Combinator::Or,
        rules: vec![
            rule("a", FilterOp::Eq, Some(FilterValue::Single("1".into()))),
            rule("b", FilterOp::IsNull, None),
            rule("c", FilterOp::Between, Some(FilterValue::Pair("x".into(), "y".into()))),
            rule("d", FilterOp::In, Some(FilterValue::List(vec!["p".into(), "q".into()]))),
        ],
        extra_sql: None,
    };
    let json = serde_json::to_string(&original).unwrap();
    let parsed: FilterSet = serde_json::from_str(&json).unwrap();
    assert_eq!(original, parsed);
}

#[test]
fn filter_set_default_combinator_is_and() {
    // Forward-compat: a stored file written before a hypothetical
    // future field gets added must still load. The Default impl on
    // Combinator (And) plus #[serde(default)] on the field covers
    // missing fields silently.
    let json = r#"{"rules":[]}"#;
    let parsed: FilterSet = serde_json::from_str(json).unwrap();
    assert!(matches!(parsed.combinator, Combinator::And));
}

#[test]
fn not_in_emits_correct_keyword() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "id",
            FilterOp::NotIn,
            Some(FilterValue::List(vec!["1".into(), "2".into()])),
        )],
        extra_sql: None,
    };
    let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "\"id\" NOT IN ($1, $2)");
}

#[test]
fn starts_with_pattern() {
    let cols = vec![col("name", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "name",
            FilterOp::StartsWith,
            Some(FilterValue::Single("ali".into())),
        )],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(params, vec![Value::Text("ali%".into())]);
}

#[test]
fn extra_sql_alone_emits_wrapped_fragment() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![],
        extra_sql: Some("LENGTH(name) > 10".into()),
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    // No structured rules means the join doesn't run; the raw
    // fragment is emitted bare (single-clause path skips parens).
    assert_eq!(sql, "(LENGTH(name) > 10)");
    assert!(params.is_empty());
}

#[test]
fn extra_sql_combines_with_structured_rules() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("id", FilterOp::Gt, Some(FilterValue::Single("10".into())))],
        extra_sql: Some("LENGTH(name) > 10".into()),
    };
    let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "(\"id\" > $1 AND (LENGTH(name) > 10))");
    assert_eq!(params, vec![Value::Int(10)]);
}

#[test]
fn extra_sql_or_combinator() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::Or,
        rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("1".into())))],
        extra_sql: Some("name LIKE 'admin%'".into()),
    };
    let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(sql, "(\"id\" = $1 OR (name LIKE 'admin%'))");
}

#[test]
fn extra_sql_blank_is_treated_as_none() {
    let cols = vec![col("id", "integer")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![],
        extra_sql: Some("   \n  ".into()),
    };
    // Whitespace-only raw → no WHERE; same as empty filter.
    assert!(build_filter_where("postgres", &cols, &set).unwrap().is_none());
}

#[test]
fn filter_set_is_empty_considers_extra_sql() {
    let no_rules_no_extra = FilterSet::default();
    assert!(no_rules_no_extra.is_empty());
    let only_extra = FilterSet {
        combinator: Combinator::And,
        rules: vec![],
        extra_sql: Some("a > 0".into()),
    };
    assert!(!only_extra.is_empty());
    assert_eq!(only_extra.len(), 1);
}

#[test]
fn ends_with_pattern() {
    let cols = vec![col("name", "text")];
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![rule(
            "name",
            FilterOp::EndsWith,
            Some(FilterValue::Single("son".into())),
        )],
        extra_sql: None,
    };
    let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
    assert_eq!(params, vec![Value::Text("%son".into())]);
}
