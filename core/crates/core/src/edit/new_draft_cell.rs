use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::value::Value;

use super::CellInput;

/// What a new row holds in `column` until the user types: the server's
/// value where it has one, else NULL.
pub fn new_draft_cell(column: &ColumnInfo) -> CellInput {
    match column.is_auto_increment || column.is_generated || !column.default.is_none() {
        true => CellInput::Default,
        false => CellInput::Value(Value::Null),
    }
}

/// A value the app read as a new row's cell, as Duplicate Rows copies one
/// and a CSV import reads its null marker. Where the dialect reads a value
/// a row does not hold as NULL, a NULL takes the column's default, which
/// leaves the value out as the row it came from did. A NULL the user types
/// is a value and never comes through here.
pub fn read_cell(value: Value, column: &ColumnInfo, dialect: &dyn SqlDialect) -> CellInput {
    match value.is_null() && dialect.reads_missing_as_null() {
        true => new_draft_cell(column),
        false => CellInput::Value(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnDefault, ColumnType, SqlExpression};
    use crate::dialect::TestDialect;

    #[test]
    fn a_null_read_where_a_missing_value_reads_as_null_is_left_to_the_default() {
        let mut field = ColumnInfo {
            name: "email".to_owned(),
            column_type: ColumnType::untyped_text("string"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        };
        let documents = TestDialect::default().reading_missing_as_null();
        let rows = TestDialect::default();

        assert_eq!(
            read_cell(Value::Null, &field, &documents),
            CellInput::Value(Value::Null)
        );
        field.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("$$REMOVE"));
        assert_eq!(read_cell(Value::Null, &field, &documents), CellInput::Default);
        assert_eq!(
            read_cell(Value::Int(1), &field, &documents),
            CellInput::Value(Value::Int(1))
        );
        assert_eq!(read_cell(Value::Null, &field, &rows), CellInput::Value(Value::Null));
    }
}
