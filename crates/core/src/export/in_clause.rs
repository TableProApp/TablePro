use super::supports_sql_literals;
use crate::query::Value;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct InClause {
    pub sql: String,
    pub skipped: usize,
}

pub fn render_in_clause(driver_id: &str, rows: &[Vec<Value>], column_index: usize) -> InClause {
    let values = rows.iter().filter_map(|row| row.get(column_index)).collect::<Vec<_>>();
    let literals = values
        .iter()
        .filter_map(|value| in_clause_literal(driver_id, value))
        .collect::<Vec<_>>();
    InClause {
        skipped: values.len() - literals.len(),
        sql: if literals.is_empty() {
            String::new()
        } else {
            format!("({})", literals.join(", "))
        },
    }
}

fn in_clause_literal(driver_id: &str, value: &Value) -> Option<String> {
    if !supports_sql_literals(driver_id) || matches!(value, Value::Null | Value::Bytes(_) | Value::Undecodable(_)) {
        return None;
    }
    if matches!(value, Value::Float(number) if !number.is_finite()) {
        return None;
    }
    if let Value::Bool(value) = value {
        return Some(
            match (driver_id, value) {
                ("mssql", true) => "1",
                ("mssql", false) => "0",
                (_, true) => "TRUE",
                (_, false) => "FALSE",
            }
            .into(),
        );
    }
    crate::sql_literal::render_sql_literal(driver_id, value).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::value_to_text;

    #[test]
    fn in_clause_renderer_quotes_values_and_reports_unusable_values() {
        let rows = vec![
            vec![Value::Int(1)],
            vec![Value::Text("O'Reilly".into())],
            vec![Value::Bool(true)],
            vec![Value::Null],
            vec![Value::Bytes(vec![0])],
            vec![Value::Undecodable("NUMERIC".into())],
        ];

        assert_eq!(
            render_in_clause("postgres", &rows, 0),
            InClause {
                sql: "(1, 'O''Reilly', TRUE)".into(),
                skipped: 3
            }
        );
        assert_eq!(render_in_clause("postgres", &rows, 1), InClause::default());
    }

    #[test]
    fn in_clause_uses_dialect_escaping_and_preserves_fractional_time() {
        let rows = vec![vec![Value::Text("x\\' OR 1=1 -- ".into())]];
        assert_eq!(render_in_clause("clickhouse", &rows, 0).sql, "('x\\\\'' OR 1=1 -- ')");
        assert_eq!(
            render_in_clause("mysql", &rows, 0).sql,
            "(_utf8mb4 X'785c27204f5220313d31202d2d20')"
        );
        assert_eq!(render_in_clause("postgres", &rows, 0).sql, "(E'x\\\\'' OR 1=1 -- ')");
        assert!(render_in_clause("redis", &rows, 0).sql.is_empty());
        assert_eq!(render_in_clause("redis", &rows, 0).skipped, 1);
        let time = Value::Time("12:34:56.123456".parse().unwrap());
        assert_eq!(value_to_text(&time).as_deref(), Some("12:34:56.123456"));
        assert_eq!(
            render_in_clause("postgres", &[vec![time]], 0).sql,
            "('12:34:56.123456')"
        );
    }
}
