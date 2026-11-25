// A store per kind in memory, a state file and a CloudKit zone, wired as the engine runs the fetch.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{CloudFields, CloudValue, from_wire, record_name, record_type_of, to_wire};
use tablepro_sync::api::cloudkit::{CloudKitField, CloudKitTransport, CloudKitValue};
use tablepro_sync::api::state::Standing;
use tablepro_sync::api::state::{
    BaseRow, DeferredRow, HeldRow, Row, RowKey, StateFiles, StateIdentity, StateStore, StoreRow,
};
use tablepro_sync::api::{
    AdapterError, Cursor, LocalChange, LocalRecord, LocalRecords, RecordAdapter, RecordKey, ScopeName, StoreStamp,
    SyncError,
};
use tablepro_sync::cloudkit::fetch::{Categories, FetchReport, Fetcher, Rebased, ServerChanged};
use tablepro_sync_testing::{FakeCloudKit, MemoryStateFiles};
use uuid::Uuid;

pub const USER: &str = "_4f1e2d";

pub const A: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
pub const B: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";
pub const C: &str = "84BC7D00-A144-4C18-80C0-A11C6070D4F9";
pub const D: &str = "3FD0B191-5CF8-4760-84A9-92779983F3CF";

pub const KINDS: [Kind; 8] = [
    Kind::Connection,
    Kind::Group,
    Kind::Tag,
    Kind::SshProfile,
    Kind::CredentialProfile,
    Kind::SavedQuery,
    Kind::FavouriteTable,
    Kind::MacosSettings,
];

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(Debug)]
struct Held {
    records: BTreeMap<String, LocalRecord>,
    unreadable: BTreeSet<String>,
    generation: Uuid,
    sequence: u64,
    refuse_next: bool,
    writes: usize,
}

#[derive(Debug)]
pub struct MemoryStore {
    kind: Kind,
    store: String,
    held: Mutex<Held>,
}

impl MemoryStore {
    pub fn new(kind: Kind) -> Arc<Self> {
        Arc::new(Self {
            kind,
            store: kind.as_str().to_owned(),
            held: Mutex::new(Held {
                records: BTreeMap::new(),
                unreadable: BTreeSet::new(),
                generation: Uuid::new_v4(),
                sequence: 0,
                refuse_next: false,
                writes: 0,
            }),
        })
    }

    pub fn put(&self, id: &str, fields: Value) {
        self.put_with(id, fields, Standing::Syncs);
    }

    pub fn put_with(&self, id: &str, fields: Value, standing: Standing) {
        let mut held = lock(&self.held);
        held.sequence += 1;
        held.unreadable.remove(id);
        held.records.insert(
            id.to_owned(),
            LocalRecord {
                record_id: id.to_owned(),
                fields,
                standing,
            },
        );
    }

    pub fn remove(&self, id: &str) {
        let mut held = lock(&self.held);
        held.sequence += 1;
        held.records.remove(id);
        held.unreadable.remove(id);
    }

    // The file now holds the record in a form this build cannot read.
    pub fn make_unreadable(&self, id: &str) {
        let mut held = lock(&self.held);
        held.records.remove(id);
        held.unreadable.insert(id.to_owned());
    }

    pub fn fields(&self, id: &str) -> Option<Value> {
        lock(&self.held).records.get(id).map(|record| record.fields.clone())
    }

    pub fn holds(&self, id: &str) -> bool {
        let held = lock(&self.held);
        held.records.contains_key(id) || held.unreadable.contains(id)
    }

    pub fn generation(&self) -> Uuid {
        lock(&self.held).generation
    }

    pub fn writes(&self) -> usize {
        lock(&self.held).writes
    }

    pub fn refuse_next_write(&self) {
        lock(&self.held).refuse_next = true;
    }

    // Restored from a backup: a new generation holding these records.
    pub fn restore(&self, records: Vec<(&str, Value)>) {
        let mut held = lock(&self.held);
        held.generation = Uuid::new_v4();
        held.sequence = 1;
        held.unreadable.clear();
        held.records = records
            .into_iter()
            .map(|(id, fields)| {
                (
                    id.to_owned(),
                    LocalRecord {
                        record_id: id.to_owned(),
                        fields,
                        standing: Standing::Syncs,
                    },
                )
            })
            .collect();
    }
}

