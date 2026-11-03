use std::ptr::null;
use std::sync::Arc;

use super::column_cells::Cell;
use super::store::{ResultStore, StoreState};
use super::{ValueKind, cell_text};
use crate::window_abi::TpWindow;

// Kept between fetches, so a scrolling grid allocates nothing once the buffers have grown.
pub(crate) struct Cursor {
    store: Arc<ResultStore>,
    order: Option<Arc<[u64]>>,
    column_kinds: Vec<u8>,
    cell_kinds: Vec<u8>,
    nulls: Vec<u8>,
    truncated: Vec<u8>,
    raw: Vec<i64>,
    offsets: Vec<u32>,
    text: Vec<u8>,
    window: TpWindow,
}

/// The rows and columns a fetch covers, once clamped to the set.
#[derive(Debug, Clone, Copy)]
struct Range {
    first_row: u64,
    rows: usize,
    first_column: usize,
    columns: usize,
}

impl Cursor {
    pub(crate) fn new(store: Arc<ResultStore>, order: Option<Arc<[u64]>>) -> Self {
        Self {
            store,
            order,
            column_kinds: Vec::new(),
            cell_kinds: Vec::new(),
            nulls: Vec::new(),
            truncated: Vec::new(),
            raw: Vec::new(),
            offsets: Vec::new(),
            text: Vec::new(),
            window: TpWindow {
                first_row: 0,
                total_rows: 0,
                row_count: 0,
                first_column: 0,
                column_count: 0,
                finished: 0,
                column_kinds: null(),
                cell_kinds: null(),
                nulls: null(),
                truncated: null(),
                raw: null(),
                offsets: null(),
                text: null(),
            },
        }
    }

    /// `None` when the window's text could pass what a `u32` offset holds.
    pub(crate) fn fetch(
        &mut self,
        first_row: u64,
        row_count: u32,
        first_column: u32,
        column_count: u32,
        max_chars: u32,
    ) -> Option<&TpWindow> {
        let store = self.store.clone();
        let state = store.read();
        let range = clamp(&state, first_row, row_count, first_column, column_count);
        let cells = range.rows * range.columns;
        let max_chars = usize::try_from(max_chars).ok()?;
        // A character takes at most four UTF-8 bytes, and hex writes two
        // per byte after its `0x`.
        let most = cells.checked_mul(max_chars.checked_mul(4)?.checked_add(2)?)?;
        if u32::try_from(most).is_err() {
            return None;
        }
        self.reset(cells);
        for column in 0..range.columns {
            self.pack_column(&state, range, column, max_chars);
        }
        self.offsets.push(u32::try_from(self.text.len()).ok()?);
        self.window = TpWindow {
            first_row,
            total_rows: state.rows,
            row_count: u32::try_from(range.rows).ok()?,
            first_column: u32::try_from(range.first_column).ok()?,
            column_count: u32::try_from(range.columns).ok()?,
            finished: u32::from(state.finished),
            column_kinds: self.column_kinds.as_ptr(),
            cell_kinds: self.cell_kinds.as_ptr(),
            nulls: self.nulls.as_ptr(),
            truncated: self.truncated.as_ptr(),
            raw: self.raw.as_ptr(),
            offsets: self.offsets.as_ptr(),
            text: self.text.as_ptr(),
        };
        Some(&self.window)
    }

    fn reset(&mut self, cells: usize) {
        self.column_kinds.clear();
        self.cell_kinds.clear();
        self.cell_kinds.resize(cells, 0);
        self.nulls.clear();
        self.nulls.resize(cells.div_ceil(8), 0);
        self.truncated.clear();
        self.truncated.resize(cells.div_ceil(8), 0);
        self.raw.clear();
        self.raw.resize(cells, 0);
        self.offsets.clear();
        self.offsets.reserve(cells + 1);
        self.text.clear();
    }

