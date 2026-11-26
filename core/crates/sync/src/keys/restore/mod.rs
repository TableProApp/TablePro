// `RestoreFlows` (0051, Keys on the wire, After a restore and What cannot go back; 0056, What the server stores and
// checks, After a restore; 0062). After a new epoch the device pushes back the key objects its own account signed
// that the server lacks, exactly as it holds them, in 0051's order. A version another account signed that the server
// lacks, or a holding its own next version needs, stops the team as `restore_wait` until the server holds it again.
// Every refusal is final.

mod plan;
mod server;
#[cfg(test)]
pub(crate) mod tests;

use async_trait::async_trait;
use serde_json::Value;
use tablepro_keys::encoding::{KeyPurpose, TeamId};
use tablepro_keys::record_id::KeyRecordId;

use self::plan::{Inputs, Plan, TeamInputs, TeamVerdict};
use self::server::BaseView;
use super::team::TeamJudged;
use super::{HeldObject, KeyService};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, KindName, ScopeName};
use crate::api::key_flows::{KeyChangeSet, KeyNoticeKind, LockCause, PushBackVerdict, RestoreFlows};
use crate::api::scopes::{ScopeInfo, ScopesAnswer, ScopesBody};
use crate::api::state::{KeyVersionRow, KeyVersionState, Row, RowKey, RowRange, StateTxn, StoppedCause, Table};
use crate::api::transport::{Change, ChangeOp, ChangeOutcome, Proof, RejectedCode};
use crate::keys::stop;

#[async_trait]
impl RestoreFlows for KeyService {
    async fn push_back(&self, epoch: EpochId) -> Result<Vec<KeyChangeSet>, SyncError> {
        let _serial = self.serialized().await;
        let proof = self.dpop_key().await?;
        let body = self.scopes_body().await?;
        if body.epoch != epoch {
            return Err(SyncError::Transport(
                crate::api::transport::TransportError::EpochChanged,
            ));
        }
        let mut txn = self.begin().await?;
        let Some(own) = self.own_account(&mut *txn).await? else {
            return Ok(Vec::new());
        };
        let gathered = self.gather(&mut *txn, &body).await?;
        let held: Vec<(ScopeName, &HeldObject)> = gathered
            .personal
            .iter()
            .map(|object| (ScopeName::Personal, object))
            .chain(gathered.teams.iter().flat_map(|team| {
                team.objects
                    .iter()
                    .map(move |object| (ScopeName::Team(team.team), object))
            }))
            .collect();
        let mut view = BaseView::new(&body, &gathered.bases, &held);
        self.check_other_versions(&mut *txn, &held, &mut view).await?;
        let plan = plan::plan(&Inputs {
            account: self.account(),
            key_device: own.device.key_device,
            newest_av: own.av,
            approved: scope_info(&body, ScopeName::Personal).and_then(|info| info.approved) == Some(true),
            personal: &gathered.personal,
            teams: gathered
                .teams
                .iter()
                .map(|team| TeamInputs {
                    team: team.team,
                    objects: &team.objects,
                    row: team.row.as_ref(),
                    roster: team.roster.as_deref(),
                })
                .collect(),
            server: &view,
        });
        let effects = self.apply_verdicts(&mut *txn, &gathered, &plan, epoch).await?;
        txn.commit().await?;
        self.announce(&effects).await?;
        // An account certificate this device never held leaves nothing of its own to push back: another device of the
        // account puts that set back. Each team's wait or end above still stands.
        if plan.blind {
            return Ok(Vec::new());
        }
        plan.sets
            .into_iter()
            .map(|set| {
                Ok(KeyChangeSet {
                    scope: set.scope,
                    changes: set.objects.iter().map(push_back_change).collect::<Result<_, _>>()?,
                    proof: proof.clone(),
                })
            })
            .collect()
    }

