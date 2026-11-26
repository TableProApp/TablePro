use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::document::VersionedDocument;
use crate::error::StorageError;
use crate::journal::{ChangeJournal, JournalEntry, JournalSlot, RecordKind, RecordRef};
use crate::paths::StoragePaths;
use crate::store_identity::StoreIdentity;

#[cfg(test)]
mod tests;

// The account a Team Library store belongs to: the server's API origin and the account id on it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TeamLibraryOwner {
    pub origin: String,
    pub account_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TeamLibraryKind {
    Connection,
    Folder,
    Query,
}

impl TeamLibraryKind {
    pub fn record_kind(self) -> RecordKind {
        match self {
            Self::Connection => RecordKind::LibraryConnection,
            Self::Folder => RecordKind::LibraryFolder,
            Self::Query => RecordKind::LibraryQuery,
        }
    }
}

// One shared item as this device holds it. `id` is the client id the team stores, byte for byte and in its case (core
// ADR 0052, Team scope), and `fields` the item's JSON object in the bundle's schema, which this store does not read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLibraryItem {
    pub kind: TeamLibraryKind,
    pub id: String,
    pub fields: Value,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLibraryTeam {
    pub team_id: String,
    #[serde(default)]
    pub items: Vec<TeamLibraryItem>,
}

// An item by its kind and the id the team stores. Shipped Macs match ids without case, so a ref does too.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TeamLibraryRef {
    pub kind: TeamLibraryKind,
    pub id: String,
}

impl TeamLibraryRef {
    pub fn names(&self, kind: TeamLibraryKind, id: &str) -> bool {
        self.kind == kind && self.id.to_lowercase() == id.to_lowercase()
    }
}

// An item's fields as this device wrote or turned them down.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLibraryCopy {
    pub kind: TeamLibraryKind,
    pub id: String,
    pub fields: Value,
}

// An edit the library 0.88 kept, against the facade's version it was made on, until the team's first pull.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLibraryImported {
    pub kind: TeamLibraryKind,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_fields: Option<Value>,
    // None deletes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Option<Value>,
    #[serde(default)]
    pub moved: bool,
    // Why the team cannot take it, listed until it is discarded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refused: Option<String>,
}

// Who last wrote an item the team holds and when, as the server named them to this account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLibraryWriter {
    pub kind: TeamLibraryKind,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub at_ms: i64,
}

// What only this device knows of a team, never synced: the team's name for an offline launch, its last pull, the items
// this device put there (so a later publish removes only those), the copies a publish wrote that the team has not
// taken yet, the copies Keep Theirs turned down, 0.88's edits still to apply, and who last wrote each item.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLibraryLocal {
    pub team_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub synced_at_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub published: Vec<TeamLibraryRef>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub claims: Vec<TeamLibraryCopy>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub declined: Vec<TeamLibraryCopy>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub imports: Vec<TeamLibraryImported>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub writers: Vec<TeamLibraryWriter>,
}

