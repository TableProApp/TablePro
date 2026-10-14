use std::sync::Arc;

use tablepro_core::column::ResultColumn;

use super::RowObject;

/// What a grid is built to show: the result's columns and its rows,
/// which the grid's store then owns.
#[derive(Debug, Clone)]
pub struct GridContent {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<RowObject>,
    /// From the read that filled the grid, so Export Results reports the
    /// same cut the footer does.
    pub truncated: bool,
}
