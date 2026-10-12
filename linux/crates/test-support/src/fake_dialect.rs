use tablepro_core::column::{ColumnType, SqlExpression};
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LiteralError, Placeholder, SqlDialect,
};
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::Value;

/// A plain ANSI dialect with numbered markers, for code that needs a
/// connection's dialect but not any one engine's spelling.
#[derive(Debug, Clone, Copy, Default)]
pub struct FakeDialect;

impl SqlDialect for FakeDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities { exact_row_counts: true }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::PostgreSql
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    fn placeholder(&self, ordinal: usize, value: Value, _target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let param_type = param_type_of(&value);
        let param = BoundParam::new(value, param_type)?;
        Ok(Placeholder::bound(format!("${}", ordinal + 1), param))
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
        text.replace('!', "!!").replace('%', "!%").replace('_', "!_")
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
        let parsed = parse_type(SqlGrammar::PostgreSql, text, MAX_TYPE_LEN)?;
        Ok(ColumnType::untyped_text(parsed.text))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::PostgreSql, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }
}

/// The parameter type that carries a value as it is, so a fake bind
/// never fails on a type the test did not mean to check.
fn param_type_of(value: &Value) -> ParamType {
    match value {
        Value::Bool(_) => ParamType::Bool,
        Value::Int(_) => ParamType::Int64,
        Value::UInt(_) => ParamType::UInt64,
        Value::Float32(_) => ParamType::Float32,
        Value::Float64(_) => ParamType::Float64,
        Value::Decimal(_) | Value::WideInt(_) => ParamType::Decimal,
        Value::Bytes(_) | Value::Bits(_) => ParamType::Bytes,
        Value::Uuid(_) => ParamType::Uuid,
        Value::Json(_) => ParamType::Json,
        Value::Date(_) => ParamType::Date,
        Value::Time(_) => ParamType::Time,
        Value::TimeTz(_) => ParamType::TimeTz,
        Value::Timestamp(_) => ParamType::Timestamp,
        Value::TimestampTz(_) => ParamType::TimestampTz,
        Value::Interval(_) => ParamType::Interval,
        _ => ParamType::Text,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;

    use super::*;

    #[test]
    fn markers_count_from_the_parameters_already_bound() {
        let placeholder = FakeDialect.placeholder(2, Value::Int(7), BindTarget::Pattern).unwrap();

        assert_eq!(placeholder.sql, "$3");
        assert_eq!(
            placeholder.param.map(|param| param.value().clone()),
            Some(Value::Int(7))
        );
    }

    #[test]
    fn identifiers_are_quoted_and_qualified() {
        let table = TableRef::new(Some("public".to_owned()), "odd\"name");

        assert_eq!(FakeDialect.qualify(&table), "\"public\".\"odd\"\"name\"");
    }
}
