// One device of an account against the fake `/v2/sync` server: its own state file, device store and hooks, the
// engine's part of a pull done here, and the approval K7-2 builds stood in for by a direct one.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::{DeviceBody, KeyBody, KeyObject, WrapBody};
use tablepro_keys::cert::DeviceCertificate;
use tablepro_keys::encoding::{AccountId, Origin, TeamId, Version, WrapPurpose};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::wrap::{Wrap, Wrapper, device_target};
use tablepro_sync::api::device_store::{DeviceItem, DeviceStoreError, HostDeviceStore};
use tablepro_sync::api::ids::{DeviceRowId, KindName, ScopeName};
use tablepro_sync::api::key_flows::{
    AccountFlows, ArrivalOrder, KeyApplied, KeyArrival, KeyState, RecoveryKeyDraft, TypedBack,
};
use tablepro_sync::api::scopes::ScopesAnswer;
use tablepro_sync::api::state::{
    KeyDevicePinRow, KeyPinRow, Opened, Row, RowKey, ScopeRow, StateFiles, StateIdentity, StateStore, StateTxn,
};
use tablepro_sync::api::transport::{
    ChangeOutcome, DpopKey, Proof, PullRequest, PulledPage, PulledRecord, PushAnswer, PushBatch, RejectedCode,
    ServiceTransport, Transport, TransportError,
};
use tablepro_sync::keys::{Clock, KeyService, KeyServiceParts, create_change};
use tablepro_sync_testing::{FakeClient, FakeDeviceStore, FakeServer, MemoryStateFiles, RecordingHooks};
use zeroize::Zeroizing;

pub const ORIGIN: &str = "https://sync.example.com";

pub fn origin() -> Origin {
    Origin::parse(ORIGIN).unwrap()
}

pub struct TestClock(AtomicI64);

