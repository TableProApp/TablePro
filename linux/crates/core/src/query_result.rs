use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

/// What a query returned.
///
/// The columns are shared rather than cloned: every cell renderer and
/// every exporter reads the same slice, and a wide result is copied
/// once however many views look at it.
#[derive(Debug, Clone)]
pub struct QueryResult {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<Vec<Value>>,
    /// The driver stopped at the row limit, so the user is looking at
    /// a prefix and the status line has to say so.
    pub truncated: bool,
}

impl QueryResult {
    pub fn new(columns: impl Into<Arc<[ResultColumn]>>, rows: Vec<Vec<Value>>) -> Self {
        Self {
            columns: columns.into(),
            rows,
            truncated: false,
        }
    }

    pub fn empty() -> Self {
        Self {
            columns: Arc::from([]),
            rows: Vec::new(),
            truncated: false,
        }
    }

    pub fn truncated(mut self, truncated: bool) -> Self {
        self.truncated = truncated;
        self
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    /// The value at a position, or `None` past the end. Ragged rows
    /// are a driver bug, so this reports rather than panicking.
    pub fn cell(&self, row: usize, column: usize) -> Option<&Value> {
        self.rows.get(row)?.get(column)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{CatalogType, ColumnKind, ColumnType, IntegerKind, ReadForm, SqlTypeExpr};

    fn columns() -> Vec<ResultColumn> {
        vec![ResultColumn::new(
            "id",
            ColumnType::new(
                SqlTypeExpr::from_catalog_text("integer"),
                ColumnKind::Integer(IntegerKind::I32),
                CatalogType::Oid(23),
                false,
                ReadForm::Native,
            ),
        )]
    }

    #[test]
    fn a_result_reports_its_shape() {
        let result = QueryResult::new(columns(), vec![vec![Value::Int(1)], vec![Value::Int(2)]]);

        assert_eq!(result.row_count(), 2);
        assert_eq!(result.columns.len(), 1);
        assert_eq!(result.cell(1, 0), Some(&Value::Int(2)));
        assert_eq!(result.cell(2, 0), None);
        assert_eq!(result.cell(0, 1), None);
        assert!(!result.truncated);
    }

    #[test]
    fn cloning_a_result_shares_its_columns() {
        let result = QueryResult::new(columns(), Vec::new());

        let copy = result.clone();

        assert!(Arc::ptr_eq(&result.columns, &copy.columns));
    }

    #[test]
    fn an_empty_result_has_no_columns() {
        let empty = QueryResult::empty();

        assert_eq!(empty.row_count(), 0);
        assert!(empty.columns.is_empty());
    }
}
