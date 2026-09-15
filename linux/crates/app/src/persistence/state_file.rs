use std::cell::{Cell, RefCell};
use std::path::PathBuf;

use tablepro_session::runtime::{LatestWinsWriter, Tasks};
use tablepro_storage::document::{VersionedDocument, decode_document, encode_document};
use tablepro_storage::{DocumentProblem, DocumentProblemKind};

/// A small versioned JSON file the app keeps in memory and writes back
/// behind the user.
///
/// Reads answer from memory, so a drag never waits on the disk. Writes
/// go through a latest-wins writer on a blocking thread, so a burst
/// costs two writes rather than one per event.
pub struct StateFile<D> {
    value: RefCell<D>,
    persistence: Cell<Persistence>,
    writer: LatestWinsWriter<D>,
}

/// Whether this file may be written back.
///
/// A file a newer TablePro wrote, or one that cannot be read at all, is
/// left exactly as it is: overwriting it would destroy state the user
/// gets back by upgrading or by fixing permissions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Persistence {
    Enabled,
    Suppressed,
}

impl<D> StateFile<D>
where
    D: VersionedDocument + Default + Clone + Send + Sync + 'static,
{
    /// Read the file once at startup. It is a few kilobytes, so this is
    /// cheaper than making every later read fallible.
    pub fn load(path: PathBuf, tasks: &Tasks) -> Self {
        let (value, persistence) = read(&path);
        let path_for_writes = path.clone();
        let writer = LatestWinsWriter::spawn(tasks, move |document: &D| write(&path_for_writes, document));
        Self {
            value: RefCell::new(value),
            persistence: Cell::new(persistence),
            writer,
        }
    }

    pub fn read<R>(&self, with: impl FnOnce(&D) -> R) -> R {
        with(&self.value.borrow())
    }

    /// Change the document. `change` returns whether anything moved, so
    /// a no-op edit costs no write.
    pub fn update(&self, change: impl FnOnce(&mut D) -> bool) {
        let snapshot = {
            let mut value = self.value.borrow_mut();
            if !change(&mut value) {
                return;
            }
            value.clone()
        };
        if self.persistence.get() == Persistence::Enabled {
            self.writer.put(snapshot);
        }
    }

    /// Resolves once everything changed so far is on disk.
    pub fn flush(&self) -> impl Future<Output = ()> + Send + use<D> {
        self.writer.flush()
    }
}

/// Load the document, applying the recovery rule for each way a file
/// can be unusable.
fn read<D: VersionedDocument + Default>(path: &std::path::Path) -> (D, Persistence) {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (D::default(), Persistence::Enabled);
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
        Ok(document) => (document, Persistence::Enabled),
        // A newer TablePro wrote this. Upgrading gets the state back;
        // writing over it does not.
        Err(problem) if problem.is_newer_version() => suppress(problem),
        Err(problem) => start_over(path, problem),
    }
}

fn suppress<D: Default>(problem: DocumentProblem) -> (D, Persistence) {
    tracing::warn!(%problem, "keeping this file as it is and not saving to it this session");
    (D::default(), Persistence::Suppressed)
}

/// Corrupt, unversioned or too old: nothing can read it and nothing
/// will, so it is moved aside under a stamped name and the app starts
/// from empty. The bytes stay on disk for anyone who wants to look.
fn start_over<D: Default>(path: &std::path::Path, problem: DocumentProblem) -> (D, Persistence) {
    match tablepro_storage::fs::move_aside_blocking(path, std::time::SystemTime::now()) {
        Ok(moved) => tracing::warn!(%problem, moved = %moved.display(), "moved the unusable file aside"),
        Err(error) => {
            tracing::warn!(%problem, %error, "could not move the unusable file aside");
            return (D::default(), Persistence::Suppressed);
        }
    }
    (D::default(), Persistence::Enabled)
}

fn write<D: VersionedDocument>(path: &std::path::Path, document: &D) {
    let bytes = match encode_document(document) {
        Ok(bytes) => bytes,
        Err(error) => {
            tracing::warn!(%error, kind = D::KIND, "could not serialise state");
            return;
        }
    };
    if let Err(error) = tablepro_storage::fs::write_private_blocking(path, &bytes) {
        tracing::warn!(%error, kind = D::KIND, "could not save state");
    }
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

    async fn push(file: &StateFile<Sample>, item: &str) {
        file.update(|sample| {
            sample.items.push(item.to_owned());
            true
        });
        file.flush().await;
    }

    #[tokio::test]
    async fn a_missing_file_starts_empty_and_writes_a_versioned_one() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        assert!(!path.exists());

        push(&file, "one").await;

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

        push(&file, "one").await;
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
        push(&file, "one").await;

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
        push(&file, "one").await;

        assert!(path.is_dir(), "the store wrote over the blocked path");
    }

    #[tokio::test]
    async fn an_update_that_changes_nothing_writes_nothing() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());

        file.update(|_| false);
        file.flush().await;

        assert!(!path.exists(), "a no-op update still wrote the file");
    }

    #[tokio::test]
    async fn a_readable_file_round_trips() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("sample.json");
        let file = StateFile::<Sample>::load(path.clone(), &paused_tasks());
        push(&file, "one").await;

        let reopened = StateFile::<Sample>::load(path, &paused_tasks());

        assert_eq!(reopened.read(|sample| sample.items.clone()), vec!["one".to_owned()]);
    }
}
