// Team Library over the engine (`tablepro_sync::api::TeamLibraryControl`): the open account's teams and items, the
// publish plan, unsent edits, their discard, the verified delete and the import of what 0.88 left unsent. A team is its
// scope name (`team_...`), the id `ProfileInfo.teams` carries; fields are JSON text; a connection, folder or query id
// from the app is its UUID in either case.

use std::sync::Arc;

use serde_json::Value;
use tablepro_keys::encoding::{AccountId, Origin};
use tablepro_storage::{
    ChangeJournal, ConnectionListState, SshProfile, StoragePaths, TeamLibraryKind, TeamLibraryOwner, TeamLibraryStore,
};
use tablepro_sync::SyncError;
use tablepro_sync::adapters::library::{DriverNames, team_bundle, team_connection};
use tablepro_sync::adapters::store_journal::StoreJournal;
use tablepro_sync::api::ids::{ScopeName, typeid_uuid};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::StateIdentity;
use tablepro_sync::api::team_library::{
    FacadeBase, ImportedEdit, SignInGuard, TeamConnection, TeamFolder, TeamId, TeamItem, TeamItemRef,
    TeamLibraryControl, TeamLibraryError, TeamLibraryImport, TeamLibraryPolicy, TeamLibraryTeam, TeamPublish,
    TeamQuery, TeamScopeStatus, UnsentState, UnsentTeamEdit,
};
use tablepro_sync::service::ServiceSync;
use uuid::Uuid;

use super::keys::TeamRoleTag;
use super::service::SyncService;
use crate::account::AccountService;
use crate::core_handle::Core;
use crate::error::CoreError;
use crate::library_contents::{LibraryConnectionRecord, stored_connection};
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TeamLibraryKindTag {
    Connection,
    Folder,
    Query,
}