    async fn push_back_answered(
        &self,
        set: KeyChangeSet,
        outcomes: Vec<ChangeOutcome>,
    ) -> Result<PushBackVerdict, SyncError> {
        if outcomes.len() != set.changes.len() || set.changes.is_empty() {
            return Err(SyncError::Malformed {
                what: "push-back answer",
            });
        }
        if outcomes
            .iter()
            .all(|outcome| matches!(outcome, ChangeOutcome::Applied { .. }))
        {
            return Ok(PushBackVerdict::Continue);
        }
        let refusal = refusal(&set, &outcomes);
        if refusal == Refusal::Nothing {
            return Ok(PushBackVerdict::Continue);
        }
        let _serial = self.serialized().await;
        // The server's current epoch, which a push in another epoch would have met as `epoch_changed`. None when the
        // server cannot be asked now: the refusal is recorded all the same.
        let epoch = self.current_epoch().await;
        let mut txn = self.begin().await?;
        match refusal {
            Refusal::AccountEnds => {
                for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
                    if let Some(row) = version_row(&mut *txn, ScopeName::Personal, purpose).await? {
                        txn.put(Row::KeyVersion(stop::ended(row, epoch))).await?;
                    }
                }
                txn.commit().await?;
                self.hooks().end_scope(ScopeName::Personal, epoch);
                self.hooks().lock(LockCause::AccountEnded);
                self.raise_notice(KeyNoticeKind::Locked {
                    cause: LockCause::AccountEnded,
                })?;
                Ok(PushBackVerdict::AccountEnded)
            }
            Refusal::TeamEnds(team) => {
                self.end_team(&mut *txn, team, epoch).await?;
                txn.commit().await?;
                self.team_ended(team, epoch)?;
                Ok(PushBackVerdict::Ended {
                    scope: ScopeName::Team(team),
                })
            }
            Refusal::TeamWaits(team) => {
                let scope = ScopeName::Team(team);
                let stopped = match version_row(&mut *txn, scope, KeyPurpose::Team).await? {
                    Some(mut row) if row.state == KeyVersionState::Ok => {
                        row.stop(StoppedCause::RestoreWait);
                        txn.put(Row::KeyVersion(row)).await?;
                        true
                    }
                    _ => false,
                };
                txn.commit().await?;
                if stopped {
                    self.hooks().stop_scope(scope, StoppedCause::RestoreWait);
                    self.raise_notice(KeyNoticeKind::ScopeStopped {
                        scope,
                        cause: StoppedCause::RestoreWait,
                    })?;
                }
                Ok(PushBackVerdict::Wait { scope })
            }
            Refusal::Nothing => Ok(PushBackVerdict::Continue),
        }
    }
}

pub(crate) struct GatheredTeam {
    team: TeamId,
    objects: Vec<HeldObject>,
    row: Option<KeyVersionRow>,
    roster: Option<Vec<crate::api::scopes::TeamMember>>,
}

pub(crate) struct Gathered {
    personal: Vec<HeldObject>,
    teams: Vec<GatheredTeam>,
    bases: server::Bases,
}

#[derive(Default)]
struct Effects {
    stopped: Vec<TeamId>,
    resumed: Vec<TeamId>,
    judged: Vec<TeamJudged>,
    ended: Vec<TeamId>,
    epoch: Option<EpochId>,
}

// What a refused push-back set does (0051, What cannot go back): an account change set ends the account, a team
// version ends the team, and a wrap or a `key.member` alone ends nothing: neither is a version, a lost confirmation
// is made again at the next team version, and the account copies its next certificate after its next `av`. A set
// refused only for `key_dependency` ends nothing either: what it depends on can still come back (0064).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    AccountEnds,
    TeamEnds(TeamId),
    TeamWaits(TeamId),
    Nothing,
}

fn refusal(set: &KeyChangeSet, outcomes: &[ChangeOutcome]) -> Refusal {
    // The rest of a refused change set answers `change_set`, which is no cause of its own.
    let causes: Vec<&RejectedCode> = outcomes
        .iter()
        .filter_map(|outcome| match outcome {
            ChangeOutcome::Rejected { code } if *code != RejectedCode::ChangeSet => Some(code),
            _ => None,
        })
        .collect();
    let only_dependency = !causes.is_empty() && causes.iter().all(|code| **code == RejectedCode::KeyDependency);
    match set.scope {
        ScopeName::Personal | ScopeName::History if only_dependency => Refusal::Nothing,
        ScopeName::Personal | ScopeName::History => Refusal::AccountEnds,
        ScopeName::Team(team) => {
            let alone = matches!(
                set.changes.as_slice(),
                [change] if matches!(change.kind.as_str(), "key.wrap" | "key.member")
            );
            if alone {
                Refusal::Nothing
            } else if only_dependency {
                // The versions above it need this one, so the team's push-back waits for what it depends on.
                Refusal::TeamWaits(team)
            } else {
                Refusal::TeamEnds(team)
            }
        }
    }
}

