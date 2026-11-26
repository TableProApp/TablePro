// `ResetFlows` (0056, Account flows, Reset): when R is lost, a proposal the honest server holds 7 days in view of
// every device, which any device certified at the current `av` or R cancels, and which only the proposing device
// activates once the wait passed. Activation removes every other device row and marks `rotation_due` on the teams.

mod objects;
mod record;
mod steps;

use std::sync::Arc;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::sign_cancel;
use tablepro_keys::encoding::{KeyPurpose, ResetId, random_uuid};
use tablepro_keys::keys::{AccountKeys, DeviceKeys};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;

use self::record::{HOLD_US, ResetRecord};
use self::steps::proposal_digest;
use super::account_genesis::ShownKey;
use super::approval::{Pushed, pushed};
use super::{HeldDeviceKeys, KeyService, ResetKeys, create_change};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{
    CancelWith, DraftId, KeyApplied, KeyArrival, KeyNoticeKind, PendingReset, RecoveryKeyDraft, ResetFlows, ResetKind,
    ResetState, TeamFlows, TypedBack,
};
use crate::api::state::{Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::{DpopKey, RejectedCode};

// R' as shown, with the two of its 14 groups the person types back before anything is pushed.
struct ResetDraft {
    kind: ResetKind,
    shown: ShownKey,
}

fn rejected(code: RejectedCode) -> SyncError {
    SyncError::Rejected { code }
}

#[async_trait]
impl ResetFlows for KeyService {
    async fn pending_reset(&self) -> Result<Option<PendingReset>, SyncError> {
        let _serial = self.serialized().await;
        let mut views: Vec<PendingReset> = self.settled_resets().await?.iter().map(ResetRecord::view).collect();
        let mut txn = self.begin().await?;
        views.extend(self.others_resets(txn.as_mut()).await?);
        Ok(views.into_iter().max_by_key(|view| view.taken_at_us))
    }

    async fn begin_reset(&self, kind: ResetKind) -> Result<RecoveryKeyDraft, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        self.reset_may_start(kind).await?;
        let draft = self.drafts().put(ResetDraft {
            kind,
            shown: ShownKey::new()?,
        })?;
        self.drafts()
            .with(draft, |held: &mut ResetDraft| held.shown.draft(draft))?
    }

    async fn finish_reset_proposal(&self, draft: DraftId, typed: TypedBack) -> Result<PendingReset, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let (kind, recovery, typed_back) = self.drafts().with(draft, |held: &mut ResetDraft| {
            (held.kind, held.shown.key.clone(), held.shown.check_typed_back(&typed))
        })?;
        typed_back?;
        let av = self.reset_may_start(kind).await?.next()?;
        let reset = ResetId(random_uuid()?);
        let keys = ResetKeys {
            account: AccountKeys::generate()?,
            device: DeviceKeys::generate()?,
        };
        let body = self.proposal_body(av, kind, &recovery, &keys.account, &keys.device)?;
        drop(recovery);
        let now = self.now_us();
        let object = KeyObject {
            id: KeyRecordId::Reset {
                account: self.account(),
                reset,
            },
            body: KeyBody::Reset(Box::new(body.clone())),
        };
        let mut record = ResetRecord {
            reset,
            sent: false,
            kind,
            av,
            ik: body.account.ik,
            key_device: body.key_device,
            state: ResetState::Pending,
            taken_at_us: now,
            held_until_us: now + HOLD_US,
            proposed_by: Some(self.device_row().clone()),
            published: Vec::new(),
            proposal: proposal_digest(&object),
            epoch: None,
        };
        self.store_reset_keys(reset, &keys).await?;
        match self.send_proposal(&mut record, &object, &keys.device).await {
            Ok(()) => {}
            // Not answered: the server may hold it, and at most one reset is pending, so the keys, the candidate and
            // the row stay and `resume_reset` sends the same proposal again.
            Err(SyncError::Transport(error)) if crate::keys::approval::transient(&error) => self.hooks().pass_soon(),
            Err(error) => {
                self.erase_reset_keys(reset).await?;
                let mut txn = self.begin().await?;
                self.drop_candidates(txn.as_mut(), ScopeName::Personal, std::slice::from_ref(&object))
                    .await?;
                txn.delete(&RowKey::KeyPending(record.to_row().flow)).await?;
                txn.commit().await?;
                return Err(error);
            }
        }
        self.drafts().remove(draft);
        self.raise_notice(KeyNoticeKind::ResetPending { reset })?;
        Ok(record.view())
    }

    async fn cancel_reset(&self, reset: ResetId, with: CancelWith) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let own = self
            .settled_resets()
            .await?
            .into_iter()
            .find(|record| record.reset == reset && record.pending());
        let mut txn = self.begin().await?;
        let (av, proposed_ik) = match &own {
            Some(record) => (record.av, record.ik),
            None => self.others_pending(txn.as_mut(), reset).await?,
        };
        let account = self.own_account(txn.as_mut()).await?;
        let (sig, proof) = match &with {
            CancelWith::ThisDevice => {
                if account.is_none() {
                    return Err(SyncError::NotAllowed { what: "cancel a reset" });
                }
                (None, self.dpop_key().await?)
            }
            CancelWith::RecoveryKey(text) => {
                let recovery = RecoveryKey::parse(text.expose_secret())?;
                let ik = recovery.identity_seed(self.origin(), self.account())?;
                let current = match &account {
                    Some(account) => account.ik,
                    None => self.newest_own_certificate(txn.as_mut()).await?.ik,
                };
                if ik.public()? != current {
                    return Err(tablepro_keys::KeysError::Signature.into());
                }
                let sig = sign_cancel(self.origin(), self.account(), av, &proposed_ik, &ik)?;
                (Some(sig), self.any_device_proof().await?)
            }
        };
        drop(txn);
        let object = KeyObject {
            id: KeyRecordId::Cancel {
                account: self.account(),
                reset,
            },
            body: KeyBody::Cancel { sig },
        };
        match self.push_one(&object, proof).await? {
            Pushed::Applied => {
                let mut txn = self.begin().await?;
                if let Some(mut record) = own {
                    self.end_reset(txn.as_mut(), &mut record, ResetState::Cancelled).await?;
                    self.put_reset(txn.as_mut(), &record).await?;
                } else {
                    self.others_ended(txn.as_mut(), reset, ResetState::Cancelled).await?;
                }
                txn.commit().await?;
                Ok(())
            }
            Pushed::Refused(code) => Err(rejected(code)),
        }
    }

    async fn activate_reset(&self, reset: ResetId) -> Result<(), SyncError> {
        let mut record = {
            let _serial = self.serialized().await;
            self.finish_cut_off_sign_out().await?;
            self.activate(reset).await?
        };
        self.publish_after_reset(&mut record).await
    }

    async fn apply_reset_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _serial = self.serialized().await;
        self.apply_resets(arrival).await
    }

    async fn resume_reset(&self, reset: ResetId) -> Result<(), SyncError> {
        let mut record = {
            let _serial = self.serialized().await;
            let Some(mut record) = self
                .settled_resets()
                .await?
                .into_iter()
                .find(|record| record.reset == reset)
            else {
                return Ok(());
            };
            match record.state {
                ResetState::Pending if !record.sent => {
                    self.resend_proposal(&mut record).await?;
                    return Ok(());
                }
                ResetState::Pending
                    if self.own_activation_applied(&record).await?
                        || self.activation_candidates(reset).await?.is_some() =>
                {
                    self.activate(reset).await?
                }
                // A restore since the server took the proposal may have lost it: a pending `key.reset` is not pushed
                // back, so the device proposes it again under its checks, and the 7 days start again (0064).
                ResetState::Pending => {
                    if self.restored_since(&record).await? {
                        self.resend_proposal(&mut record).await?;
                    }
                    return Ok(());
                }
                ResetState::Active => {
                    self.finish_activation(&record).await?;
                    record
                }
                ResetState::Cancelled | ResetState::Superseded => return Ok(()),
            }
        };
        self.publish_after_reset(&mut record).await
    }
}

