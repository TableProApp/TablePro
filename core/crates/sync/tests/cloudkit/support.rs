// A store per kind in memory, a state file and a CloudKit zone, wired as the engine runs the fetch, the push and the
// pass.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{CloudFields, CloudValue, from_wire, record_name, record_type_of, to_wire};
use tablepro_sync::adapters::approval::Queue;
use tablepro_sync::api::cloudkit::{CloudKitField, CloudKitTransport, CloudKitValue};
use tablepro_sync::api::control::PendingApproval;
use tablepro_sync::api::ids::{ChangeTag, KindName};
use tablepro_sync::api::state::{
    BaseRow, DeferredRow, HeldRow, Row, RowKey, RowRange, StateFiles, StateIdentity, StateStore, StoreRow, Table,
};
use tablepro_sync::api::state::{HeldReason, Standing};
use tablepro_sync::api::transport::PulledRecord;
use tablepro_sync::api::{
    AdapterError, Cursor, LocalChange, LocalRecord, LocalRecords, RecordAdapter, RecordKey, ScopeName, StoreStamp,
    SyncError,
};
use tablepro_sync::cloudkit::fetch::{Categories, FetchReport, Fetcher, Rebased, ServerChanged};
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync, PushReport, Pusher, Waits};
use tablepro_sync::engine::{Adapters, Clock, Journal, StopSignal};
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

// A store's generation and write sequence, which kinds kept in one file share.
#[derive(Debug)]
pub struct Identity {
    generation: Uuid,
    sequence: u64,
}

impl Identity {
    pub fn new() -> Arc<Mutex<Self>> {
        Arc::new(Mutex::new(Self {
            generation: Uuid::new_v4(),
            sequence: 0,
        }))
    }
}

#[derive(Debug)]
struct Held {
    records: BTreeMap<String, LocalRecord>,
    unreadable: BTreeSet<String>,
    refuse_next: bool,
    writes: usize,
    // A write the person makes right after the next read, while the pull merges.
    edit_after_read: Option<(String, Value)>,
}

#[derive(Debug)]
pub struct MemoryStore {
    kind: Kind,
    store: String,
    identity: Arc<Mutex<Identity>>,
    held: Mutex<Held>,
}

impl MemoryStore {
    pub fn new(kind: Kind) -> Arc<Self> {
        Self::in_file(kind, kind.as_str(), Identity::new())
    }

    pub fn in_file(kind: Kind, store: &str, identity: Arc<Mutex<Identity>>) -> Arc<Self> {
        Arc::new(Self {
            kind,
            store: store.to_owned(),
            identity,
            held: Mutex::new(Held {
                records: BTreeMap::new(),
                unreadable: BTreeSet::new(),
                refuse_next: false,
                writes: 0,
                edit_after_read: None,
            }),
        })
    }

    fn wrote(&self) -> StoreStamp {
        let mut identity = lock(&self.identity);
        identity.sequence += 1;
        StoreStamp {
            generation: identity.generation,
            sequence: identity.sequence,
        }
    }

    pub fn store_name(&self) -> &str {
        &self.store
    }

    pub fn put(&self, id: &str, fields: Value) {
        self.put_with(id, fields, Standing::Syncs);
    }

    pub fn put_with(&self, id: &str, fields: Value, standing: Standing) {
        let mut held = lock(&self.held);
        held.unreadable.remove(id);
        held.records.insert(
            id.to_owned(),
            LocalRecord {
                record_id: id.to_owned(),
                fields,
                standing,
            },
        );
        self.wrote();
    }

    pub fn remove(&self, id: &str) {
        let mut held = lock(&self.held);
        held.records.remove(id);
        held.unreadable.remove(id);
        self.wrote();
    }

    // The file now holds the record in a form this build cannot read.
    pub fn make_unreadable(&self, id: &str) {
        let mut held = lock(&self.held);
        held.records.remove(id);
        held.unreadable.insert(id.to_owned());
    }

    pub fn edit_after_next_read(&self, id: &str, fields: Value) {
        lock(&self.held).edit_after_read = Some((id.to_owned(), fields));
    }

    pub fn fields(&self, id: &str) -> Option<Value> {
        lock(&self.held).records.get(id).map(|record| record.fields.clone())
    }

    pub fn holds(&self, id: &str) -> bool {
        let held = lock(&self.held);
        held.records.contains_key(id) || held.unreadable.contains(id)
    }

    pub fn generation(&self) -> Uuid {
        lock(&self.identity).generation
    }

