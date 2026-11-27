use async_trait::async_trait;
use serde_json::Value;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, Origin, RequestId, ResetId, TeamId, Version};
use tablepro_keys::keys::{Ed25519Public, X25519Public};
use tablepro_keys::sas::{Role as ComparisonRole, SessionState};
use tablepro_keys::trust::{PinHow, Replaced};
use uuid::Uuid;

use super::error::StateError;
use super::ids::{ChangeTag, Cursor, EpochId, FileId, IdempotencyKey, KindName, RecordKey, ScopeName};
use super::scopes::{LineageEpoch, Role, ScopePolicies};
use super::transport::{DeletedReason, PulledRecord};

// One state file per provider and account (0054, The state file): SQLite in WAL mode, its sync and key tables, the
// state MAC over both digests, and the anchor in the device store. A pass reads and writes it through one transaction,
// which commits whole: the tables, then the counter and MAC, with the anchor's two steps around it.
#[async_trait]
pub trait StateStore: Send + Sync {
    // What the file is bound to; its `binding` row holds it with the file id, the counter and the MAC.
    fn identity(&self) -> &StateIdentity;

    // What opening found; it does not change while the file is open.
    fn opened(&self) -> &Opened;

    // The file has one connection, so a transaction waits for the one before it to end. A caller that holds one never
    // begins another or makes a network call: a helper that reads or writes rows under its caller's transaction takes
    // it as `&mut dyn StateTxn`, and a step that pushes or pulls ends its transaction first.
    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError>;

    // Once a delete committed, nothing of what it removed stays in the file's WAL frames or free pages, as a verified
    // delete of an owner's data needs (K8t; 0054, The state file). A store that keeps no file has nothing to purge.
    async fn purge(&self) -> Result<(), StateError> {
        Ok(())
    }
}

// What ends the distrust an open found of the key tables (0054, A stale file).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeysSettled {
    // A stale file's rebuild saw every anchored pin and version on the server.
    Rebuilt,
    // An approval, a recovery or a genesis gave a file with no anchor keys and key tables it can trust.
    Reapproved,
}

// Rows read and written in one commit. Dropping it uncommitted writes nothing.
#[async_trait]
pub trait StateTxn: Send {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError>;

    // In the byte order of the encoded primary keys, as the digests read them.
    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError>;

    async fn put(&mut self, row: Row) -> Result<(), StateError>;

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError>;

    // Erases every key table in this commit: Sign Out, or another account on this row (0054, The device's key state).
    // The device then joins again as a new device would, so nothing an open found of the key tables stays owed.
    async fn clear_key_tables(&mut self) -> Result<(), StateError>;

    // This commit settles what the open found of the key tables. Until a commit that carries it lands, every open
    // reports the same distrust, so a restart does not launder it.
    fn settle_keys(&mut self, _settled: KeysSettled) {}

    async fn commit(self: Box<Self>) -> Result<Committed, StateError>;
}

// Opens the state file of one identity, refusing a file made for another, and deletes one whole.
#[async_trait]
pub trait StateFiles: Send + Sync {
    async fn open(&self, identity: StateIdentity) -> Result<std::sync::Arc<dyn StateStore>, StateError>;

    async fn delete(&self, identity: StateIdentity) -> Result<(), StateError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Provider {
    Service,
    ICloud,
}

// What a state file is bound to. Another identity opens another file, so nothing crosses accounts.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum StateIdentity {
    Service {
        origin: Origin,
        // The sign-in key, which names the server and the account file (tablepro-account).
        sign_in: String,
        account: AccountId,
        device_row: super::ids::DeviceRowId,
    },
    ICloud {
        user_record_name: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Committed {
    pub counter: u64,
}

// What the file and its anchor said at open (0054, On open).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    pub sync_tables: SyncTrust,
    pub key_tables: KeyTrust,
}

impl Opened {
    pub const FRESH: Self = Self {
        sync_tables: SyncTrust::Trusted,
        key_tables: KeyTrust::Trusted,
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncTrust {
    Trusted,
    // A restored, replaced or uncertain file: the pull wins, records the provider never saw go up as creates.
    Refill,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyTrust {
    Trusted,
    // A stale file, or an anchor with no file: rebuild from the server's key objects at or above this checkpoint,
    // accepting no wrap or envelope and writing no secret until the server shows every anchored pin and version.
    Rebuild { checkpoint: Box<Checkpoint> },
    // A file with no anchor: it handles no secret until another device approves it again or the person recovers.
    Unanchored,
}

// What only moves forward (0054, The checkpoint).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Checkpoint {
    pub pins: Vec<KeyPinRow>,
    pub versions: Vec<KeyVersionRow>,
    pub envelopes: Vec<KeyEnvelopeRow>,
}

// The tables in digest order: the sync tables as 0054 lists them, then the key tables.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Table {
    Binding,
    Scopes,
    Stores,
    // 0066: per (store, kind), a refill the kind still owes.
    StoresKinds,
    Bases,
    // 0064: the bases a pull will apply, written before the store; at a restart one whose store copy matches becomes
    // the base, and one that does not stays a local edit.
    PendingBases,
    Standing,
    Held,
    Deferred,
    Outbox,
    // 0066: per record, the change the server refused and its code.
    Refused,
    Approvals,
    Conflicts,
    LegacyMirror,
    // A move between providers this device started: its target and how far it went (0054, Moving between providers).
    Moves,
    // Per settings record Start empty left on the device: the digest of the copy it held then, which goes up only once
    // the person edits it here.
    LeftBehind,
    KeyObjects,
    KeyPins,
    KeyDevicePins,
    KeyVersions,
    KeyEnvelopes,
    KeyComparisons,
    KeyPending,
    DeletedHistory,
}

impl Table {
    pub const SYNC: [Self; 16] = [
        Self::Binding,
        Self::Scopes,
        Self::Stores,
        Self::StoresKinds,
        Self::Bases,
        Self::PendingBases,
        Self::Standing,
        Self::Held,
        Self::Deferred,
        Self::Outbox,
        Self::Refused,
        Self::Approvals,
        Self::Conflicts,
        Self::LegacyMirror,
        Self::Moves,
        Self::LeftBehind,
    ];

