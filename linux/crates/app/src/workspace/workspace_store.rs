use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use futures::future::Either;
use tablepro_session::SessionKey;
use tablepro_session::runtime::Tasks;
use tablepro_storage::document::{VersionedDocument, decode_document, encode_document};
use tablepro_storage::{DraftScope, DraftStore, StorageError};
use tokio::sync::{mpsc, oneshot};

use super::open_sessions_record::read_open_sessions_blocking;
use super::write_job::WriteJob;
use super::writes_in_flight::{OutsideWrites, WritesInFlight};
use super::{
    OpenSessionsLoad, OpenSessionsRecord, WorkspaceFileName, WorkspaceLoad, WorkspaceLoadError, WorkspaceRecord,
    WorkspaceSaveError,
};

type WriteFile = dyn Fn(&Path, &[u8]) -> Result<(), StorageError> + Send + Sync;

/// Thousands of tabs encode to less than this. A file past it is read
/// no further, so a runaway one costs no memory to refuse.
pub(super) const MAX_FILE_BYTES: u64 = 1024 * 1024;

/// Every session's saved tabs, one file each, and which sessions the
/// windows show.
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
    moved_aside: RefCell<HashSet<SessionKey>>,
    outside: Rc<OutsideWrites>,
}

impl WorkspaceStore {
    /// `drafts` is where the editor tabs of these workspaces keep their
    /// text, which a purge deletes with the workspace.
    pub fn start(dir: PathBuf, drafts: DraftStore, tasks: &Tasks) -> Self {
        Self::start_with(
            dir,
            drafts,
            tasks,
            Arc::new(tablepro_storage::fs::write_private_blocking),
        )
    }

