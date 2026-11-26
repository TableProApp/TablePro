// Devices of one account against the fake `/v2/sync` server: each with its own state file, device store and hooks,
// the engine's part of a pull done here, and the checks the fake leaves to the real server stood in for by a refusal
// the test sets.

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::KeyObject;
use tablepro_keys::encoding::{AccountId, Origin, RequestId, TeamId, Version};
use tablepro_sync::api::device_store::{DeviceItem, DeviceStoreError, HostDeviceStore};
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::{DeviceRowId, ScopeName};
use tablepro_sync::api::key_flows::{
    AccountFlows, ApprovalFlows, ArrivalOrder, KeyApplied, KeyArrival, KeyState, RecoveryKeyDraft, ResetFlows, Roster,
    SessionPhase, TeamFlows, TypedBack,
};
use tablepro_sync::api::scopes::ScopesAnswer;
use tablepro_sync::api::scopes::{Role, TeamMember};
use tablepro_sync::api::state::{
    Committed, KeyDevicePinRow, KeyPinRow, Opened, Row, RowKey, RowRange, ScopeRow, StateFiles, StateIdentity,
    StateStore, StateTxn, Table,
};
use tablepro_sync::api::transport::{
    Change, ChangeOutcome, DpopKey, Proof, PullRequest, PulledPage, PushAnswer, PushBatch, RejectedCode,
    ServiceTransport, Transport, TransportError,
};
use tablepro_sync::keys::{Clock, KeyService, KeyServiceParts};
use tablepro_sync_testing::service::ScopeOwner;
use tablepro_sync_testing::{FakeClient, FakeDeviceStore, FakeServer, MemoryStateFiles, RecordingHooks};
use zeroize::Zeroizing;

pub const ORIGIN: &str = "https://sync.example.com";

// A state file whose next commit can be made to fail, as a crash between two writes would leave it.
pub struct Flaky {
    inner: Arc<dyn StateStore>,
    fail_commit: Arc<AtomicBool>,
}

#[async_trait]
impl StateStore for Flaky {
    fn identity(&self) -> &StateIdentity {
        self.inner.identity()
    }

    fn opened(&self) -> &Opened {
        self.inner.opened()
    }

    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        Ok(Box::new(FlakyTxn {
            inner: self.inner.begin().await?,
            fail_commit: Arc::clone(&self.fail_commit),
        }))
    }
}

struct FlakyTxn {
    inner: Box<dyn StateTxn>,
    fail_commit: Arc<AtomicBool>,
}

#[async_trait]
impl StateTxn for FlakyTxn {
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

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        if self.fail_commit.swap(false, Ordering::SeqCst) {
            return Err(StateError::Io {
                detail: "the commit did not land".to_owned(),
            });
        }
        self.inner.commit().await
    }
}

// The device store, whose next write of the device keys can be made to fail.
pub struct Store {
    pub inner: Arc<FakeDeviceStore>,
    fail_device_keys: AtomicBool,
}

#[async_trait]
impl HostDeviceStore for Store {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        self.inner.load(item).await
    }

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        if matches!(item, DeviceItem::DeviceKeys { .. }) && self.fail_device_keys.swap(false, Ordering::SeqCst) {
            return Err(DeviceStoreError::Failed {
                detail: "the write did not land".to_owned(),
            });
        }
        self.inner.store(item, value).await
    }

    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError> {
        self.inner.delete(item).await
    }
}

pub fn origin() -> Origin {
    Origin::parse(ORIGIN).unwrap()
}

// The device's clock follows the server's, as a synced clock does.
pub struct ServerClock(Arc<FakeServer>, AtomicI64);

impl Clock for ServerClock {
    fn now_us(&self) -> i64 {
        self.0.now_us() + self.1.load(Ordering::SeqCst)
    }
}

// The fake client, with every push it sent kept and a refusal the real server would make set by the test.
pub struct Wire {
    pub client: FakeClient,
    pub pushed: Mutex<Vec<Vec<Change>>>,
    refuse: Mutex<Option<RejectedCode>>,
    fail: Mutex<Option<TransportError>>,
    lose: AtomicBool,
    // Counts down the pushes before the one whose answer is lost; 0 loses none.
    lose_after: AtomicI64,
}

