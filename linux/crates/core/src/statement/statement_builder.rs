use crate::dialect::{BindError, BindTarget, SqlDialect};
use crate::value::Value;

use super::{BoundParam, Statement};

/// Builds SQL and its parameter list side by side.
///
/// Every value reaches the statement through the dialect's
/// `placeholder`, called with the number of parameters already held,
/// so the marker the SQL names and the position in the list cannot
/// disagree. This is the only way core binds a value.
#[derive(Debug, Default)]
pub struct StatementBuilder {
    sql: String,
    params: Vec<BoundParam>,
}

impl StatementBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append SQL the app itself wrote. Nothing from the user reaches
    /// this: values go through `push_value`, and identifiers through
    /// the dialect's quoting.
    pub fn push_sql(&mut self, sql: &str) {
        self.sql.push_str(sql);
    }

    /// Append one value's marker and record its parameter.
    pub fn push_value(
        &mut self,
        dialect: &dyn SqlDialect,
        value: Value,
        target: BindTarget<'_>,
    ) -> Result<(), BindError> {
        let marker = self.bind(dialect, value, target)?;
        self.sql.push_str(&marker);
        Ok(())
    }

    /// Record one value's parameter and return its marker without
    /// appending it, for a caller that hands the marker to a dialect
    /// template. Markers have to reach the finished SQL in the order
    /// they were bound.
    pub fn bind(
        &mut self,
        dialect: &dyn SqlDialect,
        value: Value,
        target: BindTarget<'_>,
    ) -> Result<String, BindError> {
        let placeholder = dialect.placeholder(self.params.len(), value, target)?;
        if let Some(param) = placeholder.param {
            self.params.push(param);
        }
        Ok(placeholder.sql)
    }

    /// Take the SQL written so far and keep its parameters, so a
    /// fragment built here can be placed inside a dialect template.
    pub fn take_fragment(&mut self) -> String {
        std::mem::take(&mut self.sql)
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
    use crate::column::{
        CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm,
        SqlTypeExpr, TextLength,
    };
    use crate::dialect::{TestDialect, TestMarkers};

    use super::*;

    fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                name: "t".to_owned(),
                kind,
                catalog: Some(CatalogType {
                    declaration: SqlTypeExpr::from_catalog_text("Int32"),
                    cast_target: SqlTypeExpr::from_catalog_text("Int32"),
                }),
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn int() -> ColumnInfo {
        column(
            "a",
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true,
            }),
        )
    }

    fn text() -> ColumnInfo {
        column(
            "b",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        )
    }

    #[test]
    fn statement_builder_ordinals_are_continuous() {
        let dialect = TestDialect::exact();
        let (a, b) = (int(), text());
        let mut builder = StatementBuilder::new();
        builder.push_sql("SELECT * FROM t WHERE a = ");
        builder
            .push_value(&dialect, Value::Int(1), BindTarget::Column(&a))
            .expect("bind a");
        builder.push_sql(" AND b = ");
        builder
            .push_value(&dialect, Value::Text("x".to_owned()), BindTarget::Column(&b))
            .expect("bind b");
        builder.push_sql(" AND c = ");
        builder
            .push_value(&dialect, Value::Null, BindTarget::Column(&a))
            .expect("bind c");

        let statement = builder.finish();

        assert_eq!(statement.sql(), "SELECT * FROM t WHERE a = $1 AND b = $2 AND c = $3");
        assert_eq!(statement.params().len(), 3);
        assert_eq!(statement.params()[1].value(), &Value::Text("x".to_owned()));
    }

    #[test]
    fn a_wrapped_statement_keeps_every_marker_with_its_parameter() {
        let dialect = TestDialect::exact().with_markers(TestMarkers::Positional);
        let (a, b) = (int(), text());
        let mut builder = StatementBuilder::new();
        builder.push_sql("SELECT * FROM t WHERE a = ");
        builder
            .push_value(&dialect, Value::Int(1), BindTarget::Column(&a))
            .expect("bind a");
        builder.push_sql(" AND b = ");
        builder
            .push_value(&dialect, Value::Text("x".to_owned()), BindTarget::Column(&b))
            .expect("bind b");
        let statement = builder.finish();
        let params = statement.params().to_vec();

        let explained = statement.wrapped("EXPLAIN (FORMAT JSON) ", "");

        assert_eq!(
            explained.sql(),
            "EXPLAIN (FORMAT JSON) SELECT * FROM t WHERE a = ? AND b = ?"
        );
        assert_eq!(explained.params(), params.as_slice());
    }

    #[test]
    fn the_dialect_sees_the_count_already_bound() {
        let dialect = TestDialect::exact();
        let a = int();
        let mut builder = StatementBuilder::new();

        for value in 0..3 {
            builder
                .bind(&dialect, Value::Int(value), BindTarget::Column(&a))
                .expect("a bound value");
        }

        assert_eq!(dialect.ordinals(), vec![0, 1, 2], "an ordinal skipped or repeated");
    }

    #[test]
    fn named_server_parameters_take_the_index_of_their_parameter() {
        let dialect = TestDialect::exact().with_markers(TestMarkers::ServerNamed);
        let (a, b) = (int(), text());
        let mut builder = StatementBuilder::new();
        builder.push_sql("ALTER TABLE t UPDATE b = ");
        builder
            .push_value(&dialect, Value::Text("x".to_owned()), BindTarget::Column(&b))
            .expect("bind b");
        builder.push_sql(" WHERE a = ");
        builder
            .push_value(&dialect, Value::Int(7), BindTarget::Column(&a))
            .expect("bind a");

        let statement = builder.finish();

        assert_eq!(
            statement.sql(),
            "ALTER TABLE t UPDATE b = {p0:Int32} WHERE a = {p1:Int32}"
        );
        assert_eq!(statement.params()[1].value(), &Value::Int(7), "p1 is not params[1]");
    }

    #[test]
    fn a_refused_value_adds_neither_marker_nor_param() {
        let dialect = TestDialect::exact();
        let a = int();
        let mut builder = StatementBuilder::new();
        builder.push_sql("SELECT ");

        let error = builder
            .push_value(&dialect, Value::Text("nope".to_owned()), BindTarget::Column(&a))
            .expect_err("text for an integer");

        assert!(matches!(error, BindError::ValueTypeMismatch { .. }), "{error:?}");
        assert_eq!(builder.param_count(), 0);
        assert_eq!(
            builder.finish().sql(),
            "SELECT ",
            "a refused value still wrote a marker"
        );
    }

    #[test]
    fn a_fragment_keeps_its_parameters() {
        let dialect = TestDialect::exact();
        let a = int();
        let mut builder = StatementBuilder::new();
        builder
            .push_value(&dialect, Value::Int(1), BindTarget::Column(&a))
            .expect("bind");

        let fragment = builder.take_fragment();
        builder.push_sql(&format!("WHERE a = {fragment}"));

        let statement = builder.finish();
        assert_eq!(statement.sql(), "WHERE a = $1");
        assert_eq!(statement.params().len(), 1);
    }
}
