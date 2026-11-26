// Team Library on the service engine (0051, Teams; 0054, The offline queue is on disk): the account's teams and
// items as this device holds them, the publish plan, the edits still to go up and their discard, the verified delete
// and the import of what 0.88 left unsent. The store keeps what only this device knows of each team, so every platform
// shares it. A sign-in that ended sends and shows nothing more, checked after every await.

mod delete;
mod import;
mod pass;
mod plan;
mod publish;
mod unsent;

use std::collections::{BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use async_trait::async_trait;
use tablepro_keys::encoding::{Origin, TeamId};
use tablepro_records::Kind;
use tablepro_storage::{
    StorageError, TeamLibraryItem, TeamLibraryKind, TeamLibraryLocal, TeamLibraryStore, TeamLibraryWriter,
};
use uuid::Uuid;

use super::{ServiceSync, Session, begin};
use crate::adapters::blocking;
use crate::api::adapter::RecordAdapter;
use crate::api::error::{AdapterError, StateError, SyncError};
use crate::api::ids::ScopeName;
use crate::api::scopes::Role;
use crate::api::state::{BaseRow, Row, RowRange, StateIdentity, Table};
use crate::api::team_library::{
    SignInGuard, TeamConnection, TeamFolder, TeamItem, TeamItemRef, TeamLibraryControl, TeamLibraryError,
    TeamLibraryImport, TeamLibraryPolicy, TeamLibraryTeam, TeamPublish, TeamQuery, TeamScopeStatus, UnsentTeamEdit,
};

pub(crate) const LIBRARY_KINDS: [TeamLibraryKind; 3] = [
    TeamLibraryKind::Connection,
    TeamLibraryKind::Folder,
    TeamLibraryKind::Query,
];

pub(crate) fn library_kind(kind: Kind) -> Option<TeamLibraryKind> {
    match kind {
        Kind::LibraryConnection => Some(TeamLibraryKind::Connection),
        Kind::LibraryFolder => Some(TeamLibraryKind::Folder),
        Kind::LibraryQuery => Some(TeamLibraryKind::Query),
        _ => None,
    }
}

struct Attached {
    store: TeamLibraryStore,
    sign_in: Arc<dyn SignInGuard>,
    policy: TeamLibraryPolicy,
}

// Team Library's part of the service: the store and sign-in it was given, whether a delete left it off, and the code
// each team's last pass met.
#[derive(Default)]
pub(crate) struct TeamLibrarySlot {
    attached: OnceLock<Attached>,
    off: AtomicBool,
    problems: Mutex<HashMap<ScopeName, String>>,
    // When this run last took the profile's names, so a renamed team shows within one poll of it.
    named_at_ms: Mutex<Option<i64>>,
}

// As often as the Swift app read the profile.
const NAMES_FRESH_MS: i64 = 15 * 60 * 1_000;

fn storage(error: StorageError) -> SyncError {
    match error {
        StorageError::DeletePending { .. } => TeamLibraryError::DeletePending.into(),
        error => AdapterError::Store {
            store: "team_library.json".to_owned(),
            detail: error.to_string(),
        }
        .into(),
    }
}

// Whether the owner the store was made for is the one this state file is bound to.
fn same_owner(identity: &StateIdentity, store: &TeamLibraryStore) -> bool {
    let StateIdentity::Service { origin, account, .. } = identity else {
        return false;
    };
    let owner = store.owner();
    Origin::of_url(&owner.origin).is_ok_and(|held| held == *origin)
        && Uuid::parse_str(&owner.account_id).is_ok_and(|id| id == account.0)
}

impl ServiceSync {
    // Once, over the store the Team Library adapters read, for the owner this state file is bound to. A delete a crash
    // cut off finishes first; if it cannot, Team Library stays off and this answers why.
    pub async fn attach_team_library(
        &self,
        store: TeamLibraryStore,
        sign_in: Arc<dyn SignInGuard>,
        policy: TeamLibraryPolicy,
    ) -> Result<(), SyncError> {
        if !same_owner(self.state.identity(), &store) {
            return Err(StateError::WrongIdentity.into());
        }
        let pending = {
            let store = store.clone();
            blocking(move || store.delete_pending_blocking()).await?
        };
        if self
            .team_library
            .attached
            .set(Attached { store, sign_in, policy })
            .is_err()
        {
            return Err(SyncError::NotAllowed {
                what: "attach a second team library",
            });
        }
        if pending {
            self.team_library.off.store(true, Ordering::SeqCst);
            let _session = self.session.lock().await;
            self.finish_delete().await?;
        }
        Ok(())
    }

    fn attached(&self) -> Result<&Attached, SyncError> {
        self.team_library.attached.get().ok_or(SyncError::Unimplemented {
            what: "sync.team_library",
        })
    }

    // Attached, and no delete waits.
    fn readable(&self) -> Result<&Attached, SyncError> {
        let attached = self.attached()?;
        if self.team_library_off() {
            return Err(TeamLibraryError::DeletePending.into());
        }
        Ok(attached)
    }

    fn signed_in(&self) -> Result<&Attached, SyncError> {
        let attached = self.readable()?;
        if !attached.sign_in.holds() {
            return Err(TeamLibraryError::SignedInChanged.into());
        }
        Ok(attached)
    }

    // Held by a commit that writes what goes up, from its check until it lands. The sign-in is checked again once the
    // read is held, since a sign-out does not wait on the gate.
    async fn policy_read(&self) -> Result<tablepro_account::PolicyRead, SyncError> {
        let policy = &self.attached()?.policy;
        let read = policy.gate.read().await;
        if !(policy.allowed)() {
            return Err(SyncError::NotAllowed {
                what: "send Team Library edits to a server the managed policy does not allow",
            });
        }
        self.signed_in()?;
        Ok(read)
    }

    // Just before each write of what goes up lands: a stop, a delete or the end of the sign-in keeps it out.
    fn team_commit_check(&self) -> Result<(), SyncError> {
        self.check_stop()?;
        self.signed_in().map(|_| ())
    }

    // Keep Mine on a team library conflict writes what goes up, so it commits as a publish does.
    pub(in crate::service) async fn team_keep_mine(&self) -> Result<tablepro_account::PolicyRead, SyncError> {
        self.signed_in()?;
        self.policy_read().await
    }

    // An empty team's pull ends caught up with no cursor, which is pulled all the same.
    async fn team_pulled(&self, scope: ScopeName) -> Result<bool, SyncError> {
        Ok(self
            .scope_row(scope)
            .await?
            .is_some_and(|row| row.epoch.is_some() && row.caught_up && !row.refill))
    }

    // A delete that did not finish, here or by another sign-in's call, keeps every team scope out of the pass, so
    // nothing of the owner is read or sent.
    pub(super) fn team_library_off(&self) -> bool {
        self.team_library.off.load(Ordering::SeqCst)
            || self
                .team_library
                .attached
                .get()
                .is_some_and(|attached| attached.store.delete_pending_blocking())
    }

    // True with no Team Library attached, as the engine's own tests run.
    pub(super) fn team_sign_in_holds(&self) -> bool {
        self.team_library
            .attached
            .get()
            .is_none_or(|attached| attached.sign_in.holds())
    }

    // Why a team batch built earlier in the pass may not go out now: the sign-in ended or a delete began meanwhile.
    pub(super) fn team_send_refused(&self) -> Option<SyncError> {
        if !self.team_sign_in_holds() {
            Some(TeamLibraryError::SignedInChanged.into())
        } else if self.team_library_off() {
            Some(TeamLibraryError::DeletePending.into())
        } else {
            None
        }
    }

    fn set_problems(&self, problems: HashMap<ScopeName, String>) {
        *self
            .team_library
            .problems
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = problems;
    }

    fn problem(&self, scope: ScopeName) -> Option<String> {
        self.team_library
            .problems
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&scope)
            .cloned()
    }

    fn library_adapters(&self, scope: ScopeName) -> Vec<(TeamLibraryKind, Arc<dyn RecordAdapter>)> {
        self.adapters
            .in_scope(scope)
            .into_iter()
            .filter_map(|adapter| library_kind(adapter.kind()).map(|kind| (kind, adapter)))
            .collect()
    }

    async fn store_call<T: Send + 'static>(
        &self,
        work: impl FnOnce(&TeamLibraryStore) -> Result<T, StorageError> + Send + 'static,
    ) -> Result<T, SyncError> {
        let store = self.attached()?.store.clone();
        blocking(move || work(&store)).await?.map_err(storage)
    }

    async fn team_items(&self, scope: ScopeName) -> Result<Vec<TeamLibraryItem>, SyncError> {
        let team = scope.wire();
        let held = self.store_call(move |store| store.team_blocking(&team)).await?;
        Ok(held.map(|team| team.items).unwrap_or_default())
    }

    async fn team_local(&self, scope: ScopeName) -> Result<TeamLibraryLocal, SyncError> {
        let team = scope.wire();
        self.store_call(move |store| store.local_blocking(&team)).await
    }

    async fn update_local<T: Send + 'static>(
        &self,
        scope: ScopeName,
        change: impl FnOnce(&mut TeamLibraryLocal) -> T + Send + 'static,
    ) -> Result<T, SyncError> {
        let team = scope.wire();
        self.store_call(move |store| store.update_local_blocking(&team, change))
            .await
    }

    async fn team_bases(&self, scope: ScopeName) -> Result<Vec<(TeamLibraryKind, BaseRow)>, SyncError> {
        let mut bases = Vec::new();
        for kind in LIBRARY_KINDS {
            for base in self.bases_in(scope, plan::kind_of(kind)).await? {
                bases.push((kind, base));
            }
        }
        Ok(bases)
    }

    // Every team this device knows of: in the last scopes body, in the state file, or in the store.
    async fn known_teams(&self, session: &Session) -> Result<Vec<ScopeName>, SyncError> {
        let mut teams: BTreeSet<TeamId> = BTreeSet::new();
        if let Some(body) = &session.body {
            teams.extend(body.scopes.iter().filter_map(|info| team_of(info.scope)));
        }
        for row in begin(&self.state).await?.scan(&RowRange::Table(Table::Scopes)).await? {
            if let Row::Scope(row) = row {
                teams.extend(team_of(row.scope));
            }
        }
        let stored = self
            .store_call(|store| {
                let mut ids: Vec<String> = store.teams_blocking()?.into_iter().map(|team| team.team_id).collect();
                ids.extend(store.locals_blocking()?.into_iter().map(|local| local.team_id));
                Ok(ids)
            })
            .await?;
        teams.extend(
            stored
                .iter()
                .filter_map(|id| ScopeName::parse(id).ok().and_then(team_of)),
        );
        Ok(teams.into_iter().map(ScopeName::Team).collect())
    }
}