#[async_trait]
impl RecordAdapter for MemoryStore {
    fn kind(&self) -> Kind {
        self.kind
    }

    fn store(&self) -> &str {
        &self.store
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        let held = lock(&self.held);
        Ok(StoreStamp {
            generation: held.generation,
            sequence: held.sequence,
        })
    }

    async fn records(&self) -> Result<LocalRecords, AdapterError> {
        let held = lock(&self.held);
        Ok(LocalRecords {
            records: held.records.values().cloned().collect(),
            unreadable: held.unreadable.iter().cloned().collect(),
            tombstones: Vec::new(),
        })
    }

    async fn apply(&self, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        let mut held = lock(&self.held);
        if std::mem::take(&mut held.refuse_next) {
            return Err(AdapterError::Store {
                store: self.store.clone(),
                detail: "refused".to_owned(),
            });
        }
        for change in changes {
            match change {
                LocalChange::Put { record_id, fields } => {
                    let standing = held
                        .records
                        .get(&record_id)
                        .map_or(Standing::Syncs, |record| record.standing);
                    held.unreadable.remove(&record_id);
                    held.records.insert(
                        record_id.clone(),
                        LocalRecord {
                            record_id,
                            fields,
                            standing,
                        },
                    );
                }
                LocalChange::Delete { record_id } => {
                    held.records.remove(&record_id);
                    held.unreadable.remove(&record_id);
                }
            }
        }
        held.sequence += 1;
        held.writes += 1;
        Ok(StoreStamp {
            generation: held.generation,
            sequence: held.sequence,
        })
    }

    async fn tombstones_pushed(&self, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}

fn cloudkit_value(value: CloudValue) -> CloudKitValue {
    match value {
        CloudValue::Text(text) => CloudKitValue::Text(text),
        CloudValue::Int64(number) => CloudKitValue::Int64(number),
        CloudValue::Double(number) => CloudKitValue::Double(number),
        CloudValue::Timestamp(millis) => CloudKitValue::Timestamp(millis),
        CloudValue::Bytes(bytes) => CloudKitValue::Bytes(bytes),
        CloudValue::TextList(items) => CloudKitValue::TextList(items),
    }
}

fn cloud_value(value: &CloudKitValue) -> CloudValue {
    match value {
        CloudKitValue::Text(text) => CloudValue::Text(text.clone()),
        CloudKitValue::Int64(number) => CloudValue::Int64(*number),
        CloudKitValue::Double(number) => CloudValue::Double(*number),
        CloudKitValue::Timestamp(millis) => CloudValue::Timestamp(*millis),
        CloudKitValue::Bytes(bytes) => CloudValue::Bytes(bytes.clone()),
        CloudKitValue::TextList(items) => CloudValue::TextList(items.clone()),
    }
}

// Every field Production holds for the type, clearing the ones the wire record lacks, as a save from a Mac sets them.
pub fn cloud_fields(kind: Kind, id: &str, wire: &Value) -> Vec<CloudKitField> {
    from_wire(kind, id, wire, 1_700_000_000_000)
        .unwrap()
        .unwrap()
        .into_iter()
        .map(|(name, value)| CloudKitField {
            name: name.to_owned(),
            value: value.map(cloudkit_value),
        })
        .collect()
}

pub fn name(kind: Kind, id: &str) -> String {
    record_name(kind, id).unwrap()
}

pub fn key(kind: Kind, id: &str) -> RecordKey {
    RecordKey::new(ScopeName::Personal, kind, id)
}

// The wire fields a record has once it went to CloudKit and back.
pub fn projected(kind: Kind, id: &str, wire: &Value) -> Value {
    let fields: CloudFields = cloud_fields(kind, id, wire)
        .into_iter()
        .filter_map(|field| Some((field.name, cloud_value(field.value.as_ref()?))))
        .collect();
    to_wire(record_type_of(kind).unwrap().name, &name(kind, id), &fields)
        .unwrap()
        .fields
}

pub struct Rig {
    pub cloud: FakeCloudKit,
    pub files: MemoryStateFiles,
    pub state: Arc<dyn StateStore>,
    pub stores: BTreeMap<Kind, Arc<MemoryStore>>,
    pub on: Mutex<BTreeSet<Kind>>,
}

impl Rig {
    pub async fn new() -> Self {
        let cloud = FakeCloudKit::signed_in(USER);
        cloud.ensure_zone(USER.to_owned()).await.unwrap();
        let files = MemoryStateFiles::new();
        let state = files.open(Self::identity()).await.unwrap();
        Self {
            cloud,
            files,
            state,
            stores: KINDS.into_iter().map(|kind| (kind, MemoryStore::new(kind))).collect(),
            on: Mutex::new(KINDS.into_iter().collect()),
        }
    }

