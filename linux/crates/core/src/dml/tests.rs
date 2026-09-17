use crate::column::{
    CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, ReadForm, SqlTypeExpr, TextKind,
};
use crate::dialect::TestDialect;
use crate::edit::CellInput;
use crate::meta::{EngineRowId, RowIdentity, TableRef};
use crate::value::{UndecodableReason, UndecodedValue, Value};

use super::*;

fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::new(
            SqlTypeExpr::from_catalog_text("t"),
            kind,
            CatalogType::Unknown,
            false,
            ReadForm::Native,
        ),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn columns() -> Vec<ColumnInfo> {
    vec![
        column("id", ColumnKind::Integer(IntegerKind::I64)),
        column("name", ColumnKind::Text(TextKind::Variable)),
        column("tenant", ColumnKind::Integer(IntegerKind::I64)),
    ]
}

fn table() -> TableRef {
    TableRef::new(Some("public".to_owned()), "users")
}

fn by_id() -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }
}

fn undecodable() -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: "geography".to_owned(),
        reason: UndecodableReason::UnsupportedType,
    }))
}

#[test]
fn build_update_binds_every_value_and_names_the_row() {
    let dialect = TestDialect::exact();
    let columns = columns();

    let statement = build_update(
        &dialect,
        &table(),
        &columns,
        &by_id(),
        &[Value::Int(7)],
        &[(1, Value::Text("new".to_owned()))],
    )
    .expect("the update");

    assert_eq!(
        statement.sql(),
        r#"UPDATE "public"."users" SET "name" = $1 WHERE "id" = $2"#
    );
    assert_eq!(statement.params().len(), 2);
    assert_eq!(statement.params()[0].value(), &Value::Text("new".to_owned()));
    assert_eq!(statement.params()[1].value(), &Value::Int(7));
}

#[test]
fn build_update_null_key_renders_is_null_without_marker() {
    let dialect = TestDialect::exact();
    let columns = columns();
    let identity = RowIdentity::UniqueKey {
        columns: vec!["id".to_owned(), "tenant".to_owned()],
    };

    let statement = build_update(
        &dialect,
        &table(),
        &columns,
        &identity,
        &[Value::Int(7), Value::Null],
        &[(1, Value::Text("new".to_owned()))],
    )
    .expect("the update");

    assert!(
        statement.sql().ends_with(r#"WHERE "id" = $2 AND "tenant" IS NULL"#),
        "{}",
        statement.sql()
    );
    assert_eq!(statement.params().len(), 2, "a null key part was bound as a parameter");
}

#[test]
fn build_update_undecodable_key_is_error() {
    let dialect = TestDialect::exact();

    let error = build_update(
        &dialect,
        &table(),
        &columns(),
        &by_id(),
        &[undecodable()],
        &[(1, Value::Text("new".to_owned()))],
    )
    .expect_err("an unreadable key");

    assert_eq!(error, BuildSqlError::UndecodableKey);
}

#[test]
fn build_update_with_no_assignments_is_error() {
    let dialect = TestDialect::exact();

    let error =
        build_update(&dialect, &table(), &columns(), &by_id(), &[Value::Int(1)], &[]).expect_err("nothing to change");

    assert_eq!(error, BuildSqlError::NothingToUpdate);
}

#[test]
fn a_key_of_the_wrong_length_is_error() {
    let dialect = TestDialect::exact();

    let error = build_delete(
        &dialect,
        &table(),
        &columns(),
        &by_id(),
        &[Value::Int(1), Value::Int(2)],
    )
    .expect_err("too many key values");

    assert_eq!(error, BuildSqlError::LengthMismatch { expected: 1, found: 2 });
}

#[test]
fn an_engine_row_id_needs_a_dialect_that_has_one() {
    let dialect = TestDialect::exact();
    let identity = RowIdentity::EngineRowId(EngineRowId::SqliteRowid);

    let error = build_delete(&dialect, &table(), &columns(), &identity, &[Value::Int(11)])
        .expect_err("an engine with no row id");

    assert_eq!(error, BuildSqlError::NoRowIdentity);
}

#[test]
fn build_delete_names_the_row_and_nothing_else() {
    let dialect = TestDialect::exact();

    let statement = build_delete(&dialect, &table(), &columns(), &by_id(), &[Value::Int(7)]).expect("the delete");

    assert_eq!(statement.sql(), r#"DELETE FROM "public"."users" WHERE "id" = $1"#);
    assert_eq!(statement.params().len(), 1);
}

#[test]
fn build_key_probe_stops_at_two_rows() {
    let dialect = TestDialect::default();

    let statement = build_key_probe(&dialect, &table(), &columns(), &by_id(), &[Value::Int(7)]).expect("the probe");

    assert!(statement.sql().contains("LIMIT 2"), "{}", statement.sql());
    assert!(statement.sql().starts_with("SELECT COUNT(*)"), "{}", statement.sql());
}

#[test]
fn build_insert_omits_default_cells_and_generated_columns() {
    let dialect = TestDialect::exact();
    let mut columns = columns();
    columns[0].is_auto_increment = true;
    columns[2].is_generated = true;

    let statement = build_insert(
        &dialect,
        &table(),
        &columns,
        &[
            CellInput::Value(Value::Int(1)),
            CellInput::Value(Value::Text("a".to_owned())),
            CellInput::Value(Value::Int(2)),
        ],
    )
    .expect("the insert");

    assert_eq!(
        statement.sql(),
        r#"INSERT INTO "public"."users" ("name") VALUES ($1)"#,
        "a column the server owns was written"
    );
    assert_eq!(statement.params().len(), 1);
}

#[test]
fn build_insert_leaves_out_the_cells_the_user_did_not_fill() {
    let dialect = TestDialect::exact();

    let statement = build_insert(
        &dialect,
        &table(),
        &columns(),
        &[
            CellInput::Value(Value::Int(1)),
            CellInput::Default,
            CellInput::Value(Value::Int(2)),
        ],
    )
    .expect("the insert");

    assert_eq!(
        statement.sql(),
        r#"INSERT INTO "public"."users" ("id", "tenant") VALUES ($1, $2)"#
    );
}

#[test]
fn build_insert_all_default_uses_default_row() {
    let dialect = TestDialect::exact();

    let statement = build_insert(
        &dialect,
        &table(),
        &columns(),
        &[CellInput::Default, CellInput::Default, CellInput::Default],
    )
    .expect("the insert");

    assert_eq!(statement.sql(), r#"INSERT INTO "public"."users" DEFAULT VALUES"#);
    assert!(statement.params().is_empty());
}

#[test]
fn a_draft_row_of_the_wrong_width_is_error() {
    let dialect = TestDialect::exact();

    let error = build_insert(&dialect, &table(), &columns(), &[CellInput::Default]).expect_err("a short row");

    assert_eq!(error, BuildSqlError::LengthMismatch { expected: 3, found: 1 });
}

#[test]
fn a_value_of_the_wrong_type_is_refused_before_it_reaches_the_server() {
    let dialect = TestDialect::exact();

    let error = build_update(
        &dialect,
        &table(),
        &columns(),
        &by_id(),
        &[Value::Int(7)],
        &[(0, Value::Text("not a number".to_owned()))],
    )
    .expect_err("text into an integer column");

    assert!(matches!(error, BuildSqlError::Bind(_)), "{error:?}");
}
