// Devices over the in-memory `/v2` server: each with its state file, its stores as in-memory adapters, and the engine.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use serde_json::{Value, json};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::keys::Ed25519Seed;
use tablepro_records::Kind;
use tablepro_sync::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use tablepro_sync::api::control::{ConflictChoice, SyncControl};
use tablepro_sync::api::device_store::HostDeviceStore;
use tablepro_sync::api::error::{AdapterError, StateError, SyncError};
use tablepro_sync::api::ids::{ChangeTag, DeviceRowId, IdempotencyKey, KindName, RecordKey, ScopeName};
use tablepro_sync::api::key_flows::{
    AccountFlows, ApprovalFlows, ArrivalOrder, DeviceFlows, KeyApplied, KeyArrival, KeyChangeSet, KeyState,
    OpenedEnvelope, PushBackVerdict, ResetFlows, RestoreFlows, Roster, StopAction, StopFlows, TeamFlows,
};
use tablepro_sync::api::scopes::ScopesAnswer;
use tablepro_sync::api::state::{
    Committed, KeysSettled, Opened, Row, RowKey, RowRange, Standing, StateFiles, StateIdentity, StateStore, StateTxn,
};
use tablepro_sync::api::transport::{
    Change, ChangeOp, ChangeOutcome, DpopKey, Proof, PullRequest, PulledPage, PushAnswer, PushBatch, ServiceTransport,
    Transport, TransportError,
};
use tablepro_sync::engine::{Adapters, Clock, EngineHooks, Journal, StopSignal, Wake};
use tablepro_sync::service::{PassReport, ServiceMode, ServiceParts, ServiceSync};
use tablepro_sync::state::SqliteStateFiles;
use tablepro_sync_testing::service::ScopeOwner;
use tablepro_sync_testing::{FakeClient, FakeDeviceStore, FakeServer, MemoryStateFiles};
use uuid::Uuid;

pub const ACCOUNT: &str = "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8";

pub fn account() -> AccountId {
    AccountId::from_wire(ACCOUNT).unwrap()
}

pub fn origin() -> Origin {
    Origin::parse("https://sync.example.com").unwrap()
}

pub fn id(n: u8) -> String {
    format!("6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C{n:02X}")
}

pub fn identity(row: &str) -> StateIdentity {
    StateIdentity::Service {
        origin: origin(),
        sign_in: "sign-in".to_owned(),
        account: account(),
        device_row: DeviceRowId(row.to_owned()),
    }
}

pub fn personal() -> ScopeOwner {
    ScopeOwner::Personal(account())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

// One store file, which every kind it holds shares: its generation and write sequence.
#[derive(Debug)]
pub struct StoreFile {
    stamp: Mutex<StoreStamp>,
}

impl StoreFile {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            stamp: Mutex::new(StoreStamp {
                generation: Uuid::new_v4(),
                sequence: 0,
            }),
        })
    }

    fn advance(&self) {
        lock(&self.stamp).sequence += 1;
    }

    pub fn stamp(&self) -> StoreStamp {
        *lock(&self.stamp)
    }

    // The file put back from a backup: another generation.
    pub fn restored(&self) {
        let mut stamp = lock(&self.stamp);
        stamp.generation = Uuid::new_v4();
        stamp.sequence = 0;
    }
}

#[derive(Default)]
struct Held {
    records: BTreeMap<String, (Value, Standing)>,
    unreadable: Vec<String>,
    tombstones: Vec<String>,
    applies: Vec<Vec<LocalChange>>,
}

impl Held {
    fn local(&self) -> LocalRecords {
        LocalRecords {
            records: self
                .records
                .iter()
                .map(|(id, (fields, standing))| LocalRecord {
                    record_id: id.clone(),
                    fields: fields.clone(),
                    standing: *standing,
                })
                .collect(),
            unreadable: self.unreadable.clone(),
            tombstones: self.tombstones.clone(),
        }
    }

