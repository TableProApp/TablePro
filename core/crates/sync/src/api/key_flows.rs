// The end-to-end flows of 0056, one trait per lane that fills them, so each lane writes its own `impl` in its own
// files. Every method answers `sync.unimplemented` until its lane overrides it; the fake in `tablepro-sync-testing`
// overrides them all. Flows a person starts come through the FFI; the `apply_*`, `seal_*`, `open_*` and `resume_*`
// calls are the engine's, made during a pass in revision order. `KeyHooks` is how a flow stops or locks the engine
// and reports to the app.

use async_trait::async_trait;
use secrecy::SecretString;
use serde_json::Value;
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, HistoryId, KeyDeviceId, RequestId, ResetId, TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::keys::Ed25519Public;
use uuid::Uuid;

use super::error::SyncError;
use super::ids::{DeviceRowId, EpochId, ScopeName};
use super::scopes::{Role, ScopeInfo, StopReport, TeamMember};
use super::state::{KeyVersionState, PendingFlow, StoppedCause};
use super::transport::{Change, ChangeOutcome, DpopKey, PulledRecord};

pub trait KeyFlows:
    AccountFlows + ApprovalFlows + DeviceFlows + ResetFlows + TeamFlows + RestoreFlows + StopFlows
{
}

impl<T> KeyFlows for T where
    T: AccountFlows + ApprovalFlows + DeviceFlows + ResetFlows + TeamFlows + RestoreFlows + StopFlows
{
}

fn unimplemented<T>(what: &'static str) -> Result<T, SyncError> {
    Err(SyncError::unimplemented(what))
}

// K7-1: Keys, The recovery key, Pins, Genesis, Sign Out, Replace, Envelopes and history, Rollback.
#[async_trait]
pub trait AccountFlows: Send + Sync {
    async fn key_state(&self) -> Result<KeyState, SyncError> {
        unimplemented("keys.key_state")
    }

    // Genesis step 1: R is made and shown, with the two groups the person types back before anything is pushed.
    async fn begin_genesis(&self) -> Result<RecoveryKeyDraft, SyncError> {
        unimplemented("keys.begin_genesis")
    }

    // Genesis step 2: the change set at `av` 1. When another device's genesis won, this device asks for approval.
    async fn finish_genesis(&self, draft: DraftId, typed: TypedBack) -> Result<GenesisOutcome, SyncError> {
        let _ = (draft, typed);
        unimplemented("keys.finish_genesis")
    }

    // The revoke when online, then the device keys and key device id erased; nothing rotates (D7).
    async fn sign_out(&self) -> Result<SignOutOutcome, SyncError> {
        unimplemented("keys.sign_out")
    }

    // Replace Recovery Key: a rotation with R' and IK' endorsed by the old IK, which needs the current R.
    // Shows R' and the devices the rotation can keep: this one, and those it compared with.
    async fn begin_replace(&self, recovery_key: SecretString) -> Result<RotationDraft, SyncError> {
        let _ = recovery_key;
        unimplemented("keys.begin_replace")
    }

    // `keep` is the own-device pins the person ticked; every other device joins again by approval.
    async fn finish_replace(&self, draft: DraftId, typed: TypedBack, keep: Vec<KeyDeviceId>) -> Result<(), SyncError> {
        let _ = (draft, typed, keep);
        unimplemented("keys.finish_replace")
    }

    async fn own_fingerprint(&self) -> Result<Fingerprint, SyncError> {
        unimplemented("keys.own_fingerprint")
    }

    // Another account's words, from the IK this device pinned for it.
    async fn fingerprint(&self, account: AccountId) -> Result<Fingerprint, SyncError> {
        let _ = account;
        unimplemented("keys.fingerprint")
    }

    // A scanned `TPF1:` code against the account's pinned IK; a match counts as a comparison.
    async fn compare_qr(&self, account: AccountId, text: String) -> Result<bool, SyncError> {
        let _ = (account, text);
        unimplemented("keys.compare_qr")
    }

    // An open key-change alert: the IK pinned and the one offered, each with its words, to compare before accepting.
    async fn key_change(&self, account: AccountId) -> Result<Option<KeyChange>, SyncError> {
        let _ = account;
        unimplemented("keys.key_change")
    }