// The id the team stores, byte for byte; the core matches it without case.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TeamLibraryItemRef {
    pub kind: TeamLibraryKindTag,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamLibraryItemInfo {
    pub kind: TeamLibraryKindTag,
    pub id: String,
    pub fields_json: String,
    // A connection item read as a library connection (the Mac's bundle, `ExportableConnection`), in this platform's
    // driver names; None for a folder or a query, and for a copy whose id is not a UUID.
    #[uniffi(default = None)]
    pub connection: Option<LibraryConnectionRecord>,
    // Who last changed it, as the server names them to this account, and when in milliseconds since the Unix epoch;
    // None until a pull names anyone.
    #[uniffi(default = None)]
    pub updated_by: Option<String>,
    #[uniffi(default = None)]
    pub updated_at_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamLibraryTeamInfo {
    pub team_id: String,
    // The profile's name for the team, kept for an offline launch; None until the core has read one.
    pub name: Option<String>,
    // None until the first scopes body this run.
    pub role: Option<TeamRoleTag>,
    pub can_write: bool,
    pub items: Vec<TeamLibraryItemInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamFolderArg {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub sort_order: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamQueryArg {
    pub id: String,
    pub name: String,
    pub query: String,
    pub keyword: Option<String>,
    pub folder_id: Option<String>,
    pub connection_id: Option<String>,
    pub sort_order: i64,
}

// After the pass the publish starts. `edits` 0: the team already held everything as it would be sent. `conflicts`
// wait for Keep Mine or Keep Theirs (`SyncService::conflicts`); `unsent` stay on this device, with the pass's error.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamPublishInfo {
    pub edits: u32,
    pub conflicts: u32,
    pub unsent: u32,
    pub problem: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum UnsentTeamEditTag {
    Pending,
    Conflict,
    // Listed with the server's code until it is discarded or a later publish of the item is taken.
    Refused { code: String },
    // An imported edit waiting for the team's first pull.
    Waiting,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UnsentTeamEditInfo {
    pub team_id: String,
    pub item: TeamLibraryItemRef,
    pub name: Option<String>,
    pub deletion: bool,
    pub state: UnsentTeamEditTag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamScopeStatusInfo {
    pub team_id: String,
    pub last_synced_ms: Option<i64>,
    // Past grace or after a lapse: pulls go on and edits wait.
    pub pull_only: bool,
    pub write_forbidden: bool,
    pub problem: Option<String>,
}

// One team of the library 0.88 kept: its unsent edits, and the items it published or turned down.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamLibraryImportArg {
    pub team_id: String,
    pub edits: Vec<TeamImportedEditArg>,
    pub published: Vec<TeamLibraryItemRef>,
    pub declined: Vec<TeamDeclinedArg>,
}

// `base_version` is the facade's version the edit was made against, None for a create. `fields_json` None deletes.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamImportedEditArg {
    pub item: TeamLibraryItemRef,
    pub base_version: Option<u64>,
    pub base_fields_json: Option<String>,
    pub fields_json: Option<String>,
    pub moved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamDeclinedArg {
    pub item: TeamLibraryItemRef,
    pub fields_json: String,
}

// A Team Library owner as the account names it: `ServerInfo.api_origin` and `AccountStatusInfo.account_id`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct TeamLibraryOwnerArg {
    pub api_origin: String,
    pub account_id: String,
}

// The owner a service engine's sign-in binds its Team Library to, spelled as `team_library_owner` spells one.
fn owner_of(identity: &StateIdentity) -> Option<TeamLibraryOwner> {
    let StateIdentity::Service { origin, account, .. } = identity else {
        return None;
    };
    Some(TeamLibraryOwner {
        origin: origin.as_str().to_owned(),
        account_id: account.to_wire(),
    })
}

// A call names the owner it means, which must be the engine's: the engine an account switch opens has another, so a
// call the app started for one account never lands on the next one's library.
fn check_owner(expected: &TeamLibraryOwnerArg, identity: &StateIdentity) -> Result<(), CoreError> {
    let expected = team_library_owner(&expected.api_origin, &expected.account_id).ok_or_else(|| malformed("owner"))?;
    if owner_of(identity).as_ref() != Some(&expected) {
        return Err(SyncError::from(TeamLibraryError::OtherOwner).into());
    }
    Ok(())
}

// One spelling of each owner, so the app's and the engine's name the same store file: the API's origin, and the
// account's UUID as the state file binds it, whether the account names it by UUID or by its `acct_` TypeID.
pub(crate) fn team_library_owner(api_origin: &str, account_id: &str) -> Option<TeamLibraryOwner> {
    let origin = Origin::of_url(api_origin).ok()?;
    let account = Uuid::parse_str(account_id)
        .ok()
        .or_else(|| typeid_uuid("acct_", account_id))?;
    Some(TeamLibraryOwner {
        origin: origin.as_str().to_owned(),
        account_id: AccountId(account).to_wire(),
    })
}

fn malformed(what: &'static str) -> CoreError {
    SyncError::from(TeamLibraryError::Malformed { what }).into()
}

fn team(team_id: &str) -> Result<TeamId, CoreError> {
    match ScopeName::parse(team_id) {
        Ok(ScopeName::Team(team)) => Ok(team),
        _ => Err(malformed("team id")),
    }
}

fn team_id(team: TeamId) -> String {
    ScopeName::Team(team).wire()
}

fn entity(id: &str, what: &'static str) -> Result<Uuid, CoreError> {
    Uuid::parse_str(id).map_err(|_| malformed(what))
}

fn entity_of(id: Option<&str>, what: &'static str) -> Result<Option<Uuid>, CoreError> {
    id.filter(|id| !id.is_empty()).map(|id| entity(id, what)).transpose()
}

fn object(json: &str, what: &'static str) -> Result<Value, CoreError> {
    match serde_json::from_str::<Value>(json) {
        Ok(value @ Value::Object(_)) => Ok(value),
        _ => Err(malformed(what)),
    }
}

fn kind(tag: TeamLibraryKindTag) -> TeamLibraryKind {
    match tag {
        TeamLibraryKindTag::Connection => TeamLibraryKind::Connection,
        TeamLibraryKindTag::Folder => TeamLibraryKind::Folder,
        TeamLibraryKindTag::Query => TeamLibraryKind::Query,
    }
}

fn kind_tag(kind: TeamLibraryKind) -> TeamLibraryKindTag {
    match kind {
        TeamLibraryKind::Connection => TeamLibraryKindTag::Connection,
        TeamLibraryKind::Folder => TeamLibraryKindTag::Folder,
        TeamLibraryKind::Query => TeamLibraryKindTag::Query,
    }
}

fn role_tag(role: Role) -> TeamRoleTag {
    match role {
        Role::Owner => TeamRoleTag::Owner,
        Role::Admin => TeamRoleTag::Admin,
        Role::Editor => TeamRoleTag::Editor,
        Role::Member => TeamRoleTag::Member,
    }
}

fn item_ref(item: TeamLibraryItemRef) -> TeamItemRef {
    TeamItemRef {
        kind: kind(item.kind),
        id: item.id,
    }
}

fn item_ref_info(item: TeamItemRef) -> TeamLibraryItemRef {
    TeamLibraryItemRef {
        kind: kind_tag(item.kind),
        id: item.id,
    }
}

// A tunnel whose host or user `ssh` would read as an option or a shell word, refused as the Mac refuses a team copy
// (`refusedSSHDestination`): a teammate's copy never reaches `ssh` with one.
fn refused_destination(saved: &tablepro_storage::SavedConnection) -> bool {
    let Some(ssh) = saved.ssh.as_ref().filter(|ssh| ssh.enabled) else {
        return false;
    };
    let user = |name: Option<&String>| name.filter(|name| !name.is_empty()).cloned();
    std::iter::once((ssh.host.as_str(), ssh.port, user(ssh.username.as_ref())))
        .chain(
            ssh.jump_hosts
                .iter()
                .map(|hop| (hop.host.as_str(), hop.port, user(hop.username.as_ref()))),
        )
        .filter(|(host, _, _)| !host.trim().is_empty())
        .any(|(host, port, user)| tablepro_ssh::SshDestination::new(host, port, user).is_err())
}

// A team's connection as the app shows it: the bundle read the way every platform reads it, linking only an SSH profile
// this device holds. None for one whose tunnel names a destination `ssh` would misread.
fn item_info(item: TeamItem, names: DriverNames, profiles: &[SshProfile]) -> TeamLibraryItemInfo {
    let connection = (item.item.kind == TeamLibraryKind::Connection)
        .then(|| Uuid::parse_str(&item.item.id).ok())
        .flatten()
        .map(|id| {
            team_connection(id, &item.item.fields, names, |profile| {
                profiles.iter().any(|held| held.id == profile)
            })
        })
        .filter(|saved| !refused_destination(saved))
        .map(|saved| LibraryConnectionRecord::from(&saved));
    TeamLibraryItemInfo {
        kind: kind_tag(item.item.kind),
        id: item.item.id,
        fields_json: item.item.fields.to_string(),
        connection,
        updated_by: item.updated_by,
        updated_at_ms: item.updated_at_ms,
    }
}

fn team_info(team: TeamLibraryTeam, names: DriverNames, profiles: &[SshProfile]) -> TeamLibraryTeamInfo {
    TeamLibraryTeamInfo {
        team_id: team_id(team.team),
        name: team.name,
        role: team.role.map(role_tag),
        can_write: team.writable,
        items: team
            .items
            .into_iter()
            .map(|item| item_info(item, names, profiles))
            .collect(),
    }
}

fn publish_info(publish: TeamPublish) -> TeamPublishInfo {
    TeamPublishInfo {
        edits: publish.edits,
        conflicts: publish.conflicts,
        unsent: publish.unsent,
        problem: publish.problem,
    }
}

fn unsent_info(edit: UnsentTeamEdit) -> UnsentTeamEditInfo {
    UnsentTeamEditInfo {
        team_id: team_id(edit.team),
        item: item_ref_info(edit.item),
        name: edit.name,
        deletion: edit.deletion,
        state: match edit.state {
            UnsentState::Pending => UnsentTeamEditTag::Pending,
            UnsentState::Conflict => UnsentTeamEditTag::Conflict,
            UnsentState::Refused { code } => UnsentTeamEditTag::Refused { code },
            UnsentState::Waiting => UnsentTeamEditTag::Waiting,
        },
    }
}

fn status_info(status: TeamScopeStatus) -> TeamScopeStatusInfo {
    TeamScopeStatusInfo {
        team_id: team_id(status.team),
        last_synced_ms: status.last_synced_ms,
        pull_only: status.pull_only,
        write_forbidden: status.write_forbidden,
        problem: status.problem,
    }
}

// The bundle the team gets, built the one way every platform builds it; the publish strips every secret key.
fn connection(
    record: LibraryConnectionRecord,
    names: DriverNames,
    profiles: &[SshProfile],
) -> Result<TeamConnection, CoreError> {
    let id = entity(&record.connection.id, "connection id")?;
    let saved = stored_connection(id, record, None)?;
    let profile = saved
        .details
        .ssh_profile_id
        .and_then(|linked| profiles.iter().find(|held| held.id == linked));
    Ok(TeamConnection {
        id,
        settings: team_bundle(&saved, profile, names),
    })
}

fn folder(arg: TeamFolderArg) -> Result<TeamFolder, CoreError> {
    Ok(TeamFolder {
        id: entity(&arg.id, "folder id")?,
        name: arg.name,
        parent: entity_of(arg.parent_id.as_deref(), "folder id")?,
        sort_order: arg.sort_order,
    })
}

fn query(arg: TeamQueryArg) -> Result<TeamQuery, CoreError> {
    Ok(TeamQuery {
        id: entity(&arg.id, "query id")?,
        name: arg.name,
        query: arg.query,
        keyword: arg.keyword,
        folder: entity_of(arg.folder_id.as_deref(), "folder id")?,
        connection: entity_of(arg.connection_id.as_deref(), "connection id")?,
        sort_order: arg.sort_order,
    })
}

fn imported_edit(arg: TeamImportedEditArg) -> Result<ImportedEdit, CoreError> {
    let base = match (arg.base_version, arg.base_fields_json) {
        (Some(version), fields) => Some(FacadeBase {
            version,
            fields: fields.map(|fields| object(&fields, "imported base")).transpose()?,
        }),
        (None, Some(_)) => return Err(malformed("imported base")),
        (None, None) => None,
    };
    Ok(ImportedEdit {
        item: item_ref(arg.item),
        base,
        fields: arg
            .fields_json
            .map(|fields| object(&fields, "imported edit"))
            .transpose()?,
        moved: arg.moved,
    })
}

fn import(arg: TeamLibraryImportArg) -> Result<TeamLibraryImport, CoreError> {
    Ok(TeamLibraryImport {
        team: team(&arg.team_id)?,
        edits: arg.edits.into_iter().map(imported_edit).collect::<Result<_, _>>()?,
        published: arg.published.into_iter().map(item_ref).collect(),
        declined: arg
            .declined
            .into_iter()
            .map(|declined| Ok((item_ref(declined.item), object(&declined.fields_json, "declined copy")?)))
            .collect::<Result<_, CoreError>>()?,
    })
}

impl SyncService {
    // Team scopes always use TablePro Sync, whatever the personal provider is (core ADR 0054, Providers), so every
    // Team Library call reaches the service engine, which runs teams-only on an iCloud or Off device.
    // On the engine of the owner the app means. An engine's owner never changes, and a sign-in-bound call checks that
    // the sign-in still holds after every await, so nothing lands on another account's library.
    async fn on_team_library<T, F>(
        &self,
        expected_owner: TeamLibraryOwnerArg,
        work: impl FnOnce(Arc<dyn TeamLibraryControl>) -> F + Send + 'static,
    ) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, SyncError>> + Send + 'static,
    {
        let service = Arc::clone(&self.service);
        on_runtime(&self.tasks, async move {
            let engine = service.engine().await?;
            check_owner(&expected_owner, engine.sync.identity())?;
            work(Arc::clone(&engine.sync) as Arc<dyn TeamLibraryControl>)
                .await
                .map_err(CoreError::from)
        })
        .await
    }

    fn driver_names(&self) -> DriverNames {
        super::open::driver_names(self.config.platform)
    }

    // The SSH profiles this Core's library holds, as it last read them: the only ones a team copy may link.
    fn held_profiles(&self) -> Vec<SshProfile> {
        match self.connections.as_ref().map(|store| store.snapshot().state) {
            Some(ConnectionListState::Ready(list)) => list.ssh_profiles.to_vec(),
            _ => Vec::new(),
        }
    }
}

// What the service engine needs to run Team Library for its sign-in: where the store lives and the account whose
// sign-in it stays bound to.
#[derive(Clone)]
pub(crate) struct TeamLibraryHost {
    pub(crate) paths: StoragePaths,
    pub(crate) account: Arc<AccountService>,
}

impl TeamLibraryHost {
    // The owner's store, which the engine's adapters read and write, and whose writes the engines that listen to this
    // Core's stores hear (core ADR 0060).
    pub(crate) fn store(&self, origin: &Origin, account: AccountId, journal: &Arc<StoreJournal>) -> TeamLibraryStore {
        let store = TeamLibraryStore::new(
            &self.paths,
            TeamLibraryOwner {
                origin: origin.as_str().to_owned(),
                account_id: account.to_wire(),
            },
        );
        store.set_journal(Some(Arc::clone(journal) as Arc<dyn ChangeJournal>));
        store
    }

    // A delete a crash cut off finishes here; until it does, Team Library stays off and the engine runs on. A publish
    // commits only while the managed policy allows this sign-in's server, under the account's gate (core ADR 0055).
    pub(crate) async fn attach(
        &self,
        sync: &ServiceSync,
        store: TeamLibraryStore,
        session: Option<String>,
        origin: Origin,
    ) {
        let guard = SessionGuard {
            account: Arc::clone(&self.account),
            session,
        };
        let account = self.account.account.clone();
        let policy = TeamLibraryPolicy {
            gate: account.policy_gate(),
            allowed: Arc::new(move || account.policy().allows_server(origin.as_str())),
        };
        if let Err(error) = sync.attach_team_library(store, Arc::new(guard), policy).await {
            tracing::warn!(code = error.code(), "team library is off for this sign-in");
        }
    }
}

// The sign-in the engine started for, by its session id: a sign-out, another sign-in or a restore has another.
struct SessionGuard {
    account: Arc<AccountService>,
    session: Option<String>,
}

impl SignInGuard for SessionGuard {
    fn holds(&self) -> bool {
        self.session.is_some() && self.account.status().session_id == self.session
    }
}

async fn name_teams(control: Arc<dyn TeamLibraryControl>, account: tablepro_account::Account) {
    name_teams_from(control, async move { account.profile().await }).await;
}

// The engine holds the state file, so the profile read, which waits on the network, holds it only weakly: a service
// that closes meanwhile lets its file go at once, and the names read for it are dropped.
async fn name_teams_from(
    control: Arc<dyn TeamLibraryControl>,
    profile: impl Future<Output = Result<tablepro_account::Profile, tablepro_account::AccountError>>,
) {
    let due = match control.teams_to_name().await {
        Ok(due) if !due.is_empty() => due,
        _ => return,
    };
    let held = Arc::downgrade(&control);
    drop(control);
    let profile = match profile.await {
        Ok(profile) => profile,
        Err(error) => {
            tracing::debug!(code = error.code(), "the profile gave no team names");
            return;
        }
    };
    let Some(control) = held.upgrade() else {
        return;
    };
    let names = profile
        .teams
        .into_iter()
        .filter_map(|membership| match ScopeName::parse(&membership.team.id) {
            Ok(ScopeName::Team(team)) if due.contains(&team) => Some((team, membership.team.name)),
            _ => None,
        })
        .collect();
    if let Err(error) = control.name_teams(names).await {
        tracing::debug!(code = error.code(), "the team names were not kept");
    }
}

// Every Team Library call names the owner the app means, as `team_library_owner` gave it, and is refused with
// `sync.team_library.other_owner` on another one's engine.
#[uniffi::export]
impl SyncService {
    // The owner this service's TablePro Sync sign-in binds Team Library to, for the app to pass back to each call; None
    // without one.
    pub fn team_library_owner(&self) -> Option<TeamLibraryOwnerArg> {
        let engine = self.service.now().ok()?;
        let owner = owner_of(engine.sync.identity())?;
        Some(TeamLibraryOwnerArg {
            api_origin: owner.origin,
            account_id: owner.account_id,
        })
    }

    // Names come from the profile in the background, so this never waits on the network; the listener says when
    // they changed.
    pub async fn team_library(
        &self,
        expected_owner: TeamLibraryOwnerArg,
    ) -> Result<Vec<TeamLibraryTeamInfo>, CoreError> {
        let account = self.account.as_ref().map(|service| service.account.clone());
        let tasks = self.tasks.clone();
        let (names, profiles) = (self.driver_names(), self.held_profiles());
        let teams = self
            .on_team_library(expected_owner, move |control| async move {
                let teams = control.team_library().await?;
                if let Some(account) = account {
                    drop(tasks.spawn_task(name_teams(control, account)));
                }
                Ok(teams)
            })
            .await?;
        Ok(teams
            .into_iter()
            .map(|team| team_info(team, names, &profiles))
            .collect())
    }

    // The connections `TeamLibraryPublishPlan.connections` names, as the library holds them; the core builds each one's
    // bundle and decides what goes up.
    pub async fn publish_team_connections(
        &self,
        expected_owner: TeamLibraryOwnerArg,
        team_id: String,
        connections: Vec<LibraryConnectionRecord>,
    ) -> Result<TeamPublishInfo, CoreError> {
        let team = team(&team_id)?;
        let (names, profiles) = (self.driver_names(), self.held_profiles());
        let connections = connections
            .into_iter()
            .map(|record| connection(record, names, &profiles))
            .collect::<Result<Vec<_>, _>>()?;
        let publish = self
            .on_team_library(expected_owner, move |control| async move {
                control.publish_team_connections(team, connections).await
            })
            .await?;
        Ok(publish_info(publish))
    }

    // Every saved query and folder this device holds: what it published before and no longer holds is removed.
    pub async fn publish_team_saved_queries(
        &self,
        expected_owner: TeamLibraryOwnerArg,
        team_id: String,
        folders: Vec<TeamFolderArg>,
        queries: Vec<TeamQueryArg>,
    ) -> Result<TeamPublishInfo, CoreError> {
        let team = team(&team_id)?;
        let folders = folders.into_iter().map(folder).collect::<Result<Vec<_>, _>>()?;
        let queries = queries.into_iter().map(query).collect::<Result<Vec<_>, _>>()?;
        let publish = self
            .on_team_library(expected_owner, move |control| async move {
                control.publish_team_saved_queries(team, folders, queries).await
            })
            .await?;
        Ok(publish_info(publish))
    }

    pub async fn remove_team_items(
        &self,
        expected_owner: TeamLibraryOwnerArg,
        team_id: String,
        items: Vec<TeamLibraryItemRef>,
    ) -> Result<TeamPublishInfo, CoreError> {
        let team = team(&team_id)?;
        let items = items.into_iter().map(item_ref).collect();
        let publish = self
            .on_team_library(expected_owner, move |control| async move {
                control.remove_team_items(team, items).await
            })
            .await?;
        Ok(publish_info(publish))
    }

    // What a sign-out or a switch lists before it asks push, discard or cancel.
    pub async fn unsent_team_edits(
        &self,
        expected_owner: TeamLibraryOwnerArg,
    ) -> Result<Vec<UnsentTeamEditInfo>, CoreError> {
        let edits = self
            .on_team_library(expected_owner, move |control| async move {
                control.unsent_team_edits().await
            })
            .await?;
        Ok(edits.into_iter().map(unsent_info).collect())
    }

    // None discards every team's, refused and imported edits included.
    pub async fn discard_team_edits(
        &self,
        expected_owner: TeamLibraryOwnerArg,
        team_id: Option<String>,
    ) -> Result<(), CoreError> {
        let team = team_id.as_deref().map(team).transpose()?;
        self.on_team_library(expected_owner, move |control| async move {
            control.discard_team_edits(team).await
        })
        .await
    }

    // Also after the sign-in ended, as Sign Out deletes once it has signed out. On failure Team Library stays off for
    // this account until a later delete succeeds.
    pub async fn delete_team_library_data(&self, expected_owner: TeamLibraryOwnerArg) -> Result<(), CoreError> {
        self.on_team_library(expected_owner, move |control| async move {
            control.delete_team_library_data().await
        })
        .await
    }

    pub async fn team_scope_status(
        &self,
        expected_owner: TeamLibraryOwnerArg,
    ) -> Result<Vec<TeamScopeStatusInfo>, CoreError> {
        let status = self
            .on_team_library(expected_owner, move |control| async move {
                control.team_scope_status().await
            })
            .await?;
        Ok(status.into_iter().map(status_info).collect())
    }

    // Once, with what the library 0.88 kept for this sign-in: kept on disk at once and pushed against the facade's
    // versions once each team is pulled, so an edit the team changed meanwhile asks Keep Mine or Keep Theirs.
    pub async fn import_team_library(
        &self,
        expected_owner: TeamLibraryOwnerArg,
        teams: Vec<TeamLibraryImportArg>,
    ) -> Result<(), CoreError> {
        let teams = teams.into_iter().map(import).collect::<Result<Vec<_>, _>>()?;
        self.on_team_library(expected_owner, move |control| async move {
            control.import_team_library(teams).await
        })
        .await
    }
}

#[uniffi::export]
impl Core {
    // Every owner's Team Library data on this device but `keep`'s, as a sign-in by someone else after an involuntary
    // sign-out needs. Each owner's store file goes now, verified; the team scopes of its state file go before that
    // owner's next sync service reads them, and until then Team Library stays off for it.
    pub async fn delete_other_team_library_data(&self, keep: Option<TeamLibraryOwnerArg>) -> Result<(), CoreError> {
        let keep = match keep {
            Some(owner) => {
                Some(team_library_owner(&owner.api_origin, &owner.account_id).ok_or_else(|| malformed("owner"))?)
            }
            None => None,
        };
        let paths = self
            .paths
            .clone()
            .ok_or_else(|| CoreError::failed("ffi.no_storage", "the core was started without a storage folder"))?;
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            tasks
                .spawn_blocking_task(move || {
                    tablepro_storage::delete_other_team_library_owners_blocking(&paths, keep.as_ref())
                })
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
                .map_err(|error| {
                    SyncError::from(TeamLibraryError::DeleteFailed {
                        detail: error.to_string(),
                    })
                    .into()
                })
        })
        .await
    }
}

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing here"
)]
mod tests {
    use serde_json::json;
    use tablepro_storage::TeamLibraryItem;

