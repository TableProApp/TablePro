// The end-to-end flows of 0056 over the `api` contracts. `KeyService` is the one type the K7 lanes implement
// `api::key_flows`'s traits on, each in its own files: K7-1 `account*`, `pins*` and `personal*`; K7-2 `approval*`,
// `reset*` and `rotation*`; K7-3 `team*`; K7-4 `restore*` and `stop*`. What every lane shares sits here: the parts
// the service runs on, the drafts a flow keeps between two calls, and the key objects the state file holds.

mod account;
mod account_apply;
mod account_flows;
mod account_genesis;
mod account_replace;
mod account_sign_out;
mod approval;
pub mod personal;
mod personal_envelopes;
pub mod pins;
mod pins_alerts;
mod reset;
mod restore;
mod rotation;
mod stop;
mod team;

use std::any::Any;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use serde_json::Value;
use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyObject, check_same_object};
use tablepro_keys::encoding::{AccountId, Origin, TeamId, random_uuid};
use tablepro_keys::record_id::KeyKind;
use tokio::sync::Mutex as AsyncMutex;

use crate::api::device_store::HostDeviceStore;
use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, IdempotencyKey, KindName, ScopeName};
use crate::api::key_flows::{DraftId, KeyHooks, KeyNotice, KeyNoticeKind, NoticeId, Roster};
use crate::api::state::{KeyObjectRow, KeyTrust, Row, RowKey, RowRange, ScopeRow, StateStore, StateTxn, Table};
use crate::api::transport::{Change, ChangeOp, ChangeOutcome, DpopKey, Proof, PushBatch, ServiceTransport};
use crate::engine::key_base;

pub use account::{AccountObjectsPlan, HeldDeviceKeys, KeptDevice, OwnAccount, ResetKeys};
pub use personal::{CurrentPersonal, ScopeKeyPlan};
pub use pins::{IkStanding, PinChange};

// Microseconds since the Unix epoch in UTC, as the service's times are (0051, Pull).
pub trait Clock: Send + Sync {
    fn now_us(&self) -> i64;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_us(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| i64::try_from(since.as_micros()).unwrap_or(i64::MAX))
    }
}

// What a `KeyService` runs on, for one (origin, account, device row) on TablePro Sync.
pub struct KeyServiceParts {
    pub origin: Origin,
    pub account: AccountId,
    pub device_row: DeviceRowId,
    pub state: Arc<dyn StateStore>,
    pub device_store: Arc<dyn HostDeviceStore>,
    pub transport: Arc<dyn ServiceTransport>,
    pub hooks: Arc<dyn KeyHooks>,
    pub clock: Arc<dyn Clock>,
}

pub struct KeyService {
    origin: Origin,
    account: AccountId,
    device_row: DeviceRowId,
    state: Arc<dyn StateStore>,
    device_store: Arc<dyn HostDeviceStore>,
    transport: Arc<dyn ServiceTransport>,
    hooks: Arc<dyn KeyHooks>,
    clock: Arc<dyn Clock>,
    drafts: Drafts,
    // One key flow or `apply_*` call changes the key tables at a time.
    serial: AsyncMutex<()>,
    notices: Mutex<Vec<KeyNotice>>,
    rosters: Rosters,
    // A stale file takes no wrap or envelope and writes no secret until its rebuild has seen every anchored pin and
    // version (0054, A stale file).
    rebuilding: AtomicBool,
    // A file opened with no anchor handles no secret until an approval or a recovery applies (0054, A stale file).
    unanchored: AtomicBool,
}

impl KeyService {
    pub fn new(parts: KeyServiceParts) -> Self {
        let unanchored = parts.state.opened().key_tables == KeyTrust::Unanchored;
        let rebuilding = matches!(parts.state.opened().key_tables, KeyTrust::Rebuild { .. });
        Self {
            origin: parts.origin,
            account: parts.account,
            device_row: parts.device_row,
            state: parts.state,
            device_store: parts.device_store,
            transport: parts.transport,
            hooks: parts.hooks,
            clock: parts.clock,
            drafts: Drafts::default(),
            serial: AsyncMutex::new(()),
            notices: Mutex::new(Vec::new()),
            unanchored: AtomicBool::new(unanchored),
            rosters: Rosters::default(),
            rebuilding: AtomicBool::new(rebuilding),
        }
    }

    pub fn origin(&self) -> &Origin {
        &self.origin
    }

    pub fn account(&self) -> AccountId {
        self.account
    }

    pub fn device_row(&self) -> &DeviceRowId {
        &self.device_row
    }

