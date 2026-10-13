use tablepro_session::SessionKey;
use tablepro_storage::DraftScope;

/// The name one session's saved tabs are kept under, which also names
/// the directory its editor drafts live in.
///
/// A file key is hashed: its URI can be longer than a file name may be,
/// and holds slashes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WorkspaceFileName {
    stem: String,
}

impl WorkspaceFileName {
    pub fn for_key(key: &SessionKey) -> Self {
        let stem = match key {
            SessionKey::Saved(id) => id.to_string(),
            SessionKey::File(uri) => {
                // GLib returns no digest only for a checksum type it
                // does not know, which SHA-256 is not.
                let digest = glib::compute_checksum_for_string(glib::ChecksumType::Sha256, uri.as_str())
                    .map(|digest| digest.to_string())
                    .unwrap_or_default();
                format!("file-{digest}")
            }
        };
        Self { stem }
    }

    pub fn file_name(&self) -> String {
        format!("{}.json", self.stem)
    }

    pub fn draft_scope(&self) -> DraftScope {
        DraftScope::new(&self.stem).unwrap_or_else(|error| {
            tracing::warn!(%error, "a workspace name is not a usable draft scope");
            DraftScope::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    #[test]
    fn names_for_saved_and_file_keys() {
        let id = Uuid::parse_str("4f0c6a52-3b7e-4d55-9a3c-2a8f3f7e9b10").expect("a uuid");

        let saved = WorkspaceFileName::for_key(&SessionKey::Saved(id));
        let file = WorkspaceFileName::for_key(&SessionKey::File("file:///tmp/app.db".to_owned()));

        assert_eq!(saved.file_name(), "4f0c6a52-3b7e-4d55-9a3c-2a8f3f7e9b10.json");
        assert_eq!(
            file.file_name(),
            "file-35a613072ab5ce7e8aff29b0edfd55feeaff4c9c99b6df5572945f4bc16a71f7.json"
        );
        assert_ne!(
            file,
            WorkspaceFileName::for_key(&SessionKey::File("file:///tmp/other.db".to_owned()))
        );
    }

    #[test]
    fn each_name_is_its_own_draft_scope() {
        let id = Uuid::new_v4();
        let saved = WorkspaceFileName::for_key(&SessionKey::Saved(id));
        let file = WorkspaceFileName::for_key(&SessionKey::File("file:///tmp/app.db".to_owned()));

        assert_eq!(saved.draft_scope().as_str(), id.to_string());
        assert!(file.draft_scope().as_str().starts_with("file-"));
        assert_ne!(saved.draft_scope(), DraftScope::default());
    }
}
