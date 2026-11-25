// What the pass hands the key flows (0056; 0054, A pass): key objects in revision order or as a snapshot's one set,
// envelopes only under the version in force at their place, the push-back after a new epoch, the flows a crash left
// in `key_pending`, the stop reports and each team's roster once its pull is caught up.

use tablepro_keys::encoding::Version;
use tablepro_keys::envelope::EnvelopeId;
use tablepro_records::Kind;
use uuid::Uuid;

use super::{PassCtx, ServiceSync, begin};
use crate::api::error::SyncError;
use crate::api::ids::{IdempotencyKey, KindName, ScopeName};
use crate::api::key_flows::{
    ArrivalOrder, KeyApplied, KeyArrival, KeyHooks, LockCause, PushBackVerdict, Roster, StopAction, StopCause,
};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{PendingFlow, Row, RowKey, RowRange, Table};
use crate::api::transport::{Proof, PulledRecord, PushBatch};

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
    // set per push, each refusal final (0051, After a restore).
    pub(super) async fn push_back(&self, ctx: &mut PassCtx) -> Result<(), SyncError> {
        let epoch = ctx.body.epoch;
        if !ctx.new_epoch || ctx.pushed_back == Some(epoch) {
            return self.adopt_epoch(ctx).await;
        }
        for set in self.keys.push_back(epoch).await? {
            self.stop.check()?;
            let batch = PushBatch {
                scope: set.scope,
                epoch: Some(epoch),
                idempotency_key: Some(IdempotencyKey(Uuid::new_v4().to_string())),
                changes: set.changes.clone(),
                proof: Proof::Dpop(set.proof.clone()),
            };
            let answer = self.transport.push(batch).await?;
            let scope = set.scope;
            match self.keys.push_back_answered(set, answer.outcomes).await? {
                PushBackVerdict::Continue => {}
                PushBackVerdict::Wait { scope } => self.hooks.stop_scope(scope, StopCause::AwaitingPushBack),
                PushBackVerdict::Ended { scope } => self.hooks.end_scope(scope, Some(epoch)),
                PushBackVerdict::AccountEnded => {
                    tracing::debug!(%scope, "the account's own key objects were refused");
                    self.hooks.lock(LockCause::AccountEnded);
                }
            }
        }
        ctx.pushed_back = Some(epoch);
        self.adopt_epoch(ctx).await
    }

    // The refilled scopes take the epoch and its lineage only now, so a pass cut short before the push-back answered
    // refills and pushes back again.
    async fn adopt_epoch(&self, ctx: &mut PassCtx) -> Result<(), SyncError> {
        let adopt = std::mem::take(&mut ctx.adopt);
        if adopt.is_empty() {
            return Ok(());
        }
        self.stop.check()?;
        let mut txn = begin(&self.state).await?;
        for (scope, lineage) in adopt {
            if let Some(Row::Scope(mut row)) = txn.get(&RowKey::Scope(scope)).await? {
                row.refill = false;
                row.epoch = Some(ctx.body.epoch);
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
        let Some(key) = ctx.key.clone() else {
            return Ok(());
        };
        let actions = match self.keys.stop_actions().await {
            Ok(actions) => actions,
            Err(error) => {
                tracing::debug!(code = error.code(), "no stop actions this pass");
                return Ok(());
            }
        };
        for action in actions {
            self.stop.check()?;
            match action {
                StopAction::Report { team, version } => {
                    self.transport.report_stopped(team, version, key.clone()).await?;
                }
                StopAction::Withdraw { team } => self.transport.withdraw_stopped(team, key.clone()).await?,
            }
            self.keys.stop_action_sent(action).await?;
        }
        Ok(())
    }

    // The roster and role are decided on only after the team's pull is caught up (0051, `members`).
    pub(super) async fn read_roster(&self, info: &ScopeInfo) {
        let ScopeName::Team(team) = info.scope else {
            return;
        };
        if self.stop.is_stopped() {
            return;
        }
        let roster = Roster {
            members: info.members.clone(),
            role: info.role,
            rotation_due: info.rotation_due,
            caught_up: true,
        };
        if let Err(error) = self.keys.roster_read(team, roster).await {
            tracing::debug!(code = error.code(), "the roster waits for the next pass");
        }
    }
}
