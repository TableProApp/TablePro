use std::fs::{DirBuilder, OpenOptions, Permissions};
use std::io::ErrorKind;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

use crate::error::StorageError;

const PRIVATE_DIR: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;

/// Create the directory and everything above it, then force 0700 on the
/// leaf. `DirBuilder::mode` only applies to directories this call
/// creates, so an existing world-readable directory still needs fixing.
///
/// This sets the mode to exactly 0700, which also restores owner write on
/// a directory that lost it. These are the app's own directories, and it
/// has to be able to write to them.
pub fn ensure_private_dir(path: &Path) -> Result<(), StorageError> {
    DirBuilder::new()
        .recursive(true)
        .mode(PRIVATE_DIR)
        .create(path)
        .map_err(|source| StorageError::Io {
            path: path.to_owned(),
            source,
        })?;
    std::fs::set_permissions(path, Permissions::from_mode(PRIVATE_DIR)).map_err(|source| StorageError::Permissions {
        path: path.to_owned(),
        source,
    })
}

/// Write bytes so a reader sees either the old file or the new one, and
/// so the new one survives a power cut.
///
/// `g_file_set_contents_full` keeps an existing file's mode, so a file
/// that was already 0644 is tightened first. The mode argument only
/// applies when it creates the file.
pub fn write_private_blocking(path: &Path, bytes: &[u8]) -> Result<(), StorageError> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    match std::fs::metadata(path) {
        Ok(_) => std::fs::set_permissions(path, Permissions::from_mode(PRIVATE_FILE)).map_err(|source| {
            StorageError::Permissions {
                path: path.to_owned(),
                source,
            }
        })?,
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(source) => {
            return Err(StorageError::Io {
                path: path.to_owned(),
                source,
            });
        }
    }
    glib::file_set_contents_full(
        path,
        bytes,
        glib::FileSetContentsFlags::CONSISTENT | glib::FileSetContentsFlags::DURABLE,
        PRIVATE_FILE as i32,
    )
    .map_err(|source| StorageError::Write {
        path: path.to_owned(),
        source,
    })
}

/// Create an empty 0600 file when it is absent, so a library that opens
/// it later (SQLite and its WAL and SHM siblings) inherits the mode
/// instead of picking one from the umask.
pub fn create_private_file_if_missing(path: &Path) -> Result<(), StorageError> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(PRIVATE_FILE)
        .open(path)
    {
        Ok(_) => Ok(()),
        Err(error) if error.kind() == ErrorKind::AlreadyExists => Ok(()),
        Err(source) => Err(StorageError::Io {
            path: path.to_owned(),
            source,
        }),
    }
}

/// Rename a file out of the way, returning the name it now has.
///
/// The caller shows that name, so the user can find the file again. The
/// suffix counter handles two resets in the same second.
pub fn move_aside_blocking(path: &Path, now: std::time::SystemTime) -> Result<std::path::PathBuf, StorageError> {
    let seconds = now
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_owned());
    let parent = path.parent().unwrap_or(Path::new("."));

    for attempt in 0..MAX_MOVE_ASIDE_ATTEMPTS {
        let candidate = if attempt == 0 {
            parent.join(format!("{name}.corrupt-{seconds}"))
        } else {
            parent.join(format!("{name}.corrupt-{seconds}-{attempt}"))
        };
        match std::fs::symlink_metadata(&candidate) {
            Err(error) if error.kind() == ErrorKind::NotFound => {
                std::fs::rename(path, &candidate).map_err(|source| StorageError::Io {
                    path: path.to_owned(),
                    source,
                })?;
                return Ok(candidate);
            }
            Ok(_) => continue,
            Err(source) => {
                return Err(StorageError::Io {
                    path: candidate,
                    source,
                });
            }
        }
    }
    Err(StorageError::Io {
        path: path.to_owned(),
        source: std::io::Error::new(ErrorKind::AlreadyExists, "no free name to move the file aside"),
    })
}

const MAX_MOVE_ASIDE_ATTEMPTS: u32 = 1_000;

#[cfg(test)]
mod tests {
    use super::*;

