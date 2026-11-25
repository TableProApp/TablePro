use std::fmt;

use async_trait::async_trait;
use serde_json::Value;
use tablepro_keys::encoding::{TeamId, Version};
use tablepro_keys::keys::Ed25519Seed;

use super::ids::{ChangeTag, Cursor, DeviceRowId, EpochId, IdempotencyKey, KindName, ScopeName};
use super::scopes::ScopesAnswer;

// What both providers do under the engine (0054, Transports): pull a page from a cursor and push a batch, with an
// answer per change. The service transport speaks `/v2/sync` over the generated client; the CloudKit one maps these to
// `CloudKitTransport` calls.
#[async_trait]
pub trait Transport: Send + Sync {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError>;

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError>;
}

// The service's calls beyond pull and push (0051, Protocol; Keys on the wire; Teams; Lifecycle and audit).
#[async_trait]
pub trait ServiceTransport: Transport {
    // `GET /v2/sync/scopes`, with `If-None-Match` from the last body's ETag.
    async fn scopes(&self, if_none_match: Option<String>, proof: Proof) -> Result<ScopesAnswer, TransportError>;

    // Sign Out's `DELETE /v2/sync/key-device`: no body, no idempotency key, a fresh proof on every try. 204 whatever
    // the key changed.
    async fn revoke_key_device(&self, proof: DpopKey) -> Result<(), TransportError>;

    // `PUT /v2/sync/scopes/{team}/stopped` with the version the device stopped at.
    async fn report_stopped(&self, team: TeamId, version: Version, proof: DpopKey) -> Result<(), TransportError>;

    // `DELETE /v2/sync/scopes/{team}/stopped`.
    async fn withdraw_stopped(&self, team: TeamId, proof: DpopKey) -> Result<(), TransportError>;

    // The apps' removal of a device row of an account with keys: `DELETE /v2/devices/{id}` with a proof from an
    // approved device, which needs a fresh step-up (0051, Removals).
    async fn remove_device_row(&self, device: DeviceRowId, proof: DpopKey) -> Result<(), TransportError>;
}

// The device signing key a DPoP proof is signed with (0051, Whose key the proof carries). Which DSK that is depends on
// the call, so the caller names it.
#[derive(Clone)]
pub struct DpopKey(pub std::sync::Arc<Ed25519Seed>);

impl fmt::Debug for DpopKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("DpopKey(redacted)")
    }
}

impl PartialEq for DpopKey {
    fn eq(&self, other: &Self) -> bool {
        self.0.expose() == other.0.expose()
    }
}

// A team plaintext read or write carries no proof; every personal or history call and every key-object or envelope
// write does (0051, DPoP).
#[derive(Debug, Clone, PartialEq, Default)]
pub enum Proof {
    #[default]
    None,
    Dpop(DpopKey),
}

#[derive(Debug, Clone, PartialEq)]
pub struct PullRequest {
    pub scope: ScopeName,
    // None takes a snapshot.
    pub cursor: Option<Cursor>,
    // At most 500 on the service; None takes the server's default.
    pub limit: Option<u32>,
    pub proof: Proof,
}

// A page of a pull. On the service a page with no records is caught up; on CloudKit `more` false is.
#[derive(Debug, Clone, PartialEq)]
pub struct PulledPage {
    pub records: Vec<PulledRecord>,
    // Where the next page starts. None on a scope with no records yet (0051, Scopes and records). On the history
    // scope's snapshot it pages older entries.
    pub cursor: Option<Cursor>,
    // The history scope's snapshot only: the changes after its mark (0051, Pull).
    pub changes_cursor: Option<Cursor>,
    pub caught_up: bool,
    // CloudKit names it changed but could not return; the engine fetches or holds them.
    pub unread: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PulledRecord {
    pub kind: KindName,
    pub record_id: String,
    pub tag: ChangeTag,
    // None on a tombstone, whose fields `/v2/sync` never sends.
    pub fields: Option<Value>,
    pub deleted: Option<DeletedReason>,
    // The service's columns; None on CloudKit.
    pub service: Option<ServiceMeta>,
}

// 0051, Pull: each record's server columns. Times are microseconds since the Unix epoch in UTC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceMeta {
    pub version: u64,
    pub revision: u64,
    pub epoch: EpochId,
    pub updated_at_us: i64,
    pub taken_at_us: i64,
    // A pending `key.reset`'s.
    pub held_until_us: Option<i64>,
    // A `key.request`'s.
    pub expires_at_us: Option<i64>,
    pub updated_by: Option<String>,
    pub updated_device: Option<DeviceRowId>,
    // A team record's writer, under the facade's rule for the caller's role.
    pub updated_by_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DeletedReason {
    // A client deleted it; a device deletes its copy under the conflict rules.
    User,
    // A policy job tombstoned it; a device keeps its copy (0051, Tombstones).
    Policy,
}

impl DeletedReason {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Policy => "policy",
        }
    }
}

