use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use tablepro_core::{BusyReason, DriverError};
use tokio_util::sync::CancellationToken;

use crate::errors::map_error;
use crate::instance::{config, file_error};

// A log left beside an earlier database at the path would be replayed into the new one.
const WAL_SUFFIX: &str = ".wal";

// Built beside the path, as an empty file is no DuckDB database; a connect given up meanwhile leaves the path alone.
pub(crate) fn create_new(path: &Path, given_up: &CancellationToken) -> Result<(), DriverError> {
    let (parent, name) = target(path)?;
    let temporary = beside(parent, name, "tmp");
    let made = build_empty(&temporary, path)
        .and_then(|()| match given_up.is_cancelled() {
            true => Err(DriverError::Cancelled),
            false => Ok(()),
        })
        .and_then(|()| publish(&temporary, path));
    // Nothing half-built is left beside the user's files.
    let _ = std::fs::remove_file(&temporary);
    let _ = std::fs::remove_file(wal_of(&temporary));
    made?;
    tablepro_core::sync_directory(parent).map_err(|error| file_error(error.kind(), path))
}

// A link fails on anything at the path, so another program's file there is never touched, and appears whole.
fn publish(temporary: &Path, path: &Path) -> Result<(), DriverError> {
    match std::fs::hard_link(temporary, path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => return Err(already_there(path)),
        // A file system without links, such as FAT or the document portal's.
        Err(_) => copy_into_new(temporary, path)?,
    }
    match std::fs::remove_file(wal_of(path)) {
        Err(error) if error.kind() != ErrorKind::NotFound => Err(file_error(error.kind(), path)),
        _ => Ok(()),
    }
}

// Written only through its exclusive handle, and kept on a failure, when the path may name another file.
fn copy_into_new(temporary: &Path, path: &Path) -> Result<(), DriverError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(path).map_err(|error| match error.kind() {
        ErrorKind::AlreadyExists => already_there(path),
        kind => file_error(kind, path),
    })?;
    File::open(temporary)
        .and_then(|mut built| std::io::copy(&mut built, &mut file))
        .and_then(|_| file.sync_all())
        .map_err(|error| file_error(error.kind(), path))
}

fn already_there(path: &Path) -> DriverError {
    DriverError::FileExists {
        path: path.to_path_buf(),
    }
}

// The save dialog asked first. A rename puts the database in place, so a reader sees the old file or the new one.
pub(crate) fn replace(path: &Path, given_up: &CancellationToken) -> Result<(), DriverError> {
    let (parent, name) = target(path)?;
    let temporary = beside(parent, name, "tmp");
    let placed = build_empty(&temporary, path).and_then(|()| match given_up.is_cancelled() {
        true => Err(DriverError::Cancelled),
        false => place(&temporary, path, parent, name),
    });
    if placed.is_err() {
        let _ = std::fs::remove_file(&temporary);
        let _ = std::fs::remove_file(wal_of(&temporary));
        return placed;
    }
    tablepro_core::sync_directory(parent).map_err(|error| file_error(error.kind(), path))
}

fn target(path: &Path) -> Result<(&Path, &OsStr), DriverError> {
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
    Ok((parent, name))
}

fn beside(parent: &Path, name: &OsStr, suffix: &str) -> PathBuf {
    parent.join(format!(
        ".{}.{}.{suffix}",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ))
}

// Checkpointed, so no log goes with the file.
fn build_empty(temporary: &Path, target: &Path) -> Result<(), DriverError> {
    let connection = duckdb::Connection::open_with_flags(temporary, config(false)?).map_err(map_error)?;
    connection.execute_batch("CHECKPOINT").map_err(map_error)?;
    connection.close().map_err(|(_, error)| map_error(error))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        std::fs::set_permissions(temporary, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| file_error(error.kind(), target))?;
    }
    // Windows flushes only a handle opened for writing.
    OpenOptions::new()
        .write(true)
        .open(temporary)
        .and_then(|file| file.sync_all())
        .map_err(|error| file_error(error.kind(), target))
}

// The old file's log is put back if the rename fails, so a database that stays keeps the changes only its log holds.
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

