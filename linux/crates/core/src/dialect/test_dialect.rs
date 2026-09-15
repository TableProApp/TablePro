use crate::column::{ColumnInfo, ColumnType, SqlExpression, SqlTypeExpr};
use crate::meta::{EngineRowId, EngineRowIdPart};
use crate::sql_syntax::{ExpressionSyntaxError, SqlGrammar, TypeSyntaxError, parse_expression, parse_type};
use crate::statement::{BoundParam, ParamType};
use crate::value::Value;

use super::{BindError, BindTarget, DialectCapabilities, KeysetDirection, LiteralError, Placeholder, SqlDialect};

/// A plain ANSI dialect, for the core builders' own tests.
///
/// It numbers its placeholders, because that is the style whose
/// ordinals can actually disagree with the parameter list, and records
/// nothing: a test that needs to see what was bound reads the
/// statement's parameters.
#[derive(Debug, Default)]
pub struct TestDialect {
    pub exact_row_counts: bool,
}

impl TestDialect {
    pub fn exact() -> Self {
        Self { exact_row_counts: true }
    }
}

impl SqlDialect for TestDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities {
            exact_row_counts: self.exact_row_counts,
        }
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let param_type = match target {
            BindTarget::Pattern => ParamType::Text,
            BindTarget::EngineRowId(_) => ParamType::Text,
            BindTarget::Column(column) => param_type_for(column),
        };
        let param = BoundParam::new(value, param_type)?;
        Ok(Placeholder::bound(format!("${ordinal}"), param))
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        match value {
            Value::Null => Ok("NULL".to_owned()),
            Value::Bool(flag) => Ok(flag.to_string()),
            Value::Int(number) => Ok(number.to_string()),
            Value::UInt(number) => Ok(number.to_string()),
            Value::Text(text) => Ok(format!("'{}'", text.replace('\'', "''"))),
            Value::Undecodable(undecodable) => Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            }),
            other => Err(LiteralError::Unrepresentable {
                found: other.variant_name(),
            }),
        }
    }

    fn escape_like_text(&self, text: &str) -> String {
        text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
    }

    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        let order = order_by.map(|order| format!(" ORDER BY {order}")).unwrap_or_default();
        match offset {
            0 => format!("{order} LIMIT {limit}"),
            _ => format!("{order} LIMIT {limit} OFFSET {offset}"),
        }
    }

    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
        format!(
            "({}) {} ({})",
            key_sql.join(", "),
            direction.comparison(),
            markers.join(", ")
        )
    }

    fn engine_row_id(&self, _id: EngineRowId) -> Option<String> {
        None
    }

    fn engine_row_id_column(&self, _part: EngineRowIdPart) -> Option<String> {
        None
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(SqlGrammar::PostgreSql, text, crate::sql_syntax::MAX_TYPE_LEN)?;
        Ok(ColumnType::untyped_text(SqlTypeExpr::from_catalog_text(parsed.text)))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::PostgreSql, text, crate::sql_syntax::MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }
}

/// The parameter type a column takes, reduced to what the tests need.
fn param_type_for(column: &ColumnInfo) -> ParamType {
    use crate::column::{ColumnKind, FloatKind, IntegerKind};

    match column.column_type.kind() {
        ColumnKind::Boolean => ParamType::Bool,
        ColumnKind::Integer(IntegerKind::I16 | IntegerKind::U8 | IntegerKind::I8) => ParamType::Int16,
        ColumnKind::Integer(IntegerKind::I32 | IntegerKind::U16) => ParamType::Int32,
        ColumnKind::Integer(IntegerKind::U64 | IntegerKind::U128) => ParamType::UInt64,
        ColumnKind::Integer(_) => ParamType::Int64,
        ColumnKind::Decimal => ParamType::Decimal,
        ColumnKind::Float(FloatKind::F32) => ParamType::Float32,
        ColumnKind::Float(FloatKind::F64) => ParamType::Float64,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Json => ParamType::Json,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time => ParamType::Time,
        ColumnKind::Timestamp => ParamType::Timestamp,
        ColumnKind::Interval => ParamType::Interval,
        ColumnKind::Binary | ColumnKind::BitString => ParamType::Bytes,
        _ => ParamType::Text,
    }
}