impl Wire {
    // The server applies the push `skip` pushes from now, and its answer never arrives.
    pub fn lose_answer_after(&self, skip: i64) {
        self.lose_after.store(skip + 1, Ordering::SeqCst);
    }

    // The server applies the next push and its answer never arrives.
    pub fn lose_next_answer(&self) {
        self.lose.store(true, Ordering::SeqCst);
    }

    pub fn refuse_next_push(&self, code: RejectedCode) {
        *self.refuse.lock().unwrap() = Some(code);
    }

    pub fn fail_next_push(&self, error: TransportError) {
        *self.fail.lock().unwrap() = Some(error);
    }

    // The last push's changes by kind and record id, whatever order they went up in.
    pub fn last_push_by_id(&self) -> Vec<(String, String, String)> {
        let mut changes: Vec<(String, String, String)> = self
            .pushed
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .iter()
            .map(|change| {
                (
                    change.kind.as_str().to_owned(),
                    change.record_id.clone(),
                    format!("{:?}", change.op),
                )
            })
            .collect();
        changes.sort();
        changes
    }
}

#[async_trait]
impl Transport for Wire {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError> {
        self.client.pull(request).await
    }

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError> {
        if let Some(error) = self.fail.lock().unwrap().take() {
            return Err(error);
        }
        self.pushed.lock().unwrap().push(batch.changes.clone());
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
        let countdown = self.lose_after.load(Ordering::SeqCst);
        if countdown > 0 {
            self.lose_after.store(countdown - 1, Ordering::SeqCst);
        }
        if self.lose.swap(false, Ordering::SeqCst) || countdown == 1 {
            return Err(TransportError::Network {
                detail: "the answer was lost".to_owned(),
            });
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

pub struct Device {
    pub service: KeyService,
    pub server: Arc<FakeServer>,
    pub wire: Arc<Wire>,
    pub hooks: Arc<RecordingHooks>,
    pub state: Arc<dyn StateStore>,
    pub store: Arc<Store>,
    pub row: DeviceRowId,
    pub account: AccountId,
    files: Arc<MemoryStateFiles>,
    fail_commit: Arc<AtomicBool>,
    skew: Arc<ServerClock>,
}

impl Device {
    pub async fn new(server: &Arc<FakeServer>, account: AccountId, row: &str) -> Self {
        let row = DeviceRowId(row.to_owned());
        let wire = Arc::new(Wire {
            client: server.client(account, row.clone()),
            pushed: Mutex::new(Vec::new()),
            refuse: Mutex::new(None),
            fail: Mutex::new(None),
            lose: AtomicBool::new(false),
            lose_after: AtomicI64::new(0),
        });
        let store = Arc::new(Store {
            inner: Arc::new(FakeDeviceStore::new()),
            fail_device_keys: AtomicBool::new(false),
        });
        let clock = Arc::new(ServerClock(Arc::clone(server), AtomicI64::new(0)));
        Self::open(
            server,
            account,
            row,
            wire,
            store,
            Arc::new(MemoryStateFiles::new()),
            clock,
            Opened::FRESH,
        )
        .await
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "every part a device is built from, kept across a reopen"
    )]
    async fn open(
        server: &Arc<FakeServer>,
        account: AccountId,
        row: DeviceRowId,
        wire: Arc<Wire>,
        store: Arc<Store>,
        files: Arc<MemoryStateFiles>,
        clock: Arc<ServerClock>,
        opened: Opened,
    ) -> Self {
        let identity = StateIdentity::Service {
            origin: origin(),
            sign_in: "sign-in".to_owned(),
            account,
            device_row: row.clone(),
        };
        files.set_opened(identity.clone(), opened);
        let fail_commit = Arc::new(AtomicBool::new(false));
        let state: Arc<dyn StateStore> = Arc::new(Flaky {
            inner: files.open(identity).await.unwrap(),
            fail_commit: Arc::clone(&fail_commit),
        });
        let hooks = Arc::new(RecordingHooks::default());
        let service = KeyService::new(KeyServiceParts {
            origin: origin(),
            account,
            device_row: row.clone(),
            state: Arc::clone(&state),
            device_store: store.clone(),
            transport: wire.clone(),
            hooks: hooks.clone(),
            clock: clock.clone(),
        });
        Self {
            service,
            server: Arc::clone(server),
            wire,
            hooks,
            state,
            store,
            row,
            account,
            files,
            fail_commit,
            skew: clock,
        }
    }

    // The same device after a restart whose state file opened as `opened` says, its device store as it was.
    pub async fn reopen(self, opened: Opened) -> Self {
        Self::open(
            &self.server,
            self.account,
            self.row,
            self.wire,
            self.store,
            self.files,
            self.skew,
            opened,
        )
        .await
    }

    pub fn fail_next_commit(&self) {
        self.fail_commit.store(true, Ordering::SeqCst);
    }

    pub fn fail_next_device_keys_write(&self) {
        self.store.fail_device_keys.store(true, Ordering::SeqCst);
    }

    // The team as the engine meets it: its scope row from the scopes body and the roster read once caught up.
    pub async fn join_team(&self, team: TeamId, members: &[(AccountId, Role)]) {
        let role = members
            .iter()
            .find(|(account, _)| *account == self.account)
            .map(|(_, role)| *role);
        let mut row = ScopeRow::new(ScopeName::Team(team));
        row.role = role;
        row.epoch = Some(self.server.epoch());
        row.caught_up = true;
        let mut txn = self.txn().await;
        txn.put(Row::Scope(row)).await.unwrap();
        txn.commit().await.unwrap();
        let scope = ScopeName::Team(team);
        let info = tablepro_sync::api::scopes::ScopeInfo {
            scope,
            role,
            horizon: 0,
            epochs: vec![tablepro_sync::api::scopes::LineageEpoch {
                id: self.server.epoch(),
                kept_revision: 0,
            }],
            writable: true,
            policies: tablepro_sync::api::scopes::ScopePolicies::default(),
            quota: None,
            rotation_due: false,
            members: members
                .iter()
                .map(|(account, role)| TeamMember {
                    account: *account,
                    role: *role,
                })
                .collect(),
            stopped: Vec::new(),
            approved: None,
        };
        let page = tablepro_sync::api::transport::PulledPage {
            records: Vec::new(),
            cursor: None,
            changes_cursor: None,
            caught_up: true,
            unread: Vec::new(),
        };
        let caught_up = tablepro_sync::api::key_flows::CaughtUp::from_page(scope, &page);
        self.service
            .roster_read(team, Roster::of(&info, caught_up))
            .await
            .unwrap();
    }

    pub async fn txn(&self) -> Box<dyn StateTxn> {
        self.state.begin().await.unwrap()
    }

    pub async fn get(&self, key: RowKey) -> Option<Row> {
        self.txn().await.get(&key).await.unwrap()
    }

    pub async fn rows(&self, table: Table) -> Vec<Row> {
        self.txn().await.scan(&RowRange::Table(table)).await.unwrap()
    }

    pub async fn pin(&self, account: AccountId) -> Option<KeyPinRow> {
        match self.get(RowKey::KeyPin(account)).await {
            Some(Row::KeyPin(pin)) => Some(pin),
            _ => None,
        }
    }

    pub async fn device_pins(&self) -> Vec<KeyDevicePinRow> {
        self.rows(Table::KeyDevicePins)
            .await
            .into_iter()
            .filter_map(|row| match row {
                Row::KeyDevicePin(pin) => Some(pin),
                _ => None,
            })
            .collect()
    }

    pub async fn key_state(&self) -> KeyState {
        self.service.key_state().await.unwrap()
    }

    pub async fn av(&self) -> u32 {
        let state = self.key_state().await;
        assert!(matches!(state, KeyState::Approved { .. }), "not approved: {state:?}");
        match state {
            KeyState::Approved { av, .. } => av.get(),
            _ => 0,
        }
    }

    // A pull proves with the keys in force, the approval's when they are pending, else any key (0051).
    pub async fn proof(&self) -> DpopKey {
        let held = self.service.device_keys().await.unwrap();
        let keys = match held.current.or(held.pending) {
            Some(keys) => keys,
            None => self.service.ensure_device_keys().await.unwrap(),
        };
        DpopKey(Arc::new(keys.dsk))
    }

    // The engine's part of a pass over the personal scope: pages in order, each page's key objects given to every
    // key layer that reads them, and the epoch, cursor and version in force kept.
    pub async fn pull(&self) -> KeyApplied {
        let proof = Proof::Dpop(self.proof().await);
        let mut row = match self.get(RowKey::Scope(ScopeName::Personal)).await {
            Some(Row::Scope(row)) => row,
            _ => ScopeRow::new(ScopeName::Personal),
        };
        let mut all = KeyApplied::default();
        loop {
            let pulled = self
                .wire
                .pull(PullRequest {
                    scope: ScopeName::Personal,
                    cursor: row.cursor.clone(),
                    limit: None,
                    proof: proof.clone(),
                })
                .await;
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
            let arrival = KeyArrival {
                scope: ScopeName::Personal,
                records: page.records.clone(),
                order,
                in_force: (order == ArrivalOrder::InOrder).then_some(row.key_version).flatten(),
            };
            let mut applied = self.service.apply_account_objects(arrival.clone()).await.unwrap();
            for more in [
                self.service.apply_session_objects(arrival.clone()).await.unwrap(),
                self.service.apply_reset_objects(arrival).await.unwrap(),
            ] {
                applied.refused.extend(more.refused);
                applied.held.extend(more.held);
            }
            row.epoch = Some(self.server.epoch());
            row.cursor = page.cursor.or(row.cursor);
            row.key_version = applied.in_force.or(row.key_version);
            row.caught_up = page.caught_up;
            let mut txn = self.txn().await;
            txn.put(Row::Scope(row.clone())).await.unwrap();
            txn.commit().await.unwrap();
            all.held.extend(applied.held);
            all.refused.extend(applied.refused);
            all.in_force = applied.in_force;
            if page.caught_up {
                return all;
            }
        }
    }

    // Genesis as the person runs it. Returns R's text.
    pub async fn genesis(&self) -> SecretString {
        self.pull().await;
        let draft = self.service.begin_genesis().await.unwrap();
        let typed = typed_back(&draft);
        self.service.finish_genesis(draft.draft, typed).await.unwrap();
        self.server_approves().await;
        self.pull().await;
        draft.text
    }

    // What the real server does once a change set certifies this row's key device at the current `av`.
    pub async fn server_approves(&self) {
        let device = self.service.device_keys().await.unwrap().current.unwrap();
        self.server.approve(&self.row, device.dsk.public().unwrap().0);
    }

    pub fn advance(&self, micros: i64) {
        self.skew.1.fetch_add(micros, Ordering::SeqCst);
    }

    pub async fn words(&self, request: RequestId) -> Vec<String> {
        let phase = self.service.approval_session(request).await.unwrap().phase;
        assert!(
            matches!(phase, SessionPhase::Compare { .. }),
            "no words to compare: {phase:?}"
        );
        match phase {
            SessionPhase::Compare { words } => words,
            _ => Vec::new(),
        }
    }

    pub async fn pending_reset_state(&self) -> Option<tablepro_sync::api::key_flows::ResetState> {
        self.service.pending_reset().await.unwrap().map(|reset| reset.state)
    }
}

// N asks, A picks the request, both compare the same words and confirm: the whole session as two people run it.
pub async fn approve(n: &Device, a: &Device) -> RequestId {
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    let n_words = n.words(request).await;
    a.pull().await;
    let a_words = a.words(request).await;
    assert_eq!(n_words, a_words);
    a.service.confirm_session(request).await.unwrap();
    n.pull().await;
    let session = n.service.confirm_session(request).await.unwrap();
    assert_eq!(session.phase, SessionPhase::Approved);
    n.server_approves().await;
    n.pull().await;
    request
}

pub fn typed_back(draft: &RecoveryKeyDraft) -> TypedBack {
    let groups: Vec<String> = draft.text.expose_secret().split('-').map(str::to_owned).collect();
    TypedBack {
        groups: draft
            .check
            .map(|index| SecretString::from(groups[usize::from(index)].to_lowercase())),
    }
}

pub fn new_account() -> AccountId {
    AccountId(tablepro_keys::encoding::random_uuid().unwrap())
}

pub fn stored(server: &FakeServer, account: AccountId, kind: &str, id: &str) -> Option<KeyObject> {
    let stored = server.stored(ScopeOwner::Personal(account), kind, id)?;
    let text = serde_json::to_string(stored.fields.as_ref()?).unwrap();
    Some(KeyObject::parse(kind, id, text.as_bytes()).unwrap())
}

// A reset proposal as a person makes it, R' typed back.
pub async fn propose_reset(
    device: &Device,
    kind: tablepro_sync::api::key_flows::ResetKind,
) -> tablepro_sync::api::key_flows::PendingReset {
    let draft = device.service.begin_reset(kind).await.unwrap();
    device
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap()
}

pub fn stored_in_team(server: &FakeServer, team: TeamId, kind: &str, id: &str) -> bool {
    server
        .stored(ScopeOwner::Team(team), kind, id)
        .is_some_and(|record| record.deleted.is_none())
}

// The personal key at `version`, as this device reads it through its wraps and rings.
pub async fn personal_key(device: &Device, version: u32) -> [u8; 32] {
    let mut txn = device.txn().await;
    *device
        .service
        .personal_key(
            txn.as_mut(),
            tablepro_keys::encoding::KeyPurpose::Personal,
            Version::new(version).unwrap(),
        )
        .await
        .unwrap()
        .expose()
}

pub fn opened_with(key_tables: tablepro_sync::api::state::KeyTrust) -> Opened {
    Opened {
        sync_tables: tablepro_sync::api::state::SyncTrust::Trusted,
        key_tables,
    }
}

// A team this account owns alone, its keys created from `owner`.
pub async fn owned_team(owner: &Device) -> TeamId {
    let team = TeamId(tablepro_keys::encoding::random_uuid().unwrap());
    owner.server.add_team(team, &[(owner.account, Role::Owner)]);
    owner.join_team(team, &[(owner.account, Role::Owner)]).await;
    owner.service.create_team_keys(team).await.unwrap();
    team
}

pub async fn put_rows(device: &Device, rows: Vec<Row>) {
    let mut txn = device.txn().await;
    for row in rows {
        txn.put(row).await.unwrap();
    }
    txn.commit().await.unwrap();
}

pub fn served(object: &KeyObject) -> tablepro_sync::api::transport::PulledRecord {
    let fields = object.fields_json();
    tablepro_sync::api::transport::PulledRecord {
        kind: tablepro_sync::api::ids::KindName::parse(object.id.kind().name()).unwrap(),
        record_id: object.id.to_wire(),
        tag: tablepro_sync::api::ids::ChangeTag::Service("tag".to_owned()),
        fields: Some(serde_json::from_str(&fields).unwrap()),
        fields_json: Some(fields),
        deleted: None,
        service: None,
    }
}

pub fn tombstone_of(kind: &str, record_id: &str) -> tablepro_sync::api::transport::PulledRecord {
    tablepro_sync::api::transport::PulledRecord {
        kind: tablepro_sync::api::ids::KindName::parse(kind).unwrap(),
        record_id: record_id.to_owned(),
        tag: tablepro_sync::api::ids::ChangeTag::Service("tag".to_owned()),
        fields: None,
        fields_json: None,
        deleted: Some(tablepro_sync::api::transport::DeletedReason::User),
        service: None,
    }
}

pub fn arrival(records: Vec<tablepro_sync::api::transport::PulledRecord>) -> KeyArrival {
    KeyArrival {
        scope: ScopeName::Personal,
        records,
        order: ArrivalOrder::InOrder,
        in_force: None,
    }
}

// A certificate at `av` under an IK of the server's own, with keys of its own: what a server cannot sign as the account.
pub fn foreign_certificate(account: AccountId, av: u32) -> KeyObject {
    let ik = tablepro_keys::keys::Ed25519Seed::generate().unwrap();
    let keys = tablepro_keys::keys::AccountKeys::generate().unwrap();
    let certificate = tablepro_keys::cert::AccountCertificate::sign(
        &origin(),
        account,
        Version::new(av).unwrap(),
        tablepro_keys::cert::CertKind::GenesisOrRotation,
        &ik,
        keys.public().unwrap(),
        None,
    )
    .unwrap();
    KeyObject {
        id: tablepro_keys::record_id::KeyRecordId::Account {
            account,
            av: Version::new(av).unwrap(),
        },
        body: tablepro_keys::body::KeyBody::Account(tablepro_keys::body::AccountBody::of(&certificate)),
    }
}