    pub fn identity() -> StateIdentity {
        StateIdentity::ICloud {
            user_record_name: USER.to_owned(),
        }
    }

    pub fn store(&self, kind: Kind) -> &MemoryStore {
        &self.stores[&kind]
    }

    pub fn turn_off(&self, kind: Kind) {
        lock(&self.on).remove(&kind);
    }

    pub fn turn_on(&self, kind: Kind) {
        lock(&self.on).insert(kind);
    }

    fn adapters(&self) -> Vec<Arc<dyn RecordAdapter>> {
        self.stores
            .values()
            .map(|store| Arc::clone(store) as Arc<dyn RecordAdapter>)
            .collect()
    }

    pub fn fetcher<'a>(&'a self, transport: &'a dyn CloudKitTransport) -> Fetcher<'a> {
        self.fetcher_on(transport, self.state.as_ref())
    }

    pub fn fetcher_on<'a>(&'a self, transport: &'a dyn CloudKitTransport, state: &'a dyn StateStore) -> Fetcher<'a> {
        Fetcher::new(
            transport,
            state,
            &self.adapters(),
            Categories::new(lock(&self.on).iter().copied()),
        )
        .unwrap()
    }

    pub async fn fetch(&self) -> Result<FetchReport, SyncError> {
        self.fetcher(&self.cloud).fetch().await
    }

    pub async fn fetch_through(&self, transport: &dyn CloudKitTransport) -> Result<FetchReport, SyncError> {
        self.fetcher(transport).fetch().await
    }

    pub async fn rebase(&self, conflicts: Vec<ServerChanged>) -> Result<Rebased, SyncError> {
        self.fetcher(&self.cloud).rebase(conflicts).await
    }

    pub fn save_elsewhere(&self, kind: Kind, id: &str, wire: &Value) {
        let record_type = record_type_of(kind).unwrap().name;
        self.cloud
            .save_elsewhere(USER, record_type, &name(kind, id), cloud_fields(kind, id, wire));
    }

    pub fn delete_elsewhere(&self, kind: Kind, id: &str) {
        self.cloud.delete_elsewhere(USER, &name(kind, id));
    }

    async fn row(&self, key: RowKey) -> Option<Row> {
        self.state.begin().await.unwrap().get(&key).await.unwrap()
    }

    pub async fn base(&self, kind: Kind, id: &str) -> Option<BaseRow> {
        match self.row(RowKey::Base(key(kind, id))).await {
            Some(Row::Base(base)) => Some(base),
            _ => None,
        }
    }

    pub async fn held(&self, kind: Kind, id: &str) -> Option<HeldRow> {
        match self.row(RowKey::Held(key(kind, id))).await {
            Some(Row::Held(held)) => Some(held),
            _ => None,
        }
    }

    pub async fn deferred(&self, kind: Kind, id: &str) -> Option<DeferredRow> {
        match self.row(RowKey::Deferred(key(kind, id))).await {
            Some(Row::Deferred(deferred)) => Some(deferred),
            _ => None,
        }
    }

    pub async fn store_row(&self, kind: Kind) -> Option<StoreRow> {
        match self.row(RowKey::Store(kind.as_str().to_owned())).await {
            Some(Row::Store(row)) => Some(row),
            _ => None,
        }
    }

    pub async fn token(&self) -> Option<Vec<u8>> {
        match self.row(RowKey::Scope(ScopeName::Personal)).await {
            Some(Row::Scope(scope)) => match scope.cursor {
                Some(Cursor::CloudKit(token)) => Some(token),
                _ => None,
            },
            _ => None,
        }
    }
}
