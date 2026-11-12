use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_session::runtime::{LatestWinsWriter, Tasks};
use tablepro_storage::document::{VersionedDocument, decode_document, write_document_blocking};
use tablepro_storage::{DocumentProblem, DocumentProblemKind, StorageError};
use tokio::sync::watch;

#[derive(Debug, Clone, thiserror::Error)]
pub enum StateFileError {
    #[error(transparent)]
    Protected(Arc<DocumentProblem>),
    #[error(transparent)]
    Write(Arc<StorageError>),
    #[error("the state writer stopped before saving {}", .path.display())]
    WriterStopped { path: PathBuf },
}

impl StateFileError {
    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::Write(_))
    }
}

pub struct StateFile<D> {
    path: PathBuf,
    value: RefCell<D>,
    revision: Cell<u64>,
    protected: bool,
    status: Arc<Mutex<WriteStatus>>,
    failing: Arc<watch::Sender<bool>>,
    writer: LatestWinsWriter<Pending<D>>,
}

struct Pending<D> {
    sequence: u64,
    document: D,
}

struct WriteStatus {
    submitted: u64,
    completed: u64,
    unsaved: bool,
    result: Result<(), StateFileError>,
    failure: Option<StateFileError>,
}

impl<D> StateFile<D>
where
    D: VersionedDocument + Default + Clone + Send + Sync + 'static,
{
    pub fn load(path: PathBuf, tasks: &Tasks) -> Self {
        let (value, problem) = read(&path);
        let protected = problem.is_some();
        let failure = problem.map(|problem| StateFileError::Protected(Arc::new(problem)));
        let status = Arc::new(Mutex::new(WriteStatus {
            submitted: 0,
            completed: 0,
            unsaved: false,
            result: failure.clone().map_or(Ok(()), Err),
            failure,
        }));
        let failing = Arc::new(watch::channel(protected).0);
        let path_for_writes = path.clone();
        let status_for_writes = status.clone();
        let failing_for_writes = failing.clone();
        let writer = LatestWinsWriter::spawn(tasks, move |pending: &Pending<D>| {
            let result = write_document_blocking(&path_for_writes, &pending.document)
                .map_err(|error| StateFileError::Write(Arc::new(error)));
            if let Err(error) = &result {
                tracing::warn!(%error, kind = D::KIND, "could not save state");
            }
            let mut status = status_for_writes.lock().unwrap_or_else(PoisonError::into_inner);
            status.completed = pending.sequence;
            status.result = result.clone();
            match result {
                Err(error) => status.failure = Some(error),
                // An older successful snapshot must not dismiss a failure while newer edits are pending.
                Ok(()) if status.submitted == pending.sequence => {
                    status.failure = None;
                    status.unsaved = false;
                }
                Ok(()) => {}
            }
            let failed = status.failure.is_some();
            failing_for_writes.send_if_modified(|previous| std::mem::replace(previous, failed) != failed);
        });
        Self {
            path,
            value: RefCell::new(value),
            revision: Cell::new(0),
            protected,
            status,
            failing,
            writer,
        }
    }

    pub fn path(&self) -> &std::path::Path {
        &self.path
    }

    pub fn read<R>(&self, with: impl FnOnce(&D) -> R) -> R {
        with(&self.value.borrow())
    }

    pub fn failing(&self) -> watch::Receiver<bool> {
        self.failing.subscribe()
    }

    pub fn current_error(&self) -> Option<StateFileError> {
        self.status
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .failure
            .clone()
    }

    pub fn revision(&self) -> u64 {
        self.revision.get()
    }

    pub fn has_unsaved_changes(&self) -> bool {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).unsaved
    }

    pub fn update(&self, change: impl FnOnce(&mut D) -> bool) {
        let snapshot = {
            let mut value = self.value.borrow_mut();
            if !change(&mut value) {
                return;
            }
            value.clone()
        };
        self.revision.set(self.revision.get().wrapping_add(1));
        self.schedule(snapshot);
    }

    pub fn retry(&self) -> bool {
        if self.protected {
            return false;
        }
        self.schedule(self.value.borrow().clone());
        true
    }

    fn schedule(&self, document: D) {
        let sequence = {
            let mut status = self.status.lock().unwrap_or_else(PoisonError::into_inner);
            status.unsaved = true;
            if self.protected {
                return;
            }
            status.submitted += 1;
            status.submitted
        };
        self.writer.put(Pending { sequence, document });
    }

    pub fn flush(&self) -> impl Future<Output = Result<(), StateFileError>> + Send + use<D> {
        let target = self.status.lock().unwrap_or_else(PoisonError::into_inner).submitted;
        let written = self.writer.flush();
        let status = self.status.clone();
        let failing = self.failing.clone();
        let path = self.path.clone();
        async move {
            written.await;
            let mut status = status.lock().unwrap_or_else(PoisonError::into_inner);
            if status.completed < target {
                // LatestWinsWriter also finishes a wait when its task stopped without calling the writer.
                let error = StateFileError::WriterStopped { path };
                status.failure = Some(error.clone());
                failing.send_if_modified(|previous| !std::mem::replace(previous, true));
                return Err(error);
            }
            status.result.clone()
        }
    }
}

