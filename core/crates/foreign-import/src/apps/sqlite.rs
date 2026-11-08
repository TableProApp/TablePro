use std::ffi::{CStr, CString, c_int};
use std::marker::PhantomData;
use std::path::Path;
use std::ptr::{self, NonNull};

use libsqlite3_sys as ffi;

pub(crate) struct Database {
    raw: NonNull<ffi::sqlite3>,
}

impl Database {
    // Read-only, so no journal file appears in another app's data directory.
    pub(crate) fn open_read_only(path: &Path) -> Option<Self> {
        let path = c_path(path)?;
        let mut raw = ptr::null_mut();
        let flags = ffi::SQLITE_OPEN_READONLY | ffi::SQLITE_OPEN_NOMUTEX;
        // SAFETY: `path` is NUL-terminated and outlives the call, `raw` is a valid out pointer, null picks the VFS.
        let code = unsafe { ffi::sqlite3_open_v2(path.as_ptr(), &mut raw, flags, ptr::null()) };
        // A handle comes back even when the open fails, and dropping it closes it.
        let database = Self {
            raw: NonNull::new(raw)?,
        };
        (code == ffi::SQLITE_OK).then_some(database)
    }

    pub(crate) fn prepare(&self, sql: &str) -> Option<Statement<'_>> {
        let sql = CString::new(sql).ok()?;
        let mut raw = ptr::null_mut();
        // SAFETY: the connection is open while `self` lives, `sql` is NUL-terminated, `raw` is a valid out pointer.
        let code = unsafe { ffi::sqlite3_prepare_v2(self.raw.as_ptr(), sql.as_ptr(), -1, &mut raw, ptr::null_mut()) };
        let statement = Statement {
            raw: NonNull::new(raw)?,
            _database: PhantomData,
        };
        (code == ffi::SQLITE_OK).then_some(statement)
    }
}

impl Drop for Database {
    fn drop(&mut self) {
        // SAFETY: closed once, and every statement borrows the database, so all are finalized by now.
        unsafe { ffi::sqlite3_close(self.raw.as_ptr()) };
    }
}

pub(crate) struct Statement<'db> {
    raw: NonNull<ffi::sqlite3_stmt>,
    _database: PhantomData<&'db Database>,
}

impl Statement<'_> {
    pub(crate) fn bind_int64(&mut self, index: c_int, value: i64) -> bool {
        // SAFETY: the statement is live until drop, and no row borrows it while it binds.
        unsafe { ffi::sqlite3_bind_int64(self.raw.as_ptr(), index, value) == ffi::SQLITE_OK }
    }

    pub(crate) fn bind_text(&mut self, index: c_int, value: &str) -> bool {
        let Ok(length) = c_int::try_from(value.len()) else {
            return false;
        };
        // SAFETY: the pointer and length describe `value`, and SQLITE_TRANSIENT has SQLite copy it before returning.
        let code = unsafe {
            ffi::sqlite3_bind_text(
                self.raw.as_ptr(),
                index,
                value.as_ptr().cast(),
                length,
                ffi::SQLITE_TRANSIENT(),
            )
        };
        code == ffi::SQLITE_OK
    }

    // Columns are read through the row, so none is read once the statement is done.
    pub(crate) fn next_row(&mut self) -> Option<Row<'_>> {
        // SAFETY: the statement is live until drop, and a row borrows it mutably, so no column is read mid-step.
        let code = unsafe { ffi::sqlite3_step(self.raw.as_ptr()) };
        (code == ffi::SQLITE_ROW).then_some(Row {
            statement: self.raw,
            _statement: PhantomData,
        })
    }
}

impl Drop for Statement<'_> {
    fn drop(&mut self) {
        // SAFETY: finalized once, and the borrow of the database keeps the connection open until then.
        unsafe { ffi::sqlite3_finalize(self.raw.as_ptr()) };
    }
}

pub(crate) struct Row<'stmt> {
    statement: NonNull<ffi::sqlite3_stmt>,
    _statement: PhantomData<&'stmt ()>,
}

impl Row<'_> {
    pub(crate) fn is_null(&self, column: c_int) -> bool {
        // SAFETY: the borrow keeps the statement on this row; SQLite answers NULL for a column out of range.
        unsafe { ffi::sqlite3_column_type(self.statement.as_ptr(), column) == ffi::SQLITE_NULL }
    }

    pub(crate) fn int64(&self, column: c_int) -> i64 {
        // SAFETY: as in `is_null`.
        unsafe { ffi::sqlite3_column_int64(self.statement.as_ptr(), column) }
    }

    pub(crate) fn optional_int64(&self, column: c_int) -> Option<i64> {
        (!self.is_null(column)).then(|| self.int64(column))
    }

    // Stops at the first NUL, as the macOS app reads it.
    pub(crate) fn text(&self, column: c_int) -> Option<String> {
        // SAFETY: as in `is_null`.
        let text = unsafe { ffi::sqlite3_column_text(self.statement.as_ptr(), column) };
        if text.is_null() {
            return None;
        }
        // SAFETY: SQLite's text is NUL-terminated and valid until the next step, and it is copied out first.
        let text = unsafe { CStr::from_ptr(text.cast()) };
        Some(text.to_string_lossy().into_owned())
    }
}

#[cfg(unix)]
fn c_path(path: &Path) -> Option<CString> {
    use std::os::unix::ffi::OsStrExt;
    CString::new(path.as_os_str().as_bytes()).ok()
}

#[cfg(not(unix))]
fn c_path(path: &Path) -> Option<CString> {
    CString::new(path.to_str()?).ok()
}