    fn apply(&mut self, changes: Vec<LocalChange>) {
        for change in &changes {
            match change {
                LocalChange::Put { record_id, fields } => {
                    let standing = self
                        .records
                        .get(record_id)
                        .map_or(Standing::Syncs, |(_, standing)| *standing);
                    self.records.insert(record_id.clone(), (fields.clone(), standing));
                }
                LocalChange::Delete { record_id } => {
                    self.records.remove(record_id);
                }
            }
        }
        self.applies.push(changes);
    }
}

// A kind's store in memory: local edits through `put` and `remove` in the scope the device registered it for, what a
// pull settles through `apply`. The kind's records of any other scope it syncs in are kept apart.
pub struct MemoryAdapter {
    kind: Kind,
    name: String,
    file: Arc<StoreFile>,
    home: Mutex<ScopeName>,
    held: Mutex<Held>,
    elsewhere: Mutex<std::collections::HashMap<ScopeName, Held>>,
    on_apply: Mutex<Option<Box<dyn Fn() + Send>>>,
    // Ids whose pulled change the store cannot take: a write that touches one fails whole.
    refused_values: Mutex<std::collections::HashSet<String>>,
}

impl MemoryAdapter {
    pub fn new(kind: Kind, name: &str, file: Arc<StoreFile>) -> Arc<Self> {
        Arc::new(Self {
            kind,
            name: name.to_owned(),
            file,
            home: Mutex::new(ScopeName::Personal),
            held: Mutex::default(),
            elsewhere: Mutex::default(),
            on_apply: Mutex::new(None),
            refused_values: Mutex::default(),
        })
    }

    fn home(&self) -> ScopeName {
        *lock(&self.home)
    }

    pub fn register(&self, scope: ScopeName) {
        *lock(&self.home) = scope;
    }

    pub fn put(&self, id: &str, fields: Value) {
        lock(&self.held)
            .records
            .insert(id.to_owned(), (fields, Standing::Syncs));
        self.file.advance();
    }

    pub fn put_local_only(&self, id: &str, fields: Value) {
        lock(&self.held)
            .records
            .insert(id.to_owned(), (fields, Standing::LocalOnly));
        self.file.advance();
    }

    pub fn remove(&self, id: &str) {
        lock(&self.held).records.remove(id);
        self.file.advance();
    }

    // The store cannot keep a value for this id, as a build that does not know it would; false takes it again.
    pub fn refuse_value(&self, id: &str, refused: bool) {
        let mut values = lock(&self.refused_values);
        if refused {
            values.insert(id.to_owned());
        } else {
            values.remove(id);
        }
    }

    // A copy the store still holds and can no longer read, as one a newer build rewrote.
    pub fn make_unreadable(&self, id: &str) {
        let mut held = lock(&self.held);
        held.records.remove(id);
        held.unreadable.push(id.to_owned());
    }

    // A create-once entry the person deleted: a tombstone the store keeps until it is pushed.
    pub fn delete_entry(&self, id: &str) {
        let mut held = lock(&self.held);
        held.records.remove(id);
        held.tombstones.push(id.to_owned());
        drop(held);
        self.file.advance();
    }

    pub fn get(&self, id: &str) -> Option<Value> {
        lock(&self.held).records.get(id).map(|(fields, _)| fields.clone())
    }

    pub fn applies(&self) -> usize {
        lock(&self.held).applies.len()
    }

    pub fn tombstones(&self) -> Vec<String> {
        lock(&self.held).tombstones.clone()
    }

    // Runs inside the next store writes, as a stop arriving while a pull writes would.
    pub fn on_apply(&self, run: impl Fn() + Send + 'static) {
        *lock(&self.on_apply) = Some(Box::new(run));
    }
}

#[async_trait]
impl RecordAdapter for MemoryAdapter {
    fn kind(&self) -> Kind {
        self.kind
    }

