use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Utc};
use secrecy::SecretString;
use serde_json::Value;
use tablepro_core::credentials::{SecretKind, SecretLookup, SecretVault};
use tablepro_core::{
    AiPolicy, AuthMode, ClientIdentity, ConfigError, DriverError, ExternalAccess, NetworkOptions, SafeModeLevel,
    TlsConfig, TlsMode,
};
use tablepro_session::runtime::Tasks;
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionIcon, ConnectionList, ConnectionProject,
    ConnectionProjectName, ConnectionStore, ConnectionTag, ConnectionTagName, LibraryIcon, ProjectMembership,
    RemoteFileAccess, SavedConnection, SavedSshAuth, SavedSshConfig, SshJumpAuth, SshJumpHost, SshRemoteFile, SshTotp,
    SshTotpAlgorithm, SshTotpMode, StorageError, SymbolName, english_secret_label, shown_name,
};
use uuid::Uuid;

use crate::error::CoreError;
use crate::export::write_whole_file;
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TlsModeTag {
    Disable,
    Prefer,
    Require,
    // Stored for a library that holds it; no engine connects with it yet.
    VerifyCa,
    VerifyFull,
    Strict,
}

impl From<TlsMode> for TlsModeTag {
    fn from(mode: TlsMode) -> Self {
        match mode {
            TlsMode::Disable => Self::Disable,
            TlsMode::Prefer => Self::Prefer,
            TlsMode::Require => Self::Require,
            TlsMode::VerifyCa => Self::VerifyCa,
            TlsMode::VerifyFull => Self::VerifyFull,
            TlsMode::Strict => Self::Strict,
        }
    }
}

impl From<TlsModeTag> for TlsMode {
    fn from(tag: TlsModeTag) -> Self {
        match tag {
            TlsModeTag::Disable => Self::Disable,
            TlsModeTag::Prefer => Self::Prefer,
            TlsModeTag::Require => Self::Require,
            TlsModeTag::VerifyCa => Self::VerifyCa,
            TlsModeTag::VerifyFull => Self::VerifyFull,
            TlsModeTag::Strict => Self::Strict,
        }
    }
}

// The macOS levels, weakest first; an app that offers fewer shows the one `safe_mode_enforced` gives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SafeModeTag {
    Silent,
    Alert,
    AlertFull,
    SafeMode,
    SafeModeFull,
    ReadOnly,
}

impl From<SafeModeTag> for SafeModeLevel {
    fn from(tag: SafeModeTag) -> Self {
        match tag {
            SafeModeTag::Silent => Self::Silent,
            SafeModeTag::Alert => Self::Alert,
            SafeModeTag::AlertFull => Self::AlertFull,
            SafeModeTag::SafeMode => Self::SafeMode,
            SafeModeTag::SafeModeFull => Self::SafeModeFull,
            SafeModeTag::ReadOnly => Self::ReadOnly,
        }
    }
}

impl From<SafeModeLevel> for SafeModeTag {
    fn from(level: SafeModeLevel) -> Self {
        match level {
            SafeModeLevel::Silent => Self::Silent,
            SafeModeLevel::Alert => Self::Alert,
            SafeModeLevel::AlertFull => Self::AlertFull,
            SafeModeLevel::SafeMode => Self::SafeMode,
            SafeModeLevel::SafeModeFull => Self::SafeModeFull,
            SafeModeLevel::ReadOnly => Self::ReadOnly,
        }
    }
}

// The level a session runs for one stored: rounded up, never down, to Silent, Alert or Read-Only.
#[uniffi::export]
pub fn safe_mode_enforced(level: SafeModeTag) -> SafeModeTag {
    SafeModeLevel::from(level).enforced().into()
}

// What the AI assistant may send from the connection (core AiPolicy).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiPolicyTag {
    Ask,
    Allow,
    Never,
    // The app's own default decides; an app without one asks.
    AppDefault,
}

impl From<AiPolicyTag> for AiPolicy {
    fn from(tag: AiPolicyTag) -> Self {
        match tag {
            AiPolicyTag::Ask => Self::Ask,
            AiPolicyTag::Allow => Self::Allow,
            AiPolicyTag::Never => Self::Never,
            AiPolicyTag::AppDefault => Self::AppDefault,
        }
    }
}

impl From<AiPolicy> for AiPolicyTag {
    fn from(policy: AiPolicy) -> Self {
        match policy {
            AiPolicy::Ask => Self::Ask,
            AiPolicy::Allow => Self::Allow,
            AiPolicy::Never => Self::Never,
            AiPolicy::AppDefault => Self::AppDefault,
        }
    }
}

// What MCP clients and the tablepro command may do with the connection (core ExternalAccess).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExternalAccessTag {
    Blocked,
    ReadOnly,
    ReadWrite,
}

impl From<ExternalAccessTag> for ExternalAccess {
    fn from(tag: ExternalAccessTag) -> Self {
        match tag {
            ExternalAccessTag::Blocked => Self::Blocked,
            ExternalAccessTag::ReadOnly => Self::ReadOnly,
            ExternalAccessTag::ReadWrite => Self::ReadWrite,
        }
    }
}

