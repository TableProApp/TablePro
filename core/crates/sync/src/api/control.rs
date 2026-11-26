// What the engine offers an app beyond the key flows (0054, Scheduling; Providers; Moving between providers; Rules for
// both providers), which the FFI's `SyncService` wraps. Every method answers `sync.unimplemented` until the engine's
// lanes override it.

use async_trait::async_trait;
use serde_json::Value;

use super::error::SyncError;
use super::ids::{KindName, RecordKey};
use super::state::{HeldReason, Provider};

fn unimplemented<T>(what: &'static str) -> Result<T, SyncError> {
    Err(SyncError::unimplemented(what))
}

#[async_trait]
pub trait SyncControl: Send + Sync {
    fn status(&self) -> SyncStatus;

    // A journal signal, launch, foreground, the network back, a CloudKit push, the poll interval or iCloud's timer.
    async fn sync_now(&self, why: PassReason) -> Result<(), SyncError> {
        let _ = why;
        unimplemented("sync.sync_now")
    }

    // The categories this device syncs and whether passwords do: an off category sends nothing, and a deletion pulled
    // for it waits (0054, Rules for both providers).
    async fn set_categories(&self, categories: SyncCategories) -> Result<(), SyncError> {
        let _ = categories;
        unimplemented("sync.set_categories")
    }

    // A store the app still keeps wrote these records, after its write landed (0060). The diff decides what goes up.
    async fn host_changed(&self, kind: KindName, written: Vec<String>, deleted: Vec<String>) -> Result<(), SyncError> {
        let _ = (kind, written, deleted);
        unimplemented("sync.host_changed")
    }

    // Off, iCloud or TablePro Sync for personal data, among what the managed policy allows (0055).
    async fn choose_provider(&self, choice: ProviderChoice) -> Result<(), SyncError> {
        let _ = choice;
        unimplemented("sync.choose_provider")
    }

    // What a move to TablePro Sync would leave behind, for the move sheet.
    async fn plan_move_to_service(&self) -> Result<MovePlan, SyncError> {
        unimplemented("sync.plan_move_to_service")
    }

    async fn move_to_service(&self) -> Result<(), SyncError> {
        unimplemented("sync.move_to_service")
    }

    // How many iCloud records the move back deletes, which the person confirms first.
    async fn plan_move_to_icloud(&self) -> Result<MoveBackPlan, SyncError> {
        unimplemented("sync.plan_move_to_icloud")
    }

    // Refused unless `confirmed_deletions` equals the plan's count.
    async fn move_to_icloud(&self, confirmed_deletions: u64) -> Result<(), SyncError> {
        let _ = confirmed_deletions;
        unimplemented("sync.move_to_icloud")
    }

    // Another account or server: Move my data or Start empty. Nothing goes up without this choice.
    async fn choose_for_new_identity(&self, choice: NewIdentityChoice) -> Result<(), SyncError> {
        let _ = choice;
        unimplemented("sync.choose_for_new_identity")
    }

    // After a removed zone, nothing is uploaded until the person asks.
    async fn upload_again(&self) -> Result<(), SyncError> {
        unimplemented("sync.upload_again")
    }

    // The zone stays after a move until the person deletes it.
    async fn delete_icloud_zone(&self) -> Result<(), SyncError> {
        unimplemented("sync.delete_icloud_zone")
    }

    async fn approvals(&self) -> Result<Vec<PendingApproval>, SyncError> {
        unimplemented("sync.approvals")
    }

    // A rejection keeps the device's own value as a local override.
    async fn decide_approval(&self, key: RecordKey, field: String, approve: bool) -> Result<(), SyncError> {
        let _ = (key, field, approve);
        unimplemented("sync.decide_approval")
    }

    async fn conflicts(&self) -> Result<Vec<TeamConflict>, SyncError> {
        unimplemented("sync.conflicts")
    }

    async fn resolve_conflict(&self, key: RecordKey, keep: ConflictChoice) -> Result<(), SyncError> {
        let _ = (key, keep);
        unimplemented("sync.resolve_conflict")
    }

    // Records that stay on the device with a notice: over the record limit, refused, unreadable or held.
    async fn held_records(&self) -> Result<Vec<HeldRecord>, SyncError> {
        unimplemented("sync.held_records")
    }

    // The history view asks for entries older than the window.
    async fn load_older_history(&self) -> Result<bool, SyncError> {
        unimplemented("sync.load_older_history")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PassReason {
    Journal,
    // A key flow wrote something a pass should carry (`KeyHooks::pass_soon`).
    KeyFlow,
    // `CKAccountChanged`: the engine reads the account status and opens that account's state file.
    AccountChanged,
    Launch,
    Foreground,
    NetworkBack,
    CloudKitPush,
    Poll,
    Person,
}

// The kinds turned off on this device, and the password switch.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SyncCategories {
    pub off: Vec<KindName>,
    pub passwords: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProviderChoice {
    Off,
    ICloud,
    Service,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NewIdentityChoice {
    MoveMyData,
    StartEmpty,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncStatus {
    pub provider: Option<Provider>,
    pub phase: SyncPhase,
    pub last_pass_ms: Option<i64>,
    // The last pass's error code, as `SyncError::code` gives it.
    pub problem: Option<&'static str>,
    pub waiting_approvals: u32,
    pub conflicts: u32,
    pub held: u32,
    pub queued_changes: u32,
}

impl SyncStatus {
    pub const UNAVAILABLE: Self = Self {
        provider: None,
        phase: SyncPhase::Unavailable,
        last_pass_ms: None,
        problem: Some("sync.unimplemented"),
        waiting_approvals: 0,
        conflicts: 0,
        held: 0,
        queued_changes: 0,
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SyncPhase {
    Off,
    Unavailable,
    Idle,
    Syncing,
    // Backing off with jitter, honoring `Retry-After`.
    Waiting { retry_in_ms: u64 },
    // Pull-only past grace or after a lapse.
    PullOnly,
    // A removed zone waits for Upload Again.
    ZoneRemoved,
    // Another account or server waits for Move my data or Start empty.
    NewIdentity,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MovePlan {
    pub records: u64,
    // Local only and sample connections, and categories this device has turned off.
    pub staying_behind: u64,
    pub secrets_to_seal: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MoveBackPlan {
    pub icloud_deletions: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingApproval {
    pub key: RecordKey,
    pub field: String,
    pub pulled: Value,
    pub current: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamConflict {
    pub key: RecordKey,
    pub fields: Vec<String>,
    pub mine: Option<Value>,
    pub theirs: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ConflictChoice {
    KeepMine,
    KeepTheirs,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldRecord {
    pub key: RecordKey,
    pub reason: HeldRecordReason,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeldRecordReason {
    Held(HeldReason),
    // Over 1 MiB, or a value the server's rules refuse, kept on the device.
    Refused { code: String },
}
