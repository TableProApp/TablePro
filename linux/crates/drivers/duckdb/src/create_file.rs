use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use rustix::fs::FlockOperation;
use rustix::io::Errno;
use tablepro_core::{BusyReason, DriverError};

use crate::errors::map_error;
use crate::instance::file_error;

/// The write-ahead log DuckDB keeps beside a database. One left from the
/// database being replaced would be replayed into the new one.
const WAL_SUFFIX: &str = ".wal";

/// Put an empty database at `path`, replacing whatever is there.
///
/// The save dialog has already asked before replacing a file. An empty
/// file is no DuckDB database, so the new one is written beside the
/// target first, then renamed over it, which is atomic: a reader sees the
/// old file or the new one, never half of one.
pub(crate) fn create_or_replace(path: &Path) -> Result<(), DriverError> {
    let parent = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => {
            return Err(DriverError::FileNotFound {
                path: path.to_path_buf(),
            });
        }
    };
    let Some(name) = path.file_name() else {
        return Err(DriverError::NotADatabase {
            path: path.to_path_buf(),
        });
    };
    if !parent.is_dir() {
        return Err(DriverError::FileNotFound {
            path: path.to_path_buf(),
        });
    }
    let temporary = beside(parent, name, "tmp");
    let placed = build_empty(&temporary, path).and_then(|()| place(&temporary, path, parent, name));
    if placed.is_err() {
        // Nothing half-built is left beside the user's files.
        let _ = std::fs::remove_file(&temporary);
        let _ = std::fs::remove_file(wal_of(&temporary));
        return placed;
    }
    // The rename is durable only once the directory that records it is.
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| file_error(error.kind(), path))
}

/// A hidden name beside the user's file, unique to this call.
fn beside(parent: &Path, name: &OsStr, suffix: &str) -> PathBuf {
    parent.join(format!(
        ".{}.{}.{suffix}",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ))
}

/// An empty database, checkpointed into the file so no log goes with
/// it, readable by its owner only.
fn build_empty(temporary: &Path, target: &Path) -> Result<(), DriverError> {
    let connection = duckdb::Connection::open(temporary).map_err(map_error)?;
    connection.execute_batch("CHECKPOINT").map_err(map_error)?;
    connection.close().map_err(|(_, error)| map_error(error))?;
    std::fs::set_permissions(temporary, std::fs::Permissions::from_mode(0o600))
        .and_then(|()| File::open(temporary)?.sync_all())
        .map_err(|error| file_error(error.kind(), target))
}

/// Rename the new database over `path`. The old file's log is moved
/// aside first and put back if the rename fails, so a database that
/// stays keeps the changes only its log holds.
fn place(temporary: &Path, path: &Path, parent: &Path, name: &OsStr) -> Result<(), DriverError> {
    let _held = lock_replaced(path)?;
    let wal = wal_of(path);
    let aside = beside(parent, name, "wal.tmp");
    let moved = match std::fs::rename(&wal, &aside) {
        Ok(()) => true,
        Err(error) if error.kind() == ErrorKind::NotFound => false,
        Err(error) => return Err(file_error(error.kind(), path)),
    };
    if let Err(error) = std::fs::rename(temporary, path) {
        if moved && let Err(restoring) = std::fs::rename(&aside, &wal) {
            tracing::warn!(error = %restoring, aside = %aside.display(), "could not put a database's log back");
        }
        return Err(file_error(error.kind(), path));
    }
    if moved && let Err(error) = std::fs::remove_file(&aside) {
        tracing::warn!(%error, aside = %aside.display(), "could not remove a replaced database's log");
    }
    Ok(())
}

