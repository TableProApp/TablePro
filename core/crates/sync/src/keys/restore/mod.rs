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

use self::plan::{Inputs, Plan, TeamInputs, TeamVerdict};
use self::server::BaseView;
use super::{HeldObject, KeyService};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, KindName, ScopeName};
use crate::api::key_flows::{KeyChangeSet, KeyNoticeKind, LockCause, PushBackVerdict, RestoreFlows};
use crate::api::scopes::{ScopeInfo, ScopesAnswer, ScopesBody};
use crate::api::state::{KeyVersionRow, KeyVersionState, Row, RowKey, RowRange, StateTxn, StoppedCause, Table};
use crate::api::transport::{Change, ChangeOp, ChangeOutcome, Proof};
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
        let view = BaseView::new(&body, &gathered.bases);
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
        self.announce(&effects)?;
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
        let refusal = refusal(&set);
        if refusal == Refusal::Nothing {
            return Ok(PushBackVerdict::Continue);
        }
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        // The epoch the push went in, as `push_change_set` sends it: the scope's own.
        let epoch = self.scope_epoch(&mut *txn, set.scope).await?;
        match refusal {
            Refusal::AccountEnds => {
                for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
                    if let Some(row) = version_row(&mut *txn, ScopeName::Personal, purpose).await? {
                        txn.put(Row::KeyVersion(stop::ended(row, epoch))).await?;
                    }
                }
                txn.commit().await?;
                self.hooks().end_scope(ScopeName::Personal, Some(epoch));
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
    ended: Vec<TeamId>,
    epoch: Option<EpochId>,
}

// What a refused push-back set does (0051, What cannot go back): an account change set ends the account, a team
// version or `key.member` ends the team, and a wrap alone ends nothing, since a lost confirmation is made again at
// the next team version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    AccountEnds,
    TeamEnds(TeamId),
    Nothing,
}

fn refusal(set: &KeyChangeSet) -> Refusal {
    match set.scope {
        ScopeName::Personal | ScopeName::History => Refusal::AccountEnds,
        ScopeName::Team(team) => {
            let lone_wrap = matches!(set.changes.as_slice(), [change] if change.kind.as_str() == "key.wrap");
            if lone_wrap {
                Refusal::Nothing
            } else {
                Refusal::TeamEnds(team)
            }
        }
    }
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
    async fn scopes_body(&self) -> Result<ScopesBody, SyncError> {
        let proof = Proof::Dpop(self.dpop_key().await?);
        match self.transport().scopes(None, proof).await? {
            ScopesAnswer::Body { body, .. } => Ok(*body),
            ScopesAnswer::NotModified => Err(SyncError::Malformed { what: "scopes answer" }),
        }
    }

    // The key objects of the personal scope and of each team this sign-in still reaches, with the team rows, the
    // rosters `roster_read` kept once each team's pull caught up, and the bases that say what the server holds.
    async fn gather(&self, txn: &mut dyn StateTxn, body: &ScopesBody) -> Result<Gathered, SyncError> {
        let personal = held_in(txn, ScopeName::Personal).await?;
        let mut bases = server::Bases::default();
        bases.load(txn, ScopeName::Personal).await?;
        let mut teams = Vec::new();
        for info in &body.scopes {
            let ScopeName::Team(team) = info.scope else { continue };
            let objects = held_in(txn, info.scope).await?;
            let row = version_row(txn, info.scope, KeyPurpose::Team).await?;
            if objects.is_empty() && row.is_none() {
                continue;
            }
            bases.load(txn, info.scope).await?;
            teams.push(GatheredTeam {
                team,
                objects,
                row,
                roster: self
                    .rosters()
                    .get(team)
                    .filter(|roster| roster.caught_up)
                    .map(|roster| roster.members),
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
                TeamVerdict::Done if stop::kind(&row) == Some(StoppedCause::RestoreWait) => {
                    txn.put(Row::KeyVersion(stop::resumed(row))).await?;
                    effects.resumed.push(*team);
                }
                TeamVerdict::Ends => {
                    self.end_team(txn, *team, epoch).await?;
                    effects.ended.push(*team);
                }
                TeamVerdict::Waits { .. } | TeamVerdict::Done => {}
            }
        }
        Ok(effects)
    }

    fn announce(&self, effects: &Effects) -> Result<(), SyncError> {
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
        if let Some(epoch) = effects.epoch {
            for team in &effects.ended {
                self.team_ended(*team, epoch)?;
            }
        }
        Ok(())
    }

    // Ends a team on this device for good, with the epoch it ended in, and withdraws any report it sent (0051,
    // A stopped device): the withdrawal is pending in the same commit.
    pub(crate) async fn end_team(&self, txn: &mut dyn StateTxn, team: TeamId, epoch: EpochId) -> Result<(), SyncError> {
        if let Some(row) = version_row(txn, ScopeName::Team(team), KeyPurpose::Team).await? {
            txn.put(Row::KeyVersion(stop::ended(row, epoch))).await?;
        }
        stop::withdraw_pending(txn, team).await
    }

    pub(crate) fn team_ended(&self, team: TeamId, epoch: EpochId) -> Result<(), SyncError> {
        let scope = ScopeName::Team(team);
        self.hooks().end_scope(scope, Some(epoch));
        self.raise_notice(KeyNoticeKind::ScopeEnded { scope })?;
        self.hooks().pass_soon();
        Ok(())
    }
}