// A wrap or a `key.member` alone: its refusal ends nothing, so it never holds a wait open either (0051).
fn goes_alone(set: &plan::PlannedSet) -> bool {
    matches!(
        set.objects.as_slice(),
        [held] if matches!(held.object.id.kind().name(), "key.wrap" | "key.member")
    )
}

fn scope_info(body: &ScopesBody, scope: ScopeName) -> Option<&ScopeInfo> {
    body.scopes.iter().find(|info| info.scope == scope)
}

async fn version_row(
    txn: &mut dyn StateTxn,
    scope: ScopeName,
    purpose: KeyPurpose,
) -> Result<Option<KeyVersionRow>, SyncError> {
    match txn.get(&RowKey::KeyVersion(scope, purpose)).await? {
        Some(Row::KeyVersion(row)) => Ok(Some(row)),
        _ => Ok(None),
    }
}

async fn held_in(txn: &mut dyn StateTxn, scope: ScopeName) -> Result<Vec<HeldObject>, SyncError> {
    txn.scan(&RowRange::Scope(Table::KeyObjects, scope))
        .await?
        .iter()
        .filter_map(|row| match row {
            Row::KeyObject(row) => Some(HeldObject::of(row)),
            _ => None,
        })
        .collect()
}

// A held key object as the create that puts it back: no base, and its fields exactly as the device holds them.
fn push_back_change(held: &HeldObject) -> Result<Change, SyncError> {
    let fields: Value = serde_json::from_str(&held.fields).map_err(|_| SyncError::Malformed {
        what: "held key object",
    })?;
    Ok(Change {
        kind: KindName::parse(held.object.id.kind().name())?,
        record_id: held.object.id.to_wire(),
        base: None,
        op: ChangeOp::Write {
            patch: fields.clone(),
            fields,
        },
    })
}

impl KeyService {
    // A team version the server holds as another record ends the team only when this device checked that record: a
    // version record of the id its signer's certificate in the team verifies, beside the device's own (0051, What
    // cannot go back).
    async fn check_other_versions(
        &self,
        txn: &mut dyn StateTxn,
        held: &[(ScopeName, &HeldObject)],
        view: &mut BaseView<'_>,
    ) -> Result<(), SyncError> {
        for (scope, object) in held {
            let (ScopeName::Team(_), KeyRecordId::Version(key)) = (scope, object.object.id) else {
                continue;
            };
            let Some(fields) = view.other_fields(*scope, &object.object.id).cloned() else {
                continue;
            };
            if self.signed_team_version(txn, key, &fields).await? {
                view.checked_other(*scope, &object.object.id);
            }
        }
        Ok(())
    }

    // The body names the epoch with or without a proof, so asking for it needs no device keys.
    async fn current_epoch(&self) -> Option<EpochId> {
        match self.transport().scopes(None, Proof::None).await {
            Ok(ScopesAnswer::Body { body, .. }) => Some(body.epoch),
            _ => None,
        }
    }

    pub(crate) async fn scopes_body(&self) -> Result<ScopesBody, SyncError> {
        let proof = Proof::Dpop(self.dpop_key().await?);
        match self.transport().scopes(None, proof).await? {
            ScopesAnswer::Body { body, .. } => Ok(*body),
            ScopesAnswer::NotModified => Err(SyncError::Malformed { what: "scopes answer" }),
        }
    }

    // The key objects of the personal scope and of each team this sign-in still reaches, with the team rows, each
    // team's roster from this body when the team's pull is caught up, and the bases that say what the server holds.
    async fn gather(&self, txn: &mut dyn StateTxn, body: &ScopesBody) -> Result<Gathered, SyncError> {
        let personal = held_in(txn, ScopeName::Personal).await?;
        let mut bases = server::Bases::default();
        bases.load(txn, ScopeName::Personal).await?;
        if !personal.is_empty() && !server::has_view(&bases, ScopeName::Personal) {
            return Err(SyncError::NotAllowed {
                what: "push back key objects the engine kept no bases for",
            });
        }
        let mut teams = Vec::new();
        for info in &body.scopes {
            let ScopeName::Team(team) = info.scope else { continue };
            let objects = held_in(txn, info.scope).await?;
            let row = version_row(txn, info.scope, KeyPurpose::Team).await?;
            if objects.is_empty() && row.is_none() {
                continue;
            }
            bases.load(txn, info.scope).await?;
            // The roster a pull that followed its scopes body caught up on, never a stored flag (0051, `members`).
            let roster = self
                .rosters()
                .get(team)
                .filter(crate::api::key_flows::Roster::caught_up)
                .map(|roster| roster.members);
            teams.push(GatheredTeam {
                team,
                objects,
                row,
                roster,
            });
        }
        Ok(Gathered { personal, teams, bases })
    }

