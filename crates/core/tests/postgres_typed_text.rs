#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_dialect::{build_insert_from_draft, build_keyed_delete, build_optimistic_keyed_update};
use tablepro_core::{ColumnInfo, Value};

fn column(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: !primary_key,
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

fn update_sql(data_type: &str, old: Value, new: Value) -> String {
    let columns = [column("id", "integer", true), column("v", data_type, false)];
    build_optimistic_keyed_update("postgres", None, "t", &columns, &[(1, old, new)], &[Value::Int(1)])
        .unwrap()
        .0
}

#[test]
fn a_text_value_for_a_native_text_decoded_type_is_cast_to_the_column_type() {
    for (data_type, cast) in [
        ("inet", "pg_catalog.inet"),
        ("cidr", "pg_catalog.cidr"),
        ("macaddr", "pg_catalog.macaddr"),
        ("macaddr8", "pg_catalog.macaddr8"),
        ("interval", "pg_catalog.interval"),
        ("interval(3)", "pg_catalog.interval"),
        ("interval day to second", "pg_catalog.interval"),
        ("bit(3)", "pg_catalog.bit(3)"),
        ("bit", "pg_catalog.bit"),
        ("bit varying(5)", "pg_catalog.varbit(5)"),
        ("tsvector", "pg_catalog.tsvector"),
        ("character(5)", "pg_catalog.bpchar"),
    ] {
        let sql = update_sql(data_type, Value::Text("old".into()), Value::Text("new".into()));
        assert_eq!(sql.matches(&format!("::text::{cast}")).count(), 2, "{data_type}: {sql}");
    }
}

#[test]
fn a_keyed_delete_casts_a_text_key_to_the_key_column_type() {
    for (data_type, cast) in [("character(5)", "pg_catalog.bpchar"), ("inet", "pg_catalog.inet")] {
        let columns = [column("id", data_type, true), column("w", "integer", false)];
        let (sql, _) = build_keyed_delete("postgres", None, "t", &columns, &[Value::Text("ab   ".into())]).unwrap();
        assert!(
            sql.contains(&format!("\"id\" = $1::text::{cast}")),
            "{data_type}: {sql}"
        );
    }
}

#[test]
fn an_insert_draft_casts_a_native_text_decoded_value() {
    let columns = [column("id", "integer", true), column("ip", "inet", false)];
    let (sql, _) = build_insert_from_draft(
        "postgres",
        None,
        "t",
        &columns,
        &[Value::Int(1), Value::Text("10.0.0.1".into())],
    )
    .unwrap();
    assert!(sql.contains("$2::text::pg_catalog.inet"), "{sql}");
}

#[test]
fn a_json_column_is_compared_through_jsonb_because_json_has_no_equality() {
    let sql = update_sql(
        "json",
        Value::Json(serde_json::json!({"a": 1})),
        Value::Json(serde_json::json!({"a": 2})),
    );
    assert!(sql.contains("\"v\"::jsonb IS NOT DISTINCT FROM $3::jsonb"), "{sql}");
}

#[test]
fn an_xml_column_is_compared_as_text_because_xml_has_no_equality() {
    let sql = update_sql("xml", Value::Text("<a/>".into()), Value::Text("<b/>".into()));
    assert!(sql.contains("\"v\"::text IS NOT DISTINCT FROM $3::text"), "{sql}");
}

#[test]
fn types_that_need_no_cast_are_left_alone() {
    for data_type in ["text", "integer", "uuid", "boolean", "jsonb", "varchar(20)"] {
        let sql = update_sql(data_type, Value::Text("a".into()), Value::Text("b".into()));
        assert!(!sql.contains("::text::"), "{data_type}: {sql}");
    }
}

#[test]
fn a_bit_length_that_is_not_plain_digits_is_not_cast() {
    let sql = update_sql("bit(1; drop table x)", Value::Text("a".into()), Value::Text("b".into()));
    assert!(!sql.contains("pg_catalog.bit"), "{sql}");
}

#[test]
fn a_real_column_is_compared_after_casting_the_parameter_to_real() {
    for data_type in ["real", "float4"] {
        let sql = update_sql(data_type, Value::Float(0.1), Value::Float(2.5));
        assert!(sql.contains("\"v\" IS NOT DISTINCT FROM $3::real"), "{sql}");
    }
    let double = update_sql("double precision", Value::Float(0.1), Value::Float(2.5));
    assert!(double.contains("\"v\" IS NOT DISTINCT FROM $3"), "{double}");
    assert!(!double.contains("::real"), "{double}");
}

#[test]
fn geometric_columns_are_written_and_compared_through_text() {
    for data_type in ["point", "line", "lseg", "box", "path", "polygon", "circle"] {
        let sql = update_sql(data_type, Value::Text("(1,2)".into()), Value::Text("(3,4)".into()));
        assert!(
            sql.contains(&format!("\"v\" = $1::text::pg_catalog.{data_type}")),
            "{data_type}: {sql}"
        );
        assert!(
            sql.contains(&format!(
                "\"v\"::text IS NOT DISTINCT FROM $3::text::pg_catalog.{data_type}::text"
            )),
            "{data_type}: {sql}"
        );
    }
}