impl KeyService {
    // Kind 2 from an approved device, kind 3 from a device that is not; at most one reset pending per account. The
    // server checks the same and asks a kind 3 proposal for its step-up. Returns the account's current `av`.
    async fn reset_may_start(&self, kind: ResetKind) -> Result<tablepro_keys::encoding::Version, SyncError> {
        // A file with no anchor, or one still rebuilding, writes no secret and trusts no certificate it holds.
        if self.is_unanchored() || self.is_rebuilding() {
            return Err(SyncError::NotAllowed {
                what: "propose a reset before the key tables are verified",
            });
        }
        let records = self.settled_resets().await?;
        let mut txn = self.begin().await?;
        let others = self.others_resets(txn.as_mut()).await?;
        if records.iter().any(ResetRecord::pending) || others.iter().any(|view| view.state == ResetState::Pending) {
            return Err(rejected(RejectedCode::BadStatement));
        }
        let own = self.own_account(txn.as_mut()).await?;
        match (kind, own) {
            (ResetKind::KeepScopeKeys, Some(own)) => Ok(own.av),
            (ResetKind::StartEmpty, None) => Ok(self.newest_own_certificate(txn.as_mut()).await?.av),
            _ => Err(rejected(RejectedCode::BadStatement)),
        }
    }

    // A cancel signed by IK is carried by any device of the account; the signature authorizes it.
    async fn any_device_proof(&self) -> Result<DpopKey, SyncError> {
        let held = self.device_keys().await?;
        [held.current, held.pending]
            .into_iter()
            .flatten()
            .next()
            .map(|keys| DpopKey(Arc::new(keys.dsk.clone())))
            .ok_or(SyncError::NotAllowed {
                what: "cancel a reset without device keys",
            })
    }