    // Re-confirming after a key-change alert, by comparing or by accepting, which is recorded as `first_use`. Bound to
    // the offered IK the person saw, so a different one offered since is not accepted with it.
    async fn accept_key_change(
        &self,
        account: AccountId,
        offered: Ed25519Public,
        how: Acceptance,
    ) -> Result<(), SyncError> {
        let _ = (account, offered, how);
        unimplemented("keys.accept_key_change")
    }

    async fn notices(&self) -> Result<Vec<KeyNotice>, SyncError> {
        unimplemented("keys.notices")
    }

    async fn dismiss_notice(&self, notice: NoticeId) -> Result<(), SyncError> {
        let _ = notice;
        unimplemented("keys.dismiss_notice")
    }

    // The personal scope's account certificates, device certificates, recovery blobs, PK and HK version records,
    // their rings and their wraps.
    async fn apply_account_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        unimplemented("keys.apply_account_objects")
    }

    // A personal envelope under the newest PK version, after a pull of the key objects (0056, Writing).
    async fn seal_personal_envelope(
        &self,
        envelope: EnvelopeId,
        secret: SecretString,
        dest: Value,
    ) -> Result<Value, SyncError> {
        let _ = (envelope, secret, dest);
        unimplemented("keys.seal_personal_envelope")
    }

    // A pulled personal envelope, taken only under the version in force at its place in the order and never below
    // the copy held (0056, Rollback, In order). `in_force` is None in a snapshot.
    async fn open_personal_envelope(
        &self,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        let _ = (envelope, fields, in_force);
        unimplemented("keys.open_personal_envelope")
    }

    // A history entry encrypted at push time under the newest HK version.
    async fn seal_history_entry(&self, entry: HistoryId, plaintext: Value) -> Result<Value, SyncError> {
        let _ = (entry, plaintext);
        unimplemented("keys.seal_history_entry")
    }

    async fn open_history_entry(&self, entry: HistoryId, fields: Value) -> Result<Value, SyncError> {
        let _ = (entry, fields);
        unimplemented("keys.open_history_entry")
    }
}

// K7-2: Approving a device.
#[async_trait]
pub trait ApprovalFlows: Send + Sync {
    // N: fixes its view, draws r_N and writes `key.request`.
    async fn request_approval(&self) -> Result<RequestId, SyncError> {
        unimplemented("keys.request_approval")
    }

    // A: the open requests of the account, newest first.
    async fn approval_requests(&self) -> Result<Vec<ApprovalRequest>, SyncError> {
        unimplemented("keys.approval_requests")
    }

    // A: writes the `nonce` step. Another approver's step first is `create_only`, which closes this sheet.
    async fn choose_request(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let _ = request;
        unimplemented("keys.choose_request")
    }

    // Either side, polled every 1 to 2 seconds while the sheet is open. Words show once.
    async fn approval_session(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let _ = request;
        unimplemented("keys.approval_session")
    }

    // The person confirmed the words: A pushes the approval change set; N merges once it arrives.
    async fn confirm_session(&self, request: RequestId) -> Result<ApprovalSession, SyncError> {
        let _ = request;
        unimplemented("keys.confirm_session")
    }

    // The person says the words differ: a `cancel` step with `mismatch`.
    async fn words_differ(&self, request: RequestId) -> Result<(), SyncError> {
        let _ = request;
        unimplemented("keys.words_differ")
    }

    // A `cancel` step with `user`.
    async fn cancel_session(&self, request: RequestId) -> Result<(), SyncError> {
        let _ = request;
        unimplemented("keys.cancel_session")
    }

    // `key.request` and `key.sas` records as a pull serves them.
    async fn apply_session_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        unimplemented("keys.apply_session_objects")
    }

    async fn resume_approval(&self, request: RequestId) -> Result<(), SyncError> {
        let _ = request;
        unimplemented("keys.resume_approval")
    }
}

// K7-2: Rotation, Removing a device, Recovery.
#[async_trait]
pub trait DeviceFlows: Send + Sync {
    // The account's key devices, as certificates, own-device pins and the server's device rows show them.
    async fn account_devices(&self) -> Result<Vec<AccountDevice>, SyncError> {
        unimplemented("keys.account_devices")
    }

    // Step 1 of a removal: the row goes first, behind a fresh step-up (`sync.step_up_required` carries the challenge).
    async fn remove_device_row(&self, device: DeviceRowId) -> Result<(), SyncError> {
        let _ = device;
        unimplemented("keys.remove_device_row")
    }