impl From<ExternalAccess> for ExternalAccessTag {
    fn from(access: ExternalAccess) -> Self {
        match access {
            ExternalAccess::Blocked => Self::Blocked,
            ExternalAccess::ReadOnly => Self::ReadOnly,
            ExternalAccess::ReadWrite => Self::ReadWrite,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TlsSettings {
    pub mode: TlsModeTag,
    pub ca_file: Option<String>,
    pub client_certificate: Option<String>,
    pub client_key: Option<String>,
    pub server_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SshAuthTag {
    Agent,
    PrivateKey { path: Option<String>, has_passphrase: bool },
    Password,
    KeyboardInteractive,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshSettings {
    pub host: String,
    pub port: Option<u16>,
    pub username: Option<String>,
    pub jump_hosts: Vec<SshJumpHostRecord>,
    pub auth: SshAuthTag,
    // Always set on a record read back. Off keeps the settings. A save that leaves it out turns the tunnel on.
    #[uniffi(default = None)]
    pub enabled: Option<bool>,
    // Always set on a record read back; a save that leaves it out keeps the stored ones.
    #[uniffi(default = None)]
    pub options: Option<SshOptionsRecord>,
}

// A hop typed as text has no id, auth or key; a save keeps those of a stored hop that goes to the same place.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshJumpHostRecord {
    pub id: Option<String>,
    pub host: String,
    pub port: Option<u16>,
    pub username: Option<String>,
    // None tries what OpenSSH's own configuration says.
    pub auth: Option<SshJumpAuthTag>,
    pub key_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SshJumpAuthTag {
    Agent,
    PrivateKey,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshOptionsRecord {
    // A key file kept while auth is not a key; a key auth carries its own path.
    pub kept_key_path: Option<String>,
    // None is the agent SSH_AUTH_SOCK names.
    pub agent_socket: Option<String>,
    pub totp: SshTotpRecord,
    // A database file on the SSH host, as typed; None forwards a port.
    pub remote_file_path: Option<String>,
    pub remote_file_access: RemoteFileAccessTag,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SshTotpRecord {
    pub mode: SshTotpModeTag,
    pub algorithm: SshTotpAlgorithmTag,
    pub digits: u32,
    pub period: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SshTotpModeTag {
    Off,
    AutoGenerate,
    PromptAtConnect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SshTotpAlgorithmTag {
    Sha1,
    Sha256,
    Sha512,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteFileAccessTag {
    ReadOnlyCopy,
    OnServer,
}

// The icon a group or a connection shows in place of its default one. Only the Apple apps draw a symbol.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LibraryIconRecord {
    // One of the ids ConnectionIcon names.
    Named { id: String },
    // An SF Symbol name.
    Symbol { name: String },
}

// A saved connection as the form edits it. Fields the form does not show keep their stored values on save.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConnectionRecord {
    // Empty for a connection not saved yet.
    pub id: String,
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    // The database name, or for a file engine the file's path.
    pub database: String,
    pub username: String,
    pub integrated_auth: bool,
    pub tls: TlsSettings,
    pub ssh: Option<SshSettings>,
    pub safe_mode: SafeModeTag,
    pub query_timeout_secs: Option<u32>,
    pub color: Option<String>,
    pub group_id: Option<String>,
    pub last_opened_ms: Option<i64>,
    // A save keeps the stored tags, which change through tag_connections; a library write stores these.
    pub tags: Vec<String>,
    // Always set on a record read back; None on a save keeps the stored policy, Ask for a new connection.
    #[uniffi(default = None)]
    pub ai_policy: Option<AiPolicyTag>,
    // Always set on a record read back; None on a save keeps the stored level, Read Only for a new connection.
    #[uniffi(default = None)]
    pub external_access: Option<ExternalAccessTag>,
    // Read back, the project it shows in: its top-level group's when grouped. On a save it places a connection
    // with no group, and None keeps the stored one.
    #[uniffi(default = None)]
    pub project_id: Option<String>,
    // None on a save keeps the stored icon.
    #[uniffi(default = None)]
    pub icon: Option<LibraryIconRecord>,
    // The place among its group's connections. A save keeps the stored place; a library write stores this one.
    #[uniffi(default = 0)]
    pub order: u32,
}

// Each secret as the form holds it: None keeps what is stored, an empty string is stored as one.
#[derive(Clone, Default, uniffi::Record)]
pub struct ConnectionSecrets {
    pub database_password: Option<SecretString>,
    pub ssh_password: Option<SecretString>,
    pub ssh_passphrase: Option<SecretString>,
}

impl ConnectionSecrets {
    pub(crate) fn into_typed(self) -> Vec<(SecretKind, SecretString)> {
        [
            (SecretKind::DatabasePassword, self.database_password),
            (SecretKind::SshPassword, self.ssh_password),
            (SecretKind::SshPassphrase, self.ssh_passphrase),
        ]
        .into_iter()
        .filter_map(|(kind, secret)| secret.map(|secret| (kind, secret)))
        .collect()
    }
}

impl std::fmt::Debug for ConnectionSecrets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionSecrets")
            .field("database_password", &self.database_password.as_ref().map(|_| Redacted))
            .field("ssh_password", &self.ssh_password.as_ref().map(|_| Redacted))
            .field("ssh_passphrase", &self.ssh_passphrase.as_ref().map(|_| Redacted))
            .finish()
    }
}

// Stands in for a secret in Debug output, so a log line or a panic message never carries one.
pub(crate) struct Redacted;

impl std::fmt::Debug for Redacted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("[REDACTED]")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupRecord {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub order: u32,
    pub color: Option<String>,
    // The project it shows in, which its top-level group names.
    pub project_id: Option<String>,
    #[uniffi(default = None)]
    pub icon: Option<LibraryIconRecord>,
}

// All connections is no project and has no record (core ADR 0067).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProjectRecord {
    pub id: String,
    pub name: String,
    pub order: u32,
    pub color: Option<String>,
    #[uniffi(default = None)]
    pub icon: Option<LibraryIconRecord>,
}

// A label several connections share; they name it by id, so a rename or a new colour reaches all of them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagRecord {
    pub id: String,
    pub name: String,
    // None for a tag with no colour.
    pub color: Option<String>,
    // One of the tags macOS starts every library with.
    #[uniffi(default = false)]
    pub is_preset: bool,
}

// Every list is in the library's own order: connections and groups by position, tags as they were made.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibrarySnapshot {
    pub connections: Vec<ConnectionRecord>,
    pub groups: Vec<GroupRecord>,
    pub favorites: Vec<String>,
    pub recent: Vec<String>,
    pub tags: Vec<TagRecord>,
    // Every project in its order, whatever the scope.
    pub projects: Vec<ProjectRecord>,
    // The project the lists are narrowed to; None for all connections, also when the id asked for names no project.
    pub scope: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportSummary {
    pub added: u32,
    pub updated: u32,
    // The saved connections the file wrote, added or updated, once each in file order (core 0057).
    pub connection_ids: Vec<String>,
}

const RECENT_LIMIT: usize = 8;

// A kind as the vault held it before a save, None for no value or one that could not be read.
type HeldValue = (SecretKind, Option<SecretString>);

// Held by every write that can change or drop a connection, and by a connect keeping the secret it logged in with.
pub(crate) type LibraryWrites = Arc<tokio::sync::Mutex<()>>;

// An edit, a delete or a secret saved since the connect read the record wins: what it typed may unlock nothing now.
pub(crate) async fn keep_proved_secrets(
    store: &ConnectionStore,
    vault: &Arc<dyn SecretVault>,
    writes: &LibraryWrites,
    tasks: &Tasks,
    proved: &SavedConnection,
    typed: Vec<(SecretKind, SecretString)>,
) {
    if typed.is_empty() {
        return;
    }
    let _held = writes.lock().await;
    let reader = store.clone();
    let id = proved.id;
    let current = match tasks.spawn_blocking_task(move || reader.list_blocking()).await {
        Ok(Ok(list)) => list.connections.iter().find(|saved| saved.id == id).cloned(),
        Ok(Err(error)) => {
            tracing::warn!(%error, "could not read the connection to keep the secret its connect logged in with");
            return;
        }
        Err(failure) => {
            tracing::warn!(%failure, "could not read the connection to keep the secret its connect logged in with");
            return;
        }
    };
    let Some(current) = current.filter(|current| current.connects_like(proved)) else {
        return;
    };
    for (kind, secret) in typed {
        // The connect asked for it because none was stored, so one stored now came from a save since.
        if !matches!(vault.load(id, kind).await, Ok(SecretLookup::NotStored)) {
            continue;
        }
        let target = current.secret_target(kind);
        if let Err(error) = vault
            .store(id, kind, &secret, &english_secret_label(kind, &target))
            .await
        {
            tracing::warn!(%error, "could not keep the secret a connect logged in with");
        }
    }
}

#[derive(uniffi::Object)]
pub struct ConnectionLibrary {
    store: ConnectionStore,
    secrets: Arc<dyn SecretVault>,
    tasks: Tasks,
    writes: LibraryWrites,
}

impl ConnectionLibrary {
    pub(crate) fn new(
        store: ConnectionStore,
        secrets: Arc<dyn SecretVault>,
        tasks: Tasks,
        writes: LibraryWrites,
    ) -> Self {
        Self {
            store,
            secrets,
            tasks,
            writes,
        }
    }

    pub(crate) async fn hold_writes(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.writes.lock().await
    }

    pub(crate) async fn delete_secrets(&self, ids: Vec<Uuid>) -> Result<(), CoreError> {
        let vault = self.secrets.clone();
        on_runtime(&self.tasks, async move {
            for id in ids {
                vault.delete_connection(id).await.map_err(secret_error)?;
            }
            Ok(())
        })
        .await
    }

    // A secret the store cannot read stops the copy, which would otherwise fail to connect for no reason it shows.
    async fn copy_secrets(&self, source: &SavedConnection, copy: &SavedConnection) -> Result<(), CoreError> {
        let vault = self.secrets.clone();
        let (from, to) = (source.id, copy.clone());
        on_runtime(&self.tasks, async move {
            for kind in SecretKind::ALL {
                if let SecretLookup::Found(secret) = vault.load(from, kind).await.map_err(secret_error)? {
                    let label = english_secret_label(kind, &to.secret_target(kind));
                    vault.store(to.id, kind, &secret, &label).await.map_err(secret_error)?;
                }
            }
            Ok(())
        })
        .await
    }

    async fn forget_secrets(&self, id: Uuid) {
        if let Err(error) = self.delete_secrets(vec![id]).await {
            tracing::warn!(
                code = error.code(),
                "the secrets of a copy that was not saved are still in the store"
            );
        }
    }

    // A value that cannot be read counts as none, so putting it back removes the new one rather than keep it.
    async fn held_values(&self, id: Uuid, kinds: Vec<SecretKind>) -> Result<Vec<HeldValue>, CoreError> {
        let vault = self.secrets.clone();
        on_runtime(&self.tasks, async move {
            let mut held = Vec::new();
            for kind in kinds {
                held.push((kind, vault.load(id, kind).await.ok().and_then(SecretLookup::found)));
            }
            Ok(held)
        })
        .await
    }

    // Stops at the first refusal. The kinds tried end with the refused one, which a failed call may still have written.
    async fn store_secrets(
        &self,
        saved: &SavedConnection,
        typed: Vec<(SecretKind, SecretString)>,
    ) -> Result<Option<(CoreError, Vec<SecretKind>)>, CoreError> {
        let vault = self.secrets.clone();
        let stored = saved.clone();
        on_runtime(&self.tasks, async move {
            let mut tried = Vec::new();
            for (kind, secret) in typed {
                tried.push(kind);
                let label = english_secret_label(kind, &stored.secret_target(kind));
                if let Err(error) = vault.store(stored.id, kind, &secret, &label).await {
                    return Ok(Some((secret_error(error), tried)));
                }
            }
            Ok(None)
        })
        .await
    }

    // So a second Save does not add the connection twice; it stays only to name a secret known to be held.
    async fn take_back(&self, id: Uuid, wrote_one: bool) {
        if let Err(error) = self.delete_secrets(vec![id]).await {
            tracing::warn!(
                code = error.code(),
                "could not remove the secrets of a new connection whose save was refused"
            );
            if wrote_one {
                return;
            }
        }
        if let Err(error) = self.blocking(move |store| Ok(store.remove_blocking(id)?)).await {
            tracing::warn!(
                code = error.code(),
                "could not remove a new connection whose secrets were refused"
            );
        }
    }

    // Secrets are filed by id alone, so an edit left half done would send one host's password to another.
    async fn put_back(&self, before: SavedConnection, previous: Vec<HeldValue>, tried: Vec<SecretKind>) {
        let vault = self.secrets.clone();
        let entry = before.clone();
        let restored = on_runtime(&self.tasks, async move {
            for (kind, value) in previous.into_iter().filter(|(kind, _)| tried.contains(kind)) {
                let put = match value {
                    Some(value) => {
                        let label = english_secret_label(kind, &entry.secret_target(kind));
                        vault.store(entry.id, kind, &value, &label).await
                    }
                    None => vault.delete_kind(entry.id, kind).await,
                };
                if let Err(error) = put {
                    tracing::warn!(
                        code = error.code(),
                        "could not put back a secret of a connection whose edit was refused"
                    );
                }
            }
            Ok(())
        })
        .await;
        if let Err(error) = restored {
            tracing::warn!(
                code = error.code(),
                "could not put back the secrets of a connection whose edit was refused"
            );
        }
        let id = before.id;
        if let Err(error) = self
            .blocking(move |store| Ok(store.update_blocking(id, |saved| *saved = before)?))
            .await
        {
            tracing::warn!(
                code = error.code(),
                "could not put back a connection whose edit was refused"
            );
        }
    }

    // A read that fails now still gives the record, with the project it stores.
    async fn shown(&self, saved: SavedConnection) -> ConnectionRecord {
        let entry = saved.clone();
        match self.blocking(move |store| Ok(shown_project(store, &entry))).await {
            Ok(project) => ConnectionRecord::shown(&saved, project),
            Err(_) => ConnectionRecord::from(&saved),
        }
    }

    pub(crate) async fn blocking<T, F>(&self, work: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: FnOnce(&ConnectionStore) -> Result<T, CoreError> + Send + 'static,
    {
        let store = self.store.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            tasks
                .spawn_blocking_task(move || work(&store))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
        })
        .await
    }
}

#[uniffi::export]
impl ConnectionLibrary {
    // The whole library, which a reader by id uses whatever project the app shows.
    pub async fn snapshot(&self) -> Result<LibrarySnapshot, CoreError> {
        self.blocking(|store| Ok(snapshot_of(&store.list_blocking()?, None)))
            .await
    }

    // What one project shows: its connections, groups, favourites and its own recent ones. None, and an id no
    // project holds, give the whole library.
    pub async fn snapshot_in(&self, project_id: Option<String>) -> Result<LibrarySnapshot, CoreError> {
        let project = optional_id(project_id.as_deref())?;
        self.blocking(move |store| Ok(snapshot_of(&store.list_blocking()?, project)))
            .await
    }

    // Creates the connection when its id is empty or unknown, and stores the secrets the form holds.
    pub async fn save(
        &self,
        record: ConnectionRecord,
        secrets: ConnectionSecrets,
    ) -> Result<ConnectionRecord, CoreError> {
        let name = shown_name(&record.name);
        if name.is_empty() {
            return Err(CoreError::failed("library.name_required", "a connection needs a name"));
        }
        let group_id = optional_id(record.group_id.as_deref())?;
        let project_id = optional_id(record.project_id.as_deref())?;
        let id = match record.id.trim() {
            "" => None,
            id => Some(parse_id(id)?),
        };
        let tls = tls_config(&record.tls)?;
        let icon = record.icon.as_ref().map(library_icon).transpose()?;
        let typed = secrets.into_typed();
        let kinds = typed.iter().map(|(kind, _)| *kind).collect();
        let _held = self.hold_writes().await;
        // Read before anything is written, for a refused secret to put back.
        let previous = match id {
            Some(id) => self.held_values(id, kinds).await?,
            None => Vec::new(),
        };
        let (saved, before, shown) = self
            .blocking(move |store| {
                // A snapshot files a connection whose group has not arrived at the top; saving that keeps its group.
                let list = store.list_blocking()?;
                let group_id = match id.and_then(|id| list.connections.iter().find(|saved| saved.id == id)) {
                    Some(stored) if list.group_of(stored) == group_id => stored.group_id,
                    _ => group_id,
                };
                if let Some(id) = id {
                    let mut before = None;
                    let updated = store.update_blocking(id, |saved| {
                        before = Some(saved.clone());
                        apply(&record, &tls, icon.clone(), name.clone(), group_id, saved);
                        if project_id.is_some() {
                            saved.project_id = project_id;
                        }
                    })?;
                    if let Some(updated) = updated {
                        let shown = shown_project(store, &updated);
                        return Ok((updated, before, shown));
                    }
                }
                // An entry this build cannot read keeps its id, and with it the secrets filed under it.
                let unreadable = store.list_blocking()?.unreadable;
                let fresh = id.filter(|id| !unreadable.contains(id));
                let mut created = blank(fresh.unwrap_or_else(Uuid::new_v4));
                apply(&record, &tls, icon, name, group_id, &mut created);
                created.project_id = project_id;
                store.upsert_blocking(created.clone())?;
                let listed = store
                    .list_blocking()?
                    .connections
                    .iter()
                    .find(|saved| saved.id == created.id)
                    .cloned()
                    .unwrap_or(created);
                let shown = shown_project(store, &listed);
                Ok((listed, None, shown))
            })
            .await?;
        if let Some((error, tried)) = self.store_secrets(&saved, typed).await? {
            match before {
                Some(before) => self.put_back(before, previous, tried).await,
                // Every kind before the refused one went in.
                None => self.take_back(saved.id, tried.len() > 1).await,
            }
            return Err(error);
        }
        Ok(ConnectionRecord::shown(&saved, shown))
    }

    // Secrets go first, so a refused store leaves the connection listed to delete again, never a secret no entry names.
    pub async fn delete(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let _held = self.hold_writes().await;
        self.delete_secrets(vec![id]).await?;
        self.blocking(move |store| {
            store.remove_blocking(id)?;
            Ok(())
        })
        .await
    }

    pub async fn set_favorite(&self, id: String, favorite: bool) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| {
            if favorite {
                store.add_favorites_blocking(&[id], None)?;
            } else {
                store.remove_favorites_blocking(&[id])?;
            }
            Ok(())
        })
        .await
    }

    // Favourites already listed move, which is how a drag reorders them; the end when before is none.
    pub async fn add_favorites(&self, ids: Vec<String>, before: Option<String>) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let before = optional_id(before.as_deref())?;
        self.blocking(move |store| Ok(store.add_favorites_blocking(&ids, before)?))
            .await
    }

