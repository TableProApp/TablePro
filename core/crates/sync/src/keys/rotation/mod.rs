// `DeviceFlows` (0056, Account flows: Rotation, Removing a device, Recovery). Nothing rotates until R is typed; the
// rotation keeps only this device and the own-device pins the person ticked; each team is then rotated without the
// members the review marked, and the choices stay in `key_pending` until every team rotation is written.

mod plan;
mod recovery;
mod review;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, TeamId, Version, WrapPurpose};
use tablepro_keys::keys::{DeviceKeys, Signature};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;

use self::plan::{Rotation, check_recovery_key, kept_devices};
use self::review::TeamSteps;
use super::approval::{Pushed, pushed};
use super::{HeldDeviceKeys, KeyService, create_change};
use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, ScopeName};
use crate::api::key_flows::{
    AccountDevice, DeviceFlows, DraftId, KeyNoticeKind, RemovalReview, ReviewedDevice, ReviewedMember, TeamFlows,
};
use crate::api::state::{KeyPendingRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
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
        let steps = TeamSteps {
            remove: remove.iter().map(|member| (member.team, member.account)).collect(),
            ..TeamSteps::default()
        };
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
        // An earlier rotation still settling its team steps finishes before another starts.
        if self.rotation_pending(txn.as_mut()).await? {
            self.hooks().pass_soon();
            return Err(SyncError::NotAllowed {
                what: "remove a device while an earlier rotation settles",
            });
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
        self.rotate_account(&rotation, &steps, None).await
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
        if let Some(steps) = earlier
            && self.rotation_standing_locked(av, &steps).await? == Standing::Ours
        {
            return Ok(av);
        }
        let mut txn = self.begin().await?;
        if self.rotation_pending(txn.as_mut()).await? {
            self.hooks().pass_soon();
            return Err(SyncError::NotAllowed {
                what: "recover while an earlier rotation settles",
            });
        }
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
        let held_before = self.account_keys(recovered.certificate.av).await?.is_some();
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
        let av = match self.rotate_account(&rotation, &TeamSteps::default(), Some(held)).await {
            Ok(av) => av,
            Err(error) => {
                // A refused recovery leaves no copy of the account keys R opened.
                if matches!(error, SyncError::Rejected { .. }) && !held_before {
                    self.erase_account_keys(recovered.certificate.av).await?;
                }
                return Err(error);
            }
        };
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
    // set to `key_objects` as candidates before the push, so a retry resends the same objects. The pending flow names
    // the certificate, so a resume tells this rotation from another device's at the same `av`.
    async fn rotate_account(
        &self,
        rotation: &Rotation<'_>,
        steps: &TeamSteps,
        recovering: Option<HeldDeviceKeys>,
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
                self.rotation_refused(built.av, &built.objects, recovering.is_some())
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
        let kept = kept_of(objects, av);
        let mut txn = self.begin().await?;
        let stopped = self.stopped_personal(txn.as_mut()).await?;
        // A pull may have followed the certificate already; then only the objects are held as applied.
        let followed = self
            .pin(txn.as_mut(), self.account())
            .await?
            .is_some_and(|pin| pin.av >= av && !pin.alert);
        if followed {
            for object in objects {
                self.hold_object(txn.as_mut(), ScopeName::Personal, object, true)
                    .await?;
            }
        } else {
            self.adopt_account_change_set(txn.as_mut(), objects).await?;
        }
        prune_device_pins(txn.as_mut(), &kept).await?;
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

    async fn rotation_refused(&self, av: Version, objects: &[KeyObject], recovering: bool) -> Result<(), SyncError> {
        self.erase_account_keys(av).await?;
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

    // Only a certificate this flow names as its own is adopted here; a flow that names none, as Replace's, leaves its
    // rotation to the flow that wrote it.
    async fn rotation_standing_locked(&self, av: Version, steps: &TeamSteps) -> Result<Standing, SyncError> {
        let mut txn = self.begin().await?;
        let id = KeyRecordId::Account {
            account: self.account(),
            av,
        };
        let applied = self
            .applied_object(txn.as_mut(), ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?;
        let candidates = self.rotation_candidates(txn.as_mut(), av).await?;
        let Some(applied) = applied else {
            return Ok(match (candidates.is_some(), steps.certificate.is_some()) {
                (true, _) => Standing::Unsent,
                (false, true) => Standing::Gone,
                (false, false) => Standing::Waiting,
            });
        };
        let ours = certificate_signature(std::slice::from_ref(&applied));
        match steps.certificate {
            Some(signature) if ours != Some(signature) => return Ok(Standing::Theirs),
            Some(_) => {}
            None => {
                let own = self.own_account(txn.as_mut()).await?;
                return Ok(if own.is_some_and(|own| own.av >= av) {
                    Standing::Ours
                } else {
                    Standing::Waiting
                });
            }
        }
        drop(txn);
        // Applied, its answer possibly lost and a pull since: adopted from what the server holds, once.
        let objects = self.applied_change_set(av).await?;
        let adopted = {
            let mut txn = self.begin().await?;
            let own = self.own_account(txn.as_mut()).await?;
            own.is_some_and(|own| own.av >= av)
        };
        if adopted {
            let kept = kept_of(&objects, av);
            let mut txn = self.begin().await?;
            prune_device_pins(txn.as_mut(), &kept).await?;
            txn.commit().await?;
        } else {
            self.rotation_adopted(av, &objects).await?;
        }
        Ok(Standing::Ours)
    }

    // Another device's rotation holds `av`: this flow's candidates, its account keys at `av` when they are not the
    // certificate's, and the device keys a recovery drew for it go. Its review's choices go with it, since the
    // rotation they were made for never applied.
    async fn drop_lost_rotation(&self, av: Version) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let leftovers = self.rotation_candidates(txn.as_mut(), av).await?.unwrap_or_default();
        let writer = leftovers
            .iter()
            .filter_map(KeyObject::wrap)
            .find(|wrap| wrap.target.purpose == WrapPurpose::Account)
            .map(|wrap| wrap.wrapper.key_device);
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, &leftovers)
            .await?;
        let in_force = self.own_certificate(txn.as_mut(), av).await?;
        txn.delete(&RowKey::KeyPending(PendingFlow::AccountRotation { av }))
            .await?;
        txn.commit().await?;
        if let (Some(keys), Some(certificate)) = (self.account_keys(av).await?, in_force)
            && keys.check_against(&certificate.ask, &certificate.aek).is_err()
        {
            self.erase_account_keys(av).await?;
        }
        let held = self.device_keys().await?;
        if writer.is_some() && held.pending.as_ref().map(|pending| pending.key_device) == writer {
            self.store_device_keys(&HeldDeviceKeys {
                current: held.current,
                pending: None,
            })
            .await?;
        }
        Ok(())
    }

    // The change set at `av` resent while its candidates have not applied, then, once this device holds the account
    // at `av`, each team of the account: this account's certificate copied in as `key.member`, and each team where it
    // holds the key rotated without the members the review marked, whether or not the server still lists them. A
    // rotation another device won at that `av` leaves nothing of this flow to do.
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
            Standing::Waiting => return Ok(()),
            Standing::Theirs => return self.drop_lost_rotation(av).await,
            Standing::Gone => return self.end_team_steps(flow).await,
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
        // The account's teams are those a scopes body read with this device approved lists, each judged once the
        // engine's pull of it caught up after such a body and its roster was read. A device that just recovered, or
        // that was approved, has read none yet, so the steps wait for the engine's next pass (0051, `members`).
        let (teams, held) = {
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
            let unread = teams
                .iter()
                .any(|team| !self.rosters().get(*team).is_some_and(|roster| roster.caught_up()));
            if !approved || unread {
                self.hooks().pass_soon();
                return Ok(());
            }
            let _serial = self.serialized().await;
            let mut txn = self.begin().await?;
            let held: Vec<TeamId> = self
                .held_teams(txn.as_mut())
                .await?
                .into_iter()
                .filter(|team| teams.contains(team))
                .collect();
            (teams, held)
        };
        for team in teams {
            if steps.done.contains(&team) {
                continue;
            }
            match self.publish_member_certificate(team).await {
                // A team this account has left takes nothing more from it.
                Err(SyncError::Transport(TransportError::SeatRequired | TransportError::NotFound)) => {}
                other => {
                    other?;
                    if held.contains(&team) && !self.team_rotated_since(team, av).await? {
                        match self.rotate_team(team, steps.removals_for(team)).await {
                            // Already written, by this flow before a crash or a lost answer, or by another holder
                            // first: the rotation is met, as a holder that meets `create_only` takes it.
                            Err(SyncError::Rejected {
                                code: RejectedCode::CreateOnly,
                            }) => {}
                            other => other?,
                        }
                    }
                }
            }
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
        self.end_team_steps(flow).await
    }

    // Right after the account rotation applied. A team step the server does not take yet, as before it approves the
    // rotated key device, stays in `key_pending` for the next pass; the account part is done either way.
    async fn team_steps_now(&self, av: Version) -> Result<(), SyncError> {
        match self.team_steps(av).await {
            Err(SyncError::Transport(_)) => {
                self.hooks().pass_soon();
                Ok(())
            }
            other => other,
        }
    }

    // A pending account rotation of this device, which settles before any new rotation or approval starts.
    pub(crate) async fn rotation_pending(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        Ok(txn
            .scan(&RowRange::Table(Table::KeyPending))
            .await?
            .iter()
            .any(|row| matches!(row, Row::KeyPending(row) if matches!(row.flow, PendingFlow::AccountRotation { .. }))))
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
                self.rotation_refused(av, &objects, recovering).await?;
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
    // Left to the flow that wrote it, which names no certificate of its own here.
    Waiting,
    // Neither applied nor a candidate any more: nothing of it can still apply.
    Gone,
    // Applied and adopted.
    Ours,
    // Another device's rotation holds that `av`.
    Theirs,
}

fn kept_of(objects: &[KeyObject], av: Version) -> Vec<KeyDeviceId> {
    objects
        .iter()
        .filter_map(|object| match object.id {
            KeyRecordId::Device { key_device, av: at, .. } if at == av => Some(key_device),
            _ => None,
        })
        .collect()
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