impl TeamLibraryLocal {
    fn holds_nothing(&self) -> bool {
        *self
            == Self {
                team_id: self.team_id.clone(),
                ..Self::default()
            }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TeamLibraryDocument {
    owner: TeamLibraryOwner,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    store: Option<StoreIdentity>,
    #[serde(default)]
    teams: Vec<TeamLibraryTeam>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    local: Vec<TeamLibraryLocal>,
}

impl VersionedDocument for TeamLibraryDocument {
    const KIND: &'static str = "team_library";
    const VERSION: u32 = 1;
}

// The Team Library items one account holds on this device, one file per (origin, account), so no item of one account
// is ever read for another (core ADR 0054, The state file, for the same rule). The file's name is a digest of the
// owner, so an id a server chose never names a path, and the owner is kept inside it: a file bound to another owner is
// refused. A write holds a lock file from its re-read to its rename, as the connection list does. A delete marks the
// owner first, and nothing reads the owner's file while the mark stands, so a delete cut off fails closed.
#[derive(Clone)]
pub struct TeamLibraryStore {
    inner: Arc<Inner>,
}

struct Inner {
    path: PathBuf,
    owner: TeamLibraryOwner,
    lock: Mutex<()>,
    journal: JournalSlot,
}

impl TeamLibraryStore {
    pub fn new(paths: &StoragePaths, owner: TeamLibraryOwner) -> Self {
        Self {
            inner: Arc::new(Inner {
                path: Self::path_for(paths, &owner),
                owner,
                lock: Mutex::new(()),
                journal: JournalSlot::default(),
            }),
        }
    }

    pub fn path_for(paths: &StoragePaths, owner: &TeamLibraryOwner) -> PathBuf {
        let mut digest = Sha256::new();
        for part in [
            "tablepro/v1/team-library",
            owner.origin.as_str(),
            owner.account_id.as_str(),
        ] {
            digest.update(u32::try_from(part.len()).unwrap_or(u32::MAX).to_be_bytes());
            digest.update(part.as_bytes());
        }
        paths
            .state
            .join("team-library")
            .join(format!("{}.json", hex::encode(digest.finalize())))
    }

    pub fn path(&self) -> &Path {
        &self.inner.path
    }

    pub fn owner(&self) -> &TeamLibraryOwner {
        &self.inner.owner
    }

    pub fn set_journal(&self, journal: Option<Arc<dyn ChangeJournal>>) {
        self.inner.journal.set(journal);
    }

    // Beside the file and named after it, so it outlives the file it marks. The owner's marker is a cleanup's, which any
    // of the owner's state databases finishes; each database's own marker says what its delete still owes.
    fn marker(&self) -> PathBuf {
        marker_for(&self.inner.path)
    }

    fn database_marker(&self, database: &str) -> Result<PathBuf, StorageError> {
        if database.is_empty() || !database.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
            return Err(StorageError::Schema(
                "a state database is named by letters and digits".to_owned(),
            ));
        }
        Ok(self.inner.path.with_extension(format!("{database}.{DELETING}")))
    }

    // Every database's marker of this owner, with what it still owes. One that cannot be read owes the store too.
    fn database_markers(&self) -> Vec<(PathBuf, bool)> {
        let (Some(folder), Some(stem)) = (self.inner.path.parent(), self.inner.path.file_stem()) else {
            return Vec::new();
        };
        let prefix = format!("{}.", stem.to_string_lossy());
        let suffix = format!(".{DELETING}");
        let Ok(entries) = std::fs::read_dir(folder) else {
            return Vec::new();
        };
        entries
            .filter_map(Result::ok)
            .filter(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                name.starts_with(&prefix) && name.ends_with(&suffix) && name.len() > prefix.len() + suffix.len()
            })
            .map(|entry| {
                let owes_store = std::fs::read(entry.path()).map_or(true, |stage| stage != ROWS_OWED);
                (entry.path(), owes_store)
            })
            .collect()
    }

    // Nothing of the owner is read or written while a delete still owes the store file: the owner's marker stands, or
    // a database's marker has yet to see the file go. A marker that cannot be checked counts as standing.
    pub fn delete_pending_blocking(&self) -> bool {
        standing(&self.marker()) || self.database_markers().iter().any(|(_, owes_store)| *owes_store)
    }

    // What `database`'s own delete still owes: its marker, or the owner's, stands.
    pub fn deleting_blocking(&self, database: &str) -> bool {
        standing(&self.marker()) || self.database_marker(database).is_ok_and(|marker| standing(&marker))
    }

    pub fn mark_deleting_blocking(&self, database: &str) -> Result<(), StorageError> {
        crate::fs::write_private_blocking(&self.database_marker(database)?, STORE_OWED)
    }

    // The file is gone: each database's marker now owes only that database's rows, so the owner can be read again
    // while a database another sign-in holds has yet to drop them.
    pub fn store_deleted_blocking(&self) -> Result<(), StorageError> {
        if standing(&self.inner.path) {
            return Err(StorageError::Io {
                path: self.inner.path.clone(),
                source: std::io::Error::other("the file is still there after its delete"),
            });
        }
        for (marker, owes_store) in self.database_markers() {
            if owes_store {
                crate::fs::write_private_blocking(&marker, ROWS_OWED)?;
            }
        }
        Ok(())
    }

    // Only once `database`'s own rows of the owner are gone too; another database's marker stays for its own delete.
    pub fn clear_deleting_blocking(&self, database: &str) -> Result<(), StorageError> {
        remove_verified(&self.database_marker(database)?)?;
        remove_verified(&self.marker())
    }

