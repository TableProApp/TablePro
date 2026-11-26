// An in-memory `/v2/sync` server with 0051's record rules: change tags that carry the epoch, conditional writes, create
// only key kinds, change sets applied whole and never split across pages, idempotent replays, snapshots then deltas,
// epochs with their cuts, and the scopes body. It checks no signature or key-object statement: those are the real
// server's (S3K) and the hostile fake's (K7). One `FakeServer` serves many devices, each through its own `FakeClient`.

mod pull;
mod push;
mod scopes;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::Value;
use tablepro_keys::encoding::{AccountId, TeamId};
use tablepro_sync::api::ids::{ChangeTag, DeviceRowId, EpochId, KindName, ScopeName};
use tablepro_sync::api::scopes::{Role, StopReport};
use tablepro_sync::api::transport::{DeletedReason, Proof, TransportError};
use uuid::Uuid;

pub use pull::PAGE_BYTES;

// Where a scope's records live: an account's personal and history scopes, or a team's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ScopeOwner {
    Personal(AccountId),
    History(AccountId),
    Team(TeamId),
}

impl ScopeOwner {
    pub fn of(scope: ScopeName, account: AccountId) -> Self {
        match scope {
            ScopeName::Personal => Self::Personal(account),
            ScopeName::History => Self::History(account),
            ScopeName::Team(team) => Self::Team(team),
        }
    }

    pub fn scope(self) -> ScopeName {
        match self {
            Self::Personal(_) => ScopeName::Personal,
            Self::History(_) => ScopeName::History,
            Self::Team(team) => ScopeName::Team(team),
        }
    }
}

// A record as the server stores it (0051, `sync_records`).
#[derive(Debug, Clone, PartialEq)]
pub struct StoredRecord {
    pub kind: KindName,
    pub record_id: String,
    pub version: u64,
    pub revision: u64,
    pub written_epoch: EpochId,
    pub write_tag: [u8; 16],
    pub fields: Option<Value>,
    pub deleted: Option<DeletedReason>,
    pub taken_at_us: i64,
    pub updated_at_us: i64,
    pub updated_device: Option<DeviceRowId>,
    pub updated_by: Option<AccountId>,
}

