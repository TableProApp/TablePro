use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tablepro_core::AuthMode;
use tokio::sync::watch;
use uuid::Uuid;

use crate::document_problem::{DocumentProblem, DocumentProblemKind};
use crate::error::StorageError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedConnection {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    pub use_tls: bool,
    #[serde(default)]
    pub read_only: bool,
    #[serde(default)]
    pub auth_mode: AuthMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<SavedSshConfig>,
    /// Last successful open of this connection. Drives the welcome
    /// view's recency-first sort. `None` for connections saved before
    /// this field shipped (legacy files just deserialize into None);
    /// they sort after every connection that has been opened at least
    /// once and fall back to alphabetical against each other.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_opened_at: Option<DateTime<Utc>>,
    /// A colour the user put on this connection to tell production
    /// apart from staging at a glance. `None` until they pick one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<crate::ConnectionColor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSshConfig {
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub jump_hosts: Vec<String>,
    pub auth: SavedSshAuth,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SavedSshAuth {
    Agent,
    PrivateKey {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<PathBuf>,
        #[serde(default)]
        has_passphrase: bool,
    },
    Password,
    KeyboardInteractive,
}

/// The saved-connection list as it sits on disk.
#[derive(Debug, Serialize, Deserialize)]
struct ConnectionsDocument {
    connections: Vec<SavedConnection>,
}

impl crate::document::VersionedDocument for ConnectionsDocument {
    const KIND: &'static str = "connections";
    const VERSION: u32 = 1;
}

/// What the store knows about the list right now.
#[derive(Debug, Clone)]
pub enum ConnectionListState {
    /// Nothing read yet.
    Loading,
    Ready(Arc<[SavedConnection]>),
    /// The file exists but cannot be used. The store refuses every write
    /// while in this state, because a write would destroy whatever the
    /// user could still recover by hand.
    Unavailable(Arc<DocumentProblem>),
}

/// A state plus a counter, so a view can tell a real change from a
/// re-publish of the same list.
#[derive(Debug, Clone)]
pub struct ConnectionListSnapshot {
    pub revision: u64,
    pub state: ConnectionListState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoveOutcome {
    Removed,
    NotPresent,
}

#[derive(Debug)]
enum StoreState {
    Unloaded,
    Ready(Vec<SavedConnection>),
    Unavailable(DocumentProblem),
}

/// The saved-connection list on disk. One store per storage root, so a
/// development build and an installed build never share a file.
///
/// Every mutation holds the mutex across read, apply, encode and write,
/// so two threads cannot interleave a read-modify-write and lose an
/// entry.
#[derive(Clone)]
pub struct ConnectionStore {
    inner: Arc<StoreInner>,
}

struct StoreInner {
    path: PathBuf,
    state: Mutex<StoreState>,
    snapshot: watch::Sender<ConnectionListSnapshot>,
}

impl ConnectionStore {
    pub fn new(paths: &crate::StoragePaths) -> Self {
        let (snapshot, _) = watch::channel(ConnectionListSnapshot {
            revision: 0,
            state: ConnectionListState::Loading,
        });
        Self {
            inner: Arc::new(StoreInner {
                path: paths.connections_file(),
                state: Mutex::new(StoreState::Unloaded),
                snapshot,
            }),
        }
    }

    pub fn path(&self) -> &Path {
        &self.inner.path
    }

    pub fn subscribe(&self) -> watch::Receiver<ConnectionListSnapshot> {
        self.inner.snapshot.subscribe()
    }

    pub fn snapshot(&self) -> ConnectionListSnapshot {
        self.inner.snapshot.borrow().clone()
    }

    pub fn load_blocking(&self) -> Result<Arc<[SavedConnection]>, StorageError> {
        let mut state = self.lock();
        let list = self.ensure_loaded(&mut state)?;
        Ok(list)
    }

    pub fn upsert_blocking(&self, connection: SavedConnection) -> Result<(), StorageError> {
        let mut state = self.lock();
        let mut list = self.ensure_loaded(&mut state)?.to_vec();
        list.retain(|saved| saved.id != connection.id);
        list.push(connection);
        self.commit(&mut state, list)
    }

    pub fn remove_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        let mut state = self.lock();
        let mut list = self.ensure_loaded(&mut state)?.to_vec();
        let before = list.len();
        list.retain(|saved| saved.id != id);
        if list.len() == before {
            return Ok(RemoveOutcome::NotPresent);
        }
        self.commit(&mut state, list)?;
        Ok(RemoveOutcome::Removed)
    }

    /// Stamp the last-opened time so the welcome view can sort
    /// recency-first. An id that is not in the list writes nothing:
    /// a connection opened without saving has nothing to update.
    pub fn touch_last_opened_blocking(&self, id: Uuid) -> Result<(), StorageError> {
        let mut state = self.lock();
        let mut list = self.ensure_loaded(&mut state)?.to_vec();
        let Some(connection) = list.iter_mut().find(|saved| saved.id == id) else {
            return Ok(());
        };
        connection.last_opened_at = Some(Utc::now());
        self.commit(&mut state, list)
    }

    /// Move the unreadable file aside and start from an empty list,
    /// returning the name the old file now has so the user can find it.
    /// Only valid while the list is unavailable.
    pub fn reset_unreadable_blocking(&self, now: std::time::SystemTime) -> Result<PathBuf, StorageError> {
        let mut state = self.lock();
        if !matches!(*state, StoreState::Unavailable(_)) {
            return Err(StorageError::Schema(
                "the saved connections are readable; there is nothing to reset".to_owned(),
            ));
        }
        let moved = crate::fs::move_aside_blocking(&self.inner.path, now)?;
        *state = StoreState::Ready(Vec::new());
        self.publish(&state);
        Ok(moved)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, StoreState> {
        match self.inner.state.lock() {
            Ok(guard) => guard,
            // A panic mid-mutation leaves the cache suspect, so drop it
            // and read the file again.
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                *guard = StoreState::Unloaded;
                guard
            }
        }
    }

    fn ensure_loaded(&self, state: &mut StoreState) -> Result<Arc<[SavedConnection]>, StorageError> {
        if let StoreState::Unloaded = state {
            *state = match read_document(&self.inner.path) {
                Ok(list) => StoreState::Ready(list),
                Err(problem) => StoreState::Unavailable(problem),
            };
            self.publish(state);
        }
        match state {
            StoreState::Ready(list) => Ok(Arc::from(list.as_slice())),
            StoreState::Unavailable(problem) => Err(StorageError::DocumentUnavailable(problem.clone())),
            StoreState::Unloaded => unreachable!("just loaded"),
        }
    }

    /// Write first, then adopt. A failed write leaves both the file and
    /// the cached list exactly as they were.
    fn commit(&self, state: &mut StoreState, list: Vec<SavedConnection>) -> Result<(), StorageError> {
        let document = ConnectionsDocument {
            connections: list.clone(),
        };
        let bytes = crate::document::encode_document(&document)?;
        crate::fs::write_private_blocking(&self.inner.path, &bytes)?;
        *state = StoreState::Ready(list);
        self.publish(state);
        Ok(())
    }

    fn publish(&self, state: &StoreState) {
        let next = match state {
            StoreState::Unloaded => ConnectionListState::Loading,
            StoreState::Ready(list) => ConnectionListState::Ready(Arc::from(list.as_slice())),
            StoreState::Unavailable(problem) => ConnectionListState::Unavailable(Arc::new(problem.clone())),
        };
        let revision = self.inner.snapshot.borrow().revision + 1;
        // send() drops the value when no receiver is alive, which would
        // leave the snapshot stale before the first window opens.
        self.inner
            .snapshot
            .send_replace(ConnectionListSnapshot { revision, state: next });
    }
}

impl std::fmt::Debug for ConnectionStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionStore")
            .field("path", &self.inner.path)
            .finish()
    }
}

