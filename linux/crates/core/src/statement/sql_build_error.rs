use thiserror::Error;

use crate::dialect::{BindError, LiteralError};

/// Why SQL could not be built.
///
/// The three arms say which builder failed, because a browse filter, a
/// row edit and a DDL change fail for different reasons and the user
/// sees a different message for each.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SqlBuildError {
    #[error("this change could not be written as SQL: {0}")]
    Dml(#[source] BindError),
    #[error("this filter could not be written as SQL: {0}")]
    Browse(#[source] BindError),
    #[error("this schema change could not be written as SQL: {0}")]
    Ddl(String),
}

impl From<LiteralError> for SqlBuildError {
    fn from(error: LiteralError) -> Self {
        Self::Ddl(error.to_string())
    }
}
