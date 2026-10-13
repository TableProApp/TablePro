use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use tablepro_session::SessionKey;
use tablepro_session::runtime::Tasks;
use tablepro_storage::StorageError;
use tablepro_storage::document::{decode_document, encode_document};
use tokio::sync::{mpsc, oneshot};

use super::write_job::WriteJob;
use super::{WorkspaceFileName, WorkspaceLoad, WorkspaceLoadError, WorkspaceRecord, WorkspaceSaveError};

type WriteFile = dyn Fn(&Path, &[u8]) -> Result<(), StorageError> + Send + Sync;

/// Every session's saved tabs, one file each.
///
/// Writes go to one task that keeps only the newest record per file, so
/// a burst of tab changes costs one write, and each write runs on a
/// blocking thread. A file that could not be read is never written over
/// until the user resets it.
#[derive(Clone)]
pub struct WorkspaceStore {
    inner: Rc<StoreInner>,
}

struct StoreInner {
    dir: PathBuf,
    tasks: Tasks,
    writer: mpsc::UnboundedSender<WriteJob>,
    blocked: RefCell<HashSet<SessionKey>>,
}

impl WorkspaceStore {
    pub fn start(dir: PathBuf, tasks: &Tasks) -> Self {
        Self::start_with(dir, tasks, Arc::new(tablepro_storage::fs::write_private_blocking))
    }

    fn start_with(dir: PathBuf, tasks: &Tasks, write: Arc<WriteFile>) -> Self {
        let (writer, jobs) = mpsc::unbounded_channel();
        // Detached, so the last store going closes the channel and the
        // task ends once what it was handed is written.
        drop(tasks.spawn_task(run_writer(jobs, tasks.clone(), write)));
        Self {
            inner: Rc::new(StoreInner {
                dir,
                tasks: tasks.clone(),
                writer,
                blocked: RefCell::default(),
            }),
        }
    }

    /// Read a session's saved tabs, after any write already queued for
    /// it has landed.
    pub fn load(&self, key: &SessionKey) -> impl Future<Output = WorkspaceLoad> + use<> {
        let inner = self.inner.clone();
        let key = key.clone();
        let path = self.inner.path(&key);
        let written = self.inner.queue_flush(&path);
        async move {
            // A failed write still leaves whatever is on disk to read.
            let _ = written.await;
            let reading = path.clone();
            let load = inner
                .tasks
                .spawn_blocking_task(move || read_record(&reading))
                .await
                .unwrap_or_else(|failure| WorkspaceLoad::Blocked(WorkspaceLoadError::Io(failure.to_string())));
            match &load {
                WorkspaceLoad::Blocked(error) => {
                    tracing::warn!(%error, path = %path.display(), "keeping the saved tabs as they are");
                    inner.blocked.borrow_mut().insert(key);
                }
                WorkspaceLoad::Restored(_) | WorkspaceLoad::Empty => {
                    inner.blocked.borrow_mut().remove(&key);
                }
            }
            load
        }
    }

    /// Queue `record` as the session's saved tabs. A newer record for the
    /// same session replaces it if the writer has not reached it yet.
    pub fn schedule(&self, key: &SessionKey, record: WorkspaceRecord) -> Result<(), WorkspaceSaveError> {
        if self.is_blocked(key) {
            return Err(WorkspaceSaveError::Blocked);
        }
        self.inner
            .writer
            .send(WriteJob::Write {
                path: self.inner.path(key),
                record,
            })
            .map_err(|_| WorkspaceSaveError::WriterStopped)
    }

    /// Resolves once every record queued so far for the session is on
    /// disk, with how the last write of it went.
    pub fn flush(&self, key: &SessionKey) -> impl Future<Output = Result<(), WorkspaceSaveError>> + use<> {
        let written = (!self.is_blocked(key)).then(|| self.inner.queue_flush(&self.inner.path(key)));
        async move {
            let Some(written) = written else {
                return Err(WorkspaceSaveError::Blocked);
            };
            written.await.unwrap_or(Err(WorkspaceSaveError::WriterStopped))
        }
    }