/// Lock the file being replaced as DuckDB locks a database it opens, and
/// hold the lock through the rename. Another process with the database
/// open holds that lock, and would go on writing a log beside the new
/// file under the same name.
fn lock_replaced(path: &Path) -> Result<Option<File>, DriverError> {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => metadata,
        // Nothing there to lock, or something the rename itself refuses.
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(file_error(error.kind(), path)),
    };
    // A POSIX lock belongs to the process, and closing any descriptor on
    // the file drops all of them, so a file this process holds open is
    // not opened again here.
    if held_by_this_process(&metadata) {
        return Err(DriverError::Busy(BusyReason::FileLocked));
    }
    let (file, lock) = match OpenOptions::new().read(true).write(true).open(path) {
        Ok(file) => (file, FlockOperation::NonBlockingLockExclusive),
        // A write lock needs the file open for writing. A shared lock
        // still meets the writer's.
        Err(error) if error.kind() == ErrorKind::PermissionDenied || error.kind() == ErrorKind::ReadOnlyFilesystem => (
            File::open(path).map_err(|error| file_error(error.kind(), path))?,
            FlockOperation::NonBlockingLockShared,
        ),
        Err(error) => return Err(file_error(error.kind(), path)),
    };
    match rustix::fs::fcntl_lock(&file, lock) {
        Ok(()) => Ok(Some(file)),
        Err(errno) if errno == Errno::AGAIN || errno == Errno::ACCESS => Err(DriverError::Busy(BusyReason::FileLocked)),
        // A file system without locks: DuckDB could not have locked it
        // either.
        Err(_) => Ok(Some(file)),
    }
}

/// Whether a descriptor this process has open names the file.
fn held_by_this_process(file: &std::fs::Metadata) -> bool {
    let Ok(descriptors) = std::fs::read_dir("/proc/self/fd") else {
        return false;
    };
    descriptors.flatten().any(|descriptor| {
        std::fs::metadata(descriptor.path()).is_ok_and(|held| held.dev() == file.dev() && held.ino() == file.ino())
    })
}

fn wal_of(path: &Path) -> PathBuf {
    let mut wal = path.as_os_str().to_owned();
    wal.push(WAL_SUFFIX);
    PathBuf::from(wal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_existing_file_and_its_log_are_replaced_by_an_empty_private_database() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.duckdb");
        std::fs::write(&path, b"old contents").unwrap();
        std::fs::write(wal_of(&path), b"old log").unwrap();

        create_or_replace(&path).unwrap();

        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert!(
            !wal_of(&path).exists(),
            "the old log would be replayed into the new database"
        );
        let leftovers: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(leftovers, [std::ffi::OsString::from("data.duckdb")]);
        let reopened = duckdb::Connection::open(&path).unwrap();
        let tables: i64 = reopened
            .query_row("SELECT count(*) FROM duckdb_tables()", [], |row| row.get(0))
            .unwrap();
        assert_eq!(tables, 0);
    }

    #[test]
    fn the_log_of_a_database_that_stays_is_kept() {
        let directory = tempfile::tempdir().unwrap();
        // A directory cannot be renamed over, so the database stays.
        let path = directory.path().join("data.duckdb");
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("inside"), b"keeps the directory from being replaced").unwrap();
        std::fs::write(wal_of(&path), b"committed changes").unwrap();

        assert!(create_or_replace(&path).is_err());

        assert_eq!(std::fs::read(wal_of(&path)).unwrap(), b"committed changes");
        let mut leftovers: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        leftovers.sort();
        assert_eq!(
            leftovers,
            [
                std::ffi::OsString::from("data.duckdb"),
                std::ffi::OsString::from("data.duckdb.wal")
            ]
        );
    }

    #[test]
    fn a_file_this_process_holds_is_not_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("held.duckdb");
        std::fs::write(&path, b"open elsewhere in this process").unwrap();
        let open = File::open(&path).unwrap();

        assert_eq!(create_or_replace(&path), Err(DriverError::Busy(BusyReason::FileLocked)));
        assert_eq!(std::fs::read(&path).unwrap(), b"open elsewhere in this process");
        drop(open);
    }

    #[test]
    fn a_missing_directory_is_file_not_found() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("missing").join("data.duckdb");

        assert_eq!(create_or_replace(&path), Err(DriverError::FileNotFound { path }));
    }
}
