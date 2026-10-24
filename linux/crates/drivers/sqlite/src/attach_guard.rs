//! Refusing an ATTACH of a file DuckDB has open in this process.
//!
//! SQLite would open the file, find no SQLite database in it and close it
//! again, and closing a descriptor drops every POSIX lock the process
//! holds on the file, DuckDB's among them. SQLite's authorizer is told
//! an ATTACH's file name only when the statement spells it as a string,
//! so one it computes is refused while DuckDB has any file open. The
//! editor runs an ATTACH under `tablepro_core::opening_file`, so DuckDB
//! cannot open the file between the check and SQLite's open.

use std::ffi::{CStr, OsString, c_char, c_int, c_void};
use std::os::unix::ffi::OsStringExt;
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
    let name = unsafe { CStr::from_ptr(file) }.to_bytes();
    let held = attached_paths(name)
        .iter()
        .any(|path| tablepro_core::claimed_by_another(path, ENGINE));
    match held {
        true => libsqlite3_sys::SQLITE_DENY,
        false => libsqlite3_sys::SQLITE_OK,
    }
}

/// The files an ATTACH may open: the name as a path, and for a `file:`
/// name also the URI's path, with its query left off and its escapes
/// decoded as SQLite decodes them, since whether SQLite reads the name as
/// a URI depends on how the connection was opened. Relative to the
/// working directory, as SQLite opens them.
fn attached_paths(name: &[u8]) -> Vec<PathBuf> {
    if name.is_empty() || name == b":memory:" {
        return Vec::new();
    }
    let mut paths = vec![PathBuf::from(OsString::from_vec(name.to_vec()))];
    if let Some(uri) = name.strip_prefix(b"file:") {
        let end = uri
            .iter()
            .position(|byte| matches!(byte, b'?' | b'#'))
            .unwrap_or(uri.len());
        let path = uri.get(..end).unwrap_or_default();
        let path = path
            .strip_prefix(b"//localhost")
            .or_else(|| path.strip_prefix(b"//"))
            .unwrap_or(path);
        let decoded = percent_decoded(path);
        if !decoded.is_empty() && decoded != b":memory:" {
            paths.push(PathBuf::from(OsString::from_vec(decoded)));
        }
    }
    paths
}

/// The path with each `%XX` escape decoded, as SQLite decodes a URI: a
/// `%` that two hex digits do not follow stays as it is, and an escaped
/// NUL ends the path.
fn percent_decoded(text: &[u8]) -> Vec<u8> {
    let hex = |byte: Option<&u8>| byte.and_then(|byte| char::from(*byte).to_digit(16));
    let mut decoded = Vec::with_capacity(text.len());
    let mut index = 0;
    while let Some(&byte) = text.get(index) {
        let escaped = match byte {
            b'%' => hex(text.get(index + 1)).zip(hex(text.get(index + 2))),
            _ => None,
        };
        let (byte, width) = match escaped {
            Some((high, low)) => (u8::try_from(high * 16 + low).unwrap_or(0), 3),
            None => (byte, 1),
        };
        if byte == 0 {
            break;
        }
        decoded.push(byte);
        index += width;
    }
    decoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_attach_names_a_path_and_a_uris_path() {
        let paths = |name: &str| attached_paths(name.as_bytes());
        let path = |text: &str| PathBuf::from(text);

        assert_eq!(paths("/srv/a.db"), [path("/srv/a.db")]);
        assert_eq!(paths("rel.db"), [path("rel.db")]);
        assert_eq!(
            paths("file:/srv/a%20b.db?mode=ro"),
            [path("file:/srv/a%20b.db?mode=ro"), path("/srv/a b.db")]
        );
        assert_eq!(paths("file:///srv/a.db")[1], path("/srv/a.db"));
        assert_eq!(paths("file://localhost/srv/a.db")[1], path("/srv/a.db"));
        assert_eq!(paths("file:/srv/data.duckdb%00ignored")[1], path("/srv/data.duckdb"));
        assert_eq!(paths("file:/srv/held%GG.duckdb")[1], path("/srv/held%GG.duckdb"));
        assert_eq!(paths("file:/srv/end%2")[1], path("/srv/end%2"));
        assert!(paths(":memory:").is_empty());
        assert_eq!(paths("file::memory:?cache=shared").len(), 1);
        assert!(paths("").is_empty());
    }
}