    use super::*;

    fn wire(n: u128) -> String {
        team_id(TeamId(Uuid::from_u128(n)))
    }

    // Names what it is asked to, into a list the test keeps past the control.
    struct Naming(Arc<std::sync::Mutex<Vec<(TeamId, String)>>>);

    #[async_trait::async_trait]
    impl TeamLibraryControl for Naming {
        async fn teams_to_name(&self) -> Result<Vec<TeamId>, SyncError> {
            Ok(vec![TeamId(Uuid::from_u128(5))])
        }

        async fn name_teams(&self, names: Vec<(TeamId, String)>) -> Result<(), SyncError> {
            self.0.lock().unwrap().extend(names);
            Ok(())
        }
    }

    fn acme() -> tablepro_account::Profile {
        tablepro_account::Profile {
            id: "acct_1".to_owned(),
            email: "owner@example.com".to_owned(),
            name: None,
            licenses: Vec::new(),
            teams: vec![tablepro_account::Membership {
                team: tablepro_account::TeamClaim {
                    id: wire(5),
                    name: "Acme".to_owned(),
                },
                role: "owner".to_owned(),
                has_seat: true,
            }],
        }
    }

    // A profile read that waits until the test lets it go, and says when it started.
    fn held_profile() -> (
        tokio::sync::oneshot::Receiver<()>,
        tokio::sync::oneshot::Sender<()>,
        impl Future<Output = Result<tablepro_account::Profile, tablepro_account::AccountError>>,
    ) {
        let (reached, reached_rx) = tokio::sync::oneshot::channel();
        let (go, go_rx) = tokio::sync::oneshot::channel::<()>();
        let read = async move {
            reached.send(()).unwrap();
            go_rx.await.unwrap();
            Ok(acme())
        };
        (reached_rx, go, read)
    }

