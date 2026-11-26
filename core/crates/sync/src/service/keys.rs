// What the pass hands the key flows (0056; 0054, A pass): key objects in revision order or as a snapshot's one set,
// envelopes only under the version in force at their place, the push-back after a new epoch, the flows a crash left
// in `key_pending`, the stop reports and each team's roster once its pull is caught up.

use std::collections::HashSet;
use std::sync::Arc;

use sha2::{Digest, Sha256};
use tablepro_keys::encoding::{HistoryId, KeyPurpose, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_records::Kind;
use tablepro_records::record_id::parse_uuid;
use uuid::Uuid;

use super::{PassCtx, ServiceSync, begin, scope_refusal};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, IdempotencyKey, KindName, ScopeName};
use crate::api::key_flows::{
    ArrivalOrder, CaughtUp, KeyApplied, KeyArrival, KeyHooks, KeyState, LockCause, PushBackVerdict, Roster, StopAction,
};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateStore, StoppedCause, Table};
use crate::api::transport::{Change, ChangeOutcome, Proof, PulledRecord, PushBatch};
use crate::engine::key_base;

// What the keys made of a pulled envelope.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Opens {
    Taken,
    Refused,
    Waits,
}

// What a scope's waiting envelopes were judged against: its key rows and the personal scope's, a digest of the key
// objects both hold, the pins, whether the device could check envelopes at all, and whether its key tables still
// rebuilt. Only a change here can let a waiting envelope open.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct KeyMark {
    rows: Vec<Row>,
    objects: [u8; 32],
    pins: Vec<Row>,
    can_open: bool,
    rebuilding: bool,
}

pub(super) async fn key_mark(
    state: &Arc<dyn StateStore>,
    scope: ScopeName,
    can_open: bool,
    rebuilding: bool,
) -> Result<KeyMark, SyncError> {
    let mut txn = begin(state).await?;
    let mut scopes = vec![scope];
    if scope != ScopeName::Personal {
        scopes.push(ScopeName::Personal);
    }
    let mut rows = Vec::new();
    let mut objects = Sha256::new();
    for scope in scopes {
        rows.extend(txn.scan(&RowRange::Scope(Table::KeyVersions, scope)).await?);
        for row in txn.scan(&RowRange::Scope(Table::KeyObjects, scope)).await? {
            if let Row::KeyObject(object) = row {
                for part in [
                    object.scope.wire().as_bytes(),
                    object.kind.as_str().as_bytes(),
                    object.record_id.as_bytes(),
                    object.fields.as_bytes(),
                ] {
                    objects.update(u64::try_from(part.len()).unwrap_or(u64::MAX).to_be_bytes());
                    objects.update(part);
                }
                objects.update([u8::from(object.applied)]);
            }
        }
    }
    Ok(KeyMark {
        rows,
        objects: objects.finalize().into(),
        pins: txn.scan(&RowRange::Table(Table::KeyPins)).await?,
        can_open,
        rebuilding,
    })
}

// What the keys made of a pulled history entry: its plaintext, or why the device holds it by id.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum HistoryOpens {
    Plain(serde_json::Value),
    Refused,
    Waits,
}

// Which flow reads a key kind: the account's own objects, an approval session's, a reset's, or a team's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Family {
    Account,
    Session,
    Reset,
    Team,
}

pub(super) fn family(scope: ScopeName, kind: &KindName) -> Option<Family> {
    if !kind.is_key() {
        return None;
    }
    if let ScopeName::Team(_) = scope {
        return Some(Family::Team);
    }
    Some(match kind.known() {
        Some(Kind::KeyRequest | Kind::KeySas) => Family::Session,
        Some(Kind::KeyReset | Kind::KeyCancel) => Family::Reset,
        _ => Family::Account,
    })
}

// A snapshot's set goes in with the account's objects first, which a reset and a session are judged against.
const SET_ORDER: [Family; 4] = [Family::Account, Family::Team, Family::Reset, Family::Session];

impl ServiceSync {
    pub(super) async fn arrive(
        &self,
        scope: ScopeName,
        family: Family,
        records: Vec<PulledRecord>,
        order: ArrivalOrder,
        in_force: Option<Version>,
    ) -> Result<KeyApplied, SyncError> {
        let arrival = KeyArrival {
            scope,
            records,
            order,
            in_force,
        };
        match family {
            Family::Account => self.keys.apply_account_objects(arrival).await,
            Family::Session => self.keys.apply_session_objects(arrival).await,
            Family::Reset => self.keys.apply_reset_objects(arrival).await,
            Family::Team => self.keys.apply_team_objects(arrival).await,
        }
    }

