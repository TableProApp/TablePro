// The personal scope's key objects as a pull serves them (0056, Pins; Account flows; Rollback): each kept at its id,
// then the own account followed up its certificates one `av` at a time. At each `av` the personal and history keys move
// to the versions signed under it, so the current version is always the one signed under the account's current `av`.
// A certificate whose change set has not all arrived waits; one that leaves this device out locks it; an IK nothing
// endorsed locks it as a reset elsewhere does. Nothing here erases a key, and an object refused is never in force.

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::{AccountCertificate, IkChange};
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version, WrapPurpose};
use tablepro_keys::keys::{AccountPublicKeys, DeviceKeys, Ed25519Public};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::trust::{PinHow, Replaced};
use tablepro_keys::wrap::{Recipient, Wrap, device_target};

use super::KeyService;
use super::pins::seen_replaced;
use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::key_flows::{KeyApplied, KeyArrival, KeyNoticeKind, LockCause, RefusedObject};
use crate::api::state::{
    KeyObjectRow, KeyPinRow, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn,
    StoppedCause, Table,
};
use crate::api::transport::PulledRecord;

const ACCOUNT_KINDS: [&str; 6] = [
    "key.account",
    "key.device",
    "key.recovery",
    "key.version",
    "key.ring",
    "key.wrap",
];

enum Checked {
    Verified,
    Held,
    Refused(KeysError),
}

enum Followed {
    Yes,
    Waits,
    LeftOut,
}

// An object a pull brought, with the row its id held before, which comes back if the object is refused.
struct Arrived {
    object: KeyObject,
    before: Option<KeyObjectRow>,
}

impl KeyService {
    pub(crate) async fn apply_personal_arrival(&self, arrival: &KeyArrival) -> Result<KeyApplied, SyncError> {
        if arrival.scope != ScopeName::Personal {
            return Err(SyncError::Malformed {
                what: "account objects from another scope",
            });
        }
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let mut applied = KeyApplied::default();
        let mut fresh = Vec::new();
        let mut own_genesis = false;
        let mut own_rotation = None;
        for record in &arrival.records {
            if !ACCOUNT_KINDS.contains(&record.kind.as_str()) || record.deleted.is_some() {
                continue;
            }
            match self.take_record(txn.as_mut(), record).await {
                Ok((object, candidate, before)) => {
                    if candidate && let KeyRecordId::Account { av, .. } = object.id {
                        if av == Version::FIRST {
                            own_genesis = true;
                        } else {
                            own_rotation = Some(av);
                        }
                    }
                    fresh.push(Arrived { object, before });
                }
                Err(SyncError::Keys(error)) => {
                    if error == KeysError::Conflict {
                        self.raise_notice(KeyNoticeKind::Conflict {
                            scope: ScopeName::Personal,
                        })?;
                    }
                    applied.refused.push(RefusedObject {
                        record_id: record.record_id.clone(),
                        error,
                    });
                }
                Err(other) => return Err(other),
            }
        }
        let mut in_force = match txn.get(&RowKey::Scope(ScopeName::Personal)).await? {
            Some(Row::Scope(row)) => row.key_version,
            _ => None,
        };
        // Judged before anything below reads them, so what follows sees only objects in force.
        let pinned = self.pin(txn.as_mut(), self.account).await?.is_some();
        if pinned {
            in_force = in_force.max(self.judge_arrived(txn.as_mut(), &fresh, &mut applied).await?);
        }
        if own_genesis && !self.is_unanchored() && !self.is_rebuilding() {
            self.adopt_own_genesis(txn.as_mut()).await?;
        }
        if !pinned && self.pin(txn.as_mut(), self.account).await?.is_some() {
            in_force = in_force.max(self.judge_arrived(txn.as_mut(), &fresh, &mut applied).await?);
        }
        self.forget_lost_rotation(txn.as_mut()).await?;
        self.settle_account(txn.as_mut()).await?;
        if let Some(av) = own_rotation {
            self.forget_pins_rotation_left_out(txn.as_mut(), av).await?;
        }
        applied.in_force = in_force;
        txn.commit().await?;
        Ok(applied)
    }

