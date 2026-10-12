use thiserror::Error;

use crate::dialect::BindError;
use crate::dml::BuildSqlError;
use crate::filter::BuildFilterError;

use super::PagingMode;

/// Why a page could not be built or read back.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BrowseSqlError {
    #[error("the table has no columns to select")]
    NoColumns,
    #[error("the sort names column {0}, which the table does not have")]
    UnknownSortColumn(usize),
    #[error("this page position cannot be read when paging by {mode:?}")]
    UnsupportedPosition { mode: PagingMode },
    #[error("the row to page from has a NULL key, which no row compares past")]
    NullAnchor,
    #[error("the page returned {found} columns but the query asked for {expected}")]
    ShapeMismatch { expected: usize, found: usize },
    #[error(transparent)]
    Filter(#[from] BuildFilterError),
    #[error(transparent)]
    Build(#[from] BuildSqlError),
    #[error(transparent)]
    Bind(#[from] BindError),
}
