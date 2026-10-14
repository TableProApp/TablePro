use std::sync::Arc;

use tablepro_core::column::ResultColumn;

use crate::ui::grid::RowSnapshot;

/// Where an export reads its rows.
#[derive(Debug, Clone)]
pub enum ExportSource {
    /// The rows a grid showed when the user asked, pending edits
    /// included. They share the cells the grid holds rather than copy
    /// them.
    Rows {
        columns: Arc<[ResultColumn]>,
        rows: Vec<RowSnapshot>,
    },
}

impl ExportSource {
    pub fn row_count(&self) -> usize {
        match self {
            Self::Rows { rows, .. } => rows.len(),
        }
    }
}
