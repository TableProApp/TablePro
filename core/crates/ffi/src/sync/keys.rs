// The end-to-end flows a person starts (core ADR 0056), over `tablepro_sync::api::KeyFlows`. Ids are upper-case
// UUID text, a team its scope name (`team_...`), which is the id `ProfileInfo.teams` gives it. A team's name comes
// from the profile and a member's name and email from the team's member list, which the server serves to owners and
// admins only, so each is None where the account cannot read it.

use std::future::Future;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_keys::encoding::TeamId;
use tablepro_keys::envelope::EnvelopeId;
use tablepro_sync::SyncError;
use tablepro_sync::api::ScopeName;
use tablepro_sync::api::key_flows::{
    AccountFlows, Acceptance, ApprovalFlows, CancelWith, DeviceFlows, LockCause, RemovalReview, ResetFlows,
    ReviewedMember, TeamFlows, TeamKeys,
};
use tablepro_sync::keys::KeyService;

use super::key_records::{
    account_arg, draft_arg, ik_arg, key_device_arg, notice_arg, request_arg, reset_arg, team_arg, team_text,
    typed_arg,
};
use super::names::Names;
use super::service::SyncService;
use crate::error::CoreError;
use crate::runtime::on_runtime;

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
    // A team restart held until the person compares the restarting owner's words (core ADR 0064).
    RestartHeld,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KeyNoticeKindTag {
    RecoveryKeyReplaced { account: String },
    KeysChanged { account: String },
    TeamKeyRestarted { team: String },
    RestartHeld { team: String, signer: String },
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
    pub team_name: Option<String>,
    pub account: String,
    pub name: Option<String>,
    pub email: Option<String>,
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
    pub name: Option<String>,
    pub email: Option<String>,
    pub role: TeamRoleTag,
    pub status: MemberKeyStatusTag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamKeysInfo {
    pub team: String,
    pub team_name: Option<String>,
    pub version: Option<u32>,
    pub state: KeyVersionStateTag,
    pub stopped_cause: Option<StopCauseTag>,
    pub rotation_due: bool,
    pub holder: bool,
    pub members: Vec<MemberKeysInfo>,
    pub stopped: Vec<StoppedDeviceInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeldRestartInfo {
    pub team: String,
    pub version: u32,
    pub signer: String,
    pub signer_ik: String,
    pub words: FingerprintInfo,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StoppedDeviceInfo {
    pub account: String,
    pub name: Option<String>,
    pub email: Option<String>,
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

impl SyncService {
    // Runs `work` over this sign-in's key flows on the runtime.
    async fn on_keys<T, F>(&self, work: impl FnOnce(Arc<KeyService>) -> F + Send) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, SyncError>> + Send + 'static,
    {
        let future = work(self.key_service()?);
        on_runtime(&self.tasks, async move { future.await.map_err(CoreError::from) }).await
    }

    fn names_account(&self) -> Option<tablepro_account::Account> {
        self.account.as_ref().map(|service| service.account.clone())
    }
}

pub(crate) fn team_keys_info(keys: TeamKeys, names: &Names) -> TeamKeysInfo {
    let team = keys.team;
    TeamKeysInfo {
        team: team_text(team),
        team_name: names.team(team),
        version: keys.version.map(|version| version.get()),
        state: keys.state.into(),
        stopped_cause: keys.stopped_cause.map(StopCauseTag::from),
        rotation_due: keys.rotation_due,
        holder: keys.holder,
        members: keys
            .members
            .into_iter()
            .map(|member| {
                let person = names.person(team, member.account);
                MemberKeysInfo {
                    account: member.account.to_wire(),
                    name: person.name,
                    email: person.email,
                    role: member.role.into(),
                    status: member.status.into(),
                }
            })
            .collect(),
        stopped: keys
            .stopped
            .into_iter()
            .map(|stopped| {
                let person = names.person(team, stopped.account);
                StoppedDeviceInfo {
                    account: stopped.account.to_wire(),
                    name: person.name,
                    email: person.email,
                    device: stopped.device.0,
                    version: stopped.version.get(),
                    can_reconfirm: stopped.can_reconfirm,
                }
            })
            .collect(),
    }
}

pub(crate) fn reviewed_member_info(member: ReviewedMember, names: &Names) -> ReviewedMemberInfo {
    let person = names.person(member.team, member.account);
    ReviewedMemberInfo {
        team: team_text(member.team),
        team_name: names.team(member.team),
        account: member.account.to_wire(),
        name: person.name,
        email: person.email,
        confirmed_under_av: member.confirmed_under_av.get(),
    }
}

fn removal_review_info(review: RemovalReview, names: &Names) -> RemovalReviewInfo {
    RemovalReviewInfo {
        review: tablepro_keys::encoding::uuid_to_wire(review.review.0),
        devices: review.devices.into_iter().map(ReviewedDeviceInfo::from).collect(),
        members: review
            .members
            .into_iter()
            .map(|member| reviewed_member_info(member, names))
            .collect(),
    }
}

// What the person ticked to remove, as the review gave it; the names the app was shown carry nothing.
pub(crate) fn reviewed_member_arg(member: &ReviewedMemberInfo) -> Result<ReviewedMember, SyncError> {
    Ok(ReviewedMember {
        team: team_arg(&member.team)?,
        account: account_arg(&member.account)?,
        confirmed_under_av: tablepro_keys::encoding::Version::new(member.confirmed_under_av)
            .map_err(|_| SyncError::Malformed { what: "version" })?,
    })
}

fn ids<T>(texts: &[String], parse: fn(&str) -> Result<T, SyncError>) -> Result<Vec<T>, SyncError> {
    texts.iter().map(|text| parse(text)).collect()
}

#[uniffi::export]
impl SyncService {
    pub async fn key_state(&self) -> Result<KeyStateInfo, CoreError> {
        self.on_keys(|keys| async move { keys.key_state().await.map(KeyStateInfo::from) })
            .await
    }

    pub async fn begin_genesis(&self) -> Result<RecoveryKeyDraftInfo, CoreError> {
        self.on_keys(|keys| async move { keys.begin_genesis().await.map(RecoveryKeyDraftInfo::from) })
            .await
    }

    // `typed` holds the two groups in the order `check` named them.
    pub async fn finish_genesis(
        &self,
        draft: String,
        typed: Vec<SecretString>,
    ) -> Result<GenesisOutcomeTag, CoreError> {
        let (draft, typed) = (draft_arg(&draft)?, typed_arg(typed)?);
        self.on_keys(|keys| async move { keys.finish_genesis(draft, typed).await.map(GenesisOutcomeTag::from) })
            .await
    }

    pub async fn sign_out_keys(&self) -> Result<SignOutOutcomeTag, CoreError> {
        self.on_keys(|keys| async move { keys.sign_out().await.map(SignOutOutcomeTag::from) })
            .await
    }

    // R' and the devices the rotation can keep.
    pub async fn begin_replace_recovery_key(&self, recovery_key: SecretString) -> Result<RotationDraftInfo, CoreError> {
        self.on_keys(|keys| async move {
            let draft = keys.begin_replace(recovery_key).await?;
            Ok(RotationDraftInfo {
                recovery: draft.recovery.into(),
                devices: draft.devices.into_iter().map(ReviewedDeviceInfo::from).collect(),
            })
        })
        .await
    }

    // `keep` holds the key device ids the person ticked.
    pub async fn finish_replace_recovery_key(
        &self,
        draft: String,
        typed: Vec<SecretString>,
        keep: Vec<String>,
    ) -> Result<(), CoreError> {
        let (draft, typed, keep) = (draft_arg(&draft)?, typed_arg(typed)?, ids(&keep, key_device_arg)?);
        self.on_keys(|keys| async move { keys.finish_replace(draft, typed, keep).await })
            .await
    }

    pub async fn own_fingerprint(&self) -> Result<FingerprintInfo, CoreError> {
        self.on_keys(|keys| async move { keys.own_fingerprint().await.map(FingerprintInfo::from) })
            .await
    }

    pub async fn account_fingerprint(&self, account: String) -> Result<FingerprintInfo, CoreError> {
        let account = account_arg(&account)?;
        self.on_keys(|keys| async move { keys.fingerprint(account).await.map(FingerprintInfo::from) })
            .await
    }

    pub async fn compare_fingerprint_qr(&self, account: String, text: String) -> Result<bool, CoreError> {
        let account = account_arg(&account)?;
        self.on_keys(|keys| async move { keys.compare_qr(account, text).await })
            .await
    }

    // The pinned and the offered identity of an account under a key-change alert, to compare.
    pub async fn account_key_change(&self, account: String) -> Result<Option<KeyChangeInfo>, CoreError> {
        let account = account_arg(&account)?;
        self.on_keys(|keys| async move { Ok(keys.key_change(account).await?.map(KeyChangeInfo::from)) })
            .await
    }

    // `offered_ik` is the one `account_key_change` showed, as base64url. Accepting without comparing is recorded as
    // `first_use`.
    pub async fn accept_key_change(
        &self,
        account: String,
        offered_ik: String,
        compared: bool,
    ) -> Result<(), CoreError> {
        let (account, offered) = (account_arg(&account)?, ik_arg(&offered_ik)?);
        let how = if compared {
            Acceptance::Compared
        } else {
            Acceptance::WithoutComparing
        };
        self.on_keys(|keys| async move { keys.accept_key_change(account, offered, how).await })
            .await
    }

    pub async fn key_notices(&self) -> Result<Vec<KeyNoticeInfo>, CoreError> {
        self.on_keys(|keys| async move {
            let notices = keys.notices().await?;
            Ok(notices.into_iter().map(KeyNoticeInfo::from).collect())
        })
        .await
    }

    pub async fn dismiss_key_notice(&self, notice: String) -> Result<(), CoreError> {
        let notice = notice_arg(&notice)?;
        self.on_keys(|keys| async move { keys.dismiss_notice(notice).await })
            .await
    }

    pub async fn request_approval(&self) -> Result<String, CoreError> {
        self.on_keys(|keys| async move { keys.request_approval().await.map(|request| request.to_wire()) })
            .await
    }

    pub async fn approval_requests(&self) -> Result<Vec<ApprovalRequestInfo>, CoreError> {
        self.on_keys(|keys| async move {
            let requests = keys.approval_requests().await?;
            Ok(requests.into_iter().map(ApprovalRequestInfo::from).collect())
        })
        .await
    }

    pub async fn choose_approval_request(&self, request: String) -> Result<ApprovalSessionInfo, CoreError> {
        let request = request_arg(&request)?;
        self.on_keys(|keys| async move { keys.choose_request(request).await.map(ApprovalSessionInfo::from) })
            .await
    }

    pub async fn approval_session(&self, request: String) -> Result<ApprovalSessionInfo, CoreError> {
        let request = request_arg(&request)?;
        self.on_keys(|keys| async move { keys.approval_session(request).await.map(ApprovalSessionInfo::from) })
            .await
    }

    pub async fn confirm_approval_session(&self, request: String) -> Result<ApprovalSessionInfo, CoreError> {
        let request = request_arg(&request)?;
        self.on_keys(|keys| async move { keys.confirm_session(request).await.map(ApprovalSessionInfo::from) })
            .await
    }

    pub async fn approval_words_differ(&self, request: String) -> Result<(), CoreError> {
        let request = request_arg(&request)?;
        self.on_keys(|keys| async move { keys.words_differ(request).await })
            .await
    }

    pub async fn cancel_approval_session(&self, request: String) -> Result<(), CoreError> {
        let request = request_arg(&request)?;
        self.on_keys(|keys| async move { keys.cancel_session(request).await })
            .await
    }

    pub async fn account_devices(&self) -> Result<Vec<AccountDeviceInfo>, CoreError> {
        self.on_keys(|keys| async move {
            let devices = keys.account_devices().await?;
            Ok(devices.into_iter().map(AccountDeviceInfo::from).collect())
        })
        .await
    }

    // `sync.step_up_required` until the account's step-up is fresh.
    pub async fn remove_device_row(&self, device: String) -> Result<(), CoreError> {
        let device = tablepro_sync::api::DeviceRowId(device);
        self.on_keys(|keys| async move { keys.remove_device_row(device).await })
            .await
    }

    pub async fn begin_device_removal(
        &self,
        recovery_key: SecretString,
        lost: Vec<String>,
    ) -> Result<RemovalReviewInfo, CoreError> {
        let lost = ids(&lost, key_device_arg)?;
        let account = self.names_account();
        self.on_keys(|keys| async move {
            let review = keys.begin_removal(recovery_key, lost).await?;
            let teams: Vec<TeamId> = review.members.iter().map(|member| member.team).collect();
            let names = Names::read(account.as_ref(), &teams).await;
            Ok(removal_review_info(review, &names))
        })
        .await
    }

    pub async fn finish_device_removal(
        &self,
        review: String,
        keep: Vec<String>,
        remove: Vec<ReviewedMemberInfo>,
    ) -> Result<(), CoreError> {
        let (review, keep) = (draft_arg(&review)?, ids(&keep, key_device_arg)?);
        let remove = remove.iter().map(reviewed_member_arg).collect::<Result<Vec<_>, _>>()?;
        self.on_keys(|keys| async move { keys.finish_removal(review, keep, remove).await })
            .await
    }

    pub async fn recover_with_recovery_key(&self, recovery_key: SecretString) -> Result<(), CoreError> {
        self.on_keys(|keys| async move { keys.recover(recovery_key).await })
            .await
    }

    pub async fn pending_reset(&self) -> Result<Option<PendingResetInfo>, CoreError> {
        self.on_keys(|keys| async move { Ok(keys.pending_reset().await?.map(PendingResetInfo::from)) })
            .await
    }

    pub async fn begin_reset(&self, kind: ResetKindTag) -> Result<RecoveryKeyDraftInfo, CoreError> {
        self.on_keys(|keys| async move { keys.begin_reset(kind.into()).await.map(RecoveryKeyDraftInfo::from) })
            .await
    }

    pub async fn finish_reset_proposal(
        &self,
        draft: String,
        typed: Vec<SecretString>,
    ) -> Result<PendingResetInfo, CoreError> {
        let (draft, typed) = (draft_arg(&draft)?, typed_arg(typed)?);
        self.on_keys(|keys| async move {
            keys.finish_reset_proposal(draft, typed)
                .await
                .map(PendingResetInfo::from)
        })
        .await
    }

    // With no recovery key, this device cancels as one certified at the current `av`.
    pub async fn cancel_reset(&self, reset: String, recovery_key: Option<SecretString>) -> Result<(), CoreError> {
        let reset = reset_arg(&reset)?;
        let with = recovery_key.map_or(CancelWith::ThisDevice, CancelWith::RecoveryKey);
        self.on_keys(|keys| async move { keys.cancel_reset(reset, with).await })
            .await
    }

    pub async fn activate_reset(&self, reset: String) -> Result<(), CoreError> {
        let reset = reset_arg(&reset)?;
        self.on_keys(|keys| async move { keys.activate_reset(reset).await })
            .await
    }

    pub async fn team_keys(&self, team: String) -> Result<TeamKeysInfo, CoreError> {
        let team = team_arg(&team)?;
        let account = self.names_account();
        self.on_keys(|keys| async move {
            let team_keys = keys.team_keys(team).await?;
            let names = Names::read(account.as_ref(), &[team]).await;
            Ok(team_keys_info(team_keys, &names))
        })
        .await
    }

    pub async fn create_team_keys(&self, team: String) -> Result<(), CoreError> {
        let team = team_arg(&team)?;
        self.on_keys(|keys| async move { keys.create_team_keys(team).await })
            .await
    }

    pub async fn confirm_member(&self, team: String, account: String) -> Result<(), CoreError> {
        let (team, account) = (team_arg(&team)?, account_arg(&account)?);
        self.on_keys(|keys| async move { keys.confirm_member(team, account).await })
            .await
    }

    pub async fn rotate_team_key(&self, team: String, remove: Vec<String>) -> Result<(), CoreError> {
        let (team, remove) = (team_arg(&team)?, ids(&remove, account_arg)?);
        self.on_keys(|keys| async move { keys.rotate_team(team, remove).await })
            .await
    }

    pub async fn restart_team_key(&self, team: String, confirm: Vec<String>) -> Result<(), CoreError> {
        let (team, confirm) = (team_arg(&team)?, ids(&confirm, account_arg)?);
        self.on_keys(|keys| async move { keys.restart_team(team, confirm).await })
            .await
    }

    // A restart this device holds until the person compares the restarting owner's words.
    pub async fn held_team_restart(&self, team: String) -> Result<Option<HeldRestartInfo>, CoreError> {
        let team = team_arg(&team)?;
        self.on_keys(|keys| async move { Ok(keys.held_restart(team).await?.map(HeldRestartInfo::from)) })
            .await
    }

    // `signer_ik` is the one `held_team_restart` showed, as base64url; there is no accept without comparing.
    pub async fn accept_team_restart(&self, team: String, signer_ik: String) -> Result<(), CoreError> {
        let (team, signer_ik) = (team_arg(&team)?, ik_arg(&signer_ik)?);
        self.on_keys(|keys| async move { keys.accept_restart(team, signer_ik).await })
            .await
    }

    // The envelope ids a removed party could read, for "Credentials to rotate".
    pub async fn credentials_to_rotate(&self, scope: String) -> Result<Vec<String>, CoreError> {
        let scope = ScopeName::parse(&scope)?;
        self.on_keys(|keys| async move {
            let envelopes = keys.credentials_to_rotate(scope).await?;
            Ok(envelopes.iter().map(EnvelopeId::to_wire).collect())
        })
        .await
    }
}
