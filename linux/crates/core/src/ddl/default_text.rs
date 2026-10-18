use crate::column::{ColumnDefault, ColumnType};
use crate::dialect::SqlDialect;
use crate::edit::parse_literal_text;
use crate::sql_syntax::{ExpressionSyntaxError, LiteralToken, MAX_EXPRESSION_LEN, parse_expression};
use crate::value::Value;

/// A default as the structure tab shows it: SQL the user could type
/// back in.
pub fn default_text(dialect: &dyn SqlDialect, default: &ColumnDefault, column_type: &ColumnType) -> String {
    match default {
        ColumnDefault::None => String::new(),
        ColumnDefault::Literal(value) => dialect
            .literal(value, column_type)
            .ok()
            .or_else(|| crate::export::value_to_text(value))
            .unwrap_or_default(),
        ColumnDefault::Expression(expression) => expression.as_sql().to_owned(),
    }
}

/// SQL the user typed as a default, accepted only when the engine's
/// parser reads it as one expression. A plain literal becomes a value,
/// so the plan writes it back in the dialect's own literal form, as it
/// does a literal the catalogue reported.
pub fn parse_default(
    dialect: &dyn SqlDialect,
    text: &str,
    column_type: &ColumnType,
) -> Result<ColumnDefault, ExpressionSyntaxError> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(ColumnDefault::None);
    }
    let expression = dialect.parse_expression(text)?;
    let literal = parse_expression(dialect.grammar(), text, MAX_EXPRESSION_LEN)
        .ok()
        .and_then(|parsed| parsed.literal);
    let literal_text = match literal {
        None => return Ok(ColumnDefault::Expression(expression)),
        Some(LiteralToken::Null) => return Ok(ColumnDefault::None),
        Some(LiteralToken::Text(text)) => text,
        Some(LiteralToken::Number(number)) => number.to_string(),
        Some(LiteralToken::Boolean(flag)) => flag.to_string(),
    };
    match parse_literal_text(&literal_text, column_type) {
        Ok(Value::Null) | Err(_) => Ok(ColumnDefault::Expression(expression)),
        Ok(value) => Ok(ColumnDefault::Literal(value)),
    }
}