fn read<D: VersionedDocument + Default>(path: &std::path::Path) -> (D, Option<DocumentProblem>) {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (D::default(), None);
        }
        Err(error) => {
            return suppress(DocumentProblem::new(
                path,
                DocumentProblemKind::Unreadable {
                    detail: error.to_string(),
                },
            ));
        }
    };

    match decode_document::<D>(path, &bytes) {
        Ok(document) => (document, None),
        // A newer TablePro can recover its own document; writing over it would destroy that option.
        Err(problem) if problem.is_newer_version() => suppress(problem),
        Err(problem) => start_over(path, problem),
    }
}

fn suppress<D: Default>(problem: DocumentProblem) -> (D, Option<DocumentProblem>) {
    tracing::warn!(%problem, "keeping this file as it is and not saving to it this session");
    (D::default(), Some(problem))
}

fn start_over<D: Default>(path: &std::path::Path, problem: DocumentProblem) -> (D, Option<DocumentProblem>) {
    match tablepro_storage::fs::move_aside_blocking(path, std::time::SystemTime::now()) {
        Ok(moved) => tracing::warn!(%problem, moved = %moved.display(), "moved the unusable file aside"),
        Err(error) => {
            tracing::warn!(%problem, %error, "could not move the unusable file aside");
            return (D::default(), Some(problem));
        }
    }
    (D::default(), None)
}

#[cfg(test)]
mod tests {
    use serde::{Deserialize, Serialize};

    use super::*;
    use crate::test_support::paused_tasks;

    #[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
    struct Sample {
        #[serde(default)]
        items: Vec<String>,
    }

    impl VersionedDocument for Sample {
        const KIND: &'static str = "sample";
        const VERSION: u32 = 1;
    }

    fn seed(root: &tempfile::TempDir, contents: &str) -> PathBuf {
        let path = root.path().join("sample.json");
        std::fs::write(&path, contents).expect("seed");
        path
    }

    async fn push(file: &StateFile<Sample>, item: &str) -> Result<(), StateFileError> {
        file.update(|sample| {
            sample.items.push(item.to_owned());
            true
        });
        file.flush().await
    }

    #[tokio::test]
    async fn a_missing_file_starts_empty_and_writes_a_versioned_one() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        assert!(!path.exists());

        push(&file, "one").await.expect("write");

