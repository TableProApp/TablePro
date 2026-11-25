// `TeamFlows` (0056, Teams; 0051, Teams): members' certificates in the team, the holders of each team key version, who
// may sign the next one, confirmation, rotation and restart as change sets, `rotation_due`, the stop a catch-up it
// cannot verify leaves, team envelopes, and what the device decides on the `members` roster.

mod apply;
mod book;
mod build;
mod chain;
mod envelopes;
mod facts;
mod roster;
mod secrets;
mod service_facts;
mod status;
#[cfg(test)]
mod tests;
mod write;

use async_trait::async_trait;
use secrecy::SecretString;
use serde_json::Value;
use tablepro_keys::encoding::{AccountId, KeyPurpose, TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::record_id::KeyKind;

use self::book::TeamBook;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyApplied, KeyArrival, OpenedEnvelope, Roster, TeamFlows, TeamKeys};
use crate::api::state::{
    KeyPendingRow, KeyTrust, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, ScopeRow, StateTxn, StoppedCause,
};
use crate::keys::KeyService;

#[async_trait]
impl TeamFlows for KeyService {
    async fn team_keys(&self, team: TeamId) -> Result<TeamKeys, SyncError> {
        let _serial = self.serialized().await;
        self.team_status(team).await
    }

    async fn create_team_keys(&self, team: TeamId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.create_team(team).await
    }

    async fn publish_member_certificate(&self, team: TeamId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.publish_certificates(team).await
    }

    async fn confirm_member(&self, team: TeamId, account: AccountId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.confirm(team, account).await
    }

    async fn rotate_team(&self, team: TeamId, remove: Vec<AccountId>) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.rotate(team, &remove).await
    }

    async fn restart_team(&self, team: TeamId, confirm: Vec<AccountId>) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.restart(team, &confirm).await
    }

    async fn credentials_to_rotate(&self, scope: ScopeName) -> Result<Vec<EnvelopeId>, SyncError> {
        let _serial = self.serialized().await;
        self.readable_by_removed(scope).await
    }

    async fn roster_read(&self, team: TeamId, roster: Roster) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.decide_on_roster(team, roster).await
    }

    async fn apply_team_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _serial = self.serialized().await;
        self.apply_team(arrival).await
    }

    async fn seal_team_envelope(
        &self,
        team: TeamId,
        envelope: EnvelopeId,
        secret: SecretString,
        dest: Value,
    ) -> Result<Value, SyncError> {
        let _serial = self.serialized().await;
        self.seal_team(team, &envelope, &secret, &dest).await
    }

    async fn open_team_envelope(
        &self,
        team: TeamId,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        let _serial = self.serialized().await;
        self.open_team(team, &envelope, &fields, in_force).await
    }
}

impl KeyService {
    // The team's version row and every version record, ring and wrap the key tables hold for it.
    async fn load_team(&self, txn: &mut dyn StateTxn, team: TeamId) -> Result<TeamBook, SyncError> {
        let scope = ScopeName::Team(team);
        let row = match txn.get(&RowKey::KeyVersion(scope, KeyPurpose::Team)).await? {
            Some(Row::KeyVersion(row)) => Some(row),
            _ => None,
        };
        let mut book = TeamBook::new(self.origin().clone(), team, self.account(), row);
        for kind in [KeyKind::Version, KeyKind::Ring, KeyKind::Wrap] {
            for held in self.held_objects(txn, scope, kind).await? {
                // An object of another team or purpose was refused when it came and is never one of this team's.
                let _ = book.insert(&held.object, false);
            }
        }
        Ok(book)
    }

    async fn scope_row(&self, txn: &mut dyn StateTxn, scope: ScopeName) -> Result<ScopeRow, SyncError> {
        Ok(match txn.get(&RowKey::Scope(scope)).await? {
            Some(Row::Scope(row)) => row,
            _ => ScopeRow::new(scope),
        })
    }

    // A file with no anchor, or one rebuilding from the server, handles no secret (0054, On open).
    fn may_handle_secrets(&self) -> Result<(), SyncError> {
        if self.is_unanchored() || matches!(self.state().opened().key_tables, KeyTrust::Rebuild { .. }) {
            return Err(SyncError::NotAllowed {
                what: "handle a team secret before the key tables are verified",
            });
        }
        Ok(())
    }

    // Moves the team's row and, when a stop it reported clears or ends, queues the report's withdrawal in the same
    // commit, which the stop flow sends until the server answers (0054, `key_pending`).
    async fn put_team_row(
        &self,
        txn: &mut dyn StateTxn,
        before: Option<&KeyVersionRow>,
        row: &KeyVersionRow,
    ) -> Result<(), SyncError> {
        if before == Some(row) {
            return Ok(());
        }
        let ScopeName::Team(team) = row.scope else {
            return Err(SyncError::NotAllowed {
                what: "keep a team row outside a team",
            });
        };
        // Only a catch-up stop is reported, so only its end has a report to withdraw (0062).
        let reported = before.is_some_and(|before| {
            before.state == KeyVersionState::Stopped && before.stopped_cause == Some(StoppedCause::CatchUp)
        });
        let still_reported = row.state == KeyVersionState::Stopped && row.stopped_cause == Some(StoppedCause::CatchUp);
        if reported && !still_reported {
            txn.put(Row::KeyPending(KeyPendingRow {
                flow: PendingFlow::StopWithdrawal { team },
                state: Vec::new(),
            }))
            .await?;
        }
        txn.put(Row::KeyVersion(row.clone())).await?;
        Ok(())
    }
}
