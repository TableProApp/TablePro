use std::collections::HashMap;

use tablepro_core::{ParameterKind, Value, extract_named_parameters, parse_parameter_value};

#[derive(Debug, Clone, PartialEq)]
pub struct BoundStatement {
    pub sql: String,
    pub values: Vec<Value>,
}

pub fn statement_names(sql: &str, driver_id: &str) -> Vec<String> {
    extract_named_parameters(sql, driver_id).names
}

pub fn bind_statement(sql: &str, driver_id: &str, values: &HashMap<String, Value>) -> Result<BoundStatement, String> {
    let parsed = extract_named_parameters(sql, driver_id);
    let mut bound = Vec::with_capacity(parsed.bindings.len());
    for name in &parsed.bindings {
        let value = values
            .get(name)
            .ok_or_else(|| crate::tr!("No value for parameter {name}").replace("{name}", name))?;
        bound.push(value.clone());
    }
    Ok(BoundStatement {
        sql: parsed.sql,
        values: bound,
    })
}

pub fn collect_values(entries: &[(String, ParameterKind, String)]) -> Result<HashMap<String, Value>, String> {
    let mut out = HashMap::with_capacity(entries.len());
    for (name, kind, text) in entries {
        let value = parse_parameter_value(*kind, text).map_err(|reason| {
            crate::tr!("{name}: {reason}")
                .replace("{name}", name)
                .replace("{reason}", &reason)
        })?;
        out.insert(name.clone(), value);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn a_missing_value_is_reported_instead_of_being_interpolated() {
        let error = bind_statement("SELECT :missing", "postgres", &HashMap::new()).expect_err("missing value");
        assert!(error.contains("missing"), "unexpected error: {error}");
    }

    #[test]
    fn statements_without_parameters_bind_nothing() {
        let bound = bind_statement("SELECT 1", "postgres", &HashMap::new()).expect("bind");
        assert_eq!(bound.sql, "SELECT 1");
        assert!(bound.values.is_empty());
    }

    #[test]
    fn collected_values_report_the_offending_parameter() {
        let entries = vec![("count".to_string(), ParameterKind::Integer, "twelve".to_string())];
        let error = collect_values(&entries).expect_err("invalid integer");
        assert!(error.starts_with("count:"), "unexpected error: {error}");
    }

    #[test]
    fn collected_values_keep_sql_text_as_data() {
        let entries = vec![(
            "name".to_string(),
            ParameterKind::Auto,
            "'; DROP TABLE users; --".to_string(),
        )];
        let values = collect_values(&entries).expect("collect");
        assert_eq!(values.get("name"), Some(&Value::Text("'; DROP TABLE users; --".into())));
    }

    #[test]
    fn names_are_reported_in_first_appearance_order() {
        assert_eq!(
            statement_names("SELECT :b, :a, :b FROM t", "postgres"),
            vec!["b".to_string(), "a".to_string()]
        );
    }
}