    // Parses a served record as the key object its kind and id name, from its exact text, and keeps it. Says whether
    // it is this device's own candidate that the server now serves back, and what the id held before.
    async fn take_record(
        &self,
        txn: &mut dyn StateTxn,
        record: &PulledRecord,
    ) -> Result<(KeyObject, bool, Option<KeyObjectRow>), SyncError> {
        let text = record.fields_json.as_deref().ok_or(KeysError::Encoding {
            what: "a key object served without its text",
        })?;
        let object = KeyObject::parse(record.kind.as_str(), &record.record_id, text.as_bytes())?;
        // A certificate its own IK did not sign never displaces anything, even on a device with no pin to judge by.
        if let (KeyRecordId::Account { av, .. }, KeyBody::Account(body)) = (&object.id, &object.body) {
            body.certificate(self.account, *av).verify(&self.origin)?;
        }
        let own = object.id.bound_account() == Some(self.account.0);
        let personal = match &object.id {
            KeyRecordId::Version(key) | KeyRecordId::Ring(key) => key.purpose != KeyPurpose::Team,
            KeyRecordId::Wrap(target) => target.purpose != WrapPurpose::Key(KeyPurpose::Team),
            _ => true,
        };
        if !own || !personal {
            return Err(KeysError::Encoding {
                what: "a personal key object of another account or a team",
            }
            .into());
        }
        let candidate = self
            .held_object(txn, ScopeName::Personal, object.id.kind(), &object.id.to_wire())
            .await?
            .is_some_and(|held| !held.applied && held.object == object);
        let before = match txn.get(&object_key(&object)?).await? {
            Some(Row::KeyObject(row)) => Some(row),
            _ => None,
        };
        self.hold_served(txn, ScopeName::Personal, &object, record).await?;
        Ok((object, candidate, before))
    }

    // Judges each object this pull brought, then the held objects a certificate in it lets be judged now. A refused
    // object gives its id back to what it held before, with two exceptions that only ever lock the device. An IK
    // change nothing endorsed locks it as a reset elsewhere does, and the approval from the resetting device reads it
    // (0056, Pins). A bad `account` or `trust` wrap to this device leaves it out of its rotation, which the walk up
    // the certificates finds from the wrap itself (0056, Rotation).
    async fn judge_arrived(
        &self,
        txn: &mut dyn StateTxn,
        fresh: &[Arrived],
        applied: &mut KeyApplied,
    ) -> Result<Option<Version>, SyncError> {
        let mut in_force = None;
        for arrived in fresh {
            let object = &arrived.object;
            match self.check_personal_object(txn, object).await? {
                Checked::Verified => {
                    if let Some(record) = object.version_record()
                        && record.key.purpose == KeyPurpose::Personal
                    {
                        in_force = in_force.max(Some(record.key.version));
                    }
                }
                Checked::Held => applied.held.push(object.id.to_wire()),
                Checked::Refused(error) => {
                    if !self.stays_refused(txn, object, &error).await? {
                        put_back(txn, object, arrived.before.clone()).await?;
                    }
                    applied.refused.push(RefusedObject {
                        record_id: object.id.to_wire(),
                        error,
                    });
                }
            }
        }
        let Some(lowest) = fresh
            .iter()
            .filter_map(|arrived| match arrived.object.id {
                KeyRecordId::Account { av, .. } => Some(av),
                _ => None,
            })
            .min()
        else {
            return Ok(in_force);
        };
        for kind in [
            KeyKind::Account,
            KeyKind::Device,
            KeyKind::Recovery,
            KeyKind::Version,
            KeyKind::Wrap,
        ] {
            for object in self.applied_objects(txn, ScopeName::Personal, kind).await? {
                if fresh.iter().any(|arrived| arrived.object.id == object.id)
                    || !object_avs(&object).iter().any(|av| *av >= lowest)
                {
                    continue;
                }
                if let Checked::Refused(error) = self.check_personal_object(txn, &object).await?
                    && !self.stays_refused(txn, &object, &error).await?
                {
                    put_back(txn, &object, None).await?;
                    applied.refused.push(RefusedObject {
                        record_id: object.id.to_wire(),
                        error,
                    });
                }
            }
        }
        Ok(in_force)
    }

    // A refused object that stays held, never in force for any decision: the unendorsed certificate itself, what it
    // signs that verifies under its own keys, and an `account` or `trust` wrap to this device.
    async fn stays_refused(
        &self,
        txn: &mut dyn StateTxn,
        object: &KeyObject,
        error: &KeysError,
    ) -> Result<bool, SyncError> {
        if let Some(wrap) = object.wrap()
            && matches!(wrap.target.purpose, WrapPurpose::Account | WrapPurpose::Trust)
        {
            let own = self.device_keys().await?.current.map(|keys| keys.key_device);
            if Some(wrap.target.recipient) == own.map(Recipient::Device) {
                return Ok(true);
            }
        }
        if *error != KeysError::Unendorsed {
            return Ok(false);
        }
        if matches!(object.id, KeyRecordId::Account { .. }) {
            return Ok(true);
        }
        self.signed_under_own_keys(txn, object).await
    }