// One push: every change judged on its own, except a change set, which applies whole or not at all (0051, Push).
#[derive(Debug, Clone, PartialEq)]
pub struct PushBatch {
    pub scope: ScopeName,
    // The epoch the device holds; the service refuses another one whole with `epoch_changed`. None on CloudKit.
    pub epoch: Option<EpochId>,
    // A UUIDv4 per batch on the service, kept in the outbox until answered. None on CloudKit.
    pub idempotency_key: Option<IdempotencyKey>,
    pub changes: Vec<Change>,
    pub proof: Proof,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    pub kind: KindName,
    pub record_id: String,
    // None creates the record.
    pub base: Option<ChangeTag>,
    pub op: ChangeOp,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ChangeOp {
    // `patch` is the RFC 7396 merge patch from the base to `fields`, which the service applies; CloudKit sets the
    // top-level fields the patch names from `fields`. A create's patch is its fields.
    Write { fields: Value, patch: Value },
    Delete,
}

// One answer per change, in the order sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushAnswer {
    pub outcomes: Vec<ChangeOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangeOutcome {
    Applied {
        // None when the change wrote nothing and the server holds no such record, as a delete of an absent one.
        tag: Option<ChangeTag>,
        // The service's new version and revision.
        service: Option<AppliedStamp>,
    },
    // The stored record, or None when the server has no such record. The service names its tag and no fields, so the
    // device pulls; CloudKit's `serverRecordChanged` carries the copy, or none, when the engine fetches it by name.
    Conflict {
        stored: Option<StoredCopy>,
    },
    // CloudKit's `unknownItem`: a save rebuilt from system fields met no record.
    Gone,
    Rejected {
        code: RejectedCode,
    },
    // A CloudKit per-record failure the engine retries.
    Failed {
        code: i64,
        retry_after_ms: Option<u64>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppliedStamp {
    pub version: u64,
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredCopy {
    pub tag: ChangeTag,
    pub tombstone: bool,
    pub service: Option<StoredStamp>,
    // CloudKit's server copy, mapped to wire fields.
    pub fields: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoredStamp {
    pub version: u64,
    pub revision: u64,
    pub epoch: EpochId,
}

// 0051's rejected codes, one per change.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RejectedCode {
    BadKind,
    BadRecordId,
    BadValue,
    SecretKey,
    TooLarge,
    KindNotInScope,
    Role,
    Policy,
    CreateOnly,
    WriterBound,
    RequestPending,
    RequestClosed,
    ResetHeld,
    KeyDependency,
    ChangeSet,
    TeamFull,
    IdCaseCollision,
    BadStatement,
    KeyVersionStale,
    KeyVersionUnknown,
    RotationDue,
    QuotaExceeded,
    // A code a newer server sends that this build does not know.
    Other(String),
}

const REJECTED: [(RejectedCode, &str); 22] = [
    (RejectedCode::BadKind, "bad_kind"),
    (RejectedCode::BadRecordId, "bad_record_id"),
    (RejectedCode::BadValue, "bad_value"),
    (RejectedCode::SecretKey, "secret_key"),
    (RejectedCode::TooLarge, "too_large"),
    (RejectedCode::KindNotInScope, "kind_not_in_scope"),
    (RejectedCode::Role, "role"),
    (RejectedCode::Policy, "policy"),
    (RejectedCode::CreateOnly, "create_only"),
    (RejectedCode::WriterBound, "writer_bound"),
    (RejectedCode::RequestPending, "request_pending"),
    (RejectedCode::RequestClosed, "request_closed"),
    (RejectedCode::ResetHeld, "reset_held"),
    (RejectedCode::KeyDependency, "key_dependency"),
    (RejectedCode::ChangeSet, "change_set"),
    (RejectedCode::TeamFull, "team_full"),
    (RejectedCode::IdCaseCollision, "id_case_collision"),
    (RejectedCode::BadStatement, "bad_statement"),
    (RejectedCode::KeyVersionStale, "key_version_stale"),
    (RejectedCode::KeyVersionUnknown, "key_version_unknown"),
    (RejectedCode::RotationDue, "rotation_due"),
    (RejectedCode::QuotaExceeded, "quota_exceeded"),
];

impl RejectedCode {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Other(code) => code,
            known => REJECTED
                .iter()
                .find(|(code, _)| code == known)
                .map_or("unknown", |(_, name)| name),
        }
    }

    pub fn parse(text: &str) -> Self {
        REJECTED
            .iter()
            .find(|(_, name)| *name == text)
            .map_or_else(|| Self::Other(text.to_owned()), |(code, _)| code.clone())
    }
}

// RFC 9470's challenge: `insufficient_user_authentication` with the methods and the age the call needs.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StepUpChallenge {
    pub acr_values: Vec<String>,
    pub max_age_secs: u64,
}

// A whole call refused or not made (0051, Whole-request refusals), and the transport's own failures.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TransportError {
    // The server asked for its nonce and the transport's retry with it was refused again.
    #[error("the server wants its DPoP nonce")]
    UseDpopNonce,
    #[error("the account lacks the feature")]
    FeatureRequired,
    #[error("the account has no seat in the team")]
    SeatRequired,
    #[error("the license is past grace")]
    LicenseExpired,
    // The device locks: it stops syncing, keeps its keys and cancels nothing (0056).
    #[error("this device's row was removed")]
    DeviceRemoved,
    #[error("the call needs a fresh step-up")]
    StepUpRequired(StepUpChallenge),
    #[error("this device is not approved for the call")]
    DeviceNotApproved,
    #[error("the sign-in came from a license key, not an interactive sign-in")]
    InteractiveSignInRequired,
    #[error("the scope is not reachable")]
    NotFound,
    #[error("the same idempotency key is still running")]
    IdempotencyInProgress,
    #[error("the request was malformed")]
    ValidationFailed,
    // Take a snapshot, and refill when the epoch changed (0051, Pull).
    #[error("the cursor expired")]
    CursorExpired,
    #[error("the server is in another epoch")]
    EpochChanged,
    #[error("the idempotency key was used with another body")]
    IdempotencyMismatch,
    #[error("rate limited")]
    RateLimited { retry_after_ms: Option<u64> },
    #[error("the server cannot run its restore check")]
    RestoreCheckUnavailable,
    // `GET /v2/sync/scopes` answered 404: the server has no `/v2/sync` (0051, Releases).
    #[error("the server is too old for TablePro Sync")]
    ServerTooOld,
    #[error("not signed in")]
    SignedOut,
    #[error("the network failed: {detail}")]
    Network { detail: String },
    // Another status or problem code, as the server sent it.
    #[error("the server answered {status} {code}")]
    Server { status: u16, code: String },
}