impl Clock for TestClock {
    fn now_us(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

// The fake client, with every Sign Out revoke recorded by the DSK that proved it.
pub struct Recorded {
    pub client: FakeClient,
    pub revokes: Mutex<Vec<Ed25519Public>>,
    // A check the fake does not make, as the real server's `bad_statement`: the next push is refused whole with it.
    refuse: Mutex<Option<RejectedCode>>,
    // The next push applies on the server and its answer never comes back.
    lose: Mutex<bool>,
}

impl Recorded {
    pub fn refuse_next_push(&self, code: RejectedCode) {
        *self.refuse.lock().unwrap() = Some(code);
    }

    pub fn lose_next_answer(&self) {
        *self.lose.lock().unwrap() = true;
    }
}

#[async_trait]
impl Transport for Recorded {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError> {
        self.client.pull(request).await
    }

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError> {
        if let Some(code) = self.refuse.lock().unwrap().take() {
            let mut outcomes = vec![ChangeOutcome::Rejected { code }];
            outcomes.resize(
                batch.changes.len(),
                ChangeOutcome::Rejected {
                    code: RejectedCode::ChangeSet,
                },
            );
            return Ok(PushAnswer { outcomes });
        }
        let answer = self.client.push(batch).await;
        if std::mem::take(&mut *self.lose.lock().unwrap()) {
            return Err(TransportError::Network {
                detail: "the answer was lost".to_owned(),
            });
        }
        answer
    }
}

#[async_trait]
impl ServiceTransport for Recorded {
    async fn scopes(&self, if_none_match: Option<String>, proof: Proof) -> Result<ScopesAnswer, TransportError> {
        self.client.scopes(if_none_match, proof).await
    }

    async fn revoke_key_device(&self, proof: DpopKey) -> Result<(), TransportError> {
        let public = proof.0.public().unwrap();
        let answer = self.client.revoke_key_device(proof).await;
        if answer.is_ok() {
            self.revokes.lock().unwrap().push(public);
        }
        answer
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

pub struct Device {
    pub service: KeyService,
    pub server: Arc<FakeServer>,
    pub transport: Arc<Recorded>,
    pub hooks: Arc<RecordingHooks>,
    pub store: Arc<FakeDeviceStore>,
    pub state: Arc<dyn StateStore>,
    pub row: DeviceRowId,
    pub account: AccountId,
}

impl Device {
    pub async fn new(server: &Arc<FakeServer>, account: AccountId, row: &str) -> Self {
        Self::with_store(server, account, row, Arc::new(FakeDeviceStore::new())).await
    }

    pub async fn with_store(
        server: &Arc<FakeServer>,
        account: AccountId,
        row: &str,
        store: Arc<FakeDeviceStore>,
    ) -> Self {
        Self::opened(server, account, row, store, Opened::FRESH).await
    }

    // A device whose state file opened as `opened` says, as a stale or unanchored one does.
    pub async fn opened(
        server: &Arc<FakeServer>,
        account: AccountId,
        row: &str,
        store: Arc<FakeDeviceStore>,
        opened: Opened,
    ) -> Self {
        let row = DeviceRowId(row.to_owned());
        let files = MemoryStateFiles::new();
        let identity = StateIdentity::Service {
            origin: origin(),
            sign_in: "sign-in".to_owned(),
            account,
            device_row: row.clone(),
        };
        files.set_opened(identity.clone(), opened);
        let state = files.open(identity).await.unwrap();
        let transport = Arc::new(Recorded {
            client: server.client(account, row.clone()),
            revokes: Mutex::new(Vec::new()),
            refuse: Mutex::new(None),
            lose: Mutex::new(false),
        });
        let hooks = Arc::new(RecordingHooks::default());
        let service = KeyService::new(KeyServiceParts {
            origin: origin(),
            account,
            device_row: row.clone(),
            state: Arc::clone(&state),
            device_store: store.clone(),
            transport: transport.clone(),
            hooks: hooks.clone(),
            clock: Arc::new(TestClock(AtomicI64::new(server.now_us()))),
        });
        Self {
            service,
            server: Arc::clone(server),
            transport,
            hooks,
            store,
            state,
            row,
            account,
        }
    }

    // The same device after its process stopped: the same state file and device store, no flow in memory.
    pub fn restarted(&self) -> Self {
        self.restarted_over(self.store.clone())
    }

    // The same device over its store as `store` reaches it, as one whose deletes fail.
    pub fn restarted_over(&self, store: Arc<dyn HostDeviceStore>) -> Self {
        let service = KeyService::new(KeyServiceParts {
            origin: origin(),
            account: self.account,
            device_row: self.row.clone(),
            state: Arc::clone(&self.state),
            device_store: store,
            transport: self.transport.clone(),
            hooks: self.hooks.clone(),
            clock: Arc::new(TestClock(AtomicI64::new(self.server.now_us()))),
        });
        Self {
            service,
            server: Arc::clone(&self.server),
            transport: Arc::clone(&self.transport),
            hooks: Arc::clone(&self.hooks),
            store: Arc::clone(&self.store),
            state: Arc::clone(&self.state),
            row: self.row.clone(),
            account: self.account,
        }
    }

    pub async fn txn(&self) -> Box<dyn StateTxn> {
        self.state.begin().await.unwrap()
    }

    pub async fn put(&self, rows: Vec<Row>) {
        let mut txn = self.txn().await;
        for row in rows {
            txn.put(row).await.unwrap();
        }
        txn.commit().await.unwrap();
    }

    pub async fn get(&self, key: RowKey) -> Option<Row> {
        self.txn().await.get(&key).await.unwrap()
    }

    pub async fn pin(&self, account: AccountId) -> Option<KeyPinRow> {
        match self.get(RowKey::KeyPin(account)).await {
            Some(Row::KeyPin(pin)) => Some(pin),
            _ => None,
        }
    }

    pub async fn key_state(&self) -> KeyState {
        self.service.key_state().await.unwrap()
    }

    pub async fn proof(&self) -> DpopKey {
        DpopKey(Arc::new(self.service.ensure_device_keys().await.unwrap().dsk))
    }

    // The engine's part of a pass for the personal scope: pages in order, each page's key objects applied, the
    // epoch, cursor and version in force kept.
    pub async fn pull(&self) -> KeyApplied {
        let proof = Proof::Dpop(self.proof().await);
        let mut row = match self.get(RowKey::Scope(ScopeName::Personal)).await {
            Some(Row::Scope(row)) => row,
            _ => ScopeRow::new(ScopeName::Personal),
        };
        let mut last = KeyApplied::default();
        loop {
            let pulled = self
                .transport
                .pull(PullRequest {
                    scope: ScopeName::Personal,
                    cursor: row.cursor.clone(),
                    limit: None,
                    proof: proof.clone(),
                })
                .await;
            // An approval since the cursor was made, or a new epoch, takes the whole scope again (0051, Pull).
            let page = match pulled {
                Err(TransportError::CursorExpired) => {
                    row.cursor = None;
                    continue;
                }
                other => other.unwrap(),
            };
            let order = if row.cursor.is_none() {
                ArrivalOrder::Snapshot
            } else {
                ArrivalOrder::InOrder
            };
            let caught_up = page.caught_up;
            let applied = self
                .service
                .apply_account_objects(KeyArrival {
                    scope: ScopeName::Personal,
                    records: page.records,
                    order,
                    in_force: (order == ArrivalOrder::InOrder).then_some(row.key_version).flatten(),
                })
                .await
                .unwrap();
            row.epoch = Some(self.server.epoch());
            row.cursor = page.cursor.or(row.cursor);
            row.key_version = applied.in_force.or(row.key_version);
            row.caught_up = caught_up;
            self.put(vec![Row::Scope(row.clone())]).await;
            last.held.extend(applied.held);
            last.refused.extend(applied.refused);
            last.in_force = applied.in_force;
            if caught_up {
                return last;
            }
        }
    }

    // Every record the server serves this device from a snapshot of the personal scope, applied to nothing.
    pub async fn served(&self) -> Vec<PulledRecord> {
        let proof = Proof::Dpop(self.proof().await);
        let mut cursor = None;
        let mut records = Vec::new();
        loop {
            let page = self
                .transport
                .pull(PullRequest {
                    scope: ScopeName::Personal,
                    cursor: cursor.clone(),
                    limit: None,
                    proof: proof.clone(),
                })
                .await
                .unwrap();
            records.extend(page.records);
            if page.caught_up {
                return records;
            }
            cursor = page.cursor;
        }
    }

    // The engine's part of a pass for the personal scope with its envelopes: key objects applied in revision order, each
    // envelope opened under the version in force at its place, none in a snapshot. Each envelope's id with its secret
    // or its error code.
    pub async fn pull_with_envelopes(&self) -> Vec<(String, Result<String, &'static str>)> {
        let proof = Proof::Dpop(self.proof().await);
        let mut row = match self.get(RowKey::Scope(ScopeName::Personal)).await {
            Some(Row::Scope(row)) => row,
            _ => ScopeRow::new(ScopeName::Personal),
        };
        let mut opened = Vec::new();
        loop {
            let page = self
                .transport
                .pull(PullRequest {
                    scope: ScopeName::Personal,
                    cursor: row.cursor.clone(),
                    limit: None,
                    proof: proof.clone(),
                })
                .await
                .unwrap();
            let order = if row.cursor.is_none() {
                ArrivalOrder::Snapshot
            } else {
                ArrivalOrder::InOrder
            };
            let (in_force, page_opened) = self.feed_with_envelopes(page.records, order, row.key_version).await;
            opened.extend(page_opened);
            row.epoch = Some(self.server.epoch());
            row.cursor = page.cursor.or(row.cursor);
            row.key_version = in_force;
            row.caught_up = page.caught_up;
            self.put(vec![Row::Scope(row.clone())]).await;
            if page.caught_up {
                return opened;
            }
        }
    }

    // A page as the engine splits it: each run of key objects applied, then each envelope opened at its place.
    pub async fn feed_with_envelopes(
        &self,
        records: Vec<PulledRecord>,
        order: ArrivalOrder,
        mut in_force: Option<Version>,
    ) -> (Option<Version>, Vec<(String, Result<String, &'static str>)>) {
        let mut opened = Vec::new();
        let mut keys = Vec::new();
        for record in records {
            if record.kind.is_key() {
                keys.push(record);
                continue;
            }
            if !keys.is_empty() {
                in_force = self.feed(std::mem::take(&mut keys), order).await.in_force.or(in_force);
            }
            if record.kind.as_str() != "secret_envelope" {
                continue;
            }
            let at = if order == ArrivalOrder::Snapshot {
                None
            } else {
                in_force
            };
            let id = tablepro_keys::envelope::EnvelopeId::parse(&record.record_id).unwrap();
            let result = self
                .service
                .open_personal_envelope(id, record.fields.clone().unwrap(), at)
                .await
                .map(|envelope| envelope.secret.expose_secret().to_owned())
                .map_err(|error| error.code());
            opened.push((record.record_id, result));
        }
        if !keys.is_empty() {
            in_force = self.feed(keys, order).await.in_force.or(in_force);
        }
        (in_force, opened)
    }

    // What a hostile server serves, straight to the key layer.
    pub async fn feed(&self, records: Vec<PulledRecord>, order: ArrivalOrder) -> KeyApplied {
        self.service
            .apply_account_objects(KeyArrival {
                scope: ScopeName::Personal,
                records,
                order,
                in_force: None,
            })
            .await
            .unwrap()
    }

    // Genesis as the person runs it, the two groups typed back right. Returns R's text.
    pub async fn genesis(&self) -> SecretString {
        self.pull().await;
        let draft = self.service.begin_genesis().await.unwrap();
        let typed = typed_back(&draft);
        self.service.finish_genesis(draft.draft, typed).await.unwrap();
        self.server_approves().await;
        draft.text
    }

    // What the real server does once a change set certifies this row's key device at the current `av`.
    pub async fn server_approves(&self) {
        let device = self.service.device_keys().await.unwrap().current.unwrap();
        self.server.approve(&self.row, device.dsk.public().unwrap().0);
    }

    // K7-2's approval, stood in for: `approver` certifies this device at its `av` and wraps the account keys to it
    // under its own DSK, and each side keeps the other as an own-device pin.
    pub async fn approved_by(&self, approver: &Device) {
        let mut txn = approver.txn().await;
        let own = approver.service.own_account(txn.as_mut()).await.unwrap().unwrap();
        let pin = approver.pin(approver.account).await.unwrap();
        let mut versions = Vec::new();
        for purpose in [
            tablepro_keys::encoding::KeyPurpose::Personal,
            tablepro_keys::encoding::KeyPurpose::History,
        ] {
            if let Some(row) = txn
                .get(&RowKey::KeyVersion(ScopeName::Personal, purpose))
                .await
                .unwrap()
            {
                versions.push(row);
            }
        }
        drop(txn);
        let device = self.service.ensure_device_keys().await.unwrap();
        let certificate = DeviceCertificate::sign(
            &origin(),
            self.account,
            own.av,
            device.key_device,
            device.dek.public().unwrap(),
            device.dsk.public().unwrap(),
            &own.keys.ask,
        )
        .unwrap();
        let target = device_target(self.account, WrapPurpose::Account, own.av, device.key_device);
        let wrap = Wrap::seal_account(
            &origin(),
            target,
            &device.dek.public().unwrap(),
            &own.keys,
            Wrapper {
                account: self.account,
                av: own.av,
                key_device: own.device.key_device,
            },
            &own.device.dsk,
        )
        .unwrap();
        let objects = [
            KeyObject {
                id: KeyRecordId::Device {
                    account: self.account,
                    key_device: device.key_device,
                    av: own.av,
                },
                body: KeyBody::Device(DeviceBody::of(&certificate)),
            },
            KeyObject {
                id: KeyRecordId::Wrap(target),
                body: KeyBody::Wrap(WrapBody::of(&wrap)),
            },
        ];
        let changes = objects.iter().map(|object| create_change(object).unwrap()).collect();
        approver.pull().await;
        let outcomes = approver
            .service
            .push_change_set(ScopeName::Personal, changes, approver.proof().await)
            .await
            .unwrap();
        assert!(
            outcomes
                .iter()
                .all(|outcome| matches!(outcome, tablepro_sync::api::transport::ChangeOutcome::Applied { .. }))
        );
        approver
            .put(vec![Row::KeyDevicePin(KeyDevicePinRow {
                key_device: device.key_device,
                dek: device.dek.public().unwrap(),
                dsk: device.dsk.public().unwrap(),
            })])
            .await;
        self.service.store_account_keys(own.av, &own.keys).await.unwrap();
        let mut rows = vec![
            Row::KeyPin(pin),
            Row::KeyDevicePin(KeyDevicePinRow {
                key_device: own.device.key_device,
                dek: own.device.dek.public().unwrap(),
                dsk: own.device.dsk.public().unwrap(),
            }),
        ];
        rows.extend(versions);
        self.put(rows).await;
        self.server_approves().await;
        self.pull().await;
    }
}

pub fn typed_back(draft: &RecoveryKeyDraft) -> TypedBack {
    let groups: Vec<String> = draft.text.expose_secret().split('-').map(str::to_owned).collect();
    TypedBack {
        groups: draft
            .check
            .map(|index| SecretString::from(groups[usize::from(index)].to_lowercase())),
    }
}

pub fn record(kind: &str, record_id: &str, fields_json: &str) -> PulledRecord {
    PulledRecord {
        kind: KindName::parse(kind).unwrap(),
        record_id: record_id.to_owned(),
        tag: tablepro_sync::api::ids::ChangeTag::Service("tag".to_owned()),
        fields: Some(serde_json::from_str(fields_json).unwrap()),
        fields_json: Some(fields_json.to_owned()),
        deleted: None,
        service: None,
    }
}

pub fn record_of(object: &KeyObject) -> PulledRecord {
    record(object.id.kind().name(), &object.id.to_wire(), &object.fields_json())
}

pub fn account_id(text: &str) -> AccountId {
    AccountId::from_wire(text).unwrap()
}

pub fn new_account() -> AccountId {
    AccountId(tablepro_keys::encoding::random_uuid().unwrap())
}

pub fn stored(server: &FakeServer, account: AccountId, kind: &str, id: &str) -> KeyObject {
    let stored = server
        .stored(tablepro_sync_testing::service::ScopeOwner::Personal(account), kind, id)
        .unwrap();
    let text = serde_json::to_string(stored.fields.as_ref().unwrap()).unwrap();
    KeyObject::parse(kind, id, text.as_bytes()).unwrap()
}

pub fn refused_codes(applied: &KeyApplied) -> Vec<&'static str> {
    applied.refused.iter().map(|refused| refused.error.code()).collect()
}

// The device's store with its next delete failing, as a process cut off partway through erasing does.
pub struct CutOff {
    pub store: Arc<FakeDeviceStore>,
    pub armed: Mutex<bool>,
}

#[async_trait]
impl HostDeviceStore for CutOff {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        self.store.load(item).await
    }

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        self.store.store(item, value).await
    }

    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError> {
        if std::mem::take(&mut *self.armed.lock().unwrap()) {
            return Err(DeviceStoreError::Failed {
                detail: "cut off".to_owned(),
            });
        }
        self.store.delete(item).await
    }

    fn present(&self) -> bool {
        self.store.present()
    }
}

pub fn stored_certificate(
    server: &FakeServer,
    account: AccountId,
    av: Version,
) -> tablepro_keys::cert::AccountCertificate {
    let object = stored(server, account, "key.account", &format!("{}/{av}", account.to_wire()));
    match object.body {
        KeyBody::Account(body) => Some(body.certificate(account, av)),
        _ => None,
    }
    .unwrap()
}

pub fn stored_blob(server: &FakeServer, account: AccountId, av: Version) -> tablepro_keys::recovery::RecoveryBlob {
    let object = stored(server, account, "key.recovery", &format!("{}/{av}", account.to_wire()));
    match object.body {
        KeyBody::Recovery(blob) => Some(blob),
        _ => None,
    }
    .unwrap()
}

// The device's store as one session sees it: away entirely, or counting its deletes.
pub struct Watched {
    pub store: Arc<FakeDeviceStore>,
    pub away: bool,
    pub deletes: Mutex<usize>,
}

#[async_trait]
impl HostDeviceStore for Watched {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        self.reach()?;
        self.store.load(item).await
    }

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        self.reach()?;
        self.store.store(item, value).await
    }

    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError> {
        self.reach()?;
        *self.deletes.lock().unwrap() += 1;
        self.store.delete(item).await
    }

    fn present(&self) -> bool {
        self.store.present()
    }
}

impl Watched {
    fn reach(&self) -> Result<(), DeviceStoreError> {
        if self.away {
            Err(DeviceStoreError::Unavailable {
                detail: "no Secret Service this session".to_owned(),
            })
        } else {
            Ok(())
        }
    }
}
