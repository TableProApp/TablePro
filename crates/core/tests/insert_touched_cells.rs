#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_dialect::{build_insert_from_draft, build_insert_from_draft_touched};
use tablepro_core::{ColumnInfo, Value};

fn column(name: &str, auto_increment: bool, default: Option<&str>) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: auto_increment,
        default_value: default.map(str::to_string),
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn columns() -> Vec<ColumnInfo> {
    vec![
        column("id", true, Some("nextval('t_id_seq'::regclass)")),
        column("status", false, Some("'new'::text")),
        column("note", false, None),
    ]
}

#[test]
fn an_untouched_null_lets_the_default_apply_and_an_explicit_null_overrides_it() {
    let values = [Value::Null, Value::Null, Value::Text("x".into())];
    let untouched = build_insert_from_draft("postgres", None, "t", &columns(), &values)
        .unwrap()
        .0;
    assert_eq!(untouched, r#"INSERT INTO "t" ("note") VALUES ($1)"#);
    let explicit = build_insert_from_draft_touched("postgres", None, "t", &columns(), &values, &[false, true, true])
        .unwrap()
        .0;
    assert_eq!(explicit, r#"INSERT INTO "t" ("status", "note") VALUES ($1, $2)"#);
}

#[test]
fn a_typed_identity_value_is_inserted_but_a_null_one_is_not() {
    let typed = [Value::Int(7), Value::Null, Value::Null];
    let (sql, params) =
        build_insert_from_draft_touched("postgres", None, "t", &columns(), &typed, &[true, false, false]).unwrap();
    assert_eq!(sql, r#"INSERT INTO "t" ("id", "note") VALUES ($1, $2)"#);
    assert_eq!(params, vec![Value::Int(7), Value::Null]);
    let nulled = [Value::Null, Value::Null, Value::Text("x".into())];
    let (sql, _) =
        build_insert_from_draft_touched("postgres", None, "t", &columns(), &nulled, &[true, false, true]).unwrap();
    assert_eq!(sql, r#"INSERT INTO "t" ("note") VALUES ($1)"#);
}

#[test]
fn the_import_builder_keeps_dropping_identity_values() {
    let values = [Value::Int(7), Value::Null, Value::Text("x".into())];
    let sql = build_insert_from_draft("postgres", None, "t", &columns(), &values)
        .unwrap()
        .0;
    assert_eq!(sql, r#"INSERT INTO "t" ("note") VALUES ($1)"#);
}