impl TransportError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::UseDpopNonce => "sync.use_dpop_nonce",
            Self::FeatureRequired => "sync.feature_required",
            Self::SeatRequired => "sync.seat_required",
            Self::LicenseExpired => "sync.license_expired",
            Self::DeviceRemoved => "sync.device_removed",
            Self::StepUpRequired(_) => "sync.step_up_required",
            Self::DeviceNotApproved => "sync.device_not_approved",
            Self::InteractiveSignInRequired => "sync.interactive_sign_in_required",
            Self::NotFound => "sync.not_found",
            Self::IdempotencyInProgress => "sync.idempotency_in_progress",
            Self::ValidationFailed => "sync.validation_failed",
            Self::CursorExpired => "sync.cursor_expired",
            Self::EpochChanged => "sync.epoch_changed",
            Self::IdempotencyMismatch => "sync.idempotency_mismatch",
            Self::RateLimited { .. } => "sync.rate_limited",
            Self::RestoreCheckUnavailable => "sync.restore_check_unavailable",
            Self::ServerTooOld => "sync.server_too_old",
            Self::SignedOut => "sync.signed_out",
            Self::Network { .. } => "sync.network",
            Self::Server { .. } => "sync.server",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_rejected_code_reads_back_as_itself() {
        for (code, name) in REJECTED {
            assert_eq!(code.as_str(), name);
            assert_eq!(RejectedCode::parse(name), code);
        }
        assert_eq!(
            RejectedCode::parse("new_code"),
            RejectedCode::Other("new_code".to_owned())
        );
        assert_eq!(RejectedCode::Other("new_code".to_owned()).as_str(), "new_code");
    }
}
