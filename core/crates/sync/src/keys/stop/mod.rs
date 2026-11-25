// `StopFlows` (0056, Teams, A stopped device; 0051, A stopped device; 0062). A team stopped by a catch-up it could
// not verify reports the version it stopped at, clears only when an owner or admin it had counted as a holder of
// that version re-confirms it, and ends when no owner or admin on the roster held it. A report goes when the device
// withdraws it: once its stop clears or its team ends, kept pending across a crash and settled before any new report
// for that team. A `restore_wait` stop is never reported.

mod holders;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet};

use async_trait::async_trait;
use tablepro_keys::KeysError;
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::check::check_signed_under_newest;
use tablepro_keys::encoding::{AccountId, KeyPurpose, TeamId, Version};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::wrap::Wrapper;

pub(crate) use self::holders::{Chain, same_holder};
use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, ScopeName};
use crate::api::key_flows::{StopAction, StopFlows};
use crate::api::scopes::TeamMember;
use crate::api::state::{
    Holder, KeyPendingRow, KeyPinRow, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn,
    StoppedCause, Table,
};

pub(crate) fn kind(row: &KeyVersionRow) -> Option<StoppedCause> {
    (row.state == KeyVersionState::Stopped)
        .then_some(row.stopped_cause)
        .flatten()
}

// A restore wait the server filled (0062); a catch-up stop never clears this way.
pub(crate) fn resumed(mut row: KeyVersionRow) -> KeyVersionRow {
    if kind(&row) == Some(StoppedCause::RestoreWait) {
        row.clear_stop();
    }
    row
}

pub(crate) fn ended(row: KeyVersionRow, epoch: Option<EpochId>) -> KeyVersionRow {
    KeyVersionRow {
        state: KeyVersionState::Ended,
        stopped_cause: None,
        epoch,
        ..row
    }
}

pub(crate) async fn withdraw_pending(txn: &mut dyn StateTxn, team: TeamId) -> Result<(), SyncError> {
    txn.put(Row::KeyPending(KeyPendingRow {
        flow: PendingFlow::StopWithdrawal { team },
        state: Vec::new(),
    }))
    .await?;
    Ok(())
}

async fn pending_withdrawals(txn: &mut dyn StateTxn) -> Result<BTreeSet<TeamId>, SyncError> {
    Ok(txn
        .scan(&RowRange::Table(Table::KeyPending))
        .await?
        .into_iter()
        .filter_map(|row| match row {
            Row::KeyPending(KeyPendingRow {
                flow: PendingFlow::StopWithdrawal { team },
                ..
            }) => Some(team),
            _ => None,
        })
        .collect())
}

async fn team_rows(txn: &mut dyn StateTxn) -> Result<Vec<KeyVersionRow>, SyncError> {
    Ok(txn
        .scan(&RowRange::Table(Table::KeyVersions))
        .await?
        .into_iter()
        .filter_map(|row| match row {
            Row::KeyVersion(row) if row.purpose == KeyPurpose::Team && matches!(row.scope, ScopeName::Team(_)) => {
                Some(row)
            }
            _ => None,
        })
        .collect())
}

async fn pin_of(txn: &mut dyn StateTxn, account: AccountId) -> Result<Option<KeyPinRow>, SyncError> {
    match txn.get(&RowKey::KeyPin(account)).await? {
        Some(Row::KeyPin(pin)) => Ok(Some(pin)),
        _ => Ok(None),
    }
}

async fn team_row(txn: &mut dyn StateTxn, team: TeamId) -> Result<Option<KeyVersionRow>, SyncError> {
    match txn
        .get(&RowKey::KeyVersion(ScopeName::Team(team), KeyPurpose::Team))
        .await?
    {
        Some(Row::KeyVersion(row)) => Ok(Some(row)),
        _ => Ok(None),
    }
}

// What a re-confirmation offered to a stopped team comes to, when the wrapper's certificates are not all there yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reconfirmation {
    // The wrap's signer is a holder the device counted for the version it stopped at, under its newest `av`.
    Taken,
    // A certificate the check needs has not arrived: held, never refused for that (0056, Rollback).
    Held,
}

