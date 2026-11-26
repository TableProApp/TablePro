// Once its person confirmed: A pushes the approval change set, and N takes it under the keys it compared and merges
// the trust plaintext into its key tables in one commit (0056, Approving a device, steps 6 to 8; 0054, `key_versions`).

use std::collections::HashMap;

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::{AccountCertificate, CertKind, DeviceCertificate, IkChange};
use tablepro_keys::encoding::{AccountId, KeyPurpose, Origin, Version, WrapPurpose};
use tablepro_keys::keys::{DeviceKeys, Ed25519Public};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::scope_key::VersionRecord;
use tablepro_keys::trust::{TrustPin, TrustPlaintext, TrustVersion};
use tablepro_keys::wrap::{Recipient, Wrap, device_target};

use super::change_set::{self, Arrived};
use super::merge::{self, Approver, HeldTables, Merge, MergeFacts, Merged};
use super::session::SessionRecord;
use super::steps::{Pushed, pushed};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyNoticeKind, SessionEnd};
use crate::api::state::{KeyDevicePinRow, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::RejectedCode;
use crate::keys::{HeldDeviceKeys, HeldObject, KeyService, OwnAccount, create_change};

async fn scan_rows(txn: &mut dyn StateTxn, table: Table) -> Result<Vec<Row>, SyncError> {
    Ok(txn.scan(&RowRange::Table(table)).await?)
}

pub(super) async fn held_tables(txn: &mut dyn StateTxn) -> Result<HeldTables, SyncError> {
    let mut held = HeldTables::default();
    for row in scan_rows(txn, Table::KeyPins).await? {
        if let Row::KeyPin(pin) = row {
            held.pins.push(pin);
        }
    }
    for row in scan_rows(txn, Table::KeyVersions).await? {
        if let Row::KeyVersion(version) = row {
            held.versions.push(version);
        }
    }
    Ok(held)
}

// The approver's view as the trust plaintext carries it: every pin, and the newest version of each scope key.
pub(super) fn trust_of(held: &HeldTables, account: AccountId) -> TrustPlaintext {
    let pins = held
        .pins
        .iter()
        .map(|pin| TrustPin {
            account: pin.account,
            ik: pin.ik,
            av: pin.av,
            how: pin.how,
            alert: pin.alert,
            replaced: pin.replaced.clone(),
        })
        .collect();
    let versions = held
        .versions
        .iter()
        .map(|row| TrustVersion {
            owner: match row.scope {
                ScopeName::Team(team) => team.0,
                ScopeName::Personal | ScopeName::History => account.0,
            },
            purpose: row.purpose,
            version: row.version,
            record: row.record,
        })
        .collect();
    TrustPlaintext { pins, versions }
}

// What N reads from its own `key_objects` while it merges, loaded before the merge so it decides on one snapshot.
pub(super) struct HeldFacts {
    origin: Origin,
    account: AccountId,
    versions: HashMap<(KeyPurpose, Version), (VersionRecord, bool)>,
    certificates: HashMap<Version, AccountCertificate>,
    replaces: Vec<AccountCertificate>,
}

impl HeldFacts {
    // From the account's personal version records and certificates and the replace certificates of each team.
    pub(super) fn from_objects(
        origin: &Origin,
        account: AccountId,
        versions: &[HeldObject],
        certificates: &[HeldObject],
        members: &[HeldObject],
    ) -> Self {
        let mut facts = Self {
            origin: origin.clone(),
            account,
            versions: HashMap::new(),
            certificates: HashMap::new(),
            replaces: Vec::new(),
        };
        for held in versions {
            if let Some(record) = held.object.version_record()
                && record.key.owner == account.0
                && record.key.purpose != KeyPurpose::Team
            {
                facts
                    .versions
                    .insert((record.key.purpose, record.key.version), (record, held.applied));
            }
        }
        for held in certificates.iter().filter(|held| held.applied) {
            if let Some(certificate) = certificate_of(&held.object) {
                if certificate.kind == CertKind::Replace {
                    facts.replaces.push(certificate.clone());
                }
                if certificate.account == account && certificate.verify(origin).is_ok() {
                    facts.certificates.insert(certificate.av, certificate);
                }
            }
        }
        for held in members {
            if let Some(certificate) = certificate_of(&held.object)
                && certificate.kind == CertKind::Replace
            {
                facts.replaces.push(certificate);
            }
        }
        facts
    }
}

impl MergeFacts for HeldFacts {
    fn version_signer(
        &self,
        purpose: KeyPurpose,
        version: Version,
        record: &[u8; 32],
    ) -> Result<Option<Version>, KeysError> {
        let Some((held, applied)) = self.versions.get(&(purpose, version)) else {
            return Ok(None);
        };
        // A personal or history version is signed by its own account.
        if held.signer != self.account {
            return Err(KeysError::Signature);
        }
        let origin = &self.origin;
        if held.digest(origin)? != *record {
            // An applied record at that id is in force, so another one there is an alarm; a candidate gives way.
            return if *applied { Err(KeysError::Conflict) } else { Ok(None) };
        }
        let Some(certificate) = self.certificates.get(&held.signer_av) else {
            return Ok(None);
        };
        held.verify(origin, &certificate.ask)?;
        Ok(Some(held.signer_av))
    }

    fn endorsed_by(&self, account: AccountId, ik: &Ed25519Public) -> Option<(Ed25519Public, Version)> {
        self.replaces
            .iter()
            .filter(|certificate| certificate.account == account && certificate.ik != *ik)
            .find(|certificate| certificate.ik_change(&self.origin, ik) == Ok(IkChange::Endorsed))
            .map(|certificate| (certificate.ik, certificate.av))
    }
}

fn certificate_of(object: &KeyObject) -> Option<AccountCertificate> {
    match (&object.id, &object.body) {
        (KeyRecordId::Account { account, av }, KeyBody::Account(body))
        | (KeyRecordId::Member { account, av }, KeyBody::Member(body)) => Some(body.certificate(*account, *av)),
        _ => None,
    }
}

impl KeyService {
    async fn held_facts(&self, txn: &mut dyn StateTxn) -> Result<HeldFacts, SyncError> {
        let versions = self.held_objects(txn, ScopeName::Personal, KeyKind::Version).await?;
        let certificates = self.held_objects(txn, ScopeName::Personal, KeyKind::Account).await?;
        let mut members = Vec::new();
        for row in scan_rows(txn, Table::Scopes).await? {
            if let Row::Scope(scope) = row
                && matches!(scope.scope, ScopeName::Team(_))
            {
                members.extend(self.held_objects(txn, scope.scope, KeyKind::Member).await?);
            }
        }
        Ok(HeldFacts::from_objects(
            self.origin(),
            self.account(),
            &versions,
            &certificates,
            &members,
        ))
    }

    // A, once its person confirmed: the approval at the account's current `av`, built and sealed once. A retry sends
    // the same objects; one the server refuses because a rotation passed that `av` is built again after the next pull,
    // at the new one.
    pub(super) async fn send_approval(&self, record: &mut SessionRecord) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        let own = self.approved_device_account(txn.as_mut(), "approve a device").await?;
        // A replace or a reset changed the IK the words covered: the session ends.
        if own.ik != record.ik {
            record.cancel(SessionEnd::User).ok();
            self.send_cancel(record, SessionEnd::User).await?;
            return Err(KeysError::Session.into());
        }
        if self
            .approval_av_failed(record.request)
            .await?
            .is_some_and(|failed| own.av <= failed)
        {
            self.hooks().pass_soon();
            return Ok(());
        }
        let objects = match self.held_approval(txn.as_mut(), record, &own).await? {
            Held::Applied(objects) => return self.approval_applied(record, &objects).await,
            Held::Candidates(objects) => objects,
            Held::None => {
                let trust = trust_of(&held_tables(txn.as_mut()).await?, self.account());
                let objects = change_set::build(self.origin(), self.account(), &own, &record.n, &trust)?;
                for object in &objects {
                    self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                        .await?;
                }
                txn.commit().await?;
                objects
            }
        };
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self
            .push_change_set(ScopeName::Personal, changes, self.dpop_key().await?)
            .await;
        let answer = match outcomes {
            Ok(outcomes) => pushed(&outcomes)?,
            // Not answered: the candidates stay as sealed and go up again unchanged.
            Err(SyncError::Transport(error)) if super::transient(&error) => {
                self.hooks().pass_soon();
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        self.approval_answered(record, &own, objects, answer).await
    }

    async fn approval_answered(
        &self,
        record: &mut SessionRecord,
        own: &OwnAccount,
        objects: Vec<KeyObject>,
        answer: Pushed,
    ) -> Result<(), SyncError> {
        match answer {
            Pushed::Applied => self.approval_applied(record, &objects).await,
            // Another copy at one of its ids: this side's own, applied, when its wrap names this key device as writer.
            Pushed::Refused(RejectedCode::CreateOnly) => {
                let mut txn = self.begin().await?;
                if let Held::Applied(held) = self.held_approval(txn.as_mut(), record, own).await? {
                    drop(txn);
                    return self.approval_applied(record, &held).await;
                }
                drop(txn);
                self.forget_candidates(&objects).await?;
                Err(SyncError::Rejected {
                    code: RejectedCode::CreateOnly,
                })
            }
            Pushed::Refused(RejectedCode::BadStatement) => {
                self.forget_candidates(&objects).await?;
                self.note_approval_av_failed(record.request, own.av).await?;
                self.hooks().pass_soon();
                Ok(())
            }
            Pushed::Refused(RejectedCode::RequestClosed) => {
                self.forget_candidates(&objects).await?;
                record.expire_if_due(i64::MAX);
                self.save_session(record).await
            }
            Pushed::Refused(code) => {
                self.forget_candidates(&objects).await?;
                Err(SyncError::Rejected { code })
            }
        }
    }

    // The approval of N's key device at A's `av` as this device holds it: applied, with its wraps written by this key
    // device, or its own candidates not yet answered.
    async fn held_approval(
        &self,
        txn: &mut dyn StateTxn,
        record: &SessionRecord,
        own: &OwnAccount,
    ) -> Result<Held, SyncError> {
        let account = self.account();
        let key_device = record.n.key_device;
        let ids = [
            (
                KeyKind::Device,
                KeyRecordId::Device {
                    account,
                    key_device,
                    av: own.av,
                },
            ),
            (
                KeyKind::Wrap,
                KeyRecordId::Wrap(device_target(account, WrapPurpose::Account, own.av, key_device)),
            ),
            (
                KeyKind::Wrap,
                KeyRecordId::Wrap(device_target(account, WrapPurpose::Trust, own.av, key_device)),
            ),
        ];
        let mut held = Vec::new();
        for (kind, id) in ids {
            match self.held_object(txn, ScopeName::Personal, kind, &id.to_wire()).await? {
                Some(object) => held.push(object),
                None => return Ok(Held::None),
            }
        }
        let ours = held.iter().filter_map(|held| held.object.wrap()).all(|wrap| {
            wrap.wrapper.account == account
                && wrap.wrapper.av == own.av
                && wrap.wrapper.key_device == own.device.key_device
        });
        let objects: Vec<KeyObject> = held.iter().map(|held| held.object.clone()).collect();
        Ok(
            match (
                ours,
                held.iter().all(|held| held.applied),
                held.iter().any(|held| held.applied),
            ) {
                (true, true, _) => Held::Applied(objects),
                (true, false, false) => Held::Candidates(objects),
                _ => Held::None,
            },
        )
    }

    async fn forget_candidates(&self, objects: &[KeyObject]) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, objects).await?;
        txn.commit().await?;
        Ok(())
    }

    // The words covered N's key device id and keys, so A keeps them as an own-device pin (step 8).
    async fn approval_applied(&self, record: &mut SessionRecord, objects: &[KeyObject]) -> Result<(), SyncError> {
        record.approved();
        let mut txn = self.begin().await?;
        for object in objects {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, true)
                .await?;
        }
        txn.put(Row::KeyDevicePin(KeyDevicePinRow {
            key_device: record.n.key_device,
            dek: record.n.dek,
            dsk: record.n.dsk,
        }))
        .await?;
        self.put_session(txn.as_mut(), record).await?;
        txn.commit().await?;
        Ok(())
    }

    // N, once its person confirmed. False while the approval change set or a record it needs has not arrived.
    pub(super) async fn try_merge(&self, record: &mut SessionRecord) -> Result<bool, SyncError> {
        let held_keys = self.device_keys().await?;
        let Some(n_keys) = held_keys
            .pending
            .clone()
            .filter(|keys| keys.key_device == record.n.key_device)
        else {
            return Err(SyncError::Unknown {
                what: "the request's device keys",
            });
        };
        let old_av = {
            let mut txn = self.begin().await?;
            self.pin(txn.as_mut(), self.account()).await?.map(|pin| pin.av)
        };
        let mut txn = self.begin().await?;
        let Some(found) = self.find_approval(txn.as_mut(), &n_keys).await? else {
            return Ok(false);
        };
        let approver = record.peer().ok_or(SyncError::Keys(KeysError::Session))?;
        let arrived = Arrived {
            certificate: &found.certificate,
            device: &found.device,
            account_wrap: &found.account_wrap,
            trust_wrap: &found.trust_wrap,
        };
        let opened = match change_set::open(self.origin(), self.account(), &n_keys, &approver, &record.ik, &arrived) {
            Ok(opened) => opened,
            Err(error) => return self.refuse_approval(record, held_keys, error).await,
        };
        let held = held_tables(txn.as_mut()).await?;
        let facts = self.held_facts(txn.as_mut()).await?;
        let view = Approver {
            account: self.account(),
            ik: record.ik,
            av: opened.av,
            trust: &opened.trust,
            device: approver,
        };
        let merged = match merge::merge(&held, &view, &facts) {
            Ok(Merge::Merged(merged)) => merged,
            Ok(Merge::Waiting { .. }) => {
                self.hooks().pass_soon();
                return Ok(false);
            }
            Err(error) => return self.refuse_approval(record, held_keys, error).await,
        };
        drop(facts);
        // The tables commit first and the device keys switch after, so a crash between the two leaves the session
        // with its switch still owed, which `finish_switch` makes on resume (0054, The device's key state).
        self.store_account_keys(opened.av, &opened.keys).await?;
        record.merged();
        self.write_merged(txn.as_mut(), &held, &merged).await?;
        self.put_session(txn.as_mut(), record).await?;
        txn.commit().await?;
        self.merged_notices(&merged)?;
        self.erase_older_account_keys(old_av, opened.av).await?;
        self.finish_switch(record).await?;
        Ok(true)
    }

    // N: the approved device keys in force, the pending ones gone.
    pub(super) async fn finish_switch(&self, record: &mut SessionRecord) -> Result<(), SyncError> {
        let held = self.device_keys().await?;
        let approved = [held.pending, held.current]
            .into_iter()
            .flatten()
            .find(|keys| keys.key_device == record.n.key_device)
            .ok_or(SyncError::Unknown {
                what: "the request's device keys",
            })?;
        self.store_device_keys(&HeldDeviceKeys {
            current: Some(approved),
            pending: None,
        })
        .await?;
        record.sent.approval = true;
        self.save_session(record).await
    }

    // An approval replaces the account keys a device held (0056, Keys, Erasing): only the approved `av`'s stay.
    async fn erase_older_account_keys(&self, old: Option<Version>, approved: Version) -> Result<(), SyncError> {
        let Some(old) = old else {
            return Ok(());
        };
        for av in 1..=old.get() {
            if av != approved.get() {
                self.erase_account_keys(Version::new(av)?).await?;
            }
        }
        Ok(())
    }

    // N refuses the approval and keeps its prior keys and tables; the pending device keys go (keys.stale, a wrap N
    // did not compare, keys.conflict).
    async fn refuse_approval(
        &self,
        record: &mut SessionRecord,
        held_keys: HeldDeviceKeys,
        error: KeysError,
    ) -> Result<bool, SyncError> {
        self.store_device_keys(&HeldDeviceKeys {
            current: held_keys.current,
            pending: None,
        })
        .await?;
        record.cancel(SessionEnd::User).ok();
        record.sent.cancel = true;
        self.save_session(record).await?;
        if error == KeysError::Conflict {
            self.raise_notice(KeyNoticeKind::Conflict {
                scope: ScopeName::Personal,
            })?;
        }
        Err(error.into())
    }

    async fn write_merged(&self, txn: &mut dyn StateTxn, held: &HeldTables, merged: &Merged) -> Result<(), SyncError> {
        for pin in &merged.pins {
            txn.put(Row::KeyPin(pin.clone())).await?;
        }
        for row in &held.versions {
            if !merged
                .versions
                .iter()
                .any(|kept| kept.scope == row.scope && kept.purpose == row.purpose)
            {
                txn.delete(&RowKey::KeyVersion(row.scope, row.purpose)).await?;
            }
        }
        for version in &merged.versions {
            txn.put(Row::KeyVersion(version.clone())).await?;
        }
        for row in scan_rows(txn, Table::KeyDevicePins).await? {
            if let Row::KeyDevicePin(pin) = row {
                txn.delete(&RowKey::KeyDevicePin(pin.key_device)).await?;
            }
        }
        for pin in &merged.device_pins {
            txn.put(Row::KeyDevicePin(pin.clone())).await?;
        }
        Ok(())
    }

    fn merged_notices(&self, merged: &Merged) -> Result<(), SyncError> {
        self.clear_unanchored();
        for account in &merged.alerts_opened {
            self.raise_notice(KeyNoticeKind::KeysChanged { account: *account })?;
        }
        for account in &merged.replaced {
            self.raise_notice(KeyNoticeKind::RecoveryKeyReplaced { account: *account })?;
        }
        for purpose in &merged.resumed {
            self.hooks().resume_scope(match purpose {
                KeyPurpose::History => ScopeName::History,
                KeyPurpose::Personal | KeyPurpose::Team => ScopeName::Personal,
            });
        }
        self.hooks().pass_soon();
        Ok(())
    }

    // The approval of this key device at the highest `av` whose four objects the device holds.
    async fn find_approval(&self, txn: &mut dyn StateTxn, n: &DeviceKeys) -> Result<Option<Found>, SyncError> {
        let account = self.account();
        let mut avs: Vec<Version> = self
            .held_objects(txn, ScopeName::Personal, KeyKind::Wrap)
            .await?
            .iter()
            .filter_map(|held| held.object.wrap())
            .filter(|wrap| {
                wrap.target.owner == account.0
                    && wrap.target.purpose == WrapPurpose::Account
                    && wrap.target.recipient == Recipient::Device(n.key_device)
            })
            .map(|wrap| wrap.target.version)
            .collect();
        avs.sort_unstable();
        let Some(av) = avs.pop() else {
            return Ok(None);
        };
        let wrap_at = |purpose| KeyRecordId::Wrap(device_target(account, purpose, av, n.key_device)).to_wire();
        let account_id = wrap_at(WrapPurpose::Account);
        let account_wrap = self
            .held_object(txn, ScopeName::Personal, KeyKind::Wrap, &account_id)
            .await?
            .and_then(|held| held.object.wrap());
        let trust_id = wrap_at(WrapPurpose::Trust);
        let trust_wrap = self
            .held_object(txn, ScopeName::Personal, KeyKind::Wrap, &trust_id)
            .await?
            .and_then(|held| held.object.wrap());
        let device_id = KeyRecordId::Device {
            account,
            key_device: n.key_device,
            av,
        };
        let device = self
            .held_object(txn, ScopeName::Personal, KeyKind::Device, &device_id.to_wire())
            .await?
            .and_then(|held| match held.object.body {
                KeyBody::Device(body) => Some(body.certificate(account, n.key_device, av)),
                _ => None,
            });
        let certificate_id = KeyRecordId::Account { account, av };
        let certificate = self
            .held_object(txn, ScopeName::Personal, KeyKind::Account, &certificate_id.to_wire())
            .await?
            .and_then(|held| certificate_of(&held.object));
        Ok(match (certificate, device, account_wrap, trust_wrap) {
            (Some(certificate), Some(device), Some(account_wrap), Some(trust_wrap)) => Some(Found {
                certificate,
                device,
                account_wrap,
                trust_wrap,
            }),
            _ => None,
        })
    }
}

enum Held {
    Applied(Vec<KeyObject>),
    Candidates(Vec<KeyObject>),
    None,
}

struct Found {
    certificate: AccountCertificate,
    device: DeviceCertificate,
    account_wrap: Wrap,
    trust_wrap: Wrap,
}
