// `key.reset` and `key.cancel` records as a pull serves them (0051, Resets). The server tombstones a `key.reset` when
// it ends; the device reads why from what it holds: a cancel for it, its activation at its `av`, or neither. Another
// device's reset stays in `key_objects` as served, its served times beside it in memory (0064).

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject, check_same_object};
use tablepro_keys::encoding::ResetId;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};

use super::record::HOLD_US;
use super::steps::{check_proposal, proposal_digest};
use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::key_flows::{
    KeyApplied, KeyArrival, KeyNoticeKind, PendingReset, RefusedObject, ResetKind, ResetState,
};
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
                let (_, reset_kind) = check_proposal(self, self.account(), body)?;
                let meta = pulled.service.as_ref();
                let taken_at_us = meta.map_or_else(|| self.now_us(), |meta| meta.taken_at_us);
                let held_until_us = meta
                    .and_then(|meta| meta.held_until_us)
                    .unwrap_or(taken_at_us + HOLD_US);
                if let Some(mut record) = self.reset_record(txn, reset).await? {
                    // This device's own: only the proposal it wrote stands at its id, and a server may lengthen the
                    // wait but never shorten it.
                    if proposal_digest(&object) != record.proposal {
                        self.raise_notice(KeyNoticeKind::Conflict {
                            scope: ScopeName::Personal,
                        })?;
                        return Err(KeysError::Conflict.into());
                    }
                    self.hold_served(txn, ScopeName::Personal, &object, pulled).await?;
                    record.sent = true;
                    record.taken_at_us = taken_at_us;
                    record.held_until_us = record.held_until_us.max(held_until_us);
                    self.put_reset(txn, &record).await?;
                    return Ok(None);
                }
                let fresh = self
                    .held_object(txn, ScopeName::Personal, KeyKind::Reset, &object.id.to_wire())
                    .await?
                    .is_none();
                self.hold_served(txn, ScopeName::Personal, &object, pulled).await?;
                self.served_resets().insert(
                    reset,
                    PendingReset {
                        reset,
                        kind: reset_kind,
                        state: ResetState::Pending,
                        mine: false,
                        proposed_by: meta.and_then(|meta| meta.updated_device.clone()),
                        taken_at_us,
                        held_until_us,
                    },
                );
                if fresh {
                    self.raise_notice(KeyNoticeKind::ResetPending { reset })?;
                }
                Ok(None)
            }
            KeyBody::Cancel { .. } => {
                self.hold_served(txn, ScopeName::Personal, &object, pulled).await?;
                if let Some(mut record) = self.reset_record(txn, reset).await? {
                    self.end_reset(txn, &mut record, ResetState::Cancelled).await?;
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

    // Ended: cancelled when the device holds a cancel for it, active when its activation applied at its `av`,
    // superseded otherwise. This device's own reset is judged by the keys it proposed, never by what the server serves
    // as its proposal; another device's by its proposal's certificate standing at that `av`. The `key.reset` row goes
    // with its tombstone.
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
        let cancel_id = KeyRecordId::Cancel { account, reset }.to_wire();
        let cancelled = self
            .held_object(txn, ScopeName::Personal, KeyKind::Cancel, &cancel_id)
            .await?
            .is_some_and(|held| held.applied);
        if let Some(mut record) = self.reset_record(txn, reset).await? {
            // A write's records come in no set order, so the activation's versions may follow its tombstone: only a
            // cancel or another certificate verified at its `av` ends this device's own reset here, and an overdue
            // one ends when the wait is past (0051, Resets).
            if self.activation_present(txn, &record).await? {
                return Ok((record.pending() && self.now_us() >= record.held_until_us).then_some(reset));
            }
            let state = if cancelled {
                ResetState::Cancelled
            } else if self.av_taken(txn, record.av, &record.ik).await? {
                ResetState::Superseded
            } else {
                return Ok(None);
            };
            self.end_reset(txn, &mut record, state).await?;
            self.put_reset(txn, &record).await?;
            return Ok(None);
        }
        let Some(KeyBody::Reset(body)) = proposal.map(|held| held.object.body) else {
            return Ok(None);
        };
        let account_id = KeyRecordId::Account { account, av: body.av }.to_wire();
        let activated = match self
            .held_object(txn, ScopeName::Personal, KeyKind::Account, &account_id)
            .await?
        {
            Some(held) if held.applied => {
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
        };
        let state = if cancelled {
            ResetState::Cancelled
        } else if activated {
            ResetState::Active
        } else {
            ResetState::Superseded
        };
        let Ok((_, kind)) = check_proposal(self, account, &body) else {
            return Ok(None);
        };
        self.end_others(reset, kind, state)?;
        Ok(None)
    }

    // Another device's reset this device cancelled, before the tombstone that follows arrives.
    pub(super) async fn others_ended(
        &self,
        txn: &mut dyn StateTxn,
        reset: ResetId,
        state: ResetState,
    ) -> Result<(), SyncError> {
        let id = KeyRecordId::Reset {
            account: self.account(),
            reset,
        };
        if let Some(KeyBody::Reset(body)) = self
            .applied_object(txn, ScopeName::Personal, KeyKind::Reset, &id.to_wire())
            .await?
            .map(|object| object.body)
            && let Ok((_, kind)) = check_proposal(self, self.account(), &body)
        {
            self.end_others(reset, kind, state)?;
        }
        Ok(())
    }

    // The served view of another device's reset ends once, with its notice.
    fn end_others(&self, reset: ResetId, kind: ResetKind, state: ResetState) -> Result<(), SyncError> {
        let ended = {
            let mut served = self.served_resets();
            let view = served.entry(reset).or_insert(PendingReset {
                reset,
                kind,
                state: ResetState::Pending,
                mine: false,
                proposed_by: None,
                taken_at_us: 0,
                held_until_us: 0,
            });
            let pending = view.state == ResetState::Pending;
            if pending {
                view.state = state;
            }
            pending
        };
        if ended {
            self.raise_notice(KeyNoticeKind::ResetEnded { reset, state })?;
        }
        Ok(())
    }
}
