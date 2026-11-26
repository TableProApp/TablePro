// The proposal and activation change sets of a reset (0056, Account flows, Reset; 0051, Resets), and the rows a
// device keeps for the resets it sees.

use tablepro_keys::KeysError;
use tablepro_keys::body::{AccountBody, DeviceBody, KeyBody, KeyObject, ResetBody};
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{AccountId, KeyPurpose, ResetId, Version};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, ScopeKey};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::{RecoveryBlob, RecoveryKey};
use tablepro_keys::scope_key::Start;

use super::record::ResetRecord;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyNoticeKind, ResetKind, ResetState};
use crate::api::state::{PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
use crate::keys::{AccountObjectsPlan, KeptDevice, KeyService, ScopeKeyPlan};

pub(super) const fn cert_kind(kind: ResetKind) -> CertKind {
    match kind {
        ResetKind::KeepScopeKeys => CertKind::ResetKeepingKeys,
        ResetKind::StartEmpty => CertKind::ResetEmpty,
    }
}

// A proposal's records: its certificate under its own new IK, its device certificate under its new ASK, and its blob.
pub(super) fn check_proposal(
    service: &KeyService,
    account: AccountId,
    body: &ResetBody,
) -> Result<(AccountCertificate, ResetKind), KeysError> {
    let certificate = body.account.certificate(account, body.av);
    certificate.verify(service.origin())?;
    let kind = match certificate.kind {
        CertKind::ResetKeepingKeys => ResetKind::KeepScopeKeys,
        CertKind::ResetEmpty => ResetKind::StartEmpty,
        CertKind::GenesisOrRotation | CertKind::Replace => {
            return Err(KeysError::Encoding {
                what: "a reset proposes a certificate of kind 2 or 3",
            });
        }
    };
    body.device
        .certificate(account, body.key_device, body.av)
        .verify(service.origin(), &certificate.ask)?;
    Ok((certificate, kind))
}

// The three records the activation pushes exactly as the proposal holds them (0051, Resets, Activation).
pub(super) fn proposal_objects(account: AccountId, body: &ResetBody) -> Vec<KeyObject> {
    vec![
        KeyObject {
            id: KeyRecordId::Account { account, av: body.av },
            body: KeyBody::Account(body.account.clone()),
        },
        KeyObject {
            id: KeyRecordId::Device {
                account,
                key_device: body.key_device,
                av: body.av,
            },
            body: KeyBody::Device(body.device.clone()),
        },
        KeyObject {
            id: KeyRecordId::Recovery { account, av: body.av },
            body: KeyBody::Recovery(body.recovery.clone()),
        },
    ]
}

impl KeyService {
    pub(super) async fn reset_records(&self, txn: &mut dyn StateTxn) -> Result<Vec<ResetRecord>, SyncError> {
        txn.scan(&RowRange::Table(Table::KeyPending))
            .await?
            .iter()
            .filter_map(|row| match row {
                Row::KeyPending(row) if matches!(row.flow, PendingFlow::ResetProposal { .. }) => {
                    Some(ResetRecord::from_row(row))
                }
                _ => None,
            })
            .collect()
    }

    pub(super) async fn reset_record(
        &self,
        txn: &mut dyn StateTxn,
        reset: ResetId,
    ) -> Result<Option<ResetRecord>, SyncError> {
        match txn
            .get(&RowKey::KeyPending(PendingFlow::ResetProposal { reset }))
            .await?
        {
            Some(Row::KeyPending(row)) => ResetRecord::from_row(&row).map(Some),
            _ => Ok(None),
        }
    }

    pub(super) async fn put_reset(&self, txn: &mut dyn StateTxn, record: &ResetRecord) -> Result<(), SyncError> {
        txn.put(Row::KeyPending(record.to_row())).await?;
        Ok(())
    }

    // A reset that ended: its notice, and for this device's own proposal its waiting keys erased.
    pub(super) async fn end_reset(&self, record: &mut ResetRecord, state: ResetState) -> Result<(), SyncError> {
        if !record.pending() {
            return Ok(());
        }
        record.state = state;
        if record.mine && state != ResetState::Active {
            self.erase_reset_keys(record.reset).await?;
        }
        self.raise_notice(KeyNoticeKind::ResetEnded {
            reset: record.reset,
            state,
        })?;
        Ok(())
    }

    // Ends every pending reset that is overdue, and returns the rows as they stand.
    pub(super) async fn settled_resets(&self) -> Result<Vec<ResetRecord>, SyncError> {
        let now = self.now_us();
        let mut txn = self.begin().await?;
        let mut records = self.reset_records(txn.as_mut()).await?;
        let mut changed = false;
        for record in &mut records {
            if record.overdue(now) || self.av_taken(txn.as_mut(), record).await? {
                self.end_reset(record, ResetState::Superseded).await?;
                self.put_reset(txn.as_mut(), record).await?;
                changed = true;
            }
        }
        if changed {
            txn.commit().await?;
        }
        Ok(records)
    }

    // Another certificate applied at the `av` a pending reset proposed: a rotation or a replace by someone holding R,
    // which ends it (0056, Reset).
    async fn av_taken(&self, txn: &mut dyn StateTxn, record: &ResetRecord) -> Result<bool, SyncError> {
        if !record.pending() {
            return Ok(false);
        }
        let id = KeyRecordId::Account {
            account: self.account(),
            av: record.av,
        };
        Ok(
            match self
                .applied_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
                .await?
                .map(|object| object.body)
            {
                Some(KeyBody::Account(body)) => body.ik != record.ik,
                _ => false,
            },
        )
    }

    // A rotation that applies at `av` ends a pending reset that proposed the same `av`: whoever rotated holds R.
    pub(crate) async fn reset_superseded_at(&self, av: Version) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        for mut record in self.reset_records(txn.as_mut()).await? {
            if record.pending() && record.av == av {
                self.end_reset(&mut record, ResetState::Superseded).await?;
                self.put_reset(txn.as_mut(), &record).await?;
            }
        }
        txn.commit().await?;
        Ok(())
    }

    // The proposal: the certificate at `av + 1` under IK' with its kind, the device certificate under the new ASK,
    // and the blob under R'. The account objects come from the one builder every account change set uses.
    pub(super) fn proposal_body(
        &self,
        av: Version,
        kind: ResetKind,
        recovery: &RecoveryKey,
        keys: &AccountKeys,
        device: &DeviceKeys,
    ) -> Result<ResetBody, SyncError> {
        let ik = recovery.identity_seed(self.origin(), self.account())?;
        let objects = self.account_objects(&AccountObjectsPlan {
            av,
            kind: cert_kind(kind),
            ik: &ik,
            endorsing_ik: None,
            recovery,
            keys,
            devices: &[KeptDevice::of(device)?],
            wrapper: None,
        })?;
        let mut account: Option<AccountBody> = None;
        let mut device_body: Option<DeviceBody> = None;
        let mut blob: Option<RecoveryBlob> = None;
        for object in objects {
            match object.body {
                KeyBody::Account(body) => account = Some(body),
                KeyBody::Device(body) => device_body = Some(body),
                KeyBody::Recovery(body) => blob = Some(body),
                _ => {}
            }
        }
        let missing = SyncError::Malformed {
            what: "reset proposal objects",
        };
        Ok(ResetBody {
            av,
            key_device: device.key_device,
            account: account.ok_or(missing.clone())?,
            device: device_body.ok_or(missing.clone())?,
            recovery: blob.ok_or(missing)?,
        })
    }

    // The activation: the proposal's records as it holds them, then the personal and history versions at their next
    // versions with their wraps to the new AEK. Kind 2 carries the keys in force forward with rings; kind 3 starts
    // them over with no ring, and the server deletes the old personal and history records.
    pub(super) async fn activation_objects(
        &self,
        txn: &mut dyn StateTxn,
        record: &ResetRecord,
        body: &ResetBody,
        keys: &AccountKeys,
    ) -> Result<Vec<KeyObject>, SyncError> {
        let mut objects = proposal_objects(self.account(), body);
        let current = match record.kind {
            ResetKind::KeepScopeKeys => self.current_keys(txn).await?,
            ResetKind::StartEmpty => Vec::new(),
        };
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let next = ScopeKey::generate()?;
            let held = current.iter().find(|current| current.purpose == purpose);
            let plan = match held {
                Some(held) => ScopeKeyPlan {
                    version: held.version.next()?,
                    key: &next,
                    start: Start::Next,
                    previous: Some(&held.key),
                },
                None => ScopeKeyPlan {
                    version: self.next_version_number(txn, purpose).await?,
                    key: &next,
                    start: Start::Over,
                    previous: None,
                },
            };
            objects.extend(self.personal_version_objects(purpose, &plan, record.av, keys, record.key_device)?);
        }
        Ok(objects)
    }

    // Versions keep counting after a reset that starts empty (0051, Resets).
    async fn next_version_number(&self, txn: &mut dyn StateTxn, purpose: KeyPurpose) -> Result<Version, SyncError> {
        let account = self.account();
        let highest = self
            .held_objects(txn, ScopeName::Personal, KeyKind::Version)
            .await?
            .iter()
            .filter_map(|held| held.object.version_record().filter(|_| held.applied))
            .filter(|record| record.key.owner == account.0 && record.key.purpose == purpose)
            .map(|record| record.key.version)
            .max();
        Ok(match highest {
            Some(version) => version.next()?,
            None => Version::FIRST,
        })
    }
}
