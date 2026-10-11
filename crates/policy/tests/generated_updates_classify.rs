#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_dialect::build_optimistic_keyed_update;
use tablepro_core::{ColumnInfo, Value};
use tablepro_policy::{StatementClass, classify};

fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "text".into(),
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

#[test]
fn the_update_a_grid_edit_generates_is_a_plain_update_on_every_sql_engine() {
    let columns = [column("id", true), column("note", false)];
    for driver in ["postgres", "sqlite", "duckdb", "mysql", "mssql"] {
        for old in [Value::Text("alpha".into()), Value::Null] {
            let (sql, _params) = build_optimistic_keyed_update(
                driver,
                None,
                "items",
                &columns,
                &[(1, old, Value::Text("beta".into()))],
                &[Value::Int(1)],
            )
            .unwrap();
            let facts = classify(&sql, driver);
            assert_eq!(
                facts.class,
                StatementClass::Update,
                "{driver} generated SQL the policy cannot parse, so every grid edit would ask for approval: {sql}"
            );
        }
    }
}
