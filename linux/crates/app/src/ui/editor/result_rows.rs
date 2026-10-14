use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;

/// A result set as the results list keeps it. The grid that shows it
/// shares each row, so a page built again for the same result copies no
/// cell.
#[derive(Debug, Clone)]
pub struct ResultRows {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<Arc<[Value]>>,
    /// The driver stopped at the row limit.
    pub truncated: bool,
}

impl ResultRows {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self {
            columns,
            rows: Vec::new(),
            truncated: false,
        }
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }
}
