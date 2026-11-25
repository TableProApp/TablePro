use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::document::VersionedDocument;
use crate::error::StorageError;
use crate::journal::{ChangeJournal, JournalSlot, RecordKind};
use crate::paths::StoragePaths;
use crate::store_identity::StoreIdentity;

#[cfg(test)]
mod tests;

/// The account a Team Library store belongs to: the server's API origin and the account id on it.
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

/// One shared item as this device holds it. `id` is the client id the team stores, byte for byte
/// and in its case (core ADR 0052, Team scope), and `fields` the item's JSON object in the bundle's
/// schema, which this store does not read.
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TeamLibraryDocument {
    owner: TeamLibraryOwner,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    store: Option<StoreIdentity>,
    #[serde(default)]
    teams: Vec<TeamLibraryTeam>,
}

impl VersionedDocument for TeamLibraryDocument {
    const KIND: &'static str = "team_library";
    const VERSION: u32 = 1;
}

/// The Team Library items one account holds on this device, one file per (origin, account), so no
/// item of one account is ever read for another (core ADR 0054, The state file, for the same rule).
///
/// The file's name is a digest of the owner, so an id a server chose never names a path, and the
/// owner is kept inside it: a file bound to another owner is refused. A write holds a lock file
/// from its re-read to its rename, as the connection list does.
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

    /// The journal every later write tells, or none.
    pub fn set_journal(&self, journal: Option<Arc<dyn ChangeJournal>>) {
        self.inner.journal.set(journal);
    }

    pub fn teams_blocking(&self) -> Result<Vec<TeamLibraryTeam>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.teams)
    }

    pub fn team_blocking(&self, team_id: &str) -> Result<Option<TeamLibraryTeam>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.teams.into_iter().find(|team| team.team_id == team_id))
    }

    /// `None` until the first write.
    pub fn identity_blocking(&self) -> Result<Option<StoreIdentity>, StorageError> {
        let _held = self.lock();
        Ok(self.read()?.store)
    }

    /// Adds each item, or replaces the one of its kind with exactly its id.
    pub fn put_items_blocking(&self, team_id: &str, items: Vec<TeamLibraryItem>) -> Result<(), StorageError> {
        if let Some(item) = items.iter().find(|item| !matches!(item.fields, Value::Object(_))) {
            return Err(StorageError::Schema(format!(
                "the fields of the team library {:?} item are not an object",
                item.kind
            )));
        }
        self.write(|document| {
            let team = team_mut(document, team_id);
            let mut kinds = Vec::new();
            for item in items {
                let kind = item.kind.record_kind();
                match team
                    .items
                    .iter_mut()
                    .find(|held| held.kind == item.kind && held.id == item.id)
                {
                    Some(held) if *held == item => continue,
                    Some(held) => *held = item,
                    None => team.items.push(item),
                }
                kinds.push(kind);
            }
            kinds
        })
    }

    /// Removes each (kind, id) the team holds; ids match exactly.
    pub fn remove_items_blocking(
        &self,
        team_id: &str,
        items: &[(TeamLibraryKind, String)],
    ) -> Result<(), StorageError> {
        self.write(|document| {
            let Some(team) = document.teams.iter_mut().find(|team| team.team_id == team_id) else {
                return Vec::new();
            };
            let mut kinds = Vec::new();
            team.items.retain(|held| {
                let gone = items.iter().any(|(kind, id)| held.kind == *kind && held.id == *id);
                if gone {
                    kinds.push(held.kind.record_kind());
                }
                !gone
            });
            kinds
        })
    }

    /// Drops a team the account left or lost, with every item of it.
    pub fn remove_team_blocking(&self, team_id: &str) -> Result<(), StorageError> {
        self.write(|document| {
            let mut kinds = Vec::new();
            document.teams.retain(|team| {
                if team.team_id != team_id {
                    return true;
                }
                kinds.extend(team.items.iter().map(|item| item.kind.record_kind()));
                false
            });
            kinds
        })
    }

    /// For a host that restored the file from a backup of its own: a new generation tells sync the
    /// file is not the one it last saw.
    pub fn start_new_generation_blocking(&self) -> Result<StoreIdentity, StorageError> {
        self.write(|document| {
            document.store = Some(StoreIdentity::fresh());
            Vec::new()
        })?;
        self.identity_blocking()?.ok_or(StorageError::NotFound)
    }

    /// Deletes the account's file, as signing out of the account does.
    pub fn delete_blocking(&self) -> Result<(), StorageError> {
        let _held = self.lock();
        // Another process's write in flight would otherwise put the file back after this returns.
        let _file = crate::fs::lock_beside_blocking(&self.inner.path);
        match std::fs::remove_file(&self.inner.path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(StorageError::Io {
                path: self.inner.path.clone(),
                source,
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        match self.inner.lock.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    // A missing file is an empty store of this owner; one bound to another owner is refused.
    fn read(&self) -> Result<TeamLibraryDocument, StorageError> {
        let path = &self.inner.path;
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(TeamLibraryDocument {
                    owner: self.inner.owner.clone(),
                    store: None,
                    teams: Vec::new(),
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
    fn write(&self, change: impl FnOnce(&mut TeamLibraryDocument) -> Vec<RecordKind>) -> Result<(), StorageError> {
        let mut kinds = {
            let _held = self.lock();
            if let Some(parent) = self.inner.path.parent() {
                crate::fs::ensure_private_dir(parent)?;
            }
            let _file = crate::fs::lock_beside_blocking(&self.inner.path);
            let before = self.read()?;
            let mut document = before.clone();
            let kinds = change(&mut document);
            document.teams.retain(|team| !team.items.is_empty());
            if document == before {
                return Ok(());
            }
            document.store = Some(StoreIdentity::after_write(document.store));
            crate::document::write_document_blocking(&self.inner.path, &document)?;
            kinds
        };
        kinds.sort();
        kinds.dedup();
        self.inner.journal.notify(&kinds);
        Ok(())
    }
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
