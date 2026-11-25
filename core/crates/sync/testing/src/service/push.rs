// `POST /v2/sync/scopes/{scope}/changes` (0051, Push).

use serde_json::Value;
use sha2::{Digest, Sha256};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_records::{kind as kinds, limits, merge_patch, record_id};
use tablepro_sync::api::ids::{KindName, ScopeName};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::transport::{
    AppliedStamp, Change, ChangeOp, ChangeOutcome, DeletedReason, PushAnswer, PushBatch, RejectedCode, StoredCopy,
    StoredStamp, TransportError,
};
use uuid::Uuid;

use super::{Approval, FakeClient, ScopeOwner, State, StoredAnswer, StoredRecord};

const MAX_CHANGES: usize = 500;
const MAX_CHANGE_SET: usize = 10_000;
const MAX_BODY_BYTES: usize = 4 << 20;
const IDEMPOTENCY_RETENTION_US: i64 = 86_400 * 1_000_000;
const REQUEST_LIFETIME_US: i64 = 600 * 1_000_000;
const RESET_HOLD_US: i64 = 7 * 24 * 3600 * 1_000_000;

// A switch that turns the kind off in the scope (0051, Policies).
pub(crate) fn policy_refuses(state: &State, owner: ScopeOwner, kind: &KindName) -> bool {
    let name = kind.as_str();
    let policies = state.policies;
    let team_password = match owner {
        ScopeOwner::Team(team) => state.teams.get(&team).is_some_and(|data| !data.password_sync),
        _ => false,
    };
    (name == "secret_envelope" && (!policies.password_sync || team_password))
        || (name == "history_entry" && (!policies.history_sync || !policies.personal_sync))
        || (matches!(owner, ScopeOwner::Personal(_)) && !kind.is_key() && !policies.personal_sync)
}

// Over what the service request carries: the epoch and each change's kind, id, base and patch.
fn digest(batch: &PushBatch) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(format!("{:?}", batch.epoch).as_bytes());
    for change in &batch.changes {
        let op = match &change.op {
            ChangeOp::Write { patch, .. } => patch.to_string(),
            ChangeOp::Delete => "delete".to_owned(),
        };
        hasher.update(format!("|{}|{}|{:?}|{op}", change.kind, change.record_id, change.base).as_bytes());
    }
    hasher.finalize().into()
}

// The request body's size, as the 4 MiB limit measures it.
fn body_bytes(batch: &PushBatch) -> usize {
    batch
        .changes
        .iter()
        .map(|change| match &change.op {
            ChangeOp::Write { patch, .. } => limits::encoded_len(patch) + change.record_id.len(),
            ChangeOp::Delete => change.record_id.len(),
        })
        .sum()
}

impl FakeClient {
    pub(crate) fn push_batch(&self, batch: &PushBatch) -> Result<PushAnswer, TransportError> {
        let mut state = self.server.lock();
        self.admit(&mut state, Some(batch.scope))?;
        let owner = ScopeOwner::of(batch.scope, self.account);
        let key = batch.idempotency_key.as_ref().ok_or(TransportError::ValidationFailed)?;
        // A push of key objects alone is judged as one change set, as each of 0051's change sets goes up alone.
        let change_set = !batch.changes.is_empty() && batch.changes.iter().all(|change| change.kind.is_key());
        let limit = if change_set { MAX_CHANGE_SET } else { MAX_CHANGES };
        if batch.changes.is_empty() || batch.changes.len() > limit || named_twice(&batch.changes) {
            return Err(TransportError::ValidationFailed);
        }
        if body_bytes(batch) > MAX_BODY_BYTES {
            return Err(TransportError::Server {
                status: 413,
                code: "payload_too_large".to_owned(),
                retry_after_ms: None,
            });
        }
        self.gate(&state, batch)?;
        if batch.epoch != Some(state.epoch()) {
            return Err(TransportError::EpochChanged);
        }
        let now = state.clock_us;
        state
            .idempotency
            .retain(|_, answer| now - answer.created_at_us < IDEMPOTENCY_RETENTION_US);
        let slot = (owner, self.account, key.0.clone());
        let digest = digest(batch);
        let stored = state.idempotency.get(&slot).cloned();
        if stored.as_ref().is_some_and(|stored| stored.digest != digest) {
            return Err(TransportError::IdempotencyMismatch);
        }
        let before = state.clone();
        let (outcomes, applied) = self.judge_all(&mut state, owner, batch, stored.as_ref());
        if change_set
            && outcomes
                .iter()
                .any(|outcome| !matches!(outcome, ChangeOutcome::Applied { .. }))
        {
            *state = before;
            return Ok(PushAnswer {
                outcomes: whole_set_refused(outcomes),
            });
        }
        if change_set && applied.iter().any(Option::is_some) {
            mark_change_set(&mut state, owner, &applied);
        }
        if applied.iter().any(Option::is_some) {
            let mut answer = stored.unwrap_or(StoredAnswer {
                digest,
                applied: vec![None; applied.len()],
                created_at_us: now,
            });
            for (held, wrote) in answer.applied.iter_mut().zip(applied) {
                if wrote.is_some() {
                    *held = wrote;
                }
            }
            state.idempotency.insert(slot, answer);
        }
        Ok(PushAnswer { outcomes })
    }