impl StoredRecord {
    // 0051, Change tags: format 0x01, the written epoch, the version big-endian and the write tag, base64url.
    pub fn change_tag(&self) -> ChangeTag {
        let mut bytes = Vec::with_capacity(41);
        bytes.push(1);
        bytes.extend_from_slice(self.written_epoch.0.as_bytes());
        bytes.extend_from_slice(&self.version.to_be_bytes());
        bytes.extend_from_slice(&self.write_tag);
        ChangeTag::Service(URL_SAFE_NO_PAD.encode(bytes))
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct ScopeData {
    pub(crate) records: BTreeMap<(String, String), StoredRecord>,
    // Each change set's first and last revision, which a page never splits.
    pub(crate) change_sets: Vec<(u64, u64)>,
}

impl ScopeData {
    pub(crate) fn horizon(&self) -> u64 {
        self.records.values().map(|record| record.revision).max().unwrap_or(0)
    }
}

#[derive(Debug, Clone)]
pub(crate) struct EpochRow {
    pub(crate) id: EpochId,
    // Each scope's horizon when the epoch began.
    pub(crate) cuts: BTreeMap<ScopeOwner, u64>,
}

#[derive(Debug, Clone)]
pub(crate) struct Team {
    pub(crate) members: BTreeMap<AccountId, Role>,
    pub(crate) rotation_due: bool,
    pub(crate) password_sync: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Policies {
    pub personal_sync: bool,
    pub password_sync: bool,
    pub history_sync: bool,
}

impl Default for Policies {
    fn default() -> Self {
        Self {
            personal_sync: true,
            password_sync: true,
            history_sync: true,
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct StoredAnswer {
    pub(crate) digest: [u8; 32],
    // The outcome of each change that applied, by its place in the push; the others are judged again on a replay.
    pub(crate) applied: Vec<Option<tablepro_sync::api::transport::ChangeOutcome>>,
    pub(crate) created_at_us: i64,
}

#[derive(Debug, Clone)]
pub(crate) enum CursorPhase {
    Snapshot { mark: u64, after: Option<(String, String)> },
    HistoryOlder { mark: u64, before: u64 },
    Delta { after: u64 },
}

#[derive(Debug, Clone)]
pub(crate) struct CursorState {
    pub(crate) owner: ScopeOwner,
    pub(crate) epoch: EpochId,
    pub(crate) phase: CursorPhase,
    pub(crate) pre_approval: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct State {
    pub(crate) lineage: Vec<EpochRow>,
    pub(crate) next_revision: u64,
    pub(crate) scopes: BTreeMap<ScopeOwner, ScopeData>,
    pub(crate) teams: BTreeMap<TeamId, Team>,
    pub(crate) idempotency: HashMap<(ScopeOwner, AccountId, String), StoredAnswer>,
    // Each device row's approved DSK: the key device it holds, certified at the current `av`.
    pub(crate) approved: HashMap<DeviceRowId, [u8; 32]>,
    pub(crate) removed_rows: HashSet<DeviceRowId>,
    pub(crate) stopped: BTreeMap<(TeamId, DeviceRowId), StopReport>,
    pub(crate) policies: Policies,
    pub(crate) lapsed: bool,
    // Each device row's sign-in with a fresh step-up, and the account each row belongs to.
    pub(crate) stepped_up: HashSet<DeviceRowId>,
    pub(crate) rows: HashMap<DeviceRowId, AccountId>,
    pub(crate) fail_next: Vec<TransportError>,
    pub(crate) clock_us: i64,
    // The name a team record's writer goes by, by the writer's account id on the wire.
    pub(crate) writer_names: HashMap<String, String>,
}

impl State {
    pub(crate) fn epoch(&self) -> EpochId {
        self.lineage.last().map_or(EpochId(Uuid::nil()), |epoch| epoch.id)
    }

    pub(crate) fn take_revision(&mut self) -> u64 {
        self.next_revision += 1;
        self.next_revision
    }

    fn highest_revision(&self) -> u64 {
        self.scopes.values().map(ScopeData::horizon).max().unwrap_or(0)
    }

    // `sync new-epoch`: a new random id, each scope's horizon as its cut, and the sequence moved 2^40 past the highest
    // revision. Stop reports go with the old epoch.
    pub(crate) fn open_epoch(&mut self) -> EpochId {
        let id = EpochId(Uuid::new_v4());
        let start_revision = self.highest_revision().max(self.next_revision) + (1 << 40);
        let cuts = self
            .scopes
            .iter()
            .map(|(owner, data)| (*owner, data.horizon()))
            .collect();
        self.lineage.push(EpochRow { id, cuts });
        self.next_revision = start_revision;
        self.stopped.clear();
        id
    }
}

// A copy of the database, which `restore` puts back the way a point-in-time restore does.
#[derive(Debug, Clone)]
pub struct Backup(State);

#[derive(Debug)]
pub struct FakeServer {
    state: Mutex<State>,
    cursors: Mutex<HashMap<String, CursorState>>,
}

impl FakeServer {
    pub fn new() -> Arc<Self> {
        let mut state = State {
            lineage: Vec::new(),
            next_revision: 0,
            scopes: BTreeMap::new(),
            teams: BTreeMap::new(),
            idempotency: HashMap::new(),
            approved: HashMap::new(),
            removed_rows: HashSet::new(),
            stopped: BTreeMap::new(),
            policies: Policies::default(),
            lapsed: false,
            stepped_up: HashSet::new(),
            rows: HashMap::new(),
            fail_next: Vec::new(),
            clock_us: 1_767_225_600_000_000,
            writer_names: HashMap::new(),
        };
        state.lineage.push(EpochRow {
            id: EpochId(Uuid::new_v4()),
            cuts: BTreeMap::new(),
        });
        Arc::new(Self {
            state: Mutex::new(state),
            cursors: Mutex::new(HashMap::new()),
        })
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn cursors(&self) -> MutexGuard<'_, HashMap<String, CursorState>> {
        self.cursors.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn client(self: &Arc<Self>, account: AccountId, device_row: DeviceRowId) -> FakeClient {
        self.lock().rows.insert(device_row.clone(), account);
        FakeClient {
            server: Arc::clone(self),
            account,
            device_row,
        }
    }

    pub fn epoch(&self) -> EpochId {
        self.lock().epoch()
    }

    pub fn lineage(&self) -> Vec<(EpochId, BTreeMap<ScopeOwner, u64>)> {
        self.lock()
            .lineage
            .iter()
            .map(|epoch| (epoch.id, epoch.cuts.clone()))
            .collect()
    }

    // A failover, or a restore the server detected: a new epoch over the records as they are.
    pub fn new_epoch(&self) -> EpochId {
        self.lock().open_epoch()
    }

    pub fn backup(&self) -> Backup {
        Backup(self.lock().clone())
    }

    // Puts a backup back and opens the epoch its detection opens: writes after the backup are lost, and so are the
    // epoch rows the backup did not hold.
    pub fn restore(&self, backup: &Backup) -> EpochId {
        let mut state = self.lock();
        *state = backup.0.clone();
        state.open_epoch()
    }

    pub fn add_team(&self, team: TeamId, members: &[(AccountId, Role)]) {
        self.lock().teams.insert(
            team,
            Team {
                members: members.iter().copied().collect(),
                rotation_due: false,
                password_sync: true,
            },
        );
    }

    pub fn set_role(&self, team: TeamId, account: AccountId, role: Option<Role>) {
        let mut state = self.lock();
        let Some(data) = state.teams.get_mut(&team) else {
            return;
        };
        match role {
            Some(role) => {
                data.members.insert(account, role);
            }
            None => {
                // Removing a member marks the team `rotation_due` (0051, Removals).
                data.members.remove(&account);
                data.rotation_due = true;
            }
        }
    }

    pub fn set_rotation_due(&self, team: TeamId, due: bool) {
        if let Some(data) = self.lock().teams.get_mut(&team) {
            data.rotation_due = due;
        }
    }

    // The device row holds a key device whose DSK is `dsk`, certified at the current `av`.
    pub fn approve(&self, device_row: &DeviceRowId, dsk: [u8; 32]) {
        self.lock().approved.insert(device_row.clone(), dsk);
    }

    pub fn unapprove(&self, device_row: &DeviceRowId) {
        self.lock().approved.remove(device_row);
    }

    pub fn is_approved(&self, device_row: &DeviceRowId) -> bool {
        self.lock().approved.contains_key(device_row)
    }

    // An install admin removing the row from the portal: the row's device gets `device_removed` from then on.
    pub fn remove_row(&self, device_row: &DeviceRowId) {
        let mut state = self.lock();
        state.approved.remove(device_row);
        state.removed_rows.insert(device_row.clone());
        state.stopped.retain(|(_, row), _| row != device_row);
    }

    // Whether this row's sign-in holds a step-up within 300 s (0051, Step-up).
    pub fn set_step_up(&self, device_row: &DeviceRowId, fresh: bool) {
        let mut state = self.lock();
        if fresh {
            state.stepped_up.insert(device_row.clone());
        } else {
            state.stepped_up.remove(device_row);
        }
    }

    // The name the server gives a team record's writer.
    pub fn name_writer(&self, account: AccountId, name: &str) {
        self.lock().writer_names.insert(account.to_wire(), name.to_owned());
    }

    pub fn set_lapsed(&self, lapsed: bool) {
        self.lock().lapsed = lapsed;
    }

    // The next calls fail as given, in order, before anything else is checked.
    pub fn fail_next(&self, error: TransportError) {
        self.lock().fail_next.push(error);
    }

    pub fn advance_clock(&self, micros: i64) {
        self.lock().clock_us += micros;
    }

    pub fn now_us(&self) -> i64 {
        self.lock().clock_us
    }

    // A switch turned off: the job tombstones what it covers with `policy` and no writer; on, nothing is revived.
    pub fn set_policies(&self, policies: Policies) {
        let mut state = self.lock();
        state.policies = policies;
        let owners: Vec<ScopeOwner> = state.scopes.keys().copied().collect();
        for owner in owners {
            let ids: Vec<(String, String)> = state.scopes[&owner]
                .records
                .iter()
                .filter(|(_, record)| record.deleted.is_none() && push::policy_refuses(&state, owner, &record.kind))
                .map(|(key, _)| key.clone())
                .collect();
            for key in ids {
                let revision = state.take_revision();
                let epoch = state.epoch();
                let now = state.clock_us;
                if let Some(record) = state.scopes.get_mut(&owner).and_then(|data| data.records.get_mut(&key)) {
                    record.version += 1;
                    record.revision = revision;
                    record.written_epoch = epoch;
                    record.write_tag = *Uuid::new_v4().as_bytes();
                    record.deleted = Some(DeletedReason::Policy);
                    record.fields = None;
                    record.updated_at_us = now;
                    record.updated_device = None;
                    record.updated_by = None;
                }
            }
        }
    }

    pub fn stored(&self, owner: ScopeOwner, kind: &str, record_id: &str) -> Option<StoredRecord> {
        self.lock()
            .scopes
            .get(&owner)
            .and_then(|data| data.records.get(&(kind.to_owned(), record_id.to_owned())))
            .cloned()
    }

    pub fn horizon(&self, owner: ScopeOwner) -> u64 {
        self.lock().scopes.get(&owner).map_or(0, ScopeData::horizon)
    }

    pub fn stop_reports(&self, team: TeamId) -> Vec<StopReport> {
        self.lock()
            .stopped
            .iter()
            .filter(|((reported, _), _)| *reported == team)
            .map(|(_, report)| report.clone())
            .collect()
    }
}

// One device's sign-in against the server: its account and device row.
#[derive(Debug, Clone)]
pub struct FakeClient {
    pub(crate) server: Arc<FakeServer>,
    pub account: AccountId,
    pub device_row: DeviceRowId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Approval {
    NoProof,
    Unapproved,
    Approved,
}

impl FakeClient {
    pub fn server(&self) -> &Arc<FakeServer> {
        &self.server
    }

    // The checks every call makes first: injected failures, a removed row, a seat in a team.
    pub(crate) fn admit(&self, state: &mut State, scope: Option<ScopeName>) -> Result<(), TransportError> {
        if !state.fail_next.is_empty() {
            return Err(state.fail_next.remove(0));
        }
        if state.removed_rows.contains(&self.device_row) {
            return Err(TransportError::DeviceRemoved);
        }
        if let Some(ScopeName::Team(team)) = scope {
            let data = state.teams.get(&team).ok_or(TransportError::NotFound)?;
            if !data.members.contains_key(&self.account) {
                return Err(TransportError::SeatRequired);
            }
        }
        Ok(())
    }

    pub(crate) fn approval(&self, state: &State, proof: &Proof) -> Approval {
        match proof {
            Proof::None => Approval::NoProof,
            Proof::Dpop(key) => {
                let held = state.approved.get(&self.device_row);
                let public = key.0.public().ok().map(|public| public.0);
                if held.is_some() && held.copied() == public {
                    Approval::Approved
                } else {
                    Approval::Unapproved
                }
            }
        }
    }

    pub(crate) fn role(&self, state: &State, scope: ScopeName) -> Option<Role> {
        match scope {
            ScopeName::Team(team) => state
                .teams
                .get(&team)
                .and_then(|data| data.members.get(&self.account))
                .copied(),
            ScopeName::Personal | ScopeName::History => None,
        }
    }
}
