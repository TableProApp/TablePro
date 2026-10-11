#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! Consumer-level tests for the pipelines the application composes out
//! of `tablepro-core`. Each helper has unit tests of its own; these
//! cover the seams between them, where a mismatch produces SQL whose
//! placeholders and parameters disagree.

use tablepro_core::sql_dialect::{build_order_and_pagination, placeholder_for, quote_ident};
use tablepro_core::sql_lex::{split_statements, statement_at_cursor};
use tablepro_core::sql_literal::build_insert_literal;
use tablepro_core::{
    ColumnInfo, Combinator, FilterOp, FilterRule, FilterSet, FilterValue, Value, build_filter_where,
    extract_named_parameters, keyset_order_by, keyset_where_clause,
};

const DIALECTS: [&str; 5] = ["postgres", "mysql", "sqlite", "mssql", "clickhouse"];

fn column(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: true,
        primary_key,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn schema() -> Vec<ColumnInfo> {
    vec![
        column("id", "integer", true),
        column("name", "text", false),
        column("age", "integer", false),
    ]
}

/// Count the placeholders a dialect would bind, in the order they appear.
fn placeholders_in(driver_id: &str, sql: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut index = 0usize;
    while index < sql.len() {
        let rest = &sql[index..];
        let candidate = (0..12).find_map(|position| {
            let placeholder = placeholder_for(driver_id, position);
            rest.starts_with(&placeholder).then_some(placeholder)
        });
        match candidate {
            Some(placeholder) => {
                index += placeholder.len();
                found.push(placeholder);
            }
            None => index += rest.chars().next().map_or(1, char::len_utf8),
        }
    }
    found
}

#[test]
fn a_filtered_page_binds_exactly_the_parameters_its_sql_asks_for() {
    let columns = schema();
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![
            FilterRule {
                column: "name".into(),
                op: FilterOp::Contains,
                value: Some(FilterValue::Single("ali".into())),
            },
            FilterRule {
                column: "age".into(),
                op: FilterOp::GtEq,
                value: Some(FilterValue::Single("21".into())),
            },
        ],
        extra_sql: None,
    };

    for driver_id in DIALECTS {
        let (where_sql, params) = build_filter_where(driver_id, &columns, &set)
            .expect("the filter must build")
            .expect("two rules must produce a clause");
        let sql = format!(
            "SELECT * FROM {} WHERE {where_sql}{}",
            quote_ident(driver_id, "people"),
            build_order_and_pagination(driver_id, None, 100, 0)
        );
        assert_eq!(
            placeholders_in(driver_id, &sql).len(),
            params.len(),
            "{driver_id} produced {sql}"
        );
        assert_eq!(params, vec![Value::Text("%ali%".into()), Value::Int(21)], "{driver_id}");
    }
}

#[test]
fn a_keyset_page_continues_the_placeholder_run_the_filter_started() {
    let columns = schema();
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: "age".into(),
            op: FilterOp::GtEq,
            value: Some(FilterValue::Single("21".into())),
        }],
        extra_sql: None,
    };

    for driver_id in DIALECTS {
        let (where_sql, mut params) = build_filter_where(driver_id, &columns, &set)
            .expect("the filter must build")
            .expect("one rule must produce a clause");
        let (keyset_sql, keyset_params) = keyset_where_clause(driver_id, &["id"], &[Value::Int(500)], params.len())
            .expect("the keyset clause must build");
        params.extend(keyset_params);

        let order = keyset_order_by(driver_id, &["id"]);
        let order_inner = order.trim().strip_prefix("ORDER BY").map(str::trim);
        let sql = format!(
            "SELECT * FROM {} WHERE {where_sql} AND {keyset_sql}{}",
            quote_ident(driver_id, "people"),
            build_order_and_pagination(driver_id, order_inner, 100, 0)
        );

        let seen = placeholders_in(driver_id, &sql);
        assert_eq!(seen.len(), params.len(), "{driver_id} produced {sql}");
        if driver_id == "postgres" || driver_id == "mssql" {
            let expected: Vec<String> = (0..params.len()).map(|i| placeholder_for(driver_id, i)).collect();
            assert_eq!(
                seen, expected,
                "{driver_id} numbered its placeholders out of order: {sql}"
            );
        }
    }
}

