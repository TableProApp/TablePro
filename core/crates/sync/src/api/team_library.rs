// What an app asks of Team Library (0044, The library moves in; 0051, Teams; 0054, The offline queue is on disk): the
// open account's teams and items, publishing through the plan the Swift app had, the edits still on this device, their
// discard, the verified delete a sign-out or a switch of account needs, and the import of what 0.88 left unsent. What
// only this device knows of a team, which items it put there, which copies Keep Theirs turned down and the moves it
// still has to push, lives in the core so every platform shares it. Every method answers `sync.unimplemented` until
// the engine's lane overrides it.

use async_trait::async_trait;
use serde_json::Value;
// The FFI names teams by this type without depending on the keys crate.
pub use tablepro_keys::encoding::TeamId;
use tablepro_storage::{TeamLibraryItem, TeamLibraryKind};
use uuid::Uuid;

use super::error::SyncError;
use super::scopes::Role;

fn unimplemented<T>(what: &'static str) -> Result<T, SyncError> {
    Err(SyncError::unimplemented(what))
}

#[async_trait]
pub trait TeamLibraryControl: Send + Sync {
    // Every team scope the account reaches, with what this device holds of each.
    async fn team_library(&self) -> Result<Vec<TeamLibraryTeam>, SyncError> {
        unimplemented("sync.team_library")
    }

    // The teams whose name the profile should give: one with none yet, or every team once the names this run read are
    // older than the profile's poll. The app's read of the teams never waits on the profile.
    async fn teams_to_name(&self) -> Result<Vec<TeamId>, SyncError> {
        unimplemented("sync.teams_to_name")
    }

    // Names the scopes body does not carry, from the account's profile, kept for the next launch offline.
    async fn name_teams(&self, names: Vec<(TeamId, String)>) -> Result<(), SyncError> {
        let _ = names;
        unimplemented("sync.name_teams")
    }

    async fn publish_team_connections(
        &self,
        team: TeamId,
        connections: Vec<TeamConnection>,
    ) -> Result<TeamPublish, SyncError> {
        let _ = (team, connections);
        unimplemented("sync.publish_team_connections")
    }

    // Also removes the folders and queries this device published that `folders` and `queries` no longer hold.
    async fn publish_team_saved_queries(
        &self,
        team: TeamId,
        folders: Vec<TeamFolder>,
        queries: Vec<TeamQuery>,
    ) -> Result<TeamPublish, SyncError> {
        let _ = (team, folders, queries);
        unimplemented("sync.publish_team_saved_queries")
    }

    async fn remove_team_items(&self, team: TeamId, items: Vec<TeamItemRef>) -> Result<TeamPublish, SyncError> {
        let _ = (team, items);
        unimplemented("sync.remove_team_items")
    }

    async fn unsent_team_edits(&self) -> Result<Vec<UnsentTeamEdit>, SyncError> {
        unimplemented("sync.unsent_team_edits")
    }

    // None discards every team's.
    async fn discard_team_edits(&self, team: Option<TeamId>) -> Result<(), SyncError> {
        let _ = team;
        unimplemented("sync.discard_team_edits")
    }

    // The owner's store file and the team scopes of this state file, verified gone. Until it succeeds, Team Library
    // stays off for the owner, after a restart too.
    async fn delete_team_library_data(&self) -> Result<(), SyncError> {
        unimplemented("sync.delete_team_library_data")
    }

    async fn team_scope_status(&self) -> Result<Vec<TeamScopeStatus>, SyncError> {
        unimplemented("sync.team_scope_status")
    }

    // Kept on disk at once and applied once each team is pulled, so nothing is lost offline.
    async fn import_team_library(&self, teams: Vec<TeamLibraryImport>) -> Result<(), SyncError> {
        let _ = teams;
        unimplemented("sync.import_team_library")
    }
}

// The managed policy's word on the server this sign-in reaches (0055), read under the account's gate from a publish's
// check until its commit lands, as a move's commits are, so a value change lands wholly before the commit or after.
#[derive(Clone)]
pub struct TeamLibraryPolicy {
    pub gate: std::sync::Arc<tablepro_account::PolicyGate>,
    pub allowed: std::sync::Arc<dyn Fn() -> bool + Send + Sync>,
}

impl TeamLibraryPolicy {
    // With no account there is no policy, and no change to wait for.
    pub fn none() -> Self {
        Self {
            gate: std::sync::Arc::default(),
            allowed: std::sync::Arc::new(|| true),
        }
    }
}

