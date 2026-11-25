// The key flows as the person and the engine see them, with 0056's states and refusals but none of its cryptography
// beyond the recovery key's text, the SAS words and the fingerprints, which are real. Envelopes and history entries are
// sealed in the clear in a form that says so; their key version rules hold. For the UI lanes and the engine's tests,
// never for a check of the keys themselves.

mod account;
mod approval;
mod device;
mod reset;
mod team;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, MutexGuard, PoisonError};

use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, RequestId, TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::MemberKeyStatus;
use tablepro_sync::api::key_flows::{
    AccountDevice, ApprovalRequest, DraftId, KeyChangeSet, KeyHooks, KeyNotice, KeyState, LockCause, PendingReset,
    ReviewedMember, SessionPhase, SessionRole, StopAction, StopCause, TypedBack,
};
use tablepro_sync::api::scopes::Role;
use uuid::Uuid;

pub(crate) const SESSION_US: i64 = 600 * 1_000_000;
pub(crate) const RESET_HOLD_US: i64 = 7 * 24 * 3600 * 1_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DraftPurpose {
    Genesis,
    Replace,
    Reset(tablepro_sync::api::key_flows::ResetKind),
}

#[derive(Debug, Clone)]
pub(crate) struct Draft {
    pub(crate) purpose: DraftPurpose,
    pub(crate) text: SecretString,
    pub(crate) check: [u8; 2],
}

#[derive(Debug, Clone)]
pub(crate) struct Session {
    pub(crate) role: SessionRole,
    pub(crate) phase: SessionPhase,
    pub(crate) expires_at_us: i64,
}

#[derive(Debug, Clone)]
pub(crate) struct FakeTeam {
    pub(crate) role: Role,
    pub(crate) version: Option<Version>,
    pub(crate) holder: bool,
    pub(crate) rotation_due: bool,
    pub(crate) members: BTreeMap<AccountId, (Role, MemberKeyStatus)>,
}

#[derive(Debug)]
pub(crate) struct Model {
    pub(crate) key_state: KeyState,
    pub(crate) av: u32,
    pub(crate) recovery: Option<SecretString>,
    pub(crate) drafts: HashMap<DraftId, Draft>,
    pub(crate) another_device_won: bool,
    pub(crate) sessions: HashMap<RequestId, Session>,
    pub(crate) incoming: Vec<ApprovalRequest>,
    pub(crate) taken_elsewhere: Vec<RequestId>,
    pub(crate) devices: Vec<AccountDevice>,
    pub(crate) reviews: HashMap<DraftId, Vec<KeyDeviceId>>,
    pub(crate) confirmed_under: Vec<ReviewedMember>,
    pub(crate) step_up_fresh: bool,
    pub(crate) offline: bool,
    pub(crate) reset: Option<PendingReset>,
    pub(crate) teams: BTreeMap<TeamId, FakeTeam>,
    pub(crate) notices: Vec<KeyNotice>,
    pub(crate) stop_actions: Vec<StopAction>,
    pub(crate) push_back: Vec<KeyChangeSet>,
    pub(crate) identities: HashMap<AccountId, Ed25519Public>,
    pub(crate) history_version: u32,
    pub(crate) held_kv: HashMap<(ScopeName, String), u32>,
    pub(crate) credentials: Vec<EnvelopeId>,
    pub(crate) clock_us: i64,
}

#[derive(Debug)]
pub struct FakeKeyFlows {
    pub(crate) origin: Origin,
    pub(crate) account: AccountId,
    pub(crate) key_device: KeyDeviceId,
    pub(crate) model: Mutex<Model>,
}