    // A slow profile read never keeps the engine, and with it the state file, from closing.
    #[tokio::test]
    async fn the_profile_read_holds_no_engine_and_names_the_teams_once_back() {
        let named = Arc::default();
        let control = Arc::new(Naming(Arc::clone(&named)));
        let (reached, go, read) = held_profile();
        let naming = crate::runtime::tasks().unwrap().spawn_task(name_teams_from(
            Arc::clone(&control) as Arc<dyn TeamLibraryControl>,
            read,
        ));

        reached.await.unwrap();
        let held_during_the_read = Arc::strong_count(&control);
        go.send(()).unwrap();
        naming.await.unwrap();

        assert_eq!(held_during_the_read, 1);
        assert_eq!(
            *named.lock().unwrap(),
            vec![(TeamId(Uuid::from_u128(5)), "Acme".to_owned())]
        );
    }

    #[tokio::test]
    async fn a_service_closed_during_the_profile_read_keeps_no_names() {
        let named = Arc::default();
        let control = Arc::new(Naming(Arc::clone(&named)));
        let (reached, go, read) = held_profile();
        let naming = crate::runtime::tasks()
            .unwrap()
            .spawn_task(name_teams_from(control as Arc<dyn TeamLibraryControl>, read));

        reached.await.unwrap();
        go.send(()).unwrap();
        naming.await.unwrap();

        assert!(named.lock().unwrap().is_empty());
    }

