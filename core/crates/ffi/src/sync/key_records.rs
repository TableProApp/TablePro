// The key flows' values in the app's records, and the app's arguments read back. Ids cross as upper-case UUID text, a
// team as its scope name and an identity key as base64url.

use secrecy::SecretString;
use tablepro_keys::b64;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, RequestId, ResetId, TeamId, uuid_from_wire, uuid_to_wire};
use tablepro_keys::keys::Ed25519Public;
use tablepro_sync::SyncError;
use tablepro_sync::api::key_flows::{
    AccountDevice, ApprovalRequest, ApprovalSession, DraftId, Fingerprint, GenesisOutcome, HeldRestart, KeyChange,
    KeyNotice, KeyNoticeKind, KeyState, MemberKeyStatus, NoticeId, PendingReset, RecoveryKeyDraft, ResetKind,
    ResetState, ReviewedDevice, SessionEnd, SessionPhase, SessionRole, SignOutOutcome, TypedBack,
};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{KeyVersionState, StoppedCause};
use tablepro_sync::api::{DeviceRowId, ScopeName};

use super::keys::{
    AccountDeviceInfo, ApprovalRequestInfo, ApprovalSessionInfo, FingerprintInfo, GenesisOutcomeTag, HeldRestartInfo,
    KeyChangeInfo, KeyNoticeInfo, KeyNoticeKindTag, KeyStateInfo, KeyVersionStateTag, MemberKeyStatusTag,
    PendingResetInfo, RecoveryKeyDraftInfo, ResetKindTag, ResetStateTag, ReviewedDeviceInfo, SessionEndTag,
    SessionPhaseTag, SessionRoleTag, SignOutOutcomeTag, StopCauseTag, TeamRoleTag,
};

fn malformed(what: &'static str) -> SyncError {
    SyncError::Malformed { what }
}

pub(crate) fn uuid_arg(text: &str, what: &'static str) -> Result<uuid::Uuid, SyncError> {
    uuid_from_wire(text).map_err(|_| malformed(what))
}

pub(crate) fn draft_arg(text: &str) -> Result<DraftId, SyncError> {
    uuid_arg(text, "draft").map(DraftId)
}

pub(crate) fn account_arg(text: &str) -> Result<AccountId, SyncError> {
    uuid_arg(text, "account").map(AccountId)
}

pub(crate) fn key_device_arg(text: &str) -> Result<KeyDeviceId, SyncError> {
    uuid_arg(text, "key device").map(KeyDeviceId)
}

pub(crate) fn request_arg(text: &str) -> Result<RequestId, SyncError> {
    uuid_arg(text, "request").map(RequestId)
}

pub(crate) fn reset_arg(text: &str) -> Result<ResetId, SyncError> {
    uuid_arg(text, "reset").map(ResetId)
}

pub(crate) fn team_arg(text: &str) -> Result<TeamId, SyncError> {
    match ScopeName::parse(text)? {
        ScopeName::Team(team) => Ok(team),
        ScopeName::Personal | ScopeName::History => Err(malformed("team")),
    }
}

pub(crate) fn ik_arg(text: &str) -> Result<Ed25519Public, SyncError> {
    b64::decode_exact::<32>(text)
        .map(Ed25519Public)
        .map_err(|_| malformed("identity key"))
}

// The two groups, in the order the draft's `check` named them.
pub(crate) fn typed_arg(typed: Vec<SecretString>) -> Result<TypedBack, SyncError> {
    let groups: [SecretString; 2] = typed.try_into().map_err(|_| malformed("typed back groups"))?;
    Ok(TypedBack { groups })
}

pub(crate) fn team_text(team: TeamId) -> String {
    ScopeName::Team(team).wire()
}

impl From<KeyState> for KeyStateInfo {
    fn from(state: KeyState) -> Self {
        match state {
            KeyState::NoDeviceStore => Self::NoDeviceStore,
            KeyState::Unknown => Self::Unknown,
            KeyState::NoKeys => Self::NoKeys,
            KeyState::NeedsApproval { request } => Self::NeedsApproval {
                request: request.map(RequestId::to_wire),
            },
            KeyState::Approved { av, key_device } => Self::Approved {
                av: av.get(),
                key_device: key_device.to_wire(),
            },
            KeyState::Locked { cause } => Self::Locked { cause: cause.into() },
        }
    }
}

