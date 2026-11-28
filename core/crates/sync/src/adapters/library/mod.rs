// The connection library's kinds (0051, Kinds; 0054, Adapters): connections, groups, tags, projects, SSH and credential
// profiles over the core's connection store, one file, and table folders and their items over the saved queries' database. Each
// record's wire fields are its CloudKit fields in snake case with the Mac's values (0061, 4), so a Mac-written copy and
// the store's agree member by member. Local only and sample connections never leave the device, and neither do the
// column layouts and table folders of a connection that does not sync.

mod bundle;
mod connection;
mod details;
mod favourites;
mod folders;
mod groups;
mod local_uses;
mod profiles;
mod reads;
mod tunnel;
mod values;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::record_type_of;
use tablepro_records::record_id::{parse_uuid, uuid_id};
use tablepro_storage::{
    ConnectionList, ConnectionListState, ConnectionStore, LibraryChange, SavedQueryDatabase, SshProfile, StorageError,
};
use uuid::Uuid;

pub use bundle::{team_bundle, team_connection};
pub use connection::DriverNames;
pub use favourites::FavouriteAdapter;
pub use folders::TableFolderAdapter;
pub use local_uses::{LocalUse, shared_row_local_uses};
pub use reads::at_base;

use super::blocking;
use super::settings::ConnectionStanding;
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

const STORE: &str = "connections.json";

// The provider the adapters sync with: iCloud also carries a favourite table's legacy alias (0052, Long ids).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    ICloud,
    TableproSync,
}

pub use super::saved_queries::SAVED_QUERY_STORE;

const KINDS: [Kind; 6] = [
    Kind::Connection,
    Kind::Group,
    Kind::Tag,
    Kind::ConnectionProject,
    Kind::SshProfile,
    Kind::CredentialProfile,
];

// iCloud carries projects only once Production holds their type and the field on both members, as the Mac's
// `SyncWritableSchema.writesProjects` reads it. Until then no pulled record names a project, so a pull keeps this
// device's membership.
fn carries_projects(provider: Provider) -> bool {
    let deployed = |kind: Kind, field: Option<&str>| {
        record_type_of(kind).is_some_and(|record_type| {
            record_type.deployed
                && field.is_none_or(|name| record_type.fields.iter().any(|held| held.name == name && held.deployed))
        })
    };
    match provider {
        Provider::TableproSync => true,
        Provider::ICloud => {
            deployed(Kind::ConnectionProject, None)
                && deployed(Kind::Connection, Some("projectId"))
                && deployed(Kind::Group, Some("projectId"))
        }
    }
}

// The six kinds connections.json holds, each its own adapter over the one store.
pub struct LibraryAdapter {
    store: ConnectionStore,
    kind: Kind,
    names: DriverNames,
    // Whether a pulled record says which project its connection or group is in (`carries_projects`).
    projects: bool,
    // This device's id as the host keeps it, which names the routes it publishes.
    publisher: Option<Uuid>,
    seen: Mutex<Option<HashMap<String, Seen>>>,
    // Set by a batch the store refused, which the engine then applies one change at a time: each of those checks
    // against the same read, until the next read.
    retrying: Mutex<bool>,
}

impl LibraryAdapter {
    pub fn all(
        store: &ConnectionStore,
        names: DriverNames,
        provider: Provider,
        publisher: Option<Uuid>,
    ) -> Vec<Arc<dyn RecordAdapter>> {
        let projects = carries_projects(provider);
        KINDS
            .into_iter()
            .map(|kind| {
                Arc::new(Self {
                    store: store.clone(),
                    kind,
                    names,
                    projects,
                    publisher,
                    seen: Mutex::new(None),
                    retrying: Mutex::new(false),
                }) as Arc<dyn RecordAdapter>
            })
            .collect()
    }
}

