// The pushes each side of a session makes and the rows it keeps (0056, Approving a device). Each step is written to
// `key_comparisons` once it is taken and before it goes up, so a retry after a timeout sends the same body and never
// draws new randomness for a step already taken.

use std::collections::HashMap;
use std::sync::Arc;

use tablepro_keys::KeysError;
use tablepro_keys::body::{CancelReason, KeyBody, KeyObject, RequestBody, SasBody};
use tablepro_keys::encoding::{KeyDeviceId, RequestId, Version};
use tablepro_keys::keys::DeviceKeys;
use tablepro_keys::record_id::{KeyRecordId, SasStep};
use tablepro_keys::sas::{Comparison, Role, SasDevice};

use super::session::SessionRecord;
use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, ScopeName};
use crate::api::key_flows::{ApprovalSession, KeyState, LockCause, SessionEnd, SessionPhase, SessionRole};
use crate::api::state::{KeyPendingRow, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::{ChangeOutcome, DpopKey, RejectedCode};
use crate::keys::{KeyService, OwnAccount, create_change};

// 600 seconds after the server took the request (0056, Approving a device, step 1).
pub(super) const SESSION_US: i64 = 600 * 1_000_000;

pub(super) fn sas_of(keys: &DeviceKeys) -> Result<SasDevice, SyncError> {
    Ok(SasDevice {
        key_device: keys.key_device,
        dek: keys.dek.public()?,
        dsk: keys.dsk.public()?,
    })
}

pub(super) fn request_object(record: &SessionRecord) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Request {
            request: record.request,
        },
        body: KeyBody::Request(RequestBody {
            key_device: record.n.key_device,
            dek: record.n.dek,
            dsk: record.n.dsk,
            commit: record.commit,
        }),
    }
}

fn sas_object(request: RequestId, step: SasStep, body: SasBody) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Sas { request, step },
        body: KeyBody::Sas(body),
    }
}

pub(super) fn nonce_object(record: &SessionRecord) -> Result<KeyObject, SyncError> {
    let (a, r) = record.a.ok_or(SyncError::Keys(KeysError::Session))?;
    Ok(sas_object(
        record.request,
        SasStep::Nonce,
        SasBody::Nonce {
            key_device: a.key_device,
            dek: a.dek,
            dsk: a.dsk,
            r,
        },
    ))
}

fn reveal_object(record: &SessionRecord) -> Result<KeyObject, SyncError> {
    let r = record.r_n.ok_or(SyncError::Keys(KeysError::Session))?;
    Ok(sas_object(record.request, SasStep::Reveal, SasBody::Reveal { r }))
}

pub(super) const fn cancel_reason(end: SessionEnd) -> CancelReason {
    match end {
        SessionEnd::User => CancelReason::User,
        SessionEnd::Mismatch => CancelReason::Mismatch,
        SessionEnd::Commitment => CancelReason::Commitment,
    }
}

fn cancel_object(record: &SessionRecord, end: SessionEnd) -> KeyObject {
    sas_object(
        record.request,
        SasStep::Cancel,
        SasBody::Cancel {
            reason: cancel_reason(end),
        },
    )
}

// What a change set's answer comes to: applied whole, or the code of the change that refused it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Pushed {
    Applied,
    Refused(RejectedCode),
}

pub(crate) fn pushed(outcomes: &[ChangeOutcome]) -> Result<Pushed, SyncError> {
    let mut refused = None;
    for outcome in outcomes {
        match outcome {
            ChangeOutcome::Applied { .. } => {}
            ChangeOutcome::Rejected { code } if *code == RejectedCode::ChangeSet => {
                refused.get_or_insert(RejectedCode::ChangeSet);
            }
            ChangeOutcome::Rejected { code } => refused = Some(code.clone()),
            // A key kind is create-only, so the service answers `create_only`, never a conflict.
            ChangeOutcome::Conflict { .. } => refused = Some(RejectedCode::CreateOnly),
            ChangeOutcome::Gone | ChangeOutcome::Failed { .. } => {
                return Err(SyncError::Malformed {
                    what: "key change set answer",
                });
            }
        }
    }
    Ok(refused.map_or(Pushed::Applied, Pushed::Refused))
}

