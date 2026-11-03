use std::sync::{Arc, PoisonError, RwLock, RwLockReadGuard};

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::value::order::{row_order, sorts_as_text};

use super::column_cells::{Cell, ColumnCells, cell_value};
use super::{ValueKind, cell_text};

/// Rows per chunk. A full chunk is never written again, so an append
/// copies at most one chunk's arrays when they grow.
const CHUNK_ROWS: usize = 65_536;

/// One result set as it arrives: columnar chunks behind one lock, so a
/// window reads its rows and the row count from the same moment.
#[derive(Debug)]
pub(crate) struct ResultStore {
    state: RwLock<StoreState>,
}

#[derive(Debug)]
pub(super) struct StoreState {
    pub(super) columns: Arc<[ResultColumn]>,
    pub(super) kinds: Vec<ValueKind>,
    pub(super) chunks: Vec<Chunk>,
    pub(super) rows: u64,
    pub(super) finished: bool,
}

#[derive(Debug)]
pub(super) struct Chunk {
    pub(super) start: u64,
    pub(super) rows: usize,
    pub(super) columns: Vec<ColumnCells>,
}

impl ResultStore {
    pub(crate) fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self {
            state: RwLock::new(StoreState {
                kinds: kinds_of(&columns),
                columns,
                chunks: Vec::new(),
                rows: 0,
                finished: false,
            }),
        }
    }

    pub(super) fn read(&self) -> RwLockReadGuard<'_, StoreState> {
        self.state.read().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn columns(&self) -> Arc<[ResultColumn]> {
        self.read().columns.clone()
    }

    pub(crate) fn row_count(&self) -> u64 {
        self.read().rows
    }

    pub(crate) fn is_finished(&self) -> bool {
        self.read().finished
    }

    /// Columns a driver could type only once rows arrived. A set whose
    /// column count changes after its first row keeps the columns it had.
    pub(crate) fn resolve_columns(&self, columns: Arc<[ResultColumn]>) {
        let mut state = self.state.write().unwrap_or_else(PoisonError::into_inner);
        if columns.len() != state.columns.len() && state.rows > 0 {
            tracing::warn!(
                before = state.columns.len(),
                after = columns.len(),
                "a result set changed its column count after rows arrived"
            );
            return;
        }
        state.kinds = kinds_of(&columns);
        state.columns = columns;
    }

    /// Adds rows and returns the new row count. Values are formatted
    /// before the lock is taken, so a window never waits on that.
    pub(crate) fn append(&self, rows: &[Vec<Value>]) -> u64 {
        let columns = self.columns();
        let mut staged = vec![ColumnCells::default(); columns.len()];
        for row in rows {
            for (index, (cells, column)) in staged.iter_mut().zip(columns.iter()).enumerate() {
                cells.push(row.get(index).unwrap_or(&Value::Null), &column.column_type);
            }
        }
        let mut state = self.state.write().unwrap_or_else(PoisonError::into_inner);
        if state.columns.len() != staged.len() {
            tracing::warn!("rows arrived for columns the set no longer has");
            return state.rows;
        }
        let mut taken = 0;
        while taken < rows.len() {
            let start = state.rows;
            let width = staged.len();
            if state.chunks.last().is_none_or(|chunk| chunk.rows == CHUNK_ROWS) {
                state.chunks.push(Chunk {
                    start,
                    rows: 0,
                    columns: vec![ColumnCells::default(); width],
                });
            }
            let Some(chunk) = state.chunks.last_mut() else {
                break;
            };
            let take = (CHUNK_ROWS - chunk.rows).min(rows.len() - taken);
            for (cells, source) in chunk.columns.iter_mut().zip(&staged) {
                cells.extend_from(source, taken..taken + take);
            }
            chunk.rows += take;
            if chunk.rows == CHUNK_ROWS {
                chunk.columns.iter_mut().for_each(ColumnCells::shrink);
            }
            taken += take;
            state.rows += take as u64;
        }
        state.rows
    }

    pub(crate) fn finish(&self) {
        self.state.write().unwrap_or_else(PoisonError::into_inner).finished = true;
    }

    /// The whole value of one cell, for a detail pane or a copy: `None`
    /// for null, and every byte of a binary value as hex.
    pub(crate) fn full_text(&self, row: u64, column: usize) -> Option<Option<String>> {
        let state = self.read();
        let cell = state.cell(row, column)?;
        Some(cell.kind.map(|kind| cell_text::full(kind, cell.bytes)))
    }
}

