// What a device decides on a team's `members` roster, each only after its pull of the team caught up: who a rotation
// wraps to, how each member shows, and whether a stopped team ends. The roster is the server's assertion, so it narrows
// what the holder rules allow and never makes a holder (0051, `members`).

use std::collections::BTreeSet;

use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{AccountId, Origin};

use super::book::account_holds;
use super::facts::{Certificate, TeamFacts};
use crate::api::error::SyncError;
use crate::api::key_flows::{MemberKeyStatus, Roster};
use crate::api::scopes::ServerLimits;
use crate::api::state::Holder;
use crate::api::transport::RejectedCode;

// At most 5,000 members hold a team's key, so a rotation fits one push (0051, Limits).
pub(crate) fn holder_limit() -> usize {
    usize::try_from(ServerLimits::ADR_0051.team_key_holders).unwrap_or(usize::MAX)
}

pub(crate) fn holder_accounts(holders: &[Holder]) -> BTreeSet<AccountId> {
    holders.iter().map(|holder| holder.account).collect()
}

// A confirmation gives an account that does not hold the version its key, which past 5,000 holders is `team_full`:
// admins split the team (0056, Teams, Size).
pub(crate) fn check_room(holders: &[Holder], account: AccountId) -> Result<(), SyncError> {
    let accounts = holder_accounts(holders);
    if accounts.contains(&account) || accounts.len() < holder_limit() {
        Ok(())
    } else {
        Err(SyncError::Rejected {
            code: RejectedCode::TeamFull,
        })
    }
}

// A rotation or restart wraps to every recipient in one change set, which holds at most 5,000 of them.
pub(crate) fn check_fits(recipients: usize) -> Result<(), SyncError> {
    if recipients <= holder_limit() {
        Ok(())
    } else {
        Err(SyncError::Rejected {
            code: RejectedCode::TeamFull,
        })
    }
}

// A stopped team ends on the device only when no owner or admin on the roster held its version. An account under an
// open alert may still be the one that held it, and an end is final, so it keeps the team waiting.
pub(crate) async fn someone_can_reconfirm(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    roster: &Roster,
    holders: &[Holder],
) -> Result<bool, SyncError> {
    for member in roster.members.iter().filter(|member| member.role.manages_keys()) {
        if !holders.iter().any(|holder| holder.account == member.account) {
            continue;
        }
        match facts.pin(member.account).await? {
            None => return Ok(true),
            Some(pin) if pin.alert => return Ok(true),
            Some(_) => {
                if account_holds(origin, facts, holders, member.account).await? {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

pub(crate) async fn member_status(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    holders: &[Holder],
    account: AccountId,
) -> Result<MemberKeyStatus, SyncError> {
    if facts.chain(account).await?.is_empty() {
        return Ok(MemberKeyStatus::NoKeys);
    }
    Ok(match facts.pin(account).await? {
        Some(pin) if pin.alert => MemberKeyStatus::Alert,
        _ if account_holds(origin, facts, holders, account).await? => MemberKeyStatus::Holder,
        _ => MemberKeyStatus::AwaitingConfirmation,
    })
}

// An account's certificate at the newest `av` the device knows, which a wrap to it names.
pub(crate) async fn current_certificate(
    facts: &mut dyn TeamFacts,
    account: AccountId,
) -> Result<Option<AccountCertificate>, SyncError> {
    let Some(pin) = facts.pin(account).await? else {
        return Ok(None);
    };
    Ok(match facts.certificate(account, pin.av).await? {
        Some(Certificate::Usable(certificate)) if certificate.ik == pin.ik => Some(certificate),
        _ => None,
    })
}

// A rotation's recipients: every holder of the version held on the roster whose pin has no open alert, less those a
// removal review marked, each at its current `av` (0056, Teams, Rotating a team key). This account is always one. A
// holder whose newest certificate is not in the team yet fails the rotation, as the server would, until its app copies
// the certificate in.
pub(crate) async fn rotation_recipients(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    roster: &Roster,
    holders: &[Holder],
    me: AccountId,
    remove: &[AccountId],
) -> Result<Vec<AccountCertificate>, SyncError> {
    let mut accounts: BTreeSet<AccountId> = roster
        .members
        .iter()
        .map(|member| member.account)
        .filter(|account| !remove.contains(account))
        .collect();
    accounts.insert(me);
    let mut recipients = Vec::new();
    for account in accounts {
        if facts.pin(account).await?.is_some_and(|pin| pin.alert)
            || !account_holds(origin, facts, holders, account).await?
        {
            continue;
        }
        let certificate = current_certificate(facts, account)
            .await?
            .ok_or(SyncError::NotAllowed {
                what: "rotate before every holder's newest certificate is in the team",
            })?;
        recipients.push(certificate);
    }
    Ok(recipients)
}