    pub async fn remove_favorites(&self, ids: Vec<String>) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        self.blocking(move |store| Ok(store.remove_favorites_blocking(&ids)?))
            .await
    }

    pub async fn rename_connection(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let name = shown_name(&name);
        if name.is_empty() {
            return Err(CoreError::failed("library.name_required", "a connection needs a name"));
        }
        self.blocking(
            move |store| match store.update_blocking(id, |saved| saved.name = name)? {
                Some(_) => Ok(()),
                None => Err(StorageError::ConnectionNotFound { id }.into()),
            },
        )
        .await
    }

    pub async fn create_tag(&self, name: String, color: String) -> Result<TagRecord, CoreError> {
        let name = tag_name(&name)?;
        let color = tag_color(&color)?;
        self.blocking(move |store| Ok(TagRecord::from(&store.create_tag_blocking(name, color)?)))
            .await
    }

    // None leaves the tag with no colour, as macOS can hold one.
    pub async fn update_tag(&self, id: String, name: String, color: Option<String>) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let name = tag_name(&name)?;
        let color = color.as_deref().map(tag_color).transpose()?;
        self.blocking(move |store| {
            let is_preset = store.tags_blocking()?.iter().any(|tag| tag.id == id && tag.is_preset);
            Ok(store.update_tag_blocking(ConnectionTag {
                id,
                name,
                color,
                is_preset,
            })?)
        })
        .await
    }

    // Takes the tag off every connection too.
    pub async fn delete_tag(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| {
            store.delete_tag_blocking(id)?;
            Ok(())
        })
        .await
    }

    pub async fn tag_connections(&self, ids: Vec<String>, tag_id: String, tagged: bool) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let tag = parse_id(&tag_id)?;
        self.blocking(move |store| {
            if !store.tags_blocking()?.iter().any(|known| known.id == tag) {
                return Err(CoreError::failed("library.tag_not_found", format!("no tag {tag}")));
            }
            for id in ids {
                let changed = store.update_blocking(id, |saved| {
                    saved.tags.retain(|held| *held != tag);
                    if tagged {
                        saved.tags.push(tag);
                    }
                })?;
                if changed.is_none() {
                    return Err(StorageError::ConnectionNotFound { id }.into());
                }
            }
            Ok(())
        })
        .await
    }

    // A top-level group is made in `project_id`; a subgroup follows its top-level group, whatever is passed.
    pub async fn create_group(
        &self,
        name: String,
        parent_id: Option<String>,
        project_id: Option<String>,
    ) -> Result<GroupRecord, CoreError> {
        let name = group_name(&name)?;
        let parent = optional_id(parent_id.as_deref())?;
        let project_id = optional_id(project_id.as_deref())?.filter(|_| parent.is_none());
        self.blocking(move |store| {
            let group = store.create_group_blocking(ConnectionGroup {
                project_id,
                ..ConnectionGroup::new(name, parent)
            })?;
            let membership = store.list_blocking()?.membership();
            Ok(GroupRecord::shown(&group, &membership))
        })
        .await
    }

    // Last in the list; a name another project holds in any case is refused with storage.project_name_taken.
    pub async fn create_project(&self, name: String, color: Option<String>) -> Result<ProjectRecord, CoreError> {
        let name = project_name(&name)?;
        let color = optional_color(color)?;
        self.blocking(move |store| {
            let project = ConnectionProject {
                color,
                ..ConnectionProject::new(name)
            };
            Ok(ProjectRecord::from(&store.create_project_blocking(project)?))
        })
        .await
    }

    pub async fn rename_project(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let name = project_name(&name)?;
        self.blocking(move |store| Ok(store.rename_project_blocking(id, name)?))
            .await
    }

    // None takes the colour off.
    pub async fn set_project_color(&self, id: String, color: Option<String>) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let color = optional_color(color)?;
        self.blocking(move |store| Ok(store.set_project_color_blocking(id, color)?))
            .await
    }

    // Its groups and connections stay, in no project.
    pub async fn delete_project(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| {
            store.delete_project_blocking(id)?;
            Ok(())
        })
        .await
    }

    // Before the project named, or at the end.
    pub async fn move_projects(&self, ids: Vec<String>, before: Option<String>) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let before = optional_id(before.as_deref())?;
        self.blocking(move |store| Ok(store.move_projects_blocking(&ids, before)?))
            .await
    }

    // Connections with no group, into the project or out of every one. A grouped one refuses the whole move with
    // storage.connection_grouped: its top-level group moves instead.
    pub async fn move_to_project(&self, ids: Vec<String>, project_id: Option<String>) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let project = optional_id(project_id.as_deref())?;
        self.blocking(move |store| Ok(store.move_connections_to_project_blocking(&ids, project)?))
            .await
    }

    // Top-level groups with everything in them; a subgroup refuses with storage.group_not_top_level.
    pub async fn move_groups_to_project(&self, ids: Vec<String>, project_id: Option<String>) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let project = optional_id(project_id.as_deref())?;
        self.blocking(move |store| Ok(store.move_groups_to_project_blocking(&ids, project)?))
            .await
    }

    pub async fn rename_group(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let name = group_name(&name)?;
        self.blocking(move |store| Ok(store.rename_group_blocking(id, name)?))
            .await
    }

    // None takes the colour off; the id is one ConnectionColor names, as a tag's is.
    pub async fn set_group_color(&self, id: String, color: Option<String>) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let color = optional_color(color)?;
        self.blocking(move |store| Ok(store.set_group_color_blocking(id, color)?))
            .await
    }

    pub async fn delete_group(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| {
            store.delete_group_blocking(id)?;
            Ok(())
        })
        .await
    }

    // Into the group or the top level, before the connection named or at the end.
    pub async fn move_to_group(
        &self,
        ids: Vec<String>,
        group_id: Option<String>,
        before: Option<String>,
    ) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let group = optional_id(group_id.as_deref())?;
        let before = optional_id(before.as_deref())?;
        self.blocking(move |store| Ok(store.move_connections_blocking(&ids, group, before)?))
            .await
    }

    // Under the parent or at the top level, before the group named or at the end; never inside itself.
    pub async fn move_groups(
        &self,
        ids: Vec<String>,
        parent_id: Option<String>,
        before: Option<String>,
    ) -> Result<(), CoreError> {
        let ids = parse_ids(&ids)?;
        let parent = optional_id(parent_id.as_deref())?;
        let before = optional_id(before.as_deref())?;
        self.blocking(move |store| Ok(store.move_groups_blocking(&ids, parent, before)?))
            .await
    }

    // A copy under a new id right after the original in its group, with every secret the original keeps, so either
    // connects alone. It has never been opened and is no favourite.
    pub async fn duplicate(&self, id: String, name: String) -> Result<ConnectionRecord, CoreError> {
        let id = parse_id(&id)?;
        let name = shown_name(&name);
        if name.is_empty() {
            return Err(CoreError::failed("library.name_required", "a connection needs a name"));
        }
        let _held = self.hold_writes().await;
        let source = self
            .blocking(move |store| {
                store
                    .list_blocking()?
                    .connections
                    .iter()
                    .find(|saved| saved.id == id)
                    .cloned()
                    .ok_or_else(|| StorageError::ConnectionNotFound { id }.into())
            })
            .await?;
        let copy = SavedConnection {
            id: Uuid::new_v4(),
            name,
            last_opened_at: None,
            ..source.clone()
        };
        if let Err(error) = self.copy_secrets(&source, &copy).await {
            self.forget_secrets(copy.id).await;
            return Err(error);
        }
        let entry = copy.clone();
        let written = self
            .blocking(move |store| {
                let id = entry.id;
                store.insert_after_blocking(entry, source.id)?;
                // The store gives the copy its place in the group; a read that fails now leaves the copy saved.
                Ok(store
                    .list_blocking()
                    .ok()
                    .and_then(|list| list.connections.iter().find(|saved| saved.id == id).cloned()))
            })
            .await;
        let error = match written {
            Ok(stored) => return Ok(self.shown(stored.unwrap_or(copy)).await),
            Err(error) => error,
        };
        // A write can fail after the file was replaced, as when the folder's sync fails; a listed copy keeps its secrets.
        let id = copy.id;
        let listed = self
            .blocking(move |store| Ok(store.list_blocking()?.connections.iter().any(|saved| saved.id == id)))
            .await;
        match listed {
            Ok(true) => Ok(self.shown(copy).await),
            Ok(false) => {
                self.forget_secrets(copy.id).await;
                Err(error)
            }
            Err(_) => Err(error),
        }
    }

    // The saved connections, groups, tags and projects as a TablePro connections file at `path`, which appears
    // only once whole: what `project_id` shows and that project alone, or everything for None. It carries no
    // passwords: those stay in the system's store. Gives how many connections it holds.
    pub async fn export_file(&self, path: String, project_id: Option<String>) -> Result<u32, CoreError> {
        let project = optional_id(project_id.as_deref())?;
        self.blocking(move |store| {
            let (bytes, count) = store.export_scoped_blocking(project)?;
            write_whole_file(&path, &bytes)?;
            Ok(u32::try_from(count).unwrap_or(u32::MAX))
        })
        .await
    }

    // Merges a TablePro connections file; it carries no passwords. A project the file names wins; a new entry it
    // files under none lands in `project_id`.
    pub async fn import_file(&self, path: String, project_id: Option<String>) -> Result<ImportSummary, CoreError> {
        let project = optional_id(project_id.as_deref())?;
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let path = PathBuf::from(path);
            let bytes = std::fs::read(&path).map_err(|error| {
                CoreError::failed("library.import_unreadable", format!("{}: {error}", path.display()))
            })?;
            let preview = store.preview_import_into_blocking(&path, &bytes, project)?;
            let report = store.apply_import_blocking(&preview)?;
            Ok(ImportSummary {
                added: u32::try_from(report.added).unwrap_or(u32::MAX),
                updated: u32::try_from(report.updated).unwrap_or(u32::MAX),
                connection_ids: report.connection_ids.iter().map(Uuid::to_string).collect(),
            })
        })
        .await
    }
}

