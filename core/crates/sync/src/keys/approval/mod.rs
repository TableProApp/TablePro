// `ApprovalFlows` (0056, Approving a device): N commits to its view, A's create-only `nonce` step holds the session,
// both sides show five words from their own view, and A's approval change set reaches N only under the DSK and IK the
// words covered.

mod change_set;
mod confirm;
mod merge;
#[cfg(test)]
mod merge_tests;
mod objects;
mod session;
mod steps;
#[cfg(test)]
mod vector_tests;

use async_trait::async_trait;
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{RequestId, random_uuid};
use tablepro_keys::keys::DeviceKeys;
use tablepro_keys::sas::{Role, SessionState};

use self::session::{SessionRecord, transcript};
pub(crate) use self::steps::{Pushed, pushed};
use self::steps::{SESSION_US, random32, sas_of};
use super::{HeldDeviceKeys, KeyService};
use crate::api::error::SyncError;
use crate::api::key_flows::{ApprovalFlows, ApprovalRequest, ApprovalSession, KeyApplied, KeyArrival, SessionEnd};
use crate::api::transport::{RejectedCode, TransportError};

#[async_trait]
impl ApprovalFlows for KeyService {
    async fn request_approval(&self) -> Result<RequestId, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        // A locked device asks again: left out, stopped on its personal key, its own account reset or its anchor lost.
        if !self.may_ask_again(txn.as_mut()).await? {
            return Err(SyncError::NotAllowed {
                what: "ask for approval",
            });
        }
        let now = self.now_us();
        for mut record in self.session_records(txn.as_mut()).await? {
            if record.role == Role::NewDevice && record.live() && !record.expire_if_due(now) {
                return Err(SyncError::Rejected {
                    code: RejectedCode::RequestPending,
                });
            }
        }
        let certificate = self.newest_own_certificate(txn.as_mut()).await?;
        drop(txn);
        // Every approval takes new device keys and a new key device id; the old ones stay until it applies.
        let device = DeviceKeys::generate()?;
        let held = self.device_keys().await?;
        self.store_device_keys(&HeldDeviceKeys {
            current: held.current,
            pending: Some(device.clone()),
        })
        .await?;
        let request = RequestId(random_uuid()?);
        let mut record = SessionRecord::new_device(
            transcript(self.origin(), self.account(), request, certificate.ik),
            sas_of(&device)?,
            random32()?,
            now,
            now + SESSION_US,
        )?;
        self.save_session(&record).await?;
        match self.send_opening(&mut record).await {
            // The request is held and goes up again on the next pass, with the same body.
            Err(SyncError::Transport(error)) if transient(&error) => self.hooks().pass_soon(),
            other => other?,
        }
        Ok(request)
    }

    async fn approval_requests(&self) -> Result<Vec<ApprovalRequest>, SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        self.approved_device_account(txn.as_mut(), "approve a device").await?;
        let now = self.now_us();
        let mut requests: Vec<ApprovalRequest> = self
            .session_records(txn.as_mut())
            .await?
            .into_iter()
            .filter(|record| {
                record.role == Role::Approver
                    && record.live()
                    && record.state == SessionState::Open
                    && now < record.expires_at_us
            })
            .map(|record| ApprovalRequest {
                request: record.request,
                device: record.device,
                device_name: None,
                platform: None,
                requested_at_us: record.requested_at_us,
            })
            .collect();
        requests.sort_by_key(|request| std::cmp::Reverse(request.requested_at_us));
        Ok(requests)
    }

    async fn choose_request(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let own = {
            let mut txn = self.begin().await?;
            self.approved_device_account(txn.as_mut(), "approve a device").await?
        };
        let mut record = self.require_session(request).await?;
        if record.role != Role::Approver {
            return Err(KeysError::Session.into());
        }
        // A fixes its view with its own account's IK as it stands when the person picks the request.
        record.ik = own.ik;
        record.choose(sas_of(&own.device)?, random32()?)?;
        self.save_session(&record).await?;
        self.send_opening(&mut record).await?;
        self.session_view(&mut record).await
    }

    async fn approval_session(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let _serial = self.serialized().await;
        let mut record = self.require_session(request).await?;
        self.drive(&mut record).await?;
        if record.live() {
            self.hooks().pass_soon();
        }
        self.session_view(&mut record).await
    }

    async fn confirm_session(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let _serial = self.serialized().await;
        let mut record = self.require_session(request).await?;
        record.confirm(self.origin(), self.account())?;
        self.save_session(&record).await?;
        self.drive(&mut record).await?;
        self.session_view(&mut record).await
    }

    async fn words_differ(&self, request: RequestId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        let mut record = self.require_session(request).await?;
        let error = record.words_differ(self.origin(), self.account());
        if error != KeysError::SasMismatch {
            return Err(error.into());
        }
        self.save_session(&record).await?;
        self.send_cancel(&mut record, SessionEnd::Mismatch).await
    }

    async fn cancel_session(&self, request: RequestId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        let mut record = self.require_session(request).await?;
        record.cancel(SessionEnd::User)?;
        self.save_session(&record).await?;
        self.send_cancel(&mut record, SessionEnd::User).await
    }

    async fn apply_session_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        self.apply_sessions(arrival).await
    }

    async fn resume_approval(&self, request: RequestId) -> Result<(), SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        let Some(mut record) = self.session_record(txn.as_mut(), request).await? else {
            txn.delete(&crate::api::state::RowKey::KeyPending(
                crate::api::state::PendingFlow::Approval { request },
            ))
            .await?;
            txn.commit().await?;
            return Ok(());
        };
        drop(txn);
        if record.expire_if_due(self.now_us()) {
            self.save_session(&record).await?;
        }
        self.drive(&mut record).await
    }
}

// A failure the next pass retries: the step stays held as it was built.
pub(crate) const fn transient(error: &TransportError) -> bool {
    matches!(
        error,
        TransportError::Network { .. }
            | TransportError::RateLimited { .. }
            | TransportError::RestoreCheckUnavailable { .. }
            | TransportError::IdempotencyInProgress
            | TransportError::UseDpopNonce
    )
}

impl KeyService {
    // Sends whatever step this side owes, once: N's request and reveal, A's `nonce` and approval change set, a
    // `cancel` this side decided; and N merges an approval that arrived after its person confirmed.
    async fn drive(&self, record: &mut SessionRecord) -> Result<(), SyncError> {
        if let Some(self::session::Ended::Cancelled(end)) = record.end {
            if !record.sent.cancel {
                self.send_cancel(record, end).await?;
            }
            return Ok(());
        }
        if record.role == Role::NewDevice && record.end == Some(self::session::Ended::Approved) && !record.sent.approval
        {
            return self.finish_switch(record).await;
        }
        if !record.live() {
            return self.save_session(record).await;
        }
        if !record.sent.opened && (record.role == Role::NewDevice || record.state != SessionState::Open) {
            return self.send_opening(record).await;
        }
        match (record.role, record.state) {
            (Role::NewDevice, SessionState::Chosen | SessionState::Revealed) if !record.sent.reveal => {
                self.send_reveal(record).await
            }
            (Role::NewDevice, SessionState::Confirmed) => {
                if !self.try_merge(record).await? && record.sent.purged {
                    record.purged_unapproved();
                    self.save_session(record).await?;
                }
                Ok(())
            }
            (Role::Approver, SessionState::Confirmed) if !record.sent.approval => self.send_approval(record).await,
            _ => Ok(()),
        }
    }
}