    // An object at an unendorsed certificate's `av` that verifies under the keys that certificate names, as a reset
    // elsewhere writes them. One that does not is refused like any other.
    async fn signed_under_own_keys(&self, txn: &mut dyn StateTxn, object: &KeyObject) -> Result<bool, SyncError> {
        Ok(match (&object.id, &object.body) {
            (KeyRecordId::Device { key_device, av, .. }, KeyBody::Device(body)) => {
                self.unendorsed_at(txn, *av).await?.is_some_and(|certificate| {
                    body.certificate(self.account, *key_device, *av)
                        .verify(&self.origin, &certificate.ask)
                        .is_ok()
                })
            }
            (KeyRecordId::Recovery { av, .. }, _) => self.unendorsed_at(txn, *av).await?.is_some(),
            (KeyRecordId::Version(_), _) => match object.version_record() {
                Some(record) if record.signer == self.account && record.key.owner == self.account.0 => self
                    .unendorsed_at(txn, record.signer_av)
                    .await?
                    .is_some_and(|certificate| record.verify(&self.origin, &certificate.ask).is_ok()),
                _ => false,
            },
            (KeyRecordId::Wrap(target), _) => match (object.wrap(), target.recipient) {
                (Some(wrap), Recipient::Account(account)) if account == self.account => {
                    let recipient = self.unendorsed_at(txn, target.recipient_version).await?;
                    let wrapper = self.unendorsed_at(txn, wrap.wrapper.av).await?;
                    match (recipient, wrapper) {
                        (Some(recipient), Some(wrapper)) => {
                            wrap.verify(&self.origin, &recipient.aek, &wrapper.ask).is_ok()
                        }
                        _ => false,
                    }
                }
                _ => false,
            },
            _ => false,
        })
    }

    // The own certificate at `av` as held, its self-signature checked: what an object under it is judged by while
    // nothing endorses its IK.
    async fn unendorsed_at(
        &self,
        txn: &mut dyn StateTxn,
        av: Version,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        Ok(self
            .own_certificate(txn, av)
            .await?
            .filter(|certificate| certificate.verify(&self.origin).is_ok()))
    }

    // The key devices the account certifies at `av`: each device certificate there under the ASK of the verified
    // certificate at that `av`. Never one a served object alone names.
    pub(crate) async fn certified_devices(
        &self,
        txn: &mut dyn StateTxn,
        av: Version,
    ) -> Result<Vec<KeyDeviceId>, SyncError> {
        let certificate = match self.certificate_at(txn, ScopeName::Personal, self.account, av).await {
            Ok(Some(certificate)) => certificate,
            Ok(None) | Err(SyncError::Keys(_) | SyncError::NotAllowed { .. }) => return Ok(Vec::new()),
            Err(other) => return Err(other),
        };
        Ok(self
            .applied_objects(txn, ScopeName::Personal, KeyKind::Device)
            .await?
            .iter()
            .filter_map(|object| match (&object.id, &object.body) {
                (KeyRecordId::Device { key_device, av: at, .. }, KeyBody::Device(body))
                    if *at == av
                        && body
                            .certificate(self.account, *key_device, av)
                            .verify(&self.origin, &certificate.ask)
                            .is_ok() =>
                {
                    Some(*key_device)
                }
                _ => None,
            })
            .collect())
    }