impl std::fmt::Debug for ConnectionLibrary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionLibrary")
            .field("path", &self.store.path())
            .finish_non_exhaustive()
    }
}

impl From<StorageError> for CoreError {
    fn from(error: StorageError) -> Self {
        Self::failed(error.code(), error.to_string())
    }
}

pub(crate) fn secret_error(error: tablepro_core::credentials::SecretError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}

pub(crate) fn parse_id(id: &str) -> Result<Uuid, CoreError> {
    Uuid::parse_str(id.trim()).map_err(|_| CoreError::failed("library.invalid_id", format!("{id} is not an id")))
}

pub(crate) fn parse_ids(ids: &[String]) -> Result<Vec<Uuid>, CoreError> {
    ids.iter().map(|id| parse_id(id)).collect()
}

fn tag_name(name: &str) -> Result<ConnectionTagName, CoreError> {
    ConnectionTagName::new(name).map_err(|error| CoreError::failed(error.code(), error.to_string()))
}

pub(crate) fn tag_color(color: &str) -> Result<ConnectionColor, CoreError> {
    ConnectionColor::from_id(color.trim())
        .ok_or_else(|| CoreError::failed("library.unknown_color", format!("{color} is not a colour")))
}

fn optional_color(color: Option<String>) -> Result<Option<ConnectionColor>, CoreError> {
    color
        .filter(|color| !color.trim().is_empty())
        .map(|color| tag_color(&color))
        .transpose()
}

