// Pins (0056, Pins): per account a device meets, its own included, the IK it pinned, the newest `av` verified under
// it, how it pinned, an open alert and the IKs it saw replaced. Verifying checks an object's certificate against the
// pin and moves nothing; advancing moves the pin forward only (0056, Rollback).

use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{AccountId, Version};
use tablepro_keys::keys::Ed25519Public;

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::Fingerprint;
use crate::api::state::{KeyPinRow, StateTxn};

// Where a verified certificate's IK stands against the account's pin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IkStanding {
    Pinned,
    // An IK the pin saw replaced: its certificates verify the objects signed under them, never as the newest.
    Replaced,
    // A newer IK the pinned one endorsed through a chain of replaces the scope holds, not followed yet.
    Endorsed,
}

// What offering a certificate as an account's newest did to its pin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinChange {
    // The first certificate of an account this device meets.
    FirstUse,
    // At or below the pinned `av` under the pinned IK: verified, nothing moves.
    Unchanged,
    // The pinned IK at a higher `av`, followed silently.
    Followed { from: Version },
    // A new IK the pinned one endorsed, followed with a notice.
    Replaced { previous: Ed25519Public },
    // An IK change with no endorsement: an alert opens and the pin stays (`keys.unendorsed` fails nothing else).
    Alert,
}

impl KeyService {
    pub async fn pin(&self, txn: &mut dyn StateTxn, account: AccountId) -> Result<Option<KeyPinRow>, SyncError> {
        let _ = (txn, account);
        Err(SyncError::unimplemented("keys.pin"))
    }

    // Verifying: the certificate's signature, then its IK against the pin, through the replace certificates `scope`
    // holds for the account (`key.account` in the personal scope, `key.member` in a team).
    pub async fn verify_certificate(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        certificate: &AccountCertificate,
    ) -> Result<IkStanding, SyncError> {
        let _ = (txn, scope, certificate);
        Err(SyncError::unimplemented("keys.verify_certificate"))
    }

    // The certificate at `av` that `scope` holds for `account`, verified as above. None while it has not arrived, so
    // an object naming it is held rather than refused.
    pub async fn certificate_at(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        account: AccountId,
        av: Version,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        let _ = (txn, scope, account, av);
        Err(SyncError::unimplemented("keys.certificate_at"))
    }

    // Advancing: offers `certificate` as the account's newest and moves its pin as 0056's Pins says, raising the
    // notice or alert. An IK the pin saw replaced is `keys.retired_ik`.
    pub async fn offer_certificate(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        certificate: &AccountCertificate,
    ) -> Result<PinChange, SyncError> {
        let _ = (txn, scope, certificate);
        Err(SyncError::unimplemented("keys.offer_certificate"))
    }

    // The six words and the `TPF1:` code of an account's IK.
    pub fn fingerprint_of(&self, account: AccountId, ik: &Ed25519Public) -> Result<Fingerprint, SyncError> {
        let _ = (account, ik);
        Err(SyncError::unimplemented("keys.fingerprint_of"))
    }
}
