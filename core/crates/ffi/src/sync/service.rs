use std::sync::Arc;

use tablepro_records::Kind;
use tablepro_session::runtime::Tasks;
use tablepro_sync::SyncError;
use tablepro_sync::api::{CloudKitFailure, TransportError};

use super::cloudkit::{CloudKitBridge, CloudKitTransport};
use super::host::{HostDeviceStore, HostDeviceStoreBridge, HostSettings, HostSettingsBridge};
use super::keys::LockCauseTag;
use super::legacy::{HostLegacyMirror, LegacyMirrorBridge};
use crate::account::{AccountService, SyncProviderTag};
use crate::core_handle::Core;
use crate::error::CoreError;

// The typed fields a sync refusal carries, which the app acts on: RFC 9470's challenge to step up and retry, a
// `Retry-After`, the rejected change's own code (0051, Push), and why the device locked.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SyncFailureInfo {
    StepUp { acr_values: Vec<String>, max_age_secs: u64 },
    RetryAfter { ms: u64 },
    Rejected { code: String },
    Locked { cause: LockCauseTag },
}

fn failure_info(error: &SyncError) -> Option<SyncFailureInfo> {
    match error {
        SyncError::Transport(TransportError::StepUpRequired(challenge)) => Some(SyncFailureInfo::StepUp {
            acr_values: challenge.acr_values.clone(),
            max_age_secs: challenge.max_age_secs,
        }),
        SyncError::Transport(
            TransportError::RateLimited { retry_after_ms }
            | TransportError::RestoreCheckUnavailable { retry_after_ms }
            | TransportError::Server { retry_after_ms, .. },
        )
        | SyncError::CloudKit(CloudKitFailure::Throttled { retry_after_ms }) => {
            retry_after_ms.map(|ms| SyncFailureInfo::RetryAfter { ms })
        }
        SyncError::Rejected { code } => Some(SyncFailureInfo::Rejected {
            code: code.as_str().to_owned(),
        }),
        SyncError::Locked { cause } => Some(SyncFailureInfo::Locked { cause: (*cause).into() }),
        _ => None,
    }
}