pub(crate) fn project_name(name: &str) -> Result<ConnectionProjectName, CoreError> {
    ConnectionProjectName::new(name).map_err(|error| CoreError::failed(error.code(), error.to_string()))
}

// A list that cannot be read leaves the project the entry stores.
fn shown_project(store: &ConnectionStore, saved: &SavedConnection) -> Option<Uuid> {
    match store.list_blocking() {
        Ok(list) => list.effective_project(saved),
        Err(_) => saved.project_id,
    }
}

// Membership is read from the whole list, so a record says its project in either scope.
fn snapshot_of(whole: &ConnectionList, project: Option<Uuid>) -> LibrarySnapshot {
    let membership = whole.membership();
    let scope = whole.resolved_scope(project);
    let list = whole.scoped(scope);
    let tree = list.group_tree();
    // As the tree files them: a parent or a group the list lacks reads as the top level.
    let mut groups = Vec::new();
    for group in tree.walk() {
        groups.push(GroupRecord {
            name: group.name.shown(),
            parent_id: tree.parent(group.id).map(|id| id.to_string()),
            ..GroupRecord::shown(group, &membership)
        });
    }
    // As the list shows them: names cleaned, and a group the list lacks read as the top.
    let known: std::collections::HashSet<Uuid> = list.groups.iter().map(|group| group.id).collect();
    let listed = |saved: &SavedConnection| ConnectionRecord {
        name: shown_name(&saved.name),
        group_id: saved.group_id.filter(|id| known.contains(id)).map(|id| id.to_string()),
        ..ConnectionRecord::shown(saved, membership.of_connection(saved))
    };
    let by_group = list.connections_by_group();
    let place = |group: Option<Uuid>| by_group.get(&group).into_iter().flatten().copied();
    let mut connections: Vec<ConnectionRecord> = place(None).map(listed).collect();
    for group in tree.walk() {
        connections.extend(place(Some(group.id)).map(listed));
    }
    LibrarySnapshot {
        connections,
        groups,
        favorites: list.favorites.iter().map(Uuid::to_string).collect(),
        recent: list
            .recent(RECENT_LIMIT)
            .into_iter()
            .map(|saved| saved.id.to_string())
            .collect(),
        tags: list
            .tags
            .iter()
            .map(|tag| TagRecord {
                name: tag.name.shown(),
                ..TagRecord::from(tag)
            })
            .collect(),
        projects: whole.projects_in_order().into_iter().map(ProjectRecord::from).collect(),
        scope: scope.map(|id| id.to_string()),
    }
}