    pub fn writes(&self) -> usize {
        lock(&self.held).writes
    }

    pub fn refuse_next_write(&self) {
        lock(&self.held).refuse_next = true;
    }

    // Time Machine put the file back: the same generation at an earlier write, holding these records.
    pub fn roll_back(&self, sequence: u64, records: Vec<(&str, Value)>) {
        let generation = self.generation();
        self.restore(records);
        let mut identity = lock(&self.identity);
        identity.generation = generation;
        identity.sequence = sequence;
    }

    pub fn sequence(&self) -> u64 {
        lock(&self.identity).sequence
    }

    // Restored from a backup: the file it shares with other kinds gets a new generation, holding these records.
    pub fn restore(&self, records: Vec<(&str, Value)>) {
        {
            let mut identity = lock(&self.identity);
            identity.generation = Uuid::new_v4();
            identity.sequence = 1;
        }
        let mut held = lock(&self.held);
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
        let identity = lock(&self.identity);
        Ok(StoreStamp {
            generation: identity.generation,
            sequence: identity.sequence,
        })
    }

    async fn records(&self, _scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        let edit = {
            let mut held = lock(&self.held);
            held.edit_after_read.take()
        };
        let records = {
            let held = lock(&self.held);
            LocalRecords {
                records: held.records.values().cloned().collect(),
                unreadable: held.unreadable.iter().cloned().collect(),
                tombstones: Vec::new(),
            }
        };
        if let Some((id, fields)) = edit {
            self.put(&id, fields);
        }
        Ok(records)
    }