impl From<SyncError> for CoreError {
    fn from(error: SyncError) -> Self {
        if error == SyncError::Cancelled {
            return Self::Cancelled;
        }
        let sync = failure_info(&error);
        match Self::failed(error.code(), error.to_string()) {
            Self::Failed { mut info } => {
                info.sync = sync;
                Self::Failed { info }
            }
            cancelled @ Self::Cancelled => cancelled,
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
    pub categories: SyncCategoriesArg,
}

// The kinds turned off on this device, by their wire names, and the password switch.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct SyncCategoriesArg {
    pub off_kinds: Vec<String>,
    pub passwords: bool,
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
    pub(crate) cloudkit: Option<Arc<dyn tablepro_sync::api::CloudKitTransport>>,
    pub(crate) settings: Option<Arc<dyn tablepro_sync::api::HostSettings>>,
    pub(crate) device_store: Option<Arc<dyn tablepro_sync::api::HostDeviceStore>>,
    pub(crate) legacy_mirror: Option<Arc<dyn tablepro_sync::api::LegacyMirror>>,
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
    // The Apple apps pass their CloudKit transport and device store, and the Mac its legacy mirror while the previous
    // stable runs the Swift engine. Windows passes none: the core reaches Credential Manager itself.
    #[expect(
        clippy::too_many_arguments,
        reason = "a UniFFI record cannot carry callback interfaces, so each host service is its own argument"
    )]
    pub fn open_sync(
        &self,
        config: SyncConfig,
        account: Arc<AccountService>,
        cloudkit: Option<Arc<dyn CloudKitTransport>>,
        settings: Option<Box<dyn HostSettings>>,
        device_store: Option<Box<dyn HostDeviceStore>>,
        legacy_mirror: Option<Box<dyn HostLegacyMirror>>,
        listener: Box<dyn SyncListener>,
    ) -> Result<Arc<SyncService>, CoreError> {
        let tasks = self.tasks.clone();
        let kind = match config.platform {
            SyncPlatformTag::Macos => Kind::MacosSettings,
            SyncPlatformTag::Ios => Kind::IosSettings,
            SyncPlatformTag::Linux => Kind::LinuxSettings,
            SyncPlatformTag::Windows => Kind::WindowsSettings,
        };
        let cloudkit =
            cloudkit.map(|host| Arc::new(CloudKitBridge(host)) as Arc<dyn tablepro_sync::api::CloudKitTransport>);
        let settings = settings.map(|host| {
            Arc::new(HostSettingsBridge {
                host: Arc::from(host),
                kind,
                tasks: tasks.clone(),
            }) as Arc<dyn tablepro_sync::api::HostSettings>
        });
        let device_store = device_store.map(|host| {
            Arc::new(HostDeviceStoreBridge {
                host: Arc::from(host),
                tasks: tasks.clone(),
            }) as Arc<dyn tablepro_sync::api::HostDeviceStore>
        });
        let legacy_mirror = legacy_mirror.map(|host| {
            Arc::new(LegacyMirrorBridge {
                host: Arc::from(host),
                tasks: tasks.clone(),
            }) as Arc<dyn tablepro_sync::api::LegacyMirror>
        });
        Ok(Arc::new(SyncService {
            tasks,
            account,
            config,
            cloudkit,
            settings,
            device_store,
            legacy_mirror,
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
    // A store the app keeps wrote, after the write landed.
    Journal,
    // `CKAccountChanged`, after the operations in flight were cancelled.
    AccountChanged,
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

// The changes the last account's file held unsent, for the Move my data or Start empty prompt.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NewIdentityPlanInfo {
    pub unsent: u64,
}

// Values are JSON text. `digest` names the pulled value the person is shown, as lower-case hex, and goes back with the
// decision: a value a pull changed since is not decided (core ADR 0066).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PendingApprovalInfo {
    pub record: SyncRecordRef,
    pub field: String,
    pub pulled: String,
    pub digest: String,
    pub current: Option<String>,
}

// None is a deletion. `digest` names the conflict as listed, as lower-case hex, and goes back with the choice.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamConflictInfo {
    pub record: SyncRecordRef,
    pub fields: Vec<String>,
    pub mine: Option<String>,
    pub theirs: Option<String>,
    pub digest: String,
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

    pub async fn set_categories(&self, categories: SyncCategoriesArg) -> Result<(), CoreError> {
        let _ = categories;
        unfilled("sync.set_categories")
    }

    // A store the app still keeps wrote these records of `kind`, after its write landed (core ADR 0060).
    pub async fn record_host_changes(
        &self,
        kind: String,
        written: Vec<String>,
        deleted: Vec<String>,
    ) -> Result<(), CoreError> {
        let _ = (kind, written, deleted);
        unfilled("sync.host_changed")
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

    pub async fn plan_new_identity(&self) -> Result<NewIdentityPlanInfo, CoreError> {
        unfilled("sync.plan_new_identity")
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

    // `digest` is the approval's, as `approvals` gave it; a pull that changed the value since answers `sync.changed`.
    pub async fn decide_approval(
        &self,
        record: SyncRecordRef,
        field: String,
        digest: String,
        approve: bool,
    ) -> Result<(), CoreError> {
        let _ = (record, field, digest, approve);
        unfilled("sync.decide_approval")
    }

    pub async fn conflicts(&self) -> Result<Vec<TeamConflictInfo>, CoreError> {
        unfilled("sync.conflicts")
    }

    // `digest` is the conflict's, as `conflicts` gave it; a pull that replaced the conflict since answers `sync.changed`.
    pub async fn resolve_conflict(
        &self,
        record: SyncRecordRef,
        digest: String,
        keep: ConflictChoiceTag,
    ) -> Result<(), CoreError> {
        let _ = (record, digest, keep);
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
