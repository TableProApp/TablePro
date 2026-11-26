// Just enough of a `KeyService`'s parts for the restore and stop flows: a state file in memory whose transactions
// commit whole, a service transport that answers the scopes body and records stop reports and withdrawals, and hooks
// that record each call. `tablepro-sync-testing` has fuller fakes, which a unit test of this crate cannot link.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_keys::encoding::{AccountId, Origin, TeamId, Version};
use tablepro_keys::keys::Ed25519Seed;
use tablepro_keys::record_id::KeyRecordId;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::api::device_store::{DeviceItem, DeviceStoreError, HostDeviceStore};
use crate::api::error::StateError;
use crate::api::ids::{DeviceRowId, EpochId, ScopeName};
use crate::api::key_flows::{KeyHooks, KeyNotice, LockCause};
use crate::api::scopes::{ScopesAnswer, ScopesBody};
use crate::api::state::{
    Committed, Opened, Row, RowKey, RowRange, StateIdentity, StateStore, StateTxn, StoppedCause, Table,
};
use crate::api::transport::{
    DpopKey, Proof, PullRequest, PulledPage, PushAnswer, PushBatch, ServiceTransport, Transport, TransportError,
};
use crate::keys::restore::plan::ServerView;
use crate::keys::{Clock, KeyService, KeyServiceParts};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

type Rows = BTreeMap<(Table, Vec<u8>), Row>;

pub(crate) struct MemoryState {
    identity: StateIdentity,
    rows: Arc<Mutex<Rows>>,
}

struct MemoryTxn {
    committed: Arc<Mutex<Rows>>,
    rows: Rows,
}

fn slot(key: &RowKey) -> (Table, Vec<u8>) {
    (key.table(), key.encoded())
}

#[async_trait]
impl StateStore for MemoryState {
    fn identity(&self) -> &StateIdentity {
        &self.identity
    }

    fn opened(&self) -> &Opened {
        &Opened::FRESH
    }

    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        Ok(Box::new(MemoryTxn {
            rows: lock(&self.rows).clone(),
            committed: Arc::clone(&self.rows),
        }))
    }
}

#[async_trait]
impl StateTxn for MemoryTxn {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        Ok(self.rows.get(&slot(key)).cloned())
    }

    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        Ok(self
            .rows
            .values()
            .filter(|row| range.contains(&row.key()))
            .cloned()
            .collect())
    }

    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        self.rows.insert(slot(&row.key()), row);
        Ok(())
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        self.rows.remove(&slot(key));
        Ok(())
    }

    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        self.rows.retain(|(table, _), _| !table.is_key_table());
        Ok(())
    }

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        *lock(&self.committed) = self.rows;
        Ok(Committed { counter: 1 })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Sent {
    Report(TeamId, Version),
    Withdraw(TeamId),
}

#[derive(Default)]
pub(crate) struct Service {
    pub body: Mutex<Option<ScopesBody>>,
    pub sent: Mutex<Vec<Sent>>,
    // The next withdrawal's answer is lost, as a crash or a dropped connection would lose it.
    pub lose_next_answer: Mutex<bool>,
}

#[async_trait]
impl Transport for Service {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError> {
        let _ = request;
        Err(TransportError::NotFound)
    }

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError> {
        let _ = batch;
        Err(TransportError::NotFound)
    }
}

#[async_trait]
impl ServiceTransport for Service {
    async fn scopes(&self, if_none_match: Option<String>, proof: Proof) -> Result<ScopesAnswer, TransportError> {
        let _ = (if_none_match, proof);
        let body = lock(&self.body).clone().ok_or(TransportError::NotFound)?;
        Ok(ScopesAnswer::Body {
            body: Box::new(body),
            etag: String::new(),
        })
    }

    async fn revoke_key_device(&self, proof: DpopKey) -> Result<(), TransportError> {
        let _ = proof;
        Ok(())
    }

    async fn report_stopped(&self, team: TeamId, version: Version, proof: DpopKey) -> Result<(), TransportError> {
        let _ = proof;
        lock(&self.sent).push(Sent::Report(team, version));
        Ok(())
    }

    async fn withdraw_stopped(&self, team: TeamId, proof: DpopKey) -> Result<(), TransportError> {
        let _ = proof;
        lock(&self.sent).push(Sent::Withdraw(team));
        if std::mem::take(&mut *lock(&self.lose_next_answer)) {
            return Err(TransportError::Network {
                detail: "answer lost".to_owned(),
            });
        }
        Ok(())
    }

    async fn remove_device_row(&self, device: DeviceRowId, proof: DpopKey) -> Result<(), TransportError> {
        let _ = (device, proof);
        Err(TransportError::NotFound)
    }
}

#[derive(Default)]
pub(crate) struct MemoryDeviceStore(Mutex<HashMap<DeviceItem, Zeroizing<Vec<u8>>>>);