impl From<RecoveryKeyDraft> for RecoveryKeyDraftInfo {
    fn from(draft: RecoveryKeyDraft) -> Self {
        Self {
            draft: uuid_to_wire(draft.draft.0),
            text: draft.text,
            check: draft.check.to_vec(),
        }
    }
}

impl From<GenesisOutcome> for GenesisOutcomeTag {
    fn from(outcome: GenesisOutcome) -> Self {
        match outcome {
            GenesisOutcome::Created => Self::Created,
            GenesisOutcome::AnotherDeviceWon => Self::AnotherDeviceWon,
        }
    }
}

impl From<SignOutOutcome> for SignOutOutcomeTag {
    fn from(outcome: SignOutOutcome) -> Self {
        match outcome {
            SignOutOutcome::Revoked => Self::Revoked,
            SignOutOutcome::ErasedOffline => Self::ErasedOffline,
        }
    }
}

impl From<Fingerprint> for FingerprintInfo {
    fn from(fingerprint: Fingerprint) -> Self {
        Self {
            words: fingerprint.words,
            qr: fingerprint.qr,
        }
    }
}

impl From<KeyChange> for KeyChangeInfo {
    fn from(change: KeyChange) -> Self {
        Self {
            account: change.account.to_wire(),
            pinned: change.pinned.into(),
            offered: change.offered.into(),
            offered_ik: b64::encode(&change.offered_ik.0),
        }
    }
}

impl From<ResetState> for ResetStateTag {
    fn from(state: ResetState) -> Self {
        match state {
            ResetState::Pending => Self::Pending,
            ResetState::Cancelled => Self::Cancelled,
            ResetState::Superseded => Self::Superseded,
            ResetState::Active => Self::Active,
        }
    }
}

impl From<ResetKind> for ResetKindTag {
    fn from(kind: ResetKind) -> Self {
        match kind {
            ResetKind::KeepScopeKeys => Self::KeepScopeKeys,
            ResetKind::StartEmpty => Self::StartEmpty,
        }
    }
}

impl From<ResetKindTag> for ResetKind {
    fn from(kind: ResetKindTag) -> Self {
        match kind {
            ResetKindTag::KeepScopeKeys => Self::KeepScopeKeys,
            ResetKindTag::StartEmpty => Self::StartEmpty,
        }
    }
}

impl From<StoppedCause> for StopCauseTag {
    fn from(cause: StoppedCause) -> Self {
        match cause {
            StoppedCause::CatchUp => Self::CatchUp,
            StoppedCause::RestoreWait => Self::RestoreWait,
            StoppedCause::RestartHeld => Self::RestartHeld,
        }
    }
}

impl From<KeyNoticeKind> for KeyNoticeKindTag {
    fn from(kind: KeyNoticeKind) -> Self {
        match kind {
            KeyNoticeKind::RecoveryKeyReplaced { account } => Self::RecoveryKeyReplaced {
                account: account.to_wire(),
            },
            KeyNoticeKind::KeysChanged { account } => Self::KeysChanged {
                account: account.to_wire(),
            },
            KeyNoticeKind::TeamKeyRestarted { team } => Self::TeamKeyRestarted { team: team_text(team) },
            KeyNoticeKind::RestartHeld { team, signer } => Self::RestartHeld {
                team: team_text(team),
                signer: signer.to_wire(),
            },
            KeyNoticeKind::ResetPending { reset } => Self::ResetPending { reset: reset.to_wire() },
            KeyNoticeKind::ResetEnded { reset, state } => Self::ResetEnded {
                reset: reset.to_wire(),
                state: state.into(),
            },
            KeyNoticeKind::DeviceRemoved { device } => Self::DeviceRemoved { device: device.0 },
            KeyNoticeKind::SupersededWrap { team } => Self::SupersededWrap { team: team_text(team) },
            KeyNoticeKind::Conflict { scope } => Self::Conflict { scope: scope.wire() },
            KeyNoticeKind::ScopeStopped { scope, cause } => Self::ScopeStopped {
                scope: scope.wire(),
                cause: cause.into(),
            },
            KeyNoticeKind::ScopeEnded { scope } => Self::ScopeEnded { scope: scope.wire() },
            KeyNoticeKind::Locked { cause } => Self::Locked { cause: cause.into() },
        }
    }
}

impl From<KeyNotice> for KeyNoticeInfo {
    fn from(notice: KeyNotice) -> Self {
        Self {
            id: uuid_to_wire(notice.id.0),
            kind: notice.kind.into(),
        }
    }
}