    pub fn locals_blocking(&self) -> Result<Vec<TeamLibraryLocal>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.local)
    }

    pub fn local_blocking(&self, team_id: &str) -> Result<TeamLibraryLocal, StorageError> {
        let _held = self.lock();
        Ok(local_of(self.read()?.local, team_id))
    }

    // Device-local state changes no item, so the journal hears nothing of it.
    pub fn update_local_blocking<T>(
        &self,
        team_id: &str,
        change: impl FnOnce(&mut TeamLibraryLocal) -> T,
    ) -> Result<T, StorageError> {
        let mut out = None;
        self.write(|document| {
            let index = match document.local.iter().position(|local| local.team_id == team_id) {
                Some(index) => index,
                None => {
                    document.local.push(TeamLibraryLocal {
                        team_id: team_id.to_owned(),
                        ..TeamLibraryLocal::default()
                    });
                    document.local.len() - 1
                }
            };
            out = Some(change(&mut document.local[index]));
            Vec::new()
        })?;
        out.ok_or(StorageError::NotFound)
    }

    // What a pull said of each item's last writer, which replaces what this device held of it.
    pub fn record_writers_blocking(&self, team_id: &str, writers: Vec<TeamLibraryWriter>) -> Result<(), StorageError> {
        self.update_local_blocking(team_id, |local| {
            for writer in writers {
                local
                    .writers
                    .retain(|held| !(held.kind == writer.kind && held.id == writer.id));
                local.writers.push(writer);
            }
        })
    }

    pub fn teams_blocking(&self) -> Result<Vec<TeamLibraryTeam>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.teams)
    }

    pub fn team_blocking(&self, team_id: &str) -> Result<Option<TeamLibraryTeam>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.teams.into_iter().find(|team| team.team_id == team_id))
    }

    // None until the first write.
    pub fn identity_blocking(&self) -> Result<Option<StoreIdentity>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.store)
    }

    pub fn put_items_blocking(&self, team_id: &str, items: Vec<TeamLibraryItem>) -> Result<(), StorageError> {
        if let Some(item) = items.iter().find(|item| !matches!(item.fields, Value::Object(_))) {
            return Err(StorageError::Schema(format!(
                "the fields of the team library {:?} item are not an object",
                item.kind
            )));
        }
        self.write(|document| {
            let team = team_mut(document, team_id);
            let mut written = Vec::new();
            for item in items {
                let record = (item.kind.record_kind(), item_record(team_id, &item.id));
                match team
                    .items
                    .iter_mut()
                    .find(|held| held.kind == item.kind && held.id == item.id)
                {
                    Some(held) if *held == item => continue,
                    Some(held) => *held = item,
                    None => team.items.push(item),
                }
                written.push(record);
            }
            entries(written, Vec::new())
        })
    }

    // Ids match exactly.
    pub fn remove_items_blocking(
        &self,
        team_id: &str,
        items: &[(TeamLibraryKind, String)],
    ) -> Result<(), StorageError> {
        self.write(|document| {
            let named =
                |kind: TeamLibraryKind, id: &str| items.iter().any(|(held, held_id)| *held == kind && held_id == id);
            if let Some(local) = document.local.iter_mut().find(|local| local.team_id == team_id) {
                local.writers.retain(|writer| !named(writer.kind, &writer.id));
            }
            let Some(team) = document.teams.iter_mut().find(|team| team.team_id == team_id) else {
                return Vec::new();
            };
            let mut deleted = Vec::new();
            team.items.retain(|held| {
                let gone = items.iter().any(|(kind, id)| held.kind == *kind && held.id == *id);
                if gone {
                    deleted.push((held.kind.record_kind(), item_record(team_id, &held.id)));
                }
                !gone
            });
            entries(Vec::new(), deleted)
        })
    }

    // A team the account left or lost goes with every item and everything this device knew of it.
    pub fn remove_team_blocking(&self, team_id: &str) -> Result<(), StorageError> {
        self.write(|document| {
            document.local.retain(|local| local.team_id != team_id);
            let mut deleted = Vec::new();
            document.teams.retain(|team| {
                if team.team_id != team_id {
                    return true;
                }
                deleted.extend(
                    team.items
                        .iter()
                        .map(|item| (item.kind.record_kind(), item_record(team_id, &item.id))),
                );
                false
            });
            entries(Vec::new(), deleted)
        })
    }

    // For a host that restored the file from a backup of its own: a new generation tells sync the file is not the one
    // it last saw.
    pub fn start_new_generation_blocking(&self) -> Result<StoreIdentity, StorageError> {
        self.write(|document| {
            document.store = Some(StoreIdentity::fresh());
            Vec::new()
        })?;
        self.identity_blocking()?.ok_or(StorageError::NotFound)
    }

    // The account's file and any write a crash left beside it, verified gone.
    pub fn delete_blocking(&self) -> Result<(), StorageError> {
        let _held = self.lock();
        let _file = lock_for_delete(&self.inner.path)?;
        delete_file_blocking(&self.inner.path)
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        match self.inner.lock.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    // A missing file is an empty store of this owner; one bound to another owner, or of an owner whose delete has not
    // finished, is refused.
    fn read(&self) -> Result<TeamLibraryDocument, StorageError> {
        let path = &self.inner.path;
        if self.delete_pending_blocking() {
            return Err(StorageError::DeletePending { path: path.clone() });
        }
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(TeamLibraryDocument {
                    owner: self.inner.owner.clone(),
                    store: None,
                    teams: Vec::new(),
                    local: Vec::new(),
                });
            }
            Err(source) => {
                return Err(StorageError::Io {
                    path: path.clone(),
                    source,
                });
            }
        };
        let document = crate::document::decode_document::<TeamLibraryDocument>(path, &bytes)
            .map_err(StorageError::DocumentUnavailable)?;
        if document.owner != self.inner.owner {
            return Err(StorageError::StoreOwnerMismatch { path: path.clone() });
        }
        Ok(document)
    }

    // A change that changes nothing writes nothing. The journal hears of it once both locks are gone.
    fn write(&self, change: impl FnOnce(&mut TeamLibraryDocument) -> Vec<JournalEntry>) -> Result<(), StorageError> {
        let entries = {
            let _held = self.lock();
            if let Some(parent) = self.inner.path.parent() {
                crate::fs::ensure_private_dir(parent)?;
            }
            let _file = crate::fs::lock_beside_blocking(&self.inner.path);
            let before = self.read()?;
            let mut document = before.clone();
            let entries = change(&mut document);
            document.teams.retain(|team| !team.items.is_empty());
            document.local.retain(|local| !local.holds_nothing());
            if document == before {
                return Ok(());
            }
            document.store = Some(StoreIdentity::after_write(document.store));
            crate::document::write_document_blocking(&self.inner.path, &document)?;
            entries
        };
        self.inner.journal.notify(&entries);
        Ok(())
    }
}