    // Moves the own pin and the personal and history keys as far as the held objects allow.
    pub(crate) async fn settle_account(&self, txn: &mut dyn StateTxn) -> Result<(), SyncError> {
        let Some(mut pin) = self.pin(txn, self.account).await? else {
            return Ok(());
        };
        if pin.alert {
            return Ok(());
        }
        let device = self.device_keys().await?.current;
        loop {
            for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
                self.advance_personal(txn, purpose, pin.av).await?;
            }
            let next = pin.av.next()?;
            let Some(certificate) = self.own_certificate(txn, next).await? else {
                break;
            };
            if certificate.verify(&self.origin).is_err() {
                break;
            }
            let endorsed = if certificate.ik == pin.ik {
                false
            } else if seen_replaced(&pin.replaced, &certificate.ik) {
                break;
            } else {
                match certificate.ik_change(&self.origin, &pin.ik) {
                    Ok(IkChange::Endorsed) => true,
                    Ok(IkChange::Same) => false,
                    Err(KeysError::Unendorsed) => {
                        txn.put(Row::KeyPin(KeyPinRow { alert: true, ..pin })).await?;
                        self.locked(LockCause::OwnAccountReset)?;
                        break;
                    }
                    Err(_) => break,
                }
            };
            if !self.whole_change_set(txn, next).await? {
                break;
            }
            let followed = self.follow_own(txn, &certificate, device.as_ref()).await?;
            if matches!(followed, Followed::Waits) {
                break;
            }
            pin = followed_pin(pin, &certificate, endorsed);
            txn.put(Row::KeyPin(pin.clone())).await?;
            if endorsed {
                self.raise_notice(KeyNoticeKind::RecoveryKeyReplaced { account: self.account })?;
            }
            if matches!(followed, Followed::LeftOut) {
                self.locked(LockCause::LeftOutOfRotation)?;
                for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
                    self.advance_personal(txn, purpose, pin.av).await?;
                }
                break;
            }
        }
        Ok(())
    }

    // A genesis this device pushed and never heard applied, its own candidate served back: only this device holds the
    // account keys its certificate names, beside a device certificate for its own key device. Never in a file it
    // cannot trust, and an approval in flight finishes its own way.
    pub(crate) async fn adopt_own_genesis(&self, txn: &mut dyn StateTxn) -> Result<(), SyncError> {
        if self.pin(txn, self.account).await?.is_some() {
            return Ok(());
        }
        let approving =
            txn.scan(&RowRange::Table(Table::KeyPending)).await?.iter().any(
                |row| matches!(row, Row::KeyPending(pending) if matches!(pending.flow, PendingFlow::Approval { .. })),
            );
        if approving {
            return Ok(());
        }
        let id = KeyRecordId::Account {
            account: self.account,
            av: Version::FIRST,
        };
        let Some(object) = self
            .applied_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?
        else {
            return Ok(());
        };
        let KeyBody::Account(body) = &object.body else {
            return Ok(());
        };
        let certificate = body.certificate(self.account, Version::FIRST);
        let (Some(keys), Some(device)) = (
            self.account_keys(Version::FIRST).await?,
            self.device_keys().await?.current,
        ) else {
            return Ok(());
        };
        if certificate.verify(&self.origin).is_err()
            || keys.check_against(&certificate.ask, &certificate.aek).is_err()
            || !self.certifies(txn, &certificate, &device).await?
        {
            return Ok(());
        }
        // Only a first version this account signed under the genesis certificate's ASK becomes current; anything else
        // the server put at those ids stays where it is and counts for nothing.
        let mut objects = vec![object.clone()];
        for version in self.applied_objects(txn, ScopeName::Personal, KeyKind::Version).await? {
            let genesis = version.version_record().is_some_and(|record| {
                record.key.version == Version::FIRST
                    && record.key.owner == self.account.0
                    && record.key.purpose != KeyPurpose::Team
                    && record.signer == self.account
                    && record.signer_av == Version::FIRST
                    && record.verify(&self.origin, &certificate.ask).is_ok()
            });
            if genesis {
                objects.push(version);
            }
        }
        self.adopt_account_change_set(txn, &objects).await
    }

    // A rotation of this device that applied while its answer was lost, served back: the own-device pins it left out
    // name devices that join again only by approval (0056, Rotation).
    async fn forget_pins_rotation_left_out(&self, txn: &mut dyn StateTxn, av: Version) -> Result<(), SyncError> {
        if self.pin(txn, self.account).await?.is_none_or(|pin| pin.av < av) {
            return Ok(());
        }
        let keep = self.certified_devices(txn, av).await?;
        self.forget_pins_left_out(txn, &keep).await
    }

    fn locked(&self, cause: LockCause) -> Result<(), SyncError> {
        self.hooks.lock(cause);
        self.raise_notice(KeyNoticeKind::Locked { cause })?;
        Ok(())
    }

    // A rotation's change set as 0051 sends it whole: the certificate, its recovery blob, a device certificate, and the
    // personal and history versions signed under it. Until it all arrives a device left out cannot tell.
    async fn whole_change_set(&self, txn: &mut dyn StateTxn, av: Version) -> Result<bool, SyncError> {
        let recovery = KeyRecordId::Recovery {
            account: self.account,
            av,
        };
        if self
            .applied_object(txn, ScopeName::Personal, KeyKind::Recovery, &recovery.to_wire())
            .await?
            .is_none()
        {
            return Ok(false);
        }
        let devices = self.applied_objects(txn, ScopeName::Personal, KeyKind::Device).await?;
        if !devices
            .iter()
            .any(|object| matches!(object.id, KeyRecordId::Device { av: at, .. } if at == av))
        {
            return Ok(false);
        }
        let versions = self.applied_objects(txn, ScopeName::Personal, KeyKind::Version).await?;
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let signed = versions.iter().any(|object| {
                object
                    .version_record()
                    .is_some_and(|record| record.key.purpose == purpose && record.signer_av == av)
            });
            if !signed {
                return Ok(false);
            }
        }
        Ok(true)
    }

    // This device takes the account keys at the certificate's `av` when the change set certifies its key device and
    // wraps the keys to it under the DSK of a device it compared with (0056, Rotation).
    async fn follow_own(
        &self,
        txn: &mut dyn StateTxn,
        certificate: &AccountCertificate,
        device: Option<&DeviceKeys>,
    ) -> Result<Followed, SyncError> {
        let Some(device) = device else {
            return Ok(Followed::LeftOut);
        };
        if !self.certifies(txn, certificate, device).await? {
            return Ok(Followed::LeftOut);
        }
        if let Some(keys) = self.account_keys(certificate.av).await?
            && keys.check_against(&certificate.ask, &certificate.aek).is_ok()
        {
            return Ok(Followed::Yes);
        }
        let target = device_target(self.account, WrapPurpose::Account, certificate.av, device.key_device);
        let Some(wrap) = self
            .applied_object(
                txn,
                ScopeName::Personal,
                KeyKind::Wrap,
                &KeyRecordId::Wrap(target).to_wire(),
            )
            .await?
            .and_then(|object| object.wrap())
        else {
            return Ok(Followed::Waits);
        };
        let Some(compared) = self.compared_dsk(txn, &wrap, device).await? else {
            return Ok(Followed::LeftOut);
        };
        let public = AccountPublicKeys {
            ask: certificate.ask,
            aek: certificate.aek,
        };
        match wrap.open_account(&self.origin, &device.dek, &device.dek.public()?, &compared, &public) {
            Ok(keys) => {
                self.store_account_keys(certificate.av, &keys).await?;
                Ok(Followed::Yes)
            }
            Err(_) => Ok(Followed::LeftOut),
        }
    }

    // The DSK an `account` or `trust` wrap to this device must be signed by: its writer's, as this device compared it,
    // or this device's own for a wrap it wrote itself.
    async fn compared_dsk(
        &self,
        txn: &mut dyn StateTxn,
        wrap: &Wrap,
        device: &DeviceKeys,
    ) -> Result<Option<Ed25519Public>, SyncError> {
        if wrap.wrapper.account != self.account || wrap.wrapper.av != wrap.target.version {
            return Ok(None);
        }
        if wrap.wrapper.key_device == device.key_device {
            return Ok(Some(device.dsk.public()?));
        }
        match txn.get(&RowKey::KeyDevicePin(wrap.wrapper.key_device)).await? {
            Some(Row::KeyDevicePin(pin)) => Ok(Some(pin.dsk)),
            _ => Ok(None),
        }
    }

    // Moves the key of `purpose` up through the versions signed under `level`. A version above it signed under an
    // older `av` stops the key there (`keys.stale`): another device approves this one again, or the person recovers.
    async fn advance_personal(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
        level: Version,
    ) -> Result<(), SyncError> {
        let row = self.personal_row(txn, purpose).await?;
        if row.as_ref().is_some_and(|row| row.state != KeyVersionState::Ok) {
            return Ok(());
        }
        let mut version = row.as_ref().map(|row| row.version);
        loop {
            let next = version.map_or(Ok(Version::FIRST), Version::next)?;
            let Some(record) = self.personal_record(txn, purpose, next).await? else {
                break;
            };
            let Ok(Some(record)) = self.verified_personal_record(txn, &record).await else {
                break;
            };
            if record.signer_av > level {
                break;
            }
            if record.signer_av < level {
                if let Some(mut held) = self.personal_row(txn, purpose).await? {
                    held.stop(StoppedCause::CatchUp);
                    txn.put(Row::KeyVersion(held)).await?;
                    let scope = personal_scope(purpose);
                    self.hooks.stop_scope(scope, StoppedCause::CatchUp);
                    self.raise_notice(KeyNoticeKind::ScopeStopped {
                        scope,
                        cause: StoppedCause::CatchUp,
                    })?;
                    self.locked(LockCause::PersonalStopped)?;
                }
                break;
            }
            txn.put(Row::KeyVersion(KeyVersionRow {
                scope: ScopeName::Personal,
                purpose,
                version: next,
                record: record.digest(&self.origin)?,
                holders: Vec::new(),
                state: KeyVersionState::Ok,
                stopped_cause: None,
                epoch: None,
            }))
            .await?;
            version = Some(next);
        }
        Ok(())
    }

    // What a pulled object is worth on its own: verified, held for a certificate or version that has not arrived, or
    // refused with the code 0056 gives it.
    async fn check_personal_object(&self, txn: &mut dyn StateTxn, object: &KeyObject) -> Result<Checked, SyncError> {
        let outcome = match (&object.id, &object.body) {
            (KeyRecordId::Account { av, .. }, KeyBody::Account(body)) => {
                self.check_own_certificate(txn, &body.certificate(self.account, *av))
                    .await
            }
            (KeyRecordId::Device { key_device, av, .. }, KeyBody::Device(body)) => {
                match self.certificate_at(txn, ScopeName::Personal, self.account, *av).await {
                    Ok(Some(certificate)) => body
                        .certificate(self.account, *key_device, *av)
                        .verify(&self.origin, &certificate.ask)
                        .map(|()| Checked::Verified)
                        .map_err(SyncError::from),
                    Ok(None) => Ok(Checked::Held),
                    Err(error) => Err(error),
                }
            }
            (KeyRecordId::Recovery { av, .. }, _) => self
                .certificate_at(txn, ScopeName::Personal, self.account, *av)
                .await
                .map(|held| {
                    if held.is_some() {
                        Checked::Verified
                    } else {
                        Checked::Held
                    }
                }),
            (KeyRecordId::Version(_), _) => match object.version_record() {
                Some(record) => self.verified_personal_record(txn, &record).await.map(|held| {
                    if held.is_some() {
                        Checked::Verified
                    } else {
                        Checked::Held
                    }
                }),
                None => Ok(Checked::Held),
            },
            (KeyRecordId::Wrap(_), _) => match object.wrap() {
                Some(wrap) => self.check_personal_wrap(txn, &wrap).await,
                None => Ok(Checked::Held),
            },
            _ => Ok(Checked::Verified),
        };
        match outcome {
            Ok(checked) => Ok(checked),
            Err(SyncError::Keys(KeysError::Step { .. })) => Ok(Checked::Held),
            Err(SyncError::Keys(error)) => Ok(Checked::Refused(error)),
            Err(other) => Err(other),
        }
    }

    // At or below the pin a certificate only verifies; above it, it is offered as the newest, so the walk up to it
    // decides: a gap holds it, an IK seen replaced or one nothing endorsed refuses it.
    async fn check_own_certificate(
        &self,
        txn: &mut dyn StateTxn,
        certificate: &AccountCertificate,
    ) -> Result<Checked, SyncError> {
        let Some(pin) = self.pin(txn, self.account).await? else {
            return Ok(Checked::Verified);
        };
        if certificate.av <= pin.av {
            return self
                .verify_certificate(txn, ScopeName::Personal, certificate)
                .await
                .map(|_| Checked::Verified);
        }
        certificate.verify(&self.origin)?;
        let walk = self.walk(txn, ScopeName::Personal, &pin, certificate).await?;
        Ok(match walk.stop {
            None => Checked::Verified,
            Some(KeysError::Step { .. }) => Checked::Held,
            Some(error) => Checked::Refused(error),
        })
    }

    async fn check_personal_wrap(&self, txn: &mut dyn StateTxn, wrap: &Wrap) -> Result<Checked, SyncError> {
        match (wrap.target.purpose, wrap.target.recipient) {
            (WrapPurpose::Key(_), Recipient::Account(account)) => {
                if account != self.account || wrap.wrapper.account != self.account {
                    return Ok(Checked::Refused(KeysError::Signature));
                }
                let recipient = self
                    .certificate_at(txn, ScopeName::Personal, self.account, wrap.target.recipient_version)
                    .await?;
                let wrapper = self
                    .certificate_at(txn, ScopeName::Personal, self.account, wrap.wrapper.av)
                    .await?;
                let (Some(recipient), Some(wrapper)) = (recipient, wrapper) else {
                    return Ok(Checked::Held);
                };
                Ok(match wrap.verify(&self.origin, &recipient.aek, &wrapper.ask) {
                    Ok(()) => Checked::Verified,
                    Err(error) => Checked::Refused(error),
                })
            }
            (WrapPurpose::Account | WrapPurpose::Trust, Recipient::Device(key_device)) => {
                let Some(device) = self.device_keys().await?.current else {
                    return Ok(Checked::Verified);
                };
                if key_device != device.key_device {
                    return Ok(Checked::Verified);
                }
                let Some(compared) = self.compared_dsk(txn, wrap, &device).await? else {
                    return Ok(Checked::Refused(KeysError::NotCompared));
                };
                if let Err(error) = wrap.verify(&self.origin, &device.dek.public()?, &compared) {
                    return Ok(Checked::Refused(match error {
                        KeysError::Signature => KeysError::NotCompared,
                        other => other,
                    }));
                }
                if wrap.target.purpose != WrapPurpose::Account {
                    return Ok(Checked::Verified);
                }
                // The keys it carries must be the ones the certificate at its `av` names (`keys.mismatch`).
                let Some(certificate) = self
                    .certificate_at(txn, ScopeName::Personal, self.account, wrap.target.version)
                    .await?
                else {
                    return Ok(Checked::Held);
                };
                let public = AccountPublicKeys {
                    ask: certificate.ask,
                    aek: certificate.aek,
                };
                Ok(
                    match wrap.open_account(&self.origin, &device.dek, &device.dek.public()?, &compared, &public) {
                        Ok(_) => Checked::Verified,
                        Err(error) => Checked::Refused(error),
                    },
                )
            }
            _ => Ok(Checked::Refused(KeysError::Encoding {
                what: "wrap recipient does not fit its purpose",
            })),
        }
    }
}