pub(crate) fn optional_id(id: Option<&str>) -> Result<Option<Uuid>, CoreError> {
    id.filter(|id| !id.trim().is_empty()).map(parse_id).transpose()
}

fn group_name(name: &str) -> Result<ConnectionGroupName, CoreError> {
    ConnectionGroupName::new(name).map_err(|error| CoreError::failed(error.code(), error.to_string()))
}

pub(crate) fn blank(id: Uuid) -> SavedConnection {
    SavedConnection {
        id,
        name: String::new(),
        driver_id: String::new(),
        host: String::new(),
        port: 0,
        database: String::new(),
        username: String::new(),
        tls: TlsConfig::verify_full(),
        safe_mode: SafeModeLevel::default(),
        external_access: tablepro_core::ExternalAccess::default(),
        ai_policy: tablepro_core::AiPolicy::default(),
        query_timeout_secs: None,
        auth_mode: AuthMode::default(),
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        project_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: NetworkOptions::default(),
        details: Default::default(),
        device: Default::default(),
        unknown: Default::default(),
    }
}

fn offered_tls_modes(driver_id: &str) -> &'static [TlsMode] {
    crate::drivers::registry()
        .get(driver_id)
        .and_then(|driver| driver.capabilities().tls)
        .map_or(&[], |tls| tls.modes)
}

// `tls` and `icon` are the record's, read before any write so a refused value writes nothing.
pub(crate) fn apply(
    record: &ConnectionRecord,
    tls: &TlsConfig,
    icon: Option<LibraryIcon>,
    name: String,
    group_id: Option<Uuid>,
    saved: &mut SavedConnection,
) {
    let mode = match saved.driver_id == record.driver_id {
        true => TlsMode::edited(saved.tls.mode, tls.mode, offered_tls_modes(&record.driver_id)),
        false => tls.mode,
    };
    saved.name = shown_name(&name);
    saved.driver_id.clone_from(&record.driver_id);
    saved.host = record.host.trim().to_owned();
    saved.port = record.port;
    saved.database = record.database.trim().to_owned();
    saved.username = record.username.trim().to_owned();
    saved.auth_mode = match record.integrated_auth {
        true => AuthMode::Kerberos,
        false => AuthMode::Password,
    };
    let unknown = std::mem::take(&mut saved.tls.unknown);
    saved.tls = TlsConfig {
        mode,
        unknown,
        ..tls.clone()
    };
    saved.ssh = match &record.ssh {
        Some(settings) => Some(edited_ssh(settings, saved.ssh.as_ref())),
        // A form shows no tunnel to a database file on the SSH host, which only the Mac opens, so it stays as it is.
        None => saved.ssh.take().map(|ssh| match ssh.opens_remote_file() {
            true => ssh,
            false => SavedSshConfig { enabled: false, ..ssh },
        }),
    };
    saved.safe_mode = SafeModeLevel::edited(saved.safe_mode, record.safe_mode.into());
    saved.query_timeout_secs = record.query_timeout_secs;
    saved.color = record.color.as_deref().and_then(ConnectionColor::from_id);
    saved.group_id = group_id;
    if let Some(access) = record.external_access {
        saved.external_access = access.into();
    }
    if let Some(policy) = record.ai_policy {
        saved.ai_policy = AiPolicy::edited(saved.ai_policy, policy.into(), AiPolicy::Ask);
    }
    if icon.is_some() {
        saved.icon = icon;
    }
}

fn path(text: Option<&String>) -> Option<PathBuf> {
    text.map(|text| text.trim())
        .filter(|text| !text.is_empty())
        .map(PathBuf::from)
}

// Half a client identity is refused: dropped, it would save as none and fail later as the server's own refusal.
pub(crate) fn tls_config(settings: &TlsSettings) -> Result<TlsConfig, CoreError> {
    let mut config = TlsConfig::disabled();
    config.mode = settings.mode.into();
    config.ca_file = path(settings.ca_file.as_ref());
    config.client_identity = match (
        path(settings.client_certificate.as_ref()),
        path(settings.client_key.as_ref()),
    ) {
        (Some(certificate), Some(key)) => Some(ClientIdentity { certificate, key }),
        (None, None) => None,
        _ => return Err(DriverError::from(ConfigError::ClientIdentityIncomplete).into()),
    };
    config.server_name = settings
        .server_name
        .as_ref()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty());
    Ok(config)
}

// As the library holds them: half a client identity keeps its empty side, which a connect refuses.
pub(crate) fn stored_tls(settings: &TlsSettings, unknown: BTreeMap<String, Value>) -> TlsConfig {
    let certificate = settings.client_certificate.clone().unwrap_or_default();
    let key = settings.client_key.clone().unwrap_or_default();
    TlsConfig {
        mode: settings.mode.into(),
        ca_file: settings.ca_file.as_ref().map(PathBuf::from),
        client_identity: (!certificate.is_empty() || !key.is_empty()).then(|| ClientIdentity {
            certificate: PathBuf::from(certificate),
            key: PathBuf::from(key),
        }),
        server_name: settings.server_name.clone(),
        unknown,
    }
}

