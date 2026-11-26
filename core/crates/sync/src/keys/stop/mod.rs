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
use tablepro_keys::encoding::WrapPurpose;
use tablepro_keys::encoding::{AccountId, KeyPurpose, TeamId, Version};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::wrap::{Recipient, Wrap, Wrapper};

pub(crate) use self::holders::{Chain, same_holder};
use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, ScopeName};
use crate::api::key_flows::{StopAction, StopFlows};
use crate::api::state::{
    Holder, KeyPendingRow, KeyPinRow, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn,
    StopClear, StoppedCause, Table,
};

pub(crate) fn kind(row: &KeyVersionRow) -> Option<StoppedCause> {
    (row.state == KeyVersionState::Stopped)
        .then_some(row.stopped_cause)
        .flatten()
}

// A restore wait the server filled (0062); any other stop does not clear this way and stays as it was.
pub(crate) fn resumed(mut row: KeyVersionRow) -> KeyVersionRow {
    let _ = row.clear_stop(StopClear::AwaitedVersionsBack);
    row
}

pub(crate) fn ended(mut row: KeyVersionRow, epoch: Option<EpochId>) -> KeyVersionRow {
    row.end(epoch);
    row
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
        // The engine asks at the end of every pass, the one point where each team the pass read has its roster.
        if let Err(error) = self.check_rebuild().await {
            tracing::debug!(code = error.code(), "the rebuild is judged again after the next pass");
        }
        // A catch-up stop no owner or admin on the roster can clear ends first, by the rule a roster read applies, so
        // its report goes as a withdrawal rather than a report.
        let stopped: Vec<TeamId> = {
            let mut txn = self.begin().await?;
            team_rows(&mut *txn)
                .await?
                .into_iter()
                .filter(|row| kind(row) == Some(StoppedCause::CatchUp))
                .filter_map(|row| match row.scope {
                    ScopeName::Team(team) => Some(team),
                    _ => None,
                })
                .collect()
        };
        for team in stopped {
            let roster = {
                let mut txn = self.begin().await?;
                self.current_roster(&mut *txn, team).await?
            };
            if let Some(roster) = roster {
                self.end_unconfirmable_stop(team, &roster).await?;
            }
        }
        let mut txn = self.begin().await?;
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
        let row = team_row(txn, team).await?.ok_or(SyncError::NotAllowed {
            what: "re-confirm a team that is not stopped by a catch-up",
        })?;
        self.reconfirmation_of(txn, &row, version, wrapper).await
    }

    // The same check against the row the team stopped at, which a pull that stops and clears the team in one call has
    // not written yet.
    async fn reconfirmation_of(
        &self,
        txn: &mut dyn StateTxn,
        row: &KeyVersionRow,
        version: Version,
        wrapper: &Wrapper,
    ) -> Result<Reconfirmation, SyncError> {
        let ScopeName::Team(team) = row.scope else {
            return Err(SyncError::NotAllowed {
                what: "re-confirm a team that is not stopped by a catch-up",
            });
        };
        if kind(row) != Some(StoppedCause::CatchUp) {
            return Err(SyncError::NotAllowed {
                what: "re-confirm a team that is not stopped by a catch-up",
            });
        }
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
        let newest = holders::newest_known(&certificates, &pin);
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

    // A re-confirmation applied: the team moves from `stopped` to the new version in the caller's commit, and the
    // report it sent is withdrawn from the same commit on (0054, `key_pending`). `wrap` is the wrap of that version to
    // this account that the team flow verified; its signer is checked again here, so a catch-up stop clears no other
    // way.
    pub async fn clear_catch_up_stop(
        &self,
        txn: &mut dyn StateTxn,
        stopped: &KeyVersionRow,
        row: KeyVersionRow,
        wrap: &Wrap,
    ) -> Result<(), SyncError> {
        let ScopeName::Team(team) = row.scope else {
            return Err(SyncError::NotAllowed {
                what: "clear a catch-up stop outside a team",
            });
        };
        let to_this_account = wrap.target.owner == team.0
            && wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
            && wrap.target.version == row.version
            && wrap.target.recipient == Recipient::Account(self.account());
        if !to_this_account {
            return Err(SyncError::NotAllowed {
                what: "clear a catch-up stop with a wrap of another version or to another account",
            });
        }
        if stopped.scope != row.scope
            || self.reconfirmation_of(txn, stopped, row.version, &wrap.wrapper).await? != Reconfirmation::Taken
        {
            return Err(SyncError::NotAllowed {
                what: "clear a catch-up stop before its re-confirmation is taken",
            });
        }
        let mut moved = stopped.clone();
        moved
            .clear_stop(StopClear::Reconfirmed)
            .map_err(|_| SyncError::NotAllowed {
                what: "clear a stop that is not a catch-up",
            })?;
        txn.put(Row::KeyVersion(KeyVersionRow {
            version: row.version,
            record: row.record,
            holders: row.holders,
            ..moved
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
}