#[async_trait]
impl HostDeviceStore for MemoryDeviceStore {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        Ok(lock(&self.0).get(&item).cloned())
    }

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        lock(&self.0).insert(item, value);
        Ok(())
    }

    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError> {
        lock(&self.0).remove(&item);
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Hook {
    Lock(LockCause),
    Stop(ScopeName, StoppedCause),
    Resume(ScopeName),
    End(ScopeName, Option<EpochId>),
    Notice(KeyNotice),
    PassSoon,
}

#[derive(Default)]
pub(crate) struct Hooks(Mutex<Vec<Hook>>);

impl Hooks {
    pub fn calls(&self) -> Vec<Hook> {
        lock(&self.0).clone()
    }

    pub fn without_notices(&self) -> Vec<Hook> {
        self.calls()
            .into_iter()
            .filter(|call| !matches!(call, Hook::Notice(_) | Hook::PassSoon))
            .collect()
    }
}

impl KeyHooks for Hooks {
    fn lock(&self, cause: LockCause) {
        lock(&self.0).push(Hook::Lock(cause));
    }

    fn stop_scope(&self, scope: ScopeName, cause: StoppedCause) {
        lock(&self.0).push(Hook::Stop(scope, cause));
    }

    fn resume_scope(&self, scope: ScopeName) {
        lock(&self.0).push(Hook::Resume(scope));
    }

    fn end_scope(&self, scope: ScopeName, epoch: Option<EpochId>) {
        lock(&self.0).push(Hook::End(scope, epoch));
    }

    fn notice(&self, notice: KeyNotice) {
        lock(&self.0).push(Hook::Notice(notice));
    }

    fn pass_soon(&self) {
        lock(&self.0).push(Hook::PassSoon);
    }
}

struct FixedClock;

impl Clock for FixedClock {
    fn now_us(&self) -> i64 {
        1_767_225_600_000_000
    }
}

pub(crate) struct Rig {
    pub service: Arc<KeyService>,
    pub transport: Arc<Service>,
    pub hooks: Arc<Hooks>,
}

impl Rig {
    pub fn new(origin: &Origin, account: AccountId) -> Self {
        let rows = Arc::new(Mutex::new(Rows::new()));
        let device_row = DeviceRowId("dev_1".to_owned());
        let state = Arc::new(MemoryState {
            identity: StateIdentity::Service {
                origin: origin.clone(),
                sign_in: "sign-in".to_owned(),
                account,
                device_row: device_row.clone(),
            },
            rows,
        });
        let transport = Arc::new(Service::default());
        let hooks = Arc::new(Hooks::default());
        let service = Arc::new(KeyService::new(KeyServiceParts {
            origin: origin.clone(),
            account,
            device_row,
            state,
            device_store: Arc::new(MemoryDeviceStore::default()),
            transport: Arc::clone(&transport) as Arc<dyn ServiceTransport>,
            hooks: Arc::clone(&hooks) as Arc<dyn KeyHooks>,
            clock: Arc::new(FixedClock),
        }));
        Self {
            service,
            transport,
            hooks,
        }
    }

    pub async fn put(&self, rows: impl IntoIterator<Item = Row>) {
        let mut txn = self.service.begin().await.unwrap();
        for row in rows {
            txn.put(row).await.unwrap();
        }
        txn.commit().await.unwrap();
    }

    pub async fn get(&self, key: &RowKey) -> Option<Row> {
        self.service.begin().await.unwrap().get(key).await.unwrap()
    }
}

pub(crate) fn scopes(epoch: EpochId, scopes: Vec<crate::api::scopes::ScopeInfo>) -> ScopesBody {
    ScopesBody {
        epoch,
        scopes,
        limits: crate::api::scopes::ServerLimits::ADR_0051,
        server_version: "test".to_owned(),
        capabilities: Vec::new(),
        idempotency_retention_secs: 86_400,
        poll_interval_secs: 60,
    }
}

pub(crate) fn epoch(n: u128) -> EpochId {
    EpochId(Uuid::from_u128(n))
}

pub(crate) fn dpop() -> DpopKey {
    DpopKey(Arc::new(Ed25519Seed::from_bytes([7; 32])))
}

// A server that holds exactly the objects it is told to.
#[derive(Default)]
pub(crate) struct Holds(HashSet<(ScopeName, String)>);

impl Holds {
    pub fn with(mut self, scope: ScopeName, ids: impl IntoIterator<Item = KeyRecordId>) -> Self {
        for id in ids {
            self.0.insert((scope, format!("{}:{}", id.kind().name(), id.to_wire())));
        }
        self
    }
}

impl ServerView for Holds {
    fn holds(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        self.0
            .contains(&(scope, format!("{}:{}", id.kind().name(), id.to_wire())))
    }

    fn judged(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        let _ = (scope, id);
        true
    }
}

// A server the device has no bases for at all.
pub(crate) struct Unjudged;

impl ServerView for Unjudged {
    fn holds(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        let _ = (scope, id);
        false
    }

    fn judged(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        let _ = (scope, id);
        false
    }
}
