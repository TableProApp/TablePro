// `DeviceFlows` (0056, Account flows: Rotation, Removing a device, Recovery). Nothing rotates until R is typed; the
// rotation keeps only this device and the own-device pins the person ticked; each team is then rotated without the
// members the review marked, and the choices stay in `key_pending` until every team rotation is written.

mod plan;
mod recovery;
mod review;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::{AccountCertificate, IkChange};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, TeamId, Version, WrapPurpose};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, Signature};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::wrap::Recipient;

use self::plan::{Rotation, check_recovery_key, kept_devices};
use self::review::TeamSteps;
use super::approval::{Pushed, pushed};
use super::{HeldDeviceKeys, KeyService, create_change};
use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, ScopeName};
use crate::api::key_flows::{
    AccountDevice, DeviceFlows, DraftId, KeyNoticeKind, RemovalReview, ReviewedDevice, ReviewedMember, TeamFlows,
    TeamKeys,
};
use crate::api::state::{
    KeyPendingRow, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn, Table,
};
use crate::api::transport::{RejectedCode, TransportError};

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
        self.finish_cut_off_sign_out().await?;
        {
            let mut txn = self.begin().await?;
            self.approved_device_account(txn.as_mut(), "remove a device").await?;
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
        self.finish_cut_off_sign_out().await?;
        let recovery = recovery_key(&recovery_key_text)?;
        let mut txn = self.begin().await?;
        let own = self.approved_device_account(txn.as_mut(), "remove a device").await?;
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
        self.team_steps_now(av).await
    }

    async fn recover(&self, recovery_key_text: SecretString) -> Result<(), SyncError> {
        let av = self.recovery_rotation(&recovery_key_text).await?;
        self.team_steps_now(av).await
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
        self.finish_cut_off_sign_out().await?;
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
        let mut txn = self.begin().await?;
        let own = self.approved_device_account(txn.as_mut(), "remove a device").await?;
        check_recovery_key(self, &draft.recovery, &own.ik)?;
        // A rotation this device pushed and never heard the end of goes up again first, the same objects: a new one
        // must never stand in for one that applied (0054, `key_objects`).
        drop(txn);
        if let Resent::Applied = self.push_own_candidates(own.av.next()?).await? {
            return Err(SyncError::NotAllowed {
                what: "remove again: this device's earlier rotation applied",
            });
        }
        let mut txn = self.begin().await?;
        // Only an earlier rotation whose account change set has not settled holds a removal back. Team steps an earlier
        // one still owes, stuck ones included, carry into this one: removing a lost device with R always works (D7).
        if self.rotation_pending(txn.as_mut()).await? {
            self.hooks().pass_soon();
            return Err(SyncError::NotAllowed {
                what: "remove a device while an earlier rotation settles",
            });
        }
        let mut steps = self.carried_steps(txn.as_mut()).await?;
        steps.ik = Some(own.ik);
        for member in remove {
            if !steps.remove.contains(&(member.team, member.account)) {
                steps.remove.push((member.team, member.account));
            }
        }
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
        self.rotate_account(&rotation, &steps, None, None).await
    }

    async fn recovery_rotation(&self, recovery_key_text: &SecretString) -> Result<Version, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let recovery = recovery_key(recovery_key_text)?;
        let mut txn = self.begin().await?;
        self.forget_lost_rotation(txn.as_mut()).await?;
        // Also a device stopped on its personal key or with no anchor, which R clears as an approval would.
        if !self.may_ask_again(txn.as_mut()).await? {
            return Err(SyncError::NotAllowed {
                what: "recover a device that holds the account's keys",
            });
        }
        // A request still open, or an approval whose device key switch is owed, needs the pending device keys a
        // recovery would draw over.
        if self.asking(txn.as_mut()).await? || self.switch_owed(txn.as_mut()).await? {
            return Err(SyncError::NotAllowed {
                what: "recover while an approval of this device is open",
            });
        }
        let recovered = self.read_with_recovery_key(txn.as_mut(), &recovery).await?;
        txn.commit().await?;
        let av = recovered.certificate.av.next()?;
        // An earlier recovery whose answer was lost goes up again, the same objects, before a new one; one a pull
        // already brought back is adopted. Either way no second rotation stands in for it.
        if let Resent::Applied = self.push_own_candidates(av).await? {
            return Ok(av);
        }
        let flow = PendingFlow::AccountRotation { av };
        let earlier = {
            let mut txn = self.begin().await?;
            match txn.get(&RowKey::KeyPending(flow)).await? {
                Some(Row::KeyPending(row)) => Some(TeamSteps::decode(&row.state)?),
                _ => None,
            }
        };
        if let Some(steps) = &earlier
            && self.rotation_standing_locked(av, steps).await? == Standing::Ours
        {
            return Ok(av);
        }
        // A recovery that stopped after storing the keys R opened still names them.
        let opened_before = earlier.and_then(|steps| steps.opened);
        let mut txn = self.begin().await?;
        if self.rotation_pending(txn.as_mut()).await? {
            self.hooks().pass_soon();
            return Err(SyncError::NotAllowed {
                what: "recover while an earlier rotation settles",
            });
        }
        let mut steps = self.carried_steps(txn.as_mut()).await?;
        // A file with no anchor trusts nothing it holds: a device recovered with R starts with no pins and no team
        // key (0054, A stale file; 0056, Pins).
        if self.is_unanchored() {
            for table in [Table::KeyPins, Table::KeyVersions, Table::KeyDevicePins] {
                for row in txn.scan(&RowRange::Table(table)).await? {
                    txn.delete(&row.key()).await?;
                }
            }
            txn.commit().await?;
        } else {
            drop(txn);
        }
        steps.ik = Some(recovered.certificate.ik);
        // The keys R opened, on a device that did not hold them, go if the recovery never applies: the flow names
        // them before they are stored, so a crash between the two leaves nothing unnamed.
        let opened = if opened_before == Some(recovered.certificate.av)
            || self.account_keys(recovered.certificate.av).await?.is_none()
        {
            steps.opened = Some(recovered.certificate.av);
            let mut txn = self.begin().await?;
            txn.put(Row::KeyPending(KeyPendingRow {
                flow: PendingFlow::AccountRotation { av },
                state: steps.encode(),
            }))
            .await?;
            txn.commit().await?;
            Some(&recovered.keys)
        } else {
            None
        };
        // It compared with no device, so the rotation keeps only itself, under new device keys.
        let device = DeviceKeys::generate()?;
        let held = self.device_keys().await?;
        self.store_device_keys(&HeldDeviceKeys {
            current: held.current.clone(),
            pending: Some(device.clone()),
        })
        .await?;
        let kept = [super::KeptDevice::of(&device)?];
        let rotation = Rotation {
            av: recovered.certificate.av,
            recovery: &recovery,
            rotating: &device,
            kept: &kept,
            current: &recovered.current,
        };
        let av = self.rotate_account(&rotation, &steps, Some(held), opened).await?;
        self.clear_unanchored();
        Ok(av)
    }

    // The devices the account certifies at its current `av`, each under that `av`'s ASK.
    async fn devices_of_account(&self, txn: &mut dyn StateTxn) -> Result<Vec<AccountDevice>, SyncError> {
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
        let Some(own) = own else {
            return Ok(Vec::new());
        };
        let mut devices = Vec::new();
        for key_device in self.certified_devices(txn, own.av).await? {
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
    // set to `key_objects` as candidates before the push, so a retry resends the same objects. The pending flow names
    // the certificate, so a resume tells this rotation from another device's at the same `av`.
    async fn rotate_account(
        &self,
        rotation: &Rotation<'_>,
        steps: &TeamSteps,
        recovering: Option<HeldDeviceKeys>,
        opened: Option<&AccountKeys>,
    ) -> Result<Version, SyncError> {
        let built = self.build_rotation(rotation)?;
        self.store_account_keys(built.av, &built.keys).await?;
        let flow = PendingFlow::AccountRotation { av: built.av };
        let steps = TeamSteps {
            certificate: certificate_signature(&built.objects),
            ..steps.clone()
        };
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
        if let (Some(av), Some(keys)) = (steps.opened, opened) {
            self.store_account_keys(av, keys).await?;
        }
        let changes = built.objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let answer = self
            .push_change_set(ScopeName::Personal, changes, built.proof(rotation.rotating))
            .await
            .and_then(|outcomes| pushed(&outcomes));
        match answer {
            Ok(Pushed::Applied) => {
                self.rotation_adopted(built.av, &built.objects).await?;
                Ok(built.av)
            }
            Ok(Pushed::Refused(code)) => {
                self.rotation_refused(built.av, &built.objects, recovering.is_some(), steps.opened)
                    .await?;
                Err(SyncError::Rejected { code })
            }
            // Not answered: the candidates stay, and `resume_rotation` sends them again.
            Err(error) => Err(error),
        }
    }

    // This device's rotation applied: the device keys that wrote it in force, the account at its `av`, and only the
    // devices it kept left as own-device pins.
    async fn rotation_adopted(&self, av: Version, objects: &[KeyObject]) -> Result<(), SyncError> {
        let writer = objects
            .iter()
            .filter_map(KeyObject::wrap)
            .find(|wrap| wrap.target.purpose == WrapPurpose::Account)
            .map(|wrap| wrap.wrapper.key_device)
            .ok_or(SyncError::Unknown {
                what: "the rotation's writing key device",
            })?;
        let held = self.device_keys().await?;
        if let Some(pending) = held.pending.filter(|pending| pending.key_device == writer) {
            self.store_device_keys(&HeldDeviceKeys {
                current: Some(pending),
                pending: None,
            })
            .await?;
            self.clear_unanchored();
        }
        let mut txn = self.begin().await?;
        let stopped = self.stopped_personal(txn.as_mut()).await?;
        // A pull may have followed the certificate already; then the objects are held as applied, and a key the pull
        // left stopped moves to the rotation's version, which this device wrote.
        let followed = self
            .pin(txn.as_mut(), self.account())
            .await?
            .is_some_and(|pin| pin.av >= av && !pin.alert);
        if followed {
            for object in objects {
                self.hold_object(txn.as_mut(), ScopeName::Personal, object, true)
                    .await?;
            }
            self.resume_stopped_personal(txn.as_mut(), objects, av).await?;
        } else {
            self.adopt_account_change_set(txn.as_mut(), objects).await?;
        }
        let kept = self.certified_devices(txn.as_mut(), av).await?;
        prune_device_pins(txn.as_mut(), &kept).await?;
        self.end_superseded_flows(txn.as_mut(), av).await?;
        txn.commit().await?;
        for scope in stopped {
            self.hooks().resume_scope(scope);
        }
        self.reset_superseded_at(av).await?;
        self.hooks().pass_soon();
        Ok(())
    }

    // The personal and history scopes stopped before an account change set that makes new keys current.
    async fn stopped_personal(&self, txn: &mut dyn StateTxn) -> Result<Vec<ScopeName>, SyncError> {
        let mut stopped = Vec::new();
        for (purpose, scope) in [
            (KeyPurpose::Personal, ScopeName::Personal),
            (KeyPurpose::History, ScopeName::History),
        ] {
            if let Some(Row::KeyVersion(row)) = txn.get(&RowKey::KeyVersion(ScopeName::Personal, purpose)).await?
                && row.state == KeyVersionState::Stopped
            {
                stopped.push(scope);
            }
        }
        Ok(stopped)
    }

    // The personal and history versions this device's own rotation to `av` wrote, made current where a key still
    // stands stopped below them.
    async fn resume_stopped_personal(
        &self,
        txn: &mut dyn StateTxn,
        objects: &[KeyObject],
        av: Version,
    ) -> Result<(), SyncError> {
        for object in objects {
            let Some(record) = object.version_record() else {
                continue;
            };
            if record.signer_av != av || record.key.purpose == KeyPurpose::Team {
                continue;
            }
            let Some(record) = self.verified_personal_record(txn, &record).await? else {
                continue;
            };
            let Some(row) = self.personal_row(txn, record.key.purpose).await? else {
                continue;
            };
            if row.state != KeyVersionState::Stopped || record.key.version <= row.version {
                continue;
            }
            txn.put(Row::KeyVersion(KeyVersionRow {
                scope: ScopeName::Personal,
                purpose: record.key.purpose,
                version: record.key.version,
                record: record.digest(self.origin())?,
                holders: Vec::new(),
                state: KeyVersionState::Ok,
                stopped_cause: None,
                epoch: None,
            }))
            .await?;
        }
        Ok(())
    }

    // A recovery that never applied leaves no copy of the account keys R opened, nor the device keys it drew.
    async fn rotation_refused(
        &self,
        av: Version,
        objects: &[KeyObject],
        recovering: bool,
        opened: Option<Version>,
    ) -> Result<(), SyncError> {
        self.erase_account_keys(av).await?;
        if let Some(opened) = opened {
            self.erase_account_keys(opened).await?;
        }
        let mut txn = self.begin().await?;
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, objects).await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
            .await?;
        txn.commit().await?;
        if recovering {
            let held = self.device_keys().await?;
            self.store_device_keys(&HeldDeviceKeys {
                current: held.current,
                pending: None,
            })
            .await?;
        }
        Ok(())
    }

    // Where the rotation at `av` this flow wrote stands against what the device holds.
    async fn rotation_standing(&self, av: Version, steps: &TeamSteps) -> Result<Standing, SyncError> {
        let _serial = self.serialized().await;
        self.rotation_standing_locked(av, steps).await
    }

    // The certificate at `av` decides: this flow's own, named by its signature, is adopted; another that verifies is
    // another device's rotation that won, which this flow never runs as its own, a replace's included.
    async fn rotation_standing_locked(&self, av: Version, steps: &TeamSteps) -> Result<Standing, SyncError> {
        let mut txn = self.begin().await?;
        let applied = self.own_certificate(txn.as_mut(), av).await?;
        let candidates = self.rotation_candidates(txn.as_mut(), av).await?;
        let Some(applied) = applied else {
            return Ok(if candidates.is_some() {
                Standing::Unsent
            } else {
                Standing::Gone
            });
        };
        if steps.certificate != Some(applied.sig) {
            return Ok(if self.won_elsewhere(txn.as_mut(), &applied, steps).await? {
                Standing::Theirs
            } else {
                Standing::Held
            });
        }
        drop(txn);
        // Applied, its answer possibly lost and a pull since: adopted from what the server holds, once.
        let objects = self.applied_change_set(av).await?;
        let followed = {
            let mut txn = self.begin().await?;
            self.own_account(txn.as_mut()).await?.map(|own| own.av)
        };
        match followed {
            // Pins are pruned to this rotation's devices only while the account stands at its `av`: a device compared
            // after a later rotation keeps its pin.
            Some(at) if at == av => {
                let mut txn = self.begin().await?;
                let kept = self.certified_devices(txn.as_mut(), av).await?;
                prune_device_pins(txn.as_mut(), &kept).await?;
                self.end_superseded_flows(txn.as_mut(), av).await?;
                txn.commit().await?;
            }
            Some(at) if at > av => {}
            _ => self.rotation_adopted(av, &objects).await?,
        }
        Ok(Standing::Ours)
    }

    // Another device's rotation won `av` only if its certificate verifies: under the IK this flow began under, or
    // endorsed by it, or through the pin's chain. One under an IK nothing endorsed, which a server can make up, locks
    // the device and decides nothing until an approval makes its IK verify (0056, Pins; Erasing).
    async fn won_elsewhere(
        &self,
        txn: &mut dyn StateTxn,
        certificate: &AccountCertificate,
        steps: &TeamSteps,
    ) -> Result<bool, SyncError> {
        if let Some(ik) = &steps.ik
            && matches!(
                certificate.ik_change(self.origin(), ik),
                Ok(IkChange::Same | IkChange::Endorsed)
            )
        {
            return Ok(true);
        }
        if self.pin(txn, self.account()).await?.is_none() {
            return Ok(false);
        }
        match self.verify_certificate(txn, ScopeName::Personal, certificate).await {
            Ok(_) => Ok(true),
            Err(SyncError::Keys(_) | SyncError::NotAllowed { .. }) => Ok(false),
            Err(other) => Err(other),
        }
    }

    // The flow at `av` if another device's rotation won it, settled in `txn`: a pull that brings the winner runs this
    // before it follows it, so what this flow drew never outlives it.
    pub(crate) async fn settle_flow_if_lost(&self, txn: &mut dyn StateTxn, av: Version) -> Result<(), SyncError> {
        let Some(Row::KeyPending(row)) = txn
            .get(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
            .await?
        else {
            return Ok(());
        };
        let steps = TeamSteps::decode(&row.state)?;
        let Some(applied) = self.own_certificate(txn, av).await? else {
            return Ok(());
        };
        if steps.certificate == Some(applied.sig) || !self.won_elsewhere(txn, &applied, &steps).await? {
            return Ok(());
        }
        self.clean_up_lost(txn, av, &steps).await
    }

    // Another device's rotation holds `av`: every candidate this flow wrote at that `av`, its account keys there when
    // they are not the certificate's, the keys R opened for a recovery and the device keys it drew all go. The review's
    // choices go with the flow, since the rotation they were made for never applied.
    async fn drop_lost_rotation(&self, av: Version, steps: &TeamSteps) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        self.clean_up_lost(txn.as_mut(), av, steps).await?;
        txn.commit().await?;
        Ok(())
    }

    // The device store first and the row last, so a crash between them leaves the flow to settle again.
    async fn clean_up_lost(&self, txn: &mut dyn StateTxn, av: Version, steps: &TeamSteps) -> Result<(), SyncError> {
        let leftovers = self.candidates_at(txn, av).await?;
        let writer = leftovers
            .iter()
            .filter_map(KeyObject::wrap)
            .find(|wrap| wrap.target.purpose == WrapPurpose::Account)
            .map(|wrap| wrap.wrapper.key_device);
        let in_force = self.own_certificate(txn, av).await?;
        if let Some(keys) = self.account_keys(av).await?
            && in_force.is_none_or(|certificate| keys.check_against(&certificate.ask, &certificate.aek).is_err())
        {
            self.erase_account_keys(av).await?;
        }
        if let Some(opened) = steps.opened {
            self.erase_account_keys(opened).await?;
        }
        let held = self.device_keys().await?;
        if writer.is_some() && held.pending.as_ref().map(|pending| pending.key_device) == writer {
            self.store_device_keys(&HeldDeviceKeys {
                current: held.current,
                pending: None,
            })
            .await?;
        }
        self.drop_candidates(txn, ScopeName::Personal, &leftovers).await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
            .await?;
        Ok(())
    }

    // Neither applied nor a candidate any more: nothing of the flow can still apply, so the keys R opened for it go.
    async fn end_gone_flow(&self, av: Version, steps: &TeamSteps) -> Result<(), SyncError> {
        if let Some(opened) = steps.opened {
            self.erase_account_keys(opened).await?;
        }
        self.end_team_steps(PendingFlow::AccountRotation { av }).await
    }

    // Every candidate of an account change set to `av` this device wrote and the server never took, its rings with it.
    pub(crate) async fn candidates_at(&self, txn: &mut dyn StateTxn, av: Version) -> Result<Vec<KeyObject>, SyncError> {
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
                let ours = match held.object.id {
                    KeyRecordId::Ring(key) => objects.iter().any(|object| object.id == KeyRecordId::Version(key)),
                    _ => super::account_replace::of_rotation(&held.object, av),
                };
                if !held.applied && ours {
                    objects.push(held.object);
                }
            }
        }
        Ok(objects)
    }

    // The change set at `av` resent while its candidates have not applied, then, once this device holds the account
    // at `av`, each team of the account: this account's certificate copied in as `key.member`, and each team where it
    // holds the key rotated without the members the review marked, whether or not the server still lists them. A
    // rotation another device won at that `av` leaves nothing of this flow to do. A team the server does not take yet
    // waits for the next pass; one it refuses is recorded, tried again on the next pass, and holds no removal back
    // (0056, Removing a device).
    async fn team_steps(&self, av: Version) -> Result<(), SyncError> {
        let flow = PendingFlow::AccountRotation { av };
        let mut steps = {
            let mut txn = self.begin().await?;
            match txn.get(&RowKey::KeyPending(flow)).await? {
                Some(Row::KeyPending(row)) => TeamSteps::decode(&row.state)?,
                _ => return Ok(()),
            }
        };
        match self.rotation_standing(av, &steps).await? {
            Standing::Theirs => return self.drop_lost_rotation(av, &steps).await,
            Standing::Gone => return self.end_gone_flow(av, &steps).await,
            Standing::Held => return Ok(()),
            Standing::Unsent => {
                let resent = {
                    let _serial = self.serialized().await;
                    self.push_own_candidates(av).await?
                };
                if let Resent::Refused(code) = resent {
                    return Err(SyncError::Rejected { code });
                }
                if self.rotation_standing(av, &steps).await? != Standing::Ours {
                    return Ok(());
                }
            }
            Standing::Ours => {}
        }
        let Some((teams, held)) = self.account_teams().await? else {
            self.hooks().pass_soon();
            return Ok(());
        };
        let mut waiting = false;
        for team in teams {
            if steps.done.contains(&team) {
                continue;
            }
            match self.team_step(team, av, &steps, held.contains(&team)).await {
                Ok(Step::Done) => {
                    steps.retry.retain(|(retried, _)| *retried != team);
                    steps.stuck.retain(|stuck| *stuck != team);
                    steps.done.push(team);
                }
                Ok(Step::Wait) => waiting = true,
                Ok(Step::Retry(version)) => {
                    steps.retry.retain(|(retried, _)| *retried != team);
                    steps.retry.push((team, version));
                    waiting = true;
                }
                Err(SyncError::Transport(_)) => waiting = true,
                Err(
                    SyncError::Rejected { .. }
                    | SyncError::Keys(_)
                    | SyncError::NotAllowed { .. }
                    | SyncError::Locked { .. },
                ) => {
                    if !steps.stuck.contains(&team) {
                        steps.stuck.push(team);
                    }
                }
                Err(other) => return Err(other),
            }
            let _serial = self.serialized().await;
            let mut txn = self.begin().await?;
            txn.put(Row::KeyPending(KeyPendingRow {
                flow,
                state: steps.encode(),
            }))
            .await?;
            txn.commit().await?;
        }
        if waiting {
            self.hooks().pass_soon();
            return Ok(());
        }
        // A team the server refused stays recorded and goes up again on the next pass; the row holds no removal back.
        if !steps.stuck.is_empty() {
            return Ok(());
        }
        self.end_team_steps(flow).await
    }

    // The account's teams are those a scopes body read with this device approved lists, each judged once the engine's
    // pull of it caught up after such a body and its roster was read, with those where this account holds the key.
    // None until then: a device that just recovered, or that was approved, has read none yet (0051, `members`).
    async fn account_teams(&self) -> Result<Option<(Vec<TeamId>, Vec<TeamId>)>, SyncError> {
        let body = self.scopes_body().await?;
        let approved = body
            .scopes
            .iter()
            .any(|info| info.scope == ScopeName::Personal && info.approved == Some(true));
        let teams: Vec<TeamId> = body
            .scopes
            .iter()
            .filter_map(|info| match info.scope {
                ScopeName::Team(team) => Some(team),
                _ => None,
            })
            .collect();
        // A team's roster counts only in the epoch the device synced it in, and that is the body's; a team that
        // refills against a new epoch has none in force yet.
        let mut unread = false;
        let mut txn = self.begin().await?;
        for team in &teams {
            let roster = self.current_roster(txn.as_mut(), *team).await?;
            unread |= !roster.is_some_and(|roster| roster.epoch() == Some(body.epoch));
        }
        drop(txn);
        if !approved || unread {
            return Ok(None);
        }
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let held: Vec<TeamId> = self
            .held_teams(txn.as_mut())
            .await?
            .into_iter()
            .filter(|team| teams.contains(team))
            .collect();
        Ok(Some((teams, held)))
    }

    // One team's step. Two holders that rotate at once are serialized: the second meets `create_only`, pulls, and
    // rotates again only if a rotation is still due (0056, Version records).
    async fn team_step(&self, team: TeamId, av: Version, steps: &TeamSteps, holds: bool) -> Result<Step, SyncError> {
        match self.publish_member_certificate(team).await {
            // A team this account has left takes nothing more from it.
            Err(SyncError::Transport(TransportError::SeatRequired | TransportError::NotFound)) => {
                return Ok(Step::Done);
            }
            other => other?,
        }
        if !holds || self.team_rotated_since(team, av).await? {
            return Ok(Step::Done);
        }
        let keys = self.team_keys(team).await?;
        if let Some((_, met_at)) = steps.retry.iter().find(|(retried, _)| *retried == team) {
            if keys.version.is_none_or(|version| version <= *met_at) {
                return Ok(Step::Wait);
            }
            if !self
                .rotation_still_due(team, av, &keys, &steps.removals_for(team))
                .await?
            {
                return Ok(Step::Done);
            }
        }
        match self.rotate_team(team, steps.removals_for(team)).await {
            Err(SyncError::Rejected {
                code: RejectedCode::CreateOnly,
            }) => Ok(Step::Retry(keys.version.unwrap_or(Version::FIRST))),
            other => other.map(|()| Step::Done),
        }
    }

    // Due unless the version in force came after this account's rotation to `av`, wrapped to it at that `av` or later,
    // and no member the review marked holds it. The server's `rotation_due` alone decides nothing: a version wrapped
    // to the old account key is one the lost device can open.
    async fn rotation_still_due(
        &self,
        team: TeamId,
        av: Version,
        keys: &TeamKeys,
        marked: &[AccountId],
    ) -> Result<bool, SyncError> {
        let Some(version) = keys.version else {
            return Ok(false);
        };
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let account = Recipient::Account(self.account());
        let wrapped_since = self
            .applied_objects(txn.as_mut(), ScopeName::Team(team), KeyKind::Wrap)
            .await?
            .iter()
            .filter_map(KeyObject::wrap)
            .any(|wrap| {
                wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
                    && wrap.target.version == version
                    && wrap.target.recipient == account
                    && wrap.target.recipient_version >= av
            });
        if !wrapped_since {
            return Ok(true);
        }
        Ok(match self.team_holders_at(txn.as_mut(), team, version).await? {
            Some(holders) => marked.iter().any(|account| holders.contains(account)),
            None => !marked.is_empty(),
        })
    }

    // Right after the account rotation applied. A step the server does not take yet stays in `key_pending` for the
    // next pass; the account part is done either way.
    async fn team_steps_now(&self, av: Version) -> Result<(), SyncError> {
        match self.team_steps(av).await {
            Err(SyncError::Transport(_)) => {
                self.hooks().pass_soon();
                Ok(())
            }
            other => other,
        }
    }

    // An account change set of this device that has not settled: a rotation's candidates waiting at an `av` above the
    // one the device follows, or its reset's activation. It settles before any new rotation or approval starts; team
    // steps alone hold nothing back.
    pub(crate) async fn rotation_pending(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        if self.activation_waiting(txn).await? {
            return Ok(true);
        }
        let followed = self.pin(txn, self.account()).await?.map(|pin| pin.av);
        for av in rotation_flows(txn).await? {
            if followed.is_some_and(|at| av <= at) {
                continue;
            }
            if self.rotation_candidates(txn, av).await?.is_some() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    // What earlier rotations of this device that applied still owe their teams, which a new rotation takes on.
    async fn carried_steps(&self, txn: &mut dyn StateTxn) -> Result<TeamSteps, SyncError> {
        let mut carried = TeamSteps::default();
        for av in rotation_flows(txn).await? {
            let Some(Row::KeyPending(row)) = txn
                .get(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
                .await?
            else {
                continue;
            };
            let steps = TeamSteps::decode(&row.state)?;
            let applied = self.own_certificate(txn, av).await?;
            if applied.is_none_or(|certificate| steps.certificate != Some(certificate.sig)) {
                continue;
            }
            for (team, account) in steps.remove {
                if !steps.done.contains(&team) && !carried.remove.contains(&(team, account)) {
                    carried.remove.push((team, account));
                }
            }
        }
        Ok(carried)
    }

    // Once a rotation of this device applied at `av`, the flows of earlier ones end: it carried what they still owed.
    async fn end_superseded_flows(&self, txn: &mut dyn StateTxn, av: Version) -> Result<(), SyncError> {
        for earlier in rotation_flows(txn).await? {
            if earlier < av {
                txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av: earlier }))
                    .await?;
            }
        }
        Ok(())
    }

    async fn end_team_steps(&self, flow: PendingFlow) -> Result<(), SyncError> {
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

    // The account change set at `av` as the server served it: applied objects only, never a candidate it did not take.
    pub(crate) async fn applied_change_set(&self, av: Version) -> Result<Vec<KeyObject>, SyncError> {
        let mut txn = self.begin().await?;
        let mut objects = Vec::new();
        for kind in [KeyKind::Account, KeyKind::Recovery, KeyKind::Device, KeyKind::Version] {
            for object in self.applied_objects(txn.as_mut(), ScopeName::Personal, kind).await? {
                if in_change_set(&object, av) {
                    objects.push(object);
                }
            }
        }
        let versions: Vec<_> = objects
            .iter()
            .filter_map(KeyObject::version_record)
            .map(|record| record.key)
            .collect();
        for object in self
            .applied_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Ring)
            .await?
        {
            if let KeyRecordId::Ring(key) = object.id
                && versions.contains(&key)
            {
                objects.push(object);
            }
        }
        for object in self
            .applied_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Wrap)
            .await?
        {
            if in_change_set(&object, av) {
                objects.push(object);
            }
        }
        Ok(objects)
    }

    // This device's own candidates of a rotation to `av` that was never answered, sent again as they are. Run with the
    // serial lock held.
    async fn push_own_candidates(&self, av: Version) -> Result<Resent, SyncError> {
        let objects = {
            let mut txn = self.begin().await?;
            match self.rotation_candidates(txn.as_mut(), av).await? {
                Some(objects) => objects,
                None => return Ok(Resent::Nothing),
            }
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
        match pushed(&outcomes)? {
            Pushed::Applied => {
                self.rotation_adopted(av, &objects).await?;
                Ok(Resent::Applied)
            }
            Pushed::Refused(code) => {
                let recovering = held.pending.is_some_and(|pending| pending.key_device == wrapper);
                let opened = {
                    let mut txn = self.begin().await?;
                    match txn
                        .get(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
                        .await?
                    {
                        Some(Row::KeyPending(row)) => TeamSteps::decode(&row.state)?.opened,
                        _ => None,
                    }
                };
                self.rotation_refused(av, &objects, recovering, opened).await?;
                Ok(Resent::Refused(code))
            }
        }
    }
}

// What sending a rotation's unanswered candidates again came to.
enum Resent {
    Nothing,
    Applied,
    Refused(RejectedCode),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Standing {
    // Its candidates have not applied and go up again.
    Unsent,
    // Neither applied nor a candidate any more: nothing of it can still apply.
    Gone,
    // Applied and adopted.
    Ours,
    // Another device's rotation holds that `av`.
    Theirs,
    // A certificate nothing verifies holds that `av`: the device is locked, and the flow waits with its keys.
    Held,
}

// Where one team's step stands after this pass.
enum Step {
    Done,
    // Met `create_only` while this device held the version named: waits for a pull past it.
    Retry(Version),
    // A pull has not moved past the version a `create_only` was met at.
    Wait,
}

// The `av`s this device's account rotation flows wait at, lowest first.
async fn rotation_flows(txn: &mut dyn StateTxn) -> Result<Vec<Version>, SyncError> {
    let mut avs: Vec<Version> = txn
        .scan(&RowRange::Table(Table::KeyPending))
        .await?
        .iter()
        .filter_map(|row| match row {
            Row::KeyPending(KeyPendingRow {
                flow: PendingFlow::AccountRotation { av },
                ..
            }) => Some(*av),
            _ => None,
        })
        .collect();
    avs.sort_unstable();
    Ok(avs)
}

// Own-device pins only of the devices a rotation kept.
async fn prune_device_pins(txn: &mut dyn StateTxn, kept: &[KeyDeviceId]) -> Result<(), SyncError> {
    for row in txn.scan(&RowRange::Table(Table::KeyDevicePins)).await? {
        if let Row::KeyDevicePin(pin) = row
            && !kept.contains(&pin.key_device)
        {
            txn.delete(&RowKey::KeyDevicePin(pin.key_device)).await?;
        }
    }
    Ok(())
}

// A replace's flow in `key_pending` as it starts: no team step done, and its certificate named.
pub(crate) fn flow_state(objects: &[KeyObject]) -> Vec<u8> {
    TeamSteps {
        certificate: certificate_signature(objects),
        ..TeamSteps::default()
    }
    .encode()
}

// The signature of the account certificate an account change set carries.
fn certificate_signature(objects: &[KeyObject]) -> Option<Signature> {
    objects.iter().find_map(|object| match &object.body {
        KeyBody::Account(body) => Some(body.sig),
        _ => None,
    })
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
