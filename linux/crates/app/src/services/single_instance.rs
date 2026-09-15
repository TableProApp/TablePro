//! Process-level single-instance gate.
//!
//! `gtk::Application::register()` already handles single-instance through
//! the D-Bus session bus on a healthy GNOME session: a second launch
//! sends `activate` to the primary and exits. That mechanism breaks when
//! D-Bus is unavailable (sandboxed, headless, minimal session) and
//! silently lets two processes through. Two TablePro processes racing on
//! the workspace state corrupt each other's tabs.
//!
//! This adds a belt-and-suspenders exclusive lock on
//! `StoragePaths::instance_lock`, under the per-application runtime
//! directory. It is held for the lifetime of the returned `Lock`. The
//! kernel releases it when the process exits, so a crash does not leak
//! it.

use std::fs::TryLockError;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use tablepro_storage::StoragePaths;

#[derive(Debug)]
pub struct Lock {
    // Held only for its drop side effect: closing the fd, which the
    // kernel turns into a lock release.
    _file: File,
}

#[derive(Debug)]
pub enum LockError {
    AlreadyRunning,
    Io { path: PathBuf, source: std::io::Error },
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockError::AlreadyRunning => write!(f, "another TablePro instance is already running"),
            LockError::Io { path, source } => {
                write!(f, "single-instance lock {}: {source}", path.display())
            }
        }
    }
}

impl std::error::Error for LockError {}

/// Take the process-wide single-instance lock. `Err(AlreadyRunning)`
/// means another process holds it. The guard must outlive every code
/// path that writes user state.
pub fn acquire(paths: &StoragePaths) -> Result<Lock, LockError> {
    let path = paths.instance_lock();
    tablepro_storage::fs::ensure_private_dir(&paths.runtime).map_err(|error| LockError::Io {
        path: paths.runtime.clone(),
        source: std::io::Error::other(error),
    })?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&path)
        .map_err(|source| LockError::Io {
            path: path.clone(),
            source,
        })?;
    match file.try_lock() {
        Ok(()) => Ok(Lock { _file: file }),
        Err(TryLockError::WouldBlock) => Err(LockError::AlreadyRunning),
        Err(TryLockError::Error(source)) => Err(LockError::Io { path, source }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(root: &tempfile::TempDir) -> StoragePaths {
        StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
    }

    #[test]
    fn instance_lock_lives_under_runtime_dir() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);

        let _lock = acquire(&paths).expect("acquire");

        assert_eq!(paths.instance_lock(), paths.runtime.join("tablepro.lock"));
        assert!(paths.instance_lock().exists());
    }

    #[test]
    fn a_second_acquire_reports_already_running() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);
        let _held = acquire(&paths).expect("first acquire");

        let second = acquire(&paths);

        assert!(matches!(second, Err(LockError::AlreadyRunning)), "{second:?}");
    }

    #[test]
    fn the_lock_releases_when_the_guard_drops() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);

        drop(acquire(&paths).expect("first acquire"));

        assert!(acquire(&paths).is_ok());
    }

    #[test]
    fn two_profiles_do_not_block_each_other() {
        let root = tempfile::tempdir().expect("tempdir");
        let installed = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
        let devel = StoragePaths::under(root.path(), "tablepro-devel", "app.tablepro.TablePro.Devel");

        let _held = acquire(&installed).expect("installed");

        assert!(acquire(&devel).is_ok());
    }
}
