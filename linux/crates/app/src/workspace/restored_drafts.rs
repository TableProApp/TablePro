use std::collections::HashMap;

use tablepro_storage::{DraftId, DraftScope, DraftStore};

/// The text of a restored session's editor tabs.
#[derive(Default)]
pub struct RestoredDrafts {
    pub texts: HashMap<DraftId, String>,
    /// How many drafts could not be read. Each is moved aside, so its tab
    /// opens empty and neither typing in it nor closing it touches the
    /// bytes.
    pub unreadable: usize,
}

impl RestoredDrafts {
    pub fn read_blocking(store: &DraftStore, scope: &DraftScope, drafts: impl IntoIterator<Item = DraftId>) -> Self {
        let mut restored = Self::default();
        for draft in drafts {
            match store.read_blocking(scope, draft) {
                Ok(Some(text)) => {
                    restored.texts.insert(draft, text);
                }
                Ok(None) => {}
                Err(error) => {
                    tracing::warn!(%error, "could not read an editor draft");
                    restored.unreadable += 1;
                    match store.move_aside_blocking(scope, draft, std::time::SystemTime::now()) {
                        Ok(moved) => tracing::info!(moved = %moved.display(), "moved the unreadable draft aside"),
                        Err(error) => tracing::warn!(%error, "could not move the unreadable draft aside"),
                    }
                }
            }
        }
        restored
    }
}

impl std::fmt::Debug for RestoredDrafts {
    // The drafts are the user's SQL, which stays out of the journal.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RestoredDrafts")
            .field("texts", &self.texts.len())
            .field("unreadable", &self.unreadable)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn an_unreadable_draft_is_moved_aside() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = DraftStore::new(root.path().join("drafts"));
        let scope = DraftScope::new("session").expect("a scope");
        let (good, bad, missing) = (DraftId::new(), DraftId::new(), DraftId::new());
        store.write_blocking(&scope, good, "SELECT 1").expect("write");
        store.write_blocking(&scope, bad, "SELECT 2").expect("write");
        let bad_path = root
            .path()
            .join("drafts")
            .join(scope.as_str())
            .join(format!("{bad}.sql"));
        std::fs::write(&bad_path, b"SELECT \xff").expect("seed bytes that are not UTF-8");

        let restored = RestoredDrafts::read_blocking(&store, &scope, [good, bad, missing]);

        assert_eq!(restored.texts, HashMap::from([(good, "SELECT 1".to_owned())]));
        assert_eq!(restored.unreadable, 1);
        assert!(!bad_path.exists(), "the unreadable draft is where its tab writes");
        store.retain_blocking(&scope, &HashSet::new()).expect("retain");
        let kept: Vec<Vec<u8>> = std::fs::read_dir(bad_path.parent().expect("the scope"))
            .expect("list")
            .map(|entry| std::fs::read(entry.expect("an entry").path()).expect("read"))
            .collect();
        assert_eq!(kept, [b"SELECT \xff".to_vec()]);
    }
}
