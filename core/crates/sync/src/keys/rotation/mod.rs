// `DeviceFlows` (0056, Account flows: Rotation, Removing a device, Recovery). Nothing rotates until R is typed; the
// rotation keeps only this device and the own-device pins the person ticked; each team is then rotated without the
// members the review marked, and the choices stay in `key_pending` until every team rotation is written.

mod plan;
mod recovery;
mod review;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version, WrapPurpose};
use tablepro_keys::keys::DeviceKeys;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;

use self::plan::{Built, Rotation, check_recovery_key, kept_devices};
use self::review::TeamSteps;
use super::approval::{Pushed, pushed};
use super::{HeldDeviceKeys, KeyService, create_change};
use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, ScopeName};
use crate::api::key_flows::{
    AccountDevice, DeviceFlows, DraftId, KeyNoticeKind, RemovalReview, ReviewedDevice, ReviewedMember, TeamFlows,
};
use crate::api::state::{KeyPendingRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};

// What a removal holds between the review and the rotation: R, the lost devices and the members it listed.
struct RemovalDraft {
    recovery: RecoveryKey,
    lost: Vec<KeyDeviceId>,
    members: Vec<ReviewedMember>,
}

fn recovery_key(text: &SecretString) -> Result<RecoveryKey, SyncError> {
    Ok(RecoveryKey::parse(text.expose_secret())?)
}

#[async_trait]
impl DeviceFlows for KeyService {
    async fn account_devices(&self) -> Result<Vec<AccountDevice>, SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        self.devices_of_account(txn.as_mut()).await
    }

    async fn remove_device_row(&self, device: DeviceRowId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        {
            let mut txn = self.begin().await?;
            if self.own_account(txn.as_mut()).await?.is_none() {
                return Err(SyncError::NotAllowed {
                    what: "remove a device",
                });
            }
        }
        self.transport()
            .remove_device_row(device.clone(), self.dpop_key().await?)
            .await?;
        self.raise_notice(KeyNoticeKind::DeviceRemoved { device })?;
        self.hooks().pass_soon();
        Ok(())
    }

    async fn begin_removal(
        &self,
        recovery_key_text: SecretString,
        lost: Vec<KeyDeviceId>,
    ) -> Result<RemovalReview, SyncError> {
        let _serial = self.serialized().await;
        let recovery = recovery_key(&recovery_key_text)?;
        let mut txn = self.begin().await?;
        let own = self.own_account(txn.as_mut()).await?.ok_or(SyncError::NotAllowed {
            what: "remove a device",
        })?;
        check_recovery_key(self, &recovery, &own.ik)?;
        let devices = self
            .devices_of_account(txn.as_mut())
            .await?
            .into_iter()
            .map(|device| ReviewedDevice {
                keep_by_default: device.compared && !lost.contains(&device.key_device),
                device,
            })
            .collect();
        let members = self.removal_review(txn.as_mut(), &lost).await?;
        let review = self.drafts().put(RemovalDraft {
            recovery,
            lost,
            members: members.clone(),
        })?;
        Ok(RemovalReview {
            review,
            devices,
            members,
        })
    }

    async fn finish_removal(
        &self,
        review: DraftId,
        keep: Vec<KeyDeviceId>,
        remove: Vec<ReviewedMember>,
    ) -> Result<(), SyncError> {
        let av = self.removal_rotation(review, &keep, &remove).await?;
        self.team_steps(av).await
    }

    async fn recover(&self, recovery_key_text: SecretString) -> Result<(), SyncError> {
        let av = self.recovery_rotation(&recovery_key_text).await?;
        self.team_steps(av).await
    }

    async fn resume_rotation(&self, av: Version) -> Result<(), SyncError> {
        self.team_steps(av).await
    }
}

