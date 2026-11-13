use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::masking::{ColumnMasks, MaskingStyle};

use super::{Cursor, ResultStore, ValueKind};
use crate::error::CoreError;
use crate::masking::MaskStyleTag;
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
    // The grid shows this column masked: its header is marked and its cells refuse an edit.
    pub masked: Option<MaskStyleTag>,
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

    pub(crate) fn shown_masks(&self) -> ColumnMasks {
        self.store.shown()
    }

    pub(crate) fn external_masks(&self, columns: &[ResultColumn]) -> ColumnMasks {
        self.store.external_masks(columns)
    }

    pub(crate) fn untraced_columns(&self, columns: &[ResultColumn]) -> Vec<usize> {
        self.store.external_untraced(columns)
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
        self.store.column_infos()
    }

    // After the connection's masking rules were saved: masks the held rows of every column the rules now mask, unless
    // the tab revealed this run, off the caller's thread; windows keep reading meanwhile. True when a column changed, so
    // the grid draws again and reads `columns`. Rows that arrive after a save are masked without it.
    pub async fn remask(self: Arc<Self>) -> Result<bool, CoreError> {
        let tasks = crate::runtime::tasks()?;
        let blocking = tasks.clone();
        let store = self.store.clone();
        crate::runtime::on_runtime(&tasks, async move {
            blocking
                .spawn_blocking_task(move || store.remask())
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))
        })
        .await
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

impl ResultColumnInfo {
    pub(crate) fn of(column: &ResultColumn, masked: Option<MaskingStyle>) -> Self {
        Self {
            name: column.name.clone(),
            type_name: column.column_type.name.clone(),
            value_kind: ValueKind::of_column(&column.column_type.kind),
            masked: masked.map(MaskStyleTag::from),
        }
    }
}