    pub const KEY: [Self; 8] = [
        Self::KeyObjects,
        Self::KeyPins,
        Self::KeyDevicePins,
        Self::KeyVersions,
        Self::KeyEnvelopes,
        Self::KeyComparisons,
        Self::KeyPending,
        Self::DeletedHistory,
    ];

    pub const fn name(self) -> &'static str {
        match self {
            Self::Binding => "binding",
            Self::Scopes => "scopes",
            Self::Stores => "stores",
            Self::StoresKinds => "stores_kinds",
            Self::Bases => "bases",
            Self::PendingBases => "pending_bases",
            Self::Standing => "standing",
            Self::Held => "held",
            Self::Deferred => "deferred",
            Self::Outbox => "outbox",
            Self::Refused => "refused",
            Self::Approvals => "approvals",
            Self::Conflicts => "conflicts",
            Self::LegacyMirror => "legacy_mirror",
            Self::Moves => "moves",
            Self::LeftBehind => "left_behind",
            Self::KeyObjects => "key_objects",
            Self::KeyPins => "key_pins",
            Self::KeyDevicePins => "key_device_pins",
            Self::KeyVersions => "key_versions",
            Self::KeyEnvelopes => "key_envelopes",
            Self::KeyComparisons => "key_comparisons",
            Self::KeyPending => "key_pending",
            Self::DeletedHistory => "deleted_history",
        }
    }

    pub const fn is_key_table(self) -> bool {
        matches!(
            self,
            Self::KeyObjects
                | Self::KeyPins
                | Self::KeyDevicePins
                | Self::KeyVersions
                | Self::KeyEnvelopes
                | Self::KeyComparisons
                | Self::KeyPending
                | Self::DeletedHistory
        )
    }
}

// Each row's fields are its columns in order, the primary key first.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BindingRow {
    pub provider: Provider,
    // The server origin; None on iCloud.
    pub origin: Option<Origin>,
    // The account id, or the iCloud user record name.
    pub account: String,
    pub device: String,
    pub schema_version: u32,
    pub file_id: FileId,
    // Raised by one on every commit; the store sets it.
    pub counter: u64,
    // Left out of the sync digest, since it is computed over it.
    pub state_mac: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeRow {
    pub scope: ScopeName,
    pub role: Option<Role>,
    pub epoch: Option<EpochId>,
    // The service's cursor, or the zone's change token on iCloud.
    pub cursor: Option<Cursor>,
    // The scope key version in force at `cursor`, moved only by applying a pull (0054, A pass).
    pub key_version: Option<Version>,
    pub horizon: Option<u64>,
    pub policies: ScopePolicies,
    // The lineage the device last read, against which a new epoch's cut is found (0051, Lost writes).
    pub lineage: Vec<LineageEpoch>,
    // The history scope's cursor for older entries, kept to page back on demand.
    pub older_cursor: Option<Cursor>,
    // The kinds the last pull read. A build that reads more fetches what it held for the others again.
    pub read_kinds: Vec<KindName>,
    pub refill: bool,
    pub rotation_due: bool,
    // The last pull reached a page with no records. It schedules pulls; a roster decision takes the `CaughtUp` of a
    // pull that followed its scopes body, never this flag.
    pub caught_up: bool,
    // On iCloud, what the zone's push waits for (0066, Rules); None on the service.
    pub push_wait: Option<PushWait>,
}

// What an iCloud zone's push waits for, kept so a restart waits the same way (0066, Rules).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PushWait {
    // Another iCloud account: the person picks Move my data or Start empty, told how many changes the last account's
    // file held unsent.
    AccountChoice { unsent: u64 },
    // This device saw the zone removed, and nothing goes up until its own person asks to upload again, even after
    // another device made the zone again.
    UploadAgain,
}

