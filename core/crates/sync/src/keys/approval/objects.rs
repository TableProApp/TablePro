// `key.request` and `key.sas` records as a pull serves them, in revision order (0056, Approving a device, The
// session). A refused step is reported with its code and changes nothing; the session ends only as the steps say.

use tablepro_keys::KeysError;
use tablepro_keys::body::{CancelReason, KeyBody, KeyObject, SasBody};
use tablepro_keys::encoding::RequestId;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::sas::{Role, SasDevice, SessionState};

use super::session::SessionRecord;
use super::steps::SESSION_US;
use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::key_flows::{KeyApplied, KeyArrival, RefusedObject, SessionEnd};
use crate::api::state::{PendingFlow, RowKey, StateTxn};
use crate::api::transport::PulledRecord;
use crate::keys::{KeyService, OwnAccount};

const fn session_end(reason: CancelReason) -> SessionEnd {
    match reason {
        CancelReason::User => SessionEnd::User,
        CancelReason::Mismatch => SessionEnd::Mismatch,
        CancelReason::Commitment => SessionEnd::Commitment,
    }
}

fn request_of(record: &PulledRecord) -> Option<RequestId> {
    let kind = KeyKind::parse(record.kind.as_str()).ok()?;
    match KeyRecordId::parse(kind, &record.record_id).ok()? {
        KeyRecordId::Request { request } | KeyRecordId::Sas { request, .. } => Some(request),
        _ => None,
    }
}

impl KeyService {
    pub(super) async fn apply_sessions(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _serial = self.serialized().await;
        let mut applied = KeyApplied::default();
        if arrival.scope != ScopeName::Personal {
            return Ok(applied);
        }
        let mut txn = self.begin().await?;
        let own = self.own_account(txn.as_mut()).await?;
        let mut drive = false;
        for record in &arrival.records {
            let (moved, refused) = match self.apply_session_record(txn.as_mut(), own.as_ref(), record).await {
                Ok(step) => step,
                Err(SyncError::Keys(error)) => (false, Some(error)),
                Err(error) => return Err(error),
            };
            drive |= moved;
            if let Some(error) = refused {
                applied.refused.push(RefusedObject {
                    record_id: record.record_id.clone(),
                    error,
                });
            }
        }
        txn.commit().await?;
        if drive {
            self.hooks().pass_soon();
        }
        Ok(applied)
    }

    // Whether the session moved so this side has a step to send, and the step's refusal. A refused step still
    // leaves the session as it ended, as a reveal that does not open the commitment does.
    async fn apply_session_record(
        &self,
        txn: &mut dyn StateTxn,
        own: Option<&OwnAccount>,
        pulled: &PulledRecord,
    ) -> Result<(bool, Option<KeysError>), SyncError> {
        let Some(request) = request_of(pulled) else {
            return Ok((false, None));
        };
        let Some(fields) = pulled.fields_json.as_deref().filter(|_| pulled.deleted.is_none()) else {
            self.purge(txn, request, pulled).await?;
            return Ok((false, None));
        };
        let object = KeyObject::parse(pulled.kind.as_str(), &pulled.record_id, fields.as_bytes())?;
        self.hold_object(txn, ScopeName::Personal, &object, true).await?;
        let mut record = self.session_record(txn, request).await?;
        let moved = match (&object.body, record.as_mut()) {
            (KeyBody::Request(body), None) => {
                let Some(own) = own.filter(|own| own.device.key_device != body.key_device) else {
                    return Ok((false, None));
                };
                let service = pulled.service.as_ref();
                let taken_at_us = service.map_or_else(|| self.now_us(), |meta| meta.taken_at_us);
                let n = SasDevice {
                    key_device: body.key_device,
                    dek: body.dek,
                    dsk: body.dsk,
                };
                let seen = SessionRecord::seen_request(
                    request,
                    own.ik,
                    n,
                    body.commit,
                    taken_at_us,
                    service
                        .and_then(|meta| meta.expires_at_us)
                        .unwrap_or(taken_at_us + SESSION_US),
                    service.and_then(|meta| meta.updated_device.clone()),
                );
                record = Some(seen);
                Ok(false)
            }
            (KeyBody::Request(body), Some(held)) => {
                if held.role == Role::NewDevice && body.commit == held.commit {
                    held.sent.opened = true;
                    if let Some(expires) = pulled.service.as_ref().and_then(|meta| meta.expires_at_us) {
                        held.expires_at_us = expires;
                    }
                }
                Ok(false)
            }
            (KeyBody::Sas(step), Some(held)) => self.apply_step(held, own, step),
            _ => Ok(false),
        };
        if let Some(record) = record.as_mut() {
            record.expire_if_due(self.now_us());
            self.put_session(txn, record).await?;
        }
        match moved {
            Ok(moved) => Ok((moved, None)),
            Err(KeysError::Commitment) => Ok((true, Some(KeysError::Commitment))),
            Err(error) => Ok((false, Some(error))),
        }
    }

