use crate::dialect::BindError;
use crate::value::Value;

use super::{BoundParam, ParamType, Statement};

/// Builds SQL and its parameter list side by side.
///
/// A value is never written into the text: `push_value` appends the
/// dialect's placeholder and the parameter at the same time, so the
/// ordinal the SQL names and the position in the list cannot disagree.
#[derive(Debug, Default)]
pub struct StatementBuilder {
    sql: String,
    params: Vec<BoundParam>,
}

/// How a dialect spells the placeholder for the next parameter.
///
/// PostgreSQL numbers them, MySQL and SQLite do not, and a server type
/// needs a cast around the marker so text arrives as the right thing.
pub trait PlaceholderStyle {
    /// The marker for the parameter at `ordinal`, counting from 1.
    fn placeholder(&self, ordinal: usize, param_type: &ParamType) -> String;
}

impl StatementBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append SQL the app itself wrote. Nothing from the user reaches
    /// this: values go through `push_value`, and identifiers through
    /// the dialect's quoting.
    pub fn push_sql(&mut self, sql: &str) -> &mut Self {
        self.sql.push_str(sql);
        self
    }

    /// Append one parameter and the placeholder that names it.
    pub fn push_value(
        &mut self,
        style: &dyn PlaceholderStyle,
        value: Value,
        param_type: ParamType,
    ) -> Result<&mut Self, BindError> {
        let bound = BoundParam::new(value, param_type)?;
        // Ordinals count from 1 and are handed out in the order the
        // markers appear, so the list position is the ordinal.
        let ordinal = self.params.len() + 1;
        self.sql.push_str(&style.placeholder(ordinal, bound.param_type()));
        self.params.push(bound);
        Ok(self)
    }

    pub fn param_count(&self) -> usize {
        self.params.len()
    }

    pub fn finish(self) -> Statement {
        Statement::new(self.sql, self.params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PostgreSQL's numbered markers, which is the style that can
    /// actually disagree with the list.
    struct Numbered;

    impl PlaceholderStyle for Numbered {
        fn placeholder(&self, ordinal: usize, param_type: &ParamType) -> String {
            match param_type {
                ParamType::ServerText(name) => format!("${ordinal}::{}", name.as_sql()),
                _ => format!("${ordinal}"),
            }
        }
    }

    #[test]
    fn statement_builder_ordinals_are_continuous() {
        let mut builder = StatementBuilder::new();
        builder.push_sql("SELECT * FROM t WHERE a = ");
        builder
            .push_value(&Numbered, Value::Int(1), ParamType::Int64)
            .expect("bind a");
        builder.push_sql(" AND b = ");
        builder
            .push_value(&Numbered, Value::Text("x".to_owned()), ParamType::Text)
            .expect("bind b");
        builder.push_sql(" AND c = ");
        builder
            .push_value(&Numbered, Value::Null, ParamType::Uuid)
            .expect("bind c");

        let statement = builder.finish();

        assert_eq!(statement.sql(), "SELECT * FROM t WHERE a = $1 AND b = $2 AND c = $3");
        assert_eq!(statement.params().len(), 3);
        assert_eq!(statement.params()[1].value(), &Value::Text("x".to_owned()));
    }

    #[test]
    fn a_server_type_casts_its_marker() {
        let mut builder = StatementBuilder::new();
        builder.push_sql("INSERT INTO t VALUES (");
        builder
            .push_value(
                &Numbered,
                Value::Text("happy".to_owned()),
                ParamType::ServerText(crate::column::SqlTypeExpr::from_catalog_text("mood")),
            )
            .expect("bind the enum");
        builder.push_sql(")");

        assert_eq!(builder.finish().sql(), "INSERT INTO t VALUES ($1::mood)");
    }

    #[test]
    fn a_refused_value_adds_neither_marker_nor_param() {
        let mut builder = StatementBuilder::new();
        builder.push_sql("SELECT ");

        let error = builder
            .push_value(&Numbered, Value::Text("nope".to_owned()), ParamType::Uuid)
            .expect_err("text for a uuid");

        assert!(matches!(error, BindError::ValueTypeMismatch { .. }), "{error:?}");
        assert_eq!(builder.param_count(), 0);
        assert_eq!(
            builder.finish().sql(),
            "SELECT ",
            "a refused value still wrote a marker"
        );
    }
}