#[async_trait]
impl StopFlows for KeyService {
    async fn stop_actions(&self) -> Result<Vec<StopAction>, SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let mut ends = Vec::new();
        for row in team_rows(&mut *txn).await? {
            let ScopeName::Team(team) = row.scope else { continue };
            if kind(&row) != Some(StoppedCause::CatchUp) {
                continue;
            }
            let Some(roster) = self.rosters().get(team).filter(|roster| roster.caught_up) else {
                continue;
            };
            if !self.a_manager_held(&mut *txn, team, &row, &roster.members).await? {
                let epoch = self.scope_epoch(&mut *txn, row.scope).await.ok();
                txn.put(Row::KeyVersion(ended(row, epoch))).await?;
                withdraw_pending(&mut *txn, team).await?;
                ends.push((team, epoch));
            }
        }
        let pending = pending_withdrawals(&mut *txn).await?;
        let mut actions: Vec<StopAction> = pending
            .iter()
            .map(|team| StopAction::Withdraw { team: *team })
            .collect();
        for row in team_rows(&mut *txn).await? {
            if let ScopeName::Team(team) = row.scope
                && kind(&row) == Some(StoppedCause::CatchUp)
                && !pending.contains(&team)
            {
                actions.push(StopAction::Report {
                    team,
                    version: row.version,
                });
            }
        }
        if !ends.is_empty() {
            txn.commit().await?;
            for (team, epoch) in ends {
                self.team_ended(team, epoch)?;
            }
        }
        Ok(actions)
    }

    async fn stop_action_sent(&self, action: StopAction) -> Result<(), SyncError> {
        let StopAction::Withdraw { team } = action else {
            return Ok(());
        };
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::StopWithdrawal { team }))
            .await?;
        txn.commit().await?;
        Ok(())
    }

    async fn resume_withdrawal(&self, team: TeamId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        let held = {
            let mut txn = self.begin().await?;
            pending_withdrawals(&mut *txn).await?.contains(&team)
        };
        if !held {
            return Ok(());
        }
        self.transport().withdraw_stopped(team, self.dpop_key().await?).await?;
        let mut txn = self.begin().await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::StopWithdrawal { team }))
            .await?;
        txn.commit().await?;
        Ok(())
    }
}

impl KeyService {
    // Stops a team, or a personal or history key, in the caller's commit with 0062's precedence. True when it was
    // not stopped before, so the caller tells the engine and the app once the commit lands.
    pub async fn mark_stopped(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        purpose: KeyPurpose,
        cause: StoppedCause,
    ) -> Result<bool, SyncError> {
        let Some(Row::KeyVersion(row)) = txn.get(&RowKey::KeyVersion(scope, purpose)).await? else {
            return Err(SyncError::NotAllowed {
                what: "stop a scope key the device holds no version of",
            });
        };
        let mut row = row;
        let was = row.state;
        row.stop(cause);
        let newly = was == KeyVersionState::Ok && row.state == KeyVersionState::Stopped;
        txn.put(Row::KeyVersion(row)).await?;
        Ok(newly)
    }

    // The check a wrap offered to a team stopped by a catch-up must pass before the device takes its version: the
    // wrap's signer is among the holders the device accepted for the version it stopped at, by an IK reachable from
    // the one it accepted through endorsed replaces with no reset, signed under the newest `av` the device knows for
    // it, and consistent with the account's pin: no open alert and no IK it saw replaced (0056, Teams, A stopped
    // device; Pins). Holders the device first met after it stopped never count.
    pub async fn reconfirmation(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
        version: Version,
        wrapper: &Wrapper,
    ) -> Result<Reconfirmation, SyncError> {
        let row = team_row(txn, team)
            .await?
            .filter(|row| kind(row) == Some(StoppedCause::CatchUp))
            .ok_or(SyncError::NotAllowed {
                what: "re-confirm a team that is not stopped by a catch-up",
            })?;
        if version <= row.version {
            return Err(KeysError::Stale {
                held: row.version.get(),
                offered: version.get(),
            }
            .into());
        }
        let pairs: Vec<&Holder> = row
            .holders
            .iter()
            .filter(|pair| pair.account == wrapper.account)
            .collect();
        if pairs.is_empty() {
            return Err(KeysError::NotHolder.into());
        }
        let Some(pin) = pin_of(txn, wrapper.account).await? else {
            return Ok(Reconfirmation::Held);
        };
        if pin.alert {
            return Ok(Reconfirmation::Held);
        }
        let certificates = self.member_certificates(txn, team, wrapper.account).await?;
        let newest = holders::newest_known(&certificates, Some(pin.av)).unwrap_or(pin.av);
        check_signed_under_newest(wrapper.av, newest)?;
        let Some(signed_under) = certificates.get(&wrapper.av) else {
            return Ok(Reconfirmation::Held);
        };
        if pin.replaced.contains(&signed_under.ik) {
            return Err(KeysError::RetiredIk.into());
        }
        match same_holder(self.origin(), &pin.ik, &certificates, wrapper.av) {
            Chain::Matches => {}
            Chain::Missing => return Ok(Reconfirmation::Held),
            Chain::Breaks => return Err(KeysError::NotHolder.into()),
        }
        let chains: Vec<Chain> = pairs
            .iter()
            .map(|pair| same_holder(self.origin(), &pair.ik, &certificates, wrapper.av))
            .collect();
        if chains.contains(&Chain::Matches) {
            Ok(Reconfirmation::Taken)
        } else if chains.contains(&Chain::Missing) {
            Ok(Reconfirmation::Held)
        } else {
            Err(KeysError::NotHolder.into())
        }
    }