impl PushWait {
    // The count an integrity recovery's wait holds until an engine counts what the device would send.
    pub const UNCOUNTED: u64 = u64::MAX;

    pub const fn name(self) -> &'static str {
        match self {
            Self::AccountChoice { .. } => "account_choice",
            Self::UploadAgain => "upload_again",
        }
    }
}

impl ScopeRow {
    pub fn new(scope: ScopeName) -> Self {
        Self {
            scope,
            role: None,
            epoch: None,
            cursor: None,
            key_version: None,
            horizon: None,
            policies: ScopePolicies::default(),
            lineage: Vec::new(),
            older_cursor: None,
            read_kinds: Vec::new(),
            refill: false,
            rotation_due: false,
            caught_up: false,
            push_wait: None,
        }
    }
}

// One row per store file the core keeps, such as `connections.json` or `history.db`, for its generation and write
// sequence (0060, 0064). A new generation or a lower sequence owes each of its kinds a refill in `stores_kinds`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreRow {
    // The store file's name.
    pub store: String,
    pub generation: Uuid,
    pub sequence: u64,
}

// A kind of the store whose refill is still owed: it refills once its category is on, and the row then goes (0066,
// Per-kind refills).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StoresKindRow {
    pub store: String,
    pub kind: KindName,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BaseRow {
    pub key: RecordKey,
    pub tag: ChangeTag,
    pub version: Option<u64>,
    pub revision: Option<u64>,
    // The epoch the copy was written in, which a new epoch's cut judges it against (0051, Lost writes).
    pub epoch: Option<EpochId>,
    // A policy tombstone's base, which a revival patches on.
    pub deleted: Option<DeletedReason>,
    // The fields as last agreed; None for create-once kinds.
    pub fields: Option<Value>,
    // CloudKit's creation date of the record the base came from, in milliseconds; None on the service.
    pub created_ms: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Standing {
    Syncs,
    LocalOnly,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StandingRow {
    pub key: RecordKey,
    pub standing: Standing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HeldReason {
    Unreadable,
    UnknownKind,
    // A pulled value waits for the person (0044's approval-required fields).
    AwaitingApproval,
    // This device is not approved yet, so it holds what it may not apply (0056, D8).
    AwaitingDeviceApproval,
    // The store refused a value a refill pulled: when it takes it, the pull wins as the refill would have, so the
    // copy the restore left never reads as the device's edit.
    RefusedInRefill,
    // A team library record whose id another of its kind holds in other case: neither is applied, listed or sent, as
    // the publish plan leaves both out (0052, Team scope).
    Collides,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HeldRow {
    pub key: RecordKey,
    pub reason: HeldReason,
    // The change or deletion held.
    pub record: PulledRecord,
}

// A deletion pulled for a category that is off, applied once the category is read, or the copy a store refill found
// for a record while its kind was off (0066).
#[derive(Debug, Clone, PartialEq)]
pub struct DeferredRow {
    pub key: RecordKey,
    pub record: PulledRecord,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxRow {
    pub scope: ScopeName,
    pub idempotency_key: IdempotencyKey,
    // SHA-256 of the body sent, so a rebuilt batch reuses the key only when it is the same request.
    pub request_digest: [u8; 32],
    pub created_at_ms: i64,
}

// A change the server refused (0051, Push): sent again only once what the pass would send differs, after a restart too
// (0066).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefusedRow {
    pub key: RecordKey,
    // SHA-256 of the change as the pass sent it.
    pub digest: [u8; 32],
    // The server's code.
    pub code: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalDecision {
    // Waiting for the person, or not yet asked.
    Waiting,
    Approved,
    // Kept as a device-local override.
    Rejected { local: Value },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalRow {
    pub key: RecordKey,
    pub field: String,
    pub pulled: Value,
    pub decision: ApprovalDecision,
}

// A team record whose field both sides changed; None is a deletion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictRow {
    pub key: RecordKey,
    pub base: Option<Value>,
    pub mine: Option<Value>,
    pub theirs: Option<Value>,
}

// How far a move went. A move to TablePro Sync is `Open` in the iCloud file it leaves once iCloud stopped for it, so
// that file never syncs again while it is, and in the service file while the arrival's snapshot runs; `Done` in the
// iCloud file once everything arrived. A move back to iCloud is `Open` in the service file until iCloud holds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MovePhase {
    Open,
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LeftBehindRow {
    pub key: RecordKey,
    pub digest: [u8; 32],
}

// The one row of `moves`. `from` is None for a first upload from no provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MoveRow {
    pub from: Option<Provider>,
    pub target: Provider,
    pub phase: MovePhase,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyMirrorRow {
    pub item: String,
    pub value: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyObjectRow {
    pub scope: ScopeName,
    pub kind: KindName,
    pub record_id: String,
    // As the server served them or as this device wrote them.
    pub fields: String,
    // In force: served by the server, or written and applied by this device.
    pub applied: bool,
    // The server's times, None until it serves the record (0066).
    pub served: Option<Served>,
}

// When the server took a key object and, on a `key.reset`, until when it holds it (0051, Pull).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Served {
    pub taken_at_us: i64,
    pub held_until_us: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyPinRow {
    pub account: AccountId,
    pub ik: Ed25519Public,
    pub av: Version,
    pub how: PinHow,
    pub alert: bool,
    // In the order replaced, each with the `av` of the replace certificate that retired it; never gone back to.
    pub replaced: Vec<Replaced>,
}

// Own-device pins: never taken from a certificate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyDevicePinRow {
    pub key_device: KeyDeviceId,
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyVersionState {
    Ok,
    // A catch-up or a restore leaves the device waiting.
    Stopped,
    // Nothing clears it.
    Ended,
}

impl KeyVersionState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Stopped => "stopped",
            Self::Ended => "ended",
        }
    }
}

// One (account id, accepted IK) pair of a team row's holders, sorted by account then IK.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Holder {
    pub account: AccountId,
    pub ik: Ed25519Public,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyVersionRow {
    pub scope: ScopeName,
    pub purpose: KeyPurpose,
    pub version: Version,
    // SHA-256 of that version record's signed bytes.
    pub record: [u8; 32],
    // Empty for personal and history rows.
    pub holders: Vec<Holder>,
    pub state: KeyVersionState,
    // Why a `stopped` row waits, None otherwise (0062). Anchored with the row, so a file restore keeps it.
    pub stopped_cause: Option<StoppedCause>,
    // The epoch it ended in; None unless ended.
    pub epoch: Option<EpochId>,
}

impl KeyVersionRow {
    // Stops the row for `cause`. A scope that meets two causes keeps the stricter: `catch_up`, then `restart_held`,
    // then `restore_wait` (0062, 0064). A personal or history row only ever stops as `catch_up`. A row that ended
    // stays ended.
    pub fn stop(&mut self, cause: StoppedCause) {
        if self.state == KeyVersionState::Ended {
            return;
        }
        let cause = if self.purpose == KeyPurpose::Team {
            cause
        } else {
            StoppedCause::CatchUp
        };
        let kept = self.stopped_cause.map_or(cause, |held| held.max(cause));
        self.state = KeyVersionState::Stopped;
        self.stopped_cause = Some(kept);
    }

    // Clears a stop only by the event its cause and purpose allow (0062; 0056, Approving a device, step 7): a team's
    // catch-up stop by re-confirmation, a team's restore stop once the server holds every version it waited for, a
    // personal or history stop by an approval with the version signed under the current `av`. Anything else is
    // refused and the row stays as it was.
    pub fn clear_stop(&mut self, by: StopClear) -> Result<(), StopNotCleared> {
        if self.state != KeyVersionState::Stopped {
            return Err(StopNotCleared);
        }
        let allowed = match (self.purpose, self.stopped_cause) {
            (KeyPurpose::Team, Some(StoppedCause::CatchUp)) => by == StopClear::Reconfirmed,
            (KeyPurpose::Team, Some(StoppedCause::RestoreWait)) => by == StopClear::AwaitedVersionsBack,
            (KeyPurpose::Team, Some(StoppedCause::RestartHeld)) => by == StopClear::AcceptedRestart,
            (KeyPurpose::Personal | KeyPurpose::History, _) => by == StopClear::Approval,
            (KeyPurpose::Team, None) => false,
        };
        if !allowed {
            return Err(StopNotCleared);
        }
        self.state = KeyVersionState::Ok;
        self.stopped_cause = None;
        Ok(())
    }

    // Ends the scope in `epoch`, which nothing clears; an ended row has no stop cause (0062).
    pub fn end(&mut self, epoch: Option<EpochId>) {
        self.state = KeyVersionState::Ended;
        self.stopped_cause = None;
        self.epoch = epoch;
    }
}

// What clears a stop (0062).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StopClear {
    // An owner or admin the device counted as a holder rotated, and the device took the new version.
    Reconfirmed,
    // The server holds again every version the device waited for, with the same fields.
    AwaitedVersionsBack,
    // An approval brought the personal or history version signed under the current `av`.
    Approval,
    // The person compared the restarting owner's words and accepted the restart (0064).
    AcceptedRestart,
}

// The event does not clear this row's stop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("this event does not clear the scope's stop")]
pub struct StopNotCleared;

// Why a row stopped (0062, 0064), weakest first, so the stricter of two causes is the greater: a wait for a version a
// restore lost to come back, a team restart held until the person compares words, a catch-up the device could not
// verify.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum StoppedCause {
    RestoreWait,
    RestartHeld,
    CatchUp,
}

impl StoppedCause {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CatchUp => "catch_up",
            Self::RestoreWait => "restore_wait",
            Self::RestartHeld => "restart_held",
        }
    }

    // Only a catch-up stop is reported: no rotation clears the others (0062, 0064).
    pub const fn is_reported(self) -> bool {
        matches!(self, Self::CatchUp)
    }

    pub fn parse(text: &str) -> Option<Self> {
        [Self::CatchUp, Self::RestoreWait, Self::RestartHeld]
            .into_iter()
            .find(|cause| cause.as_str() == text)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEnvelopeRow {
    pub scope: ScopeName,
    pub record_id: String,
    pub kv: Version,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyComparisonRow {
    pub session: RequestId,
    pub role: ComparisonRole,
    // The other side's key device id and keys, as this side's view fixed them; encoded by the approval flow.
    pub peer: Vec<u8>,
    pub view: Vec<u8>,
    pub state: SessionState,
    pub expires_at_us: i64,
}

// A key flow that spans pushes and must survive a crash.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PendingFlow {
    // The team rotations an account rotation to this `av` still has to write, with its review's choices.
    AccountRotation { av: Version },
    Approval { request: RequestId },
    ResetProposal { reset: ResetId },
    // A stop report to withdraw, sent again after a restart until the server answers.
    StopWithdrawal { team: TeamId },
}

impl PendingFlow {
    pub fn key_text(self) -> String {
        match self {
            Self::AccountRotation { av } => format!("rotation/{av}"),
            Self::Approval { request } => format!("approval/{}", request.to_wire()),
            Self::ResetProposal { reset } => format!("reset/{}", reset.to_wire()),
            Self::StopWithdrawal { team } => format!("withdraw/{}", team.to_wire()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyPendingRow {
    pub flow: PendingFlow,
    // The flow's own encoding.
    pub state: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletedHistoryRow {
    pub record_id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Row {
    Binding(BindingRow),
    Scope(ScopeRow),
    Store(StoreRow),
    StoresKind(StoresKindRow),
    Base(BaseRow),
    // A base a pull wrote before the store, in `pending_bases`; its columns are a base's.
    PendingBase(BaseRow),
    Standing(StandingRow),
    Held(HeldRow),
    Deferred(DeferredRow),
    Outbox(OutboxRow),
    Refused(RefusedRow),
    Approval(ApprovalRow),
    Conflict(ConflictRow),
    LegacyMirror(LegacyMirrorRow),
    Move(MoveRow),
    LeftBehind(LeftBehindRow),
    KeyObject(KeyObjectRow),
    KeyPin(KeyPinRow),
    KeyDevicePin(KeyDevicePinRow),
    KeyVersion(KeyVersionRow),
    KeyEnvelope(KeyEnvelopeRow),
    KeyComparison(KeyComparisonRow),
    KeyPending(KeyPendingRow),
    DeletedHistory(DeletedHistoryRow),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RowKey {
    Binding,
    Scope(ScopeName),
    Store(String),
    StoresKind(String, KindName),
    Base(RecordKey),
    PendingBase(RecordKey),
    Standing(RecordKey),
    Held(RecordKey),
    Deferred(RecordKey),
    Outbox(ScopeName),
    Refused(RecordKey),
    Approval(RecordKey, String),
    Conflict(RecordKey),
    LegacyMirror(String),
    Move,
    LeftBehind(RecordKey),
    KeyObject(ScopeName, KindName, String),
    KeyPin(AccountId),
    KeyDevicePin(KeyDeviceId),
    KeyVersion(ScopeName, KeyPurpose),
    KeyEnvelope(ScopeName, String),
    KeyComparison(RequestId),
    KeyPending(PendingFlow),
    DeletedHistory(String),
}

impl Row {
    pub fn key(&self) -> RowKey {
        match self {
            Self::Binding(_) => RowKey::Binding,
            Self::Scope(row) => RowKey::Scope(row.scope),
            Self::Store(row) => RowKey::Store(row.store.clone()),
            Self::StoresKind(row) => RowKey::StoresKind(row.store.clone(), row.kind.clone()),
            Self::Base(row) => RowKey::Base(row.key.clone()),
            Self::PendingBase(row) => RowKey::PendingBase(row.key.clone()),
            Self::Standing(row) => RowKey::Standing(row.key.clone()),
            Self::Held(row) => RowKey::Held(row.key.clone()),
            Self::Deferred(row) => RowKey::Deferred(row.key.clone()),
            Self::Outbox(row) => RowKey::Outbox(row.scope),
            Self::Refused(row) => RowKey::Refused(row.key.clone()),
            Self::Approval(row) => RowKey::Approval(row.key.clone(), row.field.clone()),
            Self::Conflict(row) => RowKey::Conflict(row.key.clone()),
            Self::LegacyMirror(row) => RowKey::LegacyMirror(row.item.clone()),
            Self::Move(_) => RowKey::Move,
            Self::LeftBehind(row) => RowKey::LeftBehind(row.key.clone()),
            Self::KeyObject(row) => RowKey::KeyObject(row.scope, row.kind.clone(), row.record_id.clone()),
            Self::KeyPin(row) => RowKey::KeyPin(row.account),
            Self::KeyDevicePin(row) => RowKey::KeyDevicePin(row.key_device),
            Self::KeyVersion(row) => RowKey::KeyVersion(row.scope, row.purpose),
            Self::KeyEnvelope(row) => RowKey::KeyEnvelope(row.scope, row.record_id.clone()),
            Self::KeyComparison(row) => RowKey::KeyComparison(row.session),
            Self::KeyPending(row) => RowKey::KeyPending(row.flow),
            Self::DeletedHistory(row) => RowKey::DeletedHistory(row.record_id.clone()),
        }
    }
}

// 0054's value encoding of a present column: one byte 1, then `LP` of its bytes.
fn column(out: &mut Vec<u8>, bytes: &[u8]) {
    out.push(1);
    let length = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(bytes);
}

fn record_columns(out: &mut Vec<u8>, key: &RecordKey) {
    column(out, key.scope.wire().as_bytes());
    column(out, key.kind.as_str().as_bytes());
    column(out, key.record_id.as_bytes());
}

impl RowKey {
    pub fn table(&self) -> Table {
        match self {
            Self::Binding => Table::Binding,
            Self::Scope(_) => Table::Scopes,
            Self::Store(_) => Table::Stores,
            Self::StoresKind(..) => Table::StoresKinds,
            Self::Base(_) => Table::Bases,
            Self::PendingBase(_) => Table::PendingBases,
            Self::Standing(_) => Table::Standing,
            Self::Held(_) => Table::Held,
            Self::Deferred(_) => Table::Deferred,
            Self::Outbox(_) => Table::Outbox,
            Self::Refused(_) => Table::Refused,
            Self::Approval(..) => Table::Approvals,
            Self::Conflict(_) => Table::Conflicts,
            Self::LegacyMirror(_) => Table::LegacyMirror,
            Self::Move => Table::Moves,
            Self::LeftBehind(_) => Table::LeftBehind,
            Self::KeyObject(..) => Table::KeyObjects,
            Self::KeyPin(_) => Table::KeyPins,
            Self::KeyDevicePin(_) => Table::KeyDevicePins,
            Self::KeyVersion(..) => Table::KeyVersions,
            Self::KeyEnvelope(..) => Table::KeyEnvelopes,
            Self::KeyComparison(_) => Table::KeyComparisons,
            Self::KeyPending(_) => Table::KeyPending,
            Self::DeletedHistory(_) => Table::DeletedHistory,
        }
    }

    // The primary key's columns in 0054's value encoding, whose byte order orders a table's rows in its digest.
    // Scopes are their wire text, ids of accounts, key devices and sessions their 16 bytes.
    pub fn encoded(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match self {
            Self::Binding | Self::Move => {}
            Self::Scope(scope) | Self::Outbox(scope) => column(&mut out, scope.wire().as_bytes()),
            Self::Store(text) | Self::LegacyMirror(text) | Self::DeletedHistory(text) => {
                column(&mut out, text.as_bytes());
            }
            Self::StoresKind(store, kind) => {
                column(&mut out, store.as_bytes());
                column(&mut out, kind.as_str().as_bytes());
            }
            Self::Base(key)
            | Self::PendingBase(key)
            | Self::Standing(key)
            | Self::Held(key)
            | Self::Deferred(key)
            | Self::Refused(key)
            | Self::LeftBehind(key)
            | Self::Conflict(key) => {
                record_columns(&mut out, key);
            }
            Self::Approval(key, field) => {
                record_columns(&mut out, key);
                column(&mut out, field.as_bytes());
            }
            Self::KeyObject(scope, kind, record_id) => {
                column(&mut out, scope.wire().as_bytes());
                column(&mut out, kind.as_str().as_bytes());
                column(&mut out, record_id.as_bytes());
            }
            Self::KeyPin(account) => column(&mut out, account.0.as_bytes()),
            Self::KeyDevicePin(key_device) => column(&mut out, key_device.0.as_bytes()),
            Self::KeyVersion(scope, purpose) => {
                column(&mut out, scope.wire().as_bytes());
                column(&mut out, purpose.name().as_bytes());
            }
            Self::KeyEnvelope(scope, record_id) => {
                column(&mut out, scope.wire().as_bytes());
                column(&mut out, record_id.as_bytes());
            }
            Self::KeyComparison(session) => column(&mut out, session.0.as_bytes()),
            Self::KeyPending(flow) => column(&mut out, flow.key_text().as_bytes()),
        }
        out
    }
}

// The rows a scan reads: a whole table, or those whose leading key columns are one scope, or one scope and kind.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RowRange {
    Table(Table),
    Scope(Table, ScopeName),
    ScopeKind(Table, ScopeName, KindName),
}

impl RowRange {
    pub const fn table(&self) -> Table {
        match self {
            Self::Table(table) | Self::Scope(table, _) | Self::ScopeKind(table, ..) => *table,
        }
    }

    // A byte prefix of `RowKey::encoded` for every row in range.
    pub fn encoded_prefix(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match self {
            Self::Table(_) => {}
            Self::Scope(_, scope) => column(&mut out, scope.wire().as_bytes()),
            Self::ScopeKind(_, scope, kind) => {
                column(&mut out, scope.wire().as_bytes());
                column(&mut out, kind.as_str().as_bytes());
            }
        }
        out
    }

    pub fn contains(&self, key: &RowKey) -> bool {
        key.table() == self.table() && key.encoded().starts_with(&self.encoded_prefix())
    }
}

#[cfg(test)]
mod tests {
    use tablepro_records::Kind;

    use super::*;

    fn base(scope: ScopeName, kind: Kind, id: &str) -> RowKey {
        RowKey::Base(RecordKey::new(scope, kind, id))
    }

    #[test]
    fn a_scope_range_holds_its_scope_s_rows_and_no_other() {
        let range = RowRange::Scope(Table::Bases, ScopeName::Personal);

        assert!(range.contains(&base(ScopeName::Personal, Kind::Connection, "A")));
        assert!(!range.contains(&base(ScopeName::History, Kind::HistoryEntry, "A")));
        assert!(!range.contains(&RowKey::Held(RecordKey::new(
            ScopeName::Personal,
            Kind::Connection,
            "A"
        ))));
    }

    #[test]
    fn a_kind_range_is_not_fooled_by_a_kind_that_starts_another() {
        let range = RowRange::ScopeKind(Table::Bases, ScopeName::Personal, KindName::of(Kind::SavedQuery));

        assert!(range.contains(&base(ScopeName::Personal, Kind::SavedQuery, "A")));
        assert!(!range.contains(&base(ScopeName::Personal, Kind::SavedQueryFolder, "A")));
    }

    #[test]
    fn every_table_is_a_sync_or_a_key_table_in_digest_order() {
        let all: Vec<Table> = Table::SYNC.into_iter().chain(Table::KEY).collect();
        let mut sorted = all.clone();
        sorted.sort();

        assert_eq!(all, sorted);
        assert!(Table::SYNC.iter().all(|table| !table.is_key_table()));
        assert!(Table::KEY.iter().all(|table| table.is_key_table()));
    }

    fn team_row(purpose: KeyPurpose) -> KeyVersionRow {
        KeyVersionRow {
            scope: ScopeName::Personal,
            purpose,
            version: Version::new(3).unwrap(),
            record: [0; 32],
            holders: Vec::new(),
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
        }
    }

    #[test]
    fn a_scope_that_meets_both_causes_keeps_catch_up() {
        let mut waiting = team_row(KeyPurpose::Team);
        waiting.stop(StoppedCause::RestoreWait);
        let restore_only = waiting.stopped_cause;
        waiting.stop(StoppedCause::CatchUp);
        let mut caught = team_row(KeyPurpose::Team);
        caught.stop(StoppedCause::CatchUp);
        caught.stop(StoppedCause::RestoreWait);

        assert_eq!(restore_only, Some(StoppedCause::RestoreWait));
        assert_eq!(waiting.stopped_cause, Some(StoppedCause::CatchUp));
        assert_eq!(caught.stopped_cause, Some(StoppedCause::CatchUp));
        assert_eq!(caught.state, KeyVersionState::Stopped);
    }

    #[test]
    fn a_personal_or_history_row_stops_only_as_catch_up_and_an_ended_row_stays_ended() {
        let mut history = team_row(KeyPurpose::History);
        history.stop(StoppedCause::RestoreWait);
        let history_cause = history.stopped_cause;
        let mut ended = team_row(KeyPurpose::Team);
        ended.end(Some(EpochId(uuid::Uuid::nil())));
        ended.stop(StoppedCause::CatchUp);

        assert_eq!(history_cause, Some(StoppedCause::CatchUp));
        assert_eq!(history.clear_stop(StopClear::Reconfirmed), Err(StopNotCleared));
        assert_eq!(history.clear_stop(StopClear::Approval), Ok(()));
        assert_eq!((history.state, history.stopped_cause), (KeyVersionState::Ok, None));
        assert_eq!((ended.state, ended.stopped_cause), (KeyVersionState::Ended, None));
        assert_eq!(StoppedCause::parse("restore_wait"), Some(StoppedCause::RestoreWait));
        assert_eq!(StoppedCause::CatchUp.as_str(), "catch_up");
    }

    #[test]
    fn a_team_stop_clears_only_by_the_event_its_cause_allows() {
        let mut caught = team_row(KeyPurpose::Team);
        caught.stop(StoppedCause::CatchUp);
        let mut waiting = team_row(KeyPurpose::Team);
        waiting.stop(StoppedCause::RestoreWait);

        let caught_by_versions = caught.clear_stop(StopClear::AwaitedVersionsBack);
        let caught_by_approval = caught.clear_stop(StopClear::Approval);
        let waiting_by_reconfirm = waiting.clear_stop(StopClear::Reconfirmed);

        assert_eq!(caught_by_versions, Err(StopNotCleared));
        assert_eq!(caught_by_approval, Err(StopNotCleared));
        assert_eq!(caught.stopped_cause, Some(StoppedCause::CatchUp));
        assert_eq!(waiting_by_reconfirm, Err(StopNotCleared));
        assert_eq!(caught.clear_stop(StopClear::Reconfirmed), Ok(()));
        assert_eq!(waiting.clear_stop(StopClear::AwaitedVersionsBack), Ok(()));
        assert_eq!(
            team_row(KeyPurpose::Team).clear_stop(StopClear::Reconfirmed),
            Err(StopNotCleared)
        );
    }

    #[test]
    fn a_held_restart_clears_only_once_the_person_accepts_it_and_a_catch_up_outranks_it() {
        let mut held = team_row(KeyPurpose::Team);
        held.stop(StoppedCause::RestoreWait);
        held.stop(StoppedCause::RestartHeld);
        let over_restore = held.stopped_cause;
        let mut caught = team_row(KeyPurpose::Team);
        caught.stop(StoppedCause::RestartHeld);
        caught.stop(StoppedCause::CatchUp);

        assert_eq!(over_restore, Some(StoppedCause::RestartHeld));
        assert_eq!(held.clear_stop(StopClear::Reconfirmed), Err(StopNotCleared));
        assert_eq!(held.clear_stop(StopClear::AwaitedVersionsBack), Err(StopNotCleared));
        assert_eq!(held.clear_stop(StopClear::AcceptedRestart), Ok(()));
        assert_eq!(caught.stopped_cause, Some(StoppedCause::CatchUp));
        assert!(!StoppedCause::RestartHeld.is_reported());
        assert_eq!(StoppedCause::parse("restart_held"), Some(StoppedCause::RestartHeld));
    }

    #[test]
    fn ending_a_stopped_row_drops_its_cause() {
        let mut waiting = team_row(KeyPurpose::Team);
        waiting.stop(StoppedCause::RestoreWait);
        let epoch = EpochId(uuid::Uuid::from_u128(4));

        waiting.end(Some(epoch));

        assert_eq!(
            (waiting.state, waiting.stopped_cause, waiting.epoch),
            (KeyVersionState::Ended, None, Some(epoch))
        );
        assert_eq!(waiting.clear_stop(StopClear::AwaitedVersionsBack), Err(StopNotCleared));
    }

    #[test]
    fn a_personal_row_asked_to_wait_on_a_restore_records_catch_up() {
        let mut personal = team_row(KeyPurpose::Personal);

        personal.stop(StoppedCause::RestoreWait);

        assert_eq!(personal.stopped_cause, Some(StoppedCause::CatchUp));
    }

    #[test]
    fn the_key_of_a_row_is_its_primary_key_columns() {
        let key = RecordKey::new(ScopeName::Personal, Kind::Connection, "A");

        let encoded = RowKey::Base(key).encoded();

        assert_eq!(
            encoded,
            [
                &[1, 0, 0, 0, 8][..],
                b"personal",
                &[1, 0, 0, 0, 10],
                b"connection",
                &[1, 0, 0, 0, 1],
                b"A"
            ]
            .concat()
        );
    }
}
