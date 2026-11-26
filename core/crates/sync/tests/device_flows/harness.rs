// Devices of one account against the fake `/v2/sync` server: each with its own state file, device store and hooks,
// the engine's part of a pull done here, and the checks the fake leaves to the real server stood in for by a refusal
// the test sets.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::KeyObject;
use tablepro_keys::encoding::{AccountId, Origin, RequestId, TeamId, Version};
use tablepro_sync::api::ids::{DeviceRowId, ScopeName};
use tablepro_sync::api::key_flows::{
    AccountFlows, ApprovalFlows, ArrivalOrder, KeyApplied, KeyArrival, KeyState, RecoveryKeyDraft, ResetFlows,
    SessionPhase, TypedBack,
};
use tablepro_sync::api::scopes::ScopesAnswer;
use tablepro_sync::api::state::{
    KeyDevicePinRow, KeyPinRow, Row, RowKey, RowRange, ScopeRow, StateFiles, StateIdentity, StateStore, StateTxn, Table,
};
use tablepro_sync::api::transport::{
    Change, ChangeOutcome, DpopKey, Proof, PullRequest, PulledPage, PushAnswer, PushBatch, RejectedCode,
    ServiceTransport, Transport, TransportError,
};
use tablepro_sync::keys::{Clock, KeyService, KeyServiceParts};
use tablepro_sync_testing::service::ScopeOwner;
use tablepro_sync_testing::{FakeClient, FakeDeviceStore, FakeServer, MemoryStateFiles, RecordingHooks};

pub const ORIGIN: &str = "https://sync.example.com";

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
}

impl Wire {
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
        self.client.push(batch).await
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
    pub row: DeviceRowId,
    skew: Arc<ServerClock>,
}

impl Device {
    pub async fn new(server: &Arc<FakeServer>, account: AccountId, row: &str) -> Self {
        let row = DeviceRowId(row.to_owned());
        let state = MemoryStateFiles::new()
            .open(StateIdentity::Service {
                origin: origin(),
                sign_in: "sign-in".to_owned(),
                account,
                device_row: row.clone(),
            })
            .await
            .unwrap();
        let wire = Arc::new(Wire {
            client: server.client(account, row.clone()),
            pushed: Mutex::new(Vec::new()),
            refuse: Mutex::new(None),
            fail: Mutex::new(None),
        });
        let hooks = Arc::new(RecordingHooks::default());
        let store = Arc::new(FakeDeviceStore::new());
        let clock = Arc::new(ServerClock(Arc::clone(server), AtomicI64::new(0)));
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
            row,
            skew: clock,
        }
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