impl KeyService {
    // The account as an approved device holds it: approved by its own key tables, with an anchor and no rebuild in
    // progress, since a stale file writes no secret (0054, A stale file). A locked device answers its lock.
    pub(crate) async fn approved_device_account(
        &self,
        txn: &mut dyn StateTxn,
        what: &'static str,
    ) -> Result<OwnAccount, SyncError> {
        match self.state_of_keys(txn).await? {
            KeyState::Approved { .. } => {}
            KeyState::Locked { cause } => return Err(SyncError::Locked { cause }),
            _ => return Err(SyncError::NotAllowed { what }),
        }
        if self.is_rebuilding() {
            return Err(SyncError::NotAllowed { what });
        }
        self.own_account(txn).await?.ok_or(SyncError::NotAllowed { what })
    }

    // A device that is not approved, or locked for a cause another device's approval or R clears. An account that
    // ended signs out first (0051, What cannot go back).
    pub(crate) async fn may_ask_again(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        Ok(match self.state_of_keys(txn).await? {
            KeyState::NeedsApproval { .. } => true,
            KeyState::Locked { cause } => cause != LockCause::AccountEnded,
            KeyState::NoDeviceStore | KeyState::Unknown | KeyState::NoKeys | KeyState::Approved { .. } => false,
        })
    }

    // This device's own request, still open and not past `expires_at`, or one whose revoke is owed: its pending device
    // keys are the request's.
    pub(crate) async fn asking(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        let now = self.now_us();
        Ok(self.session_records(txn).await?.iter().any(|record| {
            record.role == Role::NewDevice && (record.sent.revoke_owed || (record.live() && now < record.expires_at_us))
        }))
    }

    pub(super) async fn revoke_owed(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        Ok(self
            .session_records(txn)
            .await?
            .iter()
            .any(|record| record.sent.revoke_owed))
    }

    // N's own session whose approval merged and whose device key switch is still owed.
    pub(crate) async fn switch_owed(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        Ok(self.session_records(txn).await?.iter().any(|record| {
            record.role == Role::NewDevice
                && record.end == Some(super::session::Ended::Approved)
                && !record.sent.approval
        }))
    }

    // The row that asked for each key device this device approved, from its sessions' rows, which outlive the requests.
    // Only an approval this device made counts: anyone signed in can write a request that names another key device.
    pub(crate) async fn requesting_rows(
        &self,
        txn: &mut dyn StateTxn,
    ) -> Result<HashMap<KeyDeviceId, DeviceRowId>, SyncError> {
        Ok(self
            .session_records(txn)
            .await?
            .into_iter()
            .filter(|record| record.role == Role::Approver && record.end == Some(super::session::Ended::Approved))
            .filter_map(|record| record.device.map(|device| (record.n.key_device, device)))
            .collect())
    }

    pub(super) async fn session_record(
        &self,
        txn: &mut dyn StateTxn,
        request: RequestId,
    ) -> Result<Option<SessionRecord>, SyncError> {
        match txn.get(&RowKey::KeyComparison(request)).await? {
            Some(Row::KeyComparison(row)) => Ok(Some(self.loaded(SessionRecord::from_row(&row)?))),
            _ => Ok(None),
        }
    }

    pub(super) async fn session_records(&self, txn: &mut dyn StateTxn) -> Result<Vec<SessionRecord>, SyncError> {
        txn.scan(&RowRange::Table(Table::KeyComparisons))
            .await?
            .iter()
            .filter_map(|row| match row {
                Row::KeyComparison(row) => Some(SessionRecord::from_row(row).map(|record| self.loaded(record))),
                _ => None,
            })
            .collect()
    }

    // A session read back without the comparison it needs lost r_N, or the comparison that checks it, to a restart.
    // It ends as this side cancelling, so the `cancel` step goes up and N can ask again with a new request, which the
    // server refuses while this one is open (0056, One comparison per session).
    fn loaded(&self, mut record: SessionRecord) -> SessionRecord {
        if record.needs_comparison() && !self.comparisons().contains_key(&record.request) {
            record.cancel(SessionEnd::User).ok();
        }
        record
    }

    pub(super) fn keep_comparison(&self, request: RequestId, comparison: Comparison) {
        self.comparisons().insert(request, comparison);
    }

