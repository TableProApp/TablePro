use async_trait::async_trait;
use tablepro_keys::encoding::{ResetId, random_uuid};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{
    CancelWith, DraftId, KeyApplied, KeyArrival, KeyNoticeKind, KeyState, PendingReset, RecoveryKeyDraft, ResetFlows,
    ResetKind, ResetState, TypedBack,
};
use tablepro_sync::api::transport::{RejectedCode, StepUpChallenge, TransportError};

use super::{
    DraftPurpose, FakeKeyFlows, Model, RESET_HOLD_US, account::notice, check_typed_back, new_draft, same_recovery_key,
};

fn rejected(code: RejectedCode) -> SyncError {
    SyncError::Rejected { code }
}

// Seven days past `held_until` with no activation, the server ends it (0051, Resets).
fn settle(model: &mut Model) {
    let now = model.clock_us;
    let ended = match &mut model.reset {
        Some(reset) if reset.state == ResetState::Pending && now >= reset.held_until_us + RESET_HOLD_US => {
            reset.state = ResetState::Superseded;
            Some(reset.reset)
        }
        _ => None,
    };
    if let Some(reset) = ended {
        notice(
            model,
            KeyNoticeKind::ResetEnded {
                reset,
                state: ResetState::Superseded,
            },
        );
    }
}

fn pending(model: &Model) -> Option<&PendingReset> {
    model.reset.as_ref().filter(|reset| reset.state == ResetState::Pending)
}

#[async_trait]
impl ResetFlows for FakeKeyFlows {
    async fn pending_reset(&self) -> Result<Option<PendingReset>, SyncError> {
        let mut model = self.lock();
        settle(&mut model);
        Ok(model.reset.clone())
    }

    async fn begin_reset(&self, kind: ResetKind) -> Result<RecoveryKeyDraft, SyncError> {
        let mut model = self.lock();
        settle(&mut model);
        let approved = matches!(model.key_state, KeyState::Approved { .. });
        // Kind 2 comes from an approved device; kind 3 from a sign-in whose device is not, stepped up.
        match kind {
            ResetKind::KeepScopeKeys if !approved => return Err(rejected(RejectedCode::BadStatement)),
            ResetKind::StartEmpty if approved => return Err(rejected(RejectedCode::BadStatement)),
            ResetKind::StartEmpty if !model.step_up_fresh => {
                return Err(SyncError::Transport(TransportError::StepUpRequired(StepUpChallenge {
                    acr_values: vec!["urn:tablepro:acr:passkey".to_owned()],
                    max_age_secs: 300,
                })));
            }
            _ => {}
        }
        if pending(&model).is_some() {
            return Err(rejected(RejectedCode::BadStatement));
        }
        let (draft, made) = new_draft(&mut model, DraftPurpose::Reset(kind))?;
        Ok(RecoveryKeyDraft {
            draft,
            text: made.text,
            check: made.check,
        })
    }

    async fn finish_reset_proposal(&self, draft: DraftId, typed: TypedBack) -> Result<PendingReset, SyncError> {
        let mut model = self.lock();
        let held = model
            .drafts
            .get(&draft)
            .cloned()
            .ok_or(SyncError::Unknown { what: "draft" })?;
        let DraftPurpose::Reset(kind) = held.purpose else {
            return Err(SyncError::Unknown { what: "reset draft" });
        };
        check_typed_back(&held, &typed)?;
        let reset = PendingReset {
            reset: ResetId(random_uuid()?),
            kind,
            state: ResetState::Pending,
            mine: true,
            proposed_by: None,
            taken_at_us: model.clock_us,
            held_until_us: model.clock_us + RESET_HOLD_US,
        };
        // R' stays with the draft, as the reset's keys wait in the device store, until it activates.
        model.reset = Some(reset.clone());
        notice(&mut model, KeyNoticeKind::ResetPending { reset: reset.reset });
        Ok(reset)
    }

    async fn cancel_reset(&self, reset: ResetId, with: CancelWith) -> Result<(), SyncError> {
        let mut model = self.lock();
        settle(&mut model);
        if pending(&model).is_none_or(|held| held.reset != reset) {
            return Err(rejected(RejectedCode::BadStatement));
        }
        match &with {
            CancelWith::ThisDevice if !matches!(model.key_state, KeyState::Approved { .. }) => {
                return Err(SyncError::NotAllowed { what: "cancel a reset" });
            }
            CancelWith::RecoveryKey(text) => same_recovery_key(model.recovery.as_ref(), text)?,
            CancelWith::ThisDevice => {}
        }
        if let Some(held) = &mut model.reset {
            held.state = ResetState::Cancelled;
        }
        notice(
            &mut model,
            KeyNoticeKind::ResetEnded {
                reset,
                state: ResetState::Cancelled,
            },
        );
        Ok(())
    }

    async fn activate_reset(&self, reset: ResetId) -> Result<(), SyncError> {
        let mut model = self.lock();
        settle(&mut model);
        let held = model.reset.clone().filter(|held| held.reset == reset);
        let Some(held) = held else {
            return Err(rejected(RejectedCode::BadStatement));
        };
        if held.state != ResetState::Pending {
            return Err(rejected(RejectedCode::BadStatement));
        }
        if !held.mine {
            return Err(rejected(RejectedCode::WriterBound));
        }
        if model.clock_us < held.held_until_us {
            return Err(rejected(RejectedCode::ResetHeld));
        }
        let draft = model
            .drafts
            .iter()
            .find(|(_, draft)| draft.purpose == DraftPurpose::Reset(held.kind))
            .map(|(id, draft)| (*id, draft.text.clone()));
        if let Some((id, text)) = draft {
            model.drafts.remove(&id);
            model.recovery = Some(text);
        }
        if let Some(stored) = &mut model.reset {
            stored.state = ResetState::Active;
        }
        model.av += 1;
        model.devices.retain(|device| device.this_device);
        for team in model.teams.values_mut() {
            team.holder = false;
            team.rotation_due = true;
        }
        self.approve(&mut model)
    }

    async fn apply_reset_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        Ok(KeyApplied::default())
    }

    async fn resume_reset(&self, reset: ResetId) -> Result<(), SyncError> {
        let _ = reset;
        Ok(())
    }
}
