use thiserror::Error;

use crate::dialect::BindError;
use crate::edit::EditParseError;
use crate::sql_syntax::ExpressionSyntaxError;

use super::FilterOp;

/// Why a filter could not be written as SQL.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BuildFilterError {
    #[error("filter rule references unknown column: {0}")]
    UnknownColumn(String),
    #[error("operator {0:?} requires a value")]
    MissingValue(FilterOp),
    #[error("BETWEEN requires both bounds")]
    BetweenMissingBound,
    #[error("IN list cannot be empty")]
    EmptyInList,
    #[error("operator {op:?} cannot use the supplied value shape")]
    WrongValueShape { op: FilterOp },
    #[error("rule on column {column}: {source}")]
    Parse {
        column: String,
        #[source]
        source: EditParseError,
    },
    #[error(transparent)]
    Bind(#[from] BindError),
    #[error("operator {op:?} does not apply to column {column}")]
    OperatorNotAllowed { column: String, op: FilterOp },
    #[error("the SQL filter is not a single expression: {0}")]
    RawPredicate(#[source] ExpressionSyntaxError),
}
