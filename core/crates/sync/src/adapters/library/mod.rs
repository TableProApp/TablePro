// The connection library's kinds (0051, Kinds; 0054, Adapters): connections, groups, tags, SSH and credential profiles
// over the core's connection store, one file, and table folders and their items over the history database. Each
// record's wire fields are its CloudKit fields in snake case with the Mac's values (0061, 4), so a Mac-written copy and
// the store's agree member by member. Local only and sample connections never leave the device, and neither do the
// column layouts and table folders of a connection that does not sync.

mod connection;
mod details;
mod folders;
mod groups;
mod profiles;
mod reads;
mod tunnel;
mod values;

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::record_id::{parse_uuid, uuid_id};
use tablepro_storage::{
    ConnectionList, ConnectionListState, ConnectionStore, LibraryChange, QueryHistory, SshProfile, StorageError,
    SyncedLibrary,
};
use uuid::Uuid;

pub use connection::DriverNames;
pub use folders::TableFolderAdapter;
pub use reads::at_base;

use super::blocking;
use super::settings::ConnectionStanding;
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

const STORE: &str = "connections.json";

// The same name for every kind the history database holds, so a restored file refills them together (0060).
pub const HISTORY_STORE: &str = "history.db";

const KINDS: [Kind; 5] = [
    Kind::Connection,
    Kind::Group,
    Kind::Tag,
    Kind::SshProfile,
    Kind::CredentialProfile,
];

// The five kinds connections.json holds, each its own adapter over the one store.
pub struct LibraryAdapter {
    store: ConnectionStore,
    kind: Kind,
    names: DriverNames,
}

impl LibraryAdapter {
    pub fn all(store: &ConnectionStore, names: DriverNames) -> Vec<Arc<dyn RecordAdapter>> {
        KINDS
            .into_iter()
            .map(|kind| {
                Arc::new(Self {
                    store: store.clone(),
                    kind,
                    names,
                }) as Arc<dyn RecordAdapter>
            })
            .collect()
    }
}

// Every kind of the library, the table folders included, over the stores a Core opens.
pub fn adapters(
    store: &ConnectionStore,
    history: Option<&QueryHistory>,
    names: DriverNames,
) -> Vec<Arc<dyn RecordAdapter>> {
    let mut all = LibraryAdapter::all(store, names);
    if let Some(history) = history {
        all.extend(TableFolderAdapter::all(history, store));
    }
    all
}

fn store_error(error: StorageError) -> AdapterError {
    AdapterError::Store {
        store: STORE.to_owned(),
        detail: error.to_string(),
    }
}

fn stamp(identity: Option<tablepro_storage::StoreIdentity>) -> StoreStamp {
    identity.map_or(
        StoreStamp {
            generation: Uuid::nil(),
            sequence: 0,
        },
        |identity| StoreStamp {
            generation: identity.generation,
            sequence: identity.sequence,
        },
    )
}

// A connection kept off sync by the person, or one of the samples, stays on the device.
fn connection_standing(saved: &tablepro_storage::SavedConnection) -> Standing {
    if saved.device.local_only || saved.device.is_sample {
        Standing::LocalOnly
    } else {
        Standing::Syncs
    }
}

fn record(id: Uuid, fields: Value, standing: Standing) -> LocalRecord {
    LocalRecord {
        record_id: uuid_id(id),
        fields,
        standing,
    }
}

// The SSH profile a connection's tunnel follows, when this device holds it.
fn followed<'a>(list: &'a ConnectionList, saved: &tablepro_storage::SavedConnection) -> Option<&'a SshProfile> {
    let id = saved.details.ssh_profile_id?;
    list.ssh_profiles.iter().find(|profile| profile.id == id)
}

fn ids(ids: &[Uuid]) -> Vec<String> {
    ids.iter().copied().map(uuid_id).collect()
}

impl LibraryAdapter {
    fn read(&self, library: &SyncedLibrary) -> LocalRecords {
        let list = &library.list;
        let (records, unreadable) = match self.kind {
            Kind::Connection => (
                list.connections
                    .iter()
                    .map(|saved| {
                        let favorite = list.is_favorite(saved.id);
                        let fields = connection::to_wire(saved, favorite, followed(list, saved), self.names);
                        record(saved.id, fields, connection_standing(saved))
                    })
                    .collect(),
                ids(&list.unreadable),
            ),
            Kind::Group => (
                list.groups
                    .iter()
                    .map(|group| record(group.id, groups::group_to_wire(group), Standing::Syncs))
                    .collect(),
                Vec::new(),
            ),
            Kind::Tag => (
                list.tags
                    .iter()
                    .map(|tag| record(tag.id, groups::tag_to_wire(tag), Standing::Syncs))
                    .collect(),
                Vec::new(),
            ),
            Kind::SshProfile => (
                list.ssh_profiles
                    .iter()
                    .map(|profile| record(profile.id, profiles::ssh_to_wire(profile), Standing::Syncs))
                    .collect(),
                ids(&library.unreadable_ssh_profiles),
            ),
            Kind::CredentialProfile => (
                list.credential_profiles
                    .iter()
                    .map(|profile| record(profile.id, profiles::credential_to_wire(profile), Standing::Syncs))
                    .collect(),
                ids(&library.unreadable_credential_profiles),
            ),
            _ => (Vec::new(), Vec::new()),
        };
        LocalRecords {
            records,
            unreadable,
            tombstones: Vec::new(),
        }
    }
}

