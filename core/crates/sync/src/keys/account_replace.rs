// Replace Recovery Key (0056, Account flows): with the current R, a rotation to a new R' and IK' that the old IK
// endorses. It keeps this device and the own-device pins the person ticks; every other device joins again by approval.
// The team steps run from `key_pending` at the next pass (0056, Rotation, step 3).

use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::KeysError;
use tablepro_keys::body::KeyObject;
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::Start;

use super::account_genesis::{ShownKey, refusal};
use super::{AccountObjectsPlan, KeptDevice, KeyService, OwnAccount, ScopeKeyPlan, create_change};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{AccountDevice, DraftId, ReviewedDevice, RotationDraft, TypedBack};
use crate::api::state::{KeyPendingRow, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::{DpopKey, RejectedCode};

struct ReplaceDraft {
    current: RecoveryKey,
    next: ShownKey,
    built: Option<BuiltReplace>,
}

#[derive(Clone)]
struct BuiltReplace {
    av: Version,
    keep: Vec<KeyDeviceId>,
    objects: Vec<KeyObject>,
    keys: AccountKeys,
}

impl KeyService {
    pub(crate) async fn start_replace(&self, recovery_key: &SecretString) -> Result<RotationDraft, SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let own = self.approved_account(txn.as_mut()).await?;
        let current = RecoveryKey::parse(recovery_key.expose_secret())?;
        if current.identity_seed(self.origin(), self.account())?.public()? != own.ik {
            return Err(KeysError::Signature.into());
        }
        let mut devices = vec![reviewed(own.device.key_device, true)];
        for key_device in compared_devices(txn.as_mut()).await? {
            if key_device != own.device.key_device {
                devices.push(reviewed(key_device, false));
            }
        }
        let next = ShownKey::new()?;
        let draft = self.drafts().put(ReplaceDraft {
            current,
            next,
            built: None,
        })?;
        let recovery = self
            .drafts()
            .with(draft, |held: &mut ReplaceDraft| held.next.draft(draft))??;
        Ok(RotationDraft { recovery, devices })
    }

    pub(crate) async fn complete_replace(
        &self,
        draft: DraftId,
        typed: &TypedBack,
        keep: &[KeyDeviceId],
    ) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.drafts()
            .with(draft, |held: &mut ReplaceDraft| held.next.check_typed_back(typed))??;
        let mut txn = self.begin().await?;
        let own = self.approved_account(txn.as_mut()).await?;
        let mut kept = vec![KeptDevice::of(&own.device)?];
        let mut keep_ids: Vec<KeyDeviceId> = Vec::new();
        for key_device in keep {
            if *key_device == own.device.key_device || keep_ids.contains(key_device) {
                continue;
            }
            match txn.get(&RowKey::KeyDevicePin(*key_device)).await? {
                Some(Row::KeyDevicePin(pin)) => kept.push(KeptDevice {
                    key_device: pin.key_device,
                    dek: pin.dek,
                    dsk: pin.dsk,
                }),
                _ => return Err(KeysError::NotCompared.into()),
            }
            keep_ids.push(*key_device);
        }
        let av = own.av.next()?;
        let reuse = self.drafts().with(draft, |held: &mut ReplaceDraft| {
            held.built
                .clone()
                .filter(|built| built.av == av && built.keep == keep_ids)
        })?;
        let built = match reuse {
            Some(built) => built,
            None => {
                let previous = self.previous_personal_keys(txn.as_mut()).await?;
                let built = self.drafts().with(draft, |held: &mut ReplaceDraft| {
                    self.replace_objects(held, &own, &kept, av, &previous)
                        .map(|(objects, keys)| BuiltReplace {
                            av,
                            keep: keep_ids.clone(),
                            objects,
                            keys,
                        })
                })??;
                self.drafts()
                    .with(draft, |held: &mut ReplaceDraft| held.built = Some(built.clone()))?;
                built
            }
        };
        drop(txn);
        self.store_account_keys(av, &built.keys).await?;
        let pending = RowKey::KeyPending(PendingFlow::AccountRotation { av });
        let mut txn = self.begin().await?;
        for object in &built.objects {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
        }
        // Written with the candidates, so the team steps still run when the device stops after the push applies.
        txn.put(Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::AccountRotation { av },
            state: Vec::new(),
        }))
        .await?;
        txn.commit().await?;
        let changes = built.objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self
            .push_change_set(ScopeName::Personal, changes, DpopKey(Arc::new(own.device.dsk.clone())))
            .await?;
        match refusal(&outcomes) {
            None => {
                let mut txn = self.begin().await?;
                self.adopt_account_change_set(txn.as_mut(), &built.objects).await?;
                txn.commit().await?;
                self.drafts().remove(draft);
                self.hooks().pass_soon();
                Ok(())
            }
            Some(code) => {
                let mut txn = self.begin().await?;
                self.drop_candidates(txn.as_mut(), ScopeName::Personal, &built.objects)
                    .await?;
                txn.delete(&pending).await?;
                txn.commit().await?;
                self.erase_account_keys(av).await?;
                if code == RejectedCode::CreateOnly {
                    self.drafts().remove(draft);
                    self.hooks().pass_soon();
                } else {
                    self.drafts().with(draft, |held: &mut ReplaceDraft| held.built = None)?;
                }
                Err(SyncError::Rejected { code })
            }
        }
    }

    async fn approved_account(&self, txn: &mut dyn StateTxn) -> Result<OwnAccount, SyncError> {
        self.own_account(txn).await?.ok_or(SyncError::NotAllowed {
            what: "rotate the account keys on a device that holds none",
        })
    }

    // The personal and history keys a rotation's rings carry forward: the versions signed under the current `av`.
    async fn previous_personal_keys(&self, txn: &mut dyn StateTxn) -> Result<[(Version, ScopeKey); 2], SyncError> {
        let mut keys = Vec::with_capacity(2);
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let current = self
                .current_personal(txn, purpose)
                .await?
                .ok_or(SyncError::NotAllowed {
                    what: "rotate without the personal keys of the current account version",
                })?;
            let version = current.record.key.version;
            keys.push((version, self.personal_key(txn, purpose, version).await?));
        }
        let [personal, history]: [(Version, ScopeKey); 2] = keys
            .try_into()
            .map_err(|_| SyncError::Malformed { what: "personal keys" })?;
        Ok([personal, history])
    }

    fn replace_objects(
        &self,
        held: &ReplaceDraft,
        own: &OwnAccount,
        kept: &[KeptDevice],
        av: Version,
        previous: &[(Version, ScopeKey); 2],
    ) -> Result<(Vec<KeyObject>, AccountKeys), SyncError> {
        let keys = AccountKeys::generate()?;
        let ik = held.next.key.identity_seed(self.origin(), self.account())?;
        let endorsing = held.current.identity_seed(self.origin(), self.account())?;
        let mut objects = self.account_objects(&AccountObjectsPlan {
            av,
            kind: CertKind::Replace,
            ik: &ik,
            endorsing_ik: Some(&endorsing),
            recovery: &held.next.key,
            keys: &keys,
            devices: kept,
            wrapper: Some(&own.device),
        })?;
        for (purpose, (version, key)) in [KeyPurpose::Personal, KeyPurpose::History].into_iter().zip(previous) {
            let next = ScopeKey::generate()?;
            objects.extend(self.personal_version_objects(
                purpose,
                &ScopeKeyPlan {
                    version: version.next()?,
                    key: &next,
                    start: Start::Next,
                    previous: Some(key),
                },
                av,
                &keys,
                own.device.key_device,
            )?);
        }
        Ok((objects, keys))
    }
}

async fn compared_devices(txn: &mut dyn StateTxn) -> Result<Vec<KeyDeviceId>, SyncError> {
    Ok(txn
        .scan(&RowRange::Table(Table::KeyDevicePins))
        .await?
        .iter()
        .filter_map(|row| match row {
            Row::KeyDevicePin(pin) => Some(pin.key_device),
            _ => None,
        })
        .collect())
}

fn reviewed(key_device: KeyDeviceId, this_device: bool) -> ReviewedDevice {
    ReviewedDevice {
        device: AccountDevice {
            key_device,
            device: None,
            name: None,
            platform: None,
            added_at_us: None,
            this_device,
            compared: true,
        },
        keep_by_default: true,
    }
}