    fn store(&self) -> &str {
        &self.name
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        Ok(self.file.stamp())
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope == self.home() {
            return Ok(lock(&self.held).local());
        }
        Ok(lock(&self.elsewhere).get(&scope).map(Held::local).unwrap_or_default())
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if let Some(run) = lock(&self.on_apply).as_ref() {
            run();
        }
        let refused = lock(&self.refused_values);
        if changes.iter().any(|change| match change {
            LocalChange::Put { record_id, .. } | LocalChange::Delete { record_id } => refused.contains(record_id),
        }) {
            return Err(AdapterError::Unreadable {
                detail: "a value this store cannot keep".to_owned(),
            });
        }
        drop(refused);
        if scope == self.home() {
            lock(&self.held).apply(changes);
        } else {
            lock(&self.elsewhere).entry(scope).or_default().apply(changes);
        }
        self.file.advance();
        Ok(self.file.stamp())
    }

    async fn tombstones_pushed(&self, scope: ScopeName, record_ids: Vec<String>) -> Result<(), AdapterError> {
        if scope == self.home() {
            lock(&self.held).tombstones.retain(|id| !record_ids.contains(id));
        } else if let Some(held) = lock(&self.elsewhere).get_mut(&scope) {
            held.tombstones.retain(|id| !record_ids.contains(id));
        }
        self.file.advance();
        Ok(())
    }
}

#[derive(Debug, Default)]
pub struct TestClock(pub AtomicI64);

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

// The transport over a fake client, which can drop a push before it is sent, lose the answer to one the server
// applied, expire a cursor, or open a new epoch just before a push. It logs the kinds of each push.
pub struct Wire {
    pub client: FakeClient,
    drop_next_push: AtomicBool,
    lose_next_answer: AtomicBool,
    expire_next_cursor: AtomicBool,
    new_epoch_before_push: AtomicBool,
    new_epoch_before_pull: AtomicBool,
    keys: Mutex<Vec<IdempotencyKey>>,
    pushed: Mutex<Vec<Vec<String>>>,
    pub pulls: AtomicUsize,
    held_pull: Mutex<Option<HeldPull>>,
}

// The next pull of a scope waits here once the server answered it: told when it is reached, then let go.
struct HeldPull {
    scope: ScopeName,
    reached: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
}

impl Wire {
    pub fn new(client: FakeClient) -> Arc<Self> {
        Arc::new(Self {
            client,
            drop_next_push: AtomicBool::new(false),
            lose_next_answer: AtomicBool::new(false),
            expire_next_cursor: AtomicBool::new(false),
            new_epoch_before_push: AtomicBool::new(false),
            new_epoch_before_pull: AtomicBool::new(false),
            keys: Mutex::default(),
            pushed: Mutex::default(),
            pulls: AtomicUsize::new(0),
            held_pull: Mutex::default(),
        })
    }

    // The next pull of `scope` holds its answer until the second notify; the first says it was reached.
    pub fn hold_next_pull(&self, scope: ScopeName) -> (Arc<tokio::sync::Notify>, Arc<tokio::sync::Notify>) {
        let reached = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        *lock(&self.held_pull) = Some(HeldPull {
            scope,
            reached: Arc::clone(&reached),
            release: Arc::clone(&release),
        });
        (reached, release)
    }

    pub fn drop_next_push(&self) {
        self.drop_next_push.store(true, Ordering::SeqCst);
    }

    pub fn lose_next_answer(&self) {
        self.lose_next_answer.store(true, Ordering::SeqCst);
    }

    pub fn expire_next_cursor(&self) {
        self.expire_next_cursor.store(true, Ordering::SeqCst);
    }

    pub fn new_epoch_before_push(&self) {
        self.new_epoch_before_push.store(true, Ordering::SeqCst);
    }

    pub fn new_epoch_before_pull(&self) {
        self.new_epoch_before_pull.store(true, Ordering::SeqCst);
    }

    pub fn keys(&self) -> Vec<IdempotencyKey> {
        lock(&self.keys).clone()
    }

    pub fn pushed(&self) -> Vec<Vec<String>> {
        lock(&self.pushed).clone()
    }
}

fn network() -> TransportError {
    TransportError::Network {
        detail: "the connection dropped".to_owned(),
    }
}

