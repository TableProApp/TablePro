// Replace Recovery Key (0056, Account flows): with the current R, a rotation to a new R' and IK' that the old IK
// endorses. It keeps this device and the own-device pins the person ticks among those the account still certifies;
// every other device joins again by approval.
// The team steps run from `key_pending` at the next pass (0056, Rotation, step 3).

use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::Start;

use super::account_genesis::{ShownKey, refusal};
use super::{AccountObjectsPlan, KeptDevice, KeyService, OwnAccount, ScopeKeyPlan, create_change};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{
    AccountDevice, DraftId, KeyState, RecoveryKeyDraft, ReviewedDevice, RotationDraft, TypedBack,
};
use crate::api::state::{KeyPendingRow, PendingFlow, Row, RowKey, RowRange, ScopeRow, StateTxn, Table};
use crate::api::transport::DpopKey;

struct ReplaceDraft {
    // R and R', wiped once the change set is built (0056, Rotation, step 4).
    secrets: Option<(RecoveryKey, ShownKey)>,
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
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let own = self.rotating_account(txn.as_mut()).await?;
        // A rotation this device pushed and never heard the end of goes up again, the same objects, before any new
        // one: a second R' must never stand in for one that applied (0054, `key_objects`).
        if let Some(candidates) = self.rotation_candidates(txn.as_mut(), own.av.next()?).await? {
            drop(txn);
            if self.push_rotation_candidates(&own, &candidates).await? {
                return Err(SyncError::NotAllowed {
                    what: "replace again: this device's earlier rotation applied",
                });
            }
            txn = self.begin().await?;
        }
        let current = RecoveryKey::parse(recovery_key.expose_secret())?;
        if current.identity_seed(self.origin(), self.account())?.public()? != own.ik {
            return Err(KeysError::Signature.into());
        }
        let mut devices = vec![reviewed(own.device.key_device, true)];
        for kept in self.certified_pins(txn.as_mut(), &own).await? {
            devices.push(reviewed(kept.key_device, false));
        }
        let next = ShownKey::new()?;
        let recovery = next.draft(DraftId(uuid::Uuid::nil()))?;
        let draft = self.drafts().put(ReplaceDraft {
            secrets: Some((current, next)),
            built: None,
        })?;
        Ok(RotationDraft {
            recovery: RecoveryKeyDraft { draft, ..recovery },
            devices,
        })
    }

    pub(crate) async fn complete_replace(
        &self,
        draft: DraftId,
        typed: &TypedBack,
        keep: &[KeyDeviceId],
    ) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let held = self
            .drafts()
            .with(draft, |held: &mut ReplaceDraft| held.built.clone())?;
        if held.is_none() {
            self.drafts().with(draft, |held: &mut ReplaceDraft| {
                held.secrets
                    .as_ref()
                    .ok_or(SyncError::Unknown { what: "draft" })
                    .and_then(|(_, next)| next.check_typed_back(typed))
            })??;
        }
        let mut txn = self.begin().await?;
        let own = self.rotating_account(txn.as_mut()).await?;
        let mut keep_ids: Vec<KeyDeviceId> = Vec::new();
        for key_device in keep {
            if *key_device != own.device.key_device && !keep_ids.contains(key_device) {
                keep_ids.push(*key_device);
            }
        }
        keep_ids.sort();
        // A retry after an answer that never came, when a pull since showed the replace applied: its certificate is
        // the one in force at its `av`, however far the account has moved since.
        if let Some(built) = &held
            && self.built_in_force(txn.as_mut(), built).await?
        {
            self.forget_pins_left_out(txn.as_mut(), &built.keep).await?;
            txn.commit().await?;
            self.drafts().remove(draft);
            return Ok(());
        }
        let av = own.av.next()?;
        let candidates = self.rotation_candidates(txn.as_mut(), av).await?;
        let built = match held {
            // Pushed already, maybe applied: only the same objects may go up again.
            Some(built) if built.av == av && built.keep != keep_ids => {
                return Err(SyncError::NotAllowed {
                    what: "keep the devices this replace was built with",
                });
            }
            Some(built) if built.av == av => built,
            Some(_) => {
                self.drafts().remove(draft);
                return Err(SyncError::NotAllowed {
                    what: "finish a replace the account moved past; start it again",
                });
            }
            None if candidates.is_some() => {
                return Err(SyncError::NotAllowed {
                    what: "replace while an earlier rotation on this device is unresolved",
                });
            }
            None => match self.build_replace(txn.as_mut(), draft, &own, &keep_ids, av).await {
                Ok(built) => built,
                Err(error) => {
                    self.drafts().remove(draft);
                    return Err(error);
                }
            },
        };
        drop(txn);
        self.store_account_keys(av, &built.keys).await?;
        let mut txn = self.begin().await?;
        for object in &built.objects {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
        }
        // Written with the candidates, so the team steps still run when the device stops after the push applies. It
        // names the replace's certificate, so a rotation another device won at `av` is never taken for it.
        txn.put(Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::AccountRotation { av },
            state: super::rotation::flow_state(&built.objects),
        }))
        .await?;
        // What the push changes is not known until a pull after it catches up.
        if let Some(Row::Scope(row)) = txn.get(&RowKey::Scope(ScopeName::Personal)).await? {
            txn.put(Row::Scope(ScopeRow {
                caught_up: false,
                ..row
            }))
            .await?;
        }
        txn.commit().await?;
        let outcome = self.push_replace(&own, &built, candidates.is_some()).await;
        if !matches!(outcome, Err(SyncError::Transport(_))) {
            self.drafts().remove(draft);
        }
        outcome
    }

    // Pushes the built replace and settles the answer. A first push refused whole never applied; a push again after a
    // lost answer may have, so its refusal waits for a pull.
    async fn push_replace(&self, own: &OwnAccount, built: &BuiltReplace, retry: bool) -> Result<(), SyncError> {
        let pending = RowKey::KeyPending(PendingFlow::AccountRotation { av: built.av });
        let changes = built.objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self
            .push_change_set(ScopeName::Personal, changes, DpopKey(Arc::new(own.device.dsk.clone())))
            .await?;
        self.hooks().pass_soon();
        let Some(code) = refusal(&outcomes) else {
            let mut txn = self.begin().await?;
            self.adopt_account_change_set(txn.as_mut(), &built.objects).await?;
            self.forget_pins_left_out(txn.as_mut(), &built.keep).await?;
            txn.commit().await?;
            return Ok(());
        };
        if !retry {
            let mut txn = self.begin().await?;
            self.drop_candidates(txn.as_mut(), ScopeName::Personal, &built.objects)
                .await?;
            txn.delete(&pending).await?;
            txn.commit().await?;
            self.erase_account_keys(built.av).await?;
        }
        Err(SyncError::Rejected { code })
    }

    // Whether the built replace's certificate is the one in force at its `av`.
    async fn built_in_force(&self, txn: &mut dyn StateTxn, built: &BuiltReplace) -> Result<bool, SyncError> {
        let id = KeyRecordId::Account {
            account: self.account(),
            av: built.av,
        };
        let in_force = self
            .applied_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?;
        Ok(built
            .objects
            .iter()
            .any(|object| object.id == id && in_force.as_ref() == Some(object)))
    }

    // The replace's change set, from the draft's R and R', which go once it is built. Only devices the account still
    // certifies at its current `av` can be kept.
    async fn build_replace(
        &self,
        txn: &mut dyn StateTxn,
        draft: DraftId,
        own: &OwnAccount,
        keep: &[KeyDeviceId],
        av: Version,
    ) -> Result<BuiltReplace, SyncError> {
        let mut kept = vec![KeptDevice::of(&own.device)?];
        let certified = self.certified_pins(txn, own).await?;
        for key_device in keep {
            match certified.iter().find(|kept| kept.key_device == *key_device) {
                Some(device) => kept.push(*device),
                None if txn.get(&RowKey::KeyDevicePin(*key_device)).await?.is_some() => {
                    return Err(SyncError::NotAllowed {
                        what: "keep a device the account no longer certifies",
                    });
                }
                None => return Err(KeysError::NotCompared.into()),
            }
        }
        let previous = self.previous_personal_keys(txn).await?;
        self.drafts().with(draft, |held: &mut ReplaceDraft| {
            let (current, next) = held.secrets.take().ok_or(SyncError::Unknown { what: "draft" })?;
            // The account may have moved on since the draft began: R must still be its recovery key.
            if current.identity_seed(self.origin(), self.account())?.public()? != own.ik {
                return Err(KeysError::Signature.into());
            }
            let (objects, keys) = self.replace_objects(&current, &next, own, &kept, av, &previous)?;
            let built = BuiltReplace {
                av,
                keep: keep.to_vec(),
                objects,
                keys,
            };
            held.built = Some(built.clone());
            Ok(built)
        })?
    }

    // This device's own objects of a rotation to `av` that never applied: its certificate and blob, the device
    // certificates and `account` wraps at `av`, and the personal and history versions signed under it with their rings
    // and wraps. None when no certificate of its own at `av` waits.
    pub(crate) async fn rotation_candidates(
        &self,
        txn: &mut dyn StateTxn,
        av: Version,
    ) -> Result<Option<Vec<KeyObject>>, SyncError> {
        let id = KeyRecordId::Account {
            account: self.account(),
            av,
        };
        // A reset's activation waits at the same id, and is only ever sent by its own flow.
        let waiting = self
            .held_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?
            .is_some_and(|held| {
                !held.applied
                    && matches!(
                        &held.object.body,
                        KeyBody::Account(body)
                            if matches!(body.certificate(self.account(), av).kind, CertKind::GenesisOrRotation | CertKind::Replace)
                    )
            });
        if !waiting {
            return Ok(None);
        }
        let mut objects: Vec<KeyObject> = Vec::new();
        for kind in [
            KeyKind::Account,
            KeyKind::Recovery,
            KeyKind::Device,
            KeyKind::Version,
            KeyKind::Ring,
            KeyKind::Wrap,
        ] {
            for held in self.held_objects(txn, ScopeName::Personal, kind).await? {
                // A ring goes with its version record, so only the rings of this rotation's versions.
                let ours = match held.object.id {
                    KeyRecordId::Ring(key) => objects.iter().any(|object| object.id == KeyRecordId::Version(key)),
                    _ => of_rotation(&held.object, av),
                };
                if !held.applied && ours {
                    objects.push(held.object);
                }
            }
        }
        Ok(Some(objects))
    }

    // Pushes a rotation's candidates again and settles the answer: true when it applied and was adopted, false when it
    // was refused and is gone. A failed call leaves them waiting.
    async fn push_rotation_candidates(&self, own: &OwnAccount, objects: &[KeyObject]) -> Result<bool, SyncError> {
        let Some(av) = objects.iter().find_map(|object| match object.id {
            KeyRecordId::Account { av, .. } => Some(av),
            _ => None,
        }) else {
            return Ok(false);
        };
        let keep: Vec<KeyDeviceId> = objects
            .iter()
            .filter_map(|object| match object.id {
                KeyRecordId::Device { key_device, .. } => Some(key_device),
                _ => None,
            })
            .collect();
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self
            .push_change_set(ScopeName::Personal, changes, DpopKey(Arc::new(own.device.dsk.clone())))
            .await?;
        let mut txn = self.begin().await?;
        self.hooks().pass_soon();
        let Some(code) = refusal(&outcomes) else {
            self.adopt_account_change_set(txn.as_mut(), objects).await?;
            self.forget_pins_left_out(txn.as_mut(), &keep).await?;
            txn.commit().await?;
            return Ok(true);
        };
        // The first push's answer was lost, so a refusal now may mean it applied and the server moved on. Only when a
        // pull that caught up shows nothing at `av` did it never apply; a rotation that won there is a pull's to settle.
        let caught_up = matches!(
            txn.get(&RowKey::Scope(ScopeName::Personal)).await?,
            Some(Row::Scope(row)) if row.caught_up
        );
        if !caught_up || self.own_certificate(txn.as_mut(), av).await?.is_some() {
            return Err(SyncError::Rejected { code });
        }
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, objects).await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
            .await?;
        txn.commit().await?;
        self.erase_account_keys(av).await?;
        Ok(false)
    }

    // A replace runs only on an approved device whose file it can trust, never over a stopped or ended key.
    async fn rotating_account(&self, txn: &mut dyn StateTxn) -> Result<OwnAccount, SyncError> {
        if self.is_rebuilding() {
            return Err(SyncError::NotAllowed {
                what: "rotate the account keys before the key tables are rebuilt",
            });
        }
        match self.state_of_keys(txn).await? {
            KeyState::Approved { .. } => self.approved_account(txn).await,
            KeyState::Locked { cause } => Err(SyncError::Locked { cause }),
            _ => Err(SyncError::NotAllowed {
                what: "rotate the account keys on a device that holds none",
            }),
        }
    }

    // The own-device pins the account still certifies at its current `av`, under the keys the comparison fixed. A pin
    // a rotation left out names a device that is no longer approved, and a replace never brings it back.
    async fn certified_pins(&self, txn: &mut dyn StateTxn, own: &OwnAccount) -> Result<Vec<KeptDevice>, SyncError> {
        let mut certified = Vec::new();
        for row in txn.scan(&RowRange::Table(Table::KeyDevicePins)).await? {
            let Row::KeyDevicePin(pin) = row else {
                continue;
            };
            if pin.key_device == own.device.key_device {
                continue;
            }
            let id = KeyRecordId::Device {
                account: self.account(),
                key_device: pin.key_device,
                av: own.av,
            };
            let Some(object) = self
                .applied_object(txn, ScopeName::Personal, KeyKind::Device, &id.to_wire())
                .await?
            else {
                continue;
            };
            let KeyBody::Device(body) = object.body else {
                continue;
            };
            let certificate = body.certificate(self.account(), pin.key_device, own.av);
            if certificate.verify(self.origin(), &own.public.ask).is_ok()
                && certificate.dek == pin.dek
                && certificate.dsk == pin.dsk
            {
                certified.push(KeptDevice {
                    key_device: pin.key_device,
                    dek: pin.dek,
                    dsk: pin.dsk,
                });
            }
        }
        Ok(certified)
    }

    // After the rotation, the own-device pins it left out name devices that join again only by approval.
    pub(crate) async fn forget_pins_left_out(
        &self,
        txn: &mut dyn StateTxn,
        keep: &[KeyDeviceId],
    ) -> Result<(), SyncError> {
        for row in txn.scan(&RowRange::Table(Table::KeyDevicePins)).await? {
            if let Row::KeyDevicePin(pin) = row
                && !keep.contains(&pin.key_device)
            {
                txn.delete(&RowKey::KeyDevicePin(pin.key_device)).await?;
            }
        }
        Ok(())
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
        current: &RecoveryKey,
        next: &ShownKey,
        own: &OwnAccount,
        kept: &[KeptDevice],
        av: Version,
        previous: &[(Version, ScopeKey); 2],
    ) -> Result<(Vec<KeyObject>, AccountKeys), SyncError> {
        let keys = AccountKeys::generate()?;
        let ik = next.key.identity_seed(self.origin(), self.account())?;
        let endorsing = current.identity_seed(self.origin(), self.account())?;
        let mut objects = self.account_objects(&AccountObjectsPlan {
            av,
            kind: CertKind::Replace,
            ik: &ik,
            endorsing_ik: Some(&endorsing),
            recovery: &next.key,
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

// An object of a rotation's change set to `av`.
pub(crate) fn of_rotation(object: &KeyObject, av: Version) -> bool {
    match &object.id {
        KeyRecordId::Account { av: at, .. }
        | KeyRecordId::Recovery { av: at, .. }
        | KeyRecordId::Device { av: at, .. } => *at == av,
        KeyRecordId::Version(_) => object.version_record().is_some_and(|record| record.signer_av == av),
        KeyRecordId::Wrap(target) => match target.purpose {
            tablepro_keys::encoding::WrapPurpose::Account => target.version == av,
            _ => object.wrap().is_some_and(|wrap| wrap.wrapper.av == av),
        },
        _ => false,
    }
}
