// `key.reset` and `key.cancel` records as a pull serves them (0051, Resets). The server tombstones a `key.reset` when
// it ends; the device reads why from what it holds: a cancel for it, its activation at its `av`, or neither.

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject, check_same_object};
use tablepro_keys::encoding::ResetId;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};

use super::record::{HOLD_US, ResetRecord};
use super::steps::check_proposal;
use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::key_flows::{KeyApplied, KeyArrival, KeyNoticeKind, RefusedObject, ResetState};
use crate::api::state::{RowKey, StateTxn};
use crate::api::transport::PulledRecord;
use crate::keys::KeyService;

fn reset_of(record: &PulledRecord) -> Option<(KeyKind, ResetId)> {
    let kind = KeyKind::parse(record.kind.as_str()).ok()?;
    match KeyRecordId::parse(kind, &record.record_id).ok()? {
        KeyRecordId::Reset { reset, .. } | KeyRecordId::Cancel { reset, .. } => Some((kind, reset)),
        _ => None,
    }
}

impl KeyService {
    pub(super) async fn apply_resets(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let mut applied = KeyApplied::default();
        if arrival.scope != ScopeName::Personal {
            return Ok(applied);
        }
        let mut txn = self.begin().await?;
        let mut adopt = Vec::new();
        for pulled in &arrival.records {
            match self.apply_reset_record(txn.as_mut(), pulled).await {
                Ok(Some(reset)) => adopt.push(reset),
                Ok(None) => {}
                Err(SyncError::Keys(error)) => applied.refused.push(RefusedObject {
                    record_id: pulled.record_id.clone(),
                    error,
                }),
                Err(error) => return Err(error),
            }
        }
        txn.commit().await?;
        for reset in adopt {
            self.adopt_own_activation(reset).await?;
        }
        Ok(applied)
    }

    // Some reset when it is this device's own and its activation applied, which it then adopts.
    async fn apply_reset_record(
        &self,
        txn: &mut dyn StateTxn,
        pulled: &PulledRecord,
    ) -> Result<Option<ResetId>, SyncError> {
        let Some((kind, reset)) = reset_of(pulled) else {
            return Ok(None);
        };
        let Some(fields) = pulled.fields_json.as_deref().filter(|_| pulled.deleted.is_none()) else {
            if kind == KeyKind::Reset {
                return self.reset_tombstoned(txn, reset, pulled).await;
            }
            return Ok(None);
        };
        let object = KeyObject::parse(pulled.kind.as_str(), &pulled.record_id, fields.as_bytes())?;
        match &object.body {
            KeyBody::Reset(body) => {
                let (certificate, reset_kind) = check_proposal(self, self.account(), body)?;
                self.hold_object(txn, ScopeName::Personal, &object, true).await?;
                let meta = pulled.service.as_ref();
                let taken_at_us = meta.map_or_else(|| self.now_us(), |meta| meta.taken_at_us);
                let held_until_us = meta
                    .and_then(|meta| meta.held_until_us)
                    .unwrap_or(taken_at_us + HOLD_US);
                let record = match self.reset_record(txn, reset).await? {
                    Some(mut record) => {
                        record.sent = record.sent || record.mine;
                        record.taken_at_us = taken_at_us;
                        record.held_until_us = held_until_us;
                        record
                    }
                    None => {
                        let mine = self.reset_keys(reset).await?.is_some();
                        if !mine {
                            self.raise_notice(KeyNoticeKind::ResetPending { reset })?;
                        }
                        ResetRecord {
                            reset,
                            mine,
                            sent: mine,
                            kind: reset_kind,
                            av: body.av,
                            ik: certificate.ik,
                            key_device: body.key_device,
                            state: ResetState::Pending,
                            taken_at_us,
                            held_until_us,
                            proposed_by: meta.and_then(|meta| meta.updated_device.clone()),
                            published: Vec::new(),
                        }
                    }
                };
                self.put_reset(txn, &record).await?;
                Ok(None)
            }
            KeyBody::Cancel { .. } => {
                self.hold_object(txn, ScopeName::Personal, &object, true).await?;
                if let Some(mut record) = self.reset_record(txn, reset).await? {
                    self.end_reset(&mut record, ResetState::Cancelled).await?;
                    self.put_reset(txn, &record).await?;
                }
                Ok(None)
            }
            _ => Err(KeysError::Encoding {
                what: "not a reset or cancel body",
            }
            .into()),
        }
    }

    // Ended: cancelled when the device holds a cancel for it, active when its activation applied at its `av` with the
    // proposal's certificate, superseded otherwise. The `key.reset` row goes with its tombstone.
    async fn reset_tombstoned(
        &self,
        txn: &mut dyn StateTxn,
        reset: ResetId,
        pulled: &PulledRecord,
    ) -> Result<Option<ResetId>, SyncError> {
        let account = self.account();
        let reset_id = KeyRecordId::Reset { account, reset }.to_wire();
        let proposal = self
            .held_object(txn, ScopeName::Personal, KeyKind::Reset, &reset_id)
            .await?;
        txn.delete(&RowKey::KeyObject(
            ScopeName::Personal,
            KindName::parse(pulled.kind.as_str())?,
            pulled.record_id.clone(),
        ))
        .await?;
        let Some(mut record) = self.reset_record(txn, reset).await? else {
            return Ok(None);
        };
        let cancel_id = KeyRecordId::Cancel { account, reset }.to_wire();
        let cancelled = self
            .held_object(txn, ScopeName::Personal, KeyKind::Cancel, &cancel_id)
            .await?
            .is_some_and(|held| held.applied);
        let account_id = KeyRecordId::Account { account, av: record.av }.to_wire();
        let activated = match (
            proposal,
            self.held_object(txn, ScopeName::Personal, KeyKind::Account, &account_id)
                .await?,
        ) {
            (Some(proposal), Some(held)) if held.applied => match proposal.object.body {
                KeyBody::Reset(body) => {
                    let proposed = tablepro_keys::body::body_json(&KeyBody::Account(body.account.clone()));
                    check_same_object(
                        "key.account",
                        &account_id,
                        proposed.as_bytes(),
                        "key.account",
                        &account_id,
                        held.fields.as_bytes(),
                    )
                    .is_ok()
                }
                _ => false,
            },
            _ => false,
        };
        if activated && record.mine && record.pending() {
            return Ok(Some(reset));
        }
        let state = if cancelled {
            ResetState::Cancelled
        } else if activated {
            ResetState::Active
        } else {
            ResetState::Superseded
        };
        self.end_reset(&mut record, state).await?;
        self.put_reset(txn, &record).await?;
        Ok(None)
    }
}
