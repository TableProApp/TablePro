//! The grid's hot path as a C ABI: one call packs the display text of
//! a visible range, which UniFFI would copy through a `RustBuffer`.
//! csbindgen reads this file to write the C# side, so it holds only the
//! exported functions and the types they name.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::null;

use crate::results::Cursor;

/// One window of a result set, valid until the cursor's next fetch or
/// its free.
///
/// Cells are column by column: the cell of row `r` and column `c` is
/// `(c - first_column) * row_count + (r - first_row)`. A cell's text is
/// `text[offsets[cell]..offsets[cell + 1]]`, UTF-8, at most the fetch's
/// `max_chars` characters on one line. `nulls` and `truncated` hold a
/// bit per cell, lowest bit first. `column_kinds` and `cell_kinds` hold
/// a `ValueKind` byte each, and a cell's kind says what its `raw` holds.
#[repr(C)]
pub struct TpWindow {
    pub first_row: u64,
    /// The set's rows when the window was read, from the same moment.
    pub total_rows: u64,
    pub row_count: u32,
    pub first_column: u32,
    pub column_count: u32,
    /// 1 once the set holds every row it will.
    pub finished: u32,
    pub column_kinds: *const u8,
    pub cell_kinds: *const u8,
    pub nulls: *const u8,
    pub truncated: *const u8,
    pub raw: *const i64,
    pub offsets: *const u32,
    pub text: *const u8,
}

/// A cursor over one result set, opened by `ResultSet::open_cursor`.
/// Each thread that reads windows keeps its own.
pub struct TpCursor {
    cursor: Cursor,
}

impl TpCursor {
    pub(crate) fn new(cursor: Cursor) -> Self {
        Self { cursor }
    }
}

/// Packs the rows from `first_row` and the columns from `first_column`
/// that the set holds, up to the counts asked for. Null when `cursor` is
/// null or the window's text could pass 4 GiB.
///
/// # Safety
///
/// `cursor` is null or a cursor `ResultSet::open_cursor` returned and no
/// one freed, used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tablepro_cursor_fetch(
    cursor: *mut TpCursor,
    first_row: u64,
    row_count: u32,
    first_column: u32,
    column_count: u32,
    max_chars: u32,
) -> *const TpWindow {
    // SAFETY: the caller passes null or a live cursor no other thread uses.
    let Some(cursor) = (unsafe { cursor.as_mut() }) else {
        return null();
    };
    let fetched = catch_unwind(AssertUnwindSafe(|| {
        cursor
            .cursor
            .fetch(first_row, row_count, first_column, column_count, max_chars)
            .map_or(null(), |window| window as *const TpWindow)
    }));
    fetched.unwrap_or(null())
}

/// # Safety
///
/// `cursor` is null or a cursor `ResultSet::open_cursor` returned, freed
/// once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tablepro_cursor_free(cursor: *mut TpCursor) {
    if !cursor.is_null() {
        // SAFETY: the cursor came from Box::into_raw in open_cursor and is freed once.
        drop(unsafe { Box::from_raw(cursor) });
    }
}
