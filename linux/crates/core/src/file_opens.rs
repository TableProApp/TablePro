//! The lock an engine's open of a database file and a read of a file's
//! first bytes take in turn.
//!
//! SQLite and DuckDB lock a file with POSIX record locks, which belong to
//! the process: closing any descriptor the process has on the file drops
//! them all. A header read opens and closes a descriptor, so it must not
//! run while an engine opens the same file through another name and has
//! no descriptor on it yet for the reader to see.

use tokio::sync::{Mutex, MutexGuard};

static FILE_OPENS: Mutex<()> = Mutex::const_new(());

/// Held by an engine from before it opens a database file until it holds
/// a descriptor on it, and by a header read throughout.
pub async fn opening_file() -> MutexGuard<'static, ()> {
    FILE_OPENS.lock().await
}

/// `opening_file` for a thread that may block, never an async task.
pub fn opening_file_blocking() -> MutexGuard<'static, ()> {
    FILE_OPENS.blocking_lock()
}