pub(crate) fn notice_arg(text: &str) -> Result<NoticeId, SyncError> {
    uuid_arg(text, "notice").map(NoticeId)
}

impl From<ApprovalRequest> for ApprovalRequestInfo {
    fn from(request: ApprovalRequest) -> Self {
        Self {
            request: request.request.to_wire(),
            device: request.device.map(|device| device.0),
            device_name: request.device_name,
            platform: request.platform,
            requested_at_us: request.requested_at_us,
        }
    }
}

impl From<SessionRole> for SessionRoleTag {
    fn from(role: SessionRole) -> Self {
        match role {
            SessionRole::NewDevice => Self::NewDevice,
            SessionRole::Approver => Self::Approver,
        }
    }
}

impl From<SessionEnd> for SessionEndTag {
    fn from(end: SessionEnd) -> Self {
        match end {
            SessionEnd::User => Self::User,
            SessionEnd::Mismatch => Self::Mismatch,
            SessionEnd::Commitment => Self::Commitment,
        }
    }
}

impl From<SessionPhase> for SessionPhaseTag {
    fn from(phase: SessionPhase) -> Self {
        match phase {
            SessionPhase::Open => Self::Open,
            SessionPhase::Chosen => Self::Chosen,
            SessionPhase::Compare { words } => Self::Compare { words },
            SessionPhase::Confirmed => Self::Confirmed,
            SessionPhase::Approved => Self::Approved,
            SessionPhase::TakenElsewhere => Self::TakenElsewhere,
            SessionPhase::Cancelled { reason } => Self::Cancelled { reason: reason.into() },
            SessionPhase::Expired => Self::Expired,
        }
    }
}

impl From<ApprovalSession> for ApprovalSessionInfo {
    fn from(session: ApprovalSession) -> Self {
        Self {
            request: session.request.to_wire(),
            role: session.role.into(),
            phase: session.phase.into(),
            expires_at_us: session.expires_at_us,
        }
    }
}

impl From<AccountDevice> for AccountDeviceInfo {
    fn from(device: AccountDevice) -> Self {
        Self {
            key_device: device.key_device.to_wire(),
            device: device.device.map(|device| device.0),
            name: device.name,
            platform: device.platform,
            added_at_us: device.added_at_us,
            this_device: device.this_device,
            compared: device.compared,
        }
    }
}

impl From<ReviewedDevice> for ReviewedDeviceInfo {
    fn from(device: ReviewedDevice) -> Self {
        Self {
            device: device.device.into(),
            keep_by_default: device.keep_by_default,
        }
    }
}

impl From<PendingReset> for PendingResetInfo {
    fn from(reset: PendingReset) -> Self {
        Self {
            reset: reset.reset.to_wire(),
            kind: reset.kind.into(),
            state: reset.state.into(),
            mine: reset.mine,
            proposed_by: reset.proposed_by.map(|device: DeviceRowId| device.0),
            taken_at_us: reset.taken_at_us,
            held_until_us: reset.held_until_us,
        }
    }
}

impl From<KeyVersionState> for KeyVersionStateTag {
    fn from(state: KeyVersionState) -> Self {
        match state {
            KeyVersionState::Ok => Self::Ok,
            KeyVersionState::Stopped => Self::Stopped,
            KeyVersionState::Ended => Self::Ended,
        }
    }
}

impl From<MemberKeyStatus> for MemberKeyStatusTag {
    fn from(status: MemberKeyStatus) -> Self {
        match status {
            MemberKeyStatus::NoKeys => Self::NoKeys,
            MemberKeyStatus::AwaitingConfirmation => Self::AwaitingConfirmation,
            MemberKeyStatus::Holder => Self::Holder,
            MemberKeyStatus::Alert => Self::Alert,
        }
    }
}

impl From<Role> for TeamRoleTag {
    fn from(role: Role) -> Self {
        match role {
            Role::Owner => Self::Owner,
            Role::Admin => Self::Admin,
            Role::Editor => Self::Editor,
            Role::Member => Self::Member,
        }
    }
}

impl From<HeldRestart> for HeldRestartInfo {
    fn from(restart: HeldRestart) -> Self {
        Self {
            team: team_text(restart.team),
            version: restart.version.get(),
            signer: restart.signer.to_wire(),
            signer_ik: b64::encode(&restart.signer_ik.0),
            words: restart.words.into(),
        }
    }
}
