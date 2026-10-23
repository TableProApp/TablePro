//! Refusing an ATTACH of a file DuckDB has open in this process.
//!
//! SQLite would open the file, find no SQLite database in it and close it
//! again, and closing a descriptor drops every POSIX lock the process
//! holds on the file, DuckDB's among them. SQLite's authorizer is told
//! an ATTACH's file name only when the statement spells it as a string,
//! so one it computes is refused while DuckDB has any file open. The
//! editor runs an ATTACH under `tablepro_core::opening_file`, so DuckDB
//! cannot open the file between the check and SQLite's open.

use std::ffi::{CStr, c_char, c_int, c_void};
use std::path::PathBuf;

use sqlx::sqlite::SqliteConnection as SqlxConnection;
use tablepro_core::DriverError;

use crate::driver::ENGINE;
use crate::errors::map_error;

/// Check every ATTACH the connection prepares from now on.
pub(crate) async fn install(connection: &mut SqlxConnection) -> Result<(), DriverError> {
    let mut handle = connection.lock_handle().await.map_err(map_error)?;
    let raw = handle.as_raw_handle();
    // SAFETY: `raw` comes from the locked handle, so the connection is
    // open and nothing runs on it while the authorizer is set. The
    // callback takes no user data.
    let code = unsafe { libsqlite3_sys::sqlite3_set_authorizer(raw.as_ptr(), Some(authorize), std::ptr::null_mut()) };
    match code {
        libsqlite3_sys::SQLITE_OK => Ok(()),
        code => Err(DriverError::Protocol(format!(
            "SQLite refused the ATTACH check with code {code}"
        ))),
    }
}

/// SQLite's authorizer: every action passes but an ATTACH of a file
/// another engine has open.
unsafe extern "C" fn authorize(
    _data: *mut c_void,
    action: c_int,
    file: *const c_char,
    _second: *const c_char,
    _database: *const c_char,
    _trigger: *const c_char,
) -> c_int {
    if action != libsqlite3_sys::SQLITE_ATTACH {
        return libsqlite3_sys::SQLITE_OK;
    }
    if file.is_null() {
        return match tablepro_core::any_claimed_by_another(ENGINE) {
            true => libsqlite3_sys::SQLITE_DENY,
            false => libsqlite3_sys::SQLITE_OK,
        };
    }
    // SAFETY: SQLite hands the file name as a NUL-terminated string that
    // stays valid for the call.
    let name = unsafe { CStr::from_ptr(file) }.to_string_lossy();
    match attached_path(&name) {
        Some(path) if tablepro_core::claimed_by_another(&path, ENGINE) => libsqlite3_sys::SQLITE_DENY,
        _ => libsqlite3_sys::SQLITE_OK,
    }
}

/// The file an ATTACH names: a path, or a `file:` URI's path with its
/// query left off and its escapes decoded. Relative to the working
/// directory, as SQLite opens it.
fn attached_path(name: &str) -> Option<PathBuf> {
    if name.is_empty() || name == ":memory:" {
        return None;
    }
    let Some(uri) = name.strip_prefix("file:") else {
        return Some(PathBuf::from(name));
    };
    let path = uri.split(['?', '#']).next().unwrap_or_default();
    let path = path
        .strip_prefix("//localhost")
        .or_else(|| path.strip_prefix("//"))
        .unwrap_or(path);
    let decoded = percent_decoded(path)?;
    (!decoded.is_empty() && decoded != ":memory:").then(|| PathBuf::from(decoded))
}

/// The path with its `%XX` escapes decoded. SQLite ends the path at an
/// escaped NUL, so this does too.
fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        let (byte, width) = match byte {
            b'%' => (u8::from_str_radix(text.get(index + 1..index + 3)?, 16).ok()?, 3),
            byte => (byte, 1),
        };
        if byte == 0 {
            break;
        }
        decoded.push(byte);
        index += width;
    }
    String::from_utf8(decoded).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_attach_names_a_path_or_a_uris_path() {
        assert_eq!(attached_path("/srv/a.db"), Some(PathBuf::from("/srv/a.db")));
        assert_eq!(attached_path("rel.db"), Some(PathBuf::from("rel.db")));
        assert_eq!(
            attached_path("file:/srv/a%20b.db?mode=ro"),
            Some(PathBuf::from("/srv/a b.db"))
        );
        assert_eq!(attached_path("file:///srv/a.db"), Some(PathBuf::from("/srv/a.db")));
        assert_eq!(
            attached_path("file://localhost/srv/a.db"),
            Some(PathBuf::from("/srv/a.db"))
        );
        assert_eq!(
            attached_path("file:/srv/data.duckdb%00ignored?mode=ro"),
            Some(PathBuf::from("/srv/data.duckdb"))
        );
        assert_eq!(attached_path(":memory:"), None);
        assert_eq!(attached_path("file::memory:?cache=shared"), None);
        assert_eq!(attached_path(""), None);
    }
}