#[test]
fn a_keyset_clause_that_cannot_be_built_is_refused_rather_than_guessed() {
    assert!(keyset_where_clause("postgres", &[], &[], 0).is_err());
    assert!(keyset_where_clause("postgres", &["id"], &[Value::Int(1), Value::Int(2)], 0).is_err());
}

#[test]
fn splitting_a_script_preserves_the_parameters_of_every_statement() {
    let script = "SELECT * FROM t WHERE a = :a; UPDATE t SET b = :b WHERE a = :a";
    for driver_id in DIALECTS {
        let statements = split_statements(script, driver_id);
        assert_eq!(statements.len(), 2, "{driver_id}");
        let names: Vec<String> = statements
            .iter()
            .flat_map(|statement| extract_named_parameters(statement, driver_id).names)
            .collect();
        assert_eq!(names, vec!["a", "b", "a"], "{driver_id}");
    }
}

#[test]
fn a_statement_the_splitter_returns_is_the_one_the_cursor_reports() {
    let script = "SELECT 1; SELECT 2; SELECT 3";
    for driver_id in DIALECTS {
        let statements = split_statements(script, driver_id);
        let mut offset = 0usize;
        for statement in &statements {
            let position = script[offset..].find(statement.as_str()).expect("statement in script") + offset;
            let picked = statement_at_cursor(script, driver_id, position).expect("a statement at that byte");
            assert_eq!(
                &picked, statement,
                "{driver_id} disagreed with itself at byte {position}"
            );
            offset = position + statement.len();
        }
    }
}

#[test]
fn a_dollar_quoted_body_survives_the_whole_editor_pipeline() {
    let script =
        "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN :nope; END; $body$ LANGUAGE plpgsql; SELECT :yes";
    let statements = split_statements(script, "postgres");
    assert_eq!(statements.len(), 2);
    assert!(statements[0].contains("RETURN :nope"), "{:?}", statements[0]);

    let body = extract_named_parameters(&statements[0], "postgres");
    assert!(
        body.is_empty(),
        "a parameter inside a dollar-quoted body must stay text"
    );
    let tail = extract_named_parameters(&statements[1], "postgres");
    assert_eq!(tail.names, vec!["yes"]);
    assert_eq!(tail.sql, "SELECT $1");
}

#[test]
fn an_identifier_holding_the_dialect_delimiter_stays_one_identifier() {
    let awkward = ["a\"b", "a`b", "a]b", "a'b", "a;b", "a b"];
    for driver_id in DIALECTS {
        for name in awkward {
            let quoted = quote_ident(driver_id, name);
            let sql = format!("SELECT {quoted} FROM t; SELECT 2");
            assert_eq!(
                split_statements(&sql, driver_id).len(),
                2,
                "{driver_id} split inside {quoted}"
            );
        }
    }
}

#[test]
fn a_copied_row_and_a_drafted_row_agree_on_which_columns_are_writable() {
    let mut columns = schema();
    columns.push(ColumnInfo {
        is_generated: true,
        comment: None,
        ..column("computed", "integer", false)
    });
    let row = vec![
        Value::Int(1),
        Value::Text("alice".into()),
        Value::Int(30),
        Value::Int(99),
    ];

    for driver_id in DIALECTS {
        let copied = build_insert_literal(driver_id, None, "people", &columns, &row).expect("render the insert");
        assert!(
            !copied.contains(&quote_ident(driver_id, "computed")),
            "{driver_id} offered to insert a generated column: {copied}"
        );
        let drafted = tablepro_core::sql_dialect::build_insert_from_draft(driver_id, None, "people", &columns, &row)
            .expect("build the draft insert");
        assert!(!drafted.0.contains(&quote_ident(driver_id, "computed")), "{driver_id}");
    }
}

#[test]
fn an_unknown_filter_column_is_reported_rather_than_quoted_into_sql() {
    let columns = schema();
    let set = FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: "no_such_column".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("1".into())),
        }],
        extra_sql: None,
    };
    let error = build_filter_where("postgres", &columns, &set).expect_err("an unknown column must be refused");
    assert!(format!("{error}").contains("no_such_column"));
}

#[test]
fn an_empty_filter_produces_no_clause_so_the_caller_can_skip_where() {
    let columns = schema();
    for driver_id in DIALECTS {
        let built = build_filter_where(driver_id, &columns, &FilterSet::default()).expect("an empty filter builds");
        assert!(built.is_none(), "{driver_id}");
    }
}