fn local_of(locals: Vec<TeamLibraryLocal>, team_id: &str) -> TeamLibraryLocal {
    locals
        .into_iter()
        .find(|local| local.team_id == team_id)
        .unwrap_or_else(|| TeamLibraryLocal {
            team_id: team_id.to_owned(),
            ..TeamLibraryLocal::default()
        })
}

const DELETING: &str = "deleting";
// A database marker's stage: the owner's file still to go, or only the database's own rows.
const STORE_OWED: &[u8] = b"store";
const ROWS_OWED: &[u8] = b"rows";

fn marker_for(path: &Path) -> PathBuf {
    path.with_extension(DELETING)
}

fn standing(path: &Path) -> bool {
    !matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
}

fn remove_verified(path: &Path) -> Result<(), StorageError> {
    let io = |source| StorageError::Io {
        path: path.to_owned(),
        source,
    };
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(source) => return Err(io(source)),
    }
    if let Some(parent) = path.parent() {
        tablepro_core::sync_directory(parent).map_err(io)?;
    }
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(source) => Err(io(source)),
        Ok(_) => Err(io(std::io::Error::other("the file is still there after its delete"))),
    }
}

// The file and the temporary copies `write_private_blocking` leaves beside it when a write is cut off.
fn delete_file_blocking(path: &Path) -> Result<(), StorageError> {
    if let (Some(parent), Some(name)) = (path.parent(), path.file_name()) {
        let prefix = format!(".{}.", name.to_string_lossy());
        let entries = match std::fs::read_dir(parent) {
            Ok(entries) => entries
                .collect::<Result<Vec<_>, _>>()
                .map_err(|source| StorageError::Io {
                    path: parent.to_owned(),
                    source,
                })?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(source) => {
                return Err(StorageError::Io {
                    path: parent.to_owned(),
                    source,
                });
            }
        };
        for entry in entries {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with(&prefix) && name.ends_with(".tmp") {
                remove_verified(&entry.path())?;
            }
        }
    }
    remove_verified(path)
}