    #[test]
    fn a_team_is_its_scope_name_and_anything_else_is_refused() {
        let id = wire(0x0191_0000_0000_7000_8000_0000_0000_00AA);

        assert_eq!(
            team(&id).unwrap(),
            TeamId(Uuid::from_u128(0x0191_0000_0000_7000_8000_0000_0000_00AA))
        );
        for bad in ["personal", "history", "team_x", ""] {
            assert_eq!(team(bad).unwrap_err().code(), "sync.team_library.malformed");
        }
    }

    #[test]
    fn a_saved_query_takes_ids_in_either_case_and_an_empty_reference_names_nothing() {
        let id = Uuid::from_u128(7);
        let parsed = query(TeamQueryArg {
            id: id.hyphenated().to_string().to_uppercase(),
            name: "Revenue".to_owned(),
            query: "select 1".to_owned(),
            keyword: None,
            folder_id: Some(String::new()),
            connection_id: Some(Uuid::from_u128(8).to_string()),
            sort_order: 3,
        })
        .unwrap();

        assert_eq!(parsed.id, id);
        assert_eq!(parsed.folder, None);
        assert_eq!(parsed.connection, Some(Uuid::from_u128(8)));
    }

    fn record(id: &str) -> LibraryConnectionRecord {
        let saved = team_connection(
            Uuid::from_u128(1),
            &json!({"name": "Shop", "host": "db", "port": 5432, "database": "shop", "username": "app",
                "type": "PostgreSQL"}),
            DriverNames::Mac,
            |_| false,
        );
        let mut record = LibraryConnectionRecord::from(&saved);
        id.clone_into(&mut record.connection.id);
        record
    }