    // Each change in the order sent. A replay answers what applied from the store, after the caller's role and every
    // other check pass again, and judges the rest again.
    fn judge_all(
        &self,
        state: &mut State,
        owner: ScopeOwner,
        batch: &PushBatch,
        stored: Option<&StoredAnswer>,
    ) -> (Vec<ChangeOutcome>, Vec<Option<ChangeOutcome>>) {
        let mut outcomes = Vec::with_capacity(batch.changes.len());
        let mut applied = Vec::with_capacity(batch.changes.len());
        for (index, change) in batch.changes.iter().enumerate() {
            let replayed = stored.and_then(|stored| stored.applied.get(index).cloned().flatten());
            let (outcome, wrote) = match replayed {
                Some(outcome) => match self.check(state, owner, change) {
                    Ok(()) => (outcome, false),
                    Err(code) => (ChangeOutcome::Rejected { code }, false),
                },
                None => self.judge(state, owner, change),
            };
            applied.push(wrote.then(|| outcome.clone()));
            outcomes.push(outcome);
        }
        (outcomes, applied)
    }

    // Whole-push refusals: approval, a lapse and the scope's own rules before any change is judged.
    fn gate(&self, state: &State, batch: &PushBatch) -> Result<(), TransportError> {
        let approval = self.approval(state, &batch.proof);
        let keyed = |change: &Change| change.kind.is_key() || change.kind.as_str() == "secret_envelope";
        match batch.scope {
            ScopeName::Personal | ScopeName::History => {
                let allowed = match approval {
                    Approval::Approved => true,
                    Approval::Unapproved => batch.scope == ScopeName::Personal && before_approval(&batch.changes),
                    Approval::NoProof => false,
                };
                if !allowed {
                    return Err(TransportError::DeviceNotApproved);
                }
            }
            ScopeName::Team(_) => {
                if batch.changes.iter().any(keyed) && approval != Approval::Approved {
                    return Err(TransportError::DeviceNotApproved);
                }
            }
        }
        if state.lapsed && batch.changes.iter().any(|change| !change.kind.is_key()) {
            return Err(TransportError::LicenseExpired);
        }
        Ok(())
    }

    // One change, in the order sent; the flag says whether it wrote.
    fn judge(&self, state: &mut State, owner: ScopeOwner, change: &Change) -> (ChangeOutcome, bool) {
        if let Err(code) = self.check(state, owner, change) {
            return (ChangeOutcome::Rejected { code }, false);
        }
        let stored = state
            .scopes
            .get(&owner)
            .and_then(|data| {
                data.records
                    .get(&(change.kind.as_str().to_owned(), change.record_id.clone()))
            })
            .cloned();
        if change.kind.is_key() {
            return self.judge_key(state, owner, change, stored);
        }
        match (&change.op, stored) {
            (ChangeOp::Delete, None) => (applied(None), false),
            (ChangeOp::Delete, Some(record)) if record.deleted.is_some() => (applied(Some(&record)), false),
            (_, Some(record)) if change.base.as_ref() != Some(&record.change_tag()) => (conflict(Some(&record)), false),
            (_, None) if change.base.is_some() => (conflict(None), false),
            (ChangeOp::Delete, Some(record)) => self.tombstone(state, owner, record),
            (ChangeOp::Write { patch, .. }, stored) => self.write(state, owner, change, patch, stored),
        }
    }

