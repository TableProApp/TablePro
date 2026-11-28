use std::future::Future;
use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_sync::SyncError;
use tablepro_sync::api::control::{SyncControl, SyncStatus};
use tablepro_sync::api::{CloudKitFailure, KindName, ScopeName, TransportError};
use tablepro_sync::engine::Journal;
use tokio_util::task::AbortOnDropHandle;

use super::engines::{IcloudEngine, ServiceSlot, icloud_categories, journal};
use super::keys::LockCauseTag;
use super::service_records::{categories_arg, digest_arg, record_arg};
use crate::account::{AccountService, SyncProviderTag};
use crate::error::CoreError;
use crate::runtime::on_runtime;

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
        // The challenge goes where an account step-up carries its own, so a host reads it from one place.
        let step_up = match &error {
            SyncError::Transport(TransportError::StepUpRequired(challenge)) => {
                Some(crate::account::StepUpChallengeInfo {
                    acr_values: challenge.acr_values.clone(),
                    max_age_secs: Some(challenge.max_age_secs),
                })
            }
            _ => None,
        };
        match Self::failed(error.code(), error.to_string()) {
            Self::Failed { mut info } => {
                info.sync = sync;
                info.step_up = step_up;
                Self::Failed { info }
            }
            cancelled @ Self::Cancelled => cancelled,
        }
    }
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
    // The provider for personal data that the app keeps (core ADR 0054, The provider key). Team scopes and the key
    // objects always use TablePro Sync.
    pub provider: SyncProviderTag,
    pub categories: SyncCategoriesArg,
    // The iCloud account whose state file this device used last, which `SyncService::icloud_account` gives the app to
    // keep; None on first use. A switch made while the app was closed deletes that account's file.
    #[uniffi(default = None)]
    pub icloud_account: Option<String>,
    // The TablePro Sync sign-in whose state file this device used last, as `SyncService::service_account` gave it;
    // None on first use. Another account or server then waits for Move my data or Start empty (core ADR 0054).
    #[uniffi(default = None)]
    pub service_account: Option<String>,
    // This device's id as the host keeps it, which names the SSH routes it publishes, so it clears only its own.
    #[uniffi(default = None)]
    pub route_publisher: Option<String>,
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
    // `status`, the conflicts or the held records changed.
    fn status_changed(&self);

    // The key state, a session, a reset, a team's keys or the key notices changed.
    fn keys_changed(&self);

    // The values waiting for the person changed: a pull brought or cleared some, or a decision took some, so the app
    // reads `approvals` again.
    fn approvals_changed(&self);
}

// One per app, over the stores of the Core it was opened on and the sign-in it was given. Dropping it stops the
// engines and their schedulers.
#[derive(uniffi::Object)]
pub struct SyncService {
    pub(crate) tasks: Tasks,
    pub(crate) account: Option<Arc<AccountService>>,
    pub(crate) config: SyncConfig,
    pub(crate) icloud: Result<IcloudEngine, SyncError>,
    pub(crate) service: Arc<ServiceSlot>,
    // This Core's connections, which name what a removed party could read.
    pub(crate) connections: Option<tablepro_storage::ConnectionStore>,
    // The downgrade mirror's marks while no iCloud engine carries them.
    pub(crate) legacy_marks: Option<Arc<tablepro_sync::cloudkit::LegacyMarks>>,
    pub(crate) _marks_hear_stores: Option<tablepro_sync::adapters::store_journal::Listening>,
    // CloudKit and this Core's state files, which the moves between providers need whatever the provider is.
    pub(crate) cloudkit: Option<Arc<dyn tablepro_sync::api::CloudKitTransport>>,
    pub(crate) files: Option<Arc<dyn tablepro_sync::api::StateFiles>>,
    pub(crate) _forward: AbortOnDropHandle<()>,
    // Leaves a provider as soon as the values the host passes again no longer allow it (core ADR 0055).
    pub(crate) _policy: std::sync::Mutex<Option<AbortOnDropHandle<()>>>,
}

impl std::fmt::Debug for SyncService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncService")
            .field("config", &self.config)
            .finish_non_exhaustive()
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
    // Nothing else to do, with values waiting for the person: `approvals` lists them.
    NeedsApproval,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncStatusInfo {
    pub provider: Option<SyncProviderTag>,
    pub phase: SyncPhaseTag,
    pub last_pass_ms: Option<i64>,
    // The last pass's error code.
    pub problem: Option<String>,
    // Records with a value waiting for the person, the team scopes' included whatever the personal provider is.
    pub waiting_approvals: u32,
    pub conflicts: u32,
    pub held: u32,
    pub queued_changes: u32,
}