    // A snapshot's key objects once the pull is caught up, as one set per flow; the version in force after them.
    pub(super) async fn arrive_set(
        &self,
        scope: ScopeName,
        records: Vec<PulledRecord>,
    ) -> Result<Option<Version>, SyncError> {
        let mut in_force = None;
        for wanted in SET_ORDER {
            let set: Vec<PulledRecord> = records
                .iter()
                .filter(|record| family(scope, &record.kind) == Some(wanted))
                .cloned()
                .collect();
            if set.is_empty() {
                continue;
            }
            self.stop.check()?;
            let applied = self.arrive(scope, wanted, set, ArrivalOrder::Snapshot, None).await?;
            in_force = applied.in_force.or(in_force);
        }
        Ok(in_force)
    }

    // An envelope is taken only under the version in force at its place in the order, and never below the copy held
    // (0056, Rollback). One the keys refuse is held by id, and nothing takes it later under a looser order. One they
    // cannot judge yet, as a team this device holds no key of or key tables still being rebuilt, waits for a snapshot
    // once they can. Any other failure, as a locked device store, ends the pass before its page commits, so the page
    // is read again.
    pub(super) async fn envelope_opens(
        &self,
        scope: ScopeName,
        record: &PulledRecord,
        in_force: Option<Version>,
    ) -> Result<Opens, SyncError> {
        let Some(fields) = record.fields.clone().filter(|_| record.deleted.is_none()) else {
            return Ok(Opens::Taken);
        };
        let Ok(envelope) = EnvelopeId::parse(&record.record_id) else {
            return Ok(Opens::Refused);
        };
        self.stop.check()?;
        let opened = match scope {
            ScopeName::Team(team) => self.keys.open_team_envelope(team, envelope, fields, in_force).await,
            ScopeName::Personal | ScopeName::History => {
                self.keys.open_personal_envelope(envelope, fields, in_force).await
            }
        };
        match opened {
            Ok(_) => Ok(Opens::Taken),
            Err(SyncError::Keys(error)) => {
                tracing::debug!(code = error.code(), "an envelope was not taken");
                Ok(Opens::Refused)
            }
            Err(error @ (SyncError::NotAllowed { .. } | SyncError::Locked { .. })) => {
                tracing::debug!(code = error.code(), "an envelope waits until the keys can judge it");
                Ok(Opens::Waits)
            }
            Err(error) => Err(error),
        }
    }

    // A history entry is sealed under the history key, so the store takes its plaintext (0056, Envelopes and history).
    // One the keys refuse is held by id; one they cannot open yet waits, as an envelope does.
    pub(super) async fn history_opens(&self, record: &PulledRecord) -> Result<HistoryOpens, SyncError> {
        let (Some(fields), Some(id)) = (record.fields.clone(), parse_uuid(&record.record_id)) else {
            return Ok(HistoryOpens::Refused);
        };
        self.stop.check()?;
        match self.keys.open_history_entry(HistoryId(id), fields).await {
            Ok(plain) if plain.is_object() => Ok(HistoryOpens::Plain(plain)),
            Ok(_) => Ok(HistoryOpens::Refused),
            Err(SyncError::Keys(error)) => {
                tracing::debug!(code = error.code(), "a history entry was not taken");
                Ok(HistoryOpens::Refused)
            }
            Err(error @ (SyncError::NotAllowed { .. } | SyncError::Locked { .. })) => {
                tracing::debug!(code = error.code(), "a history entry waits until the keys can open it");
                Ok(HistoryOpens::Waits)
            }
            Err(error) => Err(error),
        }
    }

    // Whether history entries can be opened now: only on an unlocked device whose keys are approved.
    pub(super) async fn history_opens_now(&self) -> bool {
        self.hooks.locked().is_none() && matches!(self.keys.key_state().await, Ok(KeyState::Approved { .. }))
    }

    // Whether this device holds the scope's key in force, so envelopes kept waiting can be read again.
    pub(super) async fn holds_scope_key(&self, scope: ScopeName) -> Result<bool, SyncError> {
        let purpose = match scope {
            ScopeName::Team(_) => KeyPurpose::Team,
            ScopeName::Personal => KeyPurpose::Personal,
            ScopeName::History => return Ok(true),
        };
        let row = begin(&self.state)
            .await?
            .get(&RowKey::KeyVersion(scope, purpose))
            .await?;
        Ok(matches!(row, Some(Row::KeyVersion(row)) if row.state == KeyVersionState::Ok))
    }