#[async_trait]
impl Transport for Wire {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError> {
        self.pulls.fetch_add(1, Ordering::SeqCst);
        if self.new_epoch_before_pull.swap(false, Ordering::SeqCst) {
            self.client.server().new_epoch();
        }
        if request.cursor.is_some() && self.expire_next_cursor.swap(false, Ordering::SeqCst) {
            return Err(TransportError::CursorExpired);
        }
        let scope = request.scope;
        let answer = self.client.pull(request).await;
        let held = {
            let mut held = lock(&self.held_pull);
            match held.as_ref() {
                Some(waits) if waits.scope == scope => held.take(),
                _ => None,
            }
        };
        if let Some(held) = held {
            held.reached.notify_one();
            held.release.notified().await;
        }
        answer
    }

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError> {
        if self.new_epoch_before_push.swap(false, Ordering::SeqCst) {
            self.client.server().new_epoch();
        }
        if let Some(key) = &batch.idempotency_key {
            lock(&self.keys).push(key.clone());
        }
        if self.drop_next_push.swap(false, Ordering::SeqCst) {
            return Err(network());
        }
        let kinds = batch
            .changes
            .iter()
            .map(|change| change.kind.as_str().to_owned())
            .collect();
        let answer = self.client.push(batch).await;
        if answer.is_ok() {
            lock(&self.pushed).push(kinds);
        }
        if self.lose_next_answer.swap(false, Ordering::SeqCst) {
            return Err(network());
        }
        answer
    }
}

#[async_trait]
impl ServiceTransport for Wire {
    async fn scopes(&self, if_none_match: Option<String>, proof: Proof) -> Result<ScopesAnswer, TransportError> {
        self.client.scopes(if_none_match, proof).await
    }

    async fn revoke_key_device(&self, proof: DpopKey) -> Result<(), TransportError> {
        self.client.revoke_key_device(proof).await
    }

    async fn report_stopped(&self, team: TeamId, version: Version, proof: DpopKey) -> Result<(), TransportError> {
        self.client.report_stopped(team, version, proof).await
    }

    async fn withdraw_stopped(&self, team: TeamId, proof: DpopKey) -> Result<(), TransportError> {
        self.client.withdraw_stopped(team, proof).await
    }

    async fn remove_device_row(&self, device: DeviceRowId, proof: DpopKey) -> Result<(), TransportError> {
        self.client.remove_device_row(device, proof).await
    }
}

// What the engine handed the key flows, and the versions in force they answer: a `key.version` record's id ends in
// its version, and an envelope opens only at the version in force at its place, or at most the newest in a snapshot.
#[derive(Debug, Default)]
pub struct KeyLog {
    // In the order the engine called: arrivals, then envelopes opened.
    events: Mutex<Vec<KeyEvent>>,
    rosters: Mutex<Vec<(TeamId, Roster)>>,
    push_back: Mutex<Vec<KeyChangeSet>>,
    pushed_back_at: Mutex<Vec<tablepro_sync::api::ids::EpochId>>,
    answered: Mutex<Vec<Vec<ChangeOutcome>>>,
    verdict: Mutex<Option<PushBackVerdict>>,
    newest: Mutex<BTreeMap<String, u32>>,
    waiting_for_approval: AtomicBool,
    rebuilding: AtomicBool,
    // The device's key, which the builder sets.
    proof: Mutex<Option<DpopKey>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyEvent {
    Arrived {
        scope: ScopeName,
        order: ArrivalOrder,
        ids: Vec<String>,
    },
    Opened {
        id: String,
        in_force: Option<Version>,
        taken: bool,
    },
}

impl KeyLog {
    // The device holds no keys until `approved`.
    pub fn waiting_for_approval() -> Self {
        let keys = Self::default();
        keys.waiting_for_approval.store(true, Ordering::SeqCst);
        keys
    }

    pub fn approved(&self) {
        self.waiting_for_approval.store(false, Ordering::SeqCst);
    }

    // A stale file's key tables rebuild: the device is approved, but opens no envelope until `rebuilt`.
    pub fn rebuilding() -> Self {
        let keys = Self::default();
        keys.rebuilding.store(true, Ordering::SeqCst);
        keys
    }

    pub fn rebuilt(&self) {
        self.rebuilding.store(false, Ordering::SeqCst);
    }

