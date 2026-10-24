use std::sync::Arc;

use crate::query_result::QueryResult;
use crate::row_limit::RowLimit;

/// One page of a read the server pages itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerPageRequest {
    /// The paging state the server handed back with the page before, or
    /// `None` to start from the first row.
    pub resume: Option<Arc<[u8]>>,
    /// Rows to read past before the page starts, counted but never kept.
    pub skip: u64,
    pub limit: RowLimit,
}

/// A page and where the server would resume after its last row.
#[derive(Debug, Clone)]
pub struct ServerPage {
    pub result: QueryResult,
    /// `None` once the server says no rows follow.
    pub next: Option<Arc<[u8]>>,
}
