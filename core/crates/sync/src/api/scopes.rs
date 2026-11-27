use tablepro_keys::encoding::{AccountId, Version};

use super::ids::{DeviceRowId, EpochId, ScopeName};

// `GET /v2/sync/scopes` (0051): the scopes this sign-in reaches and what the server advertises.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopesBody {
    // The current epoch's id.
    pub epoch: EpochId,
    pub scopes: Vec<ScopeInfo>,
    pub limits: ServerLimits,
    pub server_version: String,
    pub capabilities: Vec<String>,
    pub idempotency_retention_secs: u64,
    pub poll_interval_secs: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeInfo {
    pub scope: ScopeName,
    // A team scope's role for the caller; None on the personal and history scopes.
    pub role: Option<Role>,
    // The scope's highest committed revision, 0 before its first write.
    pub horizon: u64,
    // The lineage, oldest first, each epoch with the scope's kept revision (0 when it has no cut).
    pub epochs: Vec<LineageEpoch>,
    // False past grace or after a lapse, when only key-object writes are taken.
    pub writable: bool,
    pub policies: ScopePolicies,
    pub quota: Option<u64>,
    // Team scopes only.
    pub rotation_due: bool,
    // A team's roster for every seat; a server assertion, never a holder check (0051, `members`).
    pub members: Vec<TeamMember>,
    // Stop reports, served to owners and admins only.
    pub stopped: Vec<StopReport>,
    // The personal and history scopes, when the request carried a DPoP proof.
    pub approved: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LineageEpoch {
    pub id: EpochId,
    pub kept_revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Role {
    Owner,
    Admin,
    Editor,
    Member,
}

impl Role {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Editor => "editor",
            Self::Member => "member",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        [Self::Owner, Self::Admin, Self::Editor, Self::Member]
            .into_iter()
            .find(|role| role.as_str() == text)
    }

    // Owners and admins confirm members and rotate at any time (0051, Roles in a team scope).
    pub const fn manages_keys(self) -> bool {
        matches!(self, Self::Owner | Self::Admin)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TeamMember {
    pub account: AccountId,
    pub role: Role,
}

// One device row's report that it stopped on a team at a version (0051, A stopped device).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StopReport {
    pub account: AccountId,
    pub device: DeviceRowId,
    pub version: Version,
}

// The switches that apply to a scope, true when on (0051, Policies). A switch the scope does not carry is None.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ScopePolicies {
    pub personal_sync: Option<bool>,
    pub password_sync: Option<bool>,
    pub history_sync: Option<bool>,
}

// 0051, Limits, as the server advertises them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ServerLimits {
    pub record_bytes: u64,
    pub body_bytes: u64,
    pub changes_per_push: u32,
    pub changes_per_change_set: u32,
    pub page_records: u32,
    pub page_bytes: u64,
    pub json_depth: u32,
    pub team_key_holders: u32,
}

impl ServerLimits {
    pub const ADR_0051: Self = Self {
        record_bytes: 1 << 20,
        body_bytes: 4 << 20,
        changes_per_push: 500,
        changes_per_change_set: 10_000,
        page_records: 500,
        page_bytes: 4 << 20,
        json_depth: 32,
        team_key_holders: 5_000,
    };
}

// The answer to a poll: 304 when `If-None-Match` matched the strong ETag, else the body with its ETag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScopesAnswer {
    NotModified,
    Body { body: Box<ScopesBody>, etag: String },
}
