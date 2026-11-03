// csbindgen reads this file to write the C# side, so it holds only the exported functions and their types.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::null;
use std::slice;

use crate::results::Cursor;
use crate::syntax;

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

/// One token of `tablepro_syntax_tokens`. `start` and `length` are
/// UTF-16 code units from the start of the text scanned. `kind` is 0
/// identifier, 1 keyword, 2 string, 3 quoted identifier, 4 number,
/// 5 comment, 6 operator, 7 punctuation.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TpSyntaxToken {
    pub start: u32,
    pub length: u32,
    pub kind: u32,
}

/// Scans `text_len` UTF-16 code units of SQL as `grammar` reads them and
/// writes up to `capacity` tokens, in order and without white space, to
/// `tokens`. Returns how many it wrote. A construct the text leaves open
/// runs to its end. `capacity >= text_len` always suffices, since every
/// token covers at least one unit.
///
/// `grammar` is 0 PostgreSQL, 1 MySQL, 2 SQLite, 3 SQL Server,
/// 4 ClickHouse, 5 DuckDB, 6 CQL, 7 Redis, 8 MongoDB; the last two have no
/// tokens. `backslash_escapes` is 0 off, 1 on, anything else the
/// grammar's default. Null pointers, an unknown grammar or a panic
/// write nothing and return 0.
///
/// # Safety
///
/// `text` is null or points at `text_len` readable `u16`s, and `tokens`
/// is null or points at `capacity` writable `TpSyntaxToken`s that do not
/// overlap `text`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tablepro_syntax_tokens(
    grammar: u32,
    backslash_escapes: u32,
    text: *const u16,
    text_len: u32,
    tokens: *mut TpSyntaxToken,
    capacity: u32,
) -> u32 {
    if text.is_null() || tokens.is_null() || text_len == 0 || capacity == 0 {
        return 0;
    }
    let (Ok(text_len), Ok(capacity)) = (usize::try_from(text_len), usize::try_from(capacity)) else {
        return 0;
    };
    // SAFETY: the caller passes `text_len` readable units at `text`.
    let units = unsafe { slice::from_raw_parts(text, text_len) };
    // SAFETY: the caller passes `capacity` writable tokens at `tokens`, apart from `text`.
    let out = unsafe { slice::from_raw_parts_mut(tokens, capacity) };
    let written = catch_unwind(AssertUnwindSafe(|| {
        syntax::scan(grammar, backslash_escapes, units, out)
    }));
    match written {
        Ok(Some(written)) => u32::try_from(written).unwrap_or(0),
        Ok(None) | Err(_) => 0,
    }
}
