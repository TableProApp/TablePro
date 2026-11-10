use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tablepro_core::credentials::SecretKind;
use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, NetworkOptions, SafeModeLevel, TlsConfig};
use tokio::sync::watch;
use uuid::Uuid;

use crate::document_problem::{DocumentProblem, DocumentProblemKind};
use crate::error::StorageError;
use crate::{ConnectionGroup, ConnectionTag, ConnectionTagName, GroupTree};

mod additions;
mod cloud;
mod library;
mod placement;

pub use additions::ImportedConnection;
pub(crate) use placement::cyclic;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedConnection {
    pub id: Uuid,
    /// As [`crate::name_rules::shown`] gives it, so a file cannot bring a
    /// name that looks like a saved one and compares as another.
    #[serde(deserialize_with = "crate::name_rules::deserialize_shown")]
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    /// Required, with no default: guessing a mode for a file that lost it
    /// could silently connect in the clear.
    pub tls: TlsConfig,
    /// Required, with no default: guessing Off for a file that lost it
    /// would drop a guard the user set.
    pub safe_mode: SafeModeLevel,
    /// What MCP clients may do here.
    pub external_access: ExternalAccess,
    /// What the AI assistant may send from here.
    pub ai_policy: AiPolicy,
    /// The editor's query timeout here, in seconds, zero for none. A
    /// connection that never set one leaves it out and follows the one in
    /// Preferences.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query_timeout_secs: Option<u32>,
    #[serde(default)]
    pub auth_mode: AuthMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<SavedSshConfig>,
    // The picker's Recent section reads it; `None` for one never opened.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_opened_at: Option<DateTime<Utc>>,
    /// A colour the user put on this connection to tell production
    /// apart from staging at a glance. `None` until they pick one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<crate::ConnectionColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<Uuid>,
    /// Every write numbers each group's connections from 0 again.
    #[serde(default)]
    pub order: u32,
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
    pub fn connects_like(&self, other: &Self) -> bool {
        let shown_alike = |saved: &Self| Self {
            name: String::new(),
            last_opened_at: None,
            color: None,
            group_id: None,
            order: 0,
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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct ConnectionsDocument {
    connections: Vec<SavedConnection>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    groups: Vec<ConnectionGroup>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tags: Vec<ConnectionTag>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    favorites: Vec<Uuid>,
}

impl ConnectionsDocument {
    /// A tag named twice keeps its first entry and a connection names a
    /// tag at most once, whatever a hand-edited or crafted file says. A
    /// tag whose name another one holds becomes that one, so a connection
    /// keeps the label it showed. Every write passes here, so a name is
    /// stored as the list shows it however it was set.
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
            connection.name = crate::name_rules::shown(&connection.name);
            let mut seen = HashSet::with_capacity(connection.tags.len());
            connection.tags = std::mem::take(&mut connection.tags)
                .iter()
                .filter_map(|id| same.get(id).copied())
                .filter(|id| seen.insert(*id))
                .collect();
        }
        self.tidy_library();
    }

    fn list(&self) -> ConnectionList {
        ConnectionList {
            connections: Arc::from(self.connections.as_slice()),
            groups: Arc::from(self.groups.as_slice()),
            tags: Arc::from(self.tags.as_slice()),
            favorites: Arc::from(self.favorites.as_slice()),
        }
    }
}

impl crate::document::VersionedDocument for ConnectionsDocument {
    const KIND: &'static str = "connections";
    const VERSION: u32 = 1;
}

/// The connections, their groups and tags, and the favourites, as one
/// write left them.
#[derive(Debug, Clone, Default)]
pub struct ConnectionList {
    pub connections: Arc<[SavedConnection]>,
    pub groups: Arc<[ConnectionGroup]>,
    pub tags: Arc<[ConnectionTag]>,
    pub favorites: Arc<[Uuid]>,
}

impl ConnectionList {
    pub fn new(connections: impl Into<Arc<[SavedConnection]>>, tags: impl Into<Arc<[ConnectionTag]>>) -> Self {
        Self {
            connections: connections.into(),
            groups: Arc::from([]),
            tags: tags.into(),
            favorites: Arc::from([]),
        }
    }

    #[must_use]
    pub fn with_groups(self, groups: impl Into<Arc<[ConnectionGroup]>>) -> Self {
        Self {
            groups: groups.into(),
            ..self
        }
    }

    #[must_use]
    pub fn with_favorites(self, favorites: impl Into<Arc<[Uuid]>>) -> Self {
        Self {
            favorites: favorites.into(),
            ..self
        }
    }

    pub fn group_tree(&self) -> GroupTree<'_> {
        GroupTree::new(&self.groups)
    }

    pub fn is_favorite(&self, id: Uuid) -> bool {
        self.favorites.contains(&id)
    }

    pub fn connections_in(&self, group: Option<Uuid>) -> Vec<&SavedConnection> {
        let mut found: Vec<&SavedConnection> = self
            .connections
            .iter()
            .filter(|connection| connection.group_id == group)
            .collect();
        found.sort_by_key(|connection| connection.order);
        found
    }

    /// Favourites are left out, as in the macOS library.
    pub fn recent(&self, limit: usize) -> Vec<&SavedConnection> {
        let mut opened: Vec<&SavedConnection> = self
            .connections
            .iter()
            .filter(|connection| connection.last_opened_at.is_some() && !self.is_favorite(connection.id))
            .collect();
        opened.sort_by(|left, right| {
            right
                .last_opened_at
                .cmp(&left.last_opened_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        opened.truncate(limit);
        opened
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

/// What an import will do, before it is written.
#[derive(Debug, Clone)]
pub struct ImportPreview {
    entries: Vec<ImportEntry>,
    before: ConnectionsDocument,
    after: ConnectionsDocument,
}

impl ImportPreview {
    /// Each connection of the file as it will be saved, in file order.
    pub fn entries(&self) -> &[ImportEntry] {
        &self.entries
    }

    pub fn report(&self) -> ImportReport {
        let added = self
            .entries
            .iter()
            .filter(|entry| entry.change == ImportChange::Added)
            .count();
        ImportReport {
            added,
            updated: self.entries.len() - added,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportEntry {
    pub connection: SavedConnection,
    pub change: ImportChange,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportChange {
    /// A connection the list did not have, including one whose id was
    /// taken by a different connection and was given its own.
    Added,
    /// A connection already in the list that the file only renamed,
    /// recoloured, regrouped, retagged or gave another icon.
    Updated {
        /// The name it had, when the import gives it another.
        renamed_from: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoveOutcome {
    Removed,
    NotPresent,
}

// The file's bytes when the cache was read from it or written to it, `None` for no file.
type FileBytes = Option<Vec<u8>>;

#[derive(Debug)]
enum StoreState {
    Unloaded,
    Ready(ConnectionsDocument, FileBytes),
    // `None` when the file could not be read at all.
    Unavailable(DocumentProblem, Option<FileBytes>),
}

// A write holds the mutex and a lock file from its re-read of the list to its rename, so no writer loses an entry.
#[derive(Clone)]
pub struct ConnectionStore {
    inner: Arc<StoreInner>,
}

struct StoreInner {
    path: PathBuf,
    state: Mutex<StoreState>,
    snapshot: watch::Sender<ConnectionListSnapshot>,
}

struct WriteGuard<'a> {
    state: MutexGuard<'a, StoreState>,
    _file: Option<std::fs::File>,
}

impl Deref for WriteGuard<'_> {
    type Target = StoreState;

    fn deref(&self) -> &StoreState {
        &self.state
    }
}

impl DerefMut for WriteGuard<'_> {
    fn deref_mut(&mut self) -> &mut StoreState {
        &mut self.state
    }
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

    /// A new entry, or one that changed group, goes last in its group.
    pub fn upsert_blocking(&self, connection: SavedConnection) -> Result<(), StorageError> {
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
        let mut connection = connection;
        let stored = document
            .connections
            .iter()
            .find(|saved| saved.id == connection.id)
            .map(|saved| (saved.group_id, saved.order));
        document.settle_place(&mut connection, stored);
        document.connections.retain(|saved| saved.id != connection.id);
        document.connections.push(connection);
        self.commit(&mut state, document)
    }

    // One write, so no publish shows a copy at the end of its group before it moves up.
    pub fn insert_after_blocking(&self, connection: SavedConnection, after: Uuid) -> Result<(), StorageError> {
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
        let mut connection = connection;
        let stored = document
            .connections
            .iter()
            .find(|saved| saved.id == connection.id)
            .map(|saved| (saved.group_id, saved.order));
        document.connections.retain(|saved| saved.id != connection.id);
        let anchor = document
            .connections
            .iter()
            .find(|saved| saved.id == after)
            .map(|saved| (saved.group_id, saved.order));
        match anchor {
            Some((group, order)) => {
                for later in document
                    .connections
                    .iter_mut()
                    .filter(|saved| saved.group_id == group && saved.order > order)
                {
                    later.order = later.order.saturating_add(1);
                }
                connection.group_id = group;
                connection.order = order.saturating_add(1);
            }
            None => document.settle_place(&mut connection, stored),
        }
        document.connections.push(connection);
        self.commit(&mut state, document)
    }

    pub fn remove_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
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
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
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
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
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
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
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
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
        let Some(index) = document.connections.iter().position(|saved| saved.id == id) else {
            return Ok(None);
        };
        let before = document.connections[index].clone();
        let mut changed = before.clone();
        change(&mut changed);
        // The keyring files the entry's secrets under its id.
        changed.id = id;
        let kept = Some((before.group_id, changed.order));
        document.settle_place(&mut changed, kept);
        document.connections[index] = changed;
        document.tidy();
        let updated = document.connections[index].clone();
        if updated != before {
            self.commit(&mut state, document)?;
        }
        Ok(Some(updated))
    }

    // For the picker's Recent section. A connection opened without saving has no entry, so nothing is written.
    pub fn touch_last_opened_blocking(&self, id: Uuid) -> Result<(), StorageError> {
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
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

    /// Merge an exported document back into the list, as
    /// [`Self::preview_import_blocking`] and [`Self::apply_import_blocking`]
    /// do it in two steps.
    pub fn import_blocking(&self, path: &Path, bytes: &[u8]) -> Result<ImportReport, StorageError> {
        let preview = self.preview_import_blocking(path, bytes)?;
        self.apply_import_blocking(&preview)
    }

    /// What merging an exported document would do to the list, worked
    /// out without writing anything, so the user can see every host and
    /// setting the file brings before it is saved.
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
    /// An imported entry never takes a name another entry holds or held
    /// when the import began, whatever order the file lists them in, and
    /// an added one never takes the file's last-opened time, so a file
    /// cannot pass one host off as another saved connection or sort it
    /// above one. An updated entry whose name the file keeps keeps it,
    /// even when another entry has the same one.
    ///
    /// Tags are matched by id first and then by name, so importing a
    /// file twice, or a file from a machine whose `production` tag has
    /// another id, leaves one tag of each name. Groups are matched by id,
    /// then by the same name in the same place, the same way.
    pub fn preview_import_blocking(&self, path: &Path, bytes: &[u8]) -> Result<ImportPreview, StorageError> {
        let mut incoming = crate::document::decode_document::<ConnectionsDocument>(path, bytes)
            .map_err(StorageError::DocumentUnavailable)?;
        incoming.tidy();
        let mut state = self.lock();
        let before = self.ensure_loaded(&mut state)?;
        let mut document = before.clone();
        let held: HashMap<String, Uuid> = document
            .connections
            .iter()
            .map(|saved| (saved.name.clone(), saved.id))
            .collect();
        let mut entries = Vec::with_capacity(incoming.connections.len());
        let same_tags = merge_tags(&mut document.tags, incoming.tags);
        let same_groups = library::merge_groups(&mut document.groups, &incoming.groups);
        let mut landed: HashMap<Uuid, Uuid> = HashMap::with_capacity(incoming.connections.len());
        // Added entries follow the list's own and keep the file's order.
        let mut after: HashMap<Option<Uuid>, u32> = HashMap::new();
        for mut connection in incoming.connections {
            let from = connection.id;
            connection.tags = connection
                .tags
                .iter()
                .filter_map(|id| same_tags.get(id).copied())
                .collect();
            connection.group_id = connection.group_id.and_then(|id| same_groups.get(&id).copied());
            let last = *after
                .entry(connection.group_id)
                .or_insert_with(|| placement::next_order(&document.connections, connection.group_id));
            connection.order = connection.order.saturating_add(last);
            let entry = merge_connection(&mut document.connections, &held, connection);
            landed.insert(from, entry.connection.id);
            entries.push(entry);
        }
        // Added and never taken away: a file that lists none must not
        // clear the user's.
        let mut favorites: HashSet<Uuid> = document.favorites.iter().copied().collect();
        for id in incoming.favorites.iter().filter_map(|id| landed.get(id)) {
            if favorites.insert(*id) {
                document.favorites.push(*id);
            }
        }
        Ok(ImportPreview {
            entries,
            before,
            after: document,
        })
    }

    /// Write what a preview showed. A list that changed since then is
    /// refused, since the user agreed to that preview and not another.
    pub fn apply_import_blocking(&self, preview: &ImportPreview) -> Result<ImportReport, StorageError> {
        let report = preview.report();
        let mut state = self.lock_to_write();
        let current = self.ensure_current(&mut state)?;
        if current != preview.before {
            return Err(StorageError::ImportOutdated);
        }
        // Nothing to write for an empty file, and writing anyway would
        // rewrite the list for no reason.
        if report.total() == 0 {
            return Ok(report);
        }
        self.commit(&mut state, preview.after.clone())?;
        Ok(report)
    }

    // Returns the name the unreadable file was moved to. Another process may have reset or rewritten it since.
    pub fn reset_unreadable_blocking(&self, now: std::time::SystemTime) -> Result<PathBuf, StorageError> {
        let mut state = self.lock_to_write();
        match self.ensure_current(&mut state) {
            Err(StorageError::DocumentUnavailable(_)) => {}
            Ok(_) => {
                return Err(StorageError::Schema(
                    "the saved connections are readable; there is nothing to reset".to_owned(),
                ));
            }
            Err(error) => return Err(error),
        }
        let moved = crate::fs::move_aside_blocking(&self.inner.path, now)?;
        *state = StoreState::Ready(ConnectionsDocument::default(), None);
        self.publish(&state);
        Ok(moved)
    }

    fn lock(&self) -> MutexGuard<'_, StoreState> {
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

    fn lock_to_write(&self) -> WriteGuard<'_> {
        let state = self.lock();
        let file = crate::fs::lock_beside_blocking(&self.inner.path);
        WriteGuard { state, _file: file }
    }

    fn ensure_loaded(&self, state: &mut StoreState) -> Result<ConnectionsDocument, StorageError> {
        self.refresh(state, false)
    }

    fn ensure_current(&self, state: &mut WriteGuard<'_>) -> Result<ConnectionsDocument, StorageError> {
        self.refresh(state, true)
    }

    // A file that cannot be read keeps the list for a read and refuses a write, which would land over unseen bytes.
    fn refresh(&self, state: &mut StoreState, writing: bool) -> Result<ConnectionsDocument, StorageError> {
        let path = self.inner.path.as_path();
        match read_bytes(path) {
            Ok(found) => {
                let unchanged = match &*state {
                    StoreState::Ready(_, seen) | StoreState::Unavailable(_, Some(seen)) => *seen == found,
                    StoreState::Unloaded | StoreState::Unavailable(_, None) => false,
                };
                if !unchanged {
                    let decoded = decode(path, found.as_deref());
                    *state = match decoded {
                        Ok(document) => StoreState::Ready(document, found),
                        Err(problem) => StoreState::Unavailable(problem, Some(found)),
                    };
                    self.publish(state);
                }
            }
            Err(source) => {
                if let StoreState::Ready(document, _) = &*state {
                    if writing {
                        return Err(StorageError::Io {
                            path: path.to_owned(),
                            source,
                        });
                    }
                    return Ok(document.clone());
                }
                let problem = DocumentProblem::new(
                    path,
                    DocumentProblemKind::Unreadable {
                        detail: source.to_string(),
                    },
                );
                if !matches!(&*state, StoreState::Unavailable(held, None) if *held == problem) {
                    *state = StoreState::Unavailable(problem, None);
                    self.publish(state);
                }
            }
        }
        match state {
            StoreState::Ready(document, _) => Ok(document.clone()),
            StoreState::Unavailable(problem, _) => Err(StorageError::DocumentUnavailable(problem.clone())),
            StoreState::Unloaded => unreachable!("just loaded"),
        }
    }

    // A change that changes nothing writes nothing.
    fn edit<T>(
        &self,
        change: impl FnOnce(&mut ConnectionsDocument) -> Result<T, StorageError>,
    ) -> Result<T, StorageError> {
        let mut state = self.lock_to_write();
        let before = self.ensure_current(&mut state)?;
        let mut document = before.clone();
        let outcome = change(&mut document)?;
        document.tidy();
        if document != before {
            self.commit(&mut state, document)?;
        }
        Ok(outcome)
    }

    // Write first, then adopt, so a failed write leaves the file and the cache as they were.
    fn commit(&self, state: &mut WriteGuard<'_>, mut document: ConnectionsDocument) -> Result<(), StorageError> {
        // A connection saved with a tag deleted meanwhile drops it here.
        document.tidy();
        let bytes = crate::document::encode_document(&document)?;
        crate::upgrade_copies::keep_before_write_blocking::<ConnectionsDocument>(&self.inner.path)?;
        // Before the list itself, so a deleted connection is never gone from the list but kept in a
        // copy, and a failed trim leaves both as they were for the next write to try again.
        let kept = document.connections.iter().map(|saved| saved.id.to_string()).collect();
        crate::upgrade_copies::trim_connection_copies_blocking(&self.inner.path, &kept)?;
        crate::fs::write_private_blocking(&self.inner.path, &bytes)?;
        **state = StoreState::Ready(document, Some(bytes));
        self.publish(state);
        Ok(())
    }

    fn publish(&self, state: &StoreState) {
        let next = match state {
            StoreState::Unloaded => ConnectionListState::Loading,
            StoreState::Ready(document, _) => ConnectionListState::Ready(document.list()),
            StoreState::Unavailable(problem, _) => ConnectionListState::Unavailable(Arc::new(problem.clone())),
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

fn read_bytes(path: &Path) -> std::io::Result<FileBytes> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

// No file is an empty list, not a problem: a first run has none.
fn decode(path: &Path, bytes: Option<&[u8]>) -> Result<ConnectionsDocument, DocumentProblem> {
    let Some(bytes) = bytes.filter(|bytes| !bytes.iter().all(u8::is_ascii_whitespace)) else {
        return Ok(ConnectionsDocument::default());
    };
    let mut document = crate::document::decode_document::<ConnectionsDocument>(path, bytes)?;
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

/// An updated entry keeps its place unless it changed group.
fn merge_connection(
    list: &mut Vec<SavedConnection>,
    held: &HashMap<String, Uuid>,
    mut connection: SavedConnection,
) -> ImportEntry {
    match list.iter().position(|saved| saved.id == connection.id) {
        Some(index) if list[index].connects_like(&connection) => {
            // Two connections saved without a name to one server share
            // one, and re-importing their export must rename neither.
            let name = if connection.name == list[index].name {
                connection.name
            } else {
                unclaimed_name(list, held, &connection.name, Some(connection.id))
            };
            let order = if list[index].group_id == connection.group_id {
                list[index].order
            } else {
                placement::next_order(list, connection.group_id)
            };
            let existing = &mut list[index];
            let before = std::mem::replace(&mut existing.name, name);
            existing.color = connection.color;
            existing.group_id = connection.group_id;
            existing.order = order;
            existing.tags = connection.tags;
            existing.icon = connection.icon;
            let renamed_from = (existing.name != before).then_some(before);
            ImportEntry {
                connection: existing.clone(),
                change: ImportChange::Updated { renamed_from },
            }
        }
        Some(_) => {
            connection.id = Uuid::new_v4();
            ImportEntry {
                connection: add_imported(list, held, connection),
                change: ImportChange::Added,
            }
        }
        None => ImportEntry {
            connection: add_imported(list, held, connection),
            change: ImportChange::Added,
        },
    }
}

/// Add an entry the import brought. Two rows of one name, one of them
/// pointing somewhere else, would leave the user guessing which is
/// theirs, and a file's last-opened time is no open on this machine.
fn add_imported(
    list: &mut Vec<SavedConnection>,
    held: &HashMap<String, Uuid>,
    mut connection: SavedConnection,
) -> SavedConnection {
    connection.name = unclaimed_name(list, held, &connection.name, None);
    connection.last_opened_at = None;
    list.push(connection.clone());
    connection
}

/// `name`, or a suffixed one when an entry other than `owner` holds it.
fn unclaimed_name(list: &[SavedConnection], held: &HashMap<String, Uuid>, name: &str, owner: Option<Uuid>) -> String {
    let taken: Vec<&str> = list
        .iter()
        .map(|saved| (saved.name.as_str(), saved.id))
        .chain(held.iter().map(|(name, id)| (name.as_str(), *id)))
        .filter(|(_, id)| Some(*id) != owner)
        .map(|(name, _)| name)
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
            query_timeout_secs: None,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: Some(Utc::now()),
            color: None,
            group_id: None,
            order: 0,
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
            query_timeout_secs: None,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group_id: None,
            order: 0,
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
        let path = seed(&root, r#"{"version": 4, "connections": []}"#);
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
        seed(&root, &connections_json(r#","auth_mode":"from_the_future""#));

        let refused = store(&root).load_blocking();

        // Silently treating this as an empty list would lose every saved
        // connection the moment a newer auth mode appears.
        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
    }

    #[test]
    fn an_entry_without_a_level_a_policy_or_an_access_level_is_refused() {
        for (field, value) in [
            ("safe_mode", r#""off""#),
            ("external_access", r#""read_only""#),
            ("ai_policy", r#""ask""#),
        ] {
            let root = TempDir::new().expect("tempdir");
            let full = connections_json("");
            let without = full.replace(&format!(r#","{field}":{value}"#), "");
            assert_ne!(without, full, "{field}");
            seed(&root, &without);

            let refused = store(&root).load_blocking();

            // Guessing would drop a guard the user set.
            assert!(
                matches!(refused, Err(StorageError::DocumentUnavailable(_))),
                "{field}: {refused:?}"
            );
        }
    }

    #[test]
    fn saved_connection_requires_tls_field() {
        let root = TempDir::new().expect("tempdir");
        let full = connections_json("");
        let without = full.replace(r#","tls":{"mode":"disable"}"#, "");
        assert_ne!(without, full);
        seed(&root, &without);

        let refused = store(&root).load_blocking();

        // A guessed mode could connect in the clear.
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

    // Two stores on one root stand for two app processes.
    #[test]
    fn a_connect_keeps_a_connection_another_process_saved_after_this_one_read_the_list() {
        let root = TempDir::new().expect("tempdir");
        let mine = store(&root);
        let theirs = store(&root);
        let opened = sample_connection();
        mine.upsert_blocking(opened.clone()).expect("upsert");
        let added = SavedConnection {
            name: "Added elsewhere".to_owned(),
            ..sample_connection()
        };
        theirs.upsert_blocking(added.clone()).expect("their save");

        mine.touch_last_opened_blocking(opened.id).expect("touch");

        let saved = store(&root).load_blocking().expect("load");
        assert!(
            saved.iter().any(|connection| connection.id == added.id),
            "the connect wrote over the other process's save"
        );
        let ConnectionListState::Ready(list) = mine.snapshot().state else {
            panic!("expected Ready");
        };
        assert_eq!(list.connections.len(), 2, "the list read again was not published");
    }

    #[test]
    fn two_stores_on_one_file_writing_at_once_lose_nothing() {
        let root = TempDir::new().expect("tempdir");
        let stores = [store(&root), store(&root)];

        let handles: Vec<_> = (0..16)
            .map(|index| {
                let store = stores[index % 2].clone();
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

        assert_eq!(
            store(&root).load_blocking().expect("load").len(),
            16,
            "one store's write went over the other's"
        );
    }

    #[test]
    fn a_save_goes_ahead_when_the_lock_file_cannot_be_opened() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mut lock = store.path().as_os_str().to_owned();
        lock.push(".lock");
        std::fs::create_dir_all(PathBuf::from(lock)).expect("a directory in its place");

        store.upsert_blocking(sample_connection()).expect("the save");

        assert_eq!(store.load_blocking().expect("load").len(), 1);
    }

    #[test]
    fn a_file_broken_by_hand_after_the_list_was_read_is_never_written_over() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(sample_connection()).expect("upsert");
        std::fs::write(store.path(), b"{ half an edit").expect("the hand edit");

        let refused = store.upsert_blocking(sample_connection());

        assert!(
            matches!(refused, Err(StorageError::DocumentUnavailable(_))),
            "{refused:?}"
        );
        assert_eq!(std::fs::read(store.path()).expect("read"), b"{ half an edit");
        assert!(matches!(store.snapshot().state, ConnectionListState::Unavailable(_)));
    }

    #[test]
    fn a_list_that_cannot_be_read_again_still_shows_and_refuses_writes() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(sample_connection()).expect("upsert");
        let revision = store.snapshot().revision;
        std::fs::remove_file(store.path()).expect("remove");
        std::fs::create_dir(store.path()).expect("a directory in its place");

        assert_eq!(store.load_blocking().expect("the list read before").len(), 1);
        let refused = store.upsert_blocking(sample_connection());

        assert!(matches!(refused, Err(StorageError::Io { .. })), "{refused:?}");
        assert_eq!(store.snapshot().revision, revision);
    }

    #[test]
    fn a_reset_another_process_already_made_moves_nothing_aside() {
        let root = TempDir::new().expect("tempdir");
        seed(&root, "not json at all");
        let mine = store(&root);
        let theirs = store(&root);
        mine.load_blocking().expect_err("unavailable");
        theirs
            .reset_unreadable_blocking(std::time::SystemTime::now())
            .expect("their reset");
        theirs.upsert_blocking(sample_connection()).expect("their save");

        let refused = mine.reset_unreadable_blocking(std::time::SystemTime::now());

        assert!(refused.is_err(), "{refused:?}");
        assert_eq!(mine.load_blocking().expect("the list").len(), 1);
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
        // A new entry goes last in its group.
        let minimal = SavedConnection { order: 1, ..minimal };
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
        assert!(text.contains("\"version\": 1"), "{text}");
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
                    order: crafted.order,
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
    fn a_rename_in_the_file_does_not_free_the_name_for_an_added_entry() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = saved("production");
        store.upsert_blocking(mine.clone()).expect("upsert");
        let renamed = SavedConnection {
            name: "staging".to_owned(),
            ..mine.clone()
        };
        let lookalike = SavedConnection {
            host: "db.attacker.example".to_owned(),
            ..saved("production")
        };
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: vec![renamed, lookalike.clone()],
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(report, ImportReport { added: 1, updated: 1 });
        let list = store.load_blocking().expect("load");
        let kept = list.iter().find(|saved| saved.id == mine.id).expect("the saved entry");
        assert_eq!(kept.name, "staging");
        let added = list.iter().find(|saved| saved.id == lookalike.id).expect("the import");
        assert_eq!(added.name, "production (imported)");
    }

    #[test]
    fn a_rename_in_the_file_does_not_free_the_name_for_another_saved_entry() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let production = saved("production");
        let staging = SavedConnection {
            host: "staging.internal".to_owned(),
            ..saved("staging")
        };
        store.upsert_blocking(production.clone()).expect("upsert");
        store.upsert_blocking(staging.clone()).expect("upsert");
        let swapped = vec![
            SavedConnection {
                name: "staging".to_owned(),
                ..production.clone()
            },
            SavedConnection {
                name: "production".to_owned(),
                ..staging.clone()
            },
        ];
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: swapped,
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(report, ImportReport { added: 0, updated: 2 });
        let list = store.load_blocking().expect("load");
        let first = list.iter().find(|saved| saved.id == production.id).expect("production");
        assert_eq!(first.name, "staging (imported)");
        let second = list.iter().find(|saved| saved.id == staging.id).expect("staging");
        assert_eq!(second.name, "production (imported)");
    }

    #[test]
    fn a_rename_in_the_file_does_not_free_the_name_for_an_entry_under_the_same_id() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = saved("production");
        store.upsert_blocking(mine.clone()).expect("upsert");
        let renamed = SavedConnection {
            name: "staging".to_owned(),
            ..mine.clone()
        };
        let elsewhere = SavedConnection {
            host: "db.other.example".to_owned(),
            ..mine.clone()
        };
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: vec![renamed, elsewhere],
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let report = store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

        assert_eq!(report, ImportReport { added: 1, updated: 1 });
        let list = store.load_blocking().expect("load");
        let kept = list.iter().find(|saved| saved.id == mine.id).expect("the saved entry");
        assert_eq!(kept.name, "staging");
        assert_eq!(kept.host, "db.internal");
        let added = list.iter().find(|saved| saved.id != mine.id).expect("the import");
        assert_eq!(added.name, "production (imported)");
        assert_eq!(added.host, "db.other.example");
    }

    #[test]
    fn an_unchanged_reimport_keeps_names_two_entries_share() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(saved("postgres@localhost")).expect("upsert");
        let reports = SavedConnection {
            database: "reports".to_owned(),
            ..saved("postgres@localhost")
        };
        store.upsert_blocking(reports).expect("upsert");
        let bytes = store.export_blocking().expect("export");

        let preview = store
            .preview_import_blocking(Path::new("/tmp/c.json"), &bytes)
            .expect("preview");

        for entry in preview.entries() {
            assert_eq!(entry.change, ImportChange::Updated { renamed_from: None });
        }
        assert_eq!(
            store.apply_import_blocking(&preview).expect("apply"),
            ImportReport { added: 0, updated: 2 }
        );
        let names: Vec<String> = store
            .load_blocking()
            .expect("load")
            .iter()
            .map(|saved| saved.name.clone())
            .collect();
        assert_eq!(names, ["postgres@localhost", "postgres@localhost"]);
    }

    #[test]
    fn a_preview_names_what_an_updated_entry_was_called() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let production = saved("production");
        let staging = saved("staging");
        store.upsert_blocking(production.clone()).expect("upsert");
        store.upsert_blocking(staging.clone()).expect("upsert");
        let renamed = SavedConnection {
            name: "reporting".to_owned(),
            ..production
        };
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: vec![renamed, staging],
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let preview = store
            .preview_import_blocking(Path::new("/tmp/c.json"), &bytes)
            .expect("preview");

        let changes: Vec<ImportChange> = preview.entries().iter().map(|entry| entry.change.clone()).collect();
        assert_eq!(
            changes,
            [
                ImportChange::Updated {
                    renamed_from: Some("production".to_owned())
                },
                ImportChange::Updated { renamed_from: None },
            ]
        );
        assert_eq!(preview.entries()[0].connection.name, "reporting");
    }

    #[test]
    fn a_name_that_only_looks_like_a_saved_one_is_suffixed() {
        for (mine, lookalike) in [
            ("production", "production "),
            ("production", " production"),
            ("production", "production\u{a0}"),
            ("production", "produ\u{200b}ction"),
            ("production", "\u{feff}production"),
            ("production", "production\u{2060}"),
            ("staging db", "staging\u{a0}db"),
            ("staging db", "staging\u{2007}db"),
            ("Caf\u{e9} prod", "Cafe\u{301} prod"),
        ] {
            let root = TempDir::new().expect("tempdir");
            let store = store(&root);
            store.upsert_blocking(saved(mine)).expect("upsert");
            let imported = SavedConnection {
                host: "db.attacker.example".to_owned(),
                ..saved(lookalike)
            };
            let bytes = crate::document::encode_document(&ConnectionsDocument {
                connections: vec![imported.clone()],
                ..ConnectionsDocument::default()
            })
            .expect("encode");

            store.import_blocking(Path::new("/tmp/c.json"), &bytes).expect("import");

            let list = store.load_blocking().expect("load");
            let added = list.iter().find(|saved| saved.id == imported.id).expect("the import");
            assert_eq!(added.name, format!("{mine} (imported)"), "{lookalike:?}");
        }
    }

    #[test]
    fn a_rename_is_stored_as_the_list_shows_it() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = saved("staging");
        store.upsert_blocking(mine.clone()).expect("upsert");

        let updated = store
            .update_blocking(mine.id, |saved| saved.name = "pro\u{200b}duction ".to_owned())
            .expect("update")
            .expect("the entry");

        assert_eq!(updated.name, "production");
        let list = store.load_blocking().expect("load");
        assert_eq!(list[0].name, "production");
    }

    #[test]
    fn a_preview_writes_nothing_and_is_refused_once_the_list_changed() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        store.upsert_blocking(saved("mine")).expect("upsert");
        let theirs = SavedConnection {
            host: "db.elsewhere.example".to_owned(),
            ..saved("theirs")
        };
        let bytes = crate::document::encode_document(&ConnectionsDocument {
            connections: vec![theirs.clone()],
            ..ConnectionsDocument::default()
        })
        .expect("encode");

        let preview = store
            .preview_import_blocking(Path::new("/tmp/c.json"), &bytes)
            .expect("preview");

        assert_eq!(preview.entries().len(), 1);
        assert_eq!(preview.entries()[0].change, ImportChange::Added);
        assert_eq!(preview.entries()[0].connection.host, "db.elsewhere.example");
        assert_eq!(store.load_blocking().expect("load").len(), 1);

        store.upsert_blocking(saved("another")).expect("upsert");
        assert!(matches!(
            store.apply_import_blocking(&preview),
            Err(StorageError::ImportOutdated)
        ));

        let fresh = store
            .preview_import_blocking(Path::new("/tmp/c.json"), &bytes)
            .expect("preview");
        assert_eq!(
            store.apply_import_blocking(&fresh).expect("apply"),
            ImportReport { added: 1, updated: 0 }
        );
        assert_eq!(store.load_blocking().expect("load").len(), 3);
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

    /// One complete entry, with `extra` added to it and `rest` after the
    /// connections, as the store writes them.
    fn connections_document(extra: &str, rest: &str) -> String {
        format!(
            r#"{{"version": 1, "connections": [{{"id":"550e8400-e29b-41d4-a716-446655440000","name":"n","driver_id":"postgres","host":"h","port":5432,"database":"d","username":"u","tls":{{"mode":"disable"}},"safe_mode":"off","external_access":"read_only","ai_policy":"ask"{extra}}}]{rest}}}"#
        )
    }

    fn connections_json(extra: &str) -> String {
        connections_document(extra, "")
    }

    /// The label of the group `store`'s first connection sits in.
    fn first_group(store: &ConnectionStore) -> Option<String> {
        let list = store.list_blocking().expect("the list");
        let group = list.connections[0].group_id?;
        list.group_tree().label(group)
    }

    #[test]
    fn a_long_group_loads_whole_and_control_characters_are_cleaned() {
        let long = "g".repeat(200);
        let group = "6a1f0c2e-3b4d-4e5f-8a9b-0c1d2e3f4a5b";
        for (stored, read) in [
            (format!(r#""{long}""#), long.clone()),
            (String::from(r#""Work\tHome""#), String::from("Work Home")),
        ] {
            let root = TempDir::new().expect("tempdir");
            seed(
                &root,
                &connections_document(
                    &format!(r#","group_id":"{group}""#),
                    &format!(r#", "groups": [{{"id":"{group}","name":{stored}}}]"#),
                ),
            );

            assert_eq!(first_group(&store(&root)).as_deref(), Some(read.as_str()), "{stored}");
        }
    }

    #[test]
    fn an_update_keeps_what_another_writer_changed_meanwhile() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let connection = sample_connection();
        store.upsert_blocking(connection.clone()).expect("upsert");
        store.touch_last_opened_blocking(connection.id).expect("touch");
        let work = store
            .create_group_blocking(crate::ConnectionGroup::new(
                crate::ConnectionGroupName::new("Work").expect("a name"),
                None,
            ))
            .expect("the group");

        let updated = store
            .update_blocking(connection.id, |entry| entry.group_id = Some(work.id))
            .expect("update")
            .expect("the entry");

        assert_eq!(updated.group_id, Some(work.id));
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
        crate::document::encode_document(&ConnectionsDocument {
            connections,
            tags,
            ..ConnectionsDocument::default()
        })
        .expect("encode")
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
            r#"{"version": 1, "connections": [], "tags": [{"id":"550e8400-e29b-41d4-a716-446655440000","name":"  ","color":"red"}]}"#,
        );

        assert!(matches!(
            store(&root).load_blocking(),
            Err(StorageError::DocumentUnavailable(_))
        ));
    }

    #[test]
    fn a_file_without_tags_or_icons_reads_and_writes_none() {
        let root = TempDir::new().expect("tempdir");
        seed(&root, &connections_json(""));
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
    fn an_imported_tag_that_only_looks_like_one_the_list_has_becomes_that_tag() {
        let root = TempDir::new().expect("tempdir");
        let store = store(&root);
        let mine = store
            .create_tag_blocking(tag_name("production"), crate::ConnectionColor::Red)
            .expect("the tag");
        let theirs = tag("lookalike", crate::ConnectionColor::Green);
        let connection = tagged("globex-prod", &[&theirs]);
        let file = String::from_utf8(document(vec![connection], vec![theirs]))
            .expect("utf-8")
            .replace("lookalike", "production\u{200b}");

        store
            .import_blocking(Path::new("/tmp/c.json"), file.as_bytes())
            .expect("import");

        assert_eq!(store.tags_blocking().expect("tags").to_vec(), vec![mine.clone()]);
        assert_eq!(store.load_blocking().expect("list")[0].tags, [mine.id]);
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