    /// Move a file that could not be read aside, bytes and all, and let
    /// the session save again. Gives the name the file now has, or `None`
    /// when there was no file.
    pub fn reset(&self, key: &SessionKey) -> impl Future<Output = Result<Option<PathBuf>, WorkspaceSaveError>> + use<> {
        let inner = self.inner.clone();
        let key = key.clone();
        let path = self.inner.path(&key);
        async move {
            let moved = inner
                .tasks
                .spawn_blocking_task(move || move_aside(&path))
                .await
                .unwrap_or_else(|failure| Err(WorkspaceSaveError::MoveAside(failure.to_string())))?;
            inner.blocked.borrow_mut().remove(&key);
            Ok(moved)
        }
    }

    pub fn is_blocked(&self, key: &SessionKey) -> bool {
        self.inner.blocked.borrow().contains(key)
    }
}

impl StoreInner {
    fn path(&self, key: &SessionKey) -> PathBuf {
        self.dir.join(WorkspaceFileName::for_key(key).file_name())
    }

    fn queue_flush(&self, path: &Path) -> oneshot::Receiver<Result<(), WorkspaceSaveError>> {
        let (written, receiver) = oneshot::channel();
        // A writer that has stopped drops the job, and with it the
        // sender, which the receiver reports.
        let _ = self.writer.send(WriteJob::Flush {
            path: path.to_owned(),
            written,
        });
        receiver
    }
}

/// The jobs that arrived while the writer was busy. Only the newest
/// record per file is kept, and every waiter is answered after the
/// writes it queued behind.
#[derive(Default)]
struct Round {
    records: BTreeMap<PathBuf, WorkspaceRecord>,
    waiting: Vec<(PathBuf, oneshot::Sender<Result<(), WorkspaceSaveError>>)>,
}

impl Round {
    fn take(&mut self, job: WriteJob) {
        match job {
            WriteJob::Write { path, record } => {
                self.records.insert(path, record);
            }
            WriteJob::Flush { path, written } => self.waiting.push((path, written)),
        }
    }
}

async fn run_writer(mut jobs: mpsc::UnboundedReceiver<WriteJob>, tasks: Tasks, write: Arc<WriteFile>) {
    let mut last: HashMap<PathBuf, Result<(), WorkspaceSaveError>> = HashMap::new();
    while let Some(job) = jobs.recv().await {
        let mut round = Round::default();
        round.take(job);
        while let Ok(job) = jobs.try_recv() {
            round.take(job);
        }
        for (path, record) in round.records {
            let outcome = write_record(&tasks, &write, path.clone(), record).await;
            last.insert(path, outcome);
        }
        for (path, written) in round.waiting {
            let _ = written.send(last.get(&path).cloned().unwrap_or(Ok(())));
        }
    }
}

async fn write_record(
    tasks: &Tasks,
    write: &Arc<WriteFile>,
    path: PathBuf,
    record: WorkspaceRecord,
) -> Result<(), WorkspaceSaveError> {
    let write = write.clone();
    let shown = path.display().to_string();
    let outcome = tasks
        .spawn_blocking_task(move || {
            let bytes = encode_document(&record).map_err(|error| WorkspaceSaveError::Write(error.to_string()))?;
            write(&path, &bytes).map_err(|error| WorkspaceSaveError::Write(error.to_string()))
        })
        .await
        .unwrap_or_else(|failure| Err(WorkspaceSaveError::Write(failure.to_string())));
    if let Err(error) = &outcome {
        tracing::warn!(%error, path = %shown, "could not save the open tabs");
    }
    outcome
}

fn read_record(path: &Path) -> WorkspaceLoad {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return WorkspaceLoad::Empty,
        Err(error) => return WorkspaceLoad::Blocked(WorkspaceLoadError::Io(error.to_string())),
    };
    match decode_document::<WorkspaceRecord>(path, &bytes) {
        Ok(record) => WorkspaceLoad::Restored(record.clamped()),
        Err(problem) => WorkspaceLoad::Blocked(problem.into()),
    }
}

