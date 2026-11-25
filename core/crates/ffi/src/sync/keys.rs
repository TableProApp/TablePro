// The end-to-end flows a person starts (core ADR 0056), over `tablepro_sync::api::KeyFlows`. Ids are upper-case
// UUID text, a team its scope name (`team_...`).

use secrecy::SecretString;
use tablepro_sync::api::key_flows::LockCause;

use super::service::{SyncService, unfilled};
use crate::error::CoreError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LockCauseTag {
    DeviceRemoved,
    LeftOutOfRotation,
    OwnAccountReset,
    AccountEnded,
    Unanchored,
    PersonalStopped,
}

impl From<LockCause> for LockCauseTag {
    fn from(cause: LockCause) -> Self {
        match cause {
            LockCause::DeviceRemoved => Self::DeviceRemoved,
            LockCause::LeftOutOfRotation => Self::LeftOutOfRotation,
            LockCause::OwnAccountReset => Self::OwnAccountReset,
            LockCause::AccountEnded => Self::AccountEnded,
            LockCause::Unanchored => Self::Unanchored,
            LockCause::PersonalStopped => Self::PersonalStopped,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KeyStateInfo {
    NoDeviceStore,
    Unknown,
    NoKeys,
    NeedsApproval { request: Option<String> },
    Approved { av: u32, key_device: String },
    Locked { cause: LockCauseTag },
}

// R, shown once, and the two of its 14 groups the person types back.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RecoveryKeyDraftInfo {
    pub draft: String,
    pub text: SecretString,
    pub check: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GenesisOutcomeTag {
    Created,
    AnotherDeviceWon,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SignOutOutcomeTag {
    Revoked,
    ErasedOffline,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FingerprintInfo {
    pub words: Vec<String>,
    pub qr: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ResetStateTag {
    Pending,
    Cancelled,
    Superseded,
    Active,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ResetKindTag {
    KeepScopeKeys,
    StartEmpty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
// Why a team stopped on this device (core ADR 0062): a catch-up an owner or admin confirms again, or a wait for a
// version a restore lost, which clears by itself once its signer's device pushes it back.
pub enum StopCauseTag {
    CatchUp,
    RestoreWait,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KeyNoticeKindTag {
    RecoveryKeyReplaced { account: String },
    KeysChanged { account: String },
    TeamKeyRestarted { team: String },
    ResetPending { reset: String },
    ResetEnded { reset: String, state: ResetStateTag },
    DeviceRemoved { device: String },
    SupersededWrap { team: String },
    Conflict { scope: String },
    ScopeStopped { scope: String, cause: StopCauseTag },
    ScopeEnded { scope: String },
    Locked { cause: LockCauseTag },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyNoticeInfo {
    pub id: String,
    pub kind: KeyNoticeKindTag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalRequestInfo {
    pub request: String,
    pub device: Option<String>,
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub requested_at_us: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SessionRoleTag {
    NewDevice,
    Approver,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SessionEndTag {
    User,
    Mismatch,
    Commitment,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SessionPhaseTag {
    Open,
    Chosen,
    // The five words, shown once per session.
    Compare { words: Vec<String> },
    Confirmed,
    Approved,
    // "Being approved on Mac mini."
    TakenElsewhere,
    Cancelled { reason: SessionEndTag },
    Expired,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalSessionInfo {
    pub request: String,
    pub role: SessionRoleTag,
    pub phase: SessionPhaseTag,
    pub expires_at_us: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountDeviceInfo {
    pub key_device: String,
    pub device: Option<String>,
    pub name: Option<String>,
    pub platform: Option<String>,
    pub added_at_us: Option<i64>,
    pub this_device: bool,
    pub compared: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewedDeviceInfo {
    pub device: AccountDeviceInfo,
    pub keep_by_default: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewedMemberInfo {
    pub team: String,
    pub account: String,
    pub confirmed_under_av: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemovalReviewInfo {
    pub review: String,
    pub devices: Vec<ReviewedDeviceInfo>,
    pub members: Vec<ReviewedMemberInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PendingResetInfo {
    pub reset: String,
    pub kind: ResetKindTag,
    pub state: ResetStateTag,
    pub mine: bool,
    pub proposed_by: Option<String>,
    pub taken_at_us: i64,
    pub held_until_us: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyVersionStateTag {
    Ok,
    Stopped,
    Ended,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MemberKeyStatusTag {
    NoKeys,
    AwaitingConfirmation,
    Holder,
    Alert,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TeamRoleTag {
    Owner,
    Admin,
    Editor,
    Member,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MemberKeysInfo {
    pub account: String,
    pub role: TeamRoleTag,
    pub status: MemberKeyStatusTag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamKeysInfo {
    pub team: String,
    pub version: Option<u32>,
    pub state: KeyVersionStateTag,
    pub stopped_cause: Option<StopCauseTag>,
    pub rotation_due: bool,
    pub holder: bool,
    pub members: Vec<MemberKeysInfo>,
    pub stopped: Vec<StoppedDeviceInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StoppedDeviceInfo {
    pub account: String,
    pub device: String,
    pub version: u32,
    // This account held that version, so the app offers to confirm the device again by rotating.
    pub can_reconfirm: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RotationDraftInfo {
    pub recovery: RecoveryKeyDraftInfo,
    pub devices: Vec<ReviewedDeviceInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyChangeInfo {
    pub account: String,
    pub pinned: FingerprintInfo,
    pub offered: FingerprintInfo,
    pub offered_ik: String,
}

#[uniffi::export]
impl SyncService {
    pub async fn key_state(&self) -> Result<KeyStateInfo, CoreError> {
        unfilled("keys.key_state")
    }

    pub async fn begin_genesis(&self) -> Result<RecoveryKeyDraftInfo, CoreError> {
        unfilled("keys.begin_genesis")
    }

    // `typed` holds the two groups in the order `check` named them.
    pub async fn finish_genesis(
        &self,
        draft: String,
        typed: Vec<SecretString>,
    ) -> Result<GenesisOutcomeTag, CoreError> {
        let _ = (draft, typed);
        unfilled("keys.finish_genesis")
    }

    pub async fn sign_out_keys(&self) -> Result<SignOutOutcomeTag, CoreError> {
        unfilled("keys.sign_out")
    }

    // R' and the devices the rotation can keep.
    pub async fn begin_replace_recovery_key(&self, recovery_key: SecretString) -> Result<RotationDraftInfo, CoreError> {
        let _ = recovery_key;
        unfilled("keys.begin_replace")
    }

    // `keep` holds the key device ids the person ticked.
    pub async fn finish_replace_recovery_key(
        &self,
        draft: String,
        typed: Vec<SecretString>,
        keep: Vec<String>,
    ) -> Result<(), CoreError> {
        let _ = (draft, typed, keep);
        unfilled("keys.finish_replace")
    }

    pub async fn own_fingerprint(&self) -> Result<FingerprintInfo, CoreError> {
        unfilled("keys.own_fingerprint")
    }

    pub async fn account_fingerprint(&self, account: String) -> Result<FingerprintInfo, CoreError> {
        let _ = account;
        unfilled("keys.fingerprint")
    }

    pub async fn compare_fingerprint_qr(&self, account: String, text: String) -> Result<bool, CoreError> {
        let _ = (account, text);
        unfilled("keys.compare_qr")
    }

    // Accepting without comparing is recorded as `first_use`.
    // The pinned and the offered identity of an account under a key-change alert, to compare.
    pub async fn account_key_change(&self, account: String) -> Result<Option<KeyChangeInfo>, CoreError> {
        let _ = account;
        unfilled("keys.key_change")
    }

    // `offered_ik` is the one `account_key_change` showed, as base64url.
    pub async fn accept_key_change(
        &self,
        account: String,
        offered_ik: String,
        compared: bool,
    ) -> Result<(), CoreError> {
        let _ = (account, offered_ik, compared);
        unfilled("keys.accept_key_change")
    }

    pub async fn key_notices(&self) -> Result<Vec<KeyNoticeInfo>, CoreError> {
        unfilled("keys.notices")
    }

    pub async fn dismiss_key_notice(&self, notice: String) -> Result<(), CoreError> {
        let _ = notice;
        unfilled("keys.dismiss_notice")
    }

    pub async fn request_approval(&self) -> Result<String, CoreError> {
        unfilled("keys.request_approval")
    }

    pub async fn approval_requests(&self) -> Result<Vec<ApprovalRequestInfo>, CoreError> {
        unfilled("keys.approval_requests")
    }

    pub async fn choose_approval_request(&self, request: String) -> Result<ApprovalSessionInfo, CoreError> {
        let _ = request;
        unfilled("keys.choose_request")
    }

    pub async fn approval_session(&self, request: String) -> Result<ApprovalSessionInfo, CoreError> {
        let _ = request;
        unfilled("keys.approval_session")
    }

    pub async fn confirm_approval_session(&self, request: String) -> Result<ApprovalSessionInfo, CoreError> {
        let _ = request;
        unfilled("keys.confirm_session")
    }

    pub async fn approval_words_differ(&self, request: String) -> Result<(), CoreError> {
        let _ = request;
        unfilled("keys.words_differ")
    }

    pub async fn cancel_approval_session(&self, request: String) -> Result<(), CoreError> {
        let _ = request;
        unfilled("keys.cancel_session")
    }

    pub async fn account_devices(&self) -> Result<Vec<AccountDeviceInfo>, CoreError> {
        unfilled("keys.account_devices")
    }

    // `sync.step_up_required` until the account's step-up is fresh.
    pub async fn remove_device_row(&self, device: String) -> Result<(), CoreError> {
        let _ = device;
        unfilled("keys.remove_device_row")
    }

    pub async fn begin_device_removal(
        &self,
        recovery_key: SecretString,
        lost: Vec<String>,
    ) -> Result<RemovalReviewInfo, CoreError> {
        let _ = (recovery_key, lost);
        unfilled("keys.begin_removal")
    }

    pub async fn finish_device_removal(
        &self,
        review: String,
        keep: Vec<String>,
        remove: Vec<ReviewedMemberInfo>,
    ) -> Result<(), CoreError> {
        let _ = (review, keep, remove);
        unfilled("keys.finish_removal")
    }

    pub async fn recover_with_recovery_key(&self, recovery_key: SecretString) -> Result<(), CoreError> {
        let _ = recovery_key;
        unfilled("keys.recover")
    }

    pub async fn pending_reset(&self) -> Result<Option<PendingResetInfo>, CoreError> {
        unfilled("keys.pending_reset")
    }

    pub async fn begin_reset(&self, kind: ResetKindTag) -> Result<RecoveryKeyDraftInfo, CoreError> {
        let _ = kind;
        unfilled("keys.begin_reset")
    }

    pub async fn finish_reset_proposal(
        &self,
        draft: String,
        typed: Vec<SecretString>,
    ) -> Result<PendingResetInfo, CoreError> {
        let _ = (draft, typed);
        unfilled("keys.finish_reset_proposal")
    }

    // With no recovery key, this device cancels as one certified at the current `av`.
    pub async fn cancel_reset(&self, reset: String, recovery_key: Option<SecretString>) -> Result<(), CoreError> {
        let _ = (reset, recovery_key);
        unfilled("keys.cancel_reset")
    }

    pub async fn activate_reset(&self, reset: String) -> Result<(), CoreError> {
        let _ = reset;
        unfilled("keys.activate_reset")
    }

    pub async fn team_keys(&self, team: String) -> Result<TeamKeysInfo, CoreError> {
        let _ = team;
        unfilled("keys.team_keys")
    }

    pub async fn create_team_keys(&self, team: String) -> Result<(), CoreError> {
        let _ = team;
        unfilled("keys.create_team_keys")
    }

    pub async fn confirm_member(&self, team: String, account: String) -> Result<(), CoreError> {
        let _ = (team, account);
        unfilled("keys.confirm_member")
    }

    pub async fn rotate_team_key(&self, team: String, remove: Vec<String>) -> Result<(), CoreError> {
        let _ = (team, remove);
        unfilled("keys.rotate_team")
    }

    pub async fn restart_team_key(&self, team: String, confirm: Vec<String>) -> Result<(), CoreError> {
        let _ = (team, confirm);
        unfilled("keys.restart_team")
    }

    // The envelope ids a removed party could read, for "Credentials to rotate".
    pub async fn credentials_to_rotate(&self, scope: String) -> Result<Vec<String>, CoreError> {
        let _ = scope;
        unfilled("keys.credentials_to_rotate")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unfilled_call_names_the_flow_in_its_error() {
        let error = unfilled::<()>("keys.begin_genesis").unwrap_err();

        assert_eq!(error.code(), "sync.unimplemented");
        assert!(error.to_string().contains("keys.begin_genesis"));
    }
}