// A scope as the server's last scopes body named it (core ADR 0051, Scopes; Policies). A switch is None where the scope
// carries none; `writable` is false past grace or after a lapse, when only key-object writes are taken.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScopeStatusInfo {
    pub scope: String,
    pub writable: bool,
    pub personal_sync: Option<bool>,
    pub password_sync: Option<bool>,
    pub history_sync: Option<bool>,
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

// The changes the last account's file held unsent, for the Move my data or Start empty prompt, and the account the
// prompt is for, which the answer names back.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NewIdentityPlanInfo {
    pub unsent: u64,
    pub account: String,
}

// A record with values a pull brought that wait for the person (core ADR 0044, Fields a pull applies only with
// approval). `digest` names every value listed, as lower-case hex, and goes back with a decision on the whole record.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RecordApprovalInfo {
    pub record: SyncRecordRef,
    // The record's name, else its settings category; None when it has neither.
    pub name: Option<String>,
    // The device holds no copy: the record lands once every value is approved, and a refusal keeps it off the device.
    pub new_record: bool,
    pub digest: String,
    pub fields: Vec<FieldApprovalInfo>,
}

// Values are JSON text. `field` is a JSON Pointer into the record. `current` is None when the device holds no value,
// `pulled` when the pull removes it. `digest` names the pulled value, as lower-case hex, and goes back with a decision
// on this value: one a pull changed since is not decided (core ADR 0066).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FieldApprovalInfo {
    pub field: String,
    pub current: Option<String>,
    pub pulled: Option<String>,
    pub digest: String,
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
    // This device is not approved yet, so it holds what it may not apply (core ADR 0056).
    AwaitingDeviceApproval,
    // Over 1 MiB, or a value the server's rules refuse, with the server's code.
    Refused { code: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeldRecordInfo {
    pub record: SyncRecordRef,
    pub reason: HeldReasonTag,
}

// What the team scopes hold is the person's to see too, and a value waiting there asks for them as a personal one
// does, whatever the personal provider is.
pub(crate) fn with_teams(mut status: SyncStatusInfo, teams: Option<&SyncStatus>) -> SyncStatusInfo {
    if let Some(teams) = teams {
        status.waiting_approvals = status.waiting_approvals.saturating_add(teams.waiting_approvals);
        status.conflicts = status.conflicts.saturating_add(teams.conflicts);
        status.held = status.held.saturating_add(teams.held);
    }
    if status.waiting_approvals > 0 && matches!(status.phase, SyncPhaseTag::Idle | SyncPhaseTag::Off) {
        status.phase = SyncPhaseTag::NeedsApproval;
    }
    status
}

// Which engine a call reaches on the runtime: the personal provider's for personal data and history, and TablePro
// Sync's for the team scopes, whatever the personal provider is (core ADR 0054, Providers).
#[derive(Clone)]
struct Route {
    provider: SyncProviderTag,
    icloud: Result<Arc<dyn SyncControl>, SyncError>,
    service: Arc<ServiceSlot>,
}

const OFF: SyncError = SyncError::NotAllowed {
    what: "sync personal data while sync is off",
};

impl Route {
    async fn service(&self) -> Result<Arc<dyn SyncControl>, SyncError> {
        self.service
            .engine()
            .await
            .map(|engine| Arc::clone(&engine.sync) as Arc<dyn SyncControl>)
    }

    async fn personal(&self) -> Result<Arc<dyn SyncControl>, SyncError> {
        match self.provider {
            SyncProviderTag::Icloud => self.icloud.clone(),
            SyncProviderTag::TableproSync => self.service().await,
            SyncProviderTag::Off => Err(OFF),
        }
    }

    async fn for_scope(&self, scope: ScopeName) -> Result<Arc<dyn SyncControl>, SyncError> {
        match scope {
            ScopeName::Team(_) => self.service().await,
            ScopeName::Personal | ScopeName::History => self.personal().await,
        }
    }

    // TablePro Sync's engine for the team scopes, or None when there is no sign-in to run it on a device whose
    // personal provider is another; any other failure is the answer.
    async fn teams(&self) -> Result<Option<Arc<dyn SyncControl>>, SyncError> {
        match self.service().await {
            Ok(control) => Ok(Some(control)),
            Err(SyncError::Transport(TransportError::SignedOut)) if self.provider != SyncProviderTag::TableproSync => {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    // The engines that hold records here, the personal provider's first, each looked up on its own, and the first
    // failure of one that should run.
    async fn running(&self) -> (Vec<Arc<dyn SyncControl>>, Option<SyncError>) {
        let mut engines = Vec::new();
        let mut failed = None;
        if self.provider == SyncProviderTag::Icloud {
            match self.icloud.clone() {
                Ok(control) => engines.push(control),
                Err(error) => failed = Some(error),
            }
        }
        match self.teams().await {
            Ok(Some(control)) => engines.push(control),
            Ok(None) => {}
            Err(error) => {
                failed.get_or_insert(error);
            }
        }
        (engines, failed)
    }
}

impl SyncService {
    fn route(&self) -> Route {
        Route {
            provider: self.config.provider,
            icloud: self
                .icloud
                .as_ref()
                .map(|engine| Arc::clone(&engine.sync) as Arc<dyn SyncControl>)
                .map_err(Clone::clone),
            service: Arc::clone(&self.service),
        }
    }

    fn personal_status(&self) -> SyncStatusInfo {
        if self.config.provider == SyncProviderTag::Off {
            return SyncStatusInfo {
                provider: Some(SyncProviderTag::Off),
                phase: SyncPhaseTag::Off,
                last_pass_ms: None,
                problem: None,
                waiting_approvals: 0,
                conflicts: 0,
                held: 0,
                queued_changes: 0,
            };
        }
        match self.control_now() {
            Ok(control) => control.status().into(),
            // No engine holds personal data, so none of it can be counted.
            Err(error) => SyncStatusInfo {
                provider: Some(self.config.provider),
                // A start waiting for the state file the closing service still holds is a wait, not an outage.
                phase: if self.config.provider == SyncProviderTag::TableproSync && self.service.waits_for_file() {
                    SyncPhaseTag::Waiting {
                        retry_in_ms: u64::try_from(super::engines::FILE_POLL.as_millis()).unwrap_or(u64::MAX),
                    }
                } else {
                    SyncPhaseTag::Unavailable
                },
                last_pass_ms: None,
                problem: Some(error.code().to_owned()),
                waiting_approvals: 0,
                conflicts: 0,
                held: 0,
                queued_changes: 0,
            },
        }
    }

    // The personal provider's engine as it stands, for the calls that answer at once.
    fn control_now(&self) -> Result<Arc<dyn SyncControl>, SyncError> {
        match self.config.provider {
            SyncProviderTag::Icloud => self.route().icloud,
            SyncProviderTag::TableproSync => self
                .service
                .now()
                .map(|engine| Arc::clone(&engine.sync) as Arc<dyn SyncControl>),
            SyncProviderTag::Off => Err(OFF),
        }
    }

    // Runs `work` over the route on the runtime.
    async fn on_route<T, F>(&self, work: impl FnOnce(Route) -> F + Send + 'static) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, SyncError>> + Send + 'static,
    {
        let route = self.route();
        on_runtime(&self.tasks, async move { work(route).await.map_err(CoreError::from) }).await
    }

    // Runs `work` over the personal provider's engine on the runtime.
    async fn on_control<T, F>(
        &self,
        work: impl FnOnce(Arc<dyn SyncControl>) -> F + Send + 'static,
    ) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, SyncError>> + Send + 'static,
    {
        self.on_route(move |route| async move { work(route.personal().await?).await })
            .await
    }
}

#[uniffi::export]
impl SyncService {
    pub fn status(&self) -> SyncStatusInfo {
        // TablePro Sync runs the team scopes alone when another provider, or none, holds personal data.
        let teams = match self.config.provider {
            SyncProviderTag::TableproSync => None,
            SyncProviderTag::Icloud | SyncProviderTag::Off => {
                self.service.now().ok().map(|engine| engine.sync.status())
            }
        };
        with_teams(self.personal_status(), teams.as_ref())
    }

    // A pass of each engine that holds records here; the first failure is the answer, after every pass ran.
    pub async fn sync_now(&self, why: PassReasonTag) -> Result<(), CoreError> {
        self.on_route(move |route| async move {
            let (engines, mut failed) = route.running().await;
            for control in engines {
                if let Err(error) = control.sync_now(why.into()).await {
                    failed.get_or_insert(error);
                }
            }
            failed.map_or(Ok(()), Err)
        })
        .await
    }

    // Each running engine takes them; the iCloud engine reads a category turned on whole on its next fetch.
    pub async fn set_categories(&self, categories: SyncCategoriesArg) -> Result<(), CoreError> {
        let categories = categories_arg(&categories)?;
        if let Ok(engine) = &self.icloud {
            engine.sync.set_categories(icloud_categories(&categories));
        }
        let slot = Arc::clone(&self.service);
        on_runtime(&self.tasks, async move { Ok(slot.set_categories(categories).await?) }).await
    }

    // A store the app still keeps wrote these records of `kind`, after its write landed (core ADR 0060).
    pub async fn record_host_changes(
        &self,
        kind: String,
        written: Vec<String>,
        deleted: Vec<String>,
    ) -> Result<(), CoreError> {
        let kind = KindName::parse(&kind)?
            .known()
            .ok_or(SyncError::Unknown { what: "kind" })?;
        let service = self.service.now().ok();
        let journals: Vec<&Journal> = self
            .icloud
            .iter()
            .map(|engine| &engine.journal)
            .chain(service.iter().map(|engine| &engine.journal))
            .collect();
        journal(&journals, self.legacy_marks.as_deref(), kind, written, deleted);
        Ok(())
    }

    // The engine whose file waits for the choice: TablePro Sync's after another account or server, whatever the
    // personal provider is now, else the personal provider's, as iCloud after another Apple ID.
    pub async fn plan_new_identity(&self) -> Result<NewIdentityPlanInfo, CoreError> {
        let (slot, personal) = (Arc::clone(&self.service), self.control_now());
        on_runtime(&self.tasks, async move {
            if let Ok(engine) = slot.engine().await
                && let Ok(plan) = engine.sync.plan_new_identity().await
            {
                return Ok(plan.into());
            }
            Ok(personal?.plan_new_identity().await?.into())
        })
        .await
    }

    // `account` is the plan's; an answer for another account than the one signed in now answers `sync.changed`.
    pub async fn choose_for_new_identity(
        &self,
        choice: NewIdentityChoiceTag,
        account: String,
    ) -> Result<(), CoreError> {
        let (slot, personal) = (Arc::clone(&self.service), self.control_now());
        let last = (
            self.files.clone(),
            self.config
                .service_account
                .as_deref()
                .and_then(super::engines::identity_of),
        );
        on_runtime(&self.tasks, async move {
            if let Ok(engine) = slot.engine().await
                && engine.sync.plan_new_identity().await.is_ok()
            {
                engine.sync.choose_for_new_identity(choice.into(), account).await?;
                // Chosen: the last sign-in's file has told what it held and goes, as iCloud's does. A restored file
                // can hold a wait under the sign-in the app kept, whose file is this engine's own and stays.
                if let (Some(files), Some(previous)) = last
                    && previous != *engine.sync.identity()
                {
                    files.delete(previous).await.map_err(SyncError::from)?;
                }
                return Ok(());
            }
            Ok(personal?.choose_for_new_identity(choice.into(), account).await?)
        })
        .await
    }

    pub async fn upload_again(&self) -> Result<(), CoreError> {
        self.on_control(move |control| async move { control.upload_again().await })
            .await
    }

    // One entry per record, the personal provider's first, then the team scopes'.
    pub async fn approvals(&self) -> Result<Vec<RecordApprovalInfo>, CoreError> {
        self.on_route(move |route| async move {
            let (engines, failed) = route.running().await;
            if let Some(error) = failed {
                return Err(error);
            }
            let mut approvals = Vec::new();
            for control in engines {
                approvals.extend(control.approvals().await?.into_iter().map(RecordApprovalInfo::from));
            }
            Ok(approvals)
        })
        .await
    }

    // One value. `digest` is the field's, as `approvals` gave it; a pull that changed the value since answers
    // `sync.changed`. A refusal keeps the device's value, and the same pulled value is not asked again.
    pub async fn decide_approval(
        &self,
        record: SyncRecordRef,
        field: String,
        digest: String,
        approve: bool,
    ) -> Result<(), CoreError> {
        let (key, seen) = (record_arg(&record)?, digest_arg(&digest)?);
        self.on_route(move |route| async move {
            let control = route.for_scope(key.scope).await?;
            control.decide_approval(key, field, seen, approve).await
        })
        .await
    }

    // Every value the record's entry listed. `digest` is the record's, as `approvals` gave it; a pull that changed any
    // of them since answers `sync.changed` and decides nothing. Approving a new record lands it before this returns.
    pub async fn decide_record_approval(
        &self,
        record: SyncRecordRef,
        digest: String,
        approve: bool,
    ) -> Result<(), CoreError> {
        let (key, seen) = (record_arg(&record)?, digest_arg(&digest)?);
        self.on_route(move |route| async move {
            let control = route.for_scope(key.scope).await?;
            control.decide_record_approval(key, seen, approve).await
        })
        .await
    }

    // Only team records meet in a conflict, so they are TablePro Sync's; with no sign-in there are none.
    pub async fn conflicts(&self) -> Result<Vec<TeamConflictInfo>, CoreError> {
        self.on_route(move |route| async move {
            let conflicts = match route.teams().await? {
                Some(control) => control.conflicts().await?,
                None => Vec::new(),
            };
            Ok(conflicts.into_iter().map(TeamConflictInfo::from).collect())
        })
        .await
    }

    // `digest` is the conflict's, as `conflicts` gave it; a pull that replaced the conflict since answers `sync.changed`.
    pub async fn resolve_conflict(
        &self,
        record: SyncRecordRef,
        digest: String,
        keep: ConflictChoiceTag,
    ) -> Result<(), CoreError> {
        let (key, seen) = (record_arg(&record)?, digest_arg(&digest)?);
        self.on_route(move |route| async move {
            let control = route.for_scope(key.scope).await?;
            control.resolve_conflict(key, seen, keep.into()).await
        })
        .await
    }

    pub async fn held_records(&self) -> Result<Vec<HeldRecordInfo>, CoreError> {
        self.on_route(move |route| async move {
            let (engines, failed) = route.running().await;
            if let Some(error) = failed {
                return Err(error);
            }
            let mut held = Vec::new();
            for control in engines {
                held.extend(control.held_records().await?.into_iter().map(HeldRecordInfo::from));
            }
            Ok(held)
        })
        .await
    }

    // True while older entries remain on the server.
    pub async fn load_older_history(&self) -> Result<bool, CoreError> {
        self.on_control(move |control| async move { control.load_older_history().await })
            .await
    }

    // The history entries this device keeps, its retention setting: a snapshot of the history scope takes that many,
    // newest first, and `load_older_history` pages back. None keeps every entry.
    pub fn set_history_window(&self, entries: Option<u32>) {
        self.service.set_history_window(entries);
    }

    // The scopes TablePro Sync's last scopes body named, for the server's policy switches; empty before its first
    // poll or while it does not run. `status_changed` follows a body that changed them.
    pub fn scope_statuses(&self) -> Vec<ScopeStatusInfo> {
        self.service.now().map_or_else(
            |_| Vec::new(),
            |engine| {
                engine
                    .sync
                    .scopes_seen()
                    .into_iter()
                    .map(ScopeStatusInfo::from)
                    .collect()
            },
        )
    }

    // The app awaits it as it quits: it returns once every write the app reported so far has marked the Swift sync
    // metadata the previous stable reads, and fails while the app refuses a mark (core ADR 0054, Downgrade mirror).
    pub async fn flush_legacy_marks(&self) -> Result<(), CoreError> {
        let flush: std::pin::Pin<Box<dyn Future<Output = Result<(), SyncError>> + Send>> = match &self.icloud {
            Ok(engine) => {
                let sync = Arc::clone(&engine.sync);
                Box::pin(async move { sync.flush_legacy_marks().await })
            }
            Err(_) => match self.legacy_marks.clone() {
                Some(marks) => Box::pin(async move { marks.flush().await }),
                None => return Ok(()),
            },
        };
        on_runtime(&self.tasks, async move { Ok(flush.await?) }).await
    }

    // The iCloud account whose state file the device uses now, for the app to keep and pass back as
    // `SyncConfig::icloud_account` at the next launch.
    pub fn icloud_account(&self) -> Option<String> {
        match &self.icloud {
            Ok(engine) => engine.sync.account(),
            Err(_) => self.config.icloud_account.clone(),
        }
    }

    // The TablePro Sync sign-in whose state file the device uses now, for the app to keep and pass back as
    // `SyncConfig::service_account` at the next launch.
    pub fn service_account(&self) -> Option<String> {
        match self.service.now() {
            // Until the person chooses, the app keeps the sign-in this one follows, so the next open asks again.
            Ok(engine) if !engine.sync.awaits_account_choice() => super::engines::identity_text(engine.sync.identity()),
            Ok(_) | Err(_) => self.config.service_account.clone(),
        }
    }
}
