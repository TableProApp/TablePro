use crate::value::Value;

use super::value_text::value_to_text;

fn in_clause_literal(v: &Value) -> Option<String> {
    match v {
        // NULL never matches an IN list and turns a NOT IN into a
        // list that matches nothing at all; a binary literal has a
        // different spelling on every engine. Both are reported to
        // the caller rather than written.
        Value::Null | Value::Bytes(_) => None,
        Value::Bool(b) => Some(if *b { "TRUE".to_string() } else { "FALSE".to_string() }),
        Value::Int(_)
        | Value::UInt(_)
        | Value::WideInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_) => value_to_text(v),
        other => value_to_text(other).map(|s| format!("'{}'", s.replace('\'', "''"))),
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

pub fn render_in_clause(rows: &[Vec<Value>], col_index: usize) -> InClause {
    let values: Vec<&Value> = rows.iter().filter_map(|row| row.get(col_index)).collect();
    let literals: Vec<String> = values.iter().filter_map(|v| in_clause_literal(v)).collect();
    InClause {
        skipped: values.len() - literals.len(),
        sql: if literals.is_empty() {
            String::new()
        } else {
            format!("({})", literals.join(", "))
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_clause_reports_the_values_it_skips() {
        let rows = vec![
            vec![Value::Text("O'Brien".into())],
            vec![Value::Null],
            vec![Value::Int(5)],
            vec![Value::Bool(true)],
        ];

        let out = render_in_clause(&rows, 0);

        assert_eq!(out.sql, "('O''Brien', 5, TRUE)");
        assert_eq!(out.skipped, 1);
    }

    #[test]
    fn in_clause_is_empty_rather_than_invalid_when_all_skipped() {
        let rows = vec![vec![Value::Null], vec![Value::Bytes(vec![1, 2])]];

        let out = render_in_clause(&rows, 0);

        assert_eq!(out.sql, "");
        assert_eq!(out.skipped, 2);
    }
}