    // Step 2: R typed, the sheet of devices to keep and members to review.
    async fn begin_removal(
        &self,
        recovery_key: SecretString,
        lost: Vec<KeyDeviceId>,
    ) -> Result<RemovalReview, SyncError> {
        let _ = (recovery_key, lost);
        unimplemented("keys.begin_removal")
    }

    // Step 4: the rotation keeping `keep`, then each team rotated without `remove`; the choices stay in `key_pending`.
    async fn finish_removal(
        &self,
        review: DraftId,
        keep: Vec<KeyDeviceId>,
        remove: Vec<ReviewedMember>,
    ) -> Result<(), SyncError> {
        let _ = (review, keep, remove);
        unimplemented("keys.finish_removal")
    }

    // Recovery with R on a device with no approved device at hand: a rotation that keeps only this device.
    async fn recover(&self, recovery_key: SecretString) -> Result<(), SyncError> {
        let _ = recovery_key;
        unimplemented("keys.recover")
    }

    async fn resume_rotation(&self, av: Version) -> Result<(), SyncError> {
        let _ = av;
        unimplemented("keys.resume_rotation")
    }
}

// K7-2: Reset.
#[async_trait]
pub trait ResetFlows: Send + Sync {
    async fn pending_reset(&self) -> Result<Option<PendingReset>, SyncError> {
        unimplemented("keys.pending_reset")
    }

    // Kind 2 from an approved device, kind 3 from a sign-in whose device is not, after a step-up. R' is shown.
    async fn begin_reset(&self, kind: ResetKind) -> Result<RecoveryKeyDraft, SyncError> {
        let _ = kind;
        unimplemented("keys.begin_reset")
    }

    // The `key.reset` alone; the honest server holds it 7 days.
    async fn finish_reset_proposal(&self, draft: DraftId, typed: TypedBack) -> Result<PendingReset, SyncError> {
        let _ = (draft, typed);
        unimplemented("keys.finish_reset_proposal")
    }

    async fn cancel_reset(&self, reset: ResetId, with: CancelWith) -> Result<(), SyncError> {
        let _ = (reset, with);
        unimplemented("keys.cancel_reset")
    }

    // The activation change set, from the proposing device, once `held_until` passed.
    async fn activate_reset(&self, reset: ResetId) -> Result<(), SyncError> {
        let _ = reset;
        unimplemented("keys.activate_reset")
    }

    // `key.reset` and `key.cancel` records as a pull serves them.
    async fn apply_reset_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        unimplemented("keys.apply_reset_objects")
    }

    async fn resume_reset(&self, reset: ResetId) -> Result<(), SyncError> {
        let _ = reset;
        unimplemented("keys.resume_reset")
    }
}

// K7-3: Teams.
#[async_trait]
pub trait TeamFlows: Send + Sync {
    async fn team_keys(&self, team: TeamId) -> Result<TeamKeys, SyncError> {
        let _ = team;
        unimplemented("keys.team_keys")
    }

    // A team creation: the owner's `key.member`, TK v1 with `start` 1 and its wrap to the owner's AEK.
    async fn create_team_keys(&self, team: TeamId) -> Result<(), SyncError> {
        let _ = team;
        unimplemented("keys.create_team_keys")
    }

    // This account's current certificate as `key.member`: on joining, with every replace, and after every `av` change.
    async fn publish_member_certificate(&self, team: TeamId) -> Result<(), SyncError> {
        let _ = team;
        unimplemented("keys.publish_member_certificate")
    }

    // An owner's or admin's Confirm: the current version wrapped to the member's AEK. Pins on first use.
    async fn confirm_member(&self, team: TeamId, account: AccountId) -> Result<(), SyncError> {
        let _ = (team, account);
        unimplemented("keys.confirm_member")
    }

    // The next version, its ring and a wrap to each holder on the roster with no open alert, less `remove`. Also how
    // an owner or admin who held a stopped device's version confirms it again.
    async fn rotate_team(&self, team: TeamId, remove: Vec<AccountId>) -> Result<(), SyncError> {
        let _ = (team, remove);
        unimplemented("keys.rotate_team")
    }

    // An owner's restart with `start` 1 when no member on the roster holds the current version, wrapping to `confirm`.
    async fn restart_team(&self, team: TeamId, confirm: Vec<AccountId>) -> Result<(), SyncError> {
        let _ = (team, confirm);
        unimplemented("keys.restart_team")
    }

    // "Credentials to rotate": the envelopes a removed party could read (0056, Old data).
    async fn credentials_to_rotate(&self, scope: ScopeName) -> Result<Vec<EnvelopeId>, SyncError> {
        let _ = scope;
        unimplemented("keys.credentials_to_rotate")
    }