    // A published connection goes as the bundle the Mac writes, and one whose id is not a UUID is refused.
    #[test]
    fn a_published_connection_goes_as_the_mac_s_bundle_and_a_bad_id_is_refused() {
        let id = Uuid::from_u128(1).hyphenated().to_string().to_uppercase();

        let published = connection(record(&id), DriverNames::Mac, &[]).unwrap();
        let refused = connection(record("not a uuid"), DriverNames::Mac, &[]);

        assert_eq!(published.id, Uuid::from_u128(1));
        assert_eq!(
            published.settings,
            json!({"name": "Shop", "host": "db", "port": 5432, "database": "shop", "username": "app",
                "type": "PostgreSQL"})
        );
        assert_eq!(refused.unwrap_err().code(), "sync.team_library.malformed");
    }

    // A team's connection reads as a library connection; a folder or a query carries none.
    #[test]
    fn a_connection_item_reads_as_a_library_connection_and_a_query_as_none() {
        let fields = json!({"name": "Shop", "host": "db", "port": 5432, "database": "shop", "username": "app",
            "type": "PostgreSQL"});
        let item = |kind, id: &str| TeamItem {
            item: TeamLibraryItem {
                kind,
                id: id.to_owned(),
                fields: fields.clone(),
            },
            updated_by: None,
            updated_at_ms: None,
        };
        let id = Uuid::from_u128(1).hyphenated().to_string().to_uppercase();

        let connection = item_info(item(TeamLibraryKind::Connection, &id), DriverNames::Mac, &[]);
        let query = item_info(item(TeamLibraryKind::Query, "Q1"), DriverNames::Mac, &[]);

        let record = connection.connection.expect("a connection");
        assert_eq!(record.connection.name, "Shop");
        assert_eq!(record.connection.port, 5432);
        assert!(query.connection.is_none());
    }

