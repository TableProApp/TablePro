use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::{UserSql, Value};

use super::ResultSummary;

/// One result set of an editor run, with the statement that produced
/// it. The grid that shows it shares each row, so a page built again
/// for the same result copies no cell.
#[derive(Debug, Clone)]
pub struct ResultSetView {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<Arc<[Value]>>,
    pub summary: ResultSummary,
    /// The batch the result came from, which Export All runs again.
    pub statement: UserSql,
}

impl ResultSetView {
    pub(crate) fn new(columns: Arc<[ResultColumn]>, statement: UserSql) -> Self {
        Self {
            columns,
            rows: Vec::new(),
            summary: ResultSummary::complete(0),
            statement,
        }
    }

    pub(crate) fn row_count(&self) -> usize {
        self.rows.len()
    }
}