fn team_of(scope: ScopeName) -> Option<TeamId> {
    match scope {
        ScopeName::Team(team) => Some(team),
        ScopeName::Personal | ScopeName::History => None,
    }
}

// Two records whose ids collide are both left out (0052, Team scope).
fn with_writers(
    items: Vec<TeamLibraryItem>,
    bases: &[(TeamLibraryKind, BaseRow)],
    writers: &[TeamLibraryWriter],
) -> Vec<TeamItem> {
    let collided = plan::collisions(
        items
            .iter()
            .map(|item| (item.kind, item.id.as_str()))
            .chain(bases.iter().map(|(kind, base)| (*kind, base.key.record_id.as_str()))),
    );
    items
        .into_iter()
        .filter(|item| !collided.contains(&(item.kind, item.id.to_lowercase())))
        .map(|item| {
            let writer = writers
                .iter()
                .find(|writer| writer.kind == item.kind && writer.id == item.id);
            TeamItem {
                updated_by: writer.and_then(|writer| writer.name.clone()),
                updated_at_ms: writer.map(|writer| writer.at_ms),
                item,
            }
        })
        .collect()
}

// Owners, admins and editors write the library (0051, Roles in a team scope).
fn writes(role: Option<Role>) -> bool {
    role.is_some_and(|role| role != Role::Member)
}