    fn start_with(dir: PathBuf, drafts: DraftStore, tasks: &Tasks, write: Arc<WriteFile>) -> Self {
        let (writer, jobs) = mpsc::unbounded_channel();
        // Detached, so the last store going closes the channel and the
        // task ends once what it was handed is written.
        drop(tasks.spawn_task(run_writer(jobs, tasks.clone(), drafts, write)));
        Self {
            inner: Rc::new(StoreInner {
                dir,
                tasks: tasks.clone(),
                writer,
                blocked: RefCell::default(),
                moved_aside: RefCell::default(),
                outside: Rc::default(),
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
            let (load, moved_aside) = inner
                .tasks
                .spawn_blocking_task(move || (read_record(&reading), moved_aside_exists(&reading)))
                .await
                .unwrap_or_else(|failure| {
                    (
                        WorkspaceLoad::Blocked(WorkspaceLoadError::Io(failure.to_string())),
                        true,
                    )
                });
            if moved_aside {
                inner.moved_aside.borrow_mut().insert(key.clone());
            } else {
                inner.moved_aside.borrow_mut().remove(&key);
            }
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
    /// when nothing was moved: there was no file, or it could be read.
    pub fn reset(&self, key: &SessionKey) -> impl Future<Output = Result<Option<PathBuf>, WorkspaceSaveError>> + use<> {
        // Checked now: a Reset clicked after a switch to another session
        // names that session, whose file may be fine.
        let blocked = self.is_blocked(key);
        let inner = self.inner.clone();
        let key = key.clone();
        let path = self.inner.path(&key);
        async move {
            if !blocked {
                return Ok(None);
            }
            let moved = inner
                .tasks
                .spawn_blocking_task(move || move_aside(&path))
                .await
                .unwrap_or_else(|failure| Err(WorkspaceSaveError::MoveAside(failure.to_string())))?;
            inner.blocked.borrow_mut().remove(&key);
            if moved.is_some() {
                inner.moved_aside.borrow_mut().insert(key);
            }
            Ok(moved)
        }
    }

    /// Note writes for `key` that run outside the store, such as the
    /// drafts of a workspace being closed. A purge of `key` waits for
    /// them until the returned value drops.
    pub fn writes_in_flight(&self, key: &SessionKey) -> WritesInFlight {
        self.inner.outside.begin(key)
    }

    /// Delete everything kept for a session whose connection is gone:
    /// its saved tabs, any copy of them Reset moved aside, and its
    /// drafts. A record still queued for it is never written.
    ///
    /// It goes through the writer, so a write queued before it cannot
    /// land after it and bring the file back. It also waits for the
    /// session's writes in flight outside the store, or a draft landing
    /// late would bring its directory back.
    pub fn purge(&self, key: &SessionKey) -> impl Future<Output = Result<(), WorkspaceSaveError>> + use<> {
        self.inner.blocked.borrow_mut().remove(key);
        self.inner.moved_aside.borrow_mut().remove(key);
        let path = self.inner.path(key);
        let drafts = WorkspaceFileName::for_key(key).draft_scope();
        let purging = match self.inner.outside.landing(key) {
            // Queued at once, so a record scheduled before the purge is
            // dropped in the same round rather than written.
            None => Either::Left(queue_purge(&self.inner.writer, path, drafts)),
            Some(landing) => {
                let writer = self.inner.writer.clone();
                Either::Right(async move {
                    // A store that went drops the sender, which ends the
                    // wait just the same.
                    let _ = landing.await;
                    queue_purge(&writer, path, drafts).await
                })
            }
        };
        async move { purging.await.unwrap_or(Err(WorkspaceSaveError::WriterStopped)) }
    }

    /// Remove the saved tabs and drafts of every other database of the
    /// connection `id` that was ever open beside it, as `purge` does for
    /// one session. Their names hold a digest of the database, so the
    /// writer finds them by the connection's part.
    pub fn purge_databases_of(&self, id: uuid::Uuid) -> impl Future<Output = Result<(), WorkspaceSaveError>> + use<> {
        let of_connection = |key: &SessionKey| matches!(key, SessionKey::SavedIn { id: of, .. } if *of == id);
        self.inner.blocked.borrow_mut().retain(|key| !of_connection(key));
        self.inner.moved_aside.borrow_mut().retain(|key| !of_connection(key));
        let landings: Vec<_> = self
            .inner
            .outside
            .keys_in_flight(of_connection)
            .iter()
            .filter_map(|key| self.inner.outside.landing(key))
            .collect();
        let (dir, writer) = (self.inner.dir.clone(), self.inner.writer.clone());
        let prefix = WorkspaceFileName::databases_prefix(id);
        async move {
            for landing in landings {
                let _ = landing.await;
            }
            let (purged, receiver) = oneshot::channel();
            let _ = writer.send(WriteJob::PurgeNamed { dir, prefix, purged });
            receiver.await.unwrap_or(Err(WorkspaceSaveError::WriterStopped))
        }
    }

    /// Queue `record` as the sessions the windows show. A newer one
    /// replaces it if the writer has not reached it yet.
    pub fn schedule_open_sessions(&self, record: OpenSessionsRecord) -> Result<(), WorkspaceSaveError> {
        self.inner
            .writer
            .send(WriteJob::OpenSessions {
                path: self.inner.open_sessions_path(),
                record,
            })
            .map_err(|_| WorkspaceSaveError::WriterStopped)
    }

    /// Resolves once every open-sessions record queued so far is on
    /// disk, with how the last write of it went.
    pub fn flush_open_sessions(&self) -> impl Future<Output = Result<(), WorkspaceSaveError>> + use<> {
        let written = self.inner.queue_flush(&self.inner.open_sessions_path());
        async move { written.await.unwrap_or(Err(WorkspaceSaveError::WriterStopped)) }
    }

    /// Read which sessions the windows showed, after any record already
    /// queued has landed.
    pub fn load_open_sessions(&self) -> impl Future<Output = OpenSessionsLoad> + use<> {
        let inner = self.inner.clone();
        let path = self.inner.open_sessions_path();
        let written = self.inner.queue_flush(&path);
        async move {
            let _ = written.await;
            inner
                .tasks
                .spawn_blocking_task(move || read_open_sessions_blocking(&path))
                .await
                .unwrap_or_else(|failure| {
                    tracing::warn!(%failure, "could not read which sessions were open");
                    OpenSessionsLoad::Empty
                })
        }
    }

    pub fn is_blocked(&self, key: &SessionKey) -> bool {
        self.inner.blocked.borrow().contains(key)
    }

    /// Whether a copy of the session's file that Reset moved aside is
    /// still there, as of the last load or reset. It may name drafts
    /// that no saved tab does.
    pub fn has_moved_aside_copy(&self, key: &SessionKey) -> bool {
        self.inner.moved_aside.borrow().contains(key)
    }
}

impl StoreInner {
    fn path(&self, key: &SessionKey) -> PathBuf {
        self.dir.join(WorkspaceFileName::for_key(key).file_name())
    }

    fn open_sessions_path(&self) -> PathBuf {
        self.dir.join(OpenSessionsRecord::FILE_NAME)
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

type Reply = oneshot::Sender<Result<(), WorkspaceSaveError>>;

fn queue_purge(
    writer: &mpsc::UnboundedSender<WriteJob>,
    path: PathBuf,
    drafts: DraftScope,
) -> oneshot::Receiver<Result<(), WorkspaceSaveError>> {
    let (purged, receiver) = oneshot::channel();
    let _ = writer.send(WriteJob::Purge { path, drafts, purged });
    receiver
}

/// The jobs that arrived while the writer was busy. Only the newest
/// record per file is kept, and every waiter is answered after the
/// writes it queued behind.
#[derive(Default)]
struct Round {
    records: BTreeMap<PathBuf, WorkspaceRecord>,
    /// A purge wins over a record queued for its file in the same
    /// round, whichever came first.
    purges: Vec<(PathBuf, DraftScope, Reply)>,
    named_purges: Vec<(PathBuf, String, Reply)>,
    open_sessions: Option<(PathBuf, OpenSessionsRecord)>,
    waiting: Vec<(PathBuf, Reply)>,
}

impl Round {
    fn take(&mut self, job: WriteJob) {
        match job {
            WriteJob::Write { path, record } => {
                self.records.insert(path, record);
            }
            WriteJob::OpenSessions { path, record } => self.open_sessions = Some((path, record)),
            WriteJob::Flush { path, written } => self.waiting.push((path, written)),
            WriteJob::Purge { path, drafts, purged } => self.purges.push((path, drafts, purged)),
            WriteJob::PurgeNamed { dir, prefix, purged } => self.named_purges.push((dir, prefix, purged)),
        }
    }

    fn purges_path(&self, path: &Path) -> bool {
        self.purges.iter().any(|(purged, ..)| purged == path)
            || self
                .named_purges
                .iter()
                .any(|(_, prefix, _)| file_name_starts_with(path, prefix))
    }
}

fn file_name_starts_with(path: &Path, prefix: &str) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with(prefix))
}

async fn run_writer(
    mut jobs: mpsc::UnboundedReceiver<WriteJob>,
    tasks: Tasks,
    drafts: DraftStore,
    write: Arc<WriteFile>,
) {
    let mut last: HashMap<PathBuf, Result<(), WorkspaceSaveError>> = HashMap::new();
    while let Some(job) = jobs.recv().await {
        let mut round = Round::default();
        round.take(job);
        while let Ok(job) = jobs.try_recv() {
            round.take(job);
        }
        let records = std::mem::take(&mut round.records);
        for (path, record) in records {
            if round.purges_path(&path) {
                continue;
            }
            let outcome = write_record(&tasks, &write, path.clone(), record).await;
            last.insert(path, outcome);
        }
        if let Some((path, record)) = round.open_sessions {
            let outcome = write_record(&tasks, &write, path.clone(), record).await;
            last.insert(path, outcome);
        }
        for (path, scope, reply) in round.purges {
            last.remove(&path);
            let store = drafts.clone();
            let outcome = tasks
                .spawn_blocking_task(move || purge_blocking(&path, &store, &scope))
                .await
                .unwrap_or_else(|failure| Err(WorkspaceSaveError::Purge(failure.to_string())));
            if let Err(error) = &outcome {
                tracing::warn!(%error, "could not delete a deleted connection's saved tabs");
            }
            let _ = reply.send(outcome);
        }
        for (dir, prefix, reply) in round.named_purges {
            last.retain(|path, _| !file_name_starts_with(path, &prefix));
            let store = drafts.clone();
            let outcome = tasks
                .spawn_blocking_task(move || purge_named_blocking(&dir, &store, &prefix))
                .await
                .unwrap_or_else(|failure| Err(WorkspaceSaveError::Purge(failure.to_string())));
            if let Err(error) = &outcome {
                tracing::warn!(%error, "could not delete the saved tabs of a deleted connection's databases");
            }
            let _ = reply.send(outcome);
        }
        for (path, written) in round.waiting {
            let _ = written.send(last.get(&path).cloned().unwrap_or(Ok(())));
        }
    }
}

/// Every part is tried, so one that fails leaves no more behind than
/// it has to; the first failure is the one reported.
fn purge_blocking(path: &Path, drafts: &DraftStore, scope: &DraftScope) -> Result<(), WorkspaceSaveError> {
    let file = match std::fs::remove_file(path) {
        Err(error) if error.kind() != ErrorKind::NotFound => Err(error.to_string()),
        _ => Ok(()),
    };
    let copies = tablepro_storage::fs::remove_moved_aside_blocking(path)
        .map(drop)
        .map_err(|error| error.to_string());
    let drafts = drafts.delete_scope_blocking(scope).map_err(|error| error.to_string());
    file.and(copies).and(drafts).map_err(WorkspaceSaveError::Purge)
}

/// Every session named with `prefix` in `dir` or in the drafts, whether
/// it left a file, only a copy moved aside as `<name>.json.corrupt-…`,
/// or only drafts. Each is purged as `purge_blocking` does; the first
/// failure is the one reported.
fn purge_named_blocking(dir: &Path, drafts: &DraftStore, prefix: &str) -> Result<(), WorkspaceSaveError> {
    let mut stems = std::collections::BTreeSet::new();
    for root in [dir, drafts.root()] {
        let entries = match std::fs::read_dir(root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(error) => return Err(WorkspaceSaveError::Purge(error.to_string())),
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str().filter(|name| name.starts_with(prefix)) else {
                continue;
            };
            stems.insert(name.split_once(".json").map_or(name, |(stem, _)| stem).to_owned());
        }
    }
    let mut outcome = Ok(());
    for stem in stems {
        let purged = DraftScope::new(&stem)
            .map_err(|error| WorkspaceSaveError::Purge(error.to_string()))
            .and_then(|scope| purge_blocking(&dir.join(format!("{stem}.json")), drafts, &scope));
        if outcome.is_ok() {
            outcome = purged;
        }
    }
    outcome
}

async fn write_record<D: VersionedDocument + Send + 'static>(
    tasks: &Tasks,
    write: &Arc<WriteFile>,
    path: PathBuf,
    record: D,
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
        tracing::warn!(%error, path = %shown, kind = D::KIND, "could not write a workspace file");
    }
    outcome
}

fn read_record(path: &Path) -> WorkspaceLoad {
    let bytes = match read_capped(path) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => return WorkspaceLoad::Blocked(WorkspaceLoadError::TooLarge { limit: MAX_FILE_BYTES }),
        Err(error) if error.kind() == ErrorKind::NotFound => return WorkspaceLoad::Empty,
        Err(error) => return WorkspaceLoad::Blocked(WorkspaceLoadError::Io(error.to_string())),
    };
    match decode_document::<WorkspaceRecord>(path, &bytes) {
        Ok(record) => WorkspaceLoad::Restored(record.clamped()),
        Err(problem) => WorkspaceLoad::Blocked(problem.into()),
    }
}

/// The whole file, or `None` when it is larger than `MAX_FILE_BYTES`.
pub(super) fn read_capped(path: &Path) -> std::io::Result<Option<Vec<u8>>> {
    let file = std::fs::File::open(path)?;
    if file.metadata()?.len() > MAX_FILE_BYTES {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    // The file can grow after the size was read.
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
    Ok((bytes.len() as u64 <= MAX_FILE_BYTES).then_some(bytes))
}

/// A directory that cannot be listed counts as holding a copy, so
/// nothing is deleted on a guess.
fn moved_aside_exists(path: &Path) -> bool {
    tablepro_storage::fs::moved_aside_exists_blocking(path).unwrap_or_else(|error| {
        tracing::warn!(%error, "could not look for saved tabs moved aside");
        true
    })
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

    use tablepro_storage::{DraftId, DraftStore};
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
                    filter: None,
                    sort: None,
                })
                .collect(),
        }
    }

    struct Fixture {
        root: tempfile::TempDir,
        store: WorkspaceStore,
    }

    fn drafts(root: &Path) -> DraftStore {
        DraftStore::new(root.join("drafts"))
    }

    impl Fixture {
        fn new() -> Self {
            let root = tempfile::tempdir().expect("tempdir");
            let store = WorkspaceStore::start(root.path().join("workspaces"), drafts(root.path()), &paused_tasks());
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
            tabs: vec![TabRecord::Editor {
                draft: DraftId::new(),
                file: None,
                database: None,
            }],
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
        fixture.seed(&key, br#"{"version": 3, "tabs": []}"#);

        let load = fixture.store.load(&key).await;

        assert_eq!(
            load,
            WorkspaceLoad::Blocked(WorkspaceLoadError::UnsupportedVersion {
                found: Some(3),
                expected: 2
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
        let key = key();
        let path = fixture.seed(&key, b"{ not json");
        assert!(matches!(fixture.store.load(&key).await, WorkspaceLoad::Blocked(_)));
        std::fs::remove_file(&path).expect("remove");

        assert_eq!(fixture.store.reset(&key).await, Ok(None));
        assert!(!fixture.store.is_blocked(&key));
    }

    #[tokio::test]
    async fn reset_leaves_a_readable_file_alone() {
        let fixture = Fixture::new();
        let key = key();
        fixture.store.schedule(&key, record(1)).expect("scheduled");
        assert_eq!(fixture.store.load(&key).await, WorkspaceLoad::Restored(record(1)));

        assert_eq!(fixture.store.reset(&key).await, Ok(None));

        assert_eq!(fixture.on_disk(&key), record(1));
        assert!(!fixture.store.has_moved_aside_copy(&key));
    }

    #[tokio::test]
    async fn a_copy_moved_aside_is_remembered() {
        let fixture = Fixture::new();
        let (key, other) = (key(), key());
        fixture.seed(&key, b"{ not json");
        assert!(matches!(fixture.store.load(&key).await, WorkspaceLoad::Blocked(_)));
        assert!(!fixture.store.has_moved_aside_copy(&key));

        fixture.store.reset(&key).await.expect("reset");
        assert!(fixture.store.has_moved_aside_copy(&key));
        // As a later run finds it on disk.
        let restarted = WorkspaceStore::start(
            fixture.root.path().join("workspaces"),
            drafts(fixture.root.path()),
            &paused_tasks(),
        );
        assert_eq!(restarted.load(&key).await, WorkspaceLoad::Empty);
        restarted.load(&other).await;

        assert!(restarted.has_moved_aside_copy(&key));
        assert!(!restarted.has_moved_aside_copy(&other));
    }

    #[tokio::test]
    async fn a_record_of_many_tabs_loads_whole() {
        let fixture = Fixture::new();
        let key = key();
        let many = WorkspaceRecord {
            active_tab: Some(39),
            tabs: (0..40)
                .map(|_| TabRecord::Editor {
                    draft: DraftId::new(),
                    file: None,
                    database: None,
                })
                .collect(),
        };
        fixture.store.schedule(&key, many.clone()).expect("scheduled");

        assert_eq!(fixture.store.load(&key).await, WorkspaceLoad::Restored(many));
    }

    #[tokio::test]
    async fn an_oversized_file_blocks_key() {
        let fixture = Fixture::new();
        let key = key();
        let padding = " ".repeat(usize::try_from(MAX_FILE_BYTES).expect("a size"));
        let path = fixture.seed(&key, format!(r#"{{"version": 1, "tabs": []{padding}}}"#).as_bytes());
        let size = std::fs::metadata(&path).expect("metadata").len();

        let load = fixture.store.load(&key).await;

        assert_eq!(
            load,
            WorkspaceLoad::Blocked(WorkspaceLoadError::TooLarge { limit: MAX_FILE_BYTES })
        );
        assert_eq!(std::fs::metadata(&path).expect("metadata").len(), size);
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
        let store = WorkspaceStore::start_with(root.path().to_owned(), drafts(root.path()), &paused_tasks(), write);
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
    async fn purge_removes_the_file_its_moved_aside_copies_and_drafts() {
        let fixture = Fixture::new();
        let (key, other) = (key(), key());
        let path = fixture.seed(&key, b"{ not json");
        assert!(matches!(fixture.store.load(&key).await, WorkspaceLoad::Blocked(_)));
        fixture.store.reset(&key).await.expect("reset");
        fixture.store.schedule(&key, record(1)).expect("scheduled");
        fixture.store.flush(&key).await.expect("written");
        let store = drafts(fixture.root.path());
        let scope = WorkspaceFileName::for_key(&key).draft_scope();
        store
            .write_blocking(&scope, DraftId::new(), "SELECT 1")
            .expect("a draft");
        let kept_scope = WorkspaceFileName::for_key(&other).draft_scope();
        store
            .write_blocking(&kept_scope, DraftId::new(), "SELECT 2")
            .expect("a draft");
        fixture.store.schedule(&other, record(2)).expect("scheduled");

        fixture.store.purge(&key).await.expect("purged");

        assert!(!path.exists(), "the saved tabs outlived the purge");
        assert!(
            !tablepro_storage::fs::moved_aside_exists_blocking(&path).expect("list"),
            "a copy Reset moved aside outlived the purge"
        );
        assert!(
            !store.root().join(scope.as_str()).exists(),
            "the drafts outlived the purge"
        );
        assert!(
            store.root().join(kept_scope.as_str()).exists(),
            "another session's drafts went"
        );
        assert!(!fixture.store.has_moved_aside_copy(&key));
        fixture.store.flush(&other).await.expect("written");
        assert_eq!(fixture.on_disk(&other), record(2));
    }

    /// A deleted connection's other databases leave nothing behind,
    /// whether one left its saved tabs, only a copy Reset moved aside, or
    /// only drafts.
    #[tokio::test]
    async fn a_connections_databases_go_whatever_each_left() {
        let fixture = Fixture::new();
        let id = Uuid::new_v4();
        let in_database = |id: Uuid, database: &str| SessionKey::SavedIn {
            id,
            database: database.to_owned(),
        };
        let (saved, moved_aside, drafts_only) = (
            in_database(id, "analytics"),
            in_database(id, "archive"),
            in_database(id, "staging"),
        );
        let other = in_database(Uuid::new_v4(), "analytics");
        fixture.store.schedule(&saved, record(1)).expect("scheduled");
        fixture.store.flush(&saved).await.expect("written");
        let aside = fixture.seed(&moved_aside, b"{ not json");
        assert!(matches!(
            fixture.store.load(&moved_aside).await,
            WorkspaceLoad::Blocked(_)
        ));
        fixture.store.reset(&moved_aside).await.expect("reset");
        let store = drafts(fixture.root.path());
        let scope_of = |key: &SessionKey| WorkspaceFileName::for_key(key).draft_scope();
        for key in [&saved, &drafts_only, &other] {
            store
                .write_blocking(&scope_of(key), DraftId::new(), "SELECT 1")
                .expect("a draft");
        }
        fixture.store.schedule(&other, record(2)).expect("scheduled");
        fixture.store.flush(&other).await.expect("written");

        fixture.store.purge_databases_of(id).await.expect("purged");

        assert!(!fixture.path(&saved).exists(), "a database's saved tabs stayed");
        assert!(
            !tablepro_storage::fs::moved_aside_exists_blocking(&aside).expect("list"),
            "a copy moved aside with no file beside it stayed"
        );
        for key in [&saved, &drafts_only] {
            assert!(
                !store.root().join(scope_of(key).as_str()).exists(),
                "drafts with no file beside them stayed"
            );
        }
        assert!(
            store.root().join(scope_of(&other).as_str()).exists(),
            "another connection's drafts went"
        );
        assert_eq!(fixture.on_disk(&other), record(2));
    }

    #[tokio::test]
    async fn purge_drops_a_record_still_queued() {
        let root = tempfile::tempdir().expect("tempdir");
        let written: Arc<Mutex<Vec<PathBuf>>> = Arc::default();
        let (started, mut starts) = mpsc::unbounded_channel::<()>();
        let (release, hold) = std::sync::mpsc::channel::<()>();
        let hold = Mutex::new(hold);
        let log = written.clone();
        // Holds the first write open, so the record and the purge after
        // it arrive in one round.
        let write: Arc<WriteFile> = Arc::new(move |path: &Path, bytes: &[u8]| {
            let first = {
                let mut log = log.lock().expect("the log");
                log.push(path.to_owned());
                log.len() == 1
            };
            let _ = started.send(());
            if first {
                let _ = hold.lock().expect("the hold").recv();
            }
            tablepro_storage::fs::write_private_blocking(path, bytes)
        });
        let store = WorkspaceStore::start_with(root.path().to_owned(), drafts(root.path()), &paused_tasks(), write);
        let (busy, purged) = (key(), key());

        store.schedule(&busy, record(1)).expect("scheduled");
        starts.recv().await.expect("the first write started");
        store.schedule(&purged, record(2)).expect("scheduled");
        let purging = store.purge(&purged);
        release.send(()).expect("release the first write");
        purging.await.expect("purged");

        let path = store.inner.path(&purged);
        assert!(!path.exists(), "the queued record was written after all");
        assert!(
            !written.lock().expect("the log").contains(&path),
            "the queued record was written and then removed"
        );
    }

    #[tokio::test]
    async fn a_purge_waits_for_drafts_still_landing() {
        let fixture = Fixture::new();
        let key = key();
        let store = drafts(fixture.root.path());
        let scope = WorkspaceFileName::for_key(&key).draft_scope();
        let closing = fixture.store.writes_in_flight(&key);

        let mut purging = Box::pin(fixture.store.purge(&key));
        let early = tokio::time::timeout(std::time::Duration::from_millis(50), &mut purging).await;
        assert!(early.is_err(), "the purge ran with a draft still landing");
        store
            .write_blocking(&scope, DraftId::new(), "SELECT 1")
            .expect("the late draft");
        drop(closing);
        purging.await.expect("purged");

        assert!(
            !store.root().join(scope.as_str()).exists(),
            "a draft that landed late outlived the purge"
        );
    }

    #[tokio::test]
    async fn purging_a_session_with_nothing_saved_succeeds() {
        let fixture = Fixture::new();

        assert_eq!(fixture.store.purge(&key()).await, Ok(()));
    }

    #[tokio::test]
    async fn a_purge_that_cannot_delete_the_drafts_says_so() {
        let fixture = Fixture::new();
        let key = key();
        let scope = WorkspaceFileName::for_key(&key).draft_scope();
        let drafts_root = fixture.root.path().join("drafts");
        std::fs::create_dir_all(&drafts_root).expect("mkdir");
        // A file where the scope's directory goes cannot be removed as
        // one.
        std::fs::write(drafts_root.join(scope.as_str()), b"not a directory").expect("seed");

        assert!(matches!(
            fixture.store.purge(&key).await,
            Err(WorkspaceSaveError::Purge(_))
        ));
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
        let store = WorkspaceStore::start_with(root.path().to_owned(), drafts(root.path()), &paused_tasks(), write);
        let key = key();

        store.schedule(&key, record(1)).expect("scheduled");

        assert!(matches!(store.flush(&key).await, Err(WorkspaceSaveError::Write(_))));
    }
}
