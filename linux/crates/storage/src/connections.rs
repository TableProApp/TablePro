use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tablepro_core::credentials::SecretKind;
use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, NetworkOptions, SafeModeLevel, TlsConfig};
use tokio::sync::watch;
use uuid::Uuid;

use crate::document_problem::{DocumentProblem, DocumentProblemKind};
use crate::error::StorageError;
use crate::{ConnectionTag, ConnectionTagName};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedConnection {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    /// Required, with no default: a file without it was written before
    /// TLS modes existed, and guessing a mode for it could silently
    /// connect in the clear.
    pub tls: TlsConfig,
    /// Required, with no default: guessing Off for a file that lost it
    /// would drop a guard the user set.
    pub safe_mode: SafeModeLevel,
    /// What MCP clients may do here. A file written before the level
    /// existed reads as Read Only, the level a new connection starts at.
    #[serde(default)]
    pub external_access: ExternalAccess,
    /// What the AI assistant may send from here. A file written before
    /// the policy existed reads as Ask, the policy a new connection
    /// starts at.
    #[serde(default)]
    pub ai_policy: AiPolicy,
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
    /// The folder the user filed this connection under. `None` means it
    /// sits on its own, which is where every connection starts.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::connection_group_name::deserialize_stored"
    )]
    pub group: Option<crate::ConnectionGroupName>,
    /// Ids from the list's tags. Every picker shows them in the list's
    /// order, by name.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<crate::ConnectionIcon>,
    /// What the engine reads beyond host, port and database, such as a
    /// MongoDB DNS seed list. Only the engines that offer an option set
    /// it.
    #[serde(default, skip_serializing_if = "NetworkOptions::is_default")]
    pub options: NetworkOptions,
}

impl SavedConnection {
    /// What a secret of this connection belongs to, in the user's own
    /// terms. Seahorse and the credential prompt both show it, so it
    /// has to identify the connection without TablePro open.
    pub fn secret_target(&self, kind: SecretKind) -> String {
        match kind {
            SecretKind::DatabasePassword => self.database_target(),
            SecretKind::SshPassword => self.ssh_target(),
            SecretKind::SshPassphrase => self.passphrase_target(),
        }
    }

    /// Whether the keyring is meant to hold a passphrase for the SSH
    /// key. Without one the key is unencrypted, or ssh asks for it.
    pub fn has_stored_passphrase(&self) -> bool {
        matches!(
            self.ssh.as_ref().map(|ssh| &ssh.auth),
            Some(SavedSshAuth::PrivateKey {
                has_passphrase: true,
                ..
            })
        )
    }

    /// The SSH key file, when the connection names one.
    pub fn ssh_key_path(&self) -> Option<&Path> {
        match self.ssh.as_ref().map(|ssh| &ssh.auth) {
            Some(SavedSshAuth::PrivateKey { path, .. }) => path.as_deref(),
            _ => None,
        }
    }

    /// Whether the two differ at most in how the list shows them. A
    /// field added later counts as part of the connection until it is
    /// listed here.
    fn connects_like(&self, other: &Self) -> bool {
        let shown_alike = |saved: &Self| Self {
            name: String::new(),
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            ..saved.clone()
        };
        shown_alike(self) == shown_alike(other)
    }

    fn database_target(&self) -> String {
        let mut target = String::new();
        if !self.username.is_empty() {
            target.push_str(&self.username);
            target.push('@');
        }
        target.push_str(&self.host);
        target.push(':');
        target.push_str(&self.port.to_string());
        if !self.database.is_empty() {
            target.push('/');
            target.push_str(&self.database);
        }
        target
    }

    fn ssh_target(&self) -> String {
        let Some(ssh) = &self.ssh else {
            return self.host.clone();
        };
        match ssh.username.as_deref().filter(|user| !user.is_empty()) {
            Some(user) => format!("{user}@{}", ssh.host),
            None => ssh.host.clone(),
        }
    }

    /// A passphrase belongs to a key file, so the path identifies it
    /// better than the host. Without a path the key comes from the agent
    /// or the SSH config, and the host is all there is.
    fn passphrase_target(&self) -> String {
        match self.ssh_key_path() {
            Some(path) => path.display().to_string(),
            None => self.ssh_target(),
        }
    }
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
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct ConnectionsDocument {
    connections: Vec<SavedConnection>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tags: Vec<ConnectionTag>,
}

impl ConnectionsDocument {
    /// A tag named twice keeps its first entry and a connection names a
    /// tag at most once, whatever a hand-edited or crafted file says. A
    /// tag whose name another one holds becomes that one, so a connection
    /// keeps the label it showed.
    fn tidy(&mut self) {
        let mut kept: Vec<ConnectionTag> = Vec::with_capacity(self.tags.len());
        let mut same: HashMap<Uuid, Uuid> = HashMap::with_capacity(self.tags.len());
        let mut named: HashMap<String, Uuid> = HashMap::with_capacity(self.tags.len());
        for tag in std::mem::take(&mut self.tags) {
            if same.contains_key(&tag.id) {
                continue;
            }
            match named.entry(tag.name.key()) {
                Entry::Occupied(held) => {
                    same.insert(tag.id, *held.get());
                }
                Entry::Vacant(free) => {
                    free.insert(tag.id);
                    same.insert(tag.id, tag.id);
                    kept.push(tag);
                }
            }
        }
        self.tags = kept;
        for connection in &mut self.connections {
            let mut seen = HashSet::with_capacity(connection.tags.len());
            connection.tags = std::mem::take(&mut connection.tags)
                .iter()
                .filter_map(|id| same.get(id).copied())
                .filter(|id| seen.insert(*id))
                .collect();
        }
    }