// The form's jump hosts as OpenSSH's -J takes them, checked as a connect would read them; the list is saved as typed.
#[uniffi::export]
pub fn check_jump_hosts(list: String) -> Result<(), CoreError> {
    tablepro_ssh::SshDestination::parse_jump_list(&list)
        .map(|_| ())
        .map_err(|problem| DriverError::from(tablepro_core::TransportError::Ssh(problem.into())).into())
}

// A typed -J list as the hops a save takes, after the check a connect makes.
#[uniffi::export]
pub fn parse_jump_hosts(list: String) -> Result<Vec<SshJumpHostRecord>, CoreError> {
    check_jump_hosts(list.clone())?;
    Ok(SshJumpHost::parse_list(&list)
        .iter()
        .map(SshJumpHostRecord::from)
        .collect())
}

// The hops as a form shows them, the way -J takes them.
#[uniffi::export]
pub fn jump_hosts_text(hops: Vec<SshJumpHostRecord>) -> String {
    hops.iter()
        .map(|hop| SshJumpHost::new(hop.host.clone(), hop.port, hop.username.clone()).destination())
        .collect::<Vec<_>>()
        .join(", ")
}

// A form's settings over the stored tunnel: what the form leaves out keeps its stored value.
pub(crate) fn edited_ssh(settings: &SshSettings, stored: Option<&SavedSshConfig>) -> SavedSshConfig {
    let mut ssh = SavedSshConfig {
        // A save that carries the tunnel means it is on, unless it says otherwise: a form with no switch sends none.
        enabled: settings.enabled.unwrap_or(true),
        port: settings.port,
        username: settings
            .username
            .as_ref()
            .map(|user| user.trim().to_owned())
            .filter(|user| !user.is_empty()),
        jump_hosts: settings
            .jump_hosts
            .iter()
            .filter(|hop| !hop.host.trim().is_empty())
            .map(|hop| SshJumpHost {
                host: hop.host.trim().to_owned(),
                ..jump_host(hop)
            })
            .collect(),
        ..SavedSshConfig::new(settings.host.trim(), saved_auth(&settings.auth, false))
    }
    .kept_over(stored);
    if let Some(options) = &settings.options {
        apply_options(options, &mut ssh);
    }
    if matches!(ssh.auth, SavedSshAuth::PrivateKey { .. }) {
        ssh.kept_key_path = None;
    }
    ssh
}

// As a library holds them, nothing trimmed; a key a newer build wrote stays from `unknown`.
pub(crate) fn stored_ssh(
    settings: &SshSettings,
    unknown: BTreeMap<String, Value>,
) -> Result<SavedSshConfig, CoreError> {
    let mut ssh = SavedSshConfig {
        enabled: settings.enabled.unwrap_or(true),
        host: settings.host.clone(),
        port: settings.port,
        username: settings.username.clone(),
        // A hop id that does not read is refused, not dropped: the store would write the hop back without it.
        jump_hosts: settings
            .jump_hosts
            .iter()
            .map(|hop| {
                Ok(SshJumpHost {
                    id: optional_id(hop.id.as_deref())?,
                    ..jump_host(hop)
                })
            })
            .collect::<Result<_, CoreError>>()?,
        auth: saved_auth(&settings.auth, true),
        unknown,
        ..SavedSshConfig::new("", SavedSshAuth::Agent)
    };
    if let Some(options) = &settings.options {
        apply_options(options, &mut ssh);
    }
    Ok(ssh)
}

// A save of a profile is an edit; a profile keeps the keys a newer build stored in it.
pub(crate) fn saved_ssh(settings: &SshSettings) -> SavedSshConfig {
    edited_ssh(settings, None)
}

fn saved_auth(auth: &SshAuthTag, as_stored: bool) -> SavedSshAuth {
    match auth {
        SshAuthTag::Agent => SavedSshAuth::Agent,
        SshAuthTag::PrivateKey {
            path: key,
            has_passphrase,
        } => SavedSshAuth::PrivateKey {
            path: match as_stored {
                true => key.as_ref().map(PathBuf::from),
                false => path(key.as_ref()),
            },
            has_passphrase: *has_passphrase,
        },
        SshAuthTag::Password => SavedSshAuth::Password,
        SshAuthTag::KeyboardInteractive => SavedSshAuth::KeyboardInteractive,
        SshAuthTag::None => SavedSshAuth::None,
    }
}

fn jump_host(hop: &SshJumpHostRecord) -> SshJumpHost {
    SshJumpHost {
        id: hop.id.as_deref().and_then(|id| Uuid::parse_str(id.trim()).ok()),
        host: hop.host.clone(),
        port: hop.port,
        username: hop.username.clone(),
        auth: hop.auth.map(|auth| match auth {
            SshJumpAuthTag::Agent => SshJumpAuth::Agent,
            SshJumpAuthTag::PrivateKey => SshJumpAuth::PrivateKey,
        }),
        key_path: hop.key_path.as_ref().map(PathBuf::from),
    }
}

fn apply_options(options: &SshOptionsRecord, ssh: &mut SavedSshConfig) {
    ssh.kept_key_path = options.kept_key_path.as_ref().map(PathBuf::from);
    ssh.agent_socket = options.agent_socket.as_ref().map(PathBuf::from);
    ssh.totp = SshTotp {
        mode: match options.totp.mode {
            SshTotpModeTag::Off => SshTotpMode::Off,
            SshTotpModeTag::AutoGenerate => SshTotpMode::AutoGenerate,
            SshTotpModeTag::PromptAtConnect => SshTotpMode::PromptAtConnect,
        },
        algorithm: match options.totp.algorithm {
            SshTotpAlgorithmTag::Sha1 => SshTotpAlgorithm::Sha1,
            SshTotpAlgorithmTag::Sha256 => SshTotpAlgorithm::Sha256,
            SshTotpAlgorithmTag::Sha512 => SshTotpAlgorithm::Sha512,
        },
        digits: options.totp.digits,
        period: options.totp.period,
    };
    ssh.remote_file = SshRemoteFile {
        path: options.remote_file_path.clone(),
        access: match options.remote_file_access {
            RemoteFileAccessTag::ReadOnlyCopy => RemoteFileAccess::ReadOnlyCopy,
            RemoteFileAccessTag::OnServer => RemoteFileAccess::OnServer,
        },
    };
}