    async fn push_one(&self, object: &KeyObject, proof: DpopKey) -> Result<Pushed, SyncError> {
        let outcomes = self
            .push_change_set(ScopeName::Personal, vec![create_change(object)?], proof)
            .await?;
        let answer = pushed(&outcomes)?;
        let mut txn = self.begin().await?;
        if answer == Pushed::Applied {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, true)
                .await?;
        }
        txn.commit().await?;
        Ok(answer)
    }

    // The `key.reset` alone, proved by the DSK it names (0051, Whose key the proof carries).
    async fn send_proposal(
        &self,
        record: &mut ResetRecord,
        object: &KeyObject,
        device: &DeviceKeys,
    ) -> Result<(), SyncError> {
        {
            let mut txn = self.begin().await?;
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
            self.put_reset(txn.as_mut(), record).await?;
            txn.commit().await?;
        }
        match self.push_one(object, DpopKey(Arc::new(device.dsk.clone()))).await? {
            Pushed::Applied => {
                record.sent = true;
                let mut txn = self.begin().await?;
                record.epoch = personal_epoch(txn.as_mut()).await?;
                self.put_reset(txn.as_mut(), record).await?;
                txn.commit().await?;
                Ok(())
            }
            Pushed::Refused(code) => Err(rejected(code)),
        }
    }

    // This device's own activation applied, adopted never before `held_until`.
    pub(super) async fn own_activation_applied(&self, record: &ResetRecord) -> Result<bool, SyncError> {
        Ok(self.now_us() >= record.held_until_us && self.activation_present(record).await?)
    }

    // The activation's records are in force: the certificate at the reset's `av` is its proposal's under the IK it
    // proposed, the device certificate there names its reset device keys, and the personal and history versions there
    // are signed under the reset's ASK, which only this device holds. The proposal's own records are public, so they
    // alone never decide it. Whatever the clock says, a reset whose activation is present is never ended.
    pub(super) async fn activation_present(&self, record: &ResetRecord) -> Result<bool, SyncError> {
        let Some(keys) = self.reset_keys(record.reset).await? else {
            return Ok(false);
        };
        let public = keys.account.public()?;
        let account = self.account();
        let mut txn = self.begin().await?;
        let Some(certificate) = self.own_certificate(txn.as_mut(), record.av).await? else {
            return Ok(false);
        };
        if certificate.verify(self.origin()).is_err()
            || certificate.ik != record.ik
            || certificate.ask != public.ask
            || certificate.aek != public.aek
        {
            return Ok(false);
        }
        let device = KeyRecordId::Device {
            account,
            key_device: keys.device.key_device,
            av: record.av,
        };
        let certified = match self
            .applied_object(txn.as_mut(), ScopeName::Personal, KeyKind::Device, &device.to_wire())
            .await?
            .map(|object| object.body)
        {
            Some(KeyBody::Device(body)) => {
                let device_certificate = body.certificate(account, keys.device.key_device, record.av);
                device_certificate.verify(self.origin(), &public.ask).is_ok()
                    && device_certificate.dek == keys.device.dek.public()?
                    && device_certificate.dsk == keys.device.dsk.public()?
            }
            _ => false,
        };
        if !certified {
            return Ok(false);
        }
        let versions = self
            .applied_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Version)
            .await?;
        Ok([KeyPurpose::Personal, KeyPurpose::History].iter().all(|purpose| {
            versions.iter().filter_map(KeyObject::version_record).any(|version| {
                version.key.purpose == *purpose
                    && version.key.owner == account.0
                    && version.signer == account
                    && version.signer_av == record.av
                    && version.verify(self.origin(), &public.ask).is_ok()
            })
        }))
    }

    // The activation applied and the device learned of it by pull: it adopts the keys it proposed, which wins over
    // the lock the new IK raised meanwhile.
    pub(super) async fn adopt_own_activation(&self, reset: ResetId) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        let Some(mut record) = self.reset_record(txn.as_mut(), reset).await? else {
            return Ok(());
        };
        drop(txn);
        if self.reset_keys(reset).await?.is_none() {
            return Ok(());
        }
        let objects = self.applied_change_set(record.av).await?;
        self.activation_applied(&mut record, &objects).await
    }

    // The activation candidates this device already built for `reset`, so a retry resends them as they are.
    async fn activation_candidates(&self, reset: ResetId) -> Result<Option<Vec<KeyObject>>, SyncError> {
        let mut txn = self.begin().await?;
        let Some(record) = self.reset_record(txn.as_mut(), reset).await? else {
            return Ok(None);
        };
        self.activation_candidates_of(txn.as_mut(), &record).await
    }

    async fn activate(&self, reset: ResetId) -> Result<ResetRecord, SyncError> {
        let Some(mut record) = self
            .settled_resets()
            .await?
            .into_iter()
            .find(|record| record.reset == reset)
        else {
            let mut txn = self.begin().await?;
            let others = self.others_resets(txn.as_mut()).await?;
            return Err(rejected(if others.iter().any(|view| view.reset == reset) {
                RejectedCode::WriterBound
            } else {
                RejectedCode::BadStatement
            }));
        };
        if !record.pending() {
            return Err(rejected(RejectedCode::BadStatement));
        }
        let keys = self.reset_keys(reset).await?.ok_or(SyncError::Unknown {
            what: "the reset's keys",
        })?;
        if self.own_activation_applied(&record).await? {
            let objects = self.applied_change_set(record.av).await?;
            self.activation_applied(&mut record, &objects).await?;
            return Ok(record);
        }
        // The wait as the server's own times give it; the server checks the same and answers `reset_held`.
        if self.now_us() < record.held_until_us {
            return Err(rejected(RejectedCode::ResetHeld));
        }
        let objects = match self.activation_candidates(reset).await? {
            Some(objects) => objects,
            None => {
                // A rotation of this device waiting at the same `av` settles first; the two never share candidates.
                let mut txn = self.begin().await?;
                if self.rotation_candidates(txn.as_mut(), record.av).await?.is_some() {
                    return Err(SyncError::NotAllowed {
                        what: "activate a reset while a rotation of this device settles",
                    });
                }
                drop(txn);
                self.build_activation(&record, &keys).await?
            }
        };
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let proof = DpopKey(Arc::new(keys.device.dsk.clone()));
        // Not answered, the candidates stay as built and go up again unchanged.
        let outcomes = self.push_change_set(ScopeName::Personal, changes, proof).await?;
        match pushed(&outcomes)? {
            Pushed::Applied => {
                self.activation_applied(&mut record, &objects).await?;
                Ok(record)
            }
            // Too early: the candidates stay as built, so the activation goes up again unchanged.
            Pushed::Refused(RejectedCode::ResetHeld) => Err(rejected(RejectedCode::ResetHeld)),
            Pushed::Refused(code) => {
                let mut txn = self.begin().await?;
                self.drop_candidates(txn.as_mut(), ScopeName::Personal, &objects)
                    .await?;
                txn.commit().await?;
                Err(rejected(code))
            }
        }
    }

    async fn build_activation(&self, record: &ResetRecord, keys: &ResetKeys) -> Result<Vec<KeyObject>, SyncError> {
        let mut txn = self.begin().await?;
        let id = KeyRecordId::Reset {
            account: self.account(),
            reset: record.reset,
        };
        let held = self
            .held_object(txn.as_mut(), ScopeName::Personal, KeyKind::Reset, &id.to_wire())
            .await?
            .ok_or(SyncError::Unknown {
                what: "the reset proposal",
            })?;
        if proposal_digest(&held.object) != record.proposal {
            return Err(tablepro_keys::KeysError::Conflict.into());
        }
        let KeyBody::Reset(body) = held.object.body else {
            return Err(SyncError::Malformed { what: "reset proposal" });
        };
        let objects = self
            .activation_objects(txn.as_mut(), record, &body, &keys.account)
            .await?;
        for object in &objects {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
        }
        txn.commit().await?;
        Ok(objects)
    }

    // Only the proposing device is approved now: its keys are the ones in force, every own-device pin goes with the
    // other rows, and its certificate is copied into each team as `key.member`. The change set is checked and
    // committed before the device keys switch; a resume after a crash between the two makes the switch.
    async fn activation_applied(&self, record: &mut ResetRecord, objects: &[KeyObject]) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        self.adopt_account_change_set(txn.as_mut(), objects).await?;
        for row in txn.scan(&RowRange::Table(Table::KeyDevicePins)).await? {
            if let Row::KeyDevicePin(pin) = row {
                txn.delete(&RowKey::KeyDevicePin(pin.key_device)).await?;
            }
        }
        let mut active = record.clone();
        active.state = ResetState::Active;
        self.put_reset(txn.as_mut(), &active).await?;
        txn.commit().await?;
        let ended = record.pending();
        *record = active;
        if ended {
            self.raise_notice(KeyNoticeKind::ResetEnded {
                reset: record.reset,
                state: ResetState::Active,
            })?;
        }
        self.finish_activation(record).await?;
        self.hooks().pass_soon();
        Ok(())
    }

    // The reset's keys in force once its activation committed, and their waiting copy gone.
    async fn finish_activation(&self, record: &ResetRecord) -> Result<(), SyncError> {
        let Some(keys) = self.reset_keys(record.reset).await? else {
            return Ok(());
        };
        self.store_account_keys(record.av, &keys.account).await?;
        self.store_device_keys(&HeldDeviceKeys {
            current: Some(keys.device.clone()),
            pending: None,
        })
        .await?;
        self.erase_reset_keys(record.reset).await?;
        self.withdraw_lock_notices();
        Ok(())
    }

    // The scope's epoch moved since the server took the proposal: a restore that may have lost it.
    async fn restored_since(&self, record: &ResetRecord) -> Result<bool, SyncError> {
        let mut txn = self.begin().await?;
        let current = personal_epoch(txn.as_mut()).await?;
        Ok(record.sent && current.is_some() && record.epoch != current)
    }

    // Another device's pending reset as `key_objects` holds it: its `av` and proposed IK, which a cancel names.
    async fn others_pending(
        &self,
        txn: &mut dyn StateTxn,
        reset: ResetId,
    ) -> Result<(tablepro_keys::encoding::Version, tablepro_keys::keys::Ed25519Public), SyncError> {
        let pending = self
            .others_resets(txn)
            .await?
            .iter()
            .any(|view| view.reset == reset && view.state == ResetState::Pending);
        let id = KeyRecordId::Reset {
            account: self.account(),
            reset,
        };
        match self
            .applied_object(txn, ScopeName::Personal, KeyKind::Reset, &id.to_wire())
            .await?
            .map(|object| object.body)
        {
            Some(KeyBody::Reset(body)) if pending => Ok((body.av, body.account.ik)),
            _ => Err(rejected(RejectedCode::BadStatement)),
        }
    }

    async fn resend_proposal(&self, record: &mut ResetRecord) -> Result<(), SyncError> {
        let keys = self.reset_keys(record.reset).await?.ok_or(SyncError::Unknown {
            what: "the reset's keys",
        })?;
        let id = KeyRecordId::Reset {
            account: self.account(),
            reset: record.reset,
        };
        let held = {
            let mut txn = self.begin().await?;
            self.held_object(txn.as_mut(), ScopeName::Personal, KeyKind::Reset, &id.to_wire())
                .await?
                .ok_or(SyncError::Unknown {
                    what: "the reset proposal",
                })?
        };
        if proposal_digest(&held.object) != record.proposal {
            return Err(tablepro_keys::KeysError::Conflict.into());
        }
        match self.send_proposal(record, &held.object, &keys.device).await {
            // Refused, so it is not pending on the server: no copy of it stays to read as another device's.
            Err(SyncError::Rejected { code }) => {
                self.erase_reset_keys(record.reset).await?;
                let mut txn = self.begin().await?;
                txn.delete(&RowKey::KeyObject(
                    ScopeName::Personal,
                    crate::api::ids::KindName::parse(KeyKind::Reset.name())?,
                    id.to_wire(),
                ))
                .await?;
                txn.delete(&RowKey::KeyPending(record.to_row().flow)).await?;
                txn.commit().await?;
                Err(rejected(code))
            }
            other => other,
        }
    }

    // After a reset another holder rotates each team and the person waits for re-confirmation, so this device only
    // copies its new certificate in. The team flow takes the serial lock itself, so it is not held around the call.
    async fn publish_after_reset(&self, record: &mut ResetRecord) -> Result<(), SyncError> {
        let teams = {
            let _serial = self.serialized().await;
            let mut txn = self.begin().await?;
            self.team_scopes(txn.as_mut()).await?
        };
        for team in teams {
            if record.published.contains(&team) {
                continue;
            }
            self.publish_member_certificate(team).await?;
            record.published.push(team);
            let _serial = self.serialized().await;
            let mut txn = self.begin().await?;
            self.put_reset(txn.as_mut(), record).await?;
            txn.commit().await?;
        }
        Ok(())
    }
}

// The personal scope's epoch as the engine last read it.
async fn personal_epoch(txn: &mut dyn StateTxn) -> Result<Option<crate::api::ids::EpochId>, SyncError> {
    Ok(match txn.get(&RowKey::Scope(ScopeName::Personal)).await? {
        Some(Row::Scope(row)) => row.epoch,
        _ => None,
    })
}
