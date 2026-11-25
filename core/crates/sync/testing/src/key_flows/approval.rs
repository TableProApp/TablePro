use async_trait::async_trait;
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{RequestId, random_uuid};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{
    ApprovalFlows, ApprovalRequest, ApprovalSession, KeyApplied, KeyArrival, KeyState, SessionEnd, SessionPhase,
    SessionRole,
};
use tablepro_sync::api::transport::RejectedCode;

use super::{FakeKeyFlows, Model, SESSION_US, Session, account::sas_words, require_approved};

// A session that ended takes no step (0056, The session).
fn ended(phase: &SessionPhase) -> bool {
    matches!(
        phase,
        SessionPhase::Approved | SessionPhase::Cancelled { .. } | SessionPhase::Expired | SessionPhase::TakenElsewhere
    )
}

fn live(model: &mut Model, request: RequestId) -> Result<&mut Session, SyncError> {
    let now = model.clock_us;
    let session = model
        .sessions
        .get_mut(&request)
        .ok_or(SyncError::Unknown { what: "session" })?;
    if now >= session.expires_at_us && !ended(&session.phase) {
        session.phase = SessionPhase::Expired;
    }
    if ended(&session.phase) {
        return Err(SyncError::Keys(KeysError::Session));
    }
    Ok(session)
}

fn view(request: RequestId, session: &Session) -> ApprovalSession {
    ApprovalSession {
        request,
        role: session.role,
        phase: session.phase.clone(),
        expires_at_us: session.expires_at_us,
    }
}

#[async_trait]
impl ApprovalFlows for FakeKeyFlows {
    async fn request_approval(&self) -> Result<RequestId, SyncError> {
        let mut model = self.lock();
        if !matches!(model.key_state, KeyState::NeedsApproval { .. }) {
            return Err(SyncError::NotAllowed {
                what: "ask for approval",
            });
        }
        if model
            .sessions
            .values()
            .any(|session| session.role == SessionRole::NewDevice && !ended(&session.phase))
        {
            return Err(SyncError::Rejected {
                code: RejectedCode::RequestPending,
            });
        }
        let request = RequestId(random_uuid()?);
        let expires_at_us = model.clock_us + SESSION_US;
        model.sessions.insert(
            request,
            Session {
                role: SessionRole::NewDevice,
                phase: SessionPhase::Open,
                expires_at_us,
            },
        );
        model.key_state = KeyState::NeedsApproval { request: Some(request) };
        Ok(request)
    }

    async fn approval_requests(&self) -> Result<Vec<ApprovalRequest>, SyncError> {
        let model = self.lock();
        require_approved(&model, "approve a device")?;
        let open = |request: &&ApprovalRequest| {
            model
                .sessions
                .get(&request.request)
                .is_some_and(|session| session.phase == SessionPhase::Open && model.clock_us < session.expires_at_us)
        };
        let mut requests: Vec<ApprovalRequest> = model.incoming.iter().filter(open).cloned().collect();
        requests.sort_by_key(|request| std::cmp::Reverse(request.requested_at_us));
        Ok(requests)
    }

    async fn choose_request(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let mut model = self.lock();
        require_approved(&model, "approve a device")?;
        let taken = model.taken_elsewhere.contains(&request);
        let session = live(&mut model, request)?;
        if session.phase != SessionPhase::Open {
            return Err(SyncError::Keys(KeysError::Session));
        }
        // N's reveal follows the `nonce` step at once here.
        session.phase = if taken {
            SessionPhase::TakenElsewhere
        } else {
            SessionPhase::Compare { words: sas_words() }
        };
        Ok(view(request, session))
    }

    async fn approval_session(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let mut model = self.lock();
        let _ = live(&mut model, request);
        let session = model
            .sessions
            .get(&request)
            .ok_or(SyncError::Unknown { what: "session" })?;
        Ok(view(request, session))
    }

    async fn confirm_session(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let mut model = self.lock();
        let session = live(&mut model, request)?;
        if !matches!(session.phase, SessionPhase::Compare { .. }) {
            return Err(SyncError::Keys(KeysError::Session));
        }
        // The other side confirms at once here: A's change set applies and N merges it.
        session.phase = SessionPhase::Approved;
        let role = session.role;
        let answer = view(request, session);
        if role == SessionRole::NewDevice {
            self.approve(&mut model)?;
        }
        Ok(answer)
    }

    async fn words_differ(&self, request: RequestId) -> Result<(), SyncError> {
        let mut model = self.lock();
        let session = live(&mut model, request)?;
        session.phase = SessionPhase::Cancelled {
            reason: SessionEnd::Mismatch,
        };
        Ok(())
    }

    async fn cancel_session(&self, request: RequestId) -> Result<(), SyncError> {
        let mut model = self.lock();
        let session = live(&mut model, request)?;
        session.phase = SessionPhase::Cancelled {
            reason: SessionEnd::User,
        };
        Ok(())
    }

    async fn apply_session_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        Ok(self.applied())
    }

    async fn resume_approval(&self, request: RequestId) -> Result<(), SyncError> {
        let _ = request;
        Ok(())
    }
}