    fn pack_column(&mut self, state: &StoreState, range: Range, column: usize, max_chars: usize) {
        let index = range.first_column + column;
        let column_kind = state.kinds.get(index).copied().unwrap_or(ValueKind::Other);
        self.column_kinds.push(column_kind as u8);
        let mut cell = column * range.rows;
        let mut row = range.first_row;
        let end = range.first_row + range.rows as u64;
        if let Some(order) = self.order.clone() {
            for row in row..end {
                let stored = usize::try_from(row)
                    .ok()
                    .and_then(|row| order.get(row).copied())
                    .unwrap_or(row);
                let value = state
                    .locate(stored)
                    .and_then(|(chunk, local)| Some(chunk.columns.get(index)?.cell(local)));
                self.pack_cell(value, column_kind, cell, max_chars);
                cell += 1;
            }
            return;
        }
        while row < end {
            let Some((chunk, local)) = state.locate(row) else {
                break;
            };
            let Some(cells) = chunk.columns.get(index) else {
                break;
            };
            let take = (chunk.rows - local).min(usize::try_from(end - row).unwrap_or(usize::MAX));
            for at in local..local + take {
                self.pack_cell(Some(cells.cell(at)), column_kind, cell, max_chars);
                cell += 1;
            }
            row += take as u64;
        }
    }

    // A cell the store cannot find packs as null, so the window keeps its shape.
    fn pack_cell(&mut self, value: Option<Cell<'_>>, column_kind: ValueKind, cell: usize, max_chars: usize) {
        // The text never passes u32: fetch checked its bound.
        self.offsets.push(self.text.len() as u32);
        match value.and_then(|value| Some((value.kind?, value))) {
            None => {
                self.cell_kinds[cell] = column_kind as u8;
                set_bit(&mut self.nulls, cell);
            }
            Some((kind, value)) => {
                self.cell_kinds[cell] = kind as u8;
                self.raw[cell] = value.raw;
                if cell_text::display(kind, value.bytes, max_chars, &mut self.text) {
                    set_bit(&mut self.truncated, cell);
                }
            }
        }
    }
}

fn clamp(state: &StoreState, first_row: u64, row_count: u32, first_column: u32, column_count: u32) -> Range {
    let rows = state.rows.saturating_sub(first_row).min(u64::from(row_count));
    let width = state.columns.len();
    let first_column = usize::try_from(first_column).unwrap_or(usize::MAX).min(width);
    let columns = usize::try_from(column_count)
        .unwrap_or(usize::MAX)
        .min(width - first_column);
    Range {
        first_row,
        rows: usize::try_from(rows).unwrap_or(0),
        first_column,
        columns,
    }
}

