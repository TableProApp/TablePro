use crate::value::Value;

use super::SqlExpression;

/// A column's DEFAULT clause.
///
/// A literal is kept as a `Value` so the insert path can bind it, while
/// an expression such as `now()` stays as text because only the server
/// can evaluate it.
#[derive(Debug, Clone, PartialEq)]
pub enum ColumnDefault {
    None,
    Literal(Value),
    Expression(SqlExpression),
}

impl ColumnDefault {
    pub fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }

    /// Whether the server has to evaluate the default, which means an
    /// insert must omit the column rather than bind a value.
    pub fn needs_server_evaluation(&self) -> bool {
        matches!(self, Self::Expression(_))
    }

    pub fn literal(&self) -> Option<&Value> {
        match self {
            Self::Literal(value) => Some(value),
            _ => None,
        }
    }
}