        let bytes = std::fs::read_to_string(&path).expect("the file was written");
        assert!(bytes.contains("\"version\": 1"), "{bytes}");
        assert!(bytes.contains("one"), "{bytes}");
    }

    #[tokio::test]
    async fn a_corrupt_file_is_moved_aside_with_its_bytes_and_the_state_starts_empty() {
        let root = tempfile::tempdir().expect("tempdir");
        let original = "{ not json";
        let path = seed(&root, original);

        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());

        assert_eq!(file.read(|sample| sample.items.len()), 0);
        let moved: Vec<PathBuf> = std::fs::read_dir(root.path())
            .expect("read the directory")
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|entry| entry != &path)
            .collect();
        assert_eq!(moved.len(), 1, "{moved:?}");
        assert_eq!(
            std::fs::read_to_string(&moved[0]).expect("read the moved file"),
            original
        );

        push(&file, "one").await.expect("write");
        assert!(path.exists(), "the store refused to write after starting over");
    }

    #[tokio::test]
    async fn a_file_with_no_version_is_moved_aside_too() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = seed(&root, r#"{"items": ["kept"]}"#);

        let file = StateFile::<Sample>::load(path, &paused_tasks());

        assert_eq!(file.read(|sample| sample.items.len()), 0);
    }

    #[tokio::test]
    async fn a_newer_version_file_is_never_written_after_updates_and_flush() {
        let root = tempfile::tempdir().expect("tempdir");
        let original = r#"{"version": 99, "items": ["from the future"]}"#;
        let path = seed(&root, original);

        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        assert!(!file.has_unsaved_changes(), "a failed read is not a local edit");
        assert!(matches!(push(&file, "one").await, Err(StateFileError::Protected(_))));
        assert!(file.has_unsaved_changes(), "protected local edits are still unsaved");
        assert!(*file.failing().borrow());
        assert!(!file.retry(), "retry must not overwrite protected data");
        assert!(!file.current_error().expect("read failure").is_retryable());

        assert_eq!(
            std::fs::read_to_string(&path).expect("read"),
            original,
            "a file from a newer TablePro was overwritten"
        );
    }

    #[tokio::test]
    async fn an_unreadable_file_is_never_written_either() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = seed(&root, r#"{"version": 1, "items": ["kept"]}"#);
        // A directory where the file should be is the portable way to
        // make a read fail as root as well as as a normal user.
        std::fs::remove_file(&path).expect("clear");
        std::fs::create_dir(&path).expect("block the path");

        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        assert!(!file.has_unsaved_changes(), "a failed read is not a local edit");
        assert!(matches!(push(&file, "one").await, Err(StateFileError::Protected(_))));
        assert!(file.has_unsaved_changes(), "protected local edits are still unsaved");
        assert!(*file.failing().borrow());
        assert!(!file.retry(), "retry must not overwrite protected data");
        assert!(!file.current_error().expect("read failure").is_retryable());

        assert!(path.is_dir(), "the store wrote over the blocked path");
    }

    #[tokio::test]
    async fn an_update_that_changes_nothing_writes_nothing() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());

        file.update(|_| false);
        file.flush().await.expect("flush");

        assert!(!path.exists(), "a no-op update still wrote the file");
        assert!(!file.has_unsaved_changes());
    }

    #[tokio::test]
    async fn failed_writes_report_once_and_retry_saves_the_latest_document() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        let mut failing = file.failing();
        assert!(!*failing.borrow_and_update());
        assert!(!file.has_unsaved_changes());
        std::fs::create_dir(&path).expect("block writes after the initial read");

        assert!(matches!(push(&file, "one").await, Err(StateFileError::Write(_))));
        assert!(failing.has_changed().expect("watch"));
        assert!(file.has_unsaved_changes());
        assert!(*failing.borrow_and_update());
        assert!(file.current_error().expect("write error").is_retryable());
        assert!(push(&file, "two").await.is_err());
        assert!(!failing.has_changed().expect("watch"), "one toast per failure episode");

        std::fs::remove_dir(&path).expect("unblock writes");
        file.update(|_| false);
        assert!(file.flush().await.is_err(), "a no-op must not hide the failed write");
        assert!(file.retry());
        file.flush().await.expect("retry writes the latest snapshot");
        assert!(!file.has_unsaved_changes());
        assert!(file.current_error().is_none());
        assert!(!*failing.borrow_and_update());
        let reopened = StateFile::<Sample>::load(path, &paused_tasks());
        assert_eq!(reopened.read(|sample| sample.items.clone()), ["one", "two"]);
    }

    #[tokio::test]
    async fn a_flush_captured_before_newer_edits_waits_for_its_snapshot() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        file.update(|sample| {
            sample.items.push("one".to_owned());
            true
        });
        let earlier = file.flush();
        file.update(|sample| {
            sample.items.push("two".to_owned());
            true
        });
        earlier.await.expect("the earlier snapshot or its successor landed");
        file.flush().await.expect("the latest snapshot landed");
        let reopened = StateFile::<Sample>::load(path, &paused_tasks());
        assert_eq!(reopened.read(|sample| sample.items.clone()), ["one", "two"]);
    }

    struct SerializeGate {
        started: tokio::sync::mpsc::UnboundedSender<()>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }

    #[derive(Default, Clone, Deserialize)]
    struct GatedSample {
        items: Vec<String>,
        #[serde(skip)]
        gate: Option<Arc<SerializeGate>>,
    }

    impl Serialize for GatedSample {
        fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            if let Some(gate) = &self.gate {
                gate.started.send(()).map_err(serde::ser::Error::custom)?;
                gate.release
                    .lock()
                    .map_err(serde::ser::Error::custom)?
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .map_err(serde::ser::Error::custom)?;
            }
            Sample {
                items: self.items.clone(),
            }
            .serialize(serializer)
        }
    }

    impl VersionedDocument for GatedSample {
        const KIND: &'static str = "gated-sample";
        const VERSION: u32 = 1;
    }

    #[tokio::test]
    async fn an_older_success_keeps_newer_edits_unsaved_when_their_write_fails() {
        const WAIT: std::time::Duration = std::time::Duration::from_secs(10);
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<GatedSample>::load(path.clone(), &paused_tasks());
        let gate = || {
            let (started, starts) = tokio::sync::mpsc::unbounded_channel();
            let (release, released) = std::sync::mpsc::channel();
            (
                Arc::new(SerializeGate {
                    started,
                    release: Mutex::new(released),
                }),
                starts,
                release,
            )
        };
        let (first, mut first_started, release_first) = gate();
        let (second, mut second_started, release_second) = gate();
        file.update(|document| {
            document.items = vec!["first".to_owned()];
            document.gate = Some(first);
            true
        });
        assert_eq!(
            tokio::time::timeout(WAIT, first_started.recv())
                .await
                .expect("first write starts"),
            Some(())
        );
        let earlier = file.flush();
        file.update(|document| {
            document.items = vec!["latest".to_owned()];
            document.gate = Some(second);
            true
        });
        release_first.send(()).expect("release first serializer");
        tokio::time::timeout(WAIT, earlier)
            .await
            .expect("first flush finishes")
            .expect("first write succeeds");
        assert_eq!(
            tokio::time::timeout(WAIT, second_started.recv())
                .await
                .expect("second write starts"),
            Some(())
        );
        assert!(file.has_unsaved_changes(), "the older success hid the pending edit");
        assert_eq!(file.revision(), 2);
        let first_bytes = std::fs::read(&path).expect("first document landed");
        let first_document = decode_document::<Sample>(&path, &first_bytes).expect("first document");
        assert_eq!(first_document.items, ["first"]);

        std::fs::remove_file(&path).expect("remove first document");
        std::fs::create_dir(&path).expect("block second write");
        release_second.send(()).expect("release second serializer");
        let latest = tokio::time::timeout(WAIT, file.flush())
            .await
            .expect("second flush finishes");
        assert!(matches!(latest, Err(StateFileError::Write(_))));
        assert!(file.has_unsaved_changes(), "the failed latest edit must remain unsaved");
        assert_eq!(file.read(|document| document.items.clone()), ["latest"]);
    }

    #[tokio::test]
    async fn revisions_count_local_edits_even_when_protected_but_never_count_retries() {
        for protected in [false, true] {
            let root = tempfile::tempdir().expect("tempdir");
            let path = root.path().join("sample.json");
            if protected {
                std::fs::write(&path, r#"{"version":99,"items":["kept"]}"#).expect("newer file");
            }
            let file = StateFile::<Sample>::load(path, &paused_tasks());
            assert_eq!(file.revision(), 0);
            file.update(|_| false);
            assert_eq!(file.revision(), 0);
            assert_eq!(file.retry(), !protected);
            assert_eq!(file.revision(), 0, "retrying is not a document edit");
            let result = push(&file, "one").await;
            assert_eq!(result.is_err(), protected);
            assert_eq!(file.revision(), 1);
            assert_eq!(file.retry(), !protected);
            assert_eq!(file.revision(), 1);
            let result = push(&file, "two").await;
            assert_eq!(result.is_err(), protected);
            assert_eq!(file.revision(), 2);
        }
    }

    #[test]
    fn a_stopped_writer_is_not_reported_as_a_successful_flush() {
        use std::task::{Context, Poll, Waker};

        let runtime = crate::test_support::test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let file = StateFile::<Sample>::load(root.path().join("sample.json"), &runtime.tasks());
        drop(runtime);
        file.update(|sample| {
            sample.items.push("never written".to_owned());
            true
        });
        let mut flushing = std::pin::pin!(file.flush());
        let outcome = flushing.as_mut().poll(&mut Context::from_waker(Waker::noop()));
        assert!(matches!(
            outcome,
            Poll::Ready(Err(StateFileError::WriterStopped { .. }))
        ));
        assert!(*file.failing().borrow());
    }

    #[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
    struct Upgraded {
        items: Vec<String>,
    }

    fn same_shape(document: serde_json::Value) -> Result<serde_json::Value, String> {
        Ok(document)
    }

    impl VersionedDocument for Upgraded {
        const KIND: &'static str = "upgraded";
        const VERSION: u32 = 2;
        const UPGRADES: &'static [tablepro_storage::document::Upgrade] = &[same_shape];
    }

    #[tokio::test]
    async fn an_older_file_is_copied_aside_before_its_first_write() {
        let root = tempfile::tempdir().expect("tempdir");
        let original = r#"{"version": 1, "items": ["old"]}"#;
        let path = seed(&root, original);
        let file = StateFile::<Upgraded>::load(path.clone(), &paused_tasks());
        assert_eq!(file.read(|upgraded| upgraded.items.clone()), vec!["old".to_owned()]);
        let copies = || tablepro_storage::upgrade_copies::copies_blocking(&path).expect("copies");
        assert!(copies().is_empty(), "a read made a copy");

        file.update(|upgraded| {
            upgraded.items.push("new".to_owned());
            true
        });
        file.flush().await.expect("flush");

        let kept = copies();
        assert_eq!(kept.len(), 1, "{kept:?}");
        assert_eq!(std::fs::read_to_string(&kept[0].path).expect("read"), original);
        let written = std::fs::read_to_string(&path).expect("read");
        assert!(written.contains("\"version\": 2"), "{written}");
    }

    #[tokio::test]
    async fn a_readable_file_round_trips() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        push(&file, "one").await.expect("write");

        let reopened = StateFile::<Sample>::load(path, &paused_tasks());

        assert_eq!(reopened.read(|sample| sample.items.clone()), vec!["one".to_owned()]);
    }
}