// Every kind of the library, the table folders included, over the stores a Core opens.
pub fn adapters(
    store: &ConnectionStore,
    saved: Option<&SavedQueryDatabase>,
    names: DriverNames,
    provider: Provider,
    publisher: Option<Uuid>,
) -> Vec<Arc<dyn RecordAdapter>> {
    let mut all = LibraryAdapter::all(store, names, provider, publisher);
    if let Some(saved) = saved {
        all.extend(TableFolderAdapter::all(saved, store));
        all.extend(FavouriteAdapter::all(saved, store, provider));
    }
    all
}

pub(super) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
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

// What the adapter's last read found of a record. A pull merged against that read never writes over a record changed
// since, or one that stopped syncing: the write is refused and the next pass merges against what the store holds.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Seen {
    Record(Value, Standing),
    Unreadable,
}

pub(super) fn seen(records: &LocalRecords) -> HashMap<String, Seen> {
    records
        .records
        .iter()
        .map(|record| {
            (
                record.record_id.clone(),
                Seen::Record(record.fields.clone(), record.standing),
            )
        })
        .chain(records.unreadable.iter().map(|id| (id.clone(), Seen::Unreadable)))
        .collect()
}

pub(super) fn record_of(change: &LocalChange) -> &str {
    match change {
        LocalChange::Put { record_id, .. } | LocalChange::Delete { record_id } => record_id,
    }
}

// Whether a record the changes write is not as the adapter's last read found it.
pub(super) fn changed_since(
    expected: &HashMap<String, Seen>,
    now: &HashMap<String, Seen>,
    changes: &[LocalChange],
) -> bool {
    changes.iter().any(|change| {
        let id = record_of(change);
        expected.get(id) != now.get(id)
    })
}

pub(super) fn stale(store: &str) -> AdapterError {
    AdapterError::Store {
        store: store.to_owned(),
        detail: "a record changed since the pull read it".to_owned(),
    }
}