#[async_trait]
impl TeamLibraryControl for ServiceSync {
    async fn team_library(&self) -> Result<Vec<TeamLibraryTeam>, SyncError> {
        self.signed_in()?;
        let session = self.session.lock().await;
        let body = session.body.clone();
        drop(session);
        let mut teams = Vec::new();
        let scopes: Vec<(ScopeName, Option<Role>)> = match &body {
            Some(body) => body
                .scopes
                .iter()
                .filter(|info| matches!(info.scope, ScopeName::Team(_)))
                .map(|info| (info.scope, info.role))
                .collect(),
            None => self.team_rows().await?,
        };
        for (scope, role) in scopes {
            let Some(team) = team_of(scope) else { continue };
            let items = self.team_items(scope).await?;
            let bases = self.team_bases(scope).await?;
            let local = self.team_local(scope).await?;
            teams.push(TeamLibraryTeam {
                team,
                role,
                writable: writes(role),
                items: with_writers(items, &bases, &local.writers),
                name: local.name,
            });
        }
        self.signed_in()?;
        Ok(teams)
    }

    async fn teams_to_name(&self) -> Result<Vec<TeamId>, SyncError> {
        let teams = self.team_library().await?;
        let now = self.clock.now_ms();
        let named_at = *self
            .team_library
            .named_at_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let stale = named_at.is_none_or(|at| now.saturating_sub(at) >= NAMES_FRESH_MS);
        Ok(teams
            .into_iter()
            .filter(|team| stale || team.name.is_none())
            .map(|team| team.team)
            .collect())
    }

