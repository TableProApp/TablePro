use crate::value::SqlDecimal;

/// A literal the app can bind, extracted from a parsed expression.
///
/// Anything else, a function call for instance, has no literal: only the
/// server can evaluate it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiteralToken {
    Text(String),
    Number(SqlDecimal),
    Boolean(bool),
    Null,
}