    // One step through a copy of the session's comparison; a session without one takes no step. The copy takes the
    // kept one's place only once the row it moved committed (`keep_comparison`), so a write that fails leaves the
    // comparison where the row is and the step can be taken again.
    pub(super) fn step_comparison<T>(
        &self,
        record: &mut SessionRecord,
        step: impl FnOnce(&mut SessionRecord, &mut Comparison) -> Result<T, KeysError>,
    ) -> Result<(T, Comparison), KeysError> {
        let mut comparison = self
            .comparisons()
            .get(&record.request)
            .cloned()
            .ok_or(KeysError::Session)?;
        let out = step(record, &mut comparison)?;
        Ok((out, comparison))
    }

    // The row, and the pending flow while the session has a step to send or N has a change set to merge.
    pub(super) async fn put_session(&self, txn: &mut dyn StateTxn, record: &SessionRecord) -> Result<(), SyncError> {
        txn.put(Row::KeyComparison(record.to_row())).await?;
        let flow = PendingFlow::Approval {
            request: record.request,
        };
        let switching = record.role == Role::NewDevice
            && record.end == Some(super::session::Ended::Approved)
            && !record.sent.approval;
        if record.live()
            || switching
            || record.sent.revoke_owed
            || (record.end.is_some() && !record.sent.cancel && cancels(record))
        {
            if txn.get(&RowKey::KeyPending(flow)).await?.is_none() {
                txn.put(Row::KeyPending(KeyPendingRow {
                    flow,
                    state: Vec::new(),
                }))
                .await?;
            }
        } else {
            txn.delete(&RowKey::KeyPending(flow)).await?;
        }
        Ok(())
    }