// Every owner's file but `keep`'s, each marked before it goes: its marker stays until that owner's sync state lets
// go of the same data, so nothing of it is read meanwhile. An owner is found by its file, a temporary copy a crash
// left without one, or its marker. A file that cannot be read is deleted too, since its owner cannot be shown to be
// `keep`.
pub fn delete_other_owners_blocking(paths: &StoragePaths, keep: Option<&TeamLibraryOwner>) -> Result<(), StorageError> {
    let folder = paths.state.join("team-library");
    let kept = keep.map(|owner| TeamLibraryStore::path_for(paths, owner));
    let entries = match std::fs::read_dir(&folder) {
        Ok(entries) => entries
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| StorageError::Io {
                path: folder.clone(),
                source,
            })?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(source) => return Err(StorageError::Io { path: folder, source }),
    };
    let mut targets: Vec<PathBuf> = entries
        .into_iter()
        .filter_map(|entry| {
            owner_digest(&entry.file_name().to_string_lossy()).map(|digest| folder.join(format!("{digest}.json")))
        })
        .filter(|path| kept.as_deref() != Some(path.as_path()))
        .collect();
    targets.sort();
    targets.dedup();
    // Every owner is marked before any file goes, so one delete that fails leaves every owner it was meant for unread.
    for path in &targets {
        crate::fs::write_private_blocking(&marker_for(path), b"")?;
    }
    // Marked again under the lock just before its delete: the owner's own engine may have finished a delete of its
    // own and cleared the mark meanwhile, and a pass of it then sees the mark before it sends anything.
    let mut failed = None;
    for path in &targets {
        let deleted = lock_for_delete(path).and_then(|_file| {
            crate::fs::write_private_blocking(&marker_for(path), b"")?;
            delete_file_blocking(path)
        });
        if let Err(error) = deleted {
            failed.get_or_insert(error);
        }
    }
    failed.map_or(Ok(()), Err)
}

// Another process's write in flight would put the file back after a delete returns, so a delete without the lock fails.
fn lock_for_delete(path: &Path) -> Result<std::fs::File, StorageError> {
    crate::fs::lock_beside_blocking(path).ok_or_else(|| StorageError::Io {
        path: path.to_owned(),
        source: std::io::Error::other("the file's lock could not be taken for its delete"),
    })
}

// The owner digest a name in the folder belongs to: `<digest>.json`, `.<digest>.json.<random>.tmp` or
// `<digest>.deleting`.
fn owner_digest(name: &str) -> Option<&str> {
    let digest = name
        .strip_suffix(".json")
        .or_else(|| {
            name.strip_suffix(".deleting")
                .map(|rest| rest.split_once('.').map_or(rest, |(digest, _)| digest))
        })
        .or_else(|| {
            name.strip_prefix('.')
                .filter(|rest| rest.ends_with(".tmp"))
                .and_then(|rest| rest.split_once(".json."))
                .map(|(digest, _)| digest)
        })?;
    (digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())).then_some(digest)
}

fn item_record(team_id: &str, id: &str) -> RecordRef {
    RecordRef::TeamItem {
        team_id: team_id.to_owned(),
        id: id.to_owned(),
    }
}

// One entry per kind, in the order of the kinds.
fn entries(written: Vec<(RecordKind, RecordRef)>, deleted: Vec<(RecordKind, RecordRef)>) -> Vec<JournalEntry> {
    let mut kinds: Vec<RecordKind> = written.iter().chain(&deleted).map(|(kind, _)| *kind).collect();
    kinds.sort();
    kinds.dedup();
    kinds
        .into_iter()
        .map(|kind| {
            let of = |list: &[(RecordKind, RecordRef)]| -> Vec<RecordRef> {
                list.iter()
                    .filter(|(each, _)| *each == kind)
                    .map(|(_, record)| record.clone())
                    .collect()
            };
            JournalEntry::new(kind).wrote(of(&written)).deleted(of(&deleted))
        })
        .collect()
}

impl std::fmt::Debug for TeamLibraryStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TeamLibraryStore")
            .field("path", &self.inner.path)
            .finish()
    }
}

fn team_mut<'a>(document: &'a mut TeamLibraryDocument, team_id: &str) -> &'a mut TeamLibraryTeam {
    let index = match document.teams.iter().position(|team| team.team_id == team_id) {
        Some(index) => index,
        None => {
            document.teams.push(TeamLibraryTeam {
                team_id: team_id.to_owned(),
                items: Vec::new(),
            });
            document.teams.len() - 1
        }
    };
    &mut document.teams[index]
}