    // On a new epoch, before any other record: the key objects this account signed that the server lacks, one change
    // set per push in the flows' order, each refusal final (0051, After a restore). An unanswered set ends the pass, so
    // the next one starts the push-back over; a refused account set stops it, and a scope that ended sends nothing
    // more. A team waiting on a version another account signed resumes its push-back once that version is back, so the
    // push-back runs again on every pass while one waits (0062).
    pub(super) async fn push_back(&self, ctx: &mut PassCtx) -> Result<(), SyncError> {
        let epoch = ctx.body.epoch;
        let due = ctx.pushed_back != Some(epoch) && (ctx.new_epoch || self.restore_waits(ctx).await?);
        if !due {
            return self.adopt_epoch(ctx).await;
        }
        // What the key flows cannot judge, as an account certificate this device never held, goes back from another
        // device of the account; the rest of the pass goes on.
        let sets = match self.keys.push_back(epoch).await {
            Ok(sets) => sets,
            Err(SyncError::NotAllowed { what }) => {
                tracing::debug!(what, "nothing goes back from this device");
                Vec::new()
            }
            Err(error) => return Err(error),
        };
        let mut closed: HashSet<ScopeName> = HashSet::new();
        for set in sets {
            if closed.contains(&set.scope) {
                continue;
            }
            self.stop.check()?;
            let scope = set.scope;
            let batch = PushBatch {
                scope,
                epoch: Some(epoch),
                idempotency_key: Some(IdempotencyKey(Uuid::new_v4().to_string())),
                changes: set.changes.clone(),
                proof: Proof::Dpop(set.proof.clone()),
            };
            let answer = self.transport.push(batch).await?;
            if answer.outcomes.len() != set.changes.len() {
                return Err(SyncError::Malformed { what: "push answer" });
            }
            self.keep_key_bases(scope, epoch, &set.changes, &answer.outcomes)
                .await?;
            match self.keys.push_back_answered(set, answer.outcomes).await? {
                PushBackVerdict::Continue => {}
                PushBackVerdict::Wait { scope } => {
                    self.hooks.stop_scope(scope, StoppedCause::RestoreWait);
                    closed.insert(scope);
                }
                PushBackVerdict::Ended { scope } => {
                    self.hooks.end_scope(scope, Some(epoch));
                    closed.insert(scope);
                }
                PushBackVerdict::AccountEnded => {
                    tracing::debug!(%scope, "the account's own key objects were refused");
                    self.hooks.lock(LockCause::AccountEnded);
                    ctx.locked = true;
                    ctx.keys_ready = false;
                    break;
                }
            }
        }
        ctx.pushed_back = Some(epoch);
        self.adopt_epoch(ctx).await
    }

    // A team this sign-in still reaches whose row is stopped as `restore_wait`.
    async fn restore_waits(&self, ctx: &PassCtx) -> Result<bool, SyncError> {
        let mut txn = begin(&self.state).await?;
        Ok(txn.scan(&RowRange::Table(Table::KeyVersions)).await?.iter().any(|row| {
            matches!(row, Row::KeyVersion(row) if row.stopped_cause == Some(StoppedCause::RestoreWait)
                && ctx.body.scopes.iter().any(|info| info.scope == row.scope))
        }))
    }

    // What the server took is what it holds now, so a push-back run again does not judge it lost.
    async fn keep_key_bases(
        &self,
        scope: ScopeName,
        epoch: EpochId,
        changes: &[Change],
        outcomes: &[ChangeOutcome],
    ) -> Result<(), SyncError> {
        let bases: Vec<_> = changes
            .iter()
            .zip(outcomes)
            .filter_map(|(change, outcome)| key_base(scope, epoch, change, outcome))
            .collect();
        if bases.is_empty() {
            return Ok(());
        }
        self.stop.check()?;
        let mut txn = begin(&self.state).await?;
        for base in bases {
            txn.put(Row::Base(base)).await?;
        }
        txn.commit().await?;
        Ok(())
    }

    // The refilled scopes take the epoch and its lineage only now, so a pass cut short before the push-back answered
    // refills and pushes back again. A scope that refilled against another epoch than the one pushed back for stays in
    // refill for the next pass.
    async fn adopt_epoch(&self, ctx: &mut PassCtx) -> Result<(), SyncError> {
        let Some(epoch) = ctx.pushed_back else {
            return Ok(());
        };
        let adopt: Vec<_> = std::mem::take(&mut ctx.adopt)
            .into_iter()
            .filter(|(_, against, _)| *against == epoch)
            .collect();
        if adopt.is_empty() {
            return Ok(());
        }
        self.stop.check()?;
        let mut txn = begin(&self.state).await?;
        for (scope, against, lineage) in adopt {
            if let Some(Row::Scope(mut row)) = txn.get(&RowKey::Scope(scope)).await? {
                row.refill = false;
                row.epoch = Some(against);
                row.lineage = lineage;
                txn.put(Row::Scope(row)).await?;
            }
        }
        txn.commit().await?;
        Ok(())
    }