    pub(super) async fn save_session(&self, record: &SessionRecord) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        self.put_session(txn.as_mut(), record).await?;
        txn.commit().await?;
        self.settle_comparison(record.request, record.needs_comparison());
        Ok(())
    }

    // Once a row committed: a session past its reveal, or ended, needs its comparison no more. Before the commit the
    // row on disk may still need it, so a failed write can take its step again.
    pub(super) fn settle_comparison(&self, request: RequestId, needed: bool) {
        if !needed {
            self.comparisons().remove(&request);
        }
    }

    pub(super) async fn require_session(&self, request: RequestId) -> Result<SessionRecord, SyncError> {
        let mut txn = self.begin().await?;
        let mut record = self
            .session_record(txn.as_mut(), request)
            .await?
            .ok_or(SyncError::Unknown { what: "session" })?;
        if record.expire_if_due(self.now_us()) {
            self.put_session(txn.as_mut(), &record).await?;
            txn.commit().await?;
            self.settle_comparison(record.request, record.needs_comparison());
        }
        Ok(record)
    }

    // N proves with the DSK its request carries, A with the one it is approved under (0051, Whose key the proof
    // carries).
    pub(super) async fn session_proof(&self, record: &SessionRecord) -> Result<DpopKey, SyncError> {
        match record.role {
            Role::Approver => self.dpop_key().await,
            Role::NewDevice => {
                let held = self.device_keys().await?;
                [held.pending, held.current]
                    .into_iter()
                    .flatten()
                    .find(|keys| keys.key_device == record.n.key_device)
                    .map(|keys| DpopKey(Arc::new(keys.dsk.clone())))
                    .ok_or(SyncError::Unknown {
                        what: "the request's device keys",
                    })
            }
        }
    }

    // One step of the session as its own push, held as this device's candidate until it applies.
    pub(super) async fn push_step(&self, record: &SessionRecord, object: &KeyObject) -> Result<Pushed, SyncError> {
        let proof = self.session_proof(record).await?;
        {
            let mut txn = self.begin().await?;
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
            txn.commit().await?;
        }
        let outcomes = self
            .push_change_set(ScopeName::Personal, vec![create_change(object)?], proof)
            .await?;
        let answer = pushed(&outcomes)?;
        let mut txn = self.begin().await?;
        match answer {
            Pushed::Applied => {
                self.hold_object(txn.as_mut(), ScopeName::Personal, object, true)
                    .await?
            }
            Pushed::Refused(_) => {
                self.drop_candidates(txn.as_mut(), ScopeName::Personal, std::slice::from_ref(object))
                    .await?;
            }
        }
        txn.commit().await?;
        Ok(answer)
    }

    pub(super) async fn send_opening(&self, record: &mut SessionRecord) -> Result<(), SyncError> {
        let object = match record.role {
            Role::NewDevice => request_object(record),
            Role::Approver => nonce_object(record)?,
        };
        let answer = self.push_step(record, &object).await;
        let answer = match answer {
            Ok(answer) => answer,
            Err(error) => {
                self.save_session(record).await?;
                return Err(error);
            }
        };
        match answer {
            Pushed::Applied => record.sent.opened = true,
            // Another approver's `nonce` step came first: "being approved on Mac mini".
            Pushed::Refused(RejectedCode::CreateOnly) if record.role == Role::Approver => record.taken_elsewhere(),
            Pushed::Refused(RejectedCode::RequestClosed) => {
                record.cancel(SessionEnd::User).ok();
                record.sent.cancel = true;
            }
            Pushed::Refused(code) => {
                record.cancel(SessionEnd::User).ok();
                record.sent.cancel = true;
                self.save_session(record).await?;
                return Err(SyncError::Rejected { code });
            }
        }
        self.save_session(record).await
    }

    pub(super) async fn send_reveal(&self, record: &mut SessionRecord) -> Result<(), SyncError> {
        // Past the reveal the row holds every input, so the comparison is not needed once it commits.
        if record.state == tablepro_keys::sas::SessionState::Chosen {
            self.step_comparison(record, SessionRecord::reveal)?;
            self.save_session(record).await?;
        }
        match self.push_step(record, &reveal_object(record)?).await? {
            Pushed::Applied => record.sent.reveal = true,
            Pushed::Refused(_) => {
                record.cancel(SessionEnd::User).ok();
                record.sent.cancel = true;
            }
        }
        self.save_session(record).await
    }

    // This side's `cancel` step. A session the server already closed takes none, which is the same end.
    pub(super) async fn send_cancel(&self, record: &mut SessionRecord, end: SessionEnd) -> Result<(), SyncError> {
        match self.push_step(record, &cancel_object(record, end)).await {
            Ok(_) | Err(SyncError::Transport(crate::api::transport::TransportError::DeviceNotApproved)) => {
                record.sent.cancel = true;
            }
            Err(error) => {
                self.save_session(record).await?;
                return Err(error);
            }
        }
        self.save_session(record).await
    }

    pub(super) async fn session_view(&self, record: &mut SessionRecord) -> Result<ApprovalSession, SyncError> {
        let waiting_reveal = record.role == Role::NewDevice
            && record.live()
            && record.state == tablepro_keys::sas::SessionState::Revealed
            && !record.sent.reveal;
        let before = record.state;
        let phase = if waiting_reveal {
            SessionPhase::Chosen
        } else {
            record.phase(self.origin(), self.account())?
        };
        if record.state != before {
            self.save_session(record).await?;
        }
        Ok(ApprovalSession {
            request: record.request,
            role: match record.role {
                Role::NewDevice => SessionRole::NewDevice,
                Role::Approver => SessionRole::Approver,
            },
            phase,
            expires_at_us: record.expires_at_us,
        })
    }

    pub(super) async fn approval_av_failed(
        &self,
        txn: &mut dyn StateTxn,
        request: RequestId,
    ) -> Result<Option<Version>, SyncError> {
        let flow = PendingFlow::Approval { request };
        match txn.get(&RowKey::KeyPending(flow)).await? {
            Some(Row::KeyPending(row)) if row.state.len() == 4 => {
                let mut bytes = [0_u8; 4];
                bytes.copy_from_slice(&row.state);
                Ok(Some(Version::new(u32::from_be_bytes(bytes))?))
            }
            _ => Ok(None),
        }
    }

    // A's approval built at an `av` a rotation then passed: kept so it is built again only at a newer one.
    pub(super) async fn note_approval_av_failed(
        &self,
        txn: &mut dyn StateTxn,
        request: RequestId,
        av: Version,
    ) -> Result<(), SyncError> {
        txn.put(Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::Approval { request },
            state: av.get().to_be_bytes().to_vec(),
        }))
        .await?;
        Ok(())
    }
}

// A side that ended the session itself sends its `cancel` step; one that read the other's does not.
const fn cancels(record: &SessionRecord) -> bool {
    matches!(record.end, Some(super::session::Ended::Cancelled(_)))
}