fn set_bit(bits: &mut [u8], index: usize) {
    bits[index / 8] |= 1 << (index % 8);
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::{ColumnType, ResultColumn};

    use super::*;

    struct Read {
        texts: Vec<Option<String>>,
        truncated: Vec<bool>,
        raw: Vec<i64>,
        kinds: Vec<u8>,
        column_kinds: Vec<u8>,
        total_rows: u64,
        rows: u32,
    }

    fn read(window: &TpWindow) -> Read {
        let rows = window.row_count as usize;
        let cells = rows * window.column_count as usize;
        // SAFETY: the window's arrays hold `cells` entries until the next fetch.
        unsafe {
            let offsets = std::slice::from_raw_parts(window.offsets, cells + 1);
            let text = std::slice::from_raw_parts(window.text, offsets[cells] as usize);
            let nulls = std::slice::from_raw_parts(window.nulls, cells.div_ceil(8));
            let truncated = std::slice::from_raw_parts(window.truncated, cells.div_ceil(8));
            let bit = |bits: &[u8], cell: usize| bits[cell / 8] & (1 << (cell % 8)) != 0;
            Read {
                texts: (0..cells)
                    .map(|cell| {
                        (!bit(nulls, cell)).then(|| {
                            String::from_utf8(text[offsets[cell] as usize..offsets[cell + 1] as usize].to_vec())
                                .unwrap()
                        })
                    })
                    .collect(),
                truncated: (0..cells).map(|cell| bit(truncated, cell)).collect(),
                raw: std::slice::from_raw_parts(window.raw, cells).to_vec(),
                kinds: std::slice::from_raw_parts(window.cell_kinds, cells).to_vec(),
                column_kinds: std::slice::from_raw_parts(window.column_kinds, window.column_count as usize).to_vec(),
                total_rows: window.total_rows,
                rows: window.row_count,
            }
        }
    }

    fn store() -> Arc<ResultStore> {
        let columns: Arc<[ResultColumn]> = vec![
            ResultColumn::new("id", ColumnType::untyped_text("")),
            ResultColumn::new("note", ColumnType::untyped_text("")),
        ]
        .into();
        let store = Arc::new(ResultStore::new(columns));
        store.append(&[
            vec![Value::Int(1), Value::Text("first\nline".to_owned())],
            vec![Value::Int(2), Value::Null],
            vec![Value::Int(3), Value::Text("ünïcode text".to_owned())],
        ]);
        store
    }

    #[test]
    fn a_window_is_packed_column_by_column() {
        let mut cursor = Cursor::new(store(), None);

        let window = read(cursor.fetch(0, 50, 0, 10, 5).unwrap());

        assert_eq!((window.rows, window.total_rows), (3, 3));
        assert_eq!(
            window.texts,
            [
                Some("1".to_owned()),
                Some("2".to_owned()),
                Some("3".to_owned()),
                Some("first".to_owned()),
                None,
                Some("ünïco".to_owned()),
            ]
        );
        assert_eq!(window.truncated, [false, false, false, true, false, true]);
        assert_eq!(&window.raw[..3], [1, 2, 3]);
        assert_eq!(window.raw[5], "ünïcode text".len() as i64);
        assert_eq!(window.kinds[0], ValueKind::Integer as u8);
        assert_eq!(window.kinds[3], ValueKind::Text as u8);
        assert_eq!(window.column_kinds, [ValueKind::Other as u8; 2]);
    }

    #[test]
    fn a_window_past_the_end_is_empty_and_a_column_range_is_kept() {
        let mut cursor = Cursor::new(store(), None);

        let past = read(cursor.fetch(10, 50, 0, 2, 100).unwrap());
        let second = read(cursor.fetch(1, 1, 1, 5, 100).unwrap());

        assert_eq!((past.rows, past.total_rows), (0, 3));
        assert_eq!(second.texts, [None]);
        assert_eq!(second.column_kinds.len(), 1);
    }

    #[test]
    fn a_row_order_reads_each_row_from_where_it_is_held() {
        let store = store();
        store.append(&[vec![Value::Int(4), Value::Text("later".to_owned())]]);
        let mut cursor = Cursor::new(store, Some(vec![2, 0, 1].into()));

        let window = read(cursor.fetch(0, 50, 0, 2, 100).unwrap());
        let tail = read(cursor.fetch(2, 2, 0, 1, 100).unwrap());

        assert_eq!((window.rows, window.total_rows), (4, 4));
        assert_eq!(
            window.texts,
            [
                Some("3".to_owned()),
                Some("1".to_owned()),
                Some("2".to_owned()),
                Some("4".to_owned()),
                Some("ünïcode text".to_owned()),
                Some("first line".to_owned()),
                None,
                Some("later".to_owned()),
            ]
        );
        assert_eq!(&window.raw[..4], [3, 1, 2, 4]);
        assert_eq!(tail.texts, [Some("2".to_owned()), Some("4".to_owned())]);
    }

    #[test]
    fn a_window_whose_text_could_pass_four_gib_is_refused() {
        let mut cursor = Cursor::new(store(), None);

        assert!(cursor.fetch(0, 3, 0, 2, u32::MAX).is_none());
    }
}
