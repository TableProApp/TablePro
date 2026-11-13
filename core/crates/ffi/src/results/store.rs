use std::sync::{Arc, PoisonError, RwLock, RwLockReadGuard};

use tablepro_core::column::ResultColumn;
use tablepro_core::export::ResultExtent;
use tablepro_core::value::order::{row_order, sorts_as_text};
use tablepro_core::{Truncation, Value};

use super::column_cells::{Cell, ColumnCells, cell_value, stored_value};
use super::{ValueKind, cell_text};

// A full chunk is never written again, so an append copies at most one chunk's arrays when they grow.
const CHUNK_ROWS: usize = 65_536;

// One lock, so a window reads its rows and the row count from the same moment.
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
    // As the set's end reported them: every row when counted, and whether rows may follow those held.
    pub(super) total: Option<u64>,
    pub(super) cut: bool,
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
                total: None,
                cut: false,
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

    // A set whose column count changes after its first row keeps the columns it had.
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

    // Values are formatted before the lock is taken, so a window never waits on that.
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

    #[cfg(test)]
    pub(crate) fn finish(&self) {
        self.finish_as(None, Truncation::Complete);
    }

    // A set the last chunk holds would otherwise keep the slack its arrays grew by.
    pub(crate) fn finish_as(&self, total_rows: Option<u64>, truncation: Truncation) {
        let mut state = self.state.write().unwrap_or_else(PoisonError::into_inner);
        state.finished = true;
        state.total = total_rows;
        state.cut = truncation != Truncation::Complete;
        if let Some(chunk) = state.chunks.last_mut() {
            chunk.columns.iter_mut().for_each(ColumnCells::shrink);
        }
    }

    // The run ended, as a cancel or an error ends it, before the set said it was finished: rows may follow.
    pub(crate) fn finish_with_run(&self) {
        let mut state = self.state.write().unwrap_or_else(PoisonError::into_inner);
        if !state.finished {
            state.finished = true;
            state.cut = true;
        }
        if let Some(chunk) = state.chunks.last_mut() {
            chunk.columns.iter_mut().for_each(ColumnCells::shrink);
        }
    }

    pub(crate) fn extent(&self) -> ResultExtent {
        let state = self.read();
        ResultExtent {
            held: state.rows,
            total: state.total,
            cut: state.cut,
        }
    }

    // `Some(None)` for null, and every byte of a binary value as hex.
    pub(crate) fn full_text(&self, row: u64, column: usize) -> Option<Option<String>> {
        let state = self.read();
        let cell = state.cell(row, column)?;
        Some(cell.kind.map(|kind| cell_text::full(kind, cell.bytes)))
    }
}

impl ResultStore {
    // `None` when the cell is not there or its value cannot be named exactly (`stored_value`).
    pub(crate) fn stored_value(&self, row: u64, column: usize) -> Option<Value> {
        let state = self.read();
        let read = &state.columns.get(column)?.column_type;
        stored_value(state.cell(row, column)?, read)
    }

    // The kind of the value in a cell, `None` for null; a dynamically typed column can hold any.
    pub(crate) fn cell_kind(&self, row: u64, column: usize) -> Option<Option<ValueKind>> {
        Some(self.read().cell(row, column)?.kind)
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
            values.extend((0..chunk.rows).map(|row| cell_value(sort_head(cells.cell(row)))));
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

// The core orders text by its first 4,096 characters (`value::order`), which fit in four bytes each.
const SORT_HEAD_BYTES: usize = 4 * 4_096;

// A cell that reads back as text keeps only what its order reads, so a sort does not copy a whole long column.
fn sort_head(cell: Cell<'_>) -> Cell<'_> {
    match cell.kind {
        Some(
            ValueKind::Text
            | ValueKind::Json
            | ValueKind::Xml
            | ValueKind::Array
            | ValueKind::Network
            | ValueKind::Spatial
            | ValueKind::Other,
        ) => Cell {
            bytes: text_head(cell.bytes),
            ..cell
        },
        _ => cell,
    }
}

fn text_head(bytes: &[u8]) -> &[u8] {
    let Some(head) = bytes.get(..SORT_HEAD_BYTES) else {
        return bytes;
    };
    match std::str::from_utf8(head) {
        Err(error) if error.error_len().is_none() => head.get(..error.valid_up_to()).unwrap_or(head),
        _ => head,
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
    fn long_texts_sort_by_the_head_the_core_orders_by() {
        let store = store(1);
        let wide = "😀".repeat(4_095);
        let tail = "z".repeat(100_000);
        store.append(&[
            vec![Value::Text(format!("{wide}b{tail}"))],
            vec![Value::Text(format!("{wide}a{tail}"))],
            vec![Value::Text("short".to_owned())],
        ]);

        assert_eq!(store.row_order(0, true), Some(vec![2, 1, 0]));
        assert_eq!(
            text_head(format!("{wide}b{tail}").as_bytes()).len(),
            SORT_HEAD_BYTES,
            "the head ends on a whole character"
        );
        assert_eq!(text_head("é".repeat(9_000).as_bytes()).len(), SORT_HEAD_BYTES);
        assert_eq!(
            text_head(&[0xe4_u8, 0xb8, 0xad].repeat(6_000)).len(),
            SORT_HEAD_BYTES - 1
        );
    }

    #[test]
    fn a_finished_set_reads_back_every_row() {
        let store = store(2);
        store.append(&rows(0..3));

        store.finish();

        assert!(store.is_finished());
        assert_eq!(store.full_text(2, 1), Some(Some("row 2".to_owned())));
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