// Whether the sign-in the service was opened with is still the account's. Reading the teams, a publish, an import and
// the push of a team's edits check it after every await, so nothing of one sign-in shows or goes out under another.
// The unsent edits, their discard, the status and the delete touch only this device's files and are kept with the
// owner, so a sign-out asks about them and deletes them after it signed out.
pub trait SignInGuard: Send + Sync {
    fn holds(&self) -> bool;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamLibraryTeam {
    pub team: TeamId,
    pub name: Option<String>,
    // None until the first scopes body this run.
    pub role: Option<Role>,
    pub writable: bool,
    pub items: Vec<TeamItem>,
}

// An item with who last changed it and when, as the last pull of it said; None before a pull named anyone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamItem {
    pub item: TeamLibraryItem,
    pub updated_by: Option<String>,
    pub updated_at_ms: Option<i64>,
}

// The id the team stores, compared without case as shipped Macs match them (0052, Team scope).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TeamItemRef {
    pub kind: TeamLibraryKind,
    pub id: String,
}

// `settings` is the connection's bundle (`ExportableConnection`); its secret keys never leave the device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamConnection {
    pub id: Uuid,
    pub settings: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamFolder {
    pub id: Uuid,
    pub name: String,
    pub parent: Option<Uuid>,
    pub sort_order: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamQuery {
    pub id: Uuid,
    pub name: String,
    pub query: String,
    pub keyword: Option<String>,
    pub folder: Option<Uuid>,
    pub connection: Option<Uuid>,
    pub sort_order: i64,
}

// A publish ends after the pass it starts: `edits` 0 means the team already holds everything as it would be sent.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TeamPublish {
    pub edits: u32,
    pub conflicts: u32,
    pub unsent: u32,
    // The pass's error code while edits wait.
    pub problem: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnsentState {
    Pending,
    Conflict,
    // The server's code, or the device's when it can see the refusal coming; listed until discarded.
    Refused { code: String },
    // An imported edit waiting for the team's first pull.
    Waiting,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsentTeamEdit {
    pub team: TeamId,
    pub item: TeamItemRef,
    pub name: Option<String>,
    pub deletion: bool,
    pub state: UnsentState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamScopeStatus {
    pub team: TeamId,
    pub last_synced_ms: Option<i64>,
    // Past grace or after a lapse: pulls go on and edits wait (0051, Gates).
    pub pull_only: bool,
    // A member's role, or a seat that reads only.
    pub write_forbidden: bool,
    pub problem: Option<String>,
}

// What 0.88 kept for one team: its unsent edits against the facade's versions, and the items it published or turned
// down, which only this device knew.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamLibraryImport {
    pub team: TeamId,
    pub edits: Vec<ImportedEdit>,
    pub published: Vec<TeamItemRef>,
    pub declined: Vec<(TeamItemRef, Value)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedEdit {
    pub item: TeamItemRef,
    // None for a create, or an edit 0.88 sent without a base so the team would ask before bringing it back.
    pub base: Option<FacadeBase>,
    // None deletes.
    pub fields: Option<Value>,
    // It only moves someone else's item out of a folder this device deleted, so it never becomes this device's.
    pub moved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FacadeBase {
    pub version: u64,
    // The item at that version, when 0.88 still held it.
    pub fields: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TeamLibraryError {
    #[error("the sign-in this sync service was opened with has ended")]
    SignedInChanged,
    #[error("this account reaches no such team")]
    UnknownTeam,
    #[error("this account's role does not write the team's library")]
    NotWritable,
    // A publish needs the team's copy to plan against.
    #[error("the team's library has not been pulled yet")]
    NotPulled,
    // Past grace or after a lapse: the edits wait on the device, as a publish's problem says.
    #[error("the team takes no edits for now")]
    PullOnly,
    #[error("{what} is not well formed")]
    Malformed { what: &'static str },
    // An earlier delete did not finish: nothing of the owner's Team Library is read until one does.
    #[error("the Team Library data waits for its delete")]
    DeletePending,
    #[error("the Team Library data could not be deleted: {detail}")]
    DeleteFailed { detail: String },
    // Two of the team's records share the id once lower-cased, so an edit of it could land on either (0052).
    #[error("two of the team's items share this id")]
    IdCaseCollision,
}

impl TeamLibraryError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::SignedInChanged => "sync.team_library.signed_in_changed",
            Self::UnknownTeam => "sync.team_library.unknown_team",
            Self::NotWritable => "sync.team_library.not_writable",
            Self::NotPulled => "sync.team_library.not_pulled",
            Self::PullOnly => "sync.team_library.pull_only",
            Self::Malformed { .. } => "sync.team_library.malformed",
            Self::DeletePending => "sync.team_library.delete_pending",
            Self::DeleteFailed { .. } => "sync.team_library.delete_failed",
            Self::IdCaseCollision => "sync.team_library.id_case_collision",
        }
    }
}