    // Key flows that span pushes resume at the next pass (0054, `key_pending`). One that fails waits for the next.
    pub(super) async fn resume_flows(&self) {
        let pending = match begin(&self.state).await {
            Ok(mut txn) => txn.scan(&RowRange::Table(Table::KeyPending)).await.unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        for row in pending {
            if self.stop.is_stopped() {
                return;
            }
            let Row::KeyPending(row) = row else { continue };
            let resumed = match row.flow {
                PendingFlow::AccountRotation { av } => self.keys.resume_rotation(av).await,
                PendingFlow::Approval { request } => self.keys.resume_approval(request).await,
                PendingFlow::ResetProposal { reset } => self.keys.resume_reset(reset).await,
                PendingFlow::StopWithdrawal { team } => self.keys.resume_withdrawal(team).await,
            };
            if let Err(error) = resumed {
                tracing::debug!(code = error.code(), flow = %row.flow.key_text(), "a key flow waits for the next pass");
            }
        }
    }

    // The stop reports and withdrawals the flows queued, withdrawals first per team, each told back once sent.
    pub(super) async fn stop_actions(&self, ctx: &PassCtx) -> Result<(), SyncError> {
        if !ctx.keyed {
            return Ok(());
        }
        let actions = match self.keys.stop_actions().await {
            Ok(actions) => actions,
            Err(error) => {
                tracing::debug!(code = error.code(), "no stop actions this pass");
                return Ok(());
            }
        };
        for action in actions {
            self.stop.check()?;
            let Some(key) = self.keys.dpop_key().await? else {
                return Ok(());
            };
            let sent = match action {
                StopAction::Report { team, version } => self.transport.report_stopped(team, version, key).await,
                StopAction::Withdraw { team } => self.transport.withdraw_stopped(team, key).await,
            };
            match sent {
                Ok(()) => self.keys.stop_action_sent(action).await?,
                // A team this device left, or a call its row may not make now, refuses the action alone; it stays
                // queued and the rest of the pass goes on.
                Err(error) if scope_refusal(&SyncError::Transport(error.clone())).is_some() => {
                    tracing::debug!(code = error.code(), "a stop action waits");
                }
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }

    // The roster and role are decided on only after the team's pull is caught up (0051, `members`).
    pub(super) async fn read_roster(&self, info: &ScopeInfo, caught_up: Option<CaughtUp>) {
        let ScopeName::Team(team) = info.scope else {
            return;
        };
        if self.stop.is_stopped() || caught_up.is_none() {
            return;
        }
        if let Err(error) = self.keys.roster_read(team, Roster::of(info, caught_up)).await {
            tracing::debug!(code = error.code(), "the roster waits for the next pass");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::key_mark;
    use crate::api::ids::{KindName, ScopeName};
    use crate::api::state::{KeyObjectRow, Row, RowKey};
    use crate::keys::test_fakes::Rig;
    use crate::keys::test_world::World;

    fn object(scope: ScopeName, record_id: &str) -> Row {
        Row::KeyObject(KeyObjectRow {
            scope,
            kind: KindName::parse("key.sas").unwrap(),
            record_id: record_id.to_owned(),
            fields: "{}".to_owned(),
            applied: true,
            served: None,
        })
    }

    // A session step purged while a ring arrives leaves as many key objects as before: the mark still moves, so the
    // envelopes that wait on the ring are read again.
    #[tokio::test]
    async fn the_key_mark_moves_when_one_key_object_gives_way_to_another() {
        let world = World::load();
        let rig = Rig::new(&world.origin, world.account("P"));
        let state = rig.service.state().clone();
        let team = ScopeName::Team(world.team);
        rig.put([object(ScopeName::Personal, "request/nonce")]).await;
        let before = key_mark(&state, team, true, false).await.unwrap();

        let mut txn = rig.service.begin().await.unwrap();
        txn.delete(&RowKey::KeyObject(
            ScopeName::Personal,
            KindName::parse("key.sas").unwrap(),
            "request/nonce".to_owned(),
        ))
        .await
        .unwrap();
        txn.put(object(team, "ring")).await.unwrap();
        txn.commit().await.unwrap();
        let after = key_mark(&state, team, true, false).await.unwrap();

        assert_ne!(before, after);
    }

    // A rebuild that ends moves no key row, yet the envelopes it held can open now.
    #[tokio::test]
    async fn the_key_mark_moves_when_the_rebuild_ends() {
        let world = World::load();
        let rig = Rig::new(&world.origin, world.account("P"));
        let state = rig.service.state().clone();

        let rebuilding = key_mark(&state, ScopeName::Personal, true, true).await.unwrap();
        let rebuilt = key_mark(&state, ScopeName::Personal, true, false).await.unwrap();

        assert_ne!(rebuilding, rebuilt);
    }
}
