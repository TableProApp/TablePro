// What the engine offers an app beyond the key flows (0054, Scheduling; Providers; Moving between providers; Rules for
// both providers), which the FFI's `SyncService` wraps. Every method answers `sync.unimplemented` until the engine's
// lanes override it.

use async_trait::async_trait;
use serde_json::Value;
use sha2::{Digest, Sha256};

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

    // What the choice after another account weighs: the changes the last account's file held unsent, and the account
    // the prompt is for.
    async fn plan_new_identity(&self) -> Result<NewIdentityPlan, SyncError> {
        unimplemented("sync.plan_new_identity")
    }

    // Another account or server: Move my data or Start empty. Nothing goes up without this choice. Start empty takes
    // the synced records off this device, where the last account keeps them, keeps the Local only ones, and fills
    // from the new account (orchestrator ruling on 0066). `account` is the plan's: an answer shown for another account
    // than the one signed in now changes nothing and answers `sync.changed`.
    async fn choose_for_new_identity(&self, choice: NewIdentityChoice, account: String) -> Result<(), SyncError> {
        let _ = (choice, account);
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

    // The values waiting for the person, one entry per record (0044, Fields a pull applies only with approval).
    async fn approvals(&self) -> Result<Vec<RecordApproval>, SyncError> {
        unimplemented("sync.approvals")
    }

    // A rejection keeps the device's own value as a local override. `seen` is the `digest` of the value the person saw:
    // when a pull changed it since, the decision applies to nothing and answers `sync.changed`, and the person is asked
    // again (0066, Rules).
    async fn decide_approval(
        &self,
        key: RecordKey,
        field: String,
        seen: [u8; 32],
        approve: bool,
    ) -> Result<(), SyncError> {
        let _ = (key, field, seen, approve);
        unimplemented("sync.decide_approval")
    }

    // Every value of the record that waits, decided at once. `seen` is the record's `digest` as listed: a pull that
    // changed any of its values since decides nothing and answers `sync.changed`.
    async fn decide_record_approval(&self, key: RecordKey, seen: [u8; 32], approve: bool) -> Result<(), SyncError> {
        let _ = (key, seen, approve);
        unimplemented("sync.decide_record_approval")
    }

    async fn conflicts(&self) -> Result<Vec<TeamConflict>, SyncError> {
        unimplemented("sync.conflicts")
    }

    // `seen` is the `digest` of the conflict the person saw. A pull that replaced it since resolves nothing and answers
    // `sync.changed`, so the person sees the conflict as it is now.
    async fn resolve_conflict(&self, key: RecordKey, seen: [u8; 32], keep: ConflictChoice) -> Result<(), SyncError> {
        let _ = (key, seen, keep);
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
    // When the last pass ended, whatever it ended in; it tells the app a pass ran.
    pub last_pass_ms: Option<i64>,
    // When a pass last ended without an error, kept in the state file across launches.
    pub last_synced_ms: Option<i64>,
    // The last pass's error code, as `SyncError::code` gives it.
    pub problem: Option<&'static str>,
    // Records with a value waiting for the person.
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
        last_synced_ms: None,
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
    // Idle, with values waiting for the person.
    NeedsApproval,
}

impl SyncStatus {
    // What an engine shows: an idle engine with values waiting asks the person, so the status never reads as done.
    pub fn shown(mut self) -> Self {
        if self.phase == SyncPhase::Idle && self.waiting_approvals > 0 {
            self.phase = SyncPhase::NeedsApproval;
        }
        self
    }
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
pub struct NewIdentityPlan {
    // Changes the last account's file held that never went up; Start empty leaves them behind.
    pub unsent: u64,
    // The account the choice is for, which the answer names back.
    pub account: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordApproval {
    pub key: RecordKey,
    // The record's name, else its settings category: from the store's copy, else from the pulled one.
    pub name: Option<String>,
    // The store holds no copy: the record lands only once every value is approved.
    pub new_record: bool,
    // `record_approval_digest(&fields)`, which `decide_record_approval` carries back.
    pub digest: [u8; 32],
    pub fields: Vec<PendingApproval>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingApproval {
    // A JSON Pointer into the record.
    pub field: String,
    // Null when the pull removes the value.
    pub pulled: Value,
    // `approval_digest(&pulled)`, which `decide_approval` carries back.
    pub digest: [u8; 32],
    // None when the store holds no value.
    pub current: Option<Value>,
}

// SHA-256 of a pulled value as its JSON text, which names the value a person decided on.
pub fn approval_digest(pulled: &Value) -> [u8; 32] {
    Sha256::digest(pulled.to_string().as_bytes()).into()
}

// SHA-256 over each waiting value of a record in the order listed, each its pointer after a length, then its value's
// digest, which names every value a person decided on at once.
pub fn record_approval_digest(fields: &[PendingApproval]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for field in fields {
        hasher.update(u64::try_from(field.field.len()).unwrap_or(u64::MAX).to_be_bytes());
        hasher.update(field.field.as_bytes());
        hasher.update(field.digest);
    }
    hasher.finalize().into()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamConflict {
    pub key: RecordKey,
    pub fields: Vec<String>,
    pub mine: Option<Value>,
    pub theirs: Option<Value>,
    // `conflict_digest` of the conflict as the state holds it, which `resolve_conflict` carries back.
    pub digest: [u8; 32],
}

// SHA-256 over a conflict's base, mine and theirs, each framed as one byte for none or a deletion and otherwise its
// JSON text after a length, which names the conflict a person resolved.
pub fn conflict_digest(base: Option<&Value>, mine: Option<&Value>, theirs: Option<&Value>) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for side in [base, mine, theirs] {
        match side {
            None => hasher.update([0]),
            Some(value) => {
                let text = value.to_string();
                hasher.update([1]);
                hasher.update(u64::try_from(text.len()).unwrap_or(u64::MAX).to_be_bytes());
                hasher.update(text.as_bytes());
            }
        }
    }
    hasher.finalize().into()
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