    fn list(&self) -> ConnectionList {
        ConnectionList {
            connections: Arc::from(self.connections.as_slice()),
            tags: Arc::from(self.tags.as_slice()),
        }
    }
}

impl crate::document::VersionedDocument for ConnectionsDocument {
    const KIND: &'static str = "connections";
    const VERSION: u32 = 2;
    const UPGRADES: &'static [crate::document::Upgrade] = &[read_only_to_safe_mode];
}

/// Version 1 had a read-only switch, which became the Safe Mode level:
/// on is Read-Only, off is Off.
fn read_only_to_safe_mode(mut document: serde_json::Value) -> Result<serde_json::Value, String> {
    let slot = document
        .get_mut("connections")
        .ok_or_else(|| "the file has no list of connections".to_owned())?;
    let switches: Vec<ReadOnlySwitch> = serde_json::from_value(slot.take()).map_err(|error| error.to_string())?;
    let levels: Vec<SafeModeLevelled> = switches
        .into_iter()
        .map(|connection| SafeModeLevelled {
            safe_mode: match connection.read_only.unwrap_or(false) {
                true => SafeModeLevel::ReadOnly,
                false => SafeModeLevel::Off,
            },
            rest: connection.rest,
        })
        .collect();
    *slot = serde_json::to_value(levels).map_err(|error| error.to_string())?;
    Ok(document)
}

/// A version 1 connection: its switch, and everything else as it was.
#[derive(Deserialize)]
struct ReadOnlySwitch {
    #[serde(default)]
    read_only: Option<bool>,
    #[serde(flatten)]
    rest: serde_json::Value,
}

#[derive(Serialize)]
struct SafeModeLevelled {
    safe_mode: SafeModeLevel,
    #[serde(flatten)]
    rest: serde_json::Value,
}

/// The connections and the tags they can carry, as one write left them.
#[derive(Debug, Clone, Default)]
pub struct ConnectionList {
    pub connections: Arc<[SavedConnection]>,
    pub tags: Arc<[ConnectionTag]>,
}

impl ConnectionList {
    pub fn new(connections: impl Into<Arc<[SavedConnection]>>, tags: impl Into<Arc<[ConnectionTag]>>) -> Self {
        Self {
            connections: connections.into(),
            tags: tags.into(),
        }
    }
}

/// What the store knows about the list right now.
#[derive(Debug, Clone)]
pub enum ConnectionListState {
    /// Nothing read yet.
    Loading,
    Ready(ConnectionList),
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

/// What an import did to the list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ImportReport {
    /// Connections the list did not have, including one whose id was
    /// taken by a different connection and was given its own.
    pub added: usize,
    /// Connections already in the list that the file only renamed,
    /// recoloured, regrouped, retagged or gave another icon.
    pub updated: usize,
}

impl ImportReport {
    pub fn total(self) -> usize {
        self.added + self.updated
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoveOutcome {
    Removed,
    NotPresent,
}

#[derive(Debug)]
enum StoreState {
    Unloaded,
    Ready(ConnectionsDocument),
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
        Ok(Arc::from(self.ensure_loaded(&mut state)?.connections))
    }

    pub fn tags_blocking(&self) -> Result<Arc<[ConnectionTag]>, StorageError> {
        let mut state = self.lock();
        Ok(Arc::from(self.ensure_loaded(&mut state)?.tags))
    }

    pub fn upsert_blocking(&self, connection: SavedConnection) -> Result<(), StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        document.connections.retain(|saved| saved.id != connection.id);
        document.connections.push(connection);
        self.commit(&mut state, document)
    }

    pub fn remove_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        let before = document.connections.len();
        document.connections.retain(|saved| saved.id != id);
        if document.connections.len() == before {
            return Ok(RemoveOutcome::NotPresent);
        }
        self.commit(&mut state, document)?;
        Ok(RemoveOutcome::Removed)
    }

