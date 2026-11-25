// The account and device key material a device holds (0056, Keys), and the account objects every account change set
// carries: genesis, rotation, replace, recovery and a reset's activation build them here.

use tablepro_keys::body::KeyObject;
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyDeviceId, Version};
use tablepro_keys::keys::{AccountKeys, AccountPublicKeys, DeviceKeys, Ed25519Public, Ed25519Seed, X25519Public};
use tablepro_keys::recovery::RecoveryKey;

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::state::StateTxn;
use crate::api::transport::DpopKey;

// The device keys of this (origin, account, device row): the ones in force, and while an approval is in flight the new
// ones beside them, which replace them once it applies (0056, Keys).
#[derive(Debug, Clone, Default)]
pub struct HeldDeviceKeys {
    pub current: Option<DeviceKeys>,
    pub pending: Option<DeviceKeys>,
}

// This device's own account as its key tables and device store hold it: the newest `av` it verified, the IK it
// pinned, and the keys at that `av`.
#[derive(Debug, Clone)]
pub struct OwnAccount {
    pub av: Version,
    pub ik: Ed25519Public,
    pub public: AccountPublicKeys,
    pub keys: AccountKeys,
    pub device: DeviceKeys,
}

// A key device an account change set certifies: its id and the keys a comparison fixed, never a certificate's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeptDevice {
    pub key_device: KeyDeviceId,
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
}

impl KeptDevice {
    pub fn of(keys: &DeviceKeys) -> Result<Self, SyncError> {
        Ok(Self {
            key_device: keys.key_device,
            dek: keys.dek.public()?,
            dsk: keys.dsk.public()?,
        })
    }
}

// The account objects of one account change set at `av`: the certificate under `ik`, the recovery blob under
// `recovery`, a device certificate for each kept device and, when `wrapper` is set, an `account` wrap to each signed by
// the wrapper's DSK (0056, Account flows).
pub struct AccountObjectsPlan<'a> {
    pub av: Version,
    pub kind: CertKind,
    pub ik: &'a Ed25519Seed,
    // With kind 1, the IK of the certificate at `av - 1`, which endorses `ik`.
    pub endorsing_ik: Option<&'a Ed25519Seed>,
    pub recovery: &'a RecoveryKey,
    pub keys: &'a AccountKeys,
    pub devices: &'a [KeptDevice],
    // None at genesis, which wraps the account keys to no device.
    pub wrapper: Option<&'a DeviceKeys>,
}

impl KeyService {
    pub async fn device_keys(&self) -> Result<HeldDeviceKeys, SyncError> {
        Err(SyncError::unimplemented("keys.device_keys"))
    }

    pub async fn store_device_keys(&self, keys: &HeldDeviceKeys) -> Result<(), SyncError> {
        let _ = keys;
        Err(SyncError::unimplemented("keys.store_device_keys"))
    }

    // ASK and AEK at one `av`, kept while a scope key is still wrapped to that AEK.
    pub async fn account_keys(&self, av: Version) -> Result<Option<AccountKeys>, SyncError> {
        let _ = av;
        Err(SyncError::unimplemented("keys.account_keys"))
    }

    pub async fn store_account_keys(&self, av: Version, keys: &AccountKeys) -> Result<(), SyncError> {
        let _ = (av, keys);
        Err(SyncError::unimplemented("keys.store_account_keys"))
    }

    // None while this device holds no keys of the account it can use: before genesis or approval, or locked.
    pub async fn own_account(&self, txn: &mut dyn StateTxn) -> Result<Option<OwnAccount>, SyncError> {
        let _ = txn;
        Err(SyncError::unimplemented("keys.own_account"))
    }

    // The DSK of the device keys in force, which every call from an approved device proves with.
    pub async fn dpop_key(&self) -> Result<DpopKey, SyncError> {
        Err(SyncError::unimplemented("keys.dpop_key"))
    }

    pub fn account_objects(&self, plan: &AccountObjectsPlan<'_>) -> Result<Vec<KeyObject>, SyncError> {
        let _ = plan;
        Err(SyncError::unimplemented("keys.account_objects"))
    }

    // An account change set this device pushed, once applied: its objects held as applied, the own pin at its `av`,
    // and the personal and history versions it brings made current.
    pub async fn adopt_account_change_set(
        &self,
        txn: &mut dyn StateTxn,
        objects: &[KeyObject],
    ) -> Result<(), SyncError> {
        let _ = (txn, objects);
        Err(SyncError::unimplemented("keys.adopt_account_change_set"))
    }
}
