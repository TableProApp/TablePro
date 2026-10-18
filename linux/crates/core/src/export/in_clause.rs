use crate::column::ColumnType;
use crate::dialect::{LiteralError, SqlDialect};
use crate::value::Value;

/// The value as the engine's own literal, or `None` for one an IN list
/// leaves out. The engine's literal and not a quoted copy of the text:
/// MySQL and ClickHouse read a backslash in a string as an escape, so a
/// value ending in one would close the string early.
fn in_clause_literal(
    dialect: &dyn SqlDialect,
    column: &ColumnType,
    value: &Value,
) -> Option<Result<String, LiteralError>> {
    match value {
        // NULL never matches an IN list and turns a NOT IN into a
        // list that matches nothing at all; a binary literal has a
        // different spelling on every engine. Both are reported to
        // the caller rather than written.
        Value::Null | Value::Bytes(_) => None,
        // The widened double, not the real's own digits: an engine
        // compares a `real` with a numeric literal as a double, and
        // `0.1` as a double is not the `real` 0.1.
        Value::Float32(real) => Some(dialect.literal(&Value::Float64(f64::from(*real)), column)),
        other => Some(dialect.literal(other, column)),
    }
}

/// The `(…)` list plus the count of values it could not carry. An
/// empty `sql` means every value was skipped: `()` is a syntax error
/// on every engine, so the caller reports it instead of putting it on
/// the clipboard.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct InClause {
    pub sql: String,
    pub skipped: usize,
}

/// One column's values, from the rows a user picked, as an IN list in
/// the engine's spelling. A value the engine has no literal for fails
/// the list, since one left out would select other rows.
pub fn render_in_clause<'a>(
    dialect: &dyn SqlDialect,
    column: &ColumnType,
    values: impl IntoIterator<Item = &'a Value>,
) -> Result<InClause, LiteralError> {
    let mut skipped = 0;
    let mut literals = Vec::new();
    for value in values {
        match in_clause_literal(dialect, column, value) {
            Some(literal) => literals.push(literal?),
            None => skipped += 1,
        }
    }
    Ok(InClause {
        skipped,
        sql: if literals.is_empty() {
            String::new()
        } else {
            format!("({})", literals.join(", "))
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dialect::TestDialect;

    fn text_column() -> ColumnType {
        ColumnType::untyped_text("text")
    }

    #[test]
    fn in_clause_reports_the_values_it_skips() {
        let values = vec![
            Value::Text("O'Brien".into()),
            Value::Null,
            Value::Int(5),
            Value::Bool(true),
        ];

        let out = render_in_clause(&TestDialect::default(), &text_column(), &values).expect("the list");

        assert_eq!(out.sql, "('O''Brien', 5, true)");
        assert_eq!(out.skipped, 1);
    }

    #[test]
    fn in_clause_is_empty_rather_than_invalid_when_all_skipped() {
        let values = vec![Value::Null, Value::Bytes(vec![1, 2])];

        let out = render_in_clause(&TestDialect::default(), &text_column(), &values).expect("the list");

        assert_eq!(out.sql, "");
        assert_eq!(out.skipped, 2);
    }

    #[test]
    fn in_clause_fails_on_a_value_the_engine_cannot_write() {
        let values = vec![Value::Int(1), Value::Array(vec![Value::Int(2)])];

        let refused = render_in_clause(&TestDialect::default(), &text_column(), &values);

        assert!(
            matches!(refused, Err(LiteralError::Unrepresentable { .. })),
            "{refused:?}"
        );
    }
}