// The kind's records as the list holds them; `unreadable_ssh` and `unreadable_credentials` name the profiles of each
// kind this build cannot read.
fn local_records(
    kind: Kind,
    names: DriverNames,
    publisher: Option<Uuid>,
    list: &ConnectionList,
    unreadable_ssh: &[Uuid],
    unreadable_credentials: &[Uuid],
) -> LocalRecords {
    let (records, unreadable) = match kind {
        Kind::Connection => (
            list.connections
                .iter()
                .map(|saved| {
                    let favorite = list.is_favorite(saved.id);
                    let mut fields = connection::to_wire(saved, favorite, followed(list, saved), names);
                    if let Some(publisher) = publisher {
                        super::fields::set(
                            &mut fields,
                            &format!("/{}", super::unsettled::ROUTE_PUBLISHER),
                            Some(Value::String(uuid_id(publisher))),
                        );
                    }
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
        Kind::ConnectionProject => (
            list.projects
                .iter()
                .map(|project| record(project.id, groups::project_to_wire(project), Standing::Syncs))
                .collect(),
            Vec::new(),
        ),
        Kind::SshProfile => (
            list.ssh_profiles
                .iter()
                .map(|profile| record(profile.id, profiles::ssh_to_wire(profile), Standing::Syncs))
                .collect(),
            ids(unreadable_ssh),
        ),
        Kind::CredentialProfile => (
            list.credential_profiles
                .iter()
                .map(|profile| record(profile.id, profiles::credential_to_wire(profile), Standing::Syncs))
                .collect(),
            ids(unreadable_credentials),
        ),
        _ => (Vec::new(), Vec::new()),
    };
    LocalRecords {
        records,
        unreadable,
        tombstones: Vec::new(),
    }
}

// What the pulled records write, read against the list as it is under the store's write lock: a member a record
// carries as the store's copy reads keeps the store's value (`connection::model`). None when a record is one the store
// cannot hold, which the engine then holds by id rather than read as a deletion.
fn settled(
    kind: Kind,
    names: DriverNames,
    projects: bool,
    list: &ConnectionList,
    changes: Vec<LocalChange>,
) -> Option<Vec<LibraryChange>> {
    let mut settled = Vec::with_capacity(changes.len());
    for change in changes {
        let (record_id, fields) = match change {
            LocalChange::Put { record_id, fields } => (record_id, Some(fields)),
            LocalChange::Delete { record_id } => (record_id, None),
        };
        let Some(id) = parse_uuid(&record_id) else {
            tracing::warn!(kind = kind.as_str(), "a record whose id is not a UUID was left out");
            continue;
        };
        settled.push(match fields {
            None => gone(kind, id),
            Some(fields) => put(kind, names, projects, list, id, &fields)?,
        });
    }
    Some(match kind {
        Kind::CredentialProfile => unique_profile_names::<tablepro_storage::CredentialProfile>(list, settled),
        Kind::SshProfile => unique_profile_names::<SshProfile>(list, settled),
        _ => settled,
    })
}

// A profile kind every picker offers by its name alone, as a credential or an SSH profile.
trait NamedProfile: Clone {
    fn id(&self) -> Uuid;
    fn name(&self) -> &str;
    fn rename(&mut self, name: String);
    fn held(list: &ConnectionList) -> &[Self];
    fn put(change: &LibraryChange) -> Option<&Self>;
    fn gone(change: &LibraryChange) -> Option<Uuid>;
    fn change(self) -> LibraryChange;
}

impl NamedProfile for tablepro_storage::CredentialProfile {
    fn id(&self) -> Uuid {
        self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn rename(&mut self, name: String) {
        self.name = name;
    }

    fn held(list: &ConnectionList) -> &[Self] {
        &list.credential_profiles
    }

    fn put(change: &LibraryChange) -> Option<&Self> {
        match change {
            LibraryChange::CredentialProfile(profile) => Some(profile),
            _ => None,
        }
    }

    fn gone(change: &LibraryChange) -> Option<Uuid> {
        match change {
            LibraryChange::CredentialProfileGone(id) => Some(*id),
            _ => None,
        }
    }

    fn change(self) -> LibraryChange {
        LibraryChange::CredentialProfile(self)
    }
}

impl NamedProfile for SshProfile {
    fn id(&self) -> Uuid {
        self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn rename(&mut self, name: String) {
        self.name = name;
    }

    fn held(list: &ConnectionList) -> &[Self] {
        &list.ssh_profiles
    }

    fn put(change: &LibraryChange) -> Option<&Self> {
        match change {
            LibraryChange::SshProfile(profile) => Some(profile),
            _ => None,
        }
    }

    fn gone(change: &LibraryChange) -> Option<Uuid> {
        match change {
            LibraryChange::SshProfileGone(id) => Some(*id),
            _ => None,
        }
    }

    fn change(self) -> LibraryChange {
        LibraryChange::SshProfile(self)
    }
}

// A picker tells two profiles of one name apart by nothing else, so a pull that brings a second profile of a name
// settles it as 0052's Collisions do: the lowest id compared as bytes keeps the name, since a profile keeps no creation
// date, and each other takes the first free `<name> (2)`, `<name> (3)` and on, compared without case. A renamed
// profile this device held goes up as its own edit, as the Mac renamed the arriving one; one rule on every device
// converges (0075).
fn unique_profile_names<P: NamedProfile>(list: &ConnectionList, mut changes: Vec<LibraryChange>) -> Vec<LibraryChange> {
    let mut held: std::collections::BTreeMap<Uuid, P> = P::held(list)
        .iter()
        .map(|profile| (profile.id(), profile.clone()))
        .collect();
    let mut arriving: Vec<Uuid> = Vec::new();
    for change in &changes {
        if let Some(profile) = P::put(change) {
            held.insert(profile.id(), profile.clone());
            arriving.push(profile.id());
        } else if let Some(id) = P::gone(change) {
            held.remove(&id);
        }
    }
    let fold = |name: &str| name.to_lowercase();
    let mut by_name: std::collections::BTreeMap<String, Vec<Uuid>> = std::collections::BTreeMap::new();
    for profile in held.values() {
        by_name.entry(fold(profile.name())).or_default().push(profile.id());
    }
    let mut taken: std::collections::HashSet<String> = by_name.keys().cloned().collect();
    for (_, mut ids) in by_name {
        if ids.len() < 2 || !ids.iter().any(|id| arriving.contains(id)) {
            continue;
        }
        ids.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
        for id in ids.into_iter().skip(1) {
            let Some(profile) = held.get_mut(&id) else { continue };
            let name = free_name(profile.name(), |candidate| taken.contains(&fold(candidate)));
            taken.insert(fold(&name));
            profile.rename(name);
            let renamed = profile.clone().change();
            match changes
                .iter_mut()
                .find(|change| P::put(change).is_some_and(|put| put.id() == id))
            {
                Some(change) => *change = renamed,
                None => changes.push(renamed),
            }
        }
    }
    changes
}

fn free_name(name: &str, taken: impl Fn(&str) -> bool) -> String {
    let mut number: u64 = 2;
    loop {
        let candidate = format!("{name} ({number})");
        if !taken(&candidate) {
            return candidate;
        }
        number += 1;
    }
}

fn gone(kind: Kind, id: Uuid) -> LibraryChange {
    match kind {
        Kind::Connection => LibraryChange::ConnectionGone(id),
        Kind::Group => LibraryChange::GroupGone(id),
        Kind::Tag => LibraryChange::TagGone(id),
        Kind::ConnectionProject => LibraryChange::ProjectGone(id),
        Kind::SshProfile => LibraryChange::SshProfileGone(id),
        _ => LibraryChange::CredentialProfileGone(id),
    }
}

fn put(
    kind: Kind,
    names: DriverNames,
    projects: bool,
    list: &ConnectionList,
    id: Uuid,
    fields: &Value,
) -> Option<LibraryChange> {
    Some(match kind {
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
            let (mut connection, favorite) = connection::model(id, fields, held, names);
            if !projects {
                connection.project_id = held.and_then(|held| held.saved.project_id);
            }
            LibraryChange::Connection {
                connection: Box::new(connection),
                favorite,
            }
        }
        Kind::Group => {
            let stored = list.groups.iter().find(|group| group.id == id);
            let mut group = groups::group(id, fields, stored);
            if !projects {
                group.project_id = stored.and_then(|stored| stored.project_id);
            }
            LibraryChange::Group(group)
        }
        Kind::ConnectionProject => {
            let stored = list.projects.iter().find(|project| project.id == id);
            LibraryChange::Project(groups::project(id, fields, stored)?)
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
    })
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
        let records = local_records(
            self.kind,
            self.names,
            self.publisher,
            &library.list,
            &library.unreadable_ssh_profiles,
            &library.unreadable_credential_profiles,
        );
        *lock(&self.seen) = Some(seen(&records));
        *lock(&self.retrying) = false;
        Ok(records)
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::Personal || changes.is_empty() {
            return self.identity().await;
        }
        let retrying = *lock(&self.retrying);
        let expected = if retrying {
            lock(&self.seen).clone()
        } else {
            lock(&self.seen).take()
        };
        let (store, kind, names, projects, publisher) =
            (self.store.clone(), self.kind, self.names, self.projects, self.publisher);
        let (written, changed, refused, expected) = blocking(move || {
            let (mut changed, mut refused) = (false, false);
            let written = store.apply_synced_blocking(|list| {
                if let Some(expected) = &expected {
                    let held = &list.unreadable_profiles;
                    let now = seen(&local_records(kind, names, publisher, list, held, held));
                    if changed_since(expected, &now, &changes) {
                        changed = true;
                        return Vec::new();
                    }
                }
                settled(kind, names, projects, list, changes).unwrap_or_else(|| {
                    refused = true;
                    Vec::new()
                })
            });
            (written, changed, refused, expected)
        })
        .await?;
        let identity = written.map_err(store_error)?;
        if changed {
            *lock(&self.seen) = None;
            *lock(&self.retrying) = false;
            return Err(stale(STORE));
        }
        if refused {
            *lock(&self.seen) = expected;
            *lock(&self.retrying) = true;
            return Err(AdapterError::Unreadable {
                detail: format!("a {} the store cannot hold", kind.as_str()),
            });
        }
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
