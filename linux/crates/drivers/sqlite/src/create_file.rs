use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use tablepro_core::DriverError;

/// The journal and WAL files SQLite keeps beside a database. One left
/// from the database being replaced would be replayed into the new one.
const SIDECARS: [&str; 3] = ["-wal", "-shm", "-journal"];

/// Put an empty database at `path`, replacing whatever is there.
///
/// The save dialog has already asked the user before replacing a file,
/// so an existing file is not an error. It is replaced by a rename,
/// which is atomic: a reader sees the old file or the new one, never a
/// half-written one. An empty file is a valid empty database.
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
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ));

    let created = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .and_then(|file| file.sync_all());
    if let Err(error) = created {
        // A file that was created and then failed to sync is not left
        // behind beside the user's files.
        let _ = std::fs::remove_file(&temporary);
        return Err(file_error(error.kind(), path));
    }
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(file_error(error.kind(), path));
    }
    for suffix in SIDECARS {
        let mut sidecar = path.as_os_str().to_owned();
        sidecar.push(suffix);
        match std::fs::remove_file(PathBuf::from(sidecar)) {
            Err(error) if error.kind() != ErrorKind::NotFound => return Err(file_error(error.kind(), path)),
            _ => {}
        }
    }
    // The rename is durable only once the directory that records it is.
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| file_error(error.kind(), path))
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
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn an_existing_file_is_replaced_by_an_empty_private_one() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data.sqlite3");
        std::fs::write(&path, b"old contents").unwrap();

        create_or_replace(&path).unwrap();

        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.len(), 0);
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        let leftovers: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(leftovers, [std::ffi::OsString::from("data.sqlite3")]);
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

        assert_eq!(create_or_replace(&path), Err(DriverError::FileNotFound { path }));
    }
}