    /// A new tag, which no connection carries yet. A name another tag
    /// holds in any case is refused, since the two would read as one.
    pub fn create_tag_blocking(
        &self,
        name: ConnectionTagName,
        color: crate::ConnectionColor,
    ) -> Result<ConnectionTag, StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        if document.tags.iter().any(|tag| tag.name.same_name(name.as_str())) {
            return Err(StorageError::TagNameTaken);
        }
        let tag = ConnectionTag::new(name, color);
        document.tags.push(tag.clone());
        self.commit(&mut state, document)?;
        Ok(tag)
    }

    /// Rename or recolour the tag with `changed`'s id, on every
    /// connection that carries it.
    pub fn update_tag_blocking(&self, changed: ConnectionTag) -> Result<(), StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        if document
            .tags
            .iter()
            .any(|tag| tag.id != changed.id && tag.name.same_name(changed.name.as_str()))
        {
            return Err(StorageError::TagNameTaken);
        }
        let Some(tag) = document.tags.iter_mut().find(|tag| tag.id == changed.id) else {
            return Err(StorageError::NotFound);
        };
        if *tag == changed {
            return Ok(());
        }
        *tag = changed;
        self.commit(&mut state, document)
    }

    /// Delete a tag and take it off every connection, in one write.
    pub fn delete_tag_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        let before = document.tags.len();
        document.tags.retain(|tag| tag.id != id);
        if document.tags.len() == before {
            return Ok(RemoveOutcome::NotPresent);
        }
        self.commit(&mut state, document)?;
        Ok(RemoveOutcome::Removed)
    }

    /// Change the entry `id` as the list holds it at the moment of the
    /// write, so a stamp or an edit from another window in between is
    /// kept. Returns the entry as it now is, or `None` when the list has
    /// no such entry. A change that changes nothing writes nothing.
    pub fn update_blocking(
        &self,
        id: Uuid,
        change: impl FnOnce(&mut SavedConnection),
    ) -> Result<Option<SavedConnection>, StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        let Some(index) = document.connections.iter().position(|saved| saved.id == id) else {
            return Ok(None);
        };
        let before = document.connections[index].clone();
        change(&mut document.connections[index]);
        // The keyring files the entry's secrets under its id.
        document.connections[index].id = id;
        document.tidy();
        let updated = document.connections[index].clone();
        if updated != before {
            self.commit(&mut state, document)?;
        }
        Ok(Some(updated))
    }

    /// Stamp the last-opened time so the welcome view can sort
    /// recency-first. An id that is not in the list writes nothing:
    /// a connection opened without saving has nothing to update.
    pub fn touch_last_opened_blocking(&self, id: Uuid) -> Result<(), StorageError> {
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        let Some(connection) = document.connections.iter_mut().find(|saved| saved.id == id) else {
            return Ok(());
        };
        connection.last_opened_at = Some(Utc::now());
        self.commit(&mut state, document)
    }

    /// The saved connections as a document to hand to the user.
    ///
    /// It carries no passwords: those are in the keyring, and a file
    /// the user mails themselves is the wrong place for one. What it
    /// does carry is every host, port, user name, database name and SSH
    /// setting, which is why the UI says so before writing it.
    pub fn export_blocking(&self) -> Result<Vec<u8>, StorageError> {
        let mut state = self.lock();
        let document = self.ensure_loaded(&mut state)?;
        Ok(crate::document::encode_document(&document)?)
    }

    /// Merge an exported document back into the list.
    ///
    /// Connections are matched by id, so re-importing a file the user
    /// exported from this machine updates the entries it came from
    /// rather than doubling them, and a file from another machine adds
    /// its own. `path` names the file in any problem reported, since
    /// the user picked it and needs to know which one was refused.
    ///
    /// The keyring keeps secrets by connection id, so an entry may only
    /// be updated by one that sends them to the same place in the same
    /// way. Anything else under a taken id is added under a new id and
    /// starts with no secrets, so a crafted file cannot point a saved
    /// connection's password at another host.
    ///
    /// An imported entry never takes a name another entry holds, and an
    /// added one never takes the file's last-opened time, so a file
    /// cannot pass one host off as another saved connection or sort it
    /// above one.
    ///
    /// Tags are matched by id first and then by name, so importing a
    /// file twice, or a file from a machine whose `production` tag has
    /// another id, leaves one tag of each name.
    pub fn import_blocking(&self, path: &Path, bytes: &[u8]) -> Result<ImportReport, StorageError> {
        let mut incoming = crate::document::decode_document::<ConnectionsDocument>(path, bytes)
            .map_err(StorageError::DocumentUnavailable)?;
        incoming.tidy();
        let mut state = self.lock();
        let mut document = self.ensure_loaded(&mut state)?;
        let mut report = ImportReport::default();
        let same = merge_tags(&mut document.tags, incoming.tags);
        for mut connection in incoming.connections {
            connection.tags = connection.tags.iter().filter_map(|id| same.get(id).copied()).collect();
            let list = &mut document.connections;
            match list.iter().position(|saved| saved.id == connection.id) {
                Some(index) if list[index].connects_like(&connection) => {
                    let name = unclaimed_name(list, &connection.name, Some(connection.id));
                    let existing = &mut list[index];
                    existing.name = name;
                    existing.color = connection.color;
                    existing.group = connection.group;
                    existing.tags = connection.tags;
                    existing.icon = connection.icon;
                    report.updated += 1;
                }
                Some(_) => {
                    connection.id = Uuid::new_v4();
                    add_imported(list, connection);
                    report.added += 1;
                }
                None => {
                    add_imported(list, connection);
                    report.added += 1;
                }
            }
        }
        // Nothing to write for an empty file, and writing anyway would
        // rewrite the list for no reason.
        if report.total() == 0 {
            return Ok(report);
        }
        self.commit(&mut state, document)?;
        Ok(report)
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
        *state = StoreState::Ready(ConnectionsDocument::default());
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

    /// A copy of the list to change, read from disk the first time.
    fn ensure_loaded(&self, state: &mut StoreState) -> Result<ConnectionsDocument, StorageError> {
        if let StoreState::Unloaded = state {
            *state = match read_document(&self.inner.path) {
                Ok(document) => StoreState::Ready(document),
                Err(problem) => StoreState::Unavailable(problem),
            };
            self.publish(state);
        }
        match state {
            StoreState::Ready(document) => Ok(document.clone()),
            StoreState::Unavailable(problem) => Err(StorageError::DocumentUnavailable(problem.clone())),
            StoreState::Unloaded => unreachable!("just loaded"),
        }
    }

    /// Write first, then adopt. A failed write leaves both the file and
    /// the cached list exactly as they were.
    fn commit(&self, state: &mut StoreState, mut document: ConnectionsDocument) -> Result<(), StorageError> {
        // A connection saved with a tag deleted meanwhile drops it here.
        document.tidy();
        let bytes = crate::document::encode_document(&document)?;
        crate::fs::write_private_blocking(&self.inner.path, &bytes)?;
        *state = StoreState::Ready(document);
        self.publish(state);
        Ok(())
    }

    fn publish(&self, state: &StoreState) {
        let next = match state {
            StoreState::Unloaded => ConnectionListState::Loading,
            StoreState::Ready(document) => ConnectionListState::Ready(document.list()),
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

fn read_document(path: &Path) -> Result<ConnectionsDocument, DocumentProblem> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        // No file is an empty list, not a problem: a first run has none.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(ConnectionsDocument::default()),
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
        return Ok(ConnectionsDocument::default());
    }
    let mut document = crate::document::decode_document::<ConnectionsDocument>(path, &bytes)?;
    document.tidy();
    Ok(document)
}

/// Bring the file's tags into `local` and say which local tag each of
/// the file's ids now stands for. A tag the list has by id takes the
/// file's colour, and its name unless another tag holds that name; one
/// the list has by name only is that tag; any other is added.
fn merge_tags(local: &mut Vec<ConnectionTag>, incoming: Vec<ConnectionTag>) -> HashMap<Uuid, Uuid> {
    // Maps rather than scans: a crafted file of many tags must not make
    // an import hold the store for minutes.
    let mut at: HashMap<Uuid, usize> = local.iter().enumerate().map(|(index, tag)| (tag.id, index)).collect();
    let mut named: HashMap<String, Uuid> = local.iter().map(|tag| (tag.name.key(), tag.id)).collect();
    let mut same = HashMap::with_capacity(incoming.len());
    // Renames first, so a name one of them frees or takes decides the
    // rest whatever order the file lists them in.
    let (known, unknown): (Vec<ConnectionTag>, Vec<ConnectionTag>) =
        incoming.into_iter().partition(|tag| at.contains_key(&tag.id));
    for tag in known.into_iter().chain(unknown) {
        let key = tag.name.key();
        if let Some(&index) = at.get(&tag.id) {
            let held = &mut local[index];
            if named.get(&key).is_none_or(|owner| *owner == tag.id) {
                named.remove(&held.name.key());
                named.insert(key, tag.id);
                held.name = tag.name;
            }
            held.color = tag.color;
            same.insert(tag.id, tag.id);
        } else if let Some(&owner) = named.get(&key) {
            same.insert(tag.id, owner);
        } else {
            at.insert(tag.id, local.len());
            named.insert(key, tag.id);
            same.insert(tag.id, tag.id);
            local.push(tag);
        }
    }
    same
}

/// Add an entry the import brought. Two rows of one name, one of them
/// pointing somewhere else, would leave the user guessing which is
/// theirs, and a file's last-opened time is no open on this machine.
fn add_imported(list: &mut Vec<SavedConnection>, mut connection: SavedConnection) {
    connection.name = unclaimed_name(list, &connection.name, None);
    connection.last_opened_at = None;
    list.push(connection);
}

/// `name`, or a suffixed one when an entry other than `owner` holds it.
fn unclaimed_name(list: &[SavedConnection], name: &str, owner: Option<Uuid>) -> String {
    let taken: Vec<&str> = list
        .iter()
        .filter(|saved| Some(saved.id) != owner)
        .map(|saved| saved.name.as_str())
        .collect();
    if taken.contains(&name) {
        suffixed_name(name, "imported", &taken)
    } else {
        name.to_owned()
    }
}

/// `name (suffix)`, then `name (suffix 2)` and on, until one is free.
fn suffixed_name(name: &str, suffix: &str, taken: &[&str]) -> String {
    let first = format!("{name} ({suffix})");
    if !taken.contains(&first.as_str()) {
        return first;
    }
    // A name is short and the list is a person's own connections, so
    // counting up from two is bounded by how many imports took it.
    (2..)
        .map(|n| format!("{name} ({suffix} {n})"))
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
            tls: TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: Some(Utc::now()),
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
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
            tls: TlsConfig::disabled(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
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
    fn f003_truncated_file_is_unavailable_and_upsert_leaves_bytes_identical() {
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
    fn f003_a_newer_version_is_never_written() {
        let root = TempDir::new().expect("tempdir");
        let path = seed(&root, r#"{"version": 3, "connections": []}"#);
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
            r#"{"version": 1, "connections": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","tls":{"mode":"disable"},"auth_mode":"from_the_future"}]}"#,
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
    fn a_version_1_entry_without_the_switch_reads_as_off() {
        let root = TempDir::new().expect("tempdir");
        seed(&root, &connections_json(None));

        let list = store(&root).load_blocking().expect("load");

        assert_eq!(list[0].safe_mode, SafeModeLevel::Off);
    }

    #[test]
    fn a_version_1_switch_that_is_not_a_bool_is_refused() {
        let root = TempDir::new().expect("tempdir");
        seed(
            &root,
            r#"{"version": 1, "connections": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","tls":{"mode":"disable"},"read_only":"yes"}]}"#,
        );

        let refused = store(&root).load_blocking();

        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
    }

    #[test]
    fn a_version_2_entry_without_a_level_is_refused() {
        let root = TempDir::new().expect("tempdir");
        seed(
            &root,
            r#"{"version": 2, "connections": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","tls":{"mode":"disable"}}]}"#,
        );

        let refused = store(&root).load_blocking();

        // Guessing Off would drop a Read-Only the user set.
        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
    }

    #[test]
    fn saved_connection_requires_tls_field() {
        let root = TempDir::new().expect("tempdir");
        seed(
            &root,
            r#"{"version": 1, "connections": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","use_tls":true}]}"#,
        );

        let refused = store(&root).load_blocking();

        // A list written before TLS modes is refused rather than read as
        // a guess, which could connect in the clear.
        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
    }

    #[test]
    fn a_tls_configuration_round_trips_with_its_files() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mut connection = sample_connection();
        connection.tls = TlsConfig {
            ca_file: Some(PathBuf::from("/etc/ssl/db-ca.pem")),
            server_name: Some("db.example.com".to_owned()),
            ..TlsConfig::verify_full()
        };

        store.upsert_blocking(connection.clone()).expect("upsert");
        let list = store.load_blocking().expect("load");

        assert_eq!(list[0].tls, connection.tls);
    }

    fn with_ssh(auth: SavedSshAuth) -> SavedConnection {
        SavedConnection {
            ssh: Some(SavedSshConfig {
                host: "bastion.example.com".to_owned(),
                port: Some(2222),
                username: Some("deploy".to_owned()),
                jump_hosts: Vec::new(),
                auth,
            }),
            database: "shop".to_owned(),
            ..sample_connection()
        }
    }

    #[test]
    fn secret_targets_name_what_each_secret_unlocks() {
        let key = with_ssh(SavedSshAuth::PrivateKey {
            path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
            has_passphrase: true,
        });

        assert_eq!(
            key.secret_target(SecretKind::DatabasePassword),
            "postgres@localhost:5432/shop"
        );
        assert_eq!(key.secret_target(SecretKind::SshPassword), "deploy@bastion.example.com");
        assert_eq!(key.secret_target(SecretKind::SshPassphrase), "/home/u/.ssh/id_ed25519");
        assert!(key.has_stored_passphrase());
        assert_eq!(key.ssh_key_path(), Some(Path::new("/home/u/.ssh/id_ed25519")));
    }

    #[test]
    fn a_passphrase_without_a_key_file_names_the_host() {
        let agent_key = with_ssh(SavedSshAuth::PrivateKey {
            path: None,
            has_passphrase: false,
        });

        assert_eq!(
            agent_key.secret_target(SecretKind::SshPassphrase),
            "deploy@bastion.example.com"
        );
        assert!(!agent_key.has_stored_passphrase());
        assert_eq!(
            sample_connection().secret_target(SecretKind::SshPassword),
            "localhost",
            "no SSH section falls back to the database host"
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
        assert_eq!(list.connections.len(), 1);
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

    #[test]
    fn an_export_holds_every_connection() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(saved("production")).expect("upsert");
        store.upsert_blocking(saved("staging")).expect("upsert");

        let bytes = store.export_blocking().expect("export");
        let text = String::from_utf8(bytes).expect("utf-8");

        assert!(text.contains("production"), "{text}");
        assert!(text.contains("staging"), "{text}");
        assert!(text.contains("\"version\": 2"), "{text}");
    }

    /// Every key in `value`, however deep, so a secret cannot be added
    /// to a nested struct without this noticing.
    fn keys(value: &serde_json::Value, found: &mut Vec<String>) {
        match value {
            serde_json::Value::Object(map) => {
                for (key, child) in map {
                    found.push(key.clone());
                    keys(child, found);
                }
            }
            serde_json::Value::Array(items) => items.iter().for_each(|item| keys(item, found)),
            _ => {}
        }
    }

    #[test]
    fn an_export_carries_no_secret() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mut connection = saved("production");
        connection.ssh = Some(SavedSshConfig {
            host: "bastion.internal".to_owned(),
            port: Some(22),
            username: Some("deploy".to_owned()),
            jump_hosts: vec!["edge.internal".to_owned()],
            auth: SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/me/.ssh/id_ed25519")),
                has_passphrase: true,
            },
        });
        store.upsert_blocking(connection).expect("upsert");

        let bytes = store.export_blocking().expect("export");
        let mut found = Vec::new();
        keys(&serde_json::from_slice(&bytes).expect("json"), &mut found);

        // Secrets live in the keyring. The structs have no field for
        // one, and this is the guard against ever adding it.
        for key in &found {
            let lowered = key.to_lowercase();
            assert!(
                !(lowered.contains("password") || lowered.contains("passphrase") || lowered.contains("secret"))
                    || lowered == "has_passphrase",
                "the export carries a {key} field: {found:?}"
            );
        }
        assert!(found.contains(&"has_passphrase".to_owned()), "{found:?}");
    }

    #[test]
    fn an_export_imports_back_into_an_empty_list() {
        let source_root = TempDir::new().expect("tempdir");
        let source = store(&source_root);
        source.upsert_blocking(saved("production")).expect("upsert");
        let bytes = source.export_blocking().expect("export");

        let target_root = TempDir::new().expect("tempdir");
        let target = store(&target_root);
        let report = target
            .import_blocking(Path::new("/tmp/connections.json"), &bytes)
            .expect("import");

        assert_eq!(report, ImportReport { added: 1, updated: 0 });
        let list = target.load_blocking().expect("load");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "production");
    }

    #[test]
    fn importing_the_same_file_twice_updates_rather_than_doubles() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mut connection = saved("production");
        store.upsert_blocking(connection.clone()).expect("upsert");
        connection.name = "production (renamed)".to_owned();
        let document = ConnectionsDocument {
            connections: vec![connection],
            ..ConnectionsDocument::default()
        };
        let bytes = crate::document::encode_document(&document).expect("encode");

        let first = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");
        let second = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(first, ImportReport { added: 0, updated: 1 });
        assert_eq!(second, ImportReport { added: 0, updated: 1 });
        let list = store.load_blocking().expect("load");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "production (renamed)");
    }

    #[test]
    fn an_import_never_points_a_saved_entry_or_its_secrets_somewhere_else() {
        let mut elsewhere = saved("production");
        elsewhere.host = "db.attacker.example".to_owned();
        let mut in_the_clear = saved("production");
        in_the_clear.tls = TlsConfig::disabled();
        for (variant, crafted) in [("another host", elsewhere), ("TLS off", in_the_clear)] {
            let root = TempDir::new().expect("tempdir");
            let store = store(&root);
            let mine = SavedConnection {
                id: crafted.id,
                ..saved("production")
            };
            store.upsert_blocking(mine.clone()).expect("upsert");
            let bytes = crate::document::encode_document(&ConnectionsDocument {
                connections: vec![crafted.clone()],
                ..ConnectionsDocument::default()
            })
            .expect("encode");

            let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

            assert_eq!(report, ImportReport { added: 1, updated: 0 }, "{variant}");
            let list = store.load_blocking().expect("load");
            assert_eq!(list.len(), 2, "{variant}");
            let kept = list.iter().find(|saved| saved.id == mine.id).expect("the saved entry");
            assert_eq!(*kept, mine, "{variant}: the import changed the saved entry");
            let imported = list.iter().find(|saved| saved.id != mine.id).expect("the import");
            assert_eq!(imported.name, "production (imported)", "{variant}");
            assert_eq!(imported.last_opened_at, None, "{variant}");
            assert_eq!(
                SavedConnection {
                    id: crafted.id,
                    name: crafted.name.clone(),
                    last_opened_at: crafted.last_opened_at,
                    ..imported.clone()
                },
                crafted,
                "{variant}"
            );
        }
    }

    #[test]
    fn an_import_added_under_a_new_id_keeps_a_name_nobody_holds() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = saved("production");
        store.upsert_blocking(mine.clone()).expect("upsert");
        let theirs = SavedConnection {
            id: mine.id,
            host: "staging.internal".to_owned(),
            ..saved("staging")
        };
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: vec![theirs],
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        let mut names: Vec<String> = store
            .load_blocking()
            .expect("load")
            .iter()
            .map(|saved| saved.name.clone())
            .collect();
        names.sort();
        assert_eq!(names, ["production", "staging"]);
    }

    #[test]
    fn an_imported_entry_cannot_pass_for_a_saved_one() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = saved("Production");
        store.upsert_blocking(mine.clone()).expect("upsert");
        let lookalike = SavedConnection {
            host: "db.attacker.example".to_owned(),
            last_opened_at: "2099-01-01T00:00:00Z".parse().ok(),
            ..saved("Production")
        };
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: vec![lookalike.clone(), lookalike.clone()],
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(report, ImportReport { added: 1, updated: 1 });
        let list = store.load_blocking().expect("load");
        let kept = list.iter().find(|saved| saved.id == mine.id).expect("the saved entry");
        assert_eq!(*kept, mine);
        let added = list.iter().find(|saved| saved.id == lookalike.id).expect("the import");
        assert_eq!(added.name, "Production (imported)");
        assert_eq!(added.last_opened_at, None, "the file's last-opened time came along");
    }

    #[test]
    fn an_import_leaves_the_connections_the_file_does_not_mention() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(saved("mine")).expect("upsert");
        let other_root = TempDir::new().expect("tempdir");
        let other = crate::connections::ConnectionStore::new(&crate::StoragePaths::under(
            other_root.path(),
            "tablepro",
            "app.tablepro.TablePro",
        ));
        other.upsert_blocking(saved("theirs")).expect("upsert");
        let bytes = other.export_blocking().expect("export");

        let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(report, ImportReport { added: 1, updated: 0 });
        let names: Vec<String> = store
            .load_blocking()
            .expect("load")
            .iter()
            .map(|saved| saved.name.clone())
            .collect();
        assert!(names.contains(&"mine".to_owned()), "{names:?}");
        assert!(names.contains(&"theirs".to_owned()), "{names:?}");
    }

    #[test]
    fn an_empty_export_imports_as_nothing() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(saved("mine")).expect("upsert");
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: Vec::new(),
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(report, ImportReport::default());
        assert_eq!(store.load_blocking().expect("load").len(), 1);
    }

    #[test]
    fn a_file_that_is_not_an_export_is_refused_by_name() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);

        let error = store
            .import_blocking(Path::new("/tmp/holiday.json"), b"{\"holiday\": true}")
            .expect_err("not an export");

        let StorageError::DocumentUnavailable(problem) = error else {
            panic!("expected a document problem, got {error:?}");
        };
        assert!(problem.to_string().contains("holiday.json"), "{problem}");
    }

    #[test]
    fn an_export_from_a_newer_build_is_refused_rather_than_half_read() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);

        let error = store
            .import_blocking(Path::new("/tmp/c.json"), br#"{"version": 99, "connections": []}"#)
            .expect_err("newer");

        let StorageError::DocumentUnavailable(problem) = error else {
            panic!("expected a document problem, got {error:?}");
        };
        assert!(problem.is_newer_version(), "{problem:?}");
    }

    fn connections_json(group: Option<&str>) -> String {
        let group = group.map_or_else(String::new, |group| format!(r#","group":{group}"#));
        format!(
            r#"{{"version": 1, "connections": [{{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","tls":{{"mode":"disable"}}{group}}}]}}"#
        )
    }

    #[test]
    fn group_round_trips_through_connections_document() {
        let root = TempDir::new().expect("tempdir");
        seed(&root, &connections_json(None));
        assert_eq!(store(&root).load_blocking().expect("load")[0].group, None);

        let root = TempDir::new().expect("tempdir");
        seed(&root, &connections_json(Some(r#"" Work ""#)));
        let opened = store(&root);
        let list = opened.load_blocking().expect("load");
        assert_eq!(
            list[0].group.as_ref().map(crate::ConnectionGroupName::as_str),
            Some("Work")
        );
        opened.upsert_blocking(list[0].clone()).expect("rewrite");
        let raw: serde_json::Value =
            serde_json::from_slice(&std::fs::read(opened.path()).expect("read")).expect("json");
        assert_eq!(raw["connections"][0]["group"], "Work");

        for blank in [r#""""#, r#""   ""#, "null"] {
            let root = TempDir::new().expect("tempdir");
            seed(&root, &connections_json(Some(blank)));

            assert_eq!(store(&root).load_blocking().expect(blank)[0].group, None, "{blank}");
        }
    }

    #[test]
    fn a_group_an_earlier_build_wrote_past_the_limits_still_loads() {
        let long = "g".repeat(crate::ConnectionGroupName::MAX_CHARS + 1);
        for (stored, read) in [
            (
                format!(r#""{long}""#),
                "g".repeat(crate::ConnectionGroupName::MAX_CHARS),
            ),
            (String::from(r#""Work\tHome""#), String::from("Work Home")),
        ] {
            let root = TempDir::new().expect("tempdir");
            seed(&root, &connections_json(Some(&stored)));

            let list = store(&root).load_blocking().expect("the list loads");

            assert_eq!(
                list[0].group.as_ref().map(crate::ConnectionGroupName::as_str),
                Some(read.as_str()),
                "{stored}"
            );
        }
    }

    #[test]
    fn an_update_keeps_what_another_writer_changed_meanwhile() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();
        store.upsert_blocking(connection.clone()).expect("upsert");
        store.touch_last_opened_blocking(connection.id).expect("touch");
        let work = crate::ConnectionGroupName::new("Work").expect("a name");

        let updated = store
            .update_blocking(connection.id, |entry| entry.group = Some(work.clone()))
            .expect("update")
            .expect("the entry");

        assert_eq!(updated.group, Some(work));
        assert!(updated.last_opened_at.is_some(), "the update undid the stamp");
        assert_eq!(store.load_blocking().expect("load")[0], updated);
    }

    #[test]
    fn an_update_never_moves_the_entry_to_another_id() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();
        store.upsert_blocking(connection.clone()).expect("upsert");

        let updated = store
            .update_blocking(connection.id, |entry| {
                entry.id = Uuid::new_v4();
                entry.name = "Renamed".to_owned();
            })
            .expect("update")
            .expect("the entry");

        assert_eq!(updated.id, connection.id);
        assert_eq!(store.load_blocking().expect("load")[0].name, "Renamed");
    }

    #[test]
    fn an_update_that_changes_nothing_or_finds_nothing_writes_nothing() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();
        store.upsert_blocking(connection.clone()).expect("upsert");
        let revision = store.snapshot().revision;

        assert_eq!(
            store.update_blocking(connection.id, |_| {}).expect("update"),
            Some(connection)
        );
        assert_eq!(store.update_blocking(Uuid::new_v4(), |_| {}).expect("update"), None);
        assert_eq!(store.snapshot().revision, revision);
    }

    fn tag_name(name: &str) -> ConnectionTagName {
        ConnectionTagName::new(name).expect("a tag name")
    }

    fn tag(name: &str, color: crate::ConnectionColor) -> ConnectionTag {
        ConnectionTag::new(tag_name(name), color)
    }

    fn tagged(name: &str, tags: &[&ConnectionTag]) -> SavedConnection {
        SavedConnection {
            tags: tags.iter().map(|tag| tag.id).collect(),
            ..saved(name)
        }
    }

    fn document(connections: Vec<SavedConnection>, tags: Vec<ConnectionTag>) -> Vec<u8> {
        crate::document::encode_document(&ConnectionsDocument { connections, tags }).expect("encode")
    }

    fn tag_names(store: &ConnectionStore, connection: &SavedConnection) -> Vec<String> {
        let tags = store.tags_blocking().expect("the tags");
        let list = store.load_blocking().expect("the list");
        let held = list
            .iter()
            .find(|saved| saved.name == connection.name)
            .expect("the entry");
        held.tags
            .iter()
            .filter_map(|id| tags.iter().find(|tag| tag.id == *id))
            .map(|tag| tag.name.as_str().to_owned())
            .collect()
    }

    #[test]
    fn tags_are_created_renamed_recoloured_and_deleted() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let production = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        let connection = tagged("acme-prod", &[&production]);
        store.upsert_blocking(connection.clone()).expect("upsert");

        assert!(matches!(
            store.create_tag_blocking(tag_name(" Production "), crate::ConnectionColor::Blue),
            Err(StorageError::TagNameTaken)
        ));
        let renamed = ConnectionTag {
            name: tag_name("prod"),
            color: crate::ConnectionColor::Orange,
            ..production.clone()
        };
        store.update_tag_blocking(renamed.clone()).expect("the rename");
        assert_eq!(store.tags_blocking().expect("tags").to_vec(), vec![renamed]);
        assert_eq!(tag_names(&store, &connection), ["prod"]);

        assert_eq!(
            store.delete_tag_blocking(production.id).expect("delete"),
            RemoveOutcome::Removed
        );
        assert!(store.tags_blocking().expect("tags").is_empty());
        assert!(store.load_blocking().expect("list")[0].tags.is_empty());
        assert_eq!(
            store.delete_tag_blocking(production.id).expect("delete again"),
            RemoveOutcome::NotPresent
        );
        assert!(matches!(
            store.update_tag_blocking(production),
            Err(StorageError::NotFound)
        ));
    }

    #[test]
    fn a_rename_onto_another_tags_name_is_refused_and_a_no_op_writes_nothing() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let production = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        store
            .create_tag_blocking(tag_name("acme"), crate::ConnectionColor::Blue)
            .expect("the tag");
        let revision = store.snapshot().revision;

        let onto = ConnectionTag {
            name: tag_name("ACME"),
            ..production.clone()
        };
        assert!(matches!(
            store.update_tag_blocking(onto),
            Err(StorageError::TagNameTaken)
        ));
        store.update_tag_blocking(production.clone()).expect("unchanged");
        assert_eq!(store.snapshot().revision, revision);
        let recased = ConnectionTag {
            name: tag_name("Production"),
            ..production
        };
        store
            .update_tag_blocking(recased)
            .expect("its own name in another case");
    }

    #[test]
    fn a_connection_keeps_only_tags_the_list_has_once_each() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let production = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        let connection = SavedConnection {
            tags: vec![production.id, Uuid::new_v4(), production.id],
            ..saved("acme-prod")
        };

        store.upsert_blocking(connection.clone()).expect("upsert");
        assert_eq!(store.load_blocking().expect("list")[0].tags, [production.id]);

        let updated = store
            .update_blocking(connection.id, |entry| entry.tags.push(Uuid::new_v4()))
            .expect("update")
            .expect("the entry");
        assert_eq!(updated.tags, [production.id]);
    }

    #[test]
    fn a_hand_edited_file_with_doubled_tags_reads_as_one_tag_each() {
        let root = TempDir::new().expect("tempdir");
        let first = tag("production", crate::ConnectionColor::Red);
        let twin = tag("Production", crate::ConnectionColor::Blue);
        let connection = tagged("acme-prod", &[&twin]);
        seed(
            &root,
            &String::from_utf8(document(
                vec![connection.clone()],
                vec![first.clone(), twin, first.clone()],
            ))
            .expect("utf-8"),
        );
        let store = store(&root);

        assert_eq!(store.tags_blocking().expect("tags").to_vec(), vec![first.clone()]);
        assert_eq!(store.load_blocking().expect("list")[0].tags, [first.id]);
    }

    #[test]
    fn a_tag_with_a_blank_name_makes_the_file_unreadable_rather_than_dropped() {
        let root = TempDir::new().expect("tempdir");
        seed(
            &root,
            r#"{"version": 2, "connections": [], "tags": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"  ","color":"red"}]}"#,
        );

        assert!(matches!(
            store(&root).load_blocking(),
            Err(StorageError::DocumentUnavailable(_))
        ));
    }

    #[test]
    fn a_file_without_tags_or_icons_reads_and_writes_none() {
        let root = TempDir::new().expect("tempdir");
        seed(&root, &connections_json(None));
        let store = store(&root);

        let list = store.load_blocking().expect("load");
        assert!(list[0].tags.is_empty());
        assert_eq!(list[0].icon, None);
        store.upsert_blocking(list[0].clone()).expect("rewrite");
        let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(store.path()).expect("read")).expect("json");
        assert!(raw.get("tags").is_none(), "{raw}");
        assert!(raw["connections"][0].get("tags").is_none(), "{raw}");
        assert!(raw["connections"][0].get("icon").is_none(), "{raw}");
    }

    #[test]
    fn the_snapshot_carries_the_tags() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);

        let production = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");

        let ConnectionListState::Ready(list) = store.snapshot().state else {
            panic!("expected Ready");
        };
        assert_eq!(list.tags.to_vec(), vec![production]);
    }

    /// The issue's "Done means": two tags on a connection survive an
    /// export and an import, and a second import duplicates nothing.
    #[test]
    fn tags_and_the_icon_survive_an_export_and_an_import_twice() {
        let source_root = TempDir::new().expect("tempdir");
        let source = store(&source_root);
        let production = source
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        let acme = source
            .create_tag_blocking(tag_name("acme"), crate::ConnectionColor::Blue)
            .expect("the tag");
        let acme_prod = SavedConnection {
            icon: Some(crate::ConnectionIcon::Shield),
            ..tagged("acme-prod", &[&production, &acme])
        };
        let globex_prod = tagged("globex-prod", &[&production]);
        source.upsert_blocking(acme_prod.clone()).expect("upsert");
        source.upsert_blocking(globex_prod.clone()).expect("upsert");
        let bytes = source.export_blocking().expect("export");

        let target_root = TempDir::new().expect("tempdir");
        let target = store(&target_root);
        let first = target
            .import_blocking(Path::new("/tmp/c.json"), &bytes)
            .expect("import");
        let second = target
            .import_blocking(Path::new("/tmp/c.json"), &bytes)
            .expect("import");

        assert_eq!(first, ImportReport { added: 2, updated: 0 });
        assert_eq!(second, ImportReport { added: 0, updated: 2 });
        let tags = target.tags_blocking().expect("tags");
        assert_eq!(tags.to_vec(), vec![production.clone(), acme.clone()]);
        assert_eq!(tag_names(&target, &acme_prod), ["production", "acme"]);
        assert_eq!(tag_names(&target, &globex_prod), ["production"]);
        let list = target.load_blocking().expect("list");
        assert_eq!(list.len(), 2);
        let held = list.iter().find(|saved| saved.id == acme_prod.id).expect("acme-prod");
        assert_eq!(held.icon, Some(crate::ConnectionIcon::Shield));
    }

    #[test]
    fn an_imported_tag_with_a_name_the_list_has_becomes_that_tag() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        let theirs = tag("PRODUCTION", crate::ConnectionColor::Green);
        let fresh = tag("globex", crate::ConnectionColor::Purple);
        let connection = tagged("globex-prod", &[&theirs, &fresh]);

        store
            .import_blocking(
                Path::new("/tmp/c.json"),
                &document(vec![connection.clone()], vec![theirs, fresh.clone()]),
            )
            .expect("import");

        assert_eq!(
            store.tags_blocking().expect("tags").to_vec(),
            vec![mine.clone(), fresh.clone()]
        );
        assert_eq!(store.load_blocking().expect("list")[0].tags, [mine.id, fresh.id]);
    }

    #[test]
    fn an_imported_tag_with_a_known_id_takes_the_files_name_unless_another_tag_has_it() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let production = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        let staging = store
            .create_tag_blocking(tag_name("staging"), crate::ConnectionColor::Yellow)
            .expect("the tag");
        let connection = tagged("acme", &[&production]);
        let renamed = ConnectionTag {
            name: tag_name("prod"),
            color: crate::ConnectionColor::Orange,
            ..production.clone()
        };
        // Read first, while "production" is still that tag's name.
        let clash = ConnectionTag {
            name: tag_name("PRODUCTION"),
            color: crate::ConnectionColor::Green,
            ..staging.clone()
        };

        store
            .import_blocking(
                Path::new("/tmp/c.json"),
                &document(vec![connection], vec![clash, renamed.clone()]),
            )
            .expect("import");

        let tags = store.tags_blocking().expect("tags");
        assert_eq!(tags.iter().find(|tag| tag.id == production.id), Some(&renamed));
        let kept = tags.iter().find(|tag| tag.id == staging.id).expect("staging");
        assert_eq!(kept.name.as_str(), "staging");
        assert_eq!(kept.color, crate::ConnectionColor::Green);
    }

    #[test]
    fn an_import_updates_the_tags_and_icon_of_an_entry_it_matches() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = saved("production");
        store.upsert_blocking(mine.clone()).expect("upsert");
        let acme = tag("acme", crate::ConnectionColor::Blue);
        let retagged = SavedConnection {
            tags: vec![acme.id, Uuid::new_v4()],
            icon: Some(crate::ConnectionIcon::Cloud),
            ..mine.clone()
        };

        let report = store
            .import_blocking(Path::new("/tmp/c.json"), &document(vec![retagged], vec![acme.clone()]))
            .expect("import");

        assert_eq!(report, ImportReport { added: 0, updated: 1 });
        let list = store.load_blocking().expect("list");
        assert_eq!(list[0].tags, [acme.id], "a tag the file does not list was kept");
        assert_eq!(list[0].icon, Some(crate::ConnectionIcon::Cloud));
    }

    #[test]
    fn a_renamed_tag_and_a_new_one_taking_its_old_name_both_survive_in_any_order() {
        for new_first in [true, false] {
            let root = TempDir::new().expect("tempdir");
            let store = store(&root);
            let mine = store
                .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
                .expect("the tag");
            let renamed = ConnectionTag {
                name: tag_name("staging"),
                ..mine.clone()
            };
            let theirs = tag("production", crate::ConnectionColor::Green);
            let connection = tagged("acme", &[&theirs, &renamed]);
            let tags = if new_first {
                vec![theirs.clone(), renamed.clone()]
            } else {
                vec![renamed.clone(), theirs.clone()]
            };

            store
                .import_blocking(Path::new("/tmp/c.json"), &document(vec![connection.clone()], tags))
                .expect("import");

            assert_eq!(
                tag_names(&store, &connection),
                ["production", "staging"],
                "new tag listed first: {new_first}"
            );
        }
    }

    #[test]
    fn a_file_of_many_doubled_tags_imports_one_of_each() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let tags: Vec<ConnectionTag> = (0..20_000)
            .map(|n| tag(&format!("tag {}", n % 1_000), crate::ConnectionColor::Blue))
            .collect();
        let connection = SavedConnection {
            tags: tags.iter().map(|tag| tag.id).collect(),
            ..saved("everything")
        };

        store
            .import_blocking(Path::new("/tmp/c.json"), &document(vec![connection], tags))
            .expect("import");

        assert_eq!(store.tags_blocking().expect("tags").len(), 1_000);
        assert_eq!(store.load_blocking().expect("list")[0].tags.len(), 1_000);
    }

    #[test]
    fn a_file_of_tags_alone_imports_nothing() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);

        let report = store
            .import_blocking(
                Path::new("/tmp/c.json"),
                &document(Vec::new(), vec![tag("acme", crate::ConnectionColor::Blue)]),
            )
            .expect("import");

        assert_eq!(report, ImportReport::default());
        assert!(store.tags_blocking().expect("tags").is_empty());
    }
}
