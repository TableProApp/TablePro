//! Process-level single-instance gate.
//!
//! `gtk::Application::register()` already handles single-instance via
//! the DBus session bus on a healthy GNOME session: a second launch
//! sends `activate` to the primary and exits. That mechanism breaks
//! when DBus is unavailable (sandboxed / headless / minimal session)
//! and silently lets two processes through. Two TablePro processes
//! racing on `workspace_state.json` corrupt each other's tab state.
//!
//! This module adds a belt-and-suspenders `flock(2)` exclusive lock on
//! `$XDG_RUNTIME_DIR/tablepro.lock` (fallback `$XDG_CACHE_HOME` or
//! `$HOME/.cache`). Held for the lifetime of the returned `Lock`
//! guard. The kernel auto-releases the flock on process exit, so
//! crashes don't leak the lock.

use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::path::PathBuf;

const LOCK_FILE: &str = "tablepro.lock";

pub struct Lock {
    // Held only for its drop-side effect (closing the fd, which the
    // kernel turns into a flock release).
    _file: File,
}

#[derive(Debug)]
pub enum LockError {
    AlreadyRunning,
    Io(std::io::Error),
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockError::AlreadyRunning => write!(f, "another TablePro instance is already running"),
            LockError::Io(e) => write!(f, "single-instance lock io error: {e}"),
        }
    }
}

impl std::error::Error for LockError {}

fn lock_path() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        return Some(PathBuf::from(dir).join(LOCK_FILE));
    }
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    let dir = cache.join("tablepro");
    let _ = std::fs::create_dir_all(&dir);
    Some(dir.join(LOCK_FILE))
}

/// Try to acquire the process-wide single-instance lock. Returns
/// `Err(AlreadyRunning)` if another process holds it. The returned
/// guard must outlive every codepath that touches user-state JSON.
pub fn acquire() -> Result<Lock, LockError> {
    let Some(path) = lock_path() else {
        // No XDG_RUNTIME_DIR / XDG_CACHE_HOME / HOME: we can't even
        // place the lock file, so we can't enforce. Fall through —
        // the caller will treat this as a soft failure.
        return Err(LockError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "no XDG runtime / cache / HOME directory",
        )));
    };
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(LockError::Io)?;
    // SAFETY: `file` owns the fd for the duration of this call;
    // flock(2) is a thin syscall wrapper.
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        return Ok(Lock { _file: file });
    }
    let err = std::io::Error::last_os_error();
    if matches!(err.raw_os_error(), Some(libc::EWOULDBLOCK)) {
        Err(LockError::AlreadyRunning)
    } else {
        Err(LockError::Io(err))
    }
}
