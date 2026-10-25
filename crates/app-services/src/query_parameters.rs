use std::collections::HashMap;

use tablepro_core::{ParameterKind, Value, extract_named_parameters, parse_parameter_value};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum QueryParameterError {
    #[error("No value for parameter {name}")]
    MissingValue { name: String },
    #[error("Invalid value for parameter {name}: {reason}")]
    InvalidValue { name: String, reason: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct BoundStatement {
    pub sql: String,
    pub values: Vec<Value>,
}

pub fn statement_names(sql: &str, driver_id: &str) -> Vec<String> {
    extract_named_parameters(sql, driver_id).names
}

pub fn bind_statement(
    sql: &str,
    driver_id: &str,
    values: &HashMap<String, Value>,
) -> Result<BoundStatement, QueryParameterError> {
    let parsed = extract_named_parameters(sql, driver_id);
    let mut bound = Vec::with_capacity(parsed.bindings.len());
    for name in &parsed.bindings {
        let value = values
            .get(name)
            .ok_or_else(|| QueryParameterError::MissingValue { name: name.clone() })?;
        bound.push(value.clone());
    }
    Ok(BoundStatement {
        sql: parsed.sql,
        values: bound,
    })
}

pub fn collect_values(
    entries: &[(String, ParameterKind, String)],
) -> Result<HashMap<String, Value>, QueryParameterError> {
    let mut values = HashMap::with_capacity(entries.len());
    for (name, kind, text) in entries {
        let value = parse_parameter_value(*kind, text).map_err(|reason| QueryParameterError::InvalidValue {
            name: name.clone(),
            reason,
        })?;
        values.insert(name.clone(), value);
    }
    Ok(values)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use tablepro_core::{ParameterKind, Value};

    use super::{QueryParameterError, bind_statement, collect_values, statement_names};

    #[test]
    fn binds_every_occurrence_in_statement_order() {
        let mut values = HashMap::new();
        values.insert("id".to_string(), Value::Int(7));
        values.insert("name".to_string(), Value::Text("ada".into()));

        let bound = bind_statement(
            "UPDATE t SET name = :name WHERE id = :id OR parent = :id",
            "postgres",
            &values,
        )
        .expect("bind");

        assert_eq!(bound.sql, "UPDATE t SET name = $1 WHERE id = $2 OR parent = $3");
        assert_eq!(
            bound.values,
            vec![Value::Text("ada".into()), Value::Int(7), Value::Int(7)]
        );
    }

    #[test]
    fn a_missing_value_returns_a_typed_refusal() {
        let error = bind_statement("SELECT :missing", "postgres", &HashMap::new()).expect_err("missing value");

        assert_eq!(error, QueryParameterError::MissingValue { name: "missing".into() });
    }

    #[test]
    fn statements_without_parameters_bind_nothing() {
        let bound = bind_statement("SELECT 1", "postgres", &HashMap::new()).expect("bind");

        assert_eq!(bound.sql, "SELECT 1");
        assert!(bound.values.is_empty());
    }

    #[test]
    fn invalid_typed_values_return_their_parameter_name() {
        let entries = vec![("count".to_string(), ParameterKind::Integer, "twelve".to_string())];

        let error = collect_values(&entries).expect_err("invalid integer");

        assert!(matches!(error, QueryParameterError::InvalidValue { name, .. } if name == "count"));
    }

    #[test]
    fn collected_sql_text_remains_a_bound_value() {
        let sql_text = "'; DROP TABLE users; --";
        let entries = vec![("name".to_string(), ParameterKind::Auto, sql_text.to_string())];

        let values = collect_values(&entries).expect("collect");
        let bound = bind_statement("SELECT :name", "postgres", &values).expect("bind");

        assert_eq!(bound.sql, "SELECT $1");
        assert_eq!(bound.values, vec![Value::Text(sql_text.into())]);
    }

    #[test]
    fn names_are_reported_in_first_appearance_order() {
        assert_eq!(
            statement_names("SELECT :b, :a, :b FROM t", "postgres"),
            vec!["b".to_string(), "a".to_string()]
        );
    }
}
