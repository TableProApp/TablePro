use tablepro_keys::KeysError;

use super::cloudkit::CloudKitFailure;
use super::device_store::DeviceStoreError;
use super::key_flows::LockCause;
use super::transport::{RejectedCode, TransportError};

// Every sync error with a stable `code()` (core/AGENTS.md, Principles). The keys' codes pass through as 0056 gives
// them; the server's refusals carry 0051's code under `sync.`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SyncError {
    // A contract whose lane has not filled it yet. Nothing ships while one answers this.
    #[error("{what} is not built yet")]
    Unimplemented { what: &'static str },
    #[error("malformed {what}")]
    Malformed { what: &'static str },
    #[error(transparent)]
    Keys(#[from] KeysError),
    #[error(transparent)]
    Transport(#[from] TransportError),
    #[error(transparent)]
    CloudKit(#[from] CloudKitFailure),
    #[error(transparent)]
    DeviceStore(#[from] DeviceStoreError),
    #[error(transparent)]
    State(#[from] StateError),
    #[error(transparent)]
    Adapter(#[from] AdapterError),
    // A flow's change set or write was refused, with the change's code (0051, Push).
    #[error("the server refused the change: {}", code.as_str())]
    Rejected { code: RejectedCode },
    // The device keeps its keys and syncs nothing personal until it is approved again (0056, A locked device).
    #[error("this device is locked: {cause:?}")]
    Locked { cause: LockCause },
    // The two groups of the recovery key typed back do not match what was shown (0056, The recovery key).
    #[error("the recovery key was typed back wrong")]
    TypedBackWrong,
    // A draft, review or session this service does not hold, or no longer holds.
    #[error("no such {what}")]
    Unknown { what: &'static str },
    // The call needs an approved device, a device store or keys this device does not hold.
    #[error("this device cannot {what} now")]
    NotAllowed { what: &'static str },
    #[error("the call was cancelled")]
    Cancelled,
}

impl SyncError {
    pub const fn unimplemented(what: &'static str) -> Self {
        Self::Unimplemented { what }
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::Unimplemented { .. } => "sync.unimplemented",
            Self::Malformed { .. } => "sync.malformed",
            Self::Keys(error) => error.code(),
            Self::Transport(error) => error.code(),
            Self::CloudKit(failure) => failure.code(),
            Self::DeviceStore(error) => error.code(),
            Self::State(error) => error.code(),
            Self::Adapter(error) => error.code(),
            Self::Rejected { .. } => "sync.rejected",
            Self::Locked { .. } => "sync.locked",
            Self::TypedBackWrong => "sync.typed_back_wrong",
            Self::Unknown { .. } => "sync.unknown",
            Self::NotAllowed { .. } => "sync.not_allowed",
            Self::Cancelled => "sync.cancelled",
        }
    }
}

// The state file's own failures (0054, The state file; Integrity and freshness).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum StateError {
    // The file was made for another provider, server, account or device.
    #[error("the state file belongs to another identity")]
    WrongIdentity,
    // The state MAC does not verify: the file is refused.
    #[error("the state file's MAC does not verify")]
    Integrity,
    // A pending anchor entry could not be settled, so no commit may start (0054, A commit writes its anchor).
    #[error("the anchor has a pending entry that cannot be settled")]
    AnchorUnsettled,
    // Another process holds the state file's lock (0054, Scheduling).
    #[error("another process holds the state file")]
    Busy,
    #[error("the state file failed: {detail}")]
    Io { detail: String },
}

impl StateError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::WrongIdentity => "sync.state.wrong_identity",
            Self::Integrity => "sync.state.integrity",
            Self::AnchorUnsettled => "sync.state.anchor_unsettled",
            Self::Busy => "sync.state.busy",
            Self::Io { .. } => "sync.state.io",
        }
    }
}

// A record adapter's failures, over the store it reads and writes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AdapterError {
    #[error("the {store} store failed: {detail}")]
    Store { store: String, detail: String },
    // A record whose fields this build cannot read; the engine holds it by id (0054, Rules for both providers).
    #[error("the record cannot be read: {detail}")]
    Unreadable { detail: String },
    // The host's settings call failed.
    #[error("the host's settings failed: {detail}")]
    Host { detail: String },
}

impl AdapterError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Store { .. } => "sync.adapter.store",
            Self::Unreadable { .. } => "sync.adapter.unreadable",
            Self::Host { .. } => "sync.adapter.host",
        }
    }
}
