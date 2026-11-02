use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

/// A page of rows, with the key that names each one.
///
/// The columns and rows hold only what the user asked for: any hidden
/// row-id column the query projected has already been taken out, so it
/// cannot reach the grid, an export, a copy or an insert preview.
#[derive(Debug, Clone)]
pub struct BrowsePage {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<Vec<Value>>,
    /// One per row, in the same order. `None` means the row cannot be
    /// edited: the table has no key, or part of this row's key could
    /// not be read.
    pub keys: Vec<Option<Vec<Value>>>,
    pub truncated: bool,
}

impl BrowsePage {
    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn key(&self, row: usize) -> Option<&Vec<Value>> {
        self.keys.get(row)?.as_ref()
    }

    /// Whether any row on this page can be changed.
    pub fn has_editable_rows(&self) -> bool {
        self.keys.iter().any(Option::is_some)
    }
}
