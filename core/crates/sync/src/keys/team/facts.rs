// What a team's checks read besides its own version records and wraps: each member's certificates as the team holds
// them, judged against the pins, and the pins themselves. The service reads them from the key tables; a test supplies
// them directly.

use async_trait::async_trait;
use tablepro_keys::KeysError;
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{AccountId, Version};
use tablepro_keys::keys::Ed25519Public;

use crate::api::error::SyncError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Certificate {
    // Verified under the pinned IK, one it saw replaced, or one it endorsed.
    Usable(AccountCertificate),
    // Under an IK the pin saw replaced: it verifies what was signed before the replace and never advances anything,
    // since the client never goes back to such an IK (0056, Pins, Replace; `keys.retired_ik`).
    Retired(AccountCertificate),
    // An IK change with no endorsement: the alert it opens gives the account's objects no effect as a holder's until
    // the person re-confirms (0056, Pins, Any other change).
    Alerted(AccountCertificate),
    Invalid(KeysError),
}

impl Certificate {
    // For verifying only: what the certificate signed stays valid whatever came after it (0056, Rollback, Verifying).
    pub(crate) fn verifying(&self) -> Option<&AccountCertificate> {
        match self {
            Self::Usable(certificate) | Self::Retired(certificate) | Self::Alerted(certificate) => Some(certificate),
            Self::Invalid(_) => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PinFacts {
    pub(crate) ik: Ed25519Public,
    // The newest `av` verified under the pin: what "its signer's newest `av` the client knows" reads (0056, Advancing).
    pub(crate) av: Version,
    pub(crate) alert: bool,
}

#[async_trait]
pub(crate) trait TeamFacts: Send {
    // None while the team holds no `key.member` at that `av`: an object naming it is held, never refused for that.
    async fn certificate(&mut self, account: AccountId, av: Version) -> Result<Option<Certificate>, SyncError>;

    async fn pin(&mut self, account: AccountId) -> Result<Option<PinFacts>, SyncError>;

    // Every certificate of the account the team holds that verifies under its own IK, ascending by `av`.
    async fn chain(&mut self, account: AccountId) -> Result<Vec<AccountCertificate>, SyncError>;
}

// The pin with the newest `av` the device knows for the account: the pin's, or a higher one of a certificate the team
// holds under the pinned IK, which only that IK's holder can sign. A pin left behind such a certificate must not let
// an older `av` count as the newest (0056, Rollback, Advancing).
pub(crate) async fn known_pin(facts: &mut dyn TeamFacts, account: AccountId) -> Result<Option<PinFacts>, SyncError> {
    let Some(mut pin) = facts.pin(account).await? else {
        return Ok(None);
    };
    if let Some(newest) = facts
        .chain(account)
        .await?
        .iter()
        .filter(|certificate| certificate.ik == pin.ik)
        .map(|certificate| certificate.av)
        .max()
    {
        pin.av = pin.av.max(newest);
    }
    Ok(Some(pin))
}