    // A copy whose tunnel names an option where a host goes reads as no connection, as the Mac refuses one.
    #[test]
    fn a_copy_whose_tunnel_host_is_an_option_reads_as_no_connection() {
        let fields = json!({"name": "Shop", "host": "db", "port": 5432, "database": "shop", "username": "app",
            "type": "PostgreSQL", "sshConfig": {"enabled": true, "host": "-oProxyCommand=touch /tmp/x",
            "username": "ops", "authMethod": "SSH Agent", "privateKeyPath": "", "agentSocketPath": ""}});
        let item = TeamItem {
            item: TeamLibraryItem {
                kind: TeamLibraryKind::Connection,
                id: Uuid::from_u128(1).hyphenated().to_string(),
                fields,
            },
            updated_by: None,
            updated_at_ms: None,
        };

        assert!(item_info(item, DriverNames::Mac, &[]).connection.is_none());
    }

    fn signed_in(account: u128) -> StateIdentity {
        StateIdentity::Service {
            origin: Origin::parse("https://api.tablepro.app").unwrap(),
            sign_in: "sign-in".to_owned(),
            account: AccountId(Uuid::from_u128(account)),
            device_row: tablepro_sync::api::ids::DeviceRowId("dev_1".to_owned()),
        }
    }

    // The owner a call names must be the engine's, in either spelling of the account; another account's is refused.
    #[test]
    fn a_call_for_another_owner_is_refused_and_either_spelling_of_this_one_passes() {
        let identity = signed_in(9);
        let owner = owner_of(&identity).unwrap();
        let by_typeid = TeamLibraryOwnerArg {
            api_origin: "https://api.tablepro.app/".to_owned(),
            account_id: format!("acct_{}", wire(9).trim_start_matches("team_")),
        };
        let by_uuid = TeamLibraryOwnerArg {
            api_origin: "https://api.tablepro.app".to_owned(),
            account_id: Uuid::from_u128(9).to_string(),
        };
        let other = TeamLibraryOwnerArg {
            api_origin: "https://api.tablepro.app".to_owned(),
            account_id: Uuid::from_u128(10).to_string(),
        };

        assert_eq!(
            Some(owner),
            team_library_owner("https://api.tablepro.app", &Uuid::from_u128(9).to_string())
        );
        assert!(check_owner(&by_typeid, &identity).is_ok());
        assert!(check_owner(&by_uuid, &identity).is_ok());
        assert_eq!(
            check_owner(&other, &identity).unwrap_err().code(),
            "sync.team_library.other_owner"
        );
        assert_eq!(
            check_owner(&other, &signed_in(10)).map_err(|error| error.code().to_owned()),
            Ok(())
        );
    }

