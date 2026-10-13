#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::filter::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where};
use tablepro_core::{ColumnInfo, QualifiedTypeName, Value};

fn column(name: &str, data_type: &str) -> ColumnInfo {
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

fn eq(columns: &[ColumnInfo], name: &str, value: &str) -> Result<(String, Vec<Value>), String> {
    let set = FilterSet {
        rules: vec![FilterRule {
            column: name.into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(value.into())),
        }],
        ..Default::default()
    };
    build_filter_where("postgres", columns, &set)
        .map(|built| built.unwrap())
        .map_err(|error| error.to_string())
}

#[test]
fn a_plain_time_column_filters_with_a_native_time_value() {
    let columns = [column("tm", "time without time zone")];
    let (sql, params) = eq(&columns, "tm", "10:30:00").unwrap();
    assert!(matches!(params[0], Value::Time(_)), "{params:?}");
    assert!(sql.contains("\"tm\" = $1") && !sql.contains("::text"), "{sql}");
}

#[test]
fn types_without_a_native_value_filter_as_text_cast_to_the_column_type() {
    for (data_type, value, cast) in [
        ("time with time zone", "10:30:00+02", "pg_catalog.timetz"),
        ("interval", "1 day", "pg_catalog.interval"),
        ("interval day to second", "1 day", "pg_catalog.interval"),
        ("inet", "10.0.0.1", "pg_catalog.inet"),
        ("bit(3)", "101", "pg_catalog.bit(3)"),
        ("int4range", "[1,5)", "pg_catalog.int4range"),
        ("daterange", "[2026-01-01,2026-02-01)", "pg_catalog.daterange"),
        ("tstzrange", "[2026-01-01,2026-02-01)", "pg_catalog.tstzrange"),
    ] {
        let columns = [column("c", data_type)];
        let (sql, params) = eq(&columns, "c", value).unwrap_or_else(|error| panic!("{data_type}: {error}"));
        assert!(matches!(params[0], Value::Text(_)), "{data_type}: {params:?}");
        assert!(sql.contains(&format!("$1::text::{cast}")), "{data_type}: {sql}");
    }
}

#[test]
fn an_enum_whose_name_contains_a_type_word_filters_as_its_own_type() {
    for name in ["update_kind", "maintenance_status", "meeting_time", "json_kind"] {
        let mut enum_column = column("e", name);
        enum_column.enum_type = Some(QualifiedTypeName {
            schema: "public".into(),
            name: name.into(),
        });
        let columns = [enum_column];
        let (sql, params) = eq(&columns, "e", "queued").unwrap_or_else(|error| panic!("{name}: {error}"));
        assert!(matches!(params[0], Value::Text(_)), "{name}: {params:?}");
        assert!(sql.contains(&format!("\"public\".\"{name}\"")), "{name}: {sql}");
    }
}

#[test]
fn a_domain_over_an_integer_filters_as_text_cast_to_the_domain() {
    let mut domain_column = column("d", "positive_int");
    domain_column.domain_type = Some(QualifiedTypeName {
        schema: "public".into(),
        name: "positive_int".into(),
    });
    let (sql, params) = eq(&[domain_column], "d", "5").unwrap();
    assert!(matches!(params[0], Value::Text(_)), "{params:?}");
    assert!(sql.contains("$1::text::\"public\".\"positive_int\""), "{sql}");
}

#[test]
fn ordinary_columns_keep_their_native_values() {
    let columns = [
        column("n", "integer"),
        column("d", "date"),
        column("t", "text"),
        column("b", "boolean"),
    ];
    assert!(matches!(eq(&columns, "n", "5").unwrap().1[0], Value::Int(5)));
    assert!(matches!(eq(&columns, "d", "2026-01-02").unwrap().1[0], Value::Date(_)));
    assert!(matches!(eq(&columns, "t", "x").unwrap().1[0], Value::Text(_)));
    assert!(matches!(eq(&columns, "b", "true").unwrap().1[0], Value::Bool(true)));
    assert!(!eq(&columns, "t", "x").unwrap().0.contains("::text::"));
}
