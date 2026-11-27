// Team Library as `TeamLibraryControl` answers it, for the FFI's and the apps' tests: teams and their items, unsent
// edits and scope status as a test sets them, each call recorded, and the refusals the contract names. A publish takes
// the answer the test scripted; the engine's own tests cover the plan.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_keys::encoding::TeamId;
use tablepro_sync::SyncError;
use tablepro_sync::api::team_library::{
    SignInGuard, TeamConnection, TeamFolder, TeamItemRef, TeamLibraryControl, TeamLibraryError, TeamLibraryImport,
    TeamLibraryTeam, TeamPublish, TeamQuery, TeamScopeStatus, UnsentTeamEdit,
};

#[cfg(test)]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TeamLibraryCall {
    PublishConnections(TeamId, Vec<TeamConnection>),
    PublishSavedQueries(TeamId, Vec<TeamFolder>, Vec<TeamQuery>),
    Remove(TeamId, Vec<TeamItemRef>),
    Discard(Option<TeamId>),
    Delete,
    Import(Vec<TeamLibraryImport>),
}

#[derive(Default)]
struct State {
    teams: Vec<TeamLibraryTeam>,
    unsent: Vec<UnsentTeamEdit>,
    status: Vec<TeamScopeStatus>,
    publish: TeamPublish,
    calls: Vec<TeamLibraryCall>,
    delete_fails: bool,
    deleted: bool,
    delete_pending: bool,
}

pub struct FakeTeamLibrary {
    state: Mutex<State>,
    sign_in: Arc<dyn SignInGuard>,
}

// A sign-in that never ends.
struct Held;

impl SignInGuard for Held {
    fn holds(&self) -> bool {
        true
    }
}

impl Default for FakeTeamLibrary {
    fn default() -> Self {
        Self::new(Arc::new(Held))
    }
}

impl FakeTeamLibrary {
    pub fn new(sign_in: Arc<dyn SignInGuard>) -> Self {
        Self {
            state: Mutex::new(State::default()),
            sign_in,
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn set_teams(&self, teams: Vec<TeamLibraryTeam>) {
        self.lock().teams = teams;
    }

    pub fn set_unsent(&self, unsent: Vec<UnsentTeamEdit>) {
        self.lock().unsent = unsent;
    }

    pub fn set_status(&self, status: Vec<TeamScopeStatus>) {
        self.lock().status = status;
    }

    // What the next publishes answer.
    pub fn answer_publishes(&self, publish: TeamPublish) {
        self.lock().publish = publish;
    }

    pub fn fail_deletes(&self, fails: bool) {
        self.lock().delete_fails = fails;
    }

    pub fn calls(&self) -> Vec<TeamLibraryCall> {
        self.lock().calls.clone()
    }

    pub fn deleted(&self) -> bool {
        self.lock().deleted
    }

    fn signed_in(&self) -> Result<(), SyncError> {
        if self.sign_in.holds() {
            Ok(())
        } else {
            Err(TeamLibraryError::SignedInChanged.into())
        }
    }

    fn readable(&self, state: &State) -> Result<(), SyncError> {
        if state.delete_pending {
            return Err(TeamLibraryError::DeletePending.into());
        }
        self.signed_in()
    }

    fn publish(&self, team: TeamId, call: TeamLibraryCall) -> Result<TeamPublish, SyncError> {
        let mut state = self.lock();
        self.readable(&state)?;
        let held = state
            .teams
            .iter()
            .find(|held| held.team == team)
            .ok_or(TeamLibraryError::UnknownTeam)?;
        if !held.writable {
            return Err(TeamLibraryError::NotWritable.into());
        }
        state.calls.push(call);
        Ok(state.publish.clone())
    }
}

#[async_trait]
impl TeamLibraryControl for FakeTeamLibrary {
    async fn team_library(&self) -> Result<Vec<TeamLibraryTeam>, SyncError> {
        let state = self.lock();
        self.readable(&state)?;
        Ok(state.teams.clone())
    }

    async fn teams_to_name(&self) -> Result<Vec<TeamId>, SyncError> {
        Ok(self
            .lock()
            .teams
            .iter()
            .filter(|team| team.name.is_none())
            .map(|team| team.team)
            .collect())
    }

    async fn name_teams(&self, names: Vec<(TeamId, String)>) -> Result<(), SyncError> {
        let mut state = self.lock();
        for (team, name) in names {
            if let Some(held) = state.teams.iter_mut().find(|held| held.team == team) {
                held.name = Some(name);
            }
        }
        Ok(())
    }

    async fn publish_team_connections(
        &self,
        team: TeamId,
        connections: Vec<TeamConnection>,
    ) -> Result<TeamPublish, SyncError> {
        self.publish(team, TeamLibraryCall::PublishConnections(team, connections))
    }

    async fn publish_team_saved_queries(
        &self,
        team: TeamId,
        folders: Vec<TeamFolder>,
        queries: Vec<TeamQuery>,
    ) -> Result<TeamPublish, SyncError> {
        self.publish(team, TeamLibraryCall::PublishSavedQueries(team, folders, queries))
    }

    async fn remove_team_items(&self, team: TeamId, items: Vec<TeamItemRef>) -> Result<TeamPublish, SyncError> {
        self.publish(team, TeamLibraryCall::Remove(team, items))
    }

    // Kept with the owner after an involuntary sign-out, so it reads without the sign-in.
    async fn unsent_team_edits(&self) -> Result<Vec<UnsentTeamEdit>, SyncError> {
        let state = self.lock();
        if state.delete_pending {
            return Err(TeamLibraryError::DeletePending.into());
        }
        Ok(state.unsent.clone())
    }

    // Local only, so it is taken after the sign-in ended too, as a sign-out asks before it signs out.
    async fn discard_team_edits(&self, team: Option<TeamId>) -> Result<(), SyncError> {
        let mut state = self.lock();
        if state.delete_pending {
            return Err(TeamLibraryError::DeletePending.into());
        }
        state.unsent.retain(|edit| team.is_some_and(|team| edit.team != team));
        state.calls.push(TeamLibraryCall::Discard(team));
        Ok(())
    }

    // Allowed after the sign-in ended, since Sign Out deletes once it has signed out.
    async fn delete_team_library_data(&self) -> Result<(), SyncError> {
        let mut state = self.lock();
        state.calls.push(TeamLibraryCall::Delete);
        if state.delete_fails {
            state.delete_pending = true;
            return Err(TeamLibraryError::DeleteFailed {
                detail: "the fake was told to fail".to_owned(),
            }
            .into());
        }
        state.teams.clear();
        state.unsent.clear();
        state.status.clear();
        state.delete_pending = false;
        state.deleted = true;
        Ok(())
    }

    async fn team_scope_status(&self) -> Result<Vec<TeamScopeStatus>, SyncError> {
        let state = self.lock();
        if state.delete_pending {
            return Err(TeamLibraryError::DeletePending.into());
        }
        Ok(state.status.clone())
    }

    async fn import_team_library(&self, teams: Vec<TeamLibraryImport>) -> Result<(), SyncError> {
        let mut state = self.lock();
        self.readable(&state)?;
        state.calls.push(TeamLibraryCall::Import(teams));
        Ok(())
    }
}