    fn apply_step(
        &self,
        held: &mut SessionRecord,
        own: Option<&OwnAccount>,
        step: &SasBody,
    ) -> Result<bool, KeysError> {
        match (held.role, step) {
            (
                Role::NewDevice,
                SasBody::Nonce {
                    key_device,
                    dek,
                    dsk,
                    r,
                },
            ) => {
                let a = SasDevice {
                    key_device: *key_device,
                    dek: *dek,
                    dsk: *dsk,
                };
                if held.a == Some((a, *r)) {
                    return Ok(false);
                }
                self.with_comparison(held, |held, comparison| held.receive_nonce(comparison, a, *r))?;
                Ok(true)
            }
            (Role::Approver, SasBody::Nonce { key_device, r, .. }) => {
                let mine = held.a.is_some_and(|(a, r_a)| a.key_device == *key_device && r_a == *r)
                    && own.is_some_and(|own| own.device.key_device == *key_device);
                if !mine {
                    held.taken_elsewhere();
                }
                Ok(false)
            }
            (Role::Approver, SasBody::Reveal { r }) => {
                if held.r_n == Some(*r) {
                    return Ok(false);
                }
                // A reveal that does not open the commitment ends the session; this side sends its `cancel` with that
                // reason.
                self.with_comparison(held, |held, comparison| held.receive_reveal(comparison, *r))
                    .map(|()| false)
            }
            (Role::NewDevice, SasBody::Reveal { .. }) => Ok(false),
            (_, SasBody::Cancel { reason }) => {
                if held.live() {
                    held.cancel(session_end(*reason))?;
                    held.sent.cancel = true;
                }
                Ok(false)
            }
        }
    }

    // The server purges a request and its steps once the session ends. Its row goes with it; one still live ended
    // without this side seeing why, so it ends as expired.
    async fn purge(&self, txn: &mut dyn StateTxn, request: RequestId, pulled: &PulledRecord) -> Result<(), SyncError> {
        txn.delete(&RowKey::KeyObject(
            ScopeName::Personal,
            KindName::parse(pulled.kind.as_str())?,
            pulled.record_id.clone(),
        ))
        .await?;
        let is_request = KeyKind::parse(pulled.kind.as_str()) == Ok(KeyKind::Request);
        if is_request && let Some(mut record) = self.session_record(txn, request).await? {
            // N waiting for its approval, or with its device key switch still owed, keeps its row.
            let pending_merge = record.role == Role::NewDevice
                && ((record.live() && record.state == SessionState::Confirmed)
                    || (record.end == Some(super::session::Ended::Approved) && !record.sent.approval));
            if pending_merge {
                record.sent.purged = true;
                self.put_session(txn, &record).await?;
                self.hooks().pass_soon();
            } else {
                txn.delete(&RowKey::KeyComparison(request)).await?;
                txn.delete(&RowKey::KeyPending(PendingFlow::Approval { request }))
                    .await?;
            }
        }
        Ok(())
    }
}
