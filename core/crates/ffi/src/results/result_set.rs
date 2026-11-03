use std::sync::Arc;

use super::{Cursor, ResultStore, ValueKind};
use crate::error::CoreError;
use crate::window_abi::TpCursor;

// One result set of a run, readable while its rows still arrive. A sorted set reads the same rows through an order.
#[derive(Debug, uniffi::Object)]
pub struct ResultSet {
    index: u32,
    store: Arc<ResultStore>,
    order: Option<Arc<[u64]>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ResultColumnInfo {
    pub name: String,
    pub type_name: String,
    pub value_kind: ValueKind,
}

impl ResultSet {
    pub(crate) fn new(index: u32, store: Arc<ResultStore>) -> Self {
        Self {
            index,
            store,
            order: None,
        }
    }

    fn stored_row(&self, row: u64) -> u64 {
        self.order
            .as_ref()
            .and_then(|order| order.get(usize::try_from(row).ok()?).copied())
            .unwrap_or(row)
    }
}

#[uniffi::export]
impl ResultSet {
    /// Its place among the run's result sets, from 0.
    pub fn index(&self) -> u32 {
        self.index
    }

    pub fn row_count(&self) -> u64 {
        self.store.row_count()
    }

    /// True once every row the set will hold is here.
    pub fn is_finished(&self) -> bool {
        self.store.is_finished()
    }

    pub fn columns(&self) -> Vec<ResultColumnInfo> {
        self.store.columns().iter().map(ResultColumnInfo::from).collect()
    }

    // The whole value, `None` for null.
    pub fn cell_text(&self, row: u64, column: u32) -> Result<Option<String>, CoreError> {
        usize::try_from(column)
            .ok()
            .and_then(|column| self.store.full_text(self.stored_row(row), column))
            .ok_or_else(|| CoreError::failed("ffi.out_of_range", format!("no cell at row {row}, column {column}")))
    }

    // An address the caller frees with `tablepro_cursor_free`.
    pub fn open_cursor(&self) -> u64 {
        let cursor = Box::into_raw(Box::new(TpCursor::new(Cursor::new(
            self.store.clone(),
            self.order.clone(),
        ))));
        cursor.expose_provenance() as u64
    }

    // For a result whose statement cannot run again for a sort: the rows held now, ties in their arrival order.
    pub fn sorted(&self, column: u32, ascending: bool) -> Result<Arc<ResultSet>, CoreError> {
        let order = usize::try_from(column)
            .ok()
            .and_then(|index| self.store.row_order(index, ascending))
            .ok_or_else(|| CoreError::failed("ffi.out_of_range", format!("no column {column}")))?;
        Ok(Arc::new(Self {
            index: self.index,
            store: self.store.clone(),
            order: Some(order.into()),
        }))
    }
}

impl From<&tablepro_core::column::ResultColumn> for ResultColumnInfo {
    fn from(column: &tablepro_core::column::ResultColumn) -> Self {
        Self {
            name: column.name.clone(),
            type_name: column.column_type.name.clone(),
            value_kind: ValueKind::of_column(&column.column_type.kind),
        }
    }
}