impl FakeKeyFlows {
    // An account that has no keys yet: genesis is offered.
    pub fn new(origin: Origin, account: AccountId) -> Self {
        Self {
            origin,
            account,
            key_device: KeyDeviceId(Uuid::new_v4()),
            model: Mutex::new(Model {
                key_state: KeyState::NoKeys,
                av: 0,
                recovery: None,
                drafts: HashMap::new(),
                another_device_won: false,
                sessions: HashMap::new(),
                incoming: Vec::new(),
                taken_elsewhere: Vec::new(),
                devices: Vec::new(),
                reviews: HashMap::new(),
                confirmed_under: Vec::new(),
                step_up_fresh: false,
                offline: false,
                reset: None,
                teams: BTreeMap::new(),
                notices: Vec::new(),
                stop_actions: Vec::new(),
                push_back: Vec::new(),
                identities: HashMap::new(),
                history_version: 0,
                held_kv: HashMap::new(),
                credentials: Vec::new(),
                clock_us: 1_767_225_600_000_000,
            }),
        }
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, Model> {
        self.model.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn key_device(&self) -> KeyDeviceId {
        self.key_device
    }

    pub fn recovery_key(&self) -> Option<SecretString> {
        self.lock().recovery.clone()
    }

    // The account's R, as another device's genesis made it.
    pub fn set_recovery_key(&self, text: SecretString) {
        self.lock().recovery = Some(text);
    }

    // The account already has keys from another device: this one needs approval.
    pub fn account_has_keys(&self) {
        let mut model = self.lock();
        model.key_state = KeyState::NeedsApproval { request: None };
        model.av = model.av.max(1);
    }

    // Another device's genesis lands first.
    pub fn another_device_wins_genesis(&self) {
        self.lock().another_device_won = true;
    }

    pub fn set_step_up(&self, fresh: bool) {
        self.lock().step_up_fresh = fresh;
    }

    pub fn set_offline(&self, offline: bool) {
        self.lock().offline = offline;
    }

    pub fn advance_clock(&self, micros: i64) {
        self.lock().clock_us += micros;
    }

    pub fn add_device(&self, device: AccountDevice) {
        self.lock().devices.push(device);
    }

    pub fn incoming_request(&self, request: ApprovalRequest) {
        let mut model = self.lock();
        let expires_at_us = request.requested_at_us + SESSION_US;
        model.sessions.insert(
            request.request,
            Session {
                role: SessionRole::Approver,
                phase: SessionPhase::Open,
                expires_at_us,
            },
        );
        model.incoming.push(request);
    }

    // Another approver wrote its `nonce` step first.
    pub fn taken_by_another_approver(&self, request: RequestId) {
        self.lock().taken_elsewhere.push(request);
    }

    // The approver chose this device's request, and its reveal went up: both sides can show the words.
    pub fn approver_chose(&self, request: RequestId) {
        let words = account::sas_words();
        if let Some(session) = self.lock().sessions.get_mut(&request) {
            session.phase = SessionPhase::Compare { words };
        }
    }

    pub fn add_team(&self, team: TeamId, role: Role, members: &[(AccountId, Role, MemberKeyStatus)]) {
        self.lock().teams.insert(
            team,
            FakeTeam {
                role,
                version: None,
                holder: false,
                rotation_due: false,
                members: members
                    .iter()
                    .map(|(account, role, status)| (*account, (*role, *status)))
                    .collect(),
            },
        );
    }

    pub fn confirmed_while_lost_device_held_keys(&self, member: ReviewedMember) {
        self.lock().confirmed_under.push(member);
    }

    // A key change with no endorsement: an alert in every team the account is in.
    pub fn raise_alert(&self, account: AccountId) {
        let mut model = self.lock();
        for team in model.teams.values_mut() {
            if let Some((_, status)) = team.members.get_mut(&account) {
                *status = MemberKeyStatus::Alert;
            }
        }
        account::notice(
            &mut model,
            tablepro_sync::api::key_flows::KeyNoticeKind::KeysChanged { account },
        );
    }

    pub fn queue_stop_action(&self, action: StopAction) {
        self.lock().stop_actions.push(action);
    }

    pub fn queue_push_back(&self, set: KeyChangeSet) {
        self.lock().push_back.push(set);
    }

    pub fn set_credentials_to_rotate(&self, envelopes: Vec<EnvelopeId>) {
        self.lock().credentials = envelopes;
    }

    pub fn now_us(&self) -> i64 {
        self.lock().clock_us
    }
}

pub(crate) fn require_approved(model: &Model, what: &'static str) -> Result<(), SyncError> {
    match model.key_state {
        KeyState::Approved { .. } => Ok(()),
        KeyState::Locked { cause } => Err(SyncError::Locked { cause }),
        _ => Err(SyncError::NotAllowed { what }),
    }
}

pub(crate) fn version(number: u32) -> Result<Version, SyncError> {
    Version::new(number).map_err(SyncError::from)
}

// R's 14 groups, as the text shows them.
pub(crate) fn groups(text: &SecretString) -> Vec<String> {
    text.expose_secret().split('-').map(str::to_owned).collect()
}

// A group as reading the recovery key reads it (0056, The recovery key, Text).
fn normalized(group: &str) -> String {
    group
        .chars()
        .filter(|character| !matches!(character, '-' | ' '))
        .map(|character| match character.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect()
}

pub(crate) fn check_typed_back(draft: &Draft, typed: &TypedBack) -> Result<(), SyncError> {
    let groups = groups(&draft.text);
    let matches = draft.check.iter().zip(&typed.groups).all(|(index, typed)| {
        groups
            .get(usize::from(*index))
            .is_some_and(|group| normalized(typed.expose_secret()) == *group)
    });
    if matches {
        Ok(())
    } else {
        Err(SyncError::TypedBackWrong)
    }
}

pub(crate) fn same_recovery_key(held: Option<&SecretString>, typed: &SecretString) -> Result<(), SyncError> {
    let typed = RecoveryKey::parse(typed.expose_secret())?;
    let held = held.ok_or(SyncError::NotAllowed {
        what: "use a recovery key",
    })?;
    let held = RecoveryKey::parse(held.expose_secret())?;
    if typed.expose() == held.expose() {
        Ok(())
    } else {
        Err(SyncError::Keys(KeysError::Signature))
    }
}

pub(crate) fn new_draft(model: &mut Model, purpose: DraftPurpose) -> Result<(DraftId, Draft), SyncError> {
    let text = RecoveryKey::generate()?.to_text()?;
    let random = Uuid::new_v4().into_bytes();
    let first = random[0] % 14;
    let second = (first + 1 + random[1] % 13) % 14;
    let draft = Draft {
        purpose,
        text,
        check: [first, second],
    };
    let id = DraftId(Uuid::new_v4());
    model.drafts.insert(id, draft.clone());
    Ok((id, draft))
}

// The engine side of `KeyHooks`, recording each call for a test to read.
#[derive(Debug, Default)]
pub struct RecordingHooks {
    calls: Mutex<Vec<HookCall>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookCall {
    Lock(LockCause),
    Stop(ScopeName, StopCause),
    Resume(ScopeName),
    End(ScopeName, Option<tablepro_sync::api::ids::EpochId>),
    Notice(KeyNotice),
    PassSoon,
}

impl RecordingHooks {
    pub fn calls(&self) -> Vec<HookCall> {
        self.calls.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn record(&self, call: HookCall) {
        self.calls.lock().unwrap_or_else(PoisonError::into_inner).push(call);
    }
}

impl KeyHooks for RecordingHooks {
    fn lock(&self, cause: LockCause) {
        self.record(HookCall::Lock(cause));
    }

    fn stop_scope(&self, scope: ScopeName, cause: StopCause) {
        self.record(HookCall::Stop(scope, cause));
    }

    fn resume_scope(&self, scope: ScopeName) {
        self.record(HookCall::Resume(scope));
    }

    fn end_scope(&self, scope: ScopeName, epoch: Option<tablepro_sync::api::ids::EpochId>) {
        self.record(HookCall::End(scope, epoch));
    }

    fn notice(&self, notice: KeyNotice) {
        self.record(HookCall::Notice(notice));
    }

    fn pass_soon(&self) {
        self.record(HookCall::PassSoon);
    }
}