    // The roster, `rotation_due` and the caller's role from a scopes body, decided on only after the team's pull is
    // caught up.
    async fn roster_read(&self, team: TeamId, roster: Roster) -> Result<(), SyncError> {
        let _ = (team, roster);
        unimplemented("keys.roster_read")
    }

    // A team scope's `key.member`, version records, rings and wraps.
    async fn apply_team_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        unimplemented("keys.apply_team_objects")
    }

    async fn seal_team_envelope(
        &self,
        team: TeamId,
        envelope: EnvelopeId,
        secret: SecretString,
        dest: Value,
    ) -> Result<Value, SyncError> {
        let _ = (team, envelope, secret, dest);
        unimplemented("keys.seal_team_envelope")
    }

    async fn open_team_envelope(
        &self,
        team: TeamId,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        let _ = (team, envelope, fields, in_force);
        unimplemented("keys.open_team_envelope")
    }
}

// K7-4: After a restore; What cannot go back.
#[async_trait]
pub trait RestoreFlows: Send + Sync {
    // On a new epoch, before any other record: the key objects this account signed that the snapshot lacks, as
    // change sets in 0051's order. The engine pushes them one at a time and answers each.
    async fn push_back(&self, epoch: EpochId) -> Result<Vec<KeyChangeSet>, SyncError> {
        let _ = epoch;
        unimplemented("keys.push_back")
    }

    // Every refusal is final: the scope ends on this device, or the account's devices lock.
    async fn push_back_answered(
        &self,
        set: KeyChangeSet,
        outcomes: Vec<ChangeOutcome>,
    ) -> Result<PushBackVerdict, SyncError> {
        let _ = (set, outcomes);
        unimplemented("keys.push_back_answered")
    }
}

// K7-4: A stopped device.
#[async_trait]
pub trait StopFlows: Send + Sync {
    // The reports and withdrawals to send, withdrawals first per team (0054, `key_pending`).
    async fn stop_actions(&self) -> Result<Vec<StopAction>, SyncError> {
        unimplemented("keys.stop_actions")
    }

    async fn stop_action_sent(&self, action: StopAction) -> Result<(), SyncError> {
        let _ = action;
        unimplemented("keys.stop_action_sent")
    }

    async fn resume_withdrawal(&self, team: TeamId) -> Result<(), SyncError> {
        let _ = team;
        unimplemented("keys.resume_withdrawal")
    }
}

// The engine's side: how a key flow stops or locks it and reports to the app. Each returns at once.
pub trait KeyHooks: Send + Sync {
    // Nothing personal syncs; the device keeps its keys and shows why.
    fn lock(&self, cause: LockCause);

    // The scope writes no secret under its key and holds its envelopes in the queue. The cause is the one its
    // `key_versions` row records (0062); a team due a rotation is the engine's own wait, from the scopes body.
    fn stop_scope(&self, scope: ScopeName, cause: StoppedCause);

    fn resume_scope(&self, scope: ScopeName);

    // Nothing clears it: a refused push-back or a fork (`keys.conflict`).
    fn end_scope(&self, scope: ScopeName, epoch: Option<EpochId>);

    fn notice(&self, notice: KeyNotice);

    // A flow wrote something a pass should carry.
    fn pass_soon(&self);
}

// A draft, review or other flow step this service holds between two calls.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DraftId(pub Uuid);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NoticeId(pub Uuid);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyState {
    // No secret store: team plaintext records only.
    NoDeviceStore,
    // The key kinds have not been read yet.
    Unknown,
    // The account has no `key.account`: genesis is offered.
    NoKeys,
    // The account has keys and this device holds none it can use: approval, recovery or reset is offered.
    NeedsApproval { request: Option<RequestId> },
    Approved { av: Version, key_device: KeyDeviceId },
    Locked { cause: LockCause },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LockCause {
    // 403 `device_removed`.
    DeviceRemoved,
    // A verified certificate at a newer `av` and none for this key device in its change set.
    LeftOutOfRotation,
    // An unendorsed IK on the own account, as after a reset elsewhere.
    OwnAccountReset,
    // A refused push-back of the account's own objects: sign out, then recover or reset.
    AccountEnded,
    // A state file with no anchor handles no secret until approved again or recovered.
    Unanchored,
    // A personal or history catch-up it could not verify (`keys.stale`).
    PersonalStopped,
}