    pub fn state(&self) -> &Arc<dyn StateStore> {
        &self.state
    }

    pub fn device_store(&self) -> &Arc<dyn HostDeviceStore> {
        &self.device_store
    }

    pub fn transport(&self) -> &Arc<dyn ServiceTransport> {
        &self.transport
    }

    pub fn hooks(&self) -> &Arc<dyn KeyHooks> {
        &self.hooks
    }

    pub fn now_us(&self) -> i64 {
        self.clock.now_us()
    }

    pub fn drafts(&self) -> &Drafts {
        &self.drafts
    }

    pub fn rosters(&self) -> &Rosters {
        &self.rosters
    }

    // Held for the whole of a flow or an `apply_*` call, so two never interleave their reads and writes.
    pub async fn serialized(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.serial.lock().await
    }

    pub async fn begin(&self) -> Result<Box<dyn StateTxn>, SyncError> {
        Ok(self.state.begin().await?)
    }

    pub fn is_unanchored(&self) -> bool {
        self.unanchored.load(Ordering::SeqCst)
    }

    // An approval or a recovery applied, so the device holds keys again under what it verified since.
    // The lock notices raised before then, as a pull of this device's own activation or recovery that came before its
    // adoption raises, no longer hold, so they go and the app reads the notices again.
    pub fn clear_unanchored(&self) {
        self.unanchored.store(false, Ordering::SeqCst);
        let withdrawn = {
            let mut notices = lock(&self.notices);
            let before = notices.len();
            notices.retain(|notice| !matches!(notice.kind, KeyNoticeKind::Locked { .. }));
            notices.len() != before
        };
        if withdrawn {
            self.hooks.resume_scope(ScopeName::Personal);
        }
    }

    pub fn is_rebuilding(&self) -> bool {
        self.rebuilding.load(Ordering::SeqCst)
    }

    // The rebuild of a stale file's key tables has seen every anchored pin and version.
    pub fn rebuilt(&self) {
        self.rebuilding.store(false, Ordering::SeqCst);
    }

    // Records a notice for `notices` and tells the app. Every lane raises its notices here.
    pub fn raise_notice(&self, kind: KeyNoticeKind) -> Result<NoticeId, SyncError> {
        let notice = KeyNotice {
            id: NoticeId(random_uuid()?),
            kind,
        };
        lock(&self.notices).push(notice.clone());
        self.hooks.notice(notice.clone());
        Ok(notice.id)
    }

    pub fn held_notices(&self) -> Vec<KeyNotice> {
        lock(&self.notices).clone()
    }

    pub(crate) fn clear_notices(&self) {
        lock(&self.notices).clear();
    }

    pub fn dismiss(&self, notice: NoticeId) -> bool {
        let mut notices = lock(&self.notices);
        let before = notices.len();
        notices.retain(|held| held.id != notice);
        notices.len() != before
    }

    // A key object at its id in a scope, as `key_objects` holds it.
    pub async fn held_object(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        kind: KeyKind,
        record_id: &str,
    ) -> Result<Option<HeldObject>, SyncError> {
        let key = RowKey::KeyObject(scope, KindName::parse(kind.name())?, record_id.to_owned());
        match txn.get(&key).await? {
            Some(Row::KeyObject(row)) => HeldObject::of(&row).map(Some),
            _ => Ok(None),
        }
    }

    // Every key object of one kind in a scope, in record id order.
    pub async fn held_objects(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        kind: KeyKind,
    ) -> Result<Vec<HeldObject>, SyncError> {
        let range = RowRange::ScopeKind(Table::KeyObjects, scope, KindName::parse(kind.name())?);
        txn.scan(&range)
            .await?
            .iter()
            .filter_map(|row| match row {
                Row::KeyObject(row) => Some(HeldObject::of(row)),
                _ => None,
            })
            .collect()
    }

    // A key object in force at its id: served by the server, or written by this device and applied. A candidate that
    // never applied counts for nothing, since it gives way to what the server serves (0054, `key_objects`).
    pub async fn applied_object(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        kind: KeyKind,
        record_id: &str,
    ) -> Result<Option<KeyObject>, SyncError> {
        Ok(self
            .held_object(txn, scope, kind, record_id)
            .await?
            .filter(|held| held.applied)
            .map(|held| held.object))
    }

    pub async fn applied_objects(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        kind: KeyKind,
    ) -> Result<Vec<KeyObject>, SyncError> {
        Ok(self
            .held_objects(txn, scope, kind)
            .await?
            .into_iter()
            .filter(|held| held.applied)
            .map(|held| held.object)
            .collect())
    }