    fn judge_key(
        &self,
        state: &mut State,
        owner: ScopeOwner,
        change: &Change,
        stored: Option<StoredRecord>,
    ) -> (ChangeOutcome, bool) {
        let ChangeOp::Write { patch, .. } = &change.op else {
            return rejected(RejectedCode::CreateOnly);
        };
        if change.base.is_some() {
            return rejected(RejectedCode::CreateOnly);
        }
        match stored {
            // The same object again, as a retry or a push-back, answers applied and writes nothing.
            Some(record) if record.fields.as_ref() == Some(patch) => (applied(Some(&record)), false),
            Some(_) => rejected(RejectedCode::CreateOnly),
            None => self.write(state, owner, change, patch, None),
        }
    }

    fn check(&self, state: &State, owner: ScopeOwner, change: &Change) -> Result<(), RejectedCode> {
        let kind = change.kind.as_str();
        let reserved = kinds::is_reserved(kind);
        let id_fits = match change.kind.known() {
            Some(known) if reserved => record_id::check(known, &change.record_id).is_ok(),
            _ => record_id::well_formed(&change.record_id),
        };
        if !id_fits {
            return Err(RejectedCode::BadRecordId);
        }
        if !kinds::admits(owner.scope().records_scope(), kind) {
            return Err(RejectedCode::KindNotInScope);
        }
        if policy_refuses(state, owner, &change.kind) {
            return Err(RejectedCode::Policy);
        }
        self.check_role(state, owner, &change.kind)?;
        self.check_writer(change)?;
        if let ChangeOp::Write { patch, .. } = &change.op {
            if let Err(refusal) = limits::check(patch) {
                return Err(RejectedCode::parse(refusal.code()));
            }
            check_sealed(state, owner, kind, patch)?;
        }
        check_case(state, owner, change)
    }

    // 0051, Roles in a team scope, without the holder checks a key object's statement carries.
    fn check_role(&self, state: &State, owner: ScopeOwner, kind: &KindName) -> Result<(), RejectedCode> {
        let ScopeOwner::Team(team) = owner else {
            return Ok(());
        };
        let role = self.role(state, owner.scope()).ok_or(RejectedCode::Role)?;
        let rotation_due = state.teams.get(&team).is_some_and(|data| data.rotation_due);
        let allowed = match (role, kind.as_str()) {
            (_, "key.member") | (Role::Owner | Role::Admin, _) => true,
            (Role::Editor | Role::Member, "key.version" | "key.wrap" | "key.ring") => rotation_due,
            (Role::Editor, name) => !name.starts_with("key."),
            (Role::Member, _) => false,
        };
        if allowed { Ok(()) } else { Err(RejectedCode::Role) }
    }

    // A key object whose id names an account is bound to that account (0051, Writer binding).
    fn check_writer(&self, change: &Change) -> Result<(), RejectedCode> {
        let Ok(kind) = KeyKind::parse(change.kind.as_str()) else {
            return Ok(());
        };
        let bound = KeyRecordId::parse(kind, &change.record_id)
            .ok()
            .and_then(|id| id.bound_account());
        match bound {
            Some(account) if account != self.account.0 => Err(RejectedCode::WriterBound),
            _ => Ok(()),
        }
    }