    pub fn events(&self) -> Vec<KeyEvent> {
        lock(&self.events).clone()
    }

    pub fn rosters(&self) -> Vec<(TeamId, Roster)> {
        lock(&self.rosters).clone()
    }

    pub fn queue_push_back(&self, set: KeyChangeSet, verdict: PushBackVerdict) {
        lock(&self.push_back).push(set);
        *lock(&self.verdict) = Some(verdict);
    }

    pub fn pushed_back_at(&self) -> Vec<tablepro_sync::api::ids::EpochId> {
        lock(&self.pushed_back_at).clone()
    }

    pub fn answered(&self) -> Vec<Vec<ChangeOutcome>> {
        lock(&self.answered).clone()
    }

    fn applied(&self, arrival: &KeyArrival, purpose: &str) -> KeyApplied {
        lock(&self.events).push(KeyEvent::Arrived {
            scope: arrival.scope,
            order: arrival.order,
            ids: arrival.records.iter().map(|record| record.record_id.clone()).collect(),
        });
        let versions = arrival
            .records
            .iter()
            .filter(|record| record.kind.as_str() == "key.version")
            .filter_map(|record| {
                let mut parts = record.record_id.rsplitn(2, '/');
                let version = parts.next()?.parse::<u32>().ok()?;
                parts.next()?.ends_with(purpose).then_some(version)
            })
            .max();
        let mut newest = lock(&self.newest);
        let held = newest.entry(arrival.scope.wire()).or_default();
        if let Some(version) = versions {
            *held = (*held).max(version);
        }
        KeyApplied {
            in_force: versions.and_then(|version| Version::new(version).ok()),
            ..KeyApplied::default()
        }
    }

    fn open(
        &self,
        scope: ScopeName,
        envelope: &EnvelopeId,
        fields: &Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        if self.rebuilding.load(Ordering::SeqCst) {
            return Err(SyncError::NotAllowed {
                what: "handle a secret before the key tables are rebuilt",
            });
        }
        let kv = fields.get("kv").and_then(Value::as_u64).unwrap_or(0);
        let newest = u64::from(lock(&self.newest).get(&scope.wire()).copied().unwrap_or(0));
        let fits = in_force.map_or(kv <= newest && kv > 0, |held| u64::from(held.get()) == kv);
        lock(&self.events).push(KeyEvent::Opened {
            id: envelope.to_wire(),
            in_force,
            taken: fits,
        });
        if !fits {
            return Err(SyncError::Keys(tablepro_keys::KeysError::Stale {
                held: u32::try_from(newest).unwrap_or(0),
                offered: u32::try_from(kv).unwrap_or(0),
            }));
        }
        Ok(OpenedEnvelope {
            secret: secrecy::SecretString::from(String::new()),
            dest: Value::Null,
            kv: Version::new(u32::try_from(kv).unwrap_or(1)).unwrap_or(Version::FIRST),
        })
    }
}

#[async_trait]
impl AccountFlows for KeyLog {
    async fn key_state(&self) -> Result<KeyState, SyncError> {
        Ok(if self.waiting_for_approval.load(Ordering::SeqCst) {
            KeyState::NeedsApproval { request: None }
        } else {
            KeyState::Approved {
                av: Version::FIRST,
                key_device: KeyDeviceId(Uuid::nil()),
            }
        })
    }

    async fn apply_account_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        Ok(self.applied(&arrival, "personal"))
    }

    async fn open_personal_envelope(
        &self,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        self.open(ScopeName::Personal, &envelope, &fields, in_force)
    }

    // Sealed under history version 1, the plaintext carried as text so a pull reads it back.
    async fn seal_history_entry(
        &self,
        _entry: tablepro_keys::encoding::HistoryId,
        plaintext: Value,
    ) -> Result<Value, SyncError> {
        Ok(json!({"suite": "tp1", "kv": 1, "ct": plaintext.to_string()}))
    }

