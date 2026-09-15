use thiserror::Error;

use crate::dml::BuildSqlError;

/// Why a page could not be built or read back.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BrowseSqlError {
    #[error("the page returned {found} columns but the query asked for {expected}")]
    ShapeMismatch { expected: usize, found: usize },
    #[error(transparent)]
    Build(#[from] BuildSqlError),
}
