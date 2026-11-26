// Rotation (0056, Account flows): a device X, with R typed, moves the account from `av` to `av + 1`, keeping itself
// and only the own-device pins the person ticked. The account objects come from the one builder every account change
// set uses; the personal and history keys move to their next versions with rings, so old data stays readable.

use std::sync::Arc;

use tablepro_keys::KeysError;
use tablepro_keys::body::KeyObject;
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, Ed25519Public, ScopeKey};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::Start;

use crate::api::error::SyncError;
use crate::api::state::{KeyDevicePinRow, Row, RowRange, StateTxn, Table};
use crate::api::transport::DpopKey;
use crate::keys::{AccountObjectsPlan, KeptDevice, KeyService, ScopeKeyPlan};

// The personal or history key in force before the rotation, which the next version's ring seals.
pub(crate) struct CurrentKey {
    pub purpose: KeyPurpose,
    pub version: Version,
    pub key: ScopeKey,
}

pub(crate) struct Rotation<'a> {
    pub av: Version,
    pub recovery: &'a RecoveryKey,
    // X's device keys: they sign every `account` wrap and prove the push.
    pub rotating: &'a DeviceKeys,
    pub kept: &'a [KeptDevice],
    pub current: &'a [CurrentKey],
}

pub(crate) struct Built {
    pub av: Version,
    pub keys: AccountKeys,
    pub objects: Vec<KeyObject>,
}

impl Built {
    pub fn proof(&self, rotating: &DeviceKeys) -> DpopKey {
        DpopKey(Arc::new(rotating.dsk.clone()))
    }
}

// R gives the account's IK; another R is a key whose certificate does not verify.
pub(crate) fn check_recovery_key(
    service: &KeyService,
    recovery: &RecoveryKey,
    ik: &Ed25519Public,
) -> Result<tablepro_keys::keys::Ed25519Seed, SyncError> {
    let seed = recovery.identity_seed(service.origin(), service.account())?;
    if seed.public()? != *ik {
        return Err(KeysError::Signature.into());
    }
    Ok(seed)
}

// The devices a rotation keeps: X itself, and only own-device pins, never a certificate's keys.
pub(crate) async fn kept_devices(
    txn: &mut dyn StateTxn,
    rotating: &DeviceKeys,
    keep: &[KeyDeviceId],
) -> Result<Vec<KeptDevice>, SyncError> {
    let pins: Vec<KeyDevicePinRow> = txn
        .scan(&RowRange::Table(Table::KeyDevicePins))
        .await?
        .into_iter()
        .filter_map(|row| match row {
            Row::KeyDevicePin(pin) => Some(pin),
            _ => None,
        })
        .collect();
    let mut kept = vec![KeptDevice::of(rotating)?];
    for key_device in keep.iter().filter(|key_device| **key_device != rotating.key_device) {
        let pin = pins
            .iter()
            .find(|pin| pin.key_device == *key_device)
            .ok_or(KeysError::NotCompared)?;
        if kept.iter().any(|device| device.key_device == pin.key_device) {
            continue;
        }
        kept.push(KeptDevice {
            key_device: pin.key_device,
            dek: pin.dek,
            dsk: pin.dsk,
        });
    }
    Ok(kept)
}

impl KeyService {
    // The rotation change set at `av + 1`: the certificate under IK, the blob under R, a device certificate and an
    // `account` wrap for each kept device, and the next personal and history versions with their wraps and rings.
    pub(crate) fn build_rotation(&self, rotation: &Rotation<'_>) -> Result<Built, SyncError> {
        let ik = rotation.recovery.identity_seed(self.origin(), self.account())?;
        let av = rotation.av.next()?;
        let keys = AccountKeys::generate()?;
        let mut objects = self.account_objects(&AccountObjectsPlan {
            av,
            kind: CertKind::GenesisOrRotation,
            ik: &ik,
            endorsing_ik: None,
            recovery: rotation.recovery,
            keys: &keys,
            devices: rotation.kept,
            wrapper: Some(rotation.rotating),
        })?;
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let current = rotation
                .current
                .iter()
                .find(|current| current.purpose == purpose)
                .ok_or(SyncError::Unknown {
                    what: "the personal or history key in force",
                })?;
            let next = ScopeKey::generate()?;
            let plan = ScopeKeyPlan {
                version: current.version.next()?,
                key: &next,
                start: Start::Next,
                previous: Some(&current.key),
            };
            objects.extend(self.personal_version_objects(purpose, &plan, av, &keys, rotation.rotating.key_device)?);
        }
        Ok(Built { av, keys, objects })
    }

    // The keys in force on an approved device, through the personal helpers.
    pub(crate) async fn current_keys(&self, txn: &mut dyn StateTxn) -> Result<Vec<CurrentKey>, SyncError> {
        let mut current = Vec::new();
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let held = self
                .current_personal(txn, purpose)
                .await?
                .ok_or(SyncError::NotAllowed {
                    what: "rotate without the personal and history keys in force",
                })?;
            let version = held.record.key.version;
            current.push(CurrentKey {
                purpose,
                version,
                key: self.personal_key(txn, purpose, version).await?,
            });
        }
        Ok(current)
    }
}