// Held through the rename: a process with the database open holds it, and would go on logging beside the new file.
fn lock_replaced(path: &Path) -> Result<Option<File>, DriverError> {
    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => {}
        // Nothing there to lock, or something the rename itself refuses.
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(file_error(error.kind(), path)),
    }
    // Closing any descriptor drops the process's POSIX locks on the file, so one this process holds is not opened.
    if tablepro_core::held_by_this_process(path) {
        return Err(DriverError::Busy(BusyReason::FileLocked));
    }
    let (file, exclusive) = match OpenOptions::new().read(true).write(true).open(path) {
        Ok(file) => (file, true),
        // A write lock needs the file open for writing; a shared lock still meets the writer's.
        Err(error) if error.kind() == ErrorKind::PermissionDenied || error.kind() == ErrorKind::ReadOnlyFilesystem => {
            (File::open(path).map_err(|error| file_error(error.kind(), path))?, false)
        }
        Err(error) => return Err(file_error(error.kind(), path)),
    };
    match lock_as_duckdb_does(&file, exclusive) {
        LockOutcome::Held | LockOutcome::Unsupported => Ok(Some(file)),
        LockOutcome::Busy => Err(DriverError::Busy(BusyReason::FileLocked)),
    }
}

enum LockOutcome {
    Held,
    Busy,
    // A file system without locks: DuckDB could not have locked it either.
    Unsupported,
}

// A POSIX record lock, the kind DuckDB takes on Unix.
#[cfg(unix)]
fn lock_as_duckdb_does(file: &File, exclusive: bool) -> LockOutcome {
    use rustix::fs::FlockOperation;
    use rustix::io::Errno;

    let operation = match exclusive {
        true => FlockOperation::NonBlockingLockExclusive,
        false => FlockOperation::NonBlockingLockShared,
    };
    match rustix::fs::fcntl_lock(file, operation) {
        Ok(()) => LockOutcome::Held,
        Err(errno) if errno == Errno::AGAIN || errno == Errno::ACCESS => LockOutcome::Busy,
        Err(_) => LockOutcome::Unsupported,
    }
}

// LockFileEx, the kind DuckDB takes on Windows, which std's file locks are.
#[cfg(windows)]
fn lock_as_duckdb_does(file: &File, exclusive: bool) -> LockOutcome {
    let locked = match exclusive {
        true => file.try_lock(),
        false => file.try_lock_shared(),
    };
    match locked {
        Ok(()) => LockOutcome::Held,
        Err(std::fs::TryLockError::WouldBlock) => LockOutcome::Busy,
        Err(std::fs::TryLockError::Error(_)) => LockOutcome::Unsupported,
    }
}

