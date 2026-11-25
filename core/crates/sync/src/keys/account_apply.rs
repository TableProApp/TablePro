// The personal scope's key objects as a pull serves them (0056, Pins; Account flows; Rollback): each kept at its id,
// then the own account followed up its certificates one `av` at a time. At each `av` the personal and history keys move
// to the versions signed under it, so the current version is always the one signed under the account's current `av`.
// A certificate whose change set has not all arrived waits; one that leaves this device out locks it; an IK nothing
// endorsed locks it as a reset elsewhere does. Nothing here erases a key.

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::{AccountCertificate, IkChange};
use tablepro_keys::encoding::{KeyPurpose, Version, WrapPurpose};
use tablepro_keys::keys::{AccountPublicKeys, DeviceKeys, Ed25519Public};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::trust::PinHow;
use tablepro_keys::wrap::{Recipient, Wrap, device_target};

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyApplied, KeyArrival, KeyNoticeKind, LockCause, RefusedObject};
use crate::api::state::{
    KeyPinRow, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn, StoppedCause, Table,
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

impl KeyService {
    pub(crate) async fn apply_personal_arrival(&self, arrival: &KeyArrival) -> Result<KeyApplied, SyncError> {
        if arrival.scope != ScopeName::Personal {
            return Err(SyncError::Malformed {
                what: "account objects from another scope",
            });
        }
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let mut applied = KeyApplied::default();
        let mut fresh = Vec::new();
        let mut own_genesis = false;
        for record in &arrival.records {
            if !ACCOUNT_KINDS.contains(&record.kind.as_str()) || record.deleted.is_some() {
                continue;
            }
            match self.take_record(txn.as_mut(), record).await {
                Ok((object, candidate)) => {
                    own_genesis |= candidate
                        && object.id
                            == KeyRecordId::Account {
                                account: self.account,
                                av: Version::FIRST,
                            };
                    fresh.push(object);
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
        if own_genesis && !self.is_unanchored() && !self.is_rebuilding() {
            self.adopt_own_genesis(txn.as_mut()).await?;
        }
        self.settle_account(txn.as_mut()).await?;
        let mut in_force = match txn.get(&RowKey::Scope(ScopeName::Personal)).await? {
            Some(Row::Scope(row)) => row.key_version,
            _ => None,
        };
        if self.pin(txn.as_mut(), self.account).await?.is_some() {
            for object in &fresh {
                match self.check_personal_object(txn.as_mut(), object).await? {
                    Checked::Verified => {
                        if let Some(record) = object.version_record()
                            && record.key.purpose == KeyPurpose::Personal
                        {
                            in_force = in_force.max(Some(record.key.version));
                        }
                    }
                    Checked::Held => applied.held.push(object.id.to_wire()),
                    Checked::Refused(error) => applied.refused.push(RefusedObject {
                        record_id: object.id.to_wire(),
                        error,
                    }),
                }
            }
        }
        applied.in_force = in_force;
        txn.commit().await?;
        Ok(applied)
    }

    // Parses a served record as the key object its kind and id name, from its exact text, and keeps it. Says whether
    // it is this device's own candidate that the server now serves back.
    async fn take_record(&self, txn: &mut dyn StateTxn, record: &PulledRecord) -> Result<(KeyObject, bool), SyncError> {
        let text = record.fields_json.as_deref().ok_or(KeysError::Encoding {
            what: "a key object served without its text",
        })?;
        let object = KeyObject::parse(record.kind.as_str(), &record.record_id, text.as_bytes())?;
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
        self.hold_object(txn, ScopeName::Personal, &object, true).await?;
        Ok((object, candidate))
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
            } else if pin.replaced.contains(&certificate.ik) {
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
    async fn adopt_own_genesis(&self, txn: &mut dyn StateTxn) -> Result<(), SyncError> {
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
        let Some(held) = self
            .held_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?
            .filter(|held| held.applied)
        else {
            return Ok(());
        };
        let KeyBody::Account(body) = &held.object.body else {
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
        let mut objects = vec![held.object];
        for version in self.held_objects(txn, ScopeName::Personal, KeyKind::Version).await? {
            if version.applied
                && version
                    .object
                    .version_record()
                    .is_some_and(|record| record.signer_av == Version::FIRST && record.key.purpose != KeyPurpose::Team)
            {
                objects.push(version.object);
            }
        }
        self.adopt_account_change_set(txn, &objects).await
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
            .held_object(txn, ScopeName::Personal, KeyKind::Recovery, &recovery.to_wire())
            .await?
            .is_none()
        {
            return Ok(false);
        }
        let devices = self.held_objects(txn, ScopeName::Personal, KeyKind::Device).await?;
        if !devices
            .iter()
            .any(|held| matches!(held.object.id, KeyRecordId::Device { av: at, .. } if at == av))
        {
            return Ok(false);
        }
        let versions = self.held_objects(txn, ScopeName::Personal, KeyKind::Version).await?;
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let signed = versions.iter().any(|held| {
                held.object
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
            .held_object(
                txn,
                ScopeName::Personal,
                KeyKind::Wrap,
                &KeyRecordId::Wrap(target).to_wire(),
            )
            .await?
            .and_then(|held| held.object.wrap())
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

fn followed_pin(pin: KeyPinRow, certificate: &AccountCertificate, endorsed: bool) -> KeyPinRow {
    if !endorsed {
        return KeyPinRow {
            av: certificate.av,
            ..pin
        };
    }
    let mut replaced = pin.replaced;
    replaced.push(pin.ik);
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
