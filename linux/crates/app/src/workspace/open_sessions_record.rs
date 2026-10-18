use std::io::ErrorKind;
use std::path::Path;

use serde::{Deserialize, Serialize};
use tablepro_session::SessionKey;
use tablepro_storage::document::{VersionedDocument, decode_document};

use super::workspace_store::{MAX_FILE_BYTES, read_capped};
use super::{OpenSessionsLoad, SessionKeyRecord};

/// The sessions the windows showed, in the order they opened, so the
/// next launch opens them again.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenSessionsRecord {
    #[serde(default)]
    pub sessions: Vec<SessionKeyRecord>,
}

impl VersionedDocument for OpenSessionsRecord {
    const KIND: &'static str = "open-sessions";
    const VERSION: u32 = 1;
}

impl OpenSessionsRecord {
    /// Beside the sessions' own files, under a name none of them can
    /// take.
    pub const FILE_NAME: &'static str = "open-sessions.json";

    pub fn from_keys<'a>(keys: impl IntoIterator<Item = &'a SessionKey>) -> Self {
        Self {
            sessions: keys.into_iter().map(SessionKeyRecord::from).collect(),
        }
    }

    /// Each key once, in the recorded order: a key repeated in the file
    /// would open a second window only to find the first.
    pub fn keys(self) -> Vec<SessionKey> {
        let mut keys: Vec<SessionKey> = Vec::with_capacity(self.sessions.len());
        for key in self.sessions.into_iter().map(SessionKeyRecord::into_key) {
            if !keys.contains(&key) {
                keys.push(key);
            }
        }
        keys
    }
}

/// A file that cannot be used is moved aside, bytes and all, and loads
/// as empty. It holds nothing the user wrote, and the next write then
/// never lands on something nobody read.
pub(super) fn read_open_sessions_blocking(path: &Path) -> OpenSessionsLoad {
    let problem = match read_capped(path) {
        Ok(Some(bytes)) => match decode_document::<OpenSessionsRecord>(path, &bytes) {
            Ok(record) => return OpenSessionsLoad::Restored(record),
            Err(problem) => problem.to_string(),
        },
        Ok(None) => format!("the file is larger than {MAX_FILE_BYTES} bytes"),
        Err(error) if error.kind() == ErrorKind::NotFound => return OpenSessionsLoad::Empty,
        Err(error) => error.to_string(),
    };
    match tablepro_storage::fs::move_aside_blocking(path, std::time::SystemTime::now()) {
        Ok(moved) => tracing::warn!(%problem, moved = %moved.display(), "moved the open sessions record aside"),
        Err(error) => tracing::warn!(%problem, %error, "could not move the open sessions record aside"),
    }
    OpenSessionsLoad::Empty
}

#[cfg(test)]
mod tests {
    use tablepro_storage::document::encode_document;
    use uuid::Uuid;

    use super::*;

    fn record() -> OpenSessionsRecord {
        OpenSessionsRecord {
            sessions: vec![
                SessionKeyRecord::Saved { id: Uuid::new_v4() },
                SessionKeyRecord::File {
                    uri: "file:///srv/app.db".to_owned(),
                },
            ],
        }
    }

    fn moved_aside(dir: &Path) -> Vec<std::path::PathBuf> {
        std::fs::read_dir(dir)
            .expect("list the directory")
            .map(|entry| entry.expect("an entry").path())
            .filter(|path| {
                path.file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with("open-sessions.json.corrupt-"))
            })
            .collect()
    }

    #[test]
    fn round_trip() {
        let record = record();

        let bytes = encode_document(&record).expect("encode");
        let decoded: OpenSessionsRecord = decode_document(Path::new("/tmp/o.json"), &bytes).expect("decode");

        assert_eq!(decoded, record);
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains("\"version\": 1"), "{text}");
        assert!(text.contains("\"kind\": \"saved\""), "{text}");
    }

    #[test]
    fn unsupported_version_moved_aside_and_loads_empty() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OpenSessionsRecord::FILE_NAME);
        let original = br#"{"version": 2, "sessions": []}"#;
        std::fs::write(&path, original).expect("seed");

        let load = read_open_sessions_blocking(&path);

        assert_eq!(load, OpenSessionsLoad::Empty);
        assert!(!path.exists(), "the unusable file was left where the next write goes");
        let moved = moved_aside(dir.path());
        assert_eq!(moved.len(), 1, "{moved:?}");
        assert_eq!(std::fs::read(&moved[0]).expect("read the moved file"), original);
    }

    #[test]
    fn a_corrupt_file_is_moved_aside() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OpenSessionsRecord::FILE_NAME);
        std::fs::write(&path, b"{ not json").expect("seed");

        assert_eq!(read_open_sessions_blocking(&path), OpenSessionsLoad::Empty);
        assert_eq!(moved_aside(dir.path()).len(), 1);
    }

    #[test]
    fn a_missing_file_loads_empty_and_creates_nothing() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OpenSessionsRecord::FILE_NAME);

        assert_eq!(read_open_sessions_blocking(&path), OpenSessionsLoad::Empty);
        assert_eq!(std::fs::read_dir(dir.path()).expect("list").count(), 0);
    }

    #[test]
    fn a_written_record_loads() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OpenSessionsRecord::FILE_NAME);
        let record = record();
        std::fs::write(&path, encode_document(&record).expect("encode")).expect("seed");

        assert_eq!(read_open_sessions_blocking(&path), OpenSessionsLoad::Restored(record));
    }

    #[test]
    fn keys_keep_the_recorded_order_once_each() {
        let first = SessionKey::Saved(Uuid::new_v4());
        let second = SessionKey::File("file:///srv/app.db".to_owned());

        let keys = OpenSessionsRecord::from_keys([&first, &second, &first]).keys();

        assert_eq!(keys, [first, second]);
    }
}