    fn mode_of(path: &Path) -> u32 {
        std::fs::metadata(path).expect("metadata").permissions().mode() & 0o777
    }

    #[test]
    fn ensure_private_dir_sets_0700_on_existing_0755_dir() {
        let root = tempfile::tempdir().expect("tempdir");
        let dir = root.path().join("nested").join("leaf");
        std::fs::create_dir_all(&dir).expect("create");
        std::fs::set_permissions(&dir, Permissions::from_mode(0o755)).expect("chmod");

        ensure_private_dir(&dir).expect("ensure");

        assert_eq!(mode_of(&dir), 0o700);
    }

    #[test]
    fn write_private_creates_0600() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("sub").join("secret.json");

        write_private_blocking(&file, b"{}").expect("write");

        assert_eq!(mode_of(&file), 0o600);
        assert_eq!(mode_of(file.parent().expect("parent")), 0o700);
        assert_eq!(std::fs::read(&file).expect("read"), b"{}");
    }

    #[test]
    fn rewrite_of_0644_file_is_0600() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("loose.json");
        std::fs::write(&file, b"old").expect("seed");
        std::fs::set_permissions(&file, Permissions::from_mode(0o644)).expect("chmod");

        write_private_blocking(&file, b"new").expect("write");

        assert_eq!(mode_of(&file), 0o600);
        assert_eq!(std::fs::read(&file).expect("read"), b"new");
    }

    #[test]
    fn write_under_a_file_parent_is_an_io_error() {
        let root = tempfile::tempdir().expect("tempdir");
        let not_a_dir = root.path().join("regular-file");
        std::fs::write(&not_a_dir, b"x").expect("seed");

        let result = write_private_blocking(&not_a_dir.join("child.json"), b"payload");

        assert!(matches!(result, Err(StorageError::Io { .. })), "{result:?}");
    }

    #[test]
    fn a_tightened_dir_stays_writable() {
        // ensure_private_dir sets exactly 0700, so a directory that lost
        // owner write gets it back rather than failing every later write.
        let root = tempfile::tempdir().expect("tempdir");
        let dir = root.path().join("locked");
        std::fs::create_dir(&dir).expect("create");
        std::fs::set_permissions(&dir, Permissions::from_mode(0o500)).expect("chmod");
        let file = dir.join("data.json");

        write_private_blocking(&file, b"replacement").expect("write");

        assert_eq!(mode_of(&dir), 0o700);
        assert_eq!(std::fs::read(&file).expect("read"), b"replacement");
    }

    #[test]
    fn a_rewrite_replaces_the_contents_whole() {
        // CONSISTENT writes a temporary file and renames, so a reader sees
        // the old bytes or the new ones, never a mix.
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("data.json");
        write_private_blocking(&file, b"a-much-longer-original-payload").expect("seed");

        write_private_blocking(&file, b"short").expect("rewrite");

        assert_eq!(std::fs::read(&file).expect("read"), b"short");
    }

    #[test]
    fn move_aside_picks_suffix_on_collision() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("connections.json");
        let now = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);

        std::fs::write(&file, b"first").expect("seed");
        let first = move_aside_blocking(&file, now).expect("first move");
        std::fs::write(&file, b"second").expect("reseed");
        let second = move_aside_blocking(&file, now).expect("second move");

        assert_eq!(first.file_name().expect("name"), "connections.json.corrupt-1700000000");
        assert_eq!(
            second.file_name().expect("name"),
            "connections.json.corrupt-1700000000-1"
        );
        assert_eq!(std::fs::read(&first).expect("read"), b"first");
        assert_eq!(std::fs::read(&second).expect("read"), b"second");
        assert!(!file.exists(), "the original was left behind");
    }

    #[test]
    fn create_private_file_if_missing_keeps_existing_contents() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("db").join("history.db");

        create_private_file_if_missing(&file).expect("create");
        std::fs::write(&file, b"payload").expect("fill");
        create_private_file_if_missing(&file).expect("second call");

        assert_eq!(std::fs::read(&file).expect("read"), b"payload");
        assert_eq!(mode_of(&file), 0o600);
    }
}
