//! How SQLite and DuckDB share one process's database files.
//!
//! Both lock a file with POSIX record locks, which belong to the process:
//! closing any descriptor the process has on the file drops them all, the
//! other engine's included. So neither engine opens a file the other has
//! open, which it would close again on finding no database of its own in
//! it (`claim_file`, `claimed_by_another`), and a header read, which opens
//! and closes a descriptor, never runs while an engine opens a file and
//! has no descriptor on it yet for the reader to see (`opening_file`).

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::PoisonError;

use crate::busy_reason::BusyReason;
use crate::error::DriverError;

static FILE_OPENS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// The engine holding each claimed file, and how many claims it holds.
static CLAIMS: std::sync::Mutex<Option<HashMap<FileKey, (&'static str, usize)>>> = std::sync::Mutex::new(None);

/// Held by an engine from before it opens a database file until it holds
/// a descriptor on it, and by a header read throughout.
pub async fn opening_file() -> tokio::sync::MutexGuard<'static, ()> {
    FILE_OPENS.lock().await
}

/// `opening_file` for a thread that may block, never an async task.
pub fn opening_file_blocking() -> tokio::sync::MutexGuard<'static, ()> {
    FILE_OPENS.blocking_lock()
}

/// A file whatever path names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct FileKey {
    device: u64,
    inode: u64,
}

impl FileKey {
    fn of(path: &Path) -> Option<Self> {
        std::fs::metadata(path).ok().map(|metadata| Self {
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

/// One engine's hold on a file, given up when dropped.
#[derive(Debug)]
#[must_use = "the claim ends when it is dropped"]
pub struct FileClaim {
    key: FileKey,
}

impl Drop for FileClaim {
    fn drop(&mut self) {
        let mut claims = CLAIMS.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(claims) = claims.as_mut() else {
            return;
        };
        if let Some((_, count)) = claims.get_mut(&self.key) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                claims.remove(&self.key);
            }
        }
    }
}

/// Record that `engine` has the file at `path` open, or refuse while
/// another engine has it. `None` when nothing is at `path`.
pub fn claim_file(path: &Path, engine: &'static str) -> Result<Option<FileClaim>, DriverError> {
    let Some(key) = FileKey::of(path) else {
        return Ok(None);
    };
    let mut claims = CLAIMS.lock().unwrap_or_else(PoisonError::into_inner);
    let claims = claims.get_or_insert_with(HashMap::new);
    match claims.get_mut(&key) {
        Some((holder, _)) if *holder != engine => Err(DriverError::Busy(BusyReason::FileLocked)),
        Some((_, count)) => {
            *count += 1;
            Ok(Some(FileClaim { key }))
        }
        None => {
            claims.insert(key, (engine, 1));
            Ok(Some(FileClaim { key }))
        }
    }
}

/// Whether an engine other than `engine` has the file at `path` open.
pub fn claimed_by_another(path: &Path, engine: &str) -> bool {
    let Some(key) = FileKey::of(path) else {
        return false;
    };
    let claims = CLAIMS.lock().unwrap_or_else(PoisonError::into_inner);
    claims
        .as_ref()
        .and_then(|claims| claims.get(&key))
        .is_some_and(|(holder, _)| *holder != engine)
}

/// Whether an engine other than `engine` has any file open, for a check
/// that cannot tell which file an open will reach.
pub fn any_claimed_by_another(engine: &str) -> bool {
    let claims = CLAIMS.lock().unwrap_or_else(PoisonError::into_inner);
    claims
        .as_ref()
        .is_some_and(|claims| claims.values().any(|(holder, _)| *holder != engine))
}

/// Whether a descriptor this process has open names the file at `path`.
pub fn held_by_this_process(path: &Path) -> bool {
    let Some(key) = FileKey::of(path) else {
        return false;
    };
    let Ok(descriptors) = std::fs::read_dir("/proc/self/fd") else {
        return false;
    };
    descriptors
        .flatten()
        .any(|descriptor| FileKey::of(&descriptor.path()) == Some(key))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    /// A directory of the test's own, removed when it ends.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("tablepro-file-opens-{}", uuid::Uuid::new_v4().simple()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_file_one_engine_holds_is_refused_to_the_other_until_let_go() {
        let directory = Scratch::new();
        let path = directory.path().join("held.db");
        std::fs::write(&path, b"x").unwrap();
        let link = directory.path().join("link.db");
        std::fs::hard_link(&path, &link).unwrap();

        let first = claim_file(&path, "duckdb").unwrap();
        let second = claim_file(&link, "duckdb").unwrap();

        assert!(claimed_by_another(&link, "sqlite"));
        assert!(!claimed_by_another(&path, "duckdb"));
        assert!(any_claimed_by_another("sqlite"));
        assert_eq!(
            claim_file(&path, "sqlite").unwrap_err(),
            DriverError::Busy(BusyReason::FileLocked)
        );
        drop(first);
        assert!(claimed_by_another(&path, "sqlite"), "one claim is still held");
        drop(second);
        assert!(!claimed_by_another(&path, "sqlite"));
        assert!(
            claim_file(&directory.path().join("missing.db"), "sqlite")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn a_descriptor_on_any_name_of_a_file_holds_it() {
        let directory = Scratch::new();
        let path = directory.path().join("open.db");
        std::fs::write(&path, b"x").unwrap();
        let link = directory.path().join("other-name.db");
        std::fs::hard_link(&path, &link).unwrap();

        let open = std::fs::File::open(&path).unwrap();

        assert!(held_by_this_process(&link));
        drop(open);
        assert!(!held_by_this_process(&link));
    }
}