    fn write(
        &self,
        state: &mut State,
        owner: ScopeOwner,
        change: &Change,
        patch: &Value,
        stored: Option<StoredRecord>,
    ) -> (ChangeOutcome, bool) {
        let empty_patch = matches!(patch, Value::Object(members) if members.is_empty());
        if let Some(record) = &stored
            && empty_patch
            && record.deleted.is_none()
        {
            return (applied(Some(record)), false);
        }
        if let Some(record) = &stored
            && record.deleted.is_some()
            && change.kind.as_str() == "history_entry"
            && record.deleted != Some(DeletedReason::Policy)
        {
            return rejected(RejectedCode::CreateOnly);
        }
        if let Some(record) = &stored
            && record.deleted.is_none()
            && change.kind.as_str() == "history_entry"
        {
            return rejected(RejectedCode::CreateOnly);
        }
        let base = stored
            .as_ref()
            .and_then(|record| record.fields.clone())
            .unwrap_or_else(|| Value::Object(Default::default()));
        let fields = merge_patch::apply(&base, patch);
        if let Err(refusal) = limits::check(&fields) {
            return rejected(RejectedCode::parse(refusal.code()));
        }
        let record = self.stamp(state, change, stored, Some(fields), None);
        (self.commit(state, owner, record), true)
    }

    fn tombstone(&self, state: &mut State, owner: ScopeOwner, record: StoredRecord) -> (ChangeOutcome, bool) {
        // Team library tombstones keep their fields until `/v1` sunsets (0051, Tombstones).
        let keep = record.kind.known().is_some_and(tablepro_records::Kind::is_team_library);
        let fields = if keep { record.fields.clone() } else { None };
        let change = Change {
            kind: record.kind.clone(),
            record_id: record.record_id.clone(),
            base: None,
            op: ChangeOp::Delete,
        };
        let tombstone = self.stamp(state, &change, Some(record), fields, Some(DeletedReason::User));
        (self.commit(state, owner, tombstone), true)
    }

    fn stamp(
        &self,
        state: &mut State,
        change: &Change,
        stored: Option<StoredRecord>,
        fields: Option<Value>,
        deleted: Option<DeletedReason>,
    ) -> StoredRecord {
        let revision = state.take_revision();
        let now = state.clock_us;
        StoredRecord {
            kind: change.kind.clone(),
            record_id: change.record_id.clone(),
            version: stored.as_ref().map_or(1, |record| record.version + 1),
            revision,
            written_epoch: state.epoch(),
            write_tag: *Uuid::new_v4().as_bytes(),
            fields,
            deleted,
            taken_at_us: stored.as_ref().map_or(now, |record| record.taken_at_us),
            updated_at_us: now,
            updated_device: Some(self.device_row.clone()),
            updated_by: Some(self.account),
        }
    }

    fn commit(&self, state: &mut State, owner: ScopeOwner, record: StoredRecord) -> ChangeOutcome {
        let outcome = applied(Some(&record));
        state
            .scopes
            .entry(owner)
            .or_default()
            .records
            .insert((record.kind.as_str().to_owned(), record.record_id.clone()), record);
        outcome
    }
}

pub(crate) fn expires_at(record: &StoredRecord) -> Option<i64> {
    (record.kind.as_str() == "key.request").then_some(record.taken_at_us + REQUEST_LIFETIME_US)
}

pub(crate) fn held_until(record: &StoredRecord) -> Option<i64> {
    (record.kind.as_str() == "key.reset" && record.deleted.is_none()).then_some(record.taken_at_us + RESET_HOLD_US)
}

// What a device writes before approval (0051, Before approval): its request and that request's steps; a genesis,
// rotation or reset activation, each led by its `key.account`; a reset proposal; an IK-signed cancel.
fn before_approval(changes: &[Change]) -> bool {
    let all = |kinds: &[&str]| changes.iter().all(|change| kinds.contains(&change.kind.as_str()));
    let account_set = changes.iter().any(|change| change.kind.as_str() == "key.account");
    all(&["key.request", "key.sas"]) || all(&["key.reset"]) || all(&["key.cancel"]) || account_set
}

// The newest version of a scope key, from the version records the scope holds: `<owner>/<purpose>/<version>`.
fn current_version(state: &State, owner: ScopeOwner, purpose: &str) -> Option<u32> {
    state
        .scopes
        .get(&owner)?
        .records
        .values()
        .filter(|record| record.kind.as_str() == "key.version")
        .filter_map(|record| {
            let mut parts = record.record_id.rsplitn(3, '/');
            let version = parts.next()?.parse::<u32>().ok()?;
            (parts.next()? == purpose).then_some(version)
        })
        .max()
}