    // Keeps a key object served or written. Every key kind is create-only: another object at the id of an applied one
    // is `keys.conflict`, while this device's own candidate gives way to what the server serves (0054, `key_objects`).
    pub async fn hold_object(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        object: &KeyObject,
        applied: bool,
    ) -> Result<(), SyncError> {
        let kind = KindName::parse(object.id.kind().name())?;
        let record_id = object.id.to_wire();
        let fields = object.fields_json();
        let key = RowKey::KeyObject(scope, kind.clone(), record_id.clone());
        let held = match txn.get(&key).await? {
            Some(Row::KeyObject(row)) => Some(row),
            _ => None,
        };
        let row = match held {
            None => KeyObjectRow {
                scope,
                kind,
                record_id,
                fields,
                applied,
            },
            Some(row) => {
                let same = check_same_object(
                    row.kind.as_str(),
                    &row.record_id,
                    row.fields.as_bytes(),
                    kind.as_str(),
                    &record_id,
                    fields.as_bytes(),
                )
                .is_ok();
                match (same, row.applied, applied) {
                    (true, true, _) | (true, false, false) => return Ok(()),
                    (true, false, true) => KeyObjectRow { applied: true, ..row },
                    (false, true, _) => return Err(KeysError::Conflict.into()),
                    (false, false, _) => KeyObjectRow {
                        scope,
                        kind,
                        record_id,
                        fields,
                        applied,
                    },
                }
            }
        };
        txn.put(Row::KeyObject(row)).await?;
        Ok(())
    }

    // Removes this device's own candidates that never applied, as a change set the server refused leaves them.
    pub async fn drop_candidates(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        objects: &[KeyObject],
    ) -> Result<(), SyncError> {
        for object in objects {
            let key = RowKey::KeyObject(scope, KindName::parse(object.id.kind().name())?, object.id.to_wire());
            if let Some(Row::KeyObject(row)) = txn.get(&key).await?
                && !row.applied
            {
                txn.delete(&key).await?;
            }
        }
        Ok(())
    }

    // One change set as one push, applied whole or not at all (0051, Change sets), under the epoch the scope holds.
    // What applied keeps its base, so a push-back after a restore judges what the server holds by it (0051, After a
    // restore).
    pub async fn push_change_set(
        &self,
        scope: ScopeName,
        changes: Vec<Change>,
        proof: DpopKey,
    ) -> Result<Vec<ChangeOutcome>, SyncError> {
        let epoch = {
            let mut txn = self.begin().await?;
            match txn.get(&RowKey::Scope(scope)).await? {
                Some(Row::Scope(row)) => row.epoch,
                _ => None,
            }
        }
        .ok_or(SyncError::NotAllowed {
            what: "push before the scope is read",
        })?;
        let batch = PushBatch {
            scope,
            epoch: Some(epoch),
            idempotency_key: Some(IdempotencyKey::parse(&random_uuid()?.to_string())?),
            changes: changes.clone(),
            proof: Proof::Dpop(proof),
        };
        let answer = self.transport.push(batch).await?;
        if answer.outcomes.len() != changes.len() {
            return Err(SyncError::Malformed { what: "push answer" });
        }
        let bases: Vec<_> = changes
            .iter()
            .zip(&answer.outcomes)
            .filter_map(|(change, outcome)| key_base(scope, epoch, change, outcome))
            .collect();
        if !bases.is_empty() {
            let mut txn = self.begin().await?;
            for base in bases {
                txn.put(Row::Base(base)).await?;
            }
            txn.commit().await?;
        }
        Ok(answer.outcomes)
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

// A key object as `key_objects` holds it: parsed, with the exact `fields` text and whether it is in force.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldObject {
    pub object: KeyObject,
    pub fields: String,
    pub applied: bool,
}

impl HeldObject {
    fn of(row: &KeyObjectRow) -> Result<Self, SyncError> {
        Ok(Self {
            object: KeyObject::parse(row.kind.as_str(), &row.record_id, row.fields.as_bytes())?,
            fields: row.fields.clone(),
            applied: row.applied,
        })
    }
}

// The create change of a key object: no base, its `fields` as the patch (0051, Push).
pub fn create_change(object: &KeyObject) -> Result<Change, SyncError> {
    let fields: Value =
        serde_json::from_str(&object.fields_json()).map_err(|_| SyncError::Malformed { what: "key object" })?;
    Ok(Change {
        kind: KindName::parse(object.id.kind().name())?,
        record_id: object.id.to_wire(),
        base: None,
        op: ChangeOp::Write {
            patch: fields.clone(),
            fields,
        },
    })
}

// Each team's last roster read once its pull was caught up (0051, `members`): a server assertion, never a holder check.
#[derive(Debug, Default)]
pub struct Rosters(Mutex<HashMap<TeamId, Roster>>);

impl Rosters {
    pub fn get(&self, team: TeamId) -> Option<Roster> {
        lock(&self.0).get(&team).cloned()
    }

