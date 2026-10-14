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
        // The widened double, not the real's own digits: an engine
        // compares a `real` with a numeric literal as a double, and
        // `0.1` as a double is not the `real` 0.1.
        Value::Float32(real) => value_to_text(&Value::Float64(f64::from(*real))),
        Value::Int(_) | Value::UInt(_) | Value::WideInt(_) | Value::Float64(_) | Value::Decimal(_) => value_to_text(v),
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

/// One column's values, from the rows a user picked, as an IN list.
pub fn render_in_clause<'a>(values: impl IntoIterator<Item = &'a Value>) -> InClause {
    let mut count = 0;
    let literals: Vec<String> = values
        .into_iter()
        .inspect(|_| count += 1)
        .filter_map(in_clause_literal)
        .collect();
    InClause {
        skipped: count - literals.len(),
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
        let values = vec![
            Value::Text("O'Brien".into()),
            Value::Null,
            Value::Int(5),
            Value::Bool(true),
        ];

        let out = render_in_clause(&values);

        assert_eq!(out.sql, "('O''Brien', 5, TRUE)");
        assert_eq!(out.skipped, 1);
    }

    #[test]
    fn in_clause_writes_a_real_as_the_double_it_compares_as() {
        let values = vec![Value::Float32(0.1)];

        let out = render_in_clause(&values);

        assert_eq!(out.sql, format!("({})", f64::from(0.1_f32)));
    }

    #[test]
    fn in_clause_is_empty_rather_than_invalid_when_all_skipped() {
        let values = vec![Value::Null, Value::Bytes(vec![1, 2])];

        let out = render_in_clause(&values);

        assert_eq!(out.sql, "");
        assert_eq!(out.skipped, 2);
    }
}