    // Only under the sign-in that listed the teams, so a profile read after a switch names nothing here.
    async fn name_teams(&self, names: Vec<(TeamId, String)>) -> Result<(), SyncError> {
        self.signed_in()?;
        *self
            .team_library
            .named_at_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(self.clock.now_ms());
        let mut changed = false;
        for (team, name) in names {
            let scope = ScopeName::Team(team);
            let name = (!name.trim().is_empty()).then_some(name);
            self.signed_in()?;
            changed |= self
                .update_local(scope, move |local| {
                    let changed = local.name != name;
                    local.name = name;
                    changed
                })
                .await?;
        }
        if let (true, Some(events)) = (changed, &self.events) {
            events.status_changed();
        }
        Ok(())
    }

    async fn publish_team_connections(
        &self,
        team: TeamId,
        connections: Vec<TeamConnection>,
    ) -> Result<TeamPublish, SyncError> {
        self.publish(team, move |view| plan::connections(view, &connections))
            .await
    }

    async fn publish_team_saved_queries(
        &self,
        team: TeamId,
        folders: Vec<TeamFolder>,
        queries: Vec<TeamQuery>,
    ) -> Result<TeamPublish, SyncError> {
        self.publish(team, move |view| plan::saved_queries(view, &folders, &queries))
            .await
    }

    async fn remove_team_items(&self, team: TeamId, items: Vec<TeamItemRef>) -> Result<TeamPublish, SyncError> {
        self.publish(team, move |view| plan::removals(view, &items)).await
    }

    async fn unsent_team_edits(&self) -> Result<Vec<UnsentTeamEdit>, SyncError> {
        self.readable()?;
        let session = self.session.lock().await;
        self.team_unsent(&session).await
    }

    async fn discard_team_edits(&self, team: Option<TeamId>) -> Result<(), SyncError> {
        self.readable()?;
        let session = self.session.lock().await;
        self.discard(&session, team.map(ScopeName::Team)).await
    }

    async fn delete_team_library_data(&self) -> Result<(), SyncError> {
        self.attached()?;
        let _session = self.session.lock().await;
        self.delete_all().await
    }

    async fn team_scope_status(&self) -> Result<Vec<TeamScopeStatus>, SyncError> {
        self.readable()?;
        let session = self.session.lock().await;
        let body = session.body.clone();
        drop(session);
        let scopes: Vec<(ScopeName, Option<Role>, Option<bool>)> = match &body {
            Some(body) => body
                .scopes
                .iter()
                .filter(|info| matches!(info.scope, ScopeName::Team(_)))
                .map(|info| (info.scope, info.role, Some(info.writable)))
                .collect(),
            None => self
                .team_rows()
                .await?
                .into_iter()
                .map(|(scope, role)| (scope, role, None))
                .collect(),
        };
        let mut status = Vec::new();
        for (scope, role, writable) in scopes {
            let Some(team) = team_of(scope) else { continue };
            status.push(TeamScopeStatus {
                team,
                last_synced_ms: self.team_local(scope).await?.synced_at_ms,
                pull_only: writable == Some(false),
                write_forbidden: role.is_some() && !writes(role),
                problem: self.problem(scope),
            });
        }
        Ok(status)
    }

    // Under the session lock, so a pass applying earlier imports or a delete never runs beside it.
    async fn import_team_library(&self, teams: Vec<TeamLibraryImport>) -> Result<(), SyncError> {
        self.signed_in()?;
        let session = self.session.lock().await;
        self.keep_imports(teams).await?;
        drop(session);
        self.journal.pass_soon(crate::api::control::PassReason::Person);
        Ok(())
    }
}

impl ServiceSync {
    // The team scopes the state file holds, as an offline launch shows them before the first scopes body.
    async fn team_rows(&self) -> Result<Vec<(ScopeName, Option<Role>)>, SyncError> {
        let rows = begin(&self.state).await?.scan(&RowRange::Table(Table::Scopes)).await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Scope(row) if matches!(row.scope, ScopeName::Team(_)) => Some((row.scope, row.role)),
                _ => None,
            })
            .collect())
    }
}
