use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_session::Session;

use super::ExportQuery;
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
    /// A read streamed from the server through `session`, every row of
    /// it.
    Query { session: Arc<Session>, query: ExportQuery },
}

impl ExportSource {
    /// The rows it holds. `None` for a read, whose count only the
    /// server knows.
    pub fn row_count(&self) -> Option<usize> {
        match self {
            Self::Rows { rows, .. } => Some(rows.len()),
            Self::Query { .. } => None,
        }
    }
}
