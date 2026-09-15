use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::{DraftId, DraftScope};
use crate::StorageError;
use crate::fs::{ensure_private_dir, write_private_blocking};

/// Where editor text lives between sessions.
///
/// One file per tab, so a script is kept whole however long it is and
/// a workspace file stays small. Every method blocks, so callers run
/// them off the GTK thread.
#[derive(Debug, Clone)]
pub struct DraftStore {
    root: PathBuf,
}

impl DraftStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn write_blocking(&self, scope: &DraftScope, id: DraftId, text: &str) -> Result<(), StorageError> {
        let directory = self.scope_dir(scope);
        ensure_private_dir(&directory)?;
        write_private_blocking(&self.draft_path(scope, id), text.as_bytes())
    }

    /// The saved text, or `None` when there is no draft. Invalid UTF-8
    /// is an error rather than a lossy decode, and the file is left
    /// alone so the bytes are still there to recover.
    pub fn read_blocking(&self, scope: &DraftScope, id: DraftId) -> Result<Option<String>, StorageError> {
        let path = self.draft_path(scope, id);
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(source) => return Err(StorageError::Io { path, source }),
        };
        match String::from_utf8(bytes) {
            Ok(text) => Ok(Some(text)),
            Err(error) => Err(StorageError::DraftNotUtf8 {
                path,
                offset: error.utf8_error().valid_up_to(),
            }),
        }
    }

    pub fn delete_blocking(&self, scope: &DraftScope, id: DraftId) -> Result<(), StorageError> {
        let path = self.draft_path(scope, id);
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(StorageError::Io { path, source }),
        }
    }

    /// Delete every draft in the scope that no tab references any more,
    /// so a workspace that loses tabs does not leave files behind.
    pub fn retain_blocking(&self, scope: &DraftScope, keep: &HashSet<DraftId>) -> Result<usize, StorageError> {
        let directory = self.scope_dir(scope);
        let entries = match std::fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(source) => {
                return Err(StorageError::Io {
                    path: directory,
                    source,
                });
            }
        };
        let mut removed = 0;
        for entry in entries.flatten() {
            let path = entry.path();
            // Anything whose name is not a draft id was not written
            // here, so it is left alone.
            let Some(id) = draft_id_of(&path) else {
                continue;
            };
            if keep.contains(&id) {
                continue;
            }
            match std::fs::remove_file(&path) {
                Ok(()) => removed += 1,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(source) => return Err(StorageError::Io { path, source }),
            }
        }
        Ok(removed)
    }

    /// Drop a whole workspace's drafts, for a workspace the user
    /// deleted.
    pub fn delete_scope_blocking(&self, scope: &DraftScope) -> Result<(), StorageError> {
        let directory = self.scope_dir(scope);
        match std::fs::remove_dir_all(&directory) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(StorageError::Io {
                path: directory,
                source,
            }),
        }
    }

    fn scope_dir(&self, scope: &DraftScope) -> PathBuf {
        self.root.join(scope.as_str())
    }

    fn draft_path(&self, scope: &DraftScope, id: DraftId) -> PathBuf {
        self.scope_dir(scope).join(format!("{id}.sql"))
    }
}

fn draft_id_of(path: &Path) -> Option<DraftId> {
    if path.extension()? != "sql" {
        return None;
    }
    let stem = path.file_stem()?.to_str()?;
    stem.parse::<uuid::Uuid>().ok().map(DraftId::from_uuid)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn store(root: &tempfile::TempDir) -> DraftStore {
        DraftStore::new(root.path().join("drafts"))
    }

    fn scope() -> DraftScope {
        DraftScope::new("workspace_state").expect("a scope")
    }

    #[test]
    fn draft_round_trips_5_mib_multibyte() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = DraftId::new();
        // Well past the 256 KiB the workspace file used to truncate at.
        let text = "SELECT 'é☃𝄞';\n".repeat(5 * 1024 * 1024 / 16);
        assert!(text.len() > 5 * 1024 * 1024 - 32);

        store.write_blocking(&scope(), id, &text).expect("write");
        let read = store.read_blocking(&scope(), id).expect("read");

        assert_eq!(read.as_deref(), Some(text.as_str()));
    }

    #[test]
    fn draft_file_mode_0600_dir_0700() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = DraftId::new();

        store.write_blocking(&scope(), id, "SELECT 1").expect("write");

        let mode = |path: &Path| {
            std::fs::metadata(path)
                .unwrap_or_else(|error| panic!("{}: {error}", path.display()))
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode(&store.draft_path(&scope(), id)), 0o600);
        assert_eq!(mode(&store.scope_dir(&scope())), 0o700);
    }

    #[test]
    fn retain_removes_unreferenced_only() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let kept = DraftId::new();
        let dropped = DraftId::new();
        store.write_blocking(&scope(), kept, "keep").expect("write");
        store.write_blocking(&scope(), dropped, "drop").expect("write");
        // A file nothing wrote here stays put.
        let foreign = store.scope_dir(&scope()).join("notes.txt");
        std::fs::write(&foreign, b"mine").expect("seed");

        let removed = store.retain_blocking(&scope(), &HashSet::from([kept])).expect("retain");

        assert_eq!(removed, 1);
        assert_eq!(store.read_blocking(&scope(), kept).expect("read"), Some("keep".into()));
        assert_eq!(store.read_blocking(&scope(), dropped).expect("read"), None);
        assert!(foreign.exists(), "retain deleted a file it did not write");
    }

    #[test]
    fn retain_on_a_scope_that_was_never_written_is_not_an_error() {
        let root = tempfile::tempdir().expect("tempdir");

        let removed = store(&root)
            .retain_blocking(&scope(), &HashSet::new())
            .expect("retain a missing scope");

        assert_eq!(removed, 0);
    }

    #[test]
    fn invalid_utf8_draft_is_error_and_untouched() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = DraftId::new();
        store.write_blocking(&scope(), id, "").expect("create the scope");
        let path = store.draft_path(&scope(), id);
        let bytes: &[u8] = b"SELECT \xff\xfe";
        std::fs::write(&path, bytes).expect("seed");

        let error = store.read_blocking(&scope(), id).expect_err("invalid utf-8");

        assert!(
            matches!(error, StorageError::DraftNotUtf8 { offset, .. } if offset == 7),
            "{error:?}"
        );
        assert_eq!(std::fs::read(&path).expect("read the bytes"), bytes);
    }

    #[test]
    fn a_missing_draft_reads_as_none() {
        let root = tempfile::tempdir().expect("tempdir");

        assert_eq!(
            store(&root).read_blocking(&scope(), DraftId::new()).expect("read"),
            None
        );
    }

    #[test]
    fn delete_is_idempotent_and_delete_scope_takes_the_rest() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = DraftId::new();
        store.write_blocking(&scope(), id, "SELECT 1").expect("write");

        store.delete_blocking(&scope(), id).expect("delete");
        store.delete_blocking(&scope(), id).expect("delete again");
        store
            .write_blocking(&scope(), DraftId::new(), "another")
            .expect("write");
        store.delete_scope_blocking(&scope()).expect("delete the scope");

        assert!(!store.scope_dir(&scope()).exists());
        store.delete_scope_blocking(&scope()).expect("delete the scope again");
    }

    #[test]
    fn two_scopes_keep_their_own_drafts() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let other = DraftScope::new("other").expect("a scope");
        let id = DraftId::new();

        store.write_blocking(&scope(), id, "mine").expect("write");

        assert_eq!(store.read_blocking(&other, id).expect("read"), None);
    }
}