fn wal_of(path: &Path) -> PathBuf {
    let mut wal = path.as_os_str().to_owned();
    wal.push(WAL_SUFFIX);
    PathBuf::from(wal)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tables_in(path: &Path) -> i64 {
        let reopened = duckdb::Connection::open(path).unwrap();
        reopened
            .query_row("SELECT count(*) FROM duckdb_tables()", [], |row| row.get(0))
            .unwrap()
    }

    fn names_in(directory: &Path) -> Vec<std::ffi::OsString> {
        let mut names: Vec<_> = std::fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn a_new_database_is_made_where_no_file_was() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("new.duckdb");

        create_new(&path, &CancellationToken::new()).unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let metadata = std::fs::metadata(&path).unwrap();
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("new.duckdb")]);
        assert_eq!(tables_in(&path), 0);
    }

    // The app found the path free, then another program made a file there before the create.
    #[test]
    fn a_file_made_after_the_path_was_checked_is_never_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.duckdb");
        std::fs::write(&path, b"another program's data").unwrap();
        std::fs::write(wal_of(&path), b"its log").unwrap();

        assert_eq!(
            create_new(&path, &CancellationToken::new()),
            Err(DriverError::FileExists { path: path.clone() })
        );

        assert_eq!(std::fs::read(&path).unwrap(), b"another program's data");
        assert_eq!(std::fs::read(wal_of(&path)).unwrap(), b"its log");
        assert_eq!(
            names_in(directory.path()),
            [
                std::ffi::OsString::from("data.duckdb"),
                std::ffi::OsString::from("data.duckdb.wal")
            ]
        );
    }

    #[test]
    fn a_new_database_drops_the_log_a_deleted_one_left() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.duckdb");
        std::fs::write(wal_of(&path), b"left from a database that is gone").unwrap();

        create_new(&path, &CancellationToken::new()).unwrap();

        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("data.duckdb")]);
        assert_eq!(tables_in(&path), 0);
    }

    #[test]
    fn without_links_the_database_is_copied_only_where_nothing_is() {
        let directory = tempfile::tempdir().unwrap();
        let built = directory.path().join(".built.tmp");
        build_empty(&built, &built).unwrap();
        let path = directory.path().join("copied.duckdb");
        let taken = directory.path().join("taken.duckdb");
        std::fs::write(&taken, b"another program's data").unwrap();

        copy_into_new(&built, &path).unwrap();

        assert_eq!(
            copy_into_new(&built, &taken),
            Err(DriverError::FileExists { path: taken.clone() })
        );
        assert_eq!(std::fs::read(&taken).unwrap(), b"another program's data");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let metadata = std::fs::metadata(&path).unwrap();
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(tables_in(&path), 0);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_at_the_path_is_not_followed() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("link.duckdb");
        let elsewhere = directory.path().join("elsewhere.duckdb");
        std::os::unix::fs::symlink(&elsewhere, &path).unwrap();

        assert_eq!(
            create_new(&path, &CancellationToken::new()),
            Err(DriverError::FileExists { path })
        );
        assert!(!elsewhere.exists(), "the create followed the link");
    }

    #[test]
    fn an_existing_file_and_its_log_are_replaced_by_an_empty_private_database() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.duckdb");
        std::fs::write(&path, b"old contents").unwrap();
        std::fs::write(wal_of(&path), b"old log").unwrap();

        replace(&path, &CancellationToken::new()).unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let metadata = std::fs::metadata(&path).unwrap();
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        }
        assert!(
            !wal_of(&path).exists(),
            "the old log would be replayed into the new database"
        );
        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("data.duckdb")]);
        assert_eq!(tables_in(&path), 0);
    }

    #[test]
    fn the_log_of_a_database_that_stays_is_kept() {
        let directory = tempfile::tempdir().unwrap();
        // A directory cannot be renamed over, so the database stays.
        let path = directory.path().join("data.duckdb");
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("inside"), b"keeps the directory from being replaced").unwrap();
        std::fs::write(wal_of(&path), b"committed changes").unwrap();

        assert!(replace(&path, &CancellationToken::new()).is_err());
        assert!(create_new(&path, &CancellationToken::new()).is_err());

        assert_eq!(std::fs::read(wal_of(&path)).unwrap(), b"committed changes");
        assert_eq!(
            names_in(directory.path()),
            [
                std::ffi::OsString::from("data.duckdb"),
                std::ffi::OsString::from("data.duckdb.wal")
            ]
        );
    }

    // Windows lists no process's handles, so there only a claim says a file is held.
    #[cfg(unix)]
    #[test]
    fn a_file_this_process_holds_is_not_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("held.duckdb");
        std::fs::write(&path, b"open elsewhere in this process").unwrap();
        let open = File::open(&path).unwrap();

        assert_eq!(
            replace(&path, &CancellationToken::new()),
            Err(DriverError::Busy(BusyReason::FileLocked))
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"open elsewhere in this process");
        drop(open);
    }

    // A connect given up while the database was built leaves the path as it was, with nothing half-built beside it.
    #[test]
    fn a_create_given_up_while_building_leaves_the_path_as_it_was() {
        let directory = tempfile::tempdir().unwrap();
        let kept = directory.path().join("data.duckdb");
        std::fs::write(&kept, b"what the user had").unwrap();
        let free = directory.path().join("new.duckdb");
        let given_up = CancellationToken::new();
        given_up.cancel();

        assert_eq!(replace(&kept, &given_up), Err(DriverError::Cancelled));
        assert_eq!(create_new(&free, &given_up), Err(DriverError::Cancelled));

        assert_eq!(std::fs::read(&kept).unwrap(), b"what the user had");
        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("data.duckdb")]);
    }

    #[test]
    fn a_missing_directory_is_file_not_found() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("missing").join("data.duckdb");

        assert_eq!(
            create_new(&path, &CancellationToken::new()),
            Err(DriverError::FileNotFound { path: path.clone() })
        );
        assert_eq!(
            replace(&path, &CancellationToken::new()),
            Err(DriverError::FileNotFound { path })
        );
    }
}
