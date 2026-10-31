use crate::column::ResultColumn;
use crate::dialect::{LiteralError, SqlDialect};
use crate::value::Value;

use super::column_type;
use super::in_clause::list_literal;

/// Every value of the rows, row after row, as the engine's literals in
/// one list: what a user pastes into a `VALUES` row or an IN list by
/// hand. The engine's literal rather than quoted text, so a NULL is not
/// the text `NULL` and a value holding the separator stays one value.
pub fn render_value_list<'a, R>(
    dialect: &dyn SqlDialect,
    columns: &[ResultColumn],
    rows: R,
) -> Result<String, LiteralError>
where
    R: IntoIterator,
    R::Item: IntoIterator<Item = &'a Value>,
{
    let mut literals = Vec::new();
    for row in rows {
        for (index, value) in row.into_iter().enumerate() {
            literals.push(list_literal(dialect, column_type(columns, index), value)?);
        }
    }
    Ok(literals.join(", "))
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;
    use crate::dialect::TestDialect;

    #[test]
    fn value_list_writes_every_row_as_literals_on_one_line() {
        let columns = cols(&["id", "name"]);
        let rows = vec![
            vec![Value::Int(1), Value::Text("Lovelace, Ada".into())],
            vec![Value::Int(2), Value::Null],
            vec![Value::Int(3), Value::Text("NULL".into())],
        ];

        let list = render_value_list(&TestDialect::default(), &columns, &rows).expect("the list");

        assert_eq!(list, "1, 'Lovelace, Ada', 2, NULL, 3, 'NULL'");
    }

    #[test]
    fn value_list_keeps_a_line_break_inside_its_literal() {
        let rows = vec![vec![Value::Text("it's\ntwo lines".into())]];

        let list = render_value_list(&TestDialect::default(), &cols(&["a"]), &rows).expect("the list");

        assert_eq!(list, "'it''s\ntwo lines'");
    }

    #[test]
    fn value_list_fails_on_a_value_the_engine_cannot_write() {
        let rows = vec![vec![Value::Array(vec![Value::Int(2)])]];

        let refused = render_value_list(&TestDialect::default(), &cols(&["a"]), &rows);

        assert!(
            matches!(refused, Err(LiteralError::Unrepresentable { .. })),
            "{refused:?}"
        );
    }
}
