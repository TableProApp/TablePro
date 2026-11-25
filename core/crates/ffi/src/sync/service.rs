use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_sync::SyncError;

use super::cloudkit::CloudKitTransport;
use super::host::{HostDeviceStore, HostSettings};
use crate::account::{AccountService, SyncProviderTag};
use crate::core_handle::Core;
use crate::error::CoreError;

impl From<SyncError> for CoreError {
    fn from(error: SyncError) -> Self {
        match error {
            SyncError::Cancelled => Self::Cancelled,
            error => Self::failed(error.code(), error.to_string()),
        }
    }
}

// A contract whose lane has not filled it yet answers `sync.unimplemented`.
pub(crate) fn unfilled<T>(what: &'static str) -> Result<T, CoreError> {
    Err(SyncError::unimplemented(what).into())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncPlatformTag {
    Macos,
    Ios,
    Linux,
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncConfig {
    pub platform: SyncPlatformTag,
}

// Told that something changed, on a runtime thread. It only schedules a read on the app's own thread: no work, and
// nothing that blocks (core ADR 0002).
#[uniffi::export(callback_interface)]
pub trait SyncListener: Send + Sync {
    // `status`, the approvals, the conflicts or the held records changed.
    fn status_changed(&self);

    // The key state, a session, a reset, a team's keys or the key notices changed.
    fn keys_changed(&self);
}

// One per app, over the account it was opened with. Dropping it stops the scheduler.
#[derive(uniffi::Object)]
#[expect(dead_code, reason = "the engine's lanes run the service over these")]
pub struct SyncService {
    pub(crate) tasks: Tasks,
    pub(crate) account: Arc<AccountService>,
    pub(crate) config: SyncConfig,
    pub(crate) cloudkit: Option<Arc<dyn CloudKitTransport>>,
    pub(crate) settings: Option<Arc<dyn HostSettings>>,
    pub(crate) device_store: Option<Arc<dyn HostDeviceStore>>,
    pub(crate) listener: Arc<dyn SyncListener>,
}

impl std::fmt::Debug for SyncService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncService")
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

#[uniffi::export]
impl Core {
    // The Apple apps pass their CloudKit transport and device store; Windows and Linux pass neither, since the core
    // reaches Credential Manager and the Secret Service itself and they have no iCloud.
    pub fn open_sync(
        &self,
        config: SyncConfig,
        account: Arc<AccountService>,
        cloudkit: Option<Arc<dyn CloudKitTransport>>,
        settings: Option<Box<dyn HostSettings>>,
        device_store: Option<Box<dyn HostDeviceStore>>,
        listener: Box<dyn SyncListener>,
    ) -> Result<Arc<SyncService>, CoreError> {
        Ok(Arc::new(SyncService {
            tasks: self.tasks.clone(),
            account,
            config,
            cloudkit,
            settings: settings.map(Arc::from),
            device_store: device_store.map(Arc::from),
            listener: Arc::from(listener),
        }))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncPhaseTag {
    Off,
    Unavailable,
    Idle,
    Syncing,
    Waiting { retry_in_ms: u64 },
    PullOnly,
    ZoneRemoved,
    NewIdentity,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncStatusInfo {
    pub provider: Option<SyncProviderTag>,
    pub phase: SyncPhaseTag,
    pub last_pass_ms: Option<i64>,
    // The last pass's error code.
    pub problem: Option<String>,
    pub waiting_approvals: u32,
    pub conflicts: u32,
    pub held: u32,
    pub queued_changes: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PassReasonTag {
    Launch,
    Foreground,
    NetworkBack,
    CloudKitPush,
    Person,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NewIdentityChoiceTag {
    MoveMyData,
    StartEmpty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictChoiceTag {
    KeepMine,
    KeepTheirs,
}

// A synced record: its scope as the wire names it (`personal`, `history` or `team_...`), its kind and its id.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SyncRecordRef {
    pub scope: String,
    pub kind: String,
    pub record_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MovePlanInfo {
    pub records: u64,
    pub staying_behind: u64,
    pub secrets_to_seal: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MoveBackPlanInfo {
    pub icloud_deletions: u64,
}

// Values are JSON text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PendingApprovalInfo {
    pub record: SyncRecordRef,
    pub field: String,
    pub pulled: String,
    pub current: Option<String>,
}

// None is a deletion.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamConflictInfo {
    pub record: SyncRecordRef,
    pub fields: Vec<String>,
    pub mine: Option<String>,
    pub theirs: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HeldReasonTag {
    Unreadable,
    UnknownKind,
    AwaitingApproval,
    // Over 1 MiB, or a value the server's rules refuse, with the server's code.
    Refused { code: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeldRecordInfo {
    pub record: SyncRecordRef,
    pub reason: HeldReasonTag,
}

#[uniffi::export]
impl SyncService {
    pub fn status(&self) -> SyncStatusInfo {
        SyncStatusInfo {
            provider: None,
            phase: SyncPhaseTag::Unavailable,
            last_pass_ms: None,
            problem: Some(SyncError::unimplemented("sync.status").code().to_owned()),
            waiting_approvals: 0,
            conflicts: 0,
            held: 0,
            queued_changes: 0,
        }
    }

    pub async fn sync_now(&self, why: PassReasonTag) -> Result<(), CoreError> {
        let _ = why;
        unfilled("sync.sync_now")
    }

    // Among what the managed policy allows (core ADR 0055).
    pub async fn choose_provider(&self, provider: SyncProviderTag) -> Result<(), CoreError> {
        let _ = provider;
        unfilled("sync.choose_provider")
    }

    pub async fn plan_move_to_service(&self) -> Result<MovePlanInfo, CoreError> {
        unfilled("sync.plan_move_to_service")
    }

    pub async fn move_to_service(&self) -> Result<(), CoreError> {
        unfilled("sync.move_to_service")
    }

    pub async fn plan_move_to_icloud(&self) -> Result<MoveBackPlanInfo, CoreError> {
        unfilled("sync.plan_move_to_icloud")
    }

    // Refused unless the count is the plan's, which the person confirmed.
    pub async fn move_to_icloud(&self, confirmed_deletions: u64) -> Result<(), CoreError> {
        let _ = confirmed_deletions;
        unfilled("sync.move_to_icloud")
    }

    pub async fn choose_for_new_identity(&self, choice: NewIdentityChoiceTag) -> Result<(), CoreError> {
        let _ = choice;
        unfilled("sync.choose_for_new_identity")
    }

    pub async fn upload_again(&self) -> Result<(), CoreError> {
        unfilled("sync.upload_again")
    }

    pub async fn delete_icloud_zone(&self) -> Result<(), CoreError> {
        unfilled("sync.delete_icloud_zone")
    }

    pub async fn approvals(&self) -> Result<Vec<PendingApprovalInfo>, CoreError> {
        unfilled("sync.approvals")
    }

    pub async fn decide_approval(&self, record: SyncRecordRef, field: String, approve: bool) -> Result<(), CoreError> {
        let _ = (record, field, approve);
        unfilled("sync.decide_approval")
    }

    pub async fn conflicts(&self) -> Result<Vec<TeamConflictInfo>, CoreError> {
        unfilled("sync.conflicts")
    }

    pub async fn resolve_conflict(&self, record: SyncRecordRef, keep: ConflictChoiceTag) -> Result<(), CoreError> {
        let _ = (record, keep);
        unfilled("sync.resolve_conflict")
    }

    pub async fn held_records(&self) -> Result<Vec<HeldRecordInfo>, CoreError> {
        unfilled("sync.held_records")
    }

    // True while older entries remain on the server.
    pub async fn load_older_history(&self) -> Result<bool, CoreError> {
        unfilled("sync.load_older_history")
    }
}
