// Reading a team key: through a wrap of it to this account, or of a version above it, walking the rings down. Every
// key is checked against its version record's `kid`. The records, rings and wraps read here are verified only
// (0056, Rollback, Verifying), so a version the device holds as historical still opens what was written under it.

use async_trait::async_trait;
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{AccountId, Origin, TeamId, Version};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::scope_key::VersionRecord;
use tablepro_keys::wrap::Recipient;

use super::book::TeamBook;
use super::build;
use super::facts::{Certificate, TeamFacts};
use crate::api::error::SyncError;
use crate::keys::KeyService;

// This account's keys at each `av` the device still holds, which open the wraps addressed to that `av`.
#[async_trait]
pub(crate) trait Keyring: Send + Sync {
    fn origin(&self) -> &Origin;

    fn account(&self) -> AccountId;

    async fn account_keys(&self, av: Version) -> Result<Option<AccountKeys>, SyncError>;
}

#[async_trait]
impl Keyring for KeyService {
    fn origin(&self) -> &Origin {
        KeyService::origin(self)
    }

    fn account(&self) -> AccountId {
        KeyService::account(self)
    }

    async fn account_keys(&self, av: Version) -> Result<Option<AccountKeys>, SyncError> {
        KeyService::account_keys(self, av).await
    }
}

async fn verified(
    facts: &mut dyn TeamFacts,
    account: AccountId,
    av: Version,
) -> Result<Option<AccountCertificate>, SyncError> {
    Ok(match facts.certificate(account, av).await? {
        Some(Certificate::Usable(certificate) | Certificate::Alerted(certificate)) => Some(certificate),
        Some(Certificate::Invalid(_)) | None => None,
    })
}

async fn verified_record(
    origin: &Origin,
    book: &TeamBook,
    facts: &mut dyn TeamFacts,
    version: Version,
) -> Result<Option<VersionRecord>, SyncError> {
    let Some(record) = book.version_record(version).cloned() else {
        return Ok(None);
    };
    let Some(signer) = verified(facts, record.signer, record.signer_av).await? else {
        return Ok(None);
    };
    Ok(record.verify(origin, &signer.ask).is_ok().then_some(record))
}

async fn open_own_wrap(
    service: &dyn Keyring,
    book: &TeamBook,
    facts: &mut dyn TeamFacts,
    version: Version,
) -> Result<Option<ScopeKey>, SyncError> {
    let origin = service.origin();
    let Some(record) = verified_record(origin, book, facts, version).await? else {
        return Ok(None);
    };
    let me = service.account();
    let wraps: Vec<_> = book
        .wraps_of(version)
        .filter(|wrap| wrap.target.recipient == Recipient::Account(me))
        .cloned()
        .collect();
    for wrap in wraps {
        let Some(keys) = service.account_keys(wrap.target.recipient_version).await? else {
            continue;
        };
        let Some(own) = verified(facts, me, wrap.target.recipient_version).await? else {
            continue;
        };
        let Some(wrapper) = verified(facts, wrap.wrapper.account, wrap.wrapper.av).await? else {
            continue;
        };
        if let Ok(key) = wrap.open_scope_key(origin, &keys.aek, &own.aek, &wrapper.ask, &record) {
            return Ok(Some(key));
        }
    }
    Ok(None)
}

async fn walk_down(
    origin: &Origin,
    team: TeamId,
    book: &TeamBook,
    facts: &mut dyn TeamFacts,
    mut key: ScopeKey,
    from: Version,
    to: Version,
) -> Result<Option<ScopeKey>, SyncError> {
    let mut at = from;
    while at > to {
        let (Some(ring), Some(below)) = (book.ring(at).cloned(), at.previous()) else {
            return Ok(None);
        };
        let Some(record) = verified_record(origin, book, facts, below).await? else {
            return Ok(None);
        };
        match ring.open(origin, build::team_key(team, at), &key, &record) {
            Ok(older) => key = older,
            Err(_) => return Ok(None),
        }
        at = below;
    }
    Ok(Some(key))
}

// `newest` bounds the search: the version the device advanced to, above which it holds no key.
pub(crate) async fn team_key(
    service: &dyn Keyring,
    team: TeamId,
    book: &TeamBook,
    facts: &mut dyn TeamFacts,
    version: Version,
    newest: Version,
) -> Result<ScopeKey, SyncError> {
    let mut top = version;
    while top <= newest {
        if let Some(key) = open_own_wrap(service, book, facts, top).await?
            && let Some(key) = walk_down(service.origin(), team, book, facts, key, top, version).await?
        {
            return Ok(key);
        }
        let Ok(next) = top.next() else { break };
        top = next;
    }
    Err(SyncError::NotAllowed {
        what: "read a team key this account was not given",
    })
}
