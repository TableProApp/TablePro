use crate::query::ColumnInfo;

use super::{DraftColumn, build_alter_column};

fn column(from: &str, to: &str) -> DraftColumn {
    let mut column = DraftColumn::from_info(ColumnInfo {
        name: "v".into(),
        data_type: from.into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    });
    column.data_type = to.into();
    column
}

fn type_statement(from: &str, to: &str) -> String {
    build_alter_column("postgres", None, "t", &column(from, to))
        .unwrap()
        .into_iter()
        .find(|statement| statement.contains("TYPE"))
        .unwrap()
}

#[test]
fn a_change_to_a_character_type_never_uses_an_explicit_cast_that_would_truncate() {
    for (from, to) in [
        ("character varying(255)", "character varying(10)"),
        ("character varying(255)", "character(3)"),
        ("integer", "character varying(3)"),
        ("text", "varchar(5)"),
        ("numeric(10,2)", "text"),
        ("uuid", "character varying(8)"),
    ] {
        let statement = type_statement(from, to);
        assert!(!statement.contains("USING"), "{from} to {to}: {statement}");
    }
}

#[test]
fn resizing_a_bit_string_never_uses_an_explicit_cast_that_would_truncate() {
    for (from, to) in [("bit varying(10)", "bit varying(5)"), ("bit(8)", "bit varying(4)")] {
        assert!(!type_statement(from, to).contains("USING"), "{from} to {to}");
    }
}

#[test]
fn a_change_that_has_no_assignment_cast_keeps_its_using_clause() {
    for (from, to) in [
        ("text", "integer"),
        ("character varying(20)", "numeric(10,2)"),
        ("text", "uuid"),
        ("text", "timestamp with time zone"),
        ("integer", "bit(8)"),
        ("text[]", "integer[]"),
    ] {
        let statement = type_statement(from, to);
        assert!(statement.contains(" USING \"v\"::"), "{from} to {to}: {statement}");
    }
}
