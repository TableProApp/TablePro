use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use uuid::Uuid;

use crate::error::StorageError;

static PATH_LOCKS: OnceLock<Mutex<HashMap<PathBuf, Weak<AsyncMutex<()>>>>> = OnceLock::new();

pub(crate) struct PathLock {
    _file: File,
    _process_guard: OwnedMutexGuard<()>,
}

pub(crate) async fn lock_path(path: &Path) -> Result<PathLock, StorageError> {
    let lock = {
        let mut locks = PATH_LOCKS
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .map_err(|_| StorageError::Schema("storage path lock failed".into()))?;
        locks.retain(|_, lock| lock.strong_count() > 0);
        match locks.get(path).and_then(Weak::upgrade) {
            Some(lock) => lock,
            None => {
                let lock = Arc::new(AsyncMutex::new(()));
                locks.insert(path.to_path_buf(), Arc::downgrade(&lock));
                lock
            }
        }
    };
    let process_guard = lock.lock_owned().await;
    let lock_path = advisory_lock_path(path)?;
    if let Some(parent) = lock_path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let file = tokio::task::spawn_blocking(move || open_and_lock(&lock_path))
        .await
        .map_err(|error| StorageError::Schema(format!("storage lock task failed: {error}")))??;
    Ok(PathLock {
        _file: file,
        _process_guard: process_guard,
    })
}

fn advisory_lock_path(path: &Path) -> Result<PathBuf, StorageError> {
    let parent = path
        .parent()
        .ok_or_else(|| StorageError::Schema("storage path has no parent".into()))?;
    let file_name = path
        .file_name()
        .ok_or_else(|| StorageError::Schema("storage path has no file name".into()))?;
    let mut lock_name = OsString::from(".");
    lock_name.push(file_name);
    lock_name.push(".lock");
    Ok(parent.join(lock_name))
}

fn open_and_lock(path: &Path) -> Result<File, StorageError> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    loop {
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if result == 0 {
            return Ok(file);
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error.into());
        }
    }
}

pub(crate) async fn read_bounded(path: &Path, limit: usize) -> Result<Option<Vec<u8>>, StorageError> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || read_bounded_blocking(&path, limit))
        .await
        .map_err(|error| StorageError::Schema(format!("storage read task failed: {error}")))?
}

fn read_bounded_blocking(path: &Path, limit: usize) -> Result<Option<Vec<u8>>, StorageError> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let size = usize::try_from(file.metadata()?.len()).unwrap_or(usize::MAX);
    if size > limit {
        return Err(StorageError::TooLarge { got: size, limit });
    }
    let read_limit = u64::try_from(limit).unwrap_or(u64::MAX).saturating_add(1);
    let mut bytes = Vec::with_capacity(size);
    Read::by_ref(&mut file).take(read_limit).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(StorageError::TooLarge {
            got: bytes.len(),
            limit,
        });
    }
    Ok(Some(bytes))
}

pub(crate) async fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), StorageError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let path = path.to_path_buf();
    let bytes = bytes.to_vec();
    tokio::task::spawn_blocking(move || write_atomically_blocking(&path, &bytes))
        .await
        .map_err(|error| StorageError::Schema(format!("storage write task failed: {error}")))?
}

fn write_atomically_blocking(path: &Path, bytes: &[u8]) -> Result<(), StorageError> {
    let parent = path
        .parent()
        .ok_or_else(|| StorageError::Schema("storage path has no parent".into()))?;
    let file_name = path
        .file_name()
        .and_then(std::ffi::OsStr::to_str)
        .ok_or_else(|| StorageError::Schema("storage path has no valid file name".into()))?;
    let temp_path = parent.join(format!(".{file_name}.{}.tmp", Uuid::new_v4()));
    let result = write_and_replace(&temp_path, path, bytes);
    if result.is_err() {
        let _ = std::fs::remove_file(&temp_path);
    }
    result
}

fn write_and_replace(temp_path: &Path, path: &Path, bytes: &[u8]) -> Result<(), StorageError> {
    let mut handle = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(temp_path)?;
    handle.write_all(bytes)?;
    handle.sync_all()?;
    drop(handle);
    std::fs::rename(temp_path, path)?;
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    use tempfile::TempDir;

    use super::*;

    #[test]
    fn separate_processes_serialize_on_the_same_storage_path() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let first_marker = dir.path().join("first-acquired");
        let second_marker = dir.path().join("second-acquired");
        let executable = std::env::current_exe().unwrap();
        let mut first = Command::new(&executable)
            .args(["--exact", "file_access::tests::subprocess_holds_path_lock", "--ignored"])
            .env("TABLEPRO_LOCK_TEST_PATH", &path)
            .env("TABLEPRO_LOCK_TEST_MARKER", &first_marker)
            .env("TABLEPRO_LOCK_TEST_HOLD_MS", "500")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        wait_for_path(&first_marker);
        let mut second = Command::new(executable)
            .args(["--exact", "file_access::tests::subprocess_holds_path_lock", "--ignored"])
            .env("TABLEPRO_LOCK_TEST_PATH", &path)
            .env("TABLEPRO_LOCK_TEST_MARKER", &second_marker)
            .env("TABLEPRO_LOCK_TEST_HOLD_MS", "0")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();

        std::thread::sleep(Duration::from_millis(100));
        assert!(!second_marker.exists());
        assert!(first.wait().unwrap().success());
        assert!(second.wait().unwrap().success());
        assert!(second_marker.exists());
    }

    fn wait_for_path(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[tokio::test]
    #[ignore = "helper process spawned by other tests through --exact --ignored, not a standalone test"]
    async fn subprocess_holds_path_lock() {
        let path = PathBuf::from(std::env::var_os("TABLEPRO_LOCK_TEST_PATH").unwrap());
        let marker = PathBuf::from(std::env::var_os("TABLEPRO_LOCK_TEST_MARKER").unwrap());
        let hold_ms: u64 = std::env::var("TABLEPRO_LOCK_TEST_HOLD_MS").unwrap().parse().unwrap();
        let _guard = lock_path(&path).await.unwrap();
        std::fs::write(marker, b"acquired").unwrap();
        std::thread::sleep(Duration::from_millis(hold_ms));
    }
}
