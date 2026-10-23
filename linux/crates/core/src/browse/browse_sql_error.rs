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
    /// The engine pages on the server, in its own order, which no
    /// ORDER BY can change.
    #[error("this engine reads a table only in its own order")]
    SortUnsupported,
    /// The paging state came from another statement than the page's,
    /// so resuming from it would read rows from the wrong place.
    #[error("the paging state belongs to another statement")]
    StalePagingState,
    #[error("the row to page from has a NULL key, which no row compares past")]
    NullAnchor,
    #[error("the row to page from has no row address that can be read")]
    UnreadableAnchor,
    #[error("the page returned {found} columns but the query asked for {expected}")]
    ShapeMismatch { expected: usize, found: usize },
    #[error(transparent)]
    Filter(#[from] BuildFilterError),
    #[error(transparent)]
    Build(#[from] BuildSqlError),
    #[error(transparent)]
    Bind(#[from] BindError),
}
