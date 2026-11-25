// What a test that writes sqlite_schema needs from the linked SQLite, measured rather than read from its version. The
// catalog_memory target shares this file, so it uses nothing else from this target.

use std::ffi::c_int;
use std::path::Path;

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};

const SQLITE_CORRUPT: &str = "11";

// Apple's SQLite opens every connection defensive, which ignores `PRAGMA writable_schema`.
pub async fn allow_writable_schema(connection: &mut SqliteConnection) -> Result<(), sqlx::Error> {
    let mut handle = connection.lock_handle().await?;
    let raw = handle.as_raw_handle();
    let off: c_int = 0;
    // SAFETY: `raw` comes from the locked handle, so the connection is open and nothing runs on it meanwhile, and
    // DEFENSIVE takes an int and a pointer that may be null.
    let code = unsafe {
        libsqlite3_sys::sqlite3_db_config(
            raw.as_ptr(),
            libsqlite3_sys::SQLITE_DBCONFIG_DEFENSIVE,
            off,
            std::ptr::null_mut::<c_int>(),
        )
    };
    if code == libsqlite3_sys::SQLITE_OK {
        Ok(())
    } else {
        Err(sqlx::Error::Protocol(format!("SQLite kept defensive mode on: {code}")))
    }
}

// Whether the linked SQLite refuses a schema row whose stored text runs past its statement's end. Its version cannot
// tell: Fedora backports the check to 3.51.2, and Apple ships a 3.54.0 from before it.
pub async fn sqlite_refuses_a_stored_tail(directory: &Path) -> Result<bool, sqlx::Error> {
    let options = SqliteConnectOptions::new()
        .filename(directory.join("stored_tail_probe.sqlite3"))
        .create_if_missing(true);
    let mut writer = SqliteConnection::connect_with(&options).await?;
    allow_writable_schema(&mut writer).await?;
    for sql in [
        "CREATE TABLE probe (a INTEGER)",
        "PRAGMA writable_schema = ON",
        "UPDATE sqlite_schema SET sql = sql || '; SELECT 1' WHERE name = 'probe'",
    ] {
        writer.execute(sql).await?;
    }
    writer.close().await?;
    match read_schema(&options).await {
        Ok(()) => Ok(false),
        Err(sqlx::Error::Database(error)) if error.code().as_deref() == Some(SQLITE_CORRUPT) => Ok(true),
        Err(error) => Err(error),
    }
}

async fn read_schema(options: &SqliteConnectOptions) -> Result<(), sqlx::Error> {
    let mut reader = SqliteConnection::connect_with(options).await?;
    let read = reader.execute("SELECT count(*) FROM sqlite_schema").await;
    reader.close().await?;
    read.map(|_| ())
}