    pub fn put(&self, team: TeamId, roster: Roster) {
        lock(&self.0).insert(team, roster);
    }
}

// A roster speaks for the epoch the device synced the team in: the one its scope row adopted, with no refill against
// a newer one under way. One read in an earlier epoch, or while a refill has not been adopted, decides nothing (0051,
// `members`; After a restore).
pub(crate) fn roster_in_epoch(roster: &Roster, scope: &ScopeRow) -> bool {
    roster.caught_up() && !scope.refill && scope.epoch.is_some() && roster.epoch() == scope.epoch
}

impl KeyService {
    // The team's roster when it speaks for the epoch the device is in.
    pub(crate) async fn current_roster(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
    ) -> Result<Option<Roster>, SyncError> {
        let Some(roster) = self.rosters().get(team) else {
            return Ok(None);
        };
        let in_epoch = match txn.get(&RowKey::Scope(ScopeName::Team(team))).await? {
            Some(Row::Scope(scope)) => roster_in_epoch(&roster, &scope),
            _ => false,
        };
        Ok(in_epoch.then_some(roster))
    }
}

// What a flow keeps between two calls, by draft id: a recovery key shown and not yet typed back, a review, a session.
// Each lane stores its own type and takes it back by the same type; another type at the id is `sync.unknown`.
#[derive(Default)]
pub struct Drafts {
    held: Mutex<HashMap<DraftId, Box<dyn Any + Send>>>,
}

impl Drafts {
    fn lock(&self) -> MutexGuard<'_, HashMap<DraftId, Box<dyn Any + Send>>> {
        lock(&self.held)
    }

    pub fn put<T: Any + Send>(&self, value: T) -> Result<DraftId, SyncError> {
        let id = DraftId(random_uuid()?);
        self.lock().insert(id, Box::new(value));
        Ok(id)
    }

    pub fn take<T: Any + Send>(&self, id: DraftId) -> Result<T, SyncError> {
        let mut held = self.lock();
        if !held.get(&id).is_some_and(|value| value.is::<T>()) {
            return Err(SyncError::Unknown { what: "draft" });
        }
        held.remove(&id)
            .and_then(|value| value.downcast::<T>().ok())
            .map(|value| *value)
            .ok_or(SyncError::Unknown { what: "draft" })
    }

    // Runs `f` on the draft in place, leaving it held.
    pub fn with<T: Any + Send, R>(&self, id: DraftId, f: impl FnOnce(&mut T) -> R) -> Result<R, SyncError> {
        let mut held = self.lock();
        let value = held
            .get_mut(&id)
            .and_then(|value| value.downcast_mut::<T>())
            .ok_or(SyncError::Unknown { what: "draft" })?;
        Ok(f(value))
    }

    pub fn remove(&self, id: DraftId) {
        self.lock().remove(&id);
    }

    // Sign Out drops every draft, and with them any recovery key a flow still held.
    pub(crate) fn clear(&self) {
        self.lock().clear();
    }
}

// A roster as a pull that caught up after its scopes body leaves it, or as one read before that when `caught_up` is
// false, from a body whose current epoch is `epoch`.
#[cfg(test)]
pub(crate) fn test_roster(
    team: TeamId,
    members: Vec<crate::api::scopes::TeamMember>,
    role: Option<crate::api::scopes::Role>,
    rotation_due: bool,
    caught_up: bool,
    epoch: crate::api::ids::EpochId,
) -> Roster {
    let scope = ScopeName::Team(team);
    let info = crate::api::scopes::ScopeInfo {
        scope,
        role,
        horizon: 0,
        epochs: vec![crate::api::scopes::LineageEpoch {
            id: epoch,
            kept_revision: 0,
        }],
        writable: true,
        policies: crate::api::scopes::ScopePolicies::default(),
        quota: None,
        rotation_due,
        members,
        stopped: Vec::new(),
        approved: None,
    };
    let page = crate::api::transport::PulledPage {
        records: Vec::new(),
        cursor: None,
        changes_cursor: None,
        caught_up: true,
        unread: Vec::new(),
    };
    let pull = crate::api::key_flows::CaughtUp::from_page(scope, &page).filter(|_| caught_up);
    Roster::of(&info, pull)
}