    async fn open_history_entry(
        &self,
        _entry: tablepro_keys::encoding::HistoryId,
        fields: Value,
    ) -> Result<Value, SyncError> {
        fields
            .get("ct")
            .and_then(Value::as_str)
            .and_then(|text| serde_json::from_str(text).ok())
            .ok_or(SyncError::Malformed {
                what: "sealed history entry",
            })
    }

    async fn dpop_key(&self) -> Result<Option<DpopKey>, SyncError> {
        Ok(lock(&self.proof).clone())
    }

    fn rebuilding(&self) -> bool {
        self.rebuilding.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl ApprovalFlows for KeyLog {
    async fn apply_session_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = self.applied(&arrival, "none");
        Ok(KeyApplied::default())
    }
}

impl DeviceFlows for KeyLog {}

#[async_trait]
impl ResetFlows for KeyLog {
    async fn apply_reset_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = self.applied(&arrival, "none");
        Ok(KeyApplied::default())
    }
}

#[async_trait]
impl TeamFlows for KeyLog {
    async fn apply_team_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        Ok(self.applied(&arrival, "team"))
    }

    async fn open_team_envelope(
        &self,
        team: TeamId,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        self.open(ScopeName::Team(team), &envelope, &fields, in_force)
    }

    async fn roster_read(&self, team: TeamId, roster: Roster) -> Result<(), SyncError> {
        lock(&self.rosters).push((team, roster));
        Ok(())
    }
}

#[async_trait]
impl RestoreFlows for KeyLog {
    async fn push_back(&self, epoch: tablepro_sync::api::ids::EpochId) -> Result<Vec<KeyChangeSet>, SyncError> {
        lock(&self.pushed_back_at).push(epoch);
        Ok(std::mem::take(&mut *lock(&self.push_back)))
    }

    async fn push_back_answered(
        &self,
        set: KeyChangeSet,
        outcomes: Vec<ChangeOutcome>,
    ) -> Result<PushBackVerdict, SyncError> {
        let _ = set;
        lock(&self.answered).push(outcomes);
        Ok(lock(&self.verdict).clone().unwrap_or(PushBackVerdict::Continue))
    }
}

#[async_trait]
impl StopFlows for KeyLog {
    async fn stop_actions(&self) -> Result<Vec<StopAction>, SyncError> {
        Ok(Vec::new())
    }
}

// A state file whose next commit fails, as a crash between the store write and the commit leaves it.
pub struct Crashing {
    inner: Arc<dyn StateStore>,
    pub armed: Arc<AtomicBool>,
}

impl Crashing {
    pub fn new(inner: Arc<dyn StateStore>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            armed: Arc::new(AtomicBool::new(false)),
        })
    }
}

#[async_trait]
impl StateStore for Crashing {
    fn identity(&self) -> &StateIdentity {
        self.inner.identity()
    }

    fn opened(&self) -> &Opened {
        self.inner.opened()
    }

    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        Ok(Box::new(CrashingTxn {
            inner: self.inner.begin().await?,
            armed: Arc::clone(&self.armed),
        }))
    }
}

struct CrashingTxn {
    inner: Box<dyn StateTxn>,
    armed: Arc<AtomicBool>,
}

#[async_trait]
impl StateTxn for CrashingTxn {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        self.inner.get(key).await
    }

    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        self.inner.scan(range).await
    }

    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        self.inner.put(row).await
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        self.inner.delete(key).await
    }

    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        self.inner.clear_key_tables().await
    }

    fn settle_keys(&mut self, settled: KeysSettled) {
        self.inner.settle_keys(settled);
    }

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        if self.armed.swap(false, Ordering::SeqCst) {
            return Err(StateError::Io {
                detail: "the process ended before the commit".to_owned(),
            });
        }
        self.inner.commit().await
    }
}

// One device: its sign-in, its state file and its stores, with the engine over them.
pub struct Device {
    pub server: Arc<FakeServer>,
    pub wire: Arc<Wire>,
    pub state: Arc<dyn StateStore>,
    pub connections: Arc<MemoryAdapter>,
    pub connections_file: Arc<StoreFile>,
    pub keys: Arc<KeyLog>,
    pub hooks: Arc<EngineHooks>,
    pub stop: StopSignal,
    pub clock: Arc<TestClock>,
    pub sync: Arc<ServiceSync>,
    pub seed: Arc<Ed25519Seed>,
}

