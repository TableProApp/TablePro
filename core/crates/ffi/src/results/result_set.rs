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
pub struct CellTextHead {
    pub text: String,
    pub cut: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellBytes {
    pub bytes: Vec<u8>,
    pub length: u64,
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

    pub(crate) fn result_columns(&self) -> Arc<[tablepro_core::column::ResultColumn]> {
        self.store.columns()
    }

    pub(crate) fn extent(&self) -> tablepro_core::export::ResultExtent {
        self.store.extent()
    }

    pub(crate) fn stored_value(&self, row: u64, column: usize) -> Option<tablepro_core::Value> {
        self.store.stored_value(self.stored_row(row), column)
    }

    pub(crate) fn cell_kind(&self, row: u64, column: usize) -> Option<Option<ValueKind>> {
        self.store.cell_kind(self.stored_row(row), column)
    }

    pub(crate) fn full_text(&self, row: u64, column: usize) -> Option<Option<String>> {
        self.store.full_text(self.stored_row(row), column)
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

    // A value's start for a viewer, read without copying the rest: its text with line breaks kept, or a binary
    // value's hex. `None` for null.
    pub fn cell_text_head(&self, row: u64, column: u32, max_chars: u32) -> Result<Option<CellTextHead>, CoreError> {
        let max_chars = usize::try_from(max_chars).unwrap_or(usize::MAX);
        usize::try_from(column)
            .ok()
            .and_then(|column| self.store.text_head(self.stored_row(row), column, max_chars))
            .map(|head| head.map(|(text, cut)| CellTextHead { text, cut }))
            .ok_or_else(|| CoreError::failed("ffi.out_of_range", format!("no cell at row {row}, column {column}")))
    }

    // A binary value's first `max_bytes` and its whole length, for an image or a hex view; `None` for null or a
    // value that is not binary.
    pub fn cell_bytes(&self, row: u64, column: u32, max_bytes: u64) -> Result<Option<CellBytes>, CoreError> {
        let max_bytes = usize::try_from(max_bytes).unwrap_or(usize::MAX);
        usize::try_from(column)
            .ok()
            .and_then(|column| self.store.binary(self.stored_row(row), column, max_bytes))
            .map(|binary| binary.map(|(bytes, length)| CellBytes { bytes, length }))
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
