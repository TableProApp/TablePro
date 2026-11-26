// The pushes each side of a session makes and the rows it keeps (0056, Approving a device). Each step is written to
// `key_comparisons` before it goes up, so a retry after a crash or a timeout sends the same body and never draws new
// randomness for a step already taken.

use std::sync::Arc;

use tablepro_keys::KeysError;
use tablepro_keys::body::{CancelReason, KeyBody, KeyObject, RequestBody, SasBody};
use tablepro_keys::encoding::{RequestId, Version};
use tablepro_keys::keys::DeviceKeys;
use tablepro_keys::record_id::{KeyRecordId, SasStep};
use tablepro_keys::sas::{Role, SasDevice};

use super::session::SessionRecord;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{ApprovalSession, KeyState, LockCause, SessionEnd, SessionPhase, SessionRole};
use crate::api::state::{KeyPendingRow, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::{ChangeOutcome, DpopKey, RejectedCode};
use crate::keys::{KeyService, OwnAccount, create_change};

// 600 seconds after the server took the request (0056, Approving a device, step 1).
pub(super) const SESSION_US: i64 = 600 * 1_000_000;

pub(super) fn random32() -> Result<[u8; 32], SyncError> {
    let mut bytes = [0_u8; 32];
    aws_lc_rs::rand::fill(&mut bytes).map_err(|_| SyncError::Keys(KeysError::Random))?;
    Ok(bytes)
}

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

    // N's own session whose approval merged and whose device key switch is still owed.
    pub(super) async fn switch_owed(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        Ok(self.session_records(txn).await?.iter().any(|record| {
            record.role == Role::NewDevice
                && record.end == Some(super::session::Ended::Approved)
                && !record.sent.approval
        }))
    }

    pub(super) async fn session_record(
        &self,
        txn: &mut dyn StateTxn,
        request: RequestId,
    ) -> Result<Option<SessionRecord>, SyncError> {
        match txn.get(&RowKey::KeyComparison(request)).await? {
            Some(Row::KeyComparison(row)) => SessionRecord::from_row(&row).map(Some),
            _ => Ok(None),
        }
    }

    pub(super) async fn session_records(&self, txn: &mut dyn StateTxn) -> Result<Vec<SessionRecord>, SyncError> {
        txn.scan(&RowRange::Table(Table::KeyComparisons))
            .await?
            .iter()
            .filter_map(|row| match row {
                Row::KeyComparison(row) => Some(SessionRecord::from_row(row)),
                _ => None,
            })
            .collect()
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
        if record.live() || switching || (record.end.is_some() && !record.sent.cancel && cancels(record)) {
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
        Ok(())
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
        if record.state == tablepro_keys::sas::SessionState::Chosen {
            record.reveal(self.origin(), self.account())?;
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

    pub(super) async fn approval_av_failed(&self, request: RequestId) -> Result<Option<Version>, SyncError> {
        let mut txn = self.begin().await?;
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
    pub(super) async fn note_approval_av_failed(&self, request: RequestId, av: Version) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        txn.put(Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::Approval { request },
            state: av.get().to_be_bytes().to_vec(),
        }))
        .await?;
        txn.commit().await?;
        Ok(())
    }
}

// A side that ended the session itself sends its `cancel` step; one that read the other's does not.
const fn cancels(record: &SessionRecord) -> bool {
    matches!(record.end, Some(super::session::Ended::Cancelled(_)))
}