pub struct DeviceBuilder {
    server: Arc<FakeServer>,
    row: String,
    approved: bool,
    mode: ServiceMode,
    state: Option<Arc<dyn StateStore>>,
    connections: Option<(Arc<MemoryAdapter>, Arc<StoreFile>)>,
    extra: Vec<(ScopeName, Arc<MemoryAdapter>)>,
    others: Vec<Arc<dyn RecordAdapter>>,
    memory_connections: bool,
    keys: Option<Arc<KeyLog>>,
    seed: Option<Arc<Ed25519Seed>>,
}

impl DeviceBuilder {
    pub fn new(server: &Arc<FakeServer>, row: &str) -> Self {
        Self {
            server: Arc::clone(server),
            row: row.to_owned(),
            approved: true,
            mode: ServiceMode::Personal,
            state: None,
            connections: None,
            extra: Vec::new(),
            others: Vec::new(),
            memory_connections: true,
            keys: None,
            seed: None,
        }
    }

    // The core's own stores in place of the in-memory connections, as an app opens the engine over them.
    pub fn core_stores(mut self, adapters: Vec<Arc<dyn RecordAdapter>>) -> Self {
        self.memory_connections = false;
        self.others.extend(adapters);
        self
    }

    // An adapter of the test's own, over a store that behaves as a core store does.
    pub fn extra_adapter(mut self, adapter: Arc<dyn RecordAdapter>) -> Self {
        self.others.push(adapter);
        self
    }

    // A device whose personal provider is iCloud or Off: Team Library and the key objects only.
    pub fn teams_only(mut self) -> Self {
        self.mode = ServiceMode::TeamsOnly;
        self
    }

    pub fn unapproved(mut self) -> Self {
        self.approved = false;
        self
    }

    pub fn state(mut self, state: Arc<dyn StateStore>) -> Self {
        self.state = Some(state);
        self
    }

    pub fn connections(mut self, adapter: Arc<MemoryAdapter>, file: Arc<StoreFile>) -> Self {
        self.connections = Some((adapter, file));
        self
    }

    pub fn adapter(mut self, scope: ScopeName, adapter: Arc<MemoryAdapter>) -> Self {
        self.extra.push((scope, adapter));
        self
    }

    pub fn keys(mut self, keys: Arc<KeyLog>) -> Self {
        self.keys = Some(keys);
        self
    }

    pub fn seed(mut self, seed: Arc<Ed25519Seed>) -> Self {
        self.seed = Some(seed);
        self
    }

    pub async fn build(self) -> Device {
        let seed = self.seed.unwrap_or_else(|| Arc::new(Ed25519Seed::generate().unwrap()));
        let row = DeviceRowId(self.row.clone());
        if self.approved {
            self.server.approve(&row, seed.public().unwrap().0);
        }
        let wire = Wire::new(self.server.client(account(), row));
        let state = match self.state {
            Some(state) => state,
            None => MemoryStateFiles::new().open(identity(&self.row)).await.unwrap(),
        };
        let (connections, connections_file) = self.connections.unwrap_or_else(|| {
            let file = StoreFile::new();
            (
                MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file)),
                file,
            )
        });
        let mut adapters: Vec<Arc<dyn RecordAdapter>> = Vec::new();
        if self.memory_connections {
            adapters.push(Arc::clone(&connections) as Arc<dyn RecordAdapter>);
        }
        for (scope, adapter) in &self.extra {
            adapter.register(*scope);
            adapters.push(Arc::clone(adapter) as Arc<dyn RecordAdapter>);
        }
        adapters.extend(self.others);
        let keys = self.keys.unwrap_or_default();
        *lock(&keys.proof) = Some(DpopKey(Arc::clone(&seed)));
        let wake = Wake::new();
        let hooks = Arc::new(EngineHooks::new(wake.clone(), None));
        let stop = StopSignal::new();
        let clock = Arc::new(TestClock::default());
        let sync = Arc::new(ServiceSync::new(ServiceParts {
            transport: Arc::clone(&wire) as Arc<dyn ServiceTransport>,
            state: Arc::clone(&state),
            adapters: Adapters::new(adapters),
            keys: Arc::clone(&keys) as Arc<dyn tablepro_sync::api::key_flows::KeyFlows>,
            hooks: Arc::clone(&hooks),
            clock: Arc::clone(&clock) as Arc<dyn Clock>,
            stop: stop.clone(),
            journal: Journal::new(wake),
            events: None,
            categories: tablepro_sync::api::control::SyncCategories {
                off: Vec::new(),
                passwords: true,
            },
            mode: self.mode,
        }));
        Device {
            server: self.server,
            wire,
            state,
            connections,
            connections_file,
            keys,
            hooks,
            stop,
            clock,
            sync,
            seed,
        }
    }
}