fn object_key(object: &KeyObject) -> Result<RowKey, SyncError> {
    Ok(RowKey::KeyObject(
        ScopeName::Personal,
        KindName::parse(object.id.kind().name())?,
        object.id.to_wire(),
    ))
}

async fn put_back(txn: &mut dyn StateTxn, object: &KeyObject, before: Option<KeyObjectRow>) -> Result<(), SyncError> {
    match before {
        Some(row) => txn.put(Row::KeyObject(row)).await?,
        None => txn.delete(&object_key(object)?).await?,
    }
    Ok(())
}

// The account versions an object's check reads a certificate at: one that arrives late lets it be judged.
fn object_avs(object: &KeyObject) -> Vec<Version> {
    match &object.id {
        KeyRecordId::Account { av, .. } | KeyRecordId::Device { av, .. } | KeyRecordId::Recovery { av, .. } => {
            vec![*av]
        }
        KeyRecordId::Version(_) => object
            .version_record()
            .map(|record| record.signer_av)
            .into_iter()
            .collect(),
        KeyRecordId::Wrap(target) => {
            let mut avs = vec![target.recipient_version];
            // A key wrap's own version numbers the scope key, not the account.
            if !matches!(target.purpose, WrapPurpose::Key(_)) {
                avs.push(target.version);
            }
            avs.extend(object.wrap().map(|wrap| wrap.wrapper.av));
            avs
        }
        _ => Vec::new(),
    }
}

fn followed_pin(pin: KeyPinRow, certificate: &AccountCertificate, endorsed: bool) -> KeyPinRow {
    if !endorsed {
        return KeyPinRow {
            av: certificate.av,
            ..pin
        };
    }
    let mut replaced = pin.replaced;
    replaced.push(Replaced {
        ik: pin.ik,
        av: certificate.av,
    });
    KeyPinRow {
        account: pin.account,
        ik: certificate.ik,
        av: certificate.av,
        how: PinHow::Replaced,
        alert: false,
        replaced,
    }
}

pub(crate) const fn personal_scope(purpose: KeyPurpose) -> ScopeName {
    match purpose {
        KeyPurpose::History => ScopeName::History,
        KeyPurpose::Personal | KeyPurpose::Team => ScopeName::Personal,
    }
}