pub(crate) fn ssh_settings(ssh: &SavedSshConfig) -> SshSettings {
    SshSettings {
        host: ssh.host.clone(),
        port: ssh.port,
        username: ssh.username.clone(),
        jump_hosts: ssh.jump_hosts.iter().map(SshJumpHostRecord::from).collect(),
        auth: match &ssh.auth {
            SavedSshAuth::Agent => SshAuthTag::Agent,
            SavedSshAuth::PrivateKey { path, has_passphrase } => SshAuthTag::PrivateKey {
                path: path.as_deref().map(shown),
                has_passphrase: *has_passphrase,
            },
            SavedSshAuth::Password => SshAuthTag::Password,
            SavedSshAuth::KeyboardInteractive => SshAuthTag::KeyboardInteractive,
            SavedSshAuth::None => SshAuthTag::None,
        },
        enabled: Some(ssh.enabled),
        options: Some(SshOptionsRecord {
            kept_key_path: ssh.kept_key_path.as_deref().map(shown),
            agent_socket: ssh.agent_socket.as_deref().map(shown),
            totp: SshTotpRecord {
                mode: match ssh.totp.mode {
                    SshTotpMode::Off => SshTotpModeTag::Off,
                    SshTotpMode::AutoGenerate => SshTotpModeTag::AutoGenerate,
                    SshTotpMode::PromptAtConnect => SshTotpModeTag::PromptAtConnect,
                },
                algorithm: match ssh.totp.algorithm {
                    SshTotpAlgorithm::Sha1 => SshTotpAlgorithmTag::Sha1,
                    SshTotpAlgorithm::Sha256 => SshTotpAlgorithmTag::Sha256,
                    SshTotpAlgorithm::Sha512 => SshTotpAlgorithmTag::Sha512,
                },
                digits: ssh.totp.digits,
                period: ssh.totp.period,
            },
            remote_file_path: ssh.remote_file.path.clone(),
            remote_file_access: match ssh.remote_file.access {
                RemoteFileAccess::ReadOnlyCopy => RemoteFileAccessTag::ReadOnlyCopy,
                RemoteFileAccess::OnServer => RemoteFileAccessTag::OnServer,
            },
        }),
    }
}

impl From<&SshJumpHost> for SshJumpHostRecord {
    fn from(hop: &SshJumpHost) -> Self {
        Self {
            id: hop.id.map(|id| id.to_string()),
            host: hop.host.clone(),
            port: hop.port,
            username: hop.username.clone(),
            auth: hop.auth.map(|auth| match auth {
                SshJumpAuth::Agent => SshJumpAuthTag::Agent,
                SshJumpAuth::PrivateKey => SshJumpAuthTag::PrivateKey,
            }),
            key_path: hop.key_path.as_deref().map(shown),
        }
    }
}

pub(crate) fn library_icon(record: &LibraryIconRecord) -> Result<LibraryIcon, CoreError> {
    match record {
        LibraryIconRecord::Named { id } => ConnectionIcon::from_id(id)
            .map(LibraryIcon::Named)
            .ok_or_else(|| CoreError::failed("library.unknown_icon", format!("{id} is not an icon"))),
        LibraryIconRecord::Symbol { name } => SymbolName::new(name)
            .map(LibraryIcon::Symbol)
            .ok_or_else(|| CoreError::failed("library.invalid_icon", format!("{name} is not a symbol name"))),
    }
}

impl From<&LibraryIcon> for LibraryIconRecord {
    fn from(icon: &LibraryIcon) -> Self {
        match icon {
            LibraryIcon::Named(named) => Self::Named {
                id: named.id().to_owned(),
            },
            LibraryIcon::Symbol(symbol) => Self::Symbol {
                name: symbol.as_str().to_owned(),
            },
        }
    }
}

fn shown(path: &Path) -> String {
    path.display().to_string()
}

impl From<&SavedConnection> for ConnectionRecord {
    fn from(saved: &SavedConnection) -> Self {
        Self {
            id: saved.id.to_string(),
            name: saved.name.clone(),
            driver_id: saved.driver_id.clone(),
            host: saved.host.clone(),
            port: saved.port,
            database: saved.database.clone(),
            username: saved.username.clone(),
            integrated_auth: saved.auth_mode == AuthMode::Kerberos,
            tls: TlsSettings {
                mode: saved.tls.mode.into(),
                ca_file: saved.tls.ca_file.as_deref().map(shown),
                // Half an identity, which a library can hold, reads back with its empty side as none.
                client_certificate: saved
                    .tls
                    .client_identity
                    .as_ref()
                    .map(|identity| shown(&identity.certificate))
                    .filter(|path| !path.is_empty()),
                client_key: saved
                    .tls
                    .client_identity
                    .as_ref()
                    .map(|identity| shown(&identity.key))
                    .filter(|path| !path.is_empty()),
                server_name: saved.tls.server_name.clone(),
            },
            ssh: saved.ssh.as_ref().map(ssh_settings),
            safe_mode: saved.safe_mode.into(),
            query_timeout_secs: saved.query_timeout_secs,
            color: saved.color.map(|color| color.id().to_owned()),
            group_id: saved.group_id.map(|id| id.to_string()),
            last_opened_ms: saved.last_opened_at.map(|at: DateTime<Utc>| at.timestamp_millis()),
            tags: saved.tags.iter().map(Uuid::to_string).collect(),
            ai_policy: Some(saved.ai_policy.into()),
            external_access: Some(saved.external_access.into()),
            project_id: saved.project_id.map(|id| id.to_string()),
            icon: saved.icon.as_ref().map(LibraryIconRecord::from),
            order: saved.order,
        }
    }
}

impl ConnectionRecord {
    pub(crate) fn shown(saved: &SavedConnection, project: Option<Uuid>) -> Self {
        Self {
            project_id: project.map(|id| id.to_string()),
            ..Self::from(saved)
        }
    }
}

impl GroupRecord {
    fn shown(group: &ConnectionGroup, membership: &ProjectMembership) -> Self {
        Self {
            project_id: membership.of_group(group.id).map(|id| id.to_string()),
            ..Self::from(group)
        }
    }
}

// As stored: a top-level group's own project, none below it.
impl From<&ConnectionGroup> for GroupRecord {
    fn from(group: &ConnectionGroup) -> Self {
        Self {
            id: group.id.to_string(),
            name: group.name.as_str().to_owned(),
            parent_id: group.parent_id.map(|id| id.to_string()),
            order: group.order,
            color: group.color.map(|color| color.id().to_owned()),
            project_id: group.project_id.map(|id| id.to_string()),
            icon: group.icon.as_ref().map(LibraryIconRecord::from),
        }
    }
}

impl From<&ConnectionProject> for ProjectRecord {
    fn from(project: &ConnectionProject) -> Self {
        Self {
            id: project.id.to_string(),
            name: project.name.as_str().to_owned(),
            order: project.order,
            color: project.color.map(|color| color.id().to_owned()),
            icon: project.icon.as_ref().map(LibraryIconRecord::from),
        }
    }
}

impl From<&ConnectionTag> for TagRecord {
    fn from(tag: &ConnectionTag) -> Self {
        Self {
            id: tag.id.to_string(),
            name: tag.name.as_str().to_owned(),
            color: tag.color.map(|color| color.id().to_owned()),
            is_preset: tag.is_preset,
        }
    }
}

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;

    use super::*;

    #[test]
    fn debug_output_says_which_secrets_are_held_but_not_what_they_are() {
        let secrets = ConnectionSecrets {
            database_password: Some(SecretString::from("hunter2")),
            ssh_password: None,
            ssh_passphrase: Some(SecretString::from("")),
        };

        assert_eq!(
            format!("{secrets:?}"),
            "ConnectionSecrets { database_password: Some([REDACTED]), ssh_password: None, \
             ssh_passphrase: Some([REDACTED]) }"
        );
        let typed = secrets.into_typed();
        assert_eq!(
            typed
                .iter()
                .map(|(kind, secret)| (*kind, secret.expose_secret()))
                .collect::<Vec<_>>(),
            [
                (SecretKind::DatabasePassword, "hunter2"),
                (SecretKind::SshPassphrase, "")
            ]
        );
    }
}