    // A re-confirmation applied: the team moves to the new version in the caller's commit, and the report it sent is
    // withdrawn from the same commit on (0054, `key_pending`). The wrap that carried the version is checked again, so
    // no other path clears a catch-up stop.
    pub async fn clear_catch_up_stop(
        &self,
        txn: &mut dyn StateTxn,
        row: KeyVersionRow,
        wrapper: &Wrapper,
    ) -> Result<(), SyncError> {
        let ScopeName::Team(team) = row.scope else {
            return Err(SyncError::NotAllowed {
                what: "clear a catch-up stop outside a team",
            });
        };
        if self.reconfirmation(txn, team, row.version, wrapper).await? != Reconfirmation::Taken {
            return Err(SyncError::NotAllowed {
                what: "clear a catch-up stop before its re-confirmation is taken",
            });
        }
        txn.put(Row::KeyVersion(KeyVersionRow {
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
            ..row
        }))
        .await?;
        withdraw_pending(txn, team).await
    }

    // The account's certificates the team holds as `key.member`, by `av`.
    async fn member_certificates(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
        account: AccountId,
    ) -> Result<BTreeMap<Version, AccountCertificate>, SyncError> {
        Ok(self
            .held_objects(txn, ScopeName::Team(team), KeyKind::Member)
            .await?
            .into_iter()
            .filter(|held| held.applied)
            .filter_map(|held| match (held.object.id, held.object.body) {
                (KeyRecordId::Member { account: of, av }, tablepro_keys::body::KeyBody::Member(body))
                    if of == account =>
                {
                    Some((av, body.certificate(account, av)))
                }
                _ => None,
            })
            // A certificate its own IK did not sign is no evidence of anything: it is left out, as if not arrived.
            .filter(|(_, certificate)| certificate.verify(self.origin()).is_ok())
            .collect())
    }

    // Whether an owner or admin on the roster held the version the team stopped at: an account among its holders,
    // by any of its pairs, whose newest certificate the team holds is still that holder (0056, Teams, Holders). An
    // account under an open alert, or a chain whose certificates have not arrived, counts as held, so the team waits
    // rather than ends on what it cannot judge yet.
    async fn a_manager_held(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
        row: &KeyVersionRow,
        members: &[TeamMember],
    ) -> Result<bool, SyncError> {
        for member in members.iter().filter(|member| member.role.manages_keys()) {
            let pairs: Vec<&Holder> = row
                .holders
                .iter()
                .filter(|pair| pair.account == member.account)
                .collect();
            if pairs.is_empty() {
                continue;
            }
            if pin_of(txn, member.account).await?.is_none_or(|pin| pin.alert) {
                return Ok(true);
            }
            let certificates = self.member_certificates(txn, team, member.account).await?;
            let Some(newest) = certificates.keys().next_back().copied() else {
                return Ok(true);
            };
            if pairs
                .iter()
                .any(|pair| same_holder(self.origin(), &pair.ik, &certificates, newest) != Chain::Breaks)
            {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub(crate) async fn scope_epoch(&self, txn: &mut dyn StateTxn, scope: ScopeName) -> Result<EpochId, SyncError> {
        match txn.get(&RowKey::Scope(scope)).await? {
            Some(Row::Scope(row)) => row.epoch.ok_or(SyncError::NotAllowed {
                what: "end a scope before its epoch is read",
            }),
            _ => Err(SyncError::NotAllowed {
                what: "end a scope this device does not sync",
            }),
        }
    }
}