fn read_document(path: &Path) -> Result<Vec<SavedConnection>, DocumentProblem> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        // No file is an empty list, not a problem: a first run has none.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(DocumentProblem::new(
                path,
                DocumentProblemKind::Unreadable {
                    detail: error.to_string(),
                },
            ));
        }
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        return Ok(Vec::new());
    }
    crate::document::decode_document::<ConnectionsDocument>(path, &bytes).map(|document| document.connections)
}

/// A copy of `source` under a name no other connection holds.
///
/// The copy is a new connection, not a second reference to the same
/// one: it takes a fresh id, so its secrets are its own and deleting
/// either leaves the other alone.
pub fn duplicate(source: &SavedConnection, taken: &[SavedConnection]) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: copy_name(&source.name, &taken.iter().map(|c| c.name.as_str()).collect::<Vec<_>>()),
        // A copy has never been opened, whatever the original did, so
        // it sorts by name rather than claiming the original's recency.
        // The colour does carry: a copy points at the same server, so
        // it belongs to the same group of connections at a glance.
        last_opened_at: None,
        ..source.clone()
    }
}

/// `name (copy)`, then `name (copy 2)` and on, until one is free.
fn copy_name(name: &str, taken: &[&str]) -> String {
    let first = format!("{name} (copy)");
    if !taken.contains(&first.as_str()) {
        return first;
    }
    // A name is short and the list is a person's own connections, so
    // counting up from two is bounded by how many copies they made.
    (2..)
        .map(|n| format!("{name} (copy {n})"))
        .find(|candidate| !taken.contains(&candidate.as_str()))
        .unwrap_or(first)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc as StdArc;

    fn saved(name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.internal".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            use_tls: true,
            read_only: false,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: Some(Utc::now()),
            color: None,
        }
    }

    #[test]
    fn a_copy_keeps_everything_that_says_where_to_connect() {
        let source = saved("production");

        let copy = duplicate(&source, std::slice::from_ref(&source));

        assert_eq!(copy.host, source.host);
        assert_eq!(copy.port, source.port);
        assert_eq!(copy.database, source.database);
        assert_eq!(copy.username, source.username);
        assert_eq!(copy.use_tls, source.use_tls);
        assert_eq!(copy.driver_id, source.driver_id);
    }

    #[test]
    fn a_copy_keeps_the_colour_because_it_points_at_the_same_server() {
        let mut source = saved("production");
        source.color = Some(crate::ConnectionColor::Red);

        let copy = duplicate(&source, std::slice::from_ref(&source));

        assert_eq!(copy.color, Some(crate::ConnectionColor::Red));
    }

    #[test]
    fn a_copy_is_its_own_connection_not_a_second_name_for_one() {
        let source = saved("production");

        let copy = duplicate(&source, std::slice::from_ref(&source));

        assert_ne!(copy.id, source.id, "the copy shares the original's secrets");
        assert_eq!(copy.last_opened_at, None, "the copy claimed the original's recency");
    }

    #[test]
    fn copies_count_up_rather_than_colliding() {
        let first = saved("production");
        let mut taken = vec![first.clone()];

        for expected in ["production (copy)", "production (copy 2)", "production (copy 3)"] {
            let copy = duplicate(&first, &taken);
            assert_eq!(copy.name, expected);
            taken.push(copy);
        }
    }

    #[test]
    fn a_free_numbered_name_is_taken_before_counting_past_it() {
        let source = saved("db");
        let taken = vec![source.clone(), saved("db (copy)"), saved("db (copy 3)")];

        assert_eq!(duplicate(&source, &taken).name, "db (copy 2)");
    }

    use tempfile::TempDir;

    use super::*;

    fn sample_connection() -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Local Postgres".into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            username: "postgres".into(),
            use_tls: false,
            read_only: false,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
        }
    }

    fn store(root: &TempDir) -> ConnectionStore {
        ConnectionStore::new(&crate::StoragePaths::under(
            root.path(),
            "tablepro",
            "app.tablepro.TablePro",
        ))
    }

    fn seed(root: &TempDir, contents: &str) -> PathBuf {
        let paths = crate::StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
        let path = paths.connections_file();
        std::fs::create_dir_all(path.parent().expect("parent")).expect("create");
        std::fs::write(&path, contents).expect("seed");
        path
    }

    #[test]
    fn missing_file_is_ready_empty() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);

        let list = store.load_blocking().expect("load");

        assert!(list.is_empty());
        assert!(matches!(store.snapshot().state, ConnectionListState::Ready(_)));
    }

    #[test]
    fn upsert_then_load_round_trips() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();

        store.upsert_blocking(connection.clone()).expect("upsert");
        let reopened = ConnectionStore::new(&crate::StoragePaths::under(
            root.path(),
            "tablepro",
            "app.tablepro.TablePro",
        ));
        let list = reopened.load_blocking().expect("load");

        assert_eq!(list.len(), 1);
        assert_eq!(list[0], connection);
    }

    #[test]
    fn truncated_file_is_unavailable_and_upsert_leaves_bytes_identical() {
        let root = TempDir::new().expect("tempdir");
        let path = seed(&root, r#"{"version": 1, "connections": [{"id":"#);
        let before = std::fs::read(&path).expect("read");
        let store = store(&root);

        let refused = store.upsert_blocking(sample_connection());

        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
        assert_eq!(std::fs::read(&path).expect("read"), before);
        assert!(matches!(store.snapshot().state, ConnectionListState::Unavailable(_)));
    }

    #[test]
    fn version_2_is_newer_and_never_written() {
        let root = TempDir::new().expect("tempdir");
        let path = seed(&root, r#"{"version": 2, "connections": []}"#);
        let before = std::fs::read(&path).expect("read");
        let store = store(&root);

        let refused = store.upsert_blocking(sample_connection());

        assert!(matches!(refused, Err(StorageError::DocumentUnavailable(_))));
        assert_eq!(std::fs::read(&path).expect("read"), before);
        let ConnectionListState::Unavailable(problem) = store.snapshot().state else {
            panic!("expected Unavailable");
        };
        assert!(problem.is_newer_version());
    }

    #[test]
    fn missing_version_is_refused() {
        let root = TempDir::new().expect("tempdir");
        seed(&root, r#"{"connections": []}"#);

        let refused = store(&root).load_blocking();

        assert!(matches!(refused, Err(StorageError::DocumentUnavailable(_))));
    }

    #[test]
    fn unknown_auth_mode_is_corrupt_not_empty() {
        let root = TempDir::new().expect("tempdir");
        seed(
            &root,
            r#"{"version": 1, "connections": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","use_tls":false,"auth_mode":"from_the_future"}]}"#,
        );

        let refused = store(&root).load_blocking();

        // Silently treating this as an empty list would lose every saved
        // connection the moment a newer auth mode appears.
        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
    }

    #[test]
    fn concurrent_upserts_all_persist() {
        let root = TempDir::new().expect("tempdir");
        let store = StdArc::new(store(&root));

        let handles: Vec<_> = (0..16)
            .map(|index| {
                let store = StdArc::clone(&store);
                std::thread::spawn(move || {
                    let mut connection = sample_connection();
                    connection.name = format!("connection {index}");
                    store.upsert_blocking(connection).expect("upsert");
                })
            })
            .collect();
        for handle in handles {
            handle.join().expect("join");
        }

        let list = store.load_blocking().expect("load");
        assert_eq!(list.len(), 16, "an interleaved read-modify-write lost entries");
    }

    #[test]
    fn touch_missing_id_does_not_write() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(sample_connection()).expect("upsert");
        let path = store.path().to_owned();
        let before = std::fs::read(&path).expect("read");
        let revision = store.snapshot().revision;

        store.touch_last_opened_blocking(Uuid::new_v4()).expect("touch");

        assert_eq!(std::fs::read(&path).expect("read"), before);
        assert_eq!(store.snapshot().revision, revision);
    }

    #[test]
    fn touch_stamps_a_present_id() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();
        store.upsert_blocking(connection.clone()).expect("upsert");

        store.touch_last_opened_blocking(connection.id).expect("touch");

        let list = store.load_blocking().expect("load");
        assert!(list[0].last_opened_at.is_some());
    }

    #[test]
    fn remove_reports_whether_it_removed_anything() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();
        store.upsert_blocking(connection.clone()).expect("upsert");

        assert_eq!(
            store.remove_blocking(connection.id).expect("remove"),
            RemoveOutcome::Removed
        );
        assert_eq!(
            store.remove_blocking(connection.id).expect("remove again"),
            RemoveOutcome::NotPresent
        );
        assert!(store.load_blocking().expect("load").is_empty());
    }

    #[test]
    fn reset_returns_created_path_with_original_bytes_then_upsert_succeeds() {
        let root = TempDir::new().expect("tempdir");
        let path = seed(&root, "not json at all");
        let original = std::fs::read(&path).expect("read");
        let store = store(&root);
        store.load_blocking().expect_err("unavailable");

        let moved = store
            .reset_unreadable_blocking(std::time::SystemTime::now())
            .expect("reset");

        assert_eq!(std::fs::read(&moved).expect("read moved"), original);
        assert!(!path.exists());
        store.upsert_blocking(sample_connection()).expect("upsert after reset");
        assert_eq!(store.load_blocking().expect("load").len(), 1);
    }

    #[test]
    fn reset_is_refused_while_the_list_is_readable() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.load_blocking().expect("load");

        let refused = store.reset_unreadable_blocking(std::time::SystemTime::now());

        assert!(refused.is_err());
    }

    #[test]
    fn snapshot_revision_increments_per_successful_mutation() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();

        let start = store.snapshot().revision;
        store.load_blocking().expect("load");
        let after_load = store.snapshot().revision;
        store.upsert_blocking(connection.clone()).expect("upsert");
        let after_upsert = store.snapshot().revision;
        store.touch_last_opened_blocking(Uuid::new_v4()).expect("no-op touch");
        let after_noop = store.snapshot().revision;

        assert!(after_load > start);
        assert_eq!(after_upsert, after_load + 1);
        assert_eq!(after_noop, after_upsert, "a no-op must not publish");
    }

    #[test]
    fn a_subscriber_sees_the_new_list() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mut receiver = store.subscribe();

        store.upsert_blocking(sample_connection()).expect("upsert");

        let snapshot = receiver.borrow_and_update().clone();
        let ConnectionListState::Ready(list) = snapshot.state else {
            panic!("expected Ready");
        };
        assert_eq!(list.len(), 1);
    }

    #[test]
    fn saved_ssh_config_round_trips_optional_port_user_and_jumps() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let path = store.path().to_owned();
        let mut full = sample_connection();
        full.ssh = Some(SavedSshConfig {
            host: "bastion.example.com".into(),
            port: Some(2222),
            username: Some("deploy".into()),
            jump_hosts: vec!["ops@jump1:2200".into(), "[fd00::1]".into()],
            auth: SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: true,
            },
        });
        let mut minimal = sample_connection();
        minimal.ssh = Some(SavedSshConfig {
            host: "bastion".into(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        });

        store.upsert_blocking(full.clone()).expect("upsert full");
        store.upsert_blocking(minimal.clone()).expect("upsert minimal");
        assert_eq!(store.load_blocking().expect("load").to_vec(), vec![full, minimal]);

        let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
        let minimal_ssh = &raw["connections"][1]["ssh"];
        assert!(minimal_ssh.get("port").is_none());
        assert!(minimal_ssh.get("username").is_none());
        assert!(minimal_ssh.get("jump_hosts").is_none());
    }
    #[test]
    fn each_ssh_auth_mode_round_trips() {
        let cases = [
            (SavedSshAuth::Agent, "agent"),
            (
                SavedSshAuth::PrivateKey {
                    path: None,
                    has_passphrase: false,
                },
                "private_key",
            ),
            (SavedSshAuth::Password, "password"),
            (SavedSshAuth::KeyboardInteractive, "keyboard_interactive"),
        ];
        for (auth, kind) in cases {
            let json = serde_json::to_value(&auth).unwrap();
            assert_eq!(json["kind"], kind);
            assert_eq!(serde_json::from_value::<SavedSshAuth>(json).unwrap(), auth);
        }
    }
    #[test]
    fn unknown_ssh_auth_kind_fails_to_parse() {
        assert!(serde_json::from_str::<SavedSshAuth>(r#"{"kind":"gssapi"}"#).is_err());
    }
}