    #[test]
    fn an_import_keeps_each_edit_s_facade_base_and_a_base_without_a_version_is_refused() {
        let item = TeamLibraryItemRef {
            kind: TeamLibraryKindTag::Query,
            id: "Q1".to_owned(),
        };
        let edit = |base_version, base_fields_json: Option<&str>| TeamImportedEditArg {
            item: item.clone(),
            base_version,
            base_fields_json: base_fields_json.map(str::to_owned),
            fields_json: None,
            moved: false,
        };
        let arg = TeamLibraryImportArg {
            team_id: wire(5),
            edits: vec![edit(Some(4), Some(r#"{"name":"Q"}"#))],
            published: vec![item.clone()],
            declined: Vec::new(),
        };

        let imported = import(arg).unwrap();

        assert_eq!(
            imported.edits[0].base,
            Some(FacadeBase {
                version: 4,
                fields: Some(json!({"name": "Q"})),
            })
        );
        assert_eq!(imported.edits[0].fields, None);
        assert_eq!(imported.published[0].id, "Q1");
        assert!(imported_edit(edit(None, Some("{}"))).is_err());
    }

    #[test]
    fn a_team_crosses_the_boundary_with_its_role_and_items_as_json_text() {
        let info = team_info(
            TeamLibraryTeam {
                team: TeamId(Uuid::from_u128(5)),
                name: Some("Acme".to_owned()),
                role: Some(Role::Editor),
                writable: true,
                items: vec![TeamItem {
                    item: TeamLibraryItem {
                        kind: TeamLibraryKind::Folder,
                        id: "F1".to_owned(),
                        fields: json!({"name": "Shared"}),
                    },
                    updated_by: Some("Ada".to_owned()),
                    updated_at_ms: Some(1_700_000_000_000),
                }],
            },
            DriverNames::Mac,
            &[],
        );

        assert_eq!(info.team_id, wire(5));
        assert_eq!(info.role, Some(TeamRoleTag::Editor));
        assert_eq!(info.items[0].kind, TeamLibraryKindTag::Folder);
        assert_eq!(info.items[0].updated_by.as_deref(), Some("Ada"));
        assert_eq!(info.items[0].updated_at_ms, Some(1_700_000_000_000));
        assert_eq!(
            serde_json::from_str::<Value>(&info.items[0].fields_json).unwrap(),
            json!({"name": "Shared"})
        );
    }

    #[test]
    fn an_owner_is_spelled_one_way_whether_the_account_names_it_by_uuid_or_typeid() {
        let uuid = Uuid::from_u128(0x0193_a1b2_c3d4_7e5f_8a9b_0c1d_2e3f_4a5b);
        let typeid = format!("acct_{}", wire(uuid.as_u128()).trim_start_matches("team_"));

        let by_uuid = team_library_owner("https://api.tablepro.app/v2", &uuid.to_string()).unwrap();
        let by_typeid = team_library_owner("https://api.tablepro.app:443", &typeid).unwrap();

        assert_eq!(by_uuid, by_typeid);
        assert_eq!(by_uuid.origin, "https://api.tablepro.app");
        assert_eq!(by_uuid.account_id, AccountId(uuid).to_wire());
        assert!(team_library_owner("not a url", &typeid).is_none());
        assert!(team_library_owner("https://api.tablepro.app", "team_x").is_none());
    }
}
