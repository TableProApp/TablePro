use std::ffi::OsStr;
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use tablepro_core::{BusyReason, DriverError, FileOpenMode};

// A journal or log left beside the path would be replayed into the new database.
const SIDECARS: [&str; 3] = ["-wal", "-shm", "-journal"];

pub(crate) fn make_file(path: &Path, mode: FileOpenMode) -> Result<(), DriverError> {
    match mode {
        FileOpenMode::OpenExisting => Ok(()),
        FileOpenMode::CreateNew => create_new(path),
        FileOpenMode::Replace => replace(path),
    }
}

// Exclusive, so another program's file at the path is never replaced, nor removed on a failure. Empty is a database.
pub(crate) fn create_new(path: &Path) -> Result<(), DriverError> {
    let (parent, _) = target(path)?;
    let file = private_file().open(path).map_err(|error| match error.kind() {
        ErrorKind::AlreadyExists => DriverError::FileExists {
            path: path.to_path_buf(),
        },
        kind => file_error(kind, path),
    })?;
    remove_sidecars(path)?;
    file.sync_all().map_err(|error| file_error(error.kind(), path))?;
    sync_folder(parent, path)
}

// The save dialog asked first. A rename puts the file in place, so a reader sees the old file or the new one.
pub(crate) fn replace(path: &Path) -> Result<(), DriverError> {
    let (parent, name) = target(path)?;
    // A file another window or the other engine has open would be pulled out from under it.
    if tablepro_core::held_by_this_process(path) {
        return Err(DriverError::Busy(BusyReason::FileLocked));
    }
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ));
    let created = private_file().open(&temporary).and_then(|file| file.sync_all());
    if let Err(error) = created {
        let _ = std::fs::remove_file(&temporary);
        return Err(file_error(error.kind(), path));
    }
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(file_error(error.kind(), path));
    }
    remove_sidecars(path)?;
    sync_folder(parent, path)
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
    Ok((parent, name))
}

fn private_file() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options
}

fn remove_sidecars(path: &Path) -> Result<(), DriverError> {
    for suffix in SIDECARS {
        let mut sidecar = path.as_os_str().to_owned();
        sidecar.push(suffix);
        match std::fs::remove_file(PathBuf::from(sidecar)) {
            Err(error) if error.kind() != ErrorKind::NotFound => return Err(file_error(error.kind(), path)),
            _ => {}
        }
    }
    Ok(())
}

fn sync_folder(parent: &Path, path: &Path) -> Result<(), DriverError> {
    tablepro_core::sync_directory(parent).map_err(|error| file_error(error.kind(), path))
}

fn file_error(kind: ErrorKind, path: &Path) -> DriverError {
    let path = path.to_path_buf();
    match kind {
        ErrorKind::NotFound => DriverError::FileNotFound { path },
        ErrorKind::IsADirectory => DriverError::NotADatabase { path },
        ErrorKind::PermissionDenied => DriverError::FileAccessDenied { path },
        kind => DriverError::FileIo { path, kind },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names_in(directory: &Path) -> Vec<std::ffi::OsString> {
        let mut names: Vec<_> = std::fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        names.sort();
        names
    }

    fn sidecars_of(path: &Path) -> Vec<PathBuf> {
        SIDECARS
            .iter()
            .map(|suffix| {
                let mut sidecar = path.as_os_str().to_owned();
                sidecar.push(suffix);
                PathBuf::from(sidecar)
            })
            .collect()
    }

    #[test]
    fn a_new_file_is_an_empty_private_one_where_nothing_was() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("new.sqlite3");

        create_new(&path).unwrap();

        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.len(), 0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("new.sqlite3")]);
    }

    // The app found the path free, then another program made a file there before the create.
    #[test]
    fn a_file_made_after_the_path_was_checked_is_never_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.sqlite3");
        std::fs::write(&path, b"another program's data").unwrap();
        let journal = sidecars_of(&path).remove(2);
        std::fs::write(&journal, b"its journal").unwrap();

        assert_eq!(create_new(&path), Err(DriverError::FileExists { path: path.clone() }));

        assert_eq!(std::fs::read(&path).unwrap(), b"another program's data");
        assert_eq!(std::fs::read(&journal).unwrap(), b"its journal");
        assert_eq!(
            names_in(directory.path()),
            [
                std::ffi::OsString::from("data.sqlite3"),
                std::ffi::OsString::from("data.sqlite3-journal")
            ]
        );
    }

    #[test]
    fn a_new_file_removes_the_logs_a_deleted_database_left() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.sqlite3");
        for sidecar in sidecars_of(&path) {
            std::fs::write(sidecar, b"left from a database that is gone").unwrap();
        }

        create_new(&path).unwrap();

        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("data.sqlite3")]);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_at_the_path_is_not_followed() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("link.sqlite3");
        let elsewhere = directory.path().join("elsewhere.sqlite3");
        std::os::unix::fs::symlink(&elsewhere, &path).unwrap();

        assert_eq!(create_new(&path), Err(DriverError::FileExists { path }));
        assert!(!elsewhere.exists(), "the create followed the link");
    }

    #[test]
    fn a_replaced_file_becomes_an_empty_private_one() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.sqlite3");
        std::fs::write(&path, b"old contents").unwrap();

        replace(&path).unwrap();

        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.len(), 0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(names_in(directory.path()), [std::ffi::OsString::from("data.sqlite3")]);
    }

    #[test]
    fn only_a_refused_permission_is_access_denied() {
        let path = PathBuf::from("/data/app.sqlite3");

        assert_eq!(
            file_error(ErrorKind::PermissionDenied, &path),
            DriverError::FileAccessDenied { path: path.clone() }
        );
        assert_eq!(
            file_error(ErrorKind::StorageFull, &path),
            DriverError::FileIo {
                path: path.clone(),
                kind: ErrorKind::StorageFull
            }
        );
        assert_eq!(
            file_error(ErrorKind::ReadOnlyFilesystem, &path),
            DriverError::FileIo {
                path,
                kind: ErrorKind::ReadOnlyFilesystem
            }
        );
    }

    #[test]
    fn a_missing_directory_is_file_not_found() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("missing").join("data.sqlite3");

        assert_eq!(create_new(&path), Err(DriverError::FileNotFound { path: path.clone() }));
        assert_eq!(replace(&path), Err(DriverError::FileNotFound { path }));
    }
}