// What the pulled records write, read against the list as it is under the store's write lock: a member a record
// carries as the store's copy reads keeps the store's value (`connection::model`).
fn settled(kind: Kind, names: DriverNames, list: &ConnectionList, changes: Vec<LocalChange>) -> Vec<LibraryChange> {
    changes
        .into_iter()
        .filter_map(|change| {
            let (record_id, fields) = match change {
                LocalChange::Put { record_id, fields } => (record_id, Some(fields)),
                LocalChange::Delete { record_id } => (record_id, None),
            };
            let Some(id) = parse_uuid(&record_id) else {
                tracing::warn!(kind = kind.as_str(), "a record whose id is not a UUID was left out");
                return None;
            };
            Some(match fields {
                None => gone(kind, id),
                Some(fields) => put(kind, names, list, id, &fields),
            })
        })
        .collect()
}

fn gone(kind: Kind, id: Uuid) -> LibraryChange {
    match kind {
        Kind::Connection => LibraryChange::ConnectionGone(id),
        Kind::Group => LibraryChange::GroupGone(id),
        Kind::Tag => LibraryChange::TagGone(id),
        Kind::SshProfile => LibraryChange::SshProfileGone(id),
        _ => LibraryChange::CredentialProfileGone(id),
    }
}

fn put(kind: Kind, names: DriverNames, list: &ConnectionList, id: Uuid, fields: &Value) -> LibraryChange {
    match kind {
        Kind::Connection => {
            let held = list
                .connections
                .iter()
                .find(|saved| saved.id == id)
                .map(|saved| connection::Held {
                    saved,
                    favorite: list.is_favorite(id),
                    profile: followed(list, saved),
                });
            let (connection, favorite) = connection::model(id, fields, held, names);
            LibraryChange::Connection {
                connection: Box::new(connection),
                favorite,
            }
        }
        Kind::Group => {
            let stored = list.groups.iter().find(|group| group.id == id);
            LibraryChange::Group(groups::group(id, fields, stored))
        }
        Kind::Tag => {
            let stored = list.tags.iter().find(|tag| tag.id == id);
            LibraryChange::Tag(groups::tag(id, fields, stored))
        }
        Kind::SshProfile => {
            let stored = list.ssh_profiles.iter().find(|profile| profile.id == id);
            LibraryChange::SshProfile(profiles::ssh(id, fields, stored))
        }
        _ => {
            let stored = list.credential_profiles.iter().find(|profile| profile.id == id);
            LibraryChange::CredentialProfile(profiles::credential(id, fields, stored))
        }
    }
}

#[async_trait]
impl RecordAdapter for LibraryAdapter {
    fn kind(&self) -> Kind {
        self.kind
    }

    fn store(&self) -> &str {
        STORE
    }

    // A store never written yet starts its generation now, so its first write is not read as a restore.
    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        let store = self.store.clone();
        let identity = blocking(move || match store.identity_blocking()? {
            Some(identity) => Ok(identity),
            None => store.start_new_generation_blocking(),
        })
        .await?
        .map_err(store_error)?;
        Ok(stamp(Some(identity)))
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope != ScopeName::Personal {
            return Ok(LocalRecords::default());
        }
        let store = self.store.clone();
        let library = blocking(move || store.synced_library_blocking())
            .await?
            .map_err(store_error)?;
        Ok(self.read(&library))
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::Personal || changes.is_empty() {
            return self.identity().await;
        }
        let (store, kind, names) = (self.store.clone(), self.kind, self.names);
        let identity = blocking(move || store.apply_synced_blocking(move |list| settled(kind, names, list, changes)))
            .await?
            .map_err(store_error)?;
        Ok(stamp(identity))
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}

// Whether a connection's records sync, read from the list the store last published, so a settings pass never waits on
// the file. A connection the list does not hold, or a list not read yet, gives Unknown, which sends nothing.
pub struct StoreStanding(pub ConnectionStore);

impl ConnectionStanding for StoreStanding {
    fn standing(&self, connection: Uuid) -> Standing {
        match self.0.snapshot().state {
            ConnectionListState::Ready(list) => list
                .connections
                .iter()
                .find(|saved| saved.id == connection)
                .map_or(Standing::Unknown, connection_standing),
            ConnectionListState::Loading | ConnectionListState::Unavailable(_) => Standing::Unknown,
        }
    }
}

#[cfg(test)]
mod tests;
