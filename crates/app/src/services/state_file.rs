use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde::{Serialize, de::DeserializeOwned};

use super::config_io::atomic_write_json;

#[cfg(not(test))]
const FLUSH_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const FLUSH_TIMEOUT: Duration = Duration::from_secs(60);

pub struct StateFile<T> {
    shared: Arc<(Mutex<State<T>>, Condvar)>,
}

struct State<T> {
    value: T,
    revision: u64,
    // Last attempted revision, not last successful persistence. A failed write
    // settles waiters with write_error; it must not cause an unbounded retry loop.
    attempted: u64,
    read_error: Option<String>,
    write_error: Option<String>,
    closed: bool,
}

impl<T: Default + Clone + Serialize + DeserializeOwned + Send + 'static> StateFile<T> {
    pub(super) fn memory() -> Self {
        Self::with_writer(T::default(), None, |_| Ok(()))
    }

    pub fn load(path: PathBuf) -> Self {
        let loaded = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| error.to_string()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
            Err(error) => Err(error.to_string()),
        };
        let (value, read_error) = match loaded {
            Ok(value) => (value, None),
            Err(error) => {
                tracing::warn!(path = %path.display(), %error, "settings unreadable; preserving original file");
                (T::default(), Some(error))
            }
        };
        Self::with_writer(value, read_error, move |value| atomic_write_json(&path, value))
    }

    fn with_writer(
        value: T,
        read_error: Option<String>,
        write: impl Fn(&T) -> std::io::Result<()> + Send + 'static,
    ) -> Self {
        let shared = Arc::new((
            Mutex::new(State {
                value,
                revision: 0,
                attempted: 0,
                read_error,
                write_error: None,
                closed: false,
            }),
            Condvar::new(),
        ));
        let worker = shared.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("settings-writer".into())
            .spawn(move || {
                loop {
                    let (value, revision) = {
                        let (lock, wake) = &*worker;
                        let Ok(state) = lock.lock() else {
                            return;
                        };
                        let Ok(state) =
                            wake.wait_while(state, |state| state.revision == state.attempted && !state.closed)
                        else {
                            return;
                        };
                        if state.revision == state.attempted && state.closed {
                            return;
                        }
                        (state.value.clone(), state.revision)
                    };
                    let error = write(&value).err().map(|error| error.to_string());
                    if let Some(error) = error.as_ref() {
                        tracing::warn!(%error, "settings write failed");
                    }
                    let (lock, wake) = &*worker;
                    let Ok(mut state) = lock.lock() else {
                        return;
                    };
                    state.attempted = revision;
                    state.write_error = error;
                    wake.notify_all();
                }
            })
            && let Ok(mut state) = shared.0.lock()
        {
            state.read_error = Some(format!("settings writer unavailable: {error}"));
        }
        Self { shared }
    }

    pub fn read<R>(&self, read: impl FnOnce(&T) -> R) -> Option<R> {
        self.shared.0.lock().ok().map(|state| read(&state.value))
    }

    pub fn update(&self, update: impl FnOnce(&mut T)) -> Result<(), String> {
        let (lock, wake) = &*self.shared;
        let mut state = lock.lock().map_err(|_| "settings lock unavailable")?;
        if let Some(error) = &state.read_error {
            return Err(format!(
                "Settings were not saved because the existing file could not be read: {error}"
            ));
        }
        update(&mut state.value);
        state.revision += 1;
        wake.notify_all();
        Ok(())
    }

    pub fn flush(&self) -> Result<(), String> {
        let (lock, wake) = &*self.shared;
        let deadline = Instant::now() + FLUSH_TIMEOUT;
        let mut state = lock.lock().map_err(|_| "settings lock unavailable")?;
        let target = state.revision;
        while state.attempted < target {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err("settings flush timed out".into());
            }
            state = wake
                .wait_timeout(state, remaining)
                .map_err(|_| "settings lock unavailable")?
                .0;
        }
        match &state.write_error {
            Some(error) => Err(error.clone()),
            None => Ok(()),
        }
    }
}

impl<T> Drop for StateFile<T> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.shared.0.lock() {
            state.closed = true;
            self.shared.1.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_are_ordered_and_a_burst_is_coalesced() {
        let values = Arc::new(Mutex::new(Vec::new()));
        let written = values.clone();
        let (started, wait) = std::sync::mpsc::channel();
        let (release, hold) = std::sync::mpsc::channel();
        let file = StateFile::with_writer(0_u32, None, move |value| {
            if *value == 1 {
                started.send(()).unwrap();
                hold.recv_timeout(Duration::from_secs(5)).unwrap();
            }
            written.lock().unwrap().push(*value);
            Ok(())
        });
        file.update(|value| *value = 1).unwrap();
        wait.recv_timeout(Duration::from_secs(5)).unwrap();
        for value in 2..=100 {
            file.update(|current| *current = value).unwrap();
        }
        release.send(()).unwrap();
        file.flush().unwrap();
        assert_eq!(*values.lock().unwrap(), vec![1, 100]);
    }

    #[test]
    fn unreadable_files_are_preserved_and_write_failures_are_reported() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, b"broken json").unwrap();
        let file = StateFile::<Vec<u32>>::load(path.clone());
        assert!(file.update(|values| values.push(1)).is_err());
        file.flush().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"broken json");
        let failed = StateFile::with_writer(0_u32, None, |_| Err(std::io::Error::other("disk full")));
        failed.update(|value| *value = 1).unwrap();
        assert_eq!(failed.flush(), Err("disk full".into()));
    }
}