impl ResultStore {
    // The rows held now, in a column's order. Rows that arrive later follow them as they came.
    pub(crate) fn row_order(&self, column: usize, ascending: bool) -> Option<Vec<u64>> {
        let state = self.read();
        let as_text = sorts_as_text(&state.columns.get(column)?.column_type);
        let mut values = Vec::with_capacity(usize::try_from(state.rows).unwrap_or(0));
        for chunk in &state.chunks {
            let cells = chunk.columns.get(column)?;
            values.extend((0..chunk.rows).map(|row| cell_value(cells.cell(row))));
        }
        drop(state);
        Some(
            row_order(&values, as_text, ascending)
                .into_iter()
                .map(|row| row as u64)
                .collect(),
        )
    }
}

impl StoreState {
    /// The chunk that holds `row`, and the row's index in it.
    pub(super) fn locate(&self, row: u64) -> Option<(&Chunk, usize)> {
        if row >= self.rows {
            return None;
        }
        let index = self
            .chunks
            .partition_point(|chunk| chunk.start + chunk.rows as u64 <= row);
        let chunk = self.chunks.get(index)?;
        let local = usize::try_from(row - chunk.start).ok()?;
        Some((chunk, local))
    }

    fn cell(&self, row: u64, column: usize) -> Option<Cell<'_>> {
        let (chunk, local) = self.locate(row)?;
        Some(chunk.columns.get(column)?.cell(local))
    }
}

fn kinds_of(columns: &[ResultColumn]) -> Vec<ValueKind> {
    columns
        .iter()
        .map(|column| ValueKind::of_column(&column.column_type.kind))
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnType;

    use super::*;

    fn store(width: usize) -> ResultStore {
        let columns: Vec<ResultColumn> = (0..width)
            .map(|index| ResultColumn::new(format!("c{index}"), ColumnType::untyped_text("")))
            .collect();
        ResultStore::new(columns.into())
    }

    fn rows(range: std::ops::Range<i64>) -> Vec<Vec<Value>> {
        range
            .map(|row| vec![Value::Int(row), Value::Text(format!("row {row}"))])
            .collect()
    }

    #[test]
    fn rows_across_chunk_boundaries_read_back_in_order() {
        let store = store(2);
        let total = CHUNK_ROWS as i64 * 2 + 10;

        let mut count = 0;
        for start in (0..total).step_by(7_000) {
            count = store.append(&rows(start..(start + 7_000).min(total)));
        }

        assert_eq!(count, total as u64);
        assert_eq!(store.read().chunks.len(), 3);
        for row in [0, CHUNK_ROWS as u64 - 1, CHUNK_ROWS as u64, total as u64 - 1] {
            assert_eq!(store.full_text(row, 0), Some(Some(row.to_string())));
            assert_eq!(store.full_text(row, 1), Some(Some(format!("row {row}"))));
        }
        assert_eq!(store.full_text(total as u64, 0), None);
    }

    #[test]
    fn a_missing_value_reads_as_null_and_a_binary_value_in_full() {
        let store = store(2);

        store.append(&[vec![Value::Bytes(vec![0xca, 0xfe])]]);

        assert_eq!(store.full_text(0, 0), Some(Some("0xcafe".to_owned())));
        assert_eq!(store.full_text(0, 1), Some(None));
    }

    #[test]
    fn a_column_orders_the_rows_held_by_value() {
        let columns: Arc<[ResultColumn]> = vec![
            ResultColumn::new("n", ColumnType::untyped_text("")),
            ResultColumn::new("name", ColumnType::untyped_text("")),
        ]
        .into();
        let store = ResultStore::new(columns);
        store.append(&[
            vec![Value::Int(10), Value::Text("file10".to_owned())],
            vec![Value::Null, Value::Text("file2".to_owned())],
            vec![Value::Float64(2.5), Value::Null],
            vec![Value::Int(-1), Value::Text("File1".to_owned())],
        ]);

        assert_eq!(store.row_order(0, true), Some(vec![1, 3, 2, 0]));
        assert_eq!(store.row_order(1, true), Some(vec![2, 3, 1, 0]));
        assert_eq!(store.row_order(1, false), Some(vec![0, 1, 3, 2]));
        assert_eq!(store.row_order(2, true), None);
    }

    #[test]
    fn columns_resolved_before_any_row_replace_the_set_s_columns() {
        let store = store(1);
        let resolved: Arc<[ResultColumn]> = vec![
            ResultColumn::new("a", ColumnType::untyped_text("")),
            ResultColumn::new("b", ColumnType::untyped_text("")),
        ]
        .into();

        store.resolve_columns(resolved);
        store.append(&rows(0..1));

        assert_eq!(store.columns().len(), 2);
        assert_eq!(store.full_text(0, 1), Some(Some("row 0".to_owned())));
    }
}