    async fn apply(&self, _scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
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
        held.writes += 1;
        Ok(self.wrote())
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
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

// Milliseconds since the Unix epoch, moved by the test.
#[derive(Debug)]
pub struct TestClock(AtomicI64);

impl TestClock {
    pub fn advance(&self, ms: i64) {
        self.0.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for TestClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

pub struct Rig {
    pub cloud: Arc<FakeCloudKit>,
    pub files: Arc<MemoryStateFiles>,
    pub state: Arc<dyn StateStore>,
    pub stores: BTreeMap<Kind, Arc<MemoryStore>>,
    pub on: Mutex<BTreeSet<Kind>>,
    pub clock: Arc<TestClock>,
    // What a push run by the test keeps between its passes, as the engine's session does.
    waits: Mutex<Waits>,
}

impl Rig {
    pub async fn new() -> Self {
        let cloud = Arc::new(FakeCloudKit::signed_in(USER));
        cloud.ensure_zone(USER.to_owned()).await.unwrap();
        let files = Arc::new(MemoryStateFiles::new());
        let state = files.open(Self::identity()).await.unwrap();
        Self {
            cloud,
            files,
            state,
            stores: Self::stores(),
            on: Mutex::new(KINDS.into_iter().collect()),
            clock: Arc::new(TestClock(AtomicI64::new(1_767_225_600_000))),
            waits: Mutex::new(Waits::default()),
        }
    }

    // Saved queries and table favourites live in one file, as the library store keeps them.
    fn stores() -> BTreeMap<Kind, Arc<MemoryStore>> {
        let library = Identity::new();
        KINDS
            .into_iter()
            .map(|kind| {
                let store = match kind {
                    Kind::SavedQuery | Kind::FavouriteTable => {
                        MemoryStore::in_file(kind, "library", Arc::clone(&library))
                    }
                    _ => MemoryStore::new(kind),
                };
                (kind, store)
            })
            .collect()
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

    pub fn adapters(&self) -> Vec<Arc<dyn RecordAdapter>> {
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
        self.fetcher(self.cloud.as_ref()).fetch().await
    }

    pub async fn push(&self) -> Result<PushReport, SyncError> {
        self.push_through(self.cloud.as_ref()).await
    }

    pub async fn push_through(&self, transport: &dyn CloudKitTransport) -> Result<PushReport, SyncError> {
        self.push_on(transport, self.state.as_ref()).await
    }

    pub async fn push_on(
        &self,
        transport: &dyn CloudKitTransport,
        state: &dyn StateStore,
    ) -> Result<PushReport, SyncError> {
        let fetcher = self.fetcher_on(transport, state);
        let stop = StopSignal::new();
        let mut waits = std::mem::take(&mut *lock(&self.waits));
        let pushed = Pusher::new(&fetcher, &stop, self.clock.now_ms())
            .push(&mut waits, None)
            .await;
        *lock(&self.waits) = waits;
        pushed
    }

    // The iCloud pass over this rig's stores and state files, as the app last left it with `last_account`.
    pub fn sync(&self, last_account: Option<&str>) -> CloudKitSync {
        self.sync_through(Arc::clone(&self.cloud) as Arc<dyn CloudKitTransport>, last_account)
    }

    pub fn sync_through(&self, transport: Arc<dyn CloudKitTransport>, last_account: Option<&str>) -> CloudKitSync {
        self.sync_over(transport, Arc::clone(&self.files) as Arc<dyn StateFiles>, last_account)
    }

    pub fn sync_over(
        &self,
        transport: Arc<dyn CloudKitTransport>,
        files: Arc<dyn StateFiles>,
        last_account: Option<&str>,
    ) -> CloudKitSync {
        CloudKitSync::new(CloudKitParts {
            transport,
            files,
            adapters: self.adapters(),
            categories: Categories::new(lock(&self.on).iter().copied()),
            clock: Arc::clone(&self.clock) as Arc<dyn Clock>,
            stop: StopSignal::new(),
            journal: Journal::default(),
            events: None,
            last_account: last_account.map(str::to_owned),
        })
    }

    // The fields of a record the zone holds, as wire fields.
    pub fn zone_fields(&self, kind: Kind, id: &str) -> Option<Value> {
        self.zone_fields_of(USER, kind, id)
    }

    pub fn zone_fields_of(&self, account: &str, kind: Kind, id: &str) -> Option<Value> {
        let record = self.cloud.record(account, &name(kind, id))?;
        let fields: CloudFields = record
            .fields
            .iter()
            .filter_map(|field| Some((field.name.clone(), cloud_value(field.value.as_ref()?))))
            .collect();
        Some(to_wire(&record.record_type, &record.name, &fields).unwrap().fields)
    }

    pub async fn fetch_through(&self, transport: &dyn CloudKitTransport) -> Result<FetchReport, SyncError> {
        self.fetcher(transport).fetch().await
    }

    pub async fn rebase(&self, conflicts: Vec<ServerChanged>) -> Result<Rebased, SyncError> {
        self.fetcher(self.cloud.as_ref()).rebase(conflicts).await
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

    // The bases a pull staged before its store write and has not committed.
    pub async fn pending_bases(&self) -> Vec<BaseRow> {
        let mut txn = self.state.begin().await.unwrap();
        txn.scan(&RowRange::Table(Table::PendingBases))
            .await
            .unwrap()
            .into_iter()
            .filter_map(|row| match row {
                Row::PendingBase(base) => Some(base),
                _ => None,
            })
            .collect()
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

    // What waits for the person, as the app's approval sheet lists it.
    pub async fn waiting(&self) -> Vec<PendingApproval> {
        let adapters = Adapters::new(self.adapters());
        let queue = Queue {
            state: &self.state,
            adapters: &adapters,
        };
        queue.waiting().await.unwrap()
    }

    // The person approves every value the queue holds.
    pub async fn approve_everything(&self) {
        let adapters = Adapters::new(self.adapters());
        let queue = Queue {
            state: &self.state,
            adapters: &adapters,
        };
        for approval in queue.waiting().await.unwrap() {
            queue
                .decide(&approval.key, &approval.field, approval.digest, true)
                .await
                .unwrap();
        }
    }

    // The approval queue's hold on a pulled value.
    pub async fn hold_for_approval(&self, kind: Kind, id: &str) {
        let mut txn = self.state.begin().await.unwrap();
        txn.put(Row::Held(HeldRow {
            key: key(kind, id),
            reason: HeldReason::AwaitingApproval,
            record: PulledRecord {
                kind: KindName::of(kind),
                record_id: id.to_owned(),
                tag: ChangeTag::CloudKit(Vec::new()),
                fields: None,
                fields_json: None,
                deleted: None,
                service: None,
            },
        }))
        .await
        .unwrap();
        txn.commit().await.unwrap();
    }

    pub async fn deferred(&self, kind: Kind, id: &str) -> Option<DeferredRow> {
        match self.row(RowKey::Deferred(key(kind, id))).await {
            Some(Row::Deferred(deferred)) => Some(deferred),
            _ => None,
        }
    }

    // The one row of the file that keeps `kind` (0066, `stores`).
    pub async fn store_row(&self, kind: Kind) -> Option<StoreRow> {
        let row = self.store(kind).store_name().to_owned();
        match self.row(RowKey::Store(row)).await {
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
