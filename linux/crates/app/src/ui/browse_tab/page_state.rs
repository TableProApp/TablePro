use std::sync::Arc;

use tablepro_core::column::ResultColumn;

/// What the tab knows of the page on screen. Its rows are the grid's:
/// the store holds the only copy.
#[derive(Debug, Clone)]
pub(crate) struct PageState {
    /// The page's visible columns.
    pub result_columns: Arc<[ResultColumn]>,
    /// The server stopped at the row limit.
    pub truncated: bool,
    pub row_count: usize,
    /// How many rows of the table come before the page.
    pub start_ordinal: u64,
}
