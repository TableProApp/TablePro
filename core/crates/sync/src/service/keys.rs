// What the pass hands the key flows (0056; 0054, A pass): key objects in revision order or as a snapshot's one set,
// envelopes only under the version in force at their place, the push-back after a new epoch, the flows a crash left
// in `key_pending`, the stop reports and each team's roster once its pull is caught up.

use std::collections::HashSet;

use tablepro_keys::encoding::Version;
use tablepro_keys::envelope::EnvelopeId;
use tablepro_records::Kind;
use uuid::Uuid;

use super::{PassCtx, ServiceSync, begin};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, IdempotencyKey, KindName, ScopeName};
use crate::api::key_flows::{
    ArrivalOrder, CaughtUp, KeyApplied, KeyArrival, KeyHooks, LockCause, PushBackVerdict, Roster, StopAction,
};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{PendingFlow, Row, RowKey, RowRange, StoppedCause, Table};
use crate::api::transport::{Change, ChangeOutcome, Proof, PulledRecord, PushBatch};
use crate::engine::key_base;

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
    ) -> Result<KeyApplied, SyncError> {
        let arrival = KeyArrival { scope, records, order };
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
            let applied = self.arrive(scope, wanted, set, ArrivalOrder::Snapshot).await?;
            in_force = applied.in_force.or(in_force);
        }
        Ok(in_force)
    }

    // An envelope is taken only under the version in force at its place in the order, and never below the copy held
    // (0056, Rollback). One the keys refuse is held by id, and nothing takes it later under a looser order; any other
    // failure, as a locked device store, ends the pass before its page commits, so the page is read again.
    pub(super) async fn envelope_opens(
        &self,
        scope: ScopeName,
        record: &PulledRecord,
        in_force: Option<Version>,
    ) -> Result<bool, SyncError> {
        let Some(fields) = record.fields.clone().filter(|_| record.deleted.is_none()) else {
            return Ok(true);
        };
        let Ok(envelope) = EnvelopeId::parse(&record.record_id) else {
            return Ok(false);
        };
        self.stop.check()?;
        let opened = match scope {
            ScopeName::Team(team) => self.keys.open_team_envelope(team, envelope, fields, in_force).await,
            ScopeName::Personal | ScopeName::History => {
                self.keys.open_personal_envelope(envelope, fields, in_force).await
            }
        };
        match opened {
            Ok(_) => Ok(true),
            Err(SyncError::Keys(error)) => {
                tracing::debug!(code = error.code(), "an envelope was not taken");
                Ok(false)
            }
            Err(error) => Err(error),
        }
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
        let mut closed: HashSet<ScopeName> = HashSet::new();
        for set in self.keys.push_back(epoch).await? {
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
            let Some(key) = self.proofs.dpop_key().await? else {
                return Ok(());
            };
            match action {
                StopAction::Report { team, version } => {
                    self.transport.report_stopped(team, version, key).await?;
                }
                StopAction::Withdraw { team } => self.transport.withdraw_stopped(team, key).await?,
            }
            self.keys.stop_action_sent(action).await?;
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