impl KeyService {
    // The account part of a removal, under the serial lock; the team steps take it themselves around each write, so
    // the team flows they call can take it too.
    async fn removal_rotation(
        &self,
        review: DraftId,
        keep: &[KeyDeviceId],
        remove: &[ReviewedMember],
    ) -> Result<Version, SyncError> {
        let _serial = self.serialized().await;
        let draft: RemovalDraft = self.drafts().take(review)?;
        if keep.iter().any(|device| draft.lost.contains(device)) {
            return Err(SyncError::NotAllowed {
                what: "keep a lost device",
            });
        }
        if !remove.iter().all(|member| draft.members.contains(member)) {
            return Err(SyncError::Unknown {
                what: "reviewed member",
            });
        }
        let steps = TeamSteps {
            remove: remove.iter().map(|member| (member.team, member.account)).collect(),
            done: Vec::new(),
        };
        let mut txn = self.begin().await?;
        let own = self.own_account(txn.as_mut()).await?.ok_or(SyncError::NotAllowed {
            what: "remove a device",
        })?;
        check_recovery_key(self, &draft.recovery, &own.ik)?;
        let kept = kept_devices(txn.as_mut(), &own.device, keep).await?;
        let current = self.current_keys(txn.as_mut()).await?;
        drop(txn);
        let rotation = Rotation {
            av: own.av,
            recovery: &draft.recovery,
            rotating: &own.device,
            kept: &kept,
            current: &current,
        };
        self.rotate_account(&rotation, &steps, None).await
    }

    async fn recovery_rotation(&self, recovery_key_text: &SecretString) -> Result<Version, SyncError> {
        let _serial = self.serialized().await;
        let recovery = recovery_key(recovery_key_text)?;
        let mut txn = self.begin().await?;
        if self.own_account(txn.as_mut()).await?.is_some() {
            return Err(SyncError::NotAllowed {
                what: "recover a device that holds the account's keys",
            });
        }
        let recovered = self.read_with_recovery_key(txn.as_mut(), &recovery).await?;
        drop(txn);
        // It compared with no device, so the rotation keeps only itself, under new device keys.
        let device = DeviceKeys::generate()?;
        let held = self.device_keys().await?;
        self.store_device_keys(&HeldDeviceKeys {
            current: held.current.clone(),
            pending: Some(device.clone()),
        })
        .await?;
        self.store_account_keys(recovered.certificate.av, &recovered.keys)
            .await?;
        let kept = [super::KeptDevice::of(&device)?];
        let rotation = Rotation {
            av: recovered.certificate.av,
            recovery: &recovery,
            rotating: &device,
            kept: &kept,
            current: &recovered.current,
        };
        let av = self.rotate_account(&rotation, &TeamSteps::default(), Some(held)).await?;
        self.clear_unanchored();
        Ok(av)
    }

