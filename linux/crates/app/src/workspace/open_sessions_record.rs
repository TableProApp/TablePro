use std::io::ErrorKind;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tablepro_session::SessionKey;
use tablepro_storage::document::{Upgrade, VersionedDocument, decode_document};

use super::workspace_store::{MAX_FILE_BYTES, read_capped};
use super::{OpenSessionsLoad, SessionKeyRecord};

/// The sessions the windows showed, grouped by the window that held
/// them, so the next launch opens each group in a window again. Windows
/// come in the order they opened, and keys in the order their window
/// adopted them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenSessionsRecord {
    #[serde(default)]
    pub windows: Vec<Vec<SessionKeyRecord>>,
}

impl VersionedDocument for OpenSessionsRecord {
    const KIND: &'static str = "open-sessions";
    const VERSION: u32 = 2;
    const UPGRADES: &'static [Upgrade] = &[window_per_session];
}

/// Version 1 listed the sessions alone, and each opened in a window of
/// its own; version 2 keeps that by giving each one its own window.
fn window_per_session(mut document: Value) -> Result<Value, String> {
    let Value::Object(fields) = &mut document else {
        return Err("the record is not an object".to_owned());
    };
    let windows = match fields.remove("sessions") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(sessions)) => sessions.into_iter().map(|key| Value::Array(vec![key])).collect(),
        Some(_) => return Err("the sessions are not a list".to_owned()),
    };
    fields.insert("windows".to_owned(), Value::Array(windows));
    Ok(document)
}

impl OpenSessionsRecord {
    /// Beside the sessions' own files, under a name none of them can
    /// take.
    pub const FILE_NAME: &'static str = "open-sessions.json";

    pub fn from_windows<'a, W>(windows: impl IntoIterator<Item = W>) -> Self
    where
        W: IntoIterator<Item = &'a SessionKey>,
    {
        Self {
            windows: windows
                .into_iter()
                .map(|keys| keys.into_iter().map(SessionKeyRecord::from).collect())
                .collect(),
        }
    }

    /// The keys of each window, each key once across them all and no
    /// window left empty: a key repeated in the file would open a second
    /// window only to find the first, and an empty one would open a
    /// window on nothing.
    pub fn windows(self) -> Vec<Vec<SessionKey>> {
        let mut seen: Vec<SessionKey> = Vec::new();
        let mut windows: Vec<Vec<SessionKey>> = Vec::with_capacity(self.windows.len());
        for window in self.windows {
            let mut keys: Vec<SessionKey> = Vec::with_capacity(window.len());
            for key in window.into_iter().map(SessionKeyRecord::into_key) {
                if !seen.contains(&key) {
                    seen.push(key.clone());
                    keys.push(key);
                }
            }
            if !keys.is_empty() {
                windows.push(keys);
            }
        }
        windows
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
            windows: vec![
                vec![SessionKeyRecord::Saved { id: Uuid::new_v4() }],
                vec![SessionKeyRecord::File {
                    uri: "file:///srv/app.db".to_owned(),
                }],
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
        assert!(text.contains("\"version\": 2"), "{text}");
        assert!(text.contains("\"kind\": \"saved\""), "{text}");
    }

    #[test]
    fn unsupported_version_moved_aside_and_loads_empty() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OpenSessionsRecord::FILE_NAME);
        let original = br#"{"version": 3, "windows": []}"#;
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
    fn a_version_1_record_opens_each_session_in_a_window_of_its_own() {
        let first = Uuid::new_v4();
        let bytes = format!(
            r#"{{"version": 1, "sessions": [{{"kind": "saved", "id": "{first}"}}, {{"kind": "file", "uri": "file:///srv/app.db"}}]}}"#
        );

        let record: OpenSessionsRecord = decode_document(Path::new("/tmp/o.json"), bytes.as_bytes()).expect("decode");

        assert_eq!(
            record.windows(),
            [
                vec![SessionKey::Saved(first)],
                vec![SessionKey::File("file:///srv/app.db".to_owned())],
            ]
        );
    }

    #[test]
    fn a_version_1_record_without_sessions_opens_nothing() {
        let record: OpenSessionsRecord =
            decode_document(Path::new("/tmp/o.json"), br#"{"version": 1}"#).expect("decode");

        assert!(record.windows().is_empty());
    }

    #[test]
    fn round_trip_keeps_two_keys_in_one_window() {
        let (first, second) = (
            SessionKey::Saved(Uuid::new_v4()),
            SessionKey::File("file:///srv/app.db".to_owned()),
        );
        let record = OpenSessionsRecord::from_windows([[&first, &second]]);

        let bytes = encode_document(&record).expect("encode");
        let decoded: OpenSessionsRecord = decode_document(Path::new("/tmp/o.json"), &bytes).expect("decode");

        assert_eq!(decoded, record);
        assert_eq!(decoded.windows(), [vec![first, second]]);
    }

    #[test]
    fn a_key_in_two_windows_opens_in_the_first_only() {
        let (first, second) = (
            SessionKey::Saved(Uuid::new_v4()),
            SessionKey::File("file:///srv/app.db".to_owned()),
        );

        let windows = OpenSessionsRecord::from_windows([vec![&first, &second], vec![&first], vec![]]).windows();

        assert_eq!(windows, [vec![first, second]]);
    }

    #[test]
    fn keys_keep_the_recorded_order_once_each() {
        let first = SessionKey::Saved(Uuid::new_v4());
        let second = SessionKey::File("file:///srv/app.db".to_owned());

        let windows = OpenSessionsRecord::from_windows([vec![&first, &second, &first]]).windows();

        assert_eq!(windows, [vec![first, second]]);
    }
}
