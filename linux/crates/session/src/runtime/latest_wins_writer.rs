use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tokio::sync::watch;
use tokio_util::task::AbortOnDropHandle;

use super::Tasks;

/// Persists the newest value and drops the ones a burst overtook.
///
/// Dragging a column edge or clicking Apply a few times in a row
/// produces one value per event, and only the last one is worth having
/// on disk. One write runs at a time; when it finishes, whatever value
/// is newest by then goes out next. A hundred events cost two writes,
/// not a hundred.
pub struct LatestWinsWriter<T> {
    latest: watch::Sender<Option<Pending<T>>>,
    /// The last sequence that reached the disk. `flush` waits on this.
    written: watch::Receiver<u64>,
    sequence: AtomicU64,
    _worker: AbortOnDropHandle<()>,
}

/// A value and the `put` that produced it, so a waiter can tell which
/// writes have landed.
struct Pending<T> {
    sequence: u64,
    value: Arc<T>,
}

impl<T> Clone for Pending<T> {
    fn clone(&self) -> Self {
        Self {
            sequence: self.sequence,
            value: self.value.clone(),
        }
    }
}

impl<T: Send + Sync + 'static> LatestWinsWriter<T> {
    /// `write` blocks, so it runs on a blocking thread rather than a
    /// runtime worker.
    pub fn spawn<W>(tasks: &Tasks, write: W) -> Self
    where
        W: Fn(&T) + Send + Sync + 'static,
    {
        let (latest, mut newest) = watch::channel(None::<Pending<T>>);
        let (done, written) = watch::channel(0_u64);
        let write = Arc::new(write);
        let tasks_for_writes = tasks.clone();

        let worker = tasks.spawn_owned(async move {
            while newest.changed().await.is_ok() {
                // The guard cannot be held across the await below, and
                // the value is refcounted, so this is a pointer copy.
                let Some(pending) = newest.borrow_and_update().clone() else {
                    continue;
                };
                let write = write.clone();
                let value = pending.value;
                if let Err(failure) = tasks_for_writes.spawn_blocking_task(move || write(&value)).await {
                    tracing::warn!(%failure, "a state write did not finish");
                }
                // Published even when the write failed: a waiter is
                // waiting for the attempt to be over, not for it to
                // have worked.
                done.send_replace(pending.sequence);
            }
        });

        Self {
            latest,
            written,
            sequence: AtomicU64::new(0),
            _worker: worker,
        }
    }

    /// Hand over a value to write, replacing one that has not gone out
    /// yet.
    pub fn put(&self, value: T) {
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        // `send_replace` rather than `send`: the worker is the only
        // receiver and `send` would throw the value away if it had
        // already stopped.
        self.latest.send_replace(Some(Pending {
            sequence,
            value: Arc::new(value),
        }));
    }

    /// Resolves once every value handed over so far has been written.
    ///
    /// The app awaits this before it quits, so the last drag of a
    /// column edge is not lost to a runtime that stopped first.
    pub fn flush(&self) -> impl Future<Output = ()> + Send + 'static {
        let target = self.sequence.load(Ordering::Relaxed);
        let mut written = self.written.clone();
        async move {
            while *written.borrow_and_update() < target {
                // The worker is gone, so nothing more will ever be
                // written and waiting longer would hang the quit.
                if written.changed().await.is_err() {
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::test_support::paused_tasks;

    #[tokio::test]
    async fn a_burst_during_a_write_collapses_to_the_last_value() {
        let tasks = paused_tasks();
        let written: Arc<Mutex<Vec<i32>>> = Arc::new(Mutex::new(Vec::new()));
        let (started, mut starts) = tokio::sync::mpsc::unbounded_channel();
        let (finished, mut finishes) = tokio::sync::mpsc::unbounded_channel();
        // Holds the first write open so the rest of the burst arrives
        // while it is still running.
        let (release, hold) = std::sync::mpsc::channel::<()>();
        let hold = Mutex::new(hold);

        let written_by_writes = written.clone();
        let writer = LatestWinsWriter::spawn(&tasks, move |value: &i32| {
            let _ = started.send(*value);
            if *value == 0 {
                let _ = hold.lock().expect("the hold").recv();
            }
            written_by_writes.lock().expect("the log").push(*value);
            let _ = finished.send(*value);
        });

        writer.put(0);
        assert_eq!(starts.recv().await, Some(0), "the first value never started writing");
        for value in 1..=99 {
            writer.put(value);
        }
        release.send(()).expect("release the first write");

        assert_eq!(finishes.recv().await, Some(0));
        assert_eq!(finishes.recv().await, Some(99));
        assert_eq!(
            *written.lock().expect("the log"),
            vec![0, 99],
            "the burst was not collapsed"
        );
    }

    #[tokio::test]
    async fn flush_resolves_once_the_last_value_is_on_disk() {
        let tasks = paused_tasks();
        let written: Arc<Mutex<Vec<i32>>> = Arc::new(Mutex::new(Vec::new()));
        let written_by_writes = written.clone();
        let writer = LatestWinsWriter::spawn(&tasks, move |value: &i32| {
            written_by_writes.lock().expect("the log").push(*value);
        });

        for value in 0..10 {
            writer.put(value);
        }
        writer.flush().await;

        let log = written.lock().expect("the log");
        assert_eq!(
            log.last(),
            Some(&9),
            "flush returned before the last value landed: {log:?}"
        );
    }

    #[tokio::test]
    async fn flush_returns_at_once_when_nothing_was_written() {
        let tasks = paused_tasks();
        let writer = LatestWinsWriter::spawn(&tasks, |_: &i32| {});

        tokio::time::timeout(std::time::Duration::from_secs(1), writer.flush())
            .await
            .expect("flush hung with nothing to write");
    }

    #[tokio::test]
    async fn dropping_the_writer_stops_the_worker() {
        let tasks = paused_tasks();
        let (started, mut starts) = tokio::sync::mpsc::unbounded_channel();

        let writer = LatestWinsWriter::spawn(&tasks, move |value: &i32| {
            let _ = started.send(*value);
        });
        writer.put(1);
        assert_eq!(starts.recv().await, Some(1));

        drop(writer);

        assert_eq!(starts.recv().await, None, "the worker outlived its writer");
    }
}