    // Each team's verdict in the state file: a wait stops it as `restore_wait` unless a catch-up stop holds it
    // already, a wait that is over clears a `restore_wait` stop, and an awaited confirmation that cannot go back ends
    // it (0062).
    async fn apply_verdicts(
        &self,
        txn: &mut dyn StateTxn,
        gathered: &Gathered,
        plan: &Plan,
        epoch: EpochId,
    ) -> Result<Effects, SyncError> {
        let mut effects = Effects {
            epoch: Some(epoch),
            ..Effects::default()
        };
        for (team, verdict) in &plan.teams {
            let Some(row) = gathered
                .teams
                .iter()
                .find(|gathered| gathered.team == *team)
                .and_then(|gathered| gathered.row.clone())
            else {
                continue;
            };
            match verdict {
                TeamVerdict::Waits { .. } if row.state == KeyVersionState::Ok => {
                    let mut row = row;
                    row.stop(StoppedCause::RestoreWait);
                    txn.put(Row::KeyVersion(row)).await?;
                    effects.stopped.push(*team);
                }
                // The wait ends once nothing of the team is left to push back: the engine runs the push-back again
                // while the row waits, so a set cut short here goes on the next pass before anything is sealed.
                TeamVerdict::Done
                    if stop::kind(&row) == Some(StoppedCause::RestoreWait)
                        && !plan
                            .sets
                            .iter()
                            .any(|set| set.scope == ScopeName::Team(*team) && !goes_alone(set)) =>
                {
                    txn.put(Row::KeyVersion(stop::resumed(row))).await?;
                    effects.resumed.push(*team);
                    effects.judged.push(self.judge_resumed_team(txn, *team).await?);
                }
                TeamVerdict::Ends => {
                    self.end_team(txn, *team, Some(epoch)).await?;
                    effects.ended.push(*team);
                }
                TeamVerdict::Waits { .. } | TeamVerdict::Done => {}
            }
        }
        Ok(effects)
    }

    async fn announce(&self, effects: &Effects) -> Result<(), SyncError> {
        for team in &effects.stopped {
            let scope = ScopeName::Team(*team);
            self.hooks().stop_scope(scope, StoppedCause::RestoreWait);
            self.raise_notice(KeyNoticeKind::ScopeStopped {
                scope,
                cause: StoppedCause::RestoreWait,
            })?;
        }
        for team in &effects.resumed {
            self.hooks().resume_scope(ScopeName::Team(*team));
            self.hooks().pass_soon();
        }
        for judged in &effects.judged {
            self.tell_judged(judged).await?;
        }
        for team in &effects.ended {
            self.team_ended(*team, effects.epoch)?;
        }
        Ok(())
    }

    // Ends a team on this device for good, with the epoch it ended in, and withdraws any report it sent (0051,
    // A stopped device): the withdrawal is pending in the same commit.
    pub(crate) async fn end_team(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
        epoch: Option<EpochId>,
    ) -> Result<(), SyncError> {
        if let Some(row) = version_row(txn, ScopeName::Team(team), KeyPurpose::Team).await? {
            txn.put(Row::KeyVersion(stop::ended(row, epoch))).await?;
        }
        stop::withdraw_pending(txn, team).await
    }

    pub(crate) fn team_ended(&self, team: TeamId, epoch: Option<EpochId>) -> Result<(), SyncError> {
        let scope = ScopeName::Team(team);
        self.hooks().end_scope(scope, epoch);
        self.raise_notice(KeyNoticeKind::ScopeEnded { scope })?;
        self.hooks().pass_soon();
        Ok(())
    }
}
