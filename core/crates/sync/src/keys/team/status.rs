// A team's keys as the app shows them: the version held, whether this account holds it, each member's standing from
// the roster, and the stop reports, each with whether this account's rotation would confirm that device again.

use tablepro_keys::encoding::{AccountId, TeamId, Version};
use tablepro_keys::wrap::Recipient;

use super::book::{TeamBook, account_holds};
use super::facts::{Certificate, TeamFacts};
use super::roster;
use super::service_facts::{FactsCache, ServiceFacts};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{MemberKeys, StoppedDevice, TeamKeys};
use crate::api::scopes::Role;
use crate::api::state::{Holder, KeyVersionState};
use crate::keys::KeyService;

impl KeyService {
    pub(super) async fn team_status(&self, team: TeamId) -> Result<TeamKeys, SyncError> {
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        let book = self.load_team(&mut *txn, team).await?;
        let rotation_due = self.scope_row(&mut *txn, scope).await?.rotation_due;
        let roster = self.current_roster(&mut *txn, team).await?;
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        let holders = book.row().map(|row| row.holders.clone()).unwrap_or_default();
        let holder =
            book.row().is_some_and(|row| row.state == KeyVersionState::Ok) && book.own_holds(&mut facts).await?;
        let manages = roster
            .as_ref()
            .and_then(|roster| roster.role)
            .is_some_and(Role::manages_keys);
        let mut stopped = Vec::new();
        for report in roster.iter().flat_map(|roster| &roster.stopped) {
            let can_reconfirm =
                manages && held_version(self.origin(), &book, &mut facts, self.account(), report.version).await?;
            stopped.push(StoppedDevice {
                account: report.account,
                device: report.device.clone(),
                version: report.version,
                can_reconfirm,
            });
        }
        let mut members = Vec::new();
        for member in roster.iter().flat_map(|roster| &roster.members) {
            members.push(MemberKeys {
                account: member.account,
                role: member.role,
                status: roster::member_status(self.origin(), &mut facts, &holders, member.account).await?,
            });
        }
        Ok(TeamKeys {
            team,
            version: book.row().map(|row| row.version),
            state: book.row().map_or(KeyVersionState::Ok, |row| row.state),
            stopped_cause: book.row().and_then(|row| row.stopped_cause),
            rotation_due: rotation_due || roster.as_ref().is_some_and(|roster| roster.rotation_due),
            holder,
            members,
            stopped,
        })
    }
}

// Whether this account held `version`: it signed the version's record, or a wrap of it to this account verifies under
// its wrapper's certificate, under an IK this account still holds. A stopped device takes a re-confirming rotation only
// from such a holder, so the app offers it only to an owner or admin that is one (0056, Teams, A stopped device).
async fn held_version(
    origin: &tablepro_keys::encoding::Origin,
    book: &TeamBook,
    facts: &mut dyn TeamFacts,
    me: AccountId,
    version: Version,
) -> Result<bool, SyncError> {
    let mut pairs = Vec::new();
    if let Some(record) = book.version_record(version).filter(|record| record.signer == me)
        && let Some(own) = verified(facts, me, record.signer_av).await?
        && record.verify(origin, &own.ask).is_ok()
    {
        pairs.push(Holder {
            account: me,
            ik: own.ik,
        });
    }
    let wraps: Vec<_> = book
        .wraps_of(version)
        .filter(|wrap| wrap.target.recipient == Recipient::Account(me))
        .cloned()
        .collect();
    for wrap in wraps {
        if let Some(own) = verified(facts, me, wrap.target.recipient_version).await?
            && let Some(wrapper) = verified(facts, wrap.wrapper.account, wrap.wrapper.av).await?
            && wrap.verify(origin, &own.aek, &wrapper.ask).is_ok()
        {
            pairs.push(Holder {
                account: me,
                ik: own.ik,
            });
        }
    }
    account_holds(origin, facts, &pairs, me).await
}

async fn verified(
    facts: &mut dyn TeamFacts,
    account: AccountId,
    av: Version,
) -> Result<Option<tablepro_keys::cert::AccountCertificate>, SyncError> {
    Ok(facts
        .certificate(account, av)
        .await?
        .as_ref()
        .and_then(Certificate::verifying)
        .cloned())
}