impl Device {
    pub async fn new(server: &Arc<FakeServer>, row: &str) -> Self {
        DeviceBuilder::new(server, row).build().await
    }

    // Decides the approval as the person would: on the value `approvals` shows now.
    pub async fn decide(&self, key: RecordKey, field: &str, approve: bool) -> Result<(), SyncError> {
        let seen = self
            .sync
            .approvals()
            .await?
            .into_iter()
            .find(|approval| approval.key == key && approval.field == field)
            .map_or([0; 32], |approval| approval.digest);
        self.sync.decide_approval(key, field.to_owned(), seen, approve).await
    }

    // Resolves the conflict as the person would: as `conflicts` shows it now.
    pub async fn resolve(&self, key: RecordKey, keep: ConflictChoice) -> Result<(), SyncError> {
        let seen = self
            .sync
            .conflicts()
            .await?
            .into_iter()
            .find(|conflict| conflict.key == key)
            .map_or([0; 32], |conflict| conflict.digest);
        self.sync.resolve_conflict(key, seen, keep).await
    }

    pub async fn pass(&self) -> Result<PassReport, SyncError> {
        self.sync
            .run_pass(tablepro_sync::api::control::PassReason::Person)
            .await
    }

    pub async fn sync(&self) -> PassReport {
        self.pass().await.unwrap()
    }

    pub fn proof(&self) -> Proof {
        Proof::Dpop(DpopKey(Arc::clone(&self.seed)))
    }

    // A write straight through this device's sign-in, as another app or flow makes it.
    pub async fn push_raw(&self, scope: ScopeName, changes: Vec<Change>) -> Vec<ChangeOutcome> {
        let batch = PushBatch {
            scope,
            epoch: Some(self.server.epoch()),
            idempotency_key: Some(IdempotencyKey(Uuid::new_v4().to_string())),
            changes,
            proof: self.proof(),
        };
        self.wire.client.push(batch).await.unwrap().outcomes
    }

    pub async fn rows(&self, range: RowRange) -> Vec<Row> {
        self.state.begin().await.unwrap().scan(&range).await.unwrap()
    }

    pub async fn row(&self, key: RowKey) -> Option<Row> {
        self.state.begin().await.unwrap().get(&key).await.unwrap()
    }
}

pub fn write(kind: &str, id: &str, base: Option<ChangeTag>, fields: Value) -> Change {
    Change {
        kind: KindName::parse(kind).unwrap(),
        record_id: id.to_owned(),
        base,
        op: ChangeOp::Write {
            patch: fields.clone(),
            fields,
        },
    }
}

pub fn connection(name: &str) -> Value {
    json!({"name": name, "icon_name": "database", "sort_order": 1})
}

// The state files in `dir`, anchored in `store`, which a restart keeps as the device does.
pub fn files_at(dir: &Path, store: &Arc<FakeDeviceStore>) -> SqliteStateFiles {
    SqliteStateFiles::at(dir.to_path_buf(), Arc::clone(store) as Arc<dyn HostDeviceStore>)
}

pub async fn open_on_disk(dir: &Path, row: &str, store: &Arc<FakeDeviceStore>) -> Arc<dyn StateStore> {
    files_at(dir, store).open(identity(row)).await.unwrap()
}
