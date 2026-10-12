use std::path::Path;
use std::time::Duration;

use sqlx::ConnectOptions as _;
use sqlx::sqlite::SqliteConnectOptions;

/// How every connection to the file opens: the workspace's, each editor
/// session's and a streamed read's.
///
/// The path is a file name, never a URL, so `?` and `%41` in it are
/// part of the name. A missing file is an error rather than a new empty
/// database: creating one is `create_file`'s job, and only when the
/// user asked for a new database.
///
/// `busy_timeout` is the workspace's lock timeout, which is how long
/// SQLite waits for another connection's lock before it reports busy.
pub(crate) fn connect_options(path: &Path, read_only: bool, busy_timeout: Duration) -> SqliteConnectOptions {
    SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(false)
        .read_only(read_only)
        .busy_timeout(busy_timeout)
        .foreign_keys(true)
        // A schema in a file from elsewhere cannot run SQL functions
        // with side effects through a view or a trigger.
        .pragma("trusted_schema", "OFF")
        // sqlx would log every statement, values and all.
        .disable_statement_logging()
}

#[cfg(test)]
mod tests {
    use sqlx::Connection as _;
    use sqlx::sqlite::SqliteConnection as SqlxConnection;

    use super::*;

    #[tokio::test]
    async fn options_never_create_for_open_existing() {
        let directory = tempfile::tempdir().unwrap();
        let missing = directory.path().join("missing.sqlite3");

        for read_only in [false, true] {
            let options = connect_options(&missing, read_only, Duration::from_secs(1));
            let opened = SqlxConnection::connect_with(&options).await;

            assert!(opened.is_err(), "a missing file opened with read_only={read_only}");
            assert!(!missing.exists(), "opening created the file with read_only={read_only}");
        }
    }
}