    async fn devices_of_account(&self, txn: &mut dyn StateTxn) -> Result<Vec<AccountDevice>, SyncError> {
        let account = self.account();
        let own = self.own_account(txn).await?;
        let this = self.device_keys().await?.current.map(|keys| keys.key_device);
        let pins: Vec<KeyDeviceId> = txn
            .scan(&RowRange::Table(Table::KeyDevicePins))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::KeyDevicePin(pin) => Some(pin.key_device),
                _ => None,
            })
            .collect();
        let mut devices = Vec::new();
        let Some(own) = own else {
            return Ok(devices);
        };
        for held in self.held_objects(txn, ScopeName::Personal, KeyKind::Device).await? {
            let KeyRecordId::Device {
                account: owner,
                key_device,
                av,
            } = held.object.id
            else {
                continue;
            };
            if owner != account || av != own.av || !held.applied {
                continue;
            }
            devices.push(AccountDevice {
                key_device,
                device: (Some(key_device) == this).then(|| self.device_row().clone()),
                name: None,
                platform: None,
                added_at_us: None,
                this_device: Some(key_device) == this,
                compared: pins.contains(&key_device),
            });
        }
        Ok(devices)
    }

    // Pushes one rotation change set and adopts it once applied. The new account keys go to the device store and the
    // set to `key_objects` as candidates before the push, so a retry resends the same objects.
    async fn rotate_account(
        &self,
        rotation: &Rotation<'_>,
        steps: &TeamSteps,
        recovering: Option<HeldDeviceKeys>,
    ) -> Result<Version, SyncError> {
        let built = self.build_rotation(rotation)?;
        self.store_account_keys(built.av, &built.keys).await?;
        let flow = PendingFlow::AccountRotation { av: built.av };
        {
            let mut txn = self.begin().await?;
            for object in &built.objects {
                self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                    .await?;
            }
            txn.put(Row::KeyPending(KeyPendingRow {
                flow,
                state: steps.encode(),
            }))
            .await?;
            txn.commit().await?;
        }
        let changes = built.objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let answer = self
            .push_change_set(ScopeName::Personal, changes, built.proof(rotation.rotating))
            .await
            .and_then(|outcomes| pushed(&outcomes));
        match answer {
            Ok(Pushed::Applied) => {
                self.rotation_applied(&built, rotation, recovering).await?;
                Ok(built.av)
            }
            Ok(Pushed::Refused(code)) => {
                self.rotation_refused(&built, recovering).await?;
                Err(SyncError::Rejected { code })
            }
            // Not answered: the candidates stay, and `resume_rotation` sends them again.
            Err(error) => Err(error),
        }
    }

    async fn rotation_applied(
        &self,
        built: &Built,
        rotation: &Rotation<'_>,
        recovering: Option<HeldDeviceKeys>,
    ) -> Result<(), SyncError> {
        if recovering.is_some() {
            self.store_device_keys(&HeldDeviceKeys {
                current: Some(rotation.rotating.clone()),
                pending: None,
            })
            .await?;
        }
        let mut txn = self.begin().await?;
        self.adopt_account_change_set(txn.as_mut(), &built.objects).await?;
        let kept: Vec<KeyDeviceId> = rotation.kept.iter().map(|device| device.key_device).collect();
        for row in txn.scan(&RowRange::Table(Table::KeyDevicePins)).await? {
            if let Row::KeyDevicePin(pin) = row
                && !kept.contains(&pin.key_device)
            {
                txn.delete(&RowKey::KeyDevicePin(pin.key_device)).await?;
            }
        }
        txn.commit().await?;
        self.reset_superseded_at(built.av).await?;
        self.hooks().pass_soon();
        Ok(())
    }

    async fn rotation_refused(&self, built: &Built, recovering: Option<HeldDeviceKeys>) -> Result<(), SyncError> {
        self.erase_account_keys(built.av).await?;
        let mut txn = self.begin().await?;
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, &built.objects)
            .await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av: built.av }))
            .await?;
        txn.commit().await?;
        if let Some(held) = recovering {
            self.store_device_keys(&HeldDeviceKeys {
                current: held.current,
                pending: None,
            })
            .await?;
        }
        Ok(())
    }

    // The change set at `av` resent while its candidates have not applied, then, once this device holds the account
    // at `av`, each team where it holds the key: its certificate copied in as `key.member`, and the team rotated
    // without the members the review marked, whether or not the server still lists them.
    async fn team_steps(&self, av: Version) -> Result<(), SyncError> {
        let flow = PendingFlow::AccountRotation { av };
        let (mut steps, teams) = {
            let _serial = self.serialized().await;
            let mut txn = self.begin().await?;
            let Some(Row::KeyPending(row)) = txn.get(&RowKey::KeyPending(flow)).await? else {
                return Ok(());
            };
            let steps = TeamSteps::decode(&row.state)?;
            let Some(own) = self.own_account(txn.as_mut()).await? else {
                return Ok(());
            };
            if own.av < av {
                drop(txn);
                return self.resend_rotation(av).await;
            }
            let teams = self.held_teams(txn.as_mut()).await?;
            (steps, teams)
        };
        for team in teams {
            if steps.done.contains(&team) {
                continue;
            }
            self.publish_member_certificate(team).await?;
            self.rotate_team(team, steps.removals_for(team)).await?;
            steps.done.push(team);
            let _serial = self.serialized().await;
            let mut txn = self.begin().await?;
            txn.put(Row::KeyPending(KeyPendingRow {
                flow,
                state: steps.encode(),
            }))
            .await?;
            txn.commit().await?;
        }
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        txn.delete(&RowKey::KeyPending(flow)).await?;
        txn.commit().await?;
        Ok(())
    }

    // The teams where this account held the current key just before its rotation.
    async fn held_teams(&self, txn: &mut dyn StateTxn) -> Result<Vec<tablepro_keys::encoding::TeamId>, SyncError> {
        let account = self.account();
        Ok(txn
            .scan(&RowRange::Table(Table::KeyVersions))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::KeyVersion(version) => match version.scope {
                    ScopeName::Team(team)
                        if version.purpose == KeyPurpose::Team
                            && version.state == KeyVersionState::Ok
                            && version.holders.iter().any(|holder| holder.account == account) =>
                    {
                        Some(team)
                    }
                    _ => None,
                },
                _ => None,
            })
            .collect())
    }

    // This device's own candidates of the account change set at `av`: a rotation's, a replace's or a reset's
    // activation, each with the rings of its version records.
    pub(crate) async fn change_set_candidates(&self, av: Version) -> Result<Vec<KeyObject>, SyncError> {
        let mut txn = self.begin().await?;
        let mut objects = Vec::new();
        // Certificates before what they certify, and each version record before its ring and its wraps.
        for kind in [KeyKind::Account, KeyKind::Recovery, KeyKind::Device, KeyKind::Version] {
            for held in self.held_objects(txn.as_mut(), ScopeName::Personal, kind).await? {
                if !held.applied && in_change_set(&held.object, av) {
                    objects.push(held.object);
                }
            }
        }
        let versions: Vec<_> = objects
            .iter()
            .filter_map(KeyObject::version_record)
            .map(|record| record.key)
            .collect();
        for held in self
            .held_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Ring)
            .await?
        {
            if let KeyRecordId::Ring(key) = held.object.id
                && !held.applied
                && versions.contains(&key)
            {
                objects.push(held.object);
            }
        }
        for held in self
            .held_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Wrap)
            .await?
        {
            if !held.applied && in_change_set(&held.object, av) {
                objects.push(held.object);
            }
        }
        Ok(objects)
    }

    // This device's own candidates of the change set at `av`, sent again as they are.
    async fn resend_rotation(&self, av: Version) -> Result<(), SyncError> {
        let objects = self.change_set_candidates(av).await?;
        let Some(KeyObject {
            body: KeyBody::Account(_),
            ..
        }) = objects.iter().find(|object| object.id.kind() == KeyKind::Account)
        else {
            return Ok(());
        };
        let wrapper = objects
            .iter()
            .filter_map(KeyObject::wrap)
            .find(|wrap| wrap.target.purpose == WrapPurpose::Account)
            .map(|wrap| wrap.wrapper.key_device)
            .ok_or(SyncError::Unknown {
                what: "the rotation's writing key device",
            })?;
        let held = self.device_keys().await?;
        let rotating = [held.current.clone(), held.pending.clone()]
            .into_iter()
            .flatten()
            .find(|keys| keys.key_device == wrapper)
            .ok_or(SyncError::Unknown {
                what: "the rotation's device keys",
            })?;
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let proof = crate::api::transport::DpopKey(std::sync::Arc::new(rotating.dsk.clone()));
        let outcomes = self.push_change_set(ScopeName::Personal, changes, proof).await?;
        let mut txn = self.begin().await?;
        match pushed(&outcomes)? {
            Pushed::Applied => {
                if held
                    .pending
                    .as_ref()
                    .is_some_and(|pending| pending.key_device == wrapper)
                {
                    self.store_device_keys(&HeldDeviceKeys {
                        current: Some(rotating),
                        pending: None,
                    })
                    .await?;
                }
                self.adopt_account_change_set(txn.as_mut(), &objects).await?;
            }
            Pushed::Refused(code) => {
                self.drop_candidates(txn.as_mut(), ScopeName::Personal, &objects)
                    .await?;
                txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
                    .await?;
                txn.commit().await?;
                return Err(SyncError::Rejected { code });
            }
        }
        txn.commit().await?;
        self.hooks().pass_soon();
        Ok(())
    }
}

// The objects an account change set at `av` writes in the personal scope.
fn in_change_set(object: &KeyObject, av: Version) -> bool {
    match &object.id {
        KeyRecordId::Account { av: at, .. }
        | KeyRecordId::Recovery { av: at, .. }
        | KeyRecordId::Device { av: at, .. } => *at == av,
        KeyRecordId::Wrap(target) => match target.purpose {
            WrapPurpose::Account => target.version == av,
            WrapPurpose::Key(_) => target.recipient_version == av,
            WrapPurpose::Trust => false,
        },
        KeyRecordId::Version(_) => object.version_record().is_some_and(|record| record.signer_av == av),
        _ => false,
    }
}

