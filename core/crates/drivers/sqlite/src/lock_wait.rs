//! Waiting for another connection's lock in a way a stop can end.
//!
//! SQLite's own busy timeout sleeps inside the call that wants the
//! lock, where the progress handler never runs, so a stop could not
//! reach a waiting statement before the lock timeout had passed. This
//! busy handler sleeps the same steps and looks at the call's flag
//! between them.
//!
//! The handler is a C callback, and its argument is the connection's own
//! handle used only as a key. What it reads is found through a weak
//! reference, so it never follows a pointer the wait may have outlived.

use std::ffi::{c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use sqlx::sqlite::LockedSqliteHandle;
use tablepro_core::DriverError;

/// The sleeps between tries, in milliseconds, as SQLite's own handler
/// takes them; past the end, the last one repeats.
const DELAYS_MS: [u64; 12] = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100];

/// Each connection's installed wait, by the address of its handle.
static WAITS: Mutex<Vec<(usize, Weak<LockWait>)>> = Mutex::new(Vec::new());

/// One call's lock wait: as long as the lock timeout, and over as soon
/// as the call's flag is raised.
#[derive(Debug)]
pub(crate) struct LockWait {
    stop: Arc<AtomicBool>,
    timeout: Duration,
}

impl LockWait {
    pub(crate) fn new(stop: Arc<AtomicBool>, timeout: Duration) -> Self {
        Self { stop, timeout }
    }

    pub(crate) fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    /// Make this the wait the connection's lock attempts answer to. The
    /// caller keeps it alive for as long as it is installed; once it is
    /// dropped, a lock attempt gives up at once.
    pub(crate) fn install(self: &Arc<Self>, handle: &mut LockedSqliteHandle<'_>) -> Result<(), DriverError> {
        let raw = handle.as_raw_handle();
        let key = raw.as_ptr().addr();
        {
            let mut waits = WAITS.lock().unwrap_or_else(PoisonError::into_inner);
            waits.retain(|(other, wait)| *other != key && wait.strong_count() > 0);
            waits.push((key, Arc::downgrade(self)));
        }
        // SAFETY: `raw` comes from the locked handle, and the lock guard
        // is held for the whole call, so the connection is open and no
        // statement runs on it meanwhile. The argument handed to the
        // callback is never dereferenced: `on_busy` uses it as a key.
        let code = unsafe { libsqlite3_sys::sqlite3_busy_handler(raw.as_ptr(), Some(on_busy), raw.as_ptr().cast()) };
        match code {
            libsqlite3_sys::SQLITE_OK => Ok(()),
            code => Err(DriverError::Protocol(format!(
                "SQLite refused the lock wait with code {code}"
            ))),
        }
    }

    /// Sleep before the next try for the lock, or say to stop trying.
    fn keep_waiting(&self, attempts: c_int) -> bool {
        let Some(delay) = next_delay(attempts, self.timeout) else {
            return false;
        };
        if self.stopped() {
            return false;
        }
        std::thread::sleep(delay);
        !self.stopped()
    }
}

/// How long to sleep after `attempts` failed tries, or nothing once the
/// sleeps so far have used the timeout up.
fn next_delay(attempts: c_int, timeout: Duration) -> Option<Duration> {
    let attempts = usize::try_from(attempts).ok()?;
    let ramp = DELAYS_MS.len().saturating_sub(1);
    let last = DELAYS_MS.last().copied().unwrap_or(0);
    let delay = DELAYS_MS.get(attempts).copied().unwrap_or(last);
    let repeats = u64::try_from(attempts.saturating_sub(ramp)).unwrap_or(u64::MAX);
    let prior = DELAYS_MS
        .iter()
        .take(attempts.min(ramp))
        .sum::<u64>()
        .saturating_add(last.saturating_mul(repeats));
    let timeout = u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX);
    let delay = delay.min(timeout.saturating_sub(prior));
    (delay > 0).then(|| Duration::from_millis(delay))
}

/// SQLite's busy handler: nonzero to try for the lock again.
extern "C" fn on_busy(connection: *mut c_void, attempts: c_int) -> c_int {
    let key = connection.addr();
    let wait = WAITS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|(other, _)| *other == key)
        .and_then(|(_, wait)| wait.upgrade());
    match wait {
        Some(wait) => c_int::from(wait.keep_waiting(attempts)),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn millis(value: u64) -> Option<Duration> {
        Some(Duration::from_millis(value))
    }

    #[test]
    fn the_sleeps_follow_sqlites_own_until_the_timeout() {
        let timeout = Duration::from_millis(400);

        assert_eq!(next_delay(0, timeout), millis(1));
        assert_eq!(next_delay(5, timeout), millis(20));
        assert_eq!(next_delay(11, timeout), millis(100));
        // The first twelve sleeps took 328 ms, so 72 are left.
        assert_eq!(next_delay(12, timeout), millis(72));
        assert_eq!(next_delay(13, timeout), None);
        assert_eq!(next_delay(0, Duration::ZERO), None);
        assert_eq!(next_delay(-1, timeout), None);
    }

    #[test]
    fn a_raised_flag_ends_the_wait() {
        let stop = Arc::new(AtomicBool::new(false));
        let wait = LockWait::new(stop.clone(), Duration::from_secs(10));

        assert!(wait.keep_waiting(0));
        stop.store(true, Ordering::SeqCst);
        assert!(!wait.keep_waiting(1));
    }
}
