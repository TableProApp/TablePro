use thiserror::Error;

use crate::ddl::BuildDdlError;
use crate::dialect::BindError;

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
    Ddl(#[source] Box<BuildDdlError>),
}

impl From<BuildDdlError> for SqlBuildError {
    fn from(error: BuildDdlError) -> Self {
        Self::Ddl(Box::new(error))
    }
}
