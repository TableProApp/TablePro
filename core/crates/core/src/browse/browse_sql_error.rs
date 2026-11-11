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

impl BrowseSqlError {
    // Stable across releases, for an app outside Rust that words the error itself.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NoColumns => "browse.no_columns",
            Self::UnknownSortColumn(_) => "browse.unknown_sort_column",
            Self::UnsupportedPosition { .. } => "browse.unsupported_position",
            Self::SortUnsupported => "browse.sort_unsupported",
            Self::StalePagingState => "browse.stale_paging_state",
            Self::NullAnchor => "browse.null_anchor",
            Self::UnreadableAnchor => "browse.unreadable_anchor",
            Self::ShapeMismatch { .. } => "browse.shape_mismatch",
            Self::Filter(_) => "browse.filter",
            Self::Build(_) => "browse.build",
            Self::Bind(_) => "browse.bind",
        }
    }

    // Outermost first, down to the filter's or the statement builder's own code.
    pub fn codes(&self) -> Vec<&'static str> {
        let mut codes = vec![self.code()];
        match self {
            Self::Filter(filter) => codes.extend(filter.codes()),
            Self::Build(build) => codes.push(build.code()),
            _ => {}
        }
        codes
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::EditParseError;

    #[test]
    fn a_refused_filter_value_names_the_page_the_filter_and_the_parse() {
        let error = BrowseSqlError::Filter(BuildFilterError::Parse {
            column: "id".to_owned(),
            source: EditParseError::InvalidInteger,
        });

        assert_eq!(error.codes(), ["browse.filter", "filter.parse", "edit.invalid_integer"]);
    }
}
