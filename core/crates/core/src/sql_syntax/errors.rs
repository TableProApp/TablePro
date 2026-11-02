use thiserror::Error;

/// Why a user-typed SQL type was refused.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TypeSyntaxError {
    #[error("the type is empty")]
    Empty,
    #[error("the type is longer than {max} characters")]
    TooLong { max: usize },
    #[error("the type contains a comment")]
    Comment,
    /// The engine's parser does not read the whole text as one type.
    /// sqlparser's own message is English only, so none is kept.
    #[error("the type is not valid for this engine")]
    Invalid,
    /// MySQL and PostgreSQL read a backslash differently depending on a
    /// session setting, so text containing one cannot be validated here.
    #[error("the value contains a backslash, which this engine reads differently per session")]
    SessionDependentBackslash,
}

/// Why a user-typed SQL expression was refused.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ExpressionSyntaxError {
    #[error("the expression is empty")]
    Empty,
    #[error("the expression is longer than {max} characters")]
    TooLong { max: usize },
    #[error("the expression contains a comment")]
    Comment,
    /// The engine's parser does not read the whole text as one
    /// expression.
    #[error("the expression is not valid for this engine")]
    Invalid,
    #[error("the value contains a backslash, which this engine reads differently per session")]
    SessionDependentBackslash,
}