// R as the person sees it once, and the two of its 14 groups they type back.
#[derive(Debug, Clone)]
pub struct RecoveryKeyDraft {
    pub draft: DraftId,
    pub text: SecretString,
    // Group indexes from 0 to 13, chosen at random.
    pub check: [u8; 2],
}

#[derive(Debug, Clone)]
pub struct TypedBack {
    pub groups: [SecretString; 2],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GenesisOutcome {
    Created,
    // The keys made here are discarded and the device asks for approval.
    AnotherDeviceWon,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SignOutOutcome {
    Revoked,
    // Offline: erased anyway; the row keeps the old certificate until approved again, left out or removed.
    ErasedOffline,
}

// R' as a draft, with the devices a rotation can keep, ticked by default when compared.
#[derive(Debug, Clone)]
pub struct RotationDraft {
    pub recovery: RecoveryKeyDraft,
    pub devices: Vec<ReviewedDevice>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyChange {
    pub account: AccountId,
    pub pinned: Fingerprint,
    pub offered: Fingerprint,
    pub offered_ik: Ed25519Public,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Fingerprint {
    // Words 0 to 5 of the account's fingerprint.
    pub words: Vec<String>,
    // `TPF1:` and 52 Base32 symbols.
    pub qr: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Acceptance {
    Compared,
    WithoutComparing,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyNotice {
    pub id: NoticeId,
    pub kind: KeyNoticeKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyNoticeKind {
    // "Ana replaced her recovery key."
    RecoveryKeyReplaced { account: AccountId },
    // An alert in every team the account is in.
    KeysChanged { account: AccountId },
    TeamKeyRestarted { team: TeamId },
    ResetPending { reset: ResetId },
    ResetEnded { reset: ResetId, state: ResetState },
    DeviceRemoved { device: DeviceRowId },
    // A wrap or version addressed to one of this account's superseded `av`s: the member copied its certificate again.
    SupersededWrap { team: TeamId },
    // A key object at a held id with other fields, or another record at an anchored version.
    Conflict { scope: ScopeName },
    ScopeStopped { scope: ScopeName, cause: StoppedCause },
    ScopeEnded { scope: ScopeName },
    Locked { cause: LockCause },
}

// What a pull served for the key layer, in revision order on a delta page; a snapshot's go in as one set once the
// pull is caught up (0056, Rollback).
#[derive(Debug, Clone, PartialEq)]
pub struct KeyArrival {
    pub scope: ScopeName,
    pub records: Vec<PulledRecord>,
    pub order: ArrivalOrder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArrivalOrder {
    InOrder,
    Snapshot,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct KeyApplied {
    // The scope key version in force after the last record, which the engine stores with the cursor.
    pub in_force: Option<Version>,
    // Held until the certificate or version record they name arrives, never refused for that.
    pub held: Vec<String>,
    pub refused: Vec<RefusedObject>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefusedObject {
    pub record_id: String,
    pub error: KeysError,
}

#[derive(Debug, Clone)]
pub struct OpenedEnvelope {
    pub secret: SecretString,
    // The destination it was sealed for, which the record's current fields must match at use.
    pub dest: Value,
    pub kv: Version,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalRequest {
    pub request: RequestId,
    pub device: Option<DeviceRowId>,
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub requested_at_us: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SessionRole {
    NewDevice,
    Approver,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionPhase {
    // N's request is written; no approver holds it yet.
    Open,
    // An approver wrote its `nonce` step.
    Chosen,
    // Both sides can show the words.
    Compare { words: Vec<String> },
    // This side's person confirmed; waiting for the other side.
    Confirmed,
    Approved,
    // Another approver holds the session: "being approved on Mac mini".
    TakenElsewhere,
    Cancelled { reason: SessionEnd },
    Expired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SessionEnd {
    User,
    Mismatch,
    Commitment,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalSession {
    pub request: RequestId,
    pub role: SessionRole,
    pub phase: SessionPhase,
    pub expires_at_us: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountDevice {
    pub key_device: KeyDeviceId,
    pub device: Option<DeviceRowId>,
    pub name: Option<String>,
    pub platform: Option<String>,
    pub added_at_us: Option<i64>,
    pub this_device: bool,
    // This device compared with it, so a rotation can keep it.
    pub compared: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemovalReview {
    pub review: DraftId,
    pub devices: Vec<ReviewedDevice>,
    // Members this account confirmed under an `av` a lost device held a certificate for.
    pub members: Vec<ReviewedMember>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewedDevice {
    pub device: AccountDevice,
    // Ticked by default: compared, and not one of the lost devices.
    pub keep_by_default: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ReviewedMember {
    pub team: TeamId,
    pub account: AccountId,
    pub confirmed_under_av: Version,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResetKind {
    // Kind 2: keeps the scope keys this device holds.
    KeepScopeKeys,
    // Kind 3: starts empty; the server deletes the personal and history records when it activates.
    StartEmpty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResetState {
    Pending,
    Cancelled,
    Superseded,
    Active,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingReset {
    pub reset: ResetId,
    pub kind: ResetKind,
    pub state: ResetState,
    // This device proposed it, so it may activate it.
    pub mine: bool,
    pub proposed_by: Option<DeviceRowId>,
    pub taken_at_us: i64,
    pub held_until_us: i64,
}

#[derive(Debug, Clone)]
pub enum CancelWith {
    // A device certified at the current `av`.
    ThisDevice,
    // R's IK signature, carried by any device of the account.
    RecoveryKey(SecretString),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamKeys {
    pub team: TeamId,
    pub version: Option<Version>,
    pub state: KeyVersionState,
    pub stopped_cause: Option<StoppedCause>,
    pub rotation_due: bool,
    // This account holds the current version.
    pub holder: bool,
    pub members: Vec<MemberKeys>,
    // The stop reports owners and admins see (0051, A stopped device).
    pub stopped: Vec<StoppedDevice>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoppedDevice {
    pub account: AccountId,
    pub device: DeviceRowId,
    pub version: Version,
    // This account held that version, so its rotation confirms the device again; the app offers it only then.
    pub can_reconfirm: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemberKeys {
    pub account: AccountId,
    pub role: Role,
    pub status: MemberKeyStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MemberKeyStatus {
    // "Waiting for this person to set up their keys."
    NoKeys,
    // "Waiting for confirmation."
    AwaitingConfirmation,
    Holder,
    // A key-change alert: nothing is wrapped to it until re-confirmed.
    Alert,
}

// A team scope as the scopes body gives it, with whether the team's pull is caught up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Roster {
    pub members: Vec<TeamMember>,
    pub role: Option<Role>,
    pub rotation_due: bool,
    // The stop reports, which the server serves to owners and admins only (0051, A stopped device).
    pub stopped: Vec<StopReport>,
    pub caught_up: bool,
}

impl Roster {
    pub fn of(scope: &ScopeInfo, caught_up: bool) -> Self {
        Self {
            members: scope.members.clone(),
            role: scope.role,
            rotation_due: scope.rotation_due,
            stopped: scope.stopped.clone(),
            caught_up,
        }
    }
}

// One change set as one push: only its own key objects, applied whole or not at all.
#[derive(Debug, Clone, PartialEq)]
pub struct KeyChangeSet {
    pub scope: ScopeName,
    pub changes: Vec<Change>,
    pub proof: DpopKey,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushBackVerdict {
    Continue,
    // The scope stops until what it waits for is back.
    Wait { scope: ScopeName },
    Ended { scope: ScopeName },
    // The account's own objects were refused: its devices lock.
    AccountEnded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StopAction {
    Report { team: TeamId, version: Version },
    Withdraw { team: TeamId },
}

impl StopAction {
    pub const fn pending_flow(self) -> Option<PendingFlow> {
        match self {
            Self::Report { .. } => None,
            Self::Withdraw { team } => Some(PendingFlow::StopWithdrawal { team }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Unfilled;

    impl AccountFlows for Unfilled {}
    impl ApprovalFlows for Unfilled {}
    impl DeviceFlows for Unfilled {}
    impl ResetFlows for Unfilled {}
    impl TeamFlows for Unfilled {}
    impl RestoreFlows for Unfilled {}
    impl StopFlows for Unfilled {}

    fn takes_flows(flows: &impl KeyFlows) -> &impl KeyFlows {
        flows
    }

    #[tokio::test]
    async fn an_unfilled_flow_answers_unimplemented_with_its_name() {
        let flows = takes_flows(&Unfilled);

        let genesis = flows.begin_genesis().await;
        let push_back = flows.push_back(EpochId(Uuid::nil())).await;

        assert_eq!(genesis.unwrap_err(), SyncError::unimplemented("keys.begin_genesis"));
        assert_eq!(push_back.unwrap_err().code(), "sync.unimplemented");
    }
}