fn move_aside(path: &Path) -> Result<Option<PathBuf>, WorkspaceSaveError> {
    if let Err(error) = std::fs::symlink_metadata(path)
        && error.kind() == ErrorKind::NotFound
    {
        return Ok(None);
    }
    tablepro_storage::fs::move_aside_blocking(path, std::time::SystemTime::now())
        .map(Some)
        .map_err(|error| WorkspaceSaveError::MoveAside(error.to_string()))
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Mutex;

    use tablepro_storage::DraftId;
    use uuid::Uuid;

    use super::*;
    use crate::test_support::paused_tasks;
    use crate::workspace::TabRecord;

    fn key() -> SessionKey {
        SessionKey::Saved(Uuid::new_v4())
    }

    fn record(tables: usize) -> WorkspaceRecord {
        WorkspaceRecord {
            active_tab: Some(0),
            tabs: (0..tables)
                .map(|index| TabRecord::Table {
                    schema: None,
                    table: format!("t{index}"),
                    offset: 0,
                    page_size: 1_000,
                    sort: None,
                })
                .collect(),
        }
    }

    struct Fixture {
        root: tempfile::TempDir,
        store: WorkspaceStore,
    }

    impl Fixture {
        fn new() -> Self {
            let root = tempfile::tempdir().expect("tempdir");
            let store = WorkspaceStore::start(root.path().join("workspaces"), &paused_tasks());
            Self { root, store }
        }

        fn path(&self, key: &SessionKey) -> PathBuf {
            self.root
                .path()
                .join("workspaces")
                .join(WorkspaceFileName::for_key(key).file_name())
        }

        fn seed(&self, key: &SessionKey, bytes: &[u8]) -> PathBuf {
            let path = self.path(key);
            std::fs::create_dir_all(path.parent().expect("a parent")).expect("mkdir");
            std::fs::write(&path, bytes).expect("seed");
            path
        }

        fn on_disk(&self, key: &SessionKey) -> WorkspaceRecord {
            let path = self.path(key);
            let bytes = std::fs::read(&path).expect("the file was written");
            decode_document(&path, &bytes).expect("a record")
        }
    }

    #[tokio::test]
    async fn notfound_loads_empty() {
        let fixture = Fixture::new();
        let key = key();

        assert_eq!(fixture.store.load(&key).await, WorkspaceLoad::Empty);
        assert!(!fixture.store.is_blocked(&key));
    }

    #[tokio::test]
    async fn flush_waits_for_pending_write() {
        let fixture = Fixture::new();
        let key = key();

        fixture.store.schedule(&key, record(2)).expect("scheduled");
        fixture.store.flush(&key).await.expect("written");

        assert_eq!(fixture.on_disk(&key), record(2));
    }

    #[tokio::test]
    async fn load_reads_a_record_still_queued() {
        let fixture = Fixture::new();
        let key = key();
        let editor = WorkspaceRecord {
            active_tab: Some(0),
            tabs: vec![TabRecord::Editor { draft: DraftId::new() }],
        };

        fixture.store.schedule(&key, editor.clone()).expect("scheduled");

        assert_eq!(fixture.store.load(&key).await, WorkspaceLoad::Restored(editor));
    }

    #[tokio::test]
    async fn written_file_mode_0600() {
        let fixture = Fixture::new();
        let key = key();

        fixture.store.schedule(&key, record(1)).expect("scheduled");
        fixture.store.flush(&key).await.expect("written");

        let mode = std::fs::metadata(fixture.path(&key))
            .expect("metadata")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[tokio::test]
    async fn unsupported_version_blocks_key() {
        let fixture = Fixture::new();
        let key = key();
        fixture.seed(&key, br#"{"version": 2, "tabs": []}"#);

        let load = fixture.store.load(&key).await;

        assert_eq!(
            load,
            WorkspaceLoad::Blocked(WorkspaceLoadError::UnsupportedVersion {
                found: Some(2),
                expected: 1
            })
        );
        assert_eq!(
            fixture.store.schedule(&key, record(1)),
            Err(WorkspaceSaveError::Blocked)
        );
    }

    #[tokio::test]
    async fn blocked_key_leaves_bytes_unchanged() {
        let fixture = Fixture::new();
        let (key, other) = (key(), key());
        let original = b"{ not json";
        let path = fixture.seed(&key, original);

        let load = fixture.store.load(&key).await;
        let scheduled = fixture.store.schedule(&key, record(1));
        let flushed = fixture.store.flush(&key).await;
        fixture
            .store
            .schedule(&other, record(1))
            .expect("another key still saves");
        fixture.store.flush(&other).await.expect("written");

        assert!(
            matches!(load, WorkspaceLoad::Blocked(WorkspaceLoadError::Corrupt(_))),
            "{load:?}"
        );
        assert_eq!(scheduled, Err(WorkspaceSaveError::Blocked));
        assert_eq!(flushed, Err(WorkspaceSaveError::Blocked));
        assert_eq!(std::fs::read(&path).expect("read"), original);
    }

    #[tokio::test]
    async fn reset_moves_aside_and_unblocks() {
        let fixture = Fixture::new();
        let key = key();
        let original = b"{ not json";
        let path = fixture.seed(&key, original);
        assert!(matches!(fixture.store.load(&key).await, WorkspaceLoad::Blocked(_)));

        let moved = fixture.store.reset(&key).await.expect("reset").expect("a moved file");

        let moved_name = moved.file_name().expect("a name").to_string_lossy().into_owned();
        let name = WorkspaceFileName::for_key(&key).file_name();
        assert!(moved_name.starts_with(&format!("{name}.corrupt-")), "{moved_name}");
        assert_eq!(std::fs::read(&moved).expect("read the moved file"), original);
        assert!(!path.exists());
        assert!(!fixture.store.is_blocked(&key));
        fixture.store.schedule(&key, record(1)).expect("saves again");
        fixture.store.flush(&key).await.expect("written");
        assert_eq!(fixture.on_disk(&key), record(1));
    }

    #[tokio::test]
    async fn reset_without_a_file_unblocks() {
        let fixture = Fixture::new();

        assert_eq!(fixture.store.reset(&key()).await, Ok(None));
    }

    #[tokio::test]
    async fn writer_coalesces_latest_record_per_key() {
        let root = tempfile::tempdir().expect("tempdir");
        let written: Arc<Mutex<Vec<(PathBuf, usize)>>> = Arc::default();
        let (started, mut starts) = mpsc::unbounded_channel::<()>();
        // Holds the first write open, so the rest arrive while it runs.
        let (release, hold) = std::sync::mpsc::channel::<()>();
        let hold = Mutex::new(hold);
        let log = written.clone();
        let write: Arc<WriteFile> = Arc::new(move |path: &Path, bytes: &[u8]| {
            let record: WorkspaceRecord = decode_document(path, bytes).expect("a record");
            let first = {
                let mut log = log.lock().expect("the log");
                log.push((path.to_owned(), record.tabs.len()));
                log.len() == 1
            };
            let _ = started.send(());
            if first {
                let _ = hold.lock().expect("the hold").recv();
            }
            Ok(())
        });
        let store = WorkspaceStore::start_with(root.path().to_owned(), &paused_tasks(), write);
        let (a, b) = (key(), key());
        let path_a = store.inner.path(&a);
        let path_b = store.inner.path(&b);

        store.schedule(&a, record(1)).expect("scheduled");
        starts.recv().await.expect("the first write started");
        for tables in [2, 3] {
            store.schedule(&a, record(tables)).expect("scheduled");
        }
        store.schedule(&b, record(4)).expect("scheduled");
        release.send(()).expect("release the first write");
        store.flush(&a).await.expect("a written");
        store.flush(&b).await.expect("b written");

        let written = written.lock().expect("the log").clone();
        let for_path = |path: &PathBuf| -> Vec<usize> {
            written
                .iter()
                .filter(|(written, _)| written == path)
                .map(|(_, tables)| *tables)
                .collect()
        };
        assert_eq!(for_path(&path_a), [1, 3], "{written:?}");
        assert_eq!(for_path(&path_b), [4], "{written:?}");
    }

    #[tokio::test]
    async fn a_failed_write_is_reported_by_flush() {
        let root = tempfile::tempdir().expect("tempdir");
        let write: Arc<WriteFile> = Arc::new(|path: &Path, _: &[u8]| {
            Err(StorageError::Io {
                path: path.to_owned(),
                source: std::io::Error::other("disk full"),
            })
        });
        let store = WorkspaceStore::start_with(root.path().to_owned(), &paused_tasks(), write);
        let key = key();

        store.schedule(&key, record(1)).expect("scheduled");

        assert!(matches!(store.flush(&key).await, Err(WorkspaceSaveError::Write(_))));
    }
}
