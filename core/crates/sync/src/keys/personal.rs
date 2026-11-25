// The personal and history keys (0056, Keys; Rollback, Per scope key): a new version exactly when the account's `av`
// changes, so the one a device writes under is the one signed under the account's current `av`. Personal envelopes
// and history entries are sealed and opened under them.

use tablepro_keys::body::KeyObject;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::scope_key::{Start, VersionRecord};

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::state::{KeyVersionState, StateTxn};

// One personal or history key version an account change set brings.
pub struct ScopeKeyPlan<'a> {
    pub version: Version,
    pub key: &'a ScopeKey,
    pub start: Start,
    // The version below, sealed in the ring: needed with `start` 0, and with `start` 1 only when the signer holds it.
    pub previous: Option<&'a ScopeKey>,
}

// The personal or history version a device writes under, with its record and that record's digest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentPersonal {
    pub record: VersionRecord,
    pub digest: [u8; 32],
    pub state: KeyVersionState,
}

impl KeyService {
    // The version record, its ring when it has one, and its wrap to the account's AEK at `av`, signed by the ASK at
    // `av` with `wrapper` as the writing key device.
    pub fn personal_version_objects(
        &self,
        purpose: KeyPurpose,
        plan: &ScopeKeyPlan<'_>,
        av: Version,
        signer: &AccountKeys,
        wrapper: KeyDeviceId,
    ) -> Result<Vec<KeyObject>, SyncError> {
        let _ = (purpose, plan, av, signer, wrapper);
        Err(SyncError::unimplemented("keys.personal_version_objects"))
    }

    // The version of `purpose` (`personal` or `history`) signed under the account's current `av`. None when the device
    // holds none: before genesis or approval, or after a catch-up it could not verify.
    pub async fn current_personal(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
    ) -> Result<Option<CurrentPersonal>, SyncError> {
        let _ = (txn, purpose);
        Err(SyncError::unimplemented("keys.current_personal"))
    }

    // The key at one version, through its wrap to AEK or by walking the rings down from a version the device opened,
    // each checked against its record's `kid`.
    pub async fn personal_key(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
        version: Version,
    ) -> Result<ScopeKey, SyncError> {
        let _ = (txn, purpose, version);
        Err(SyncError::unimplemented("keys.personal_key"))
    }
}