// An envelope or history entry only under its scope key's current version, and a team envelope not while the team is
// due a rotation (0051, Scopes and records; Teams).
fn check_sealed(state: &State, owner: ScopeOwner, kind: &str, patch: &Value) -> Result<(), RejectedCode> {
    let (key_owner, purpose) = match (kind, owner) {
        ("secret_envelope", ScopeOwner::Personal(account)) => (ScopeOwner::Personal(account), "personal"),
        ("secret_envelope", ScopeOwner::Team(team)) => {
            if state.teams.get(&team).is_some_and(|data| data.rotation_due) {
                return Err(RejectedCode::RotationDue);
            }
            (ScopeOwner::Team(team), "team")
        }
        ("history_entry", ScopeOwner::History(account)) => (ScopeOwner::Personal(account), "history"),
        _ => return Ok(()),
    };
    let Some(kv) = patch.get("kv").and_then(Value::as_u64) else {
        return Ok(());
    };
    match current_version(state, key_owner, purpose).map(u64::from) {
        Some(current) if kv < current => Err(RejectedCode::KeyVersionStale),
        Some(current) if kv == current => Ok(()),
        _ => Err(RejectedCode::KeyVersionUnknown),
    }
}

// No two team library records of one kind whose ids match once lower-cased, tombstones included.
fn check_case(state: &State, owner: ScopeOwner, change: &Change) -> Result<(), RejectedCode> {
    let library = change.kind.known().is_some_and(tablepro_records::Kind::is_team_library);
    if !library || change.base.is_some() {
        return Ok(());
    }
    let collides = state.scopes.get(&owner).is_some_and(|data| {
        data.records.values().any(|record| {
            record.kind == change.kind
                && record.record_id != change.record_id
                && record.record_id.eq_ignore_ascii_case(&change.record_id)
        })
    });
    if collides {
        Err(RejectedCode::IdCaseCollision)
    } else {
        Ok(())
    }
}

fn named_twice(changes: &[Change]) -> bool {
    let mut seen = std::collections::HashSet::new();
    !changes
        .iter()
        .all(|change| seen.insert((change.kind.as_str(), change.record_id.as_str())))
}

fn applied(record: Option<&StoredRecord>) -> ChangeOutcome {
    ChangeOutcome::Applied {
        tag: record.map(StoredRecord::change_tag),
        service: record.map(|record| AppliedStamp {
            version: record.version,
            revision: record.revision,
        }),
    }
}

fn conflict(record: Option<&StoredRecord>) -> ChangeOutcome {
    ChangeOutcome::Conflict {
        stored: record.map(|record| StoredCopy {
            tag: record.change_tag(),
            tombstone: record.deleted.is_some(),
            service: Some(StoredStamp {
                version: record.version,
                revision: record.revision,
                epoch: record.written_epoch,
            }),
            fields: None,
        }),
    }
}

fn rejected(code: RejectedCode) -> (ChangeOutcome, bool) {
    (ChangeOutcome::Rejected { code }, false)
}

// A change set applies whole or not at all: the rejected change keeps its code, every other answers `change_set`.
fn whole_set_refused(outcomes: Vec<ChangeOutcome>) -> Vec<ChangeOutcome> {
    outcomes
        .into_iter()
        .map(|outcome| match outcome {
            ChangeOutcome::Rejected { code } => ChangeOutcome::Rejected { code },
            _ => ChangeOutcome::Rejected {
                code: RejectedCode::ChangeSet,
            },
        })
        .collect()
}

// The revisions the set wrote, which are consecutive since nothing else writes under the lock.
fn mark_change_set(state: &mut State, owner: ScopeOwner, wrote: &[Option<ChangeOutcome>]) {
    let revisions: Vec<u64> = wrote
        .iter()
        .filter_map(|outcome| match outcome {
            Some(ChangeOutcome::Applied {
                service: Some(stamp), ..
            }) => Some(stamp.revision),
            _ => None,
        })
        .collect();
    if let (Some(first), Some(last)) = (revisions.iter().min(), revisions.iter().max())
        && let Some(data) = state.scopes.get_mut(&owner)
    {
        data.change_sets.push((*first, *last));
    }
}
