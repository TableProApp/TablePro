use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Utc};
use secrecy::SecretString;
use tablepro_core::credentials::{SecretKind, SecretLookup, SecretVault};
use tablepro_core::{
    AuthMode, ClientIdentity, ConfigError, DriverError, NetworkOptions, SafeModeLevel, TlsConfig, TlsMode,
};
use tablepro_session::runtime::Tasks;
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionStore, ConnectionTag, ConnectionTagName,
    SavedConnection, SavedSshAuth, SavedSshConfig, StorageError, english_secret_label,
};
use uuid::Uuid;

use crate::error::CoreError;
use crate::masking::{MaskingRuleRecord, saved_rules};
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TlsModeTag {
    Disable,
    Prefer,
    Require,
    VerifyFull,
    Strict,
}

impl From<TlsMode> for TlsModeTag {
    fn from(mode: TlsMode) -> Self {
        match mode {
            TlsMode::Disable => Self::Disable,
            TlsMode::Prefer => Self::Prefer,
            TlsMode::Require => Self::Require,
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
            TlsModeTag::VerifyFull => Self::VerifyFull,
            TlsModeTag::Strict => Self::Strict,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SafeModeTag {
    Off,
    ConfirmWrites,
    ReadOnly,
}

impl From<SafeModeTag> for SafeModeLevel {
    fn from(tag: SafeModeTag) -> Self {
        match tag {
            SafeModeTag::Off => Self::Off,
            SafeModeTag::ConfirmWrites => Self::ConfirmWrites,
            SafeModeTag::ReadOnly => Self::ReadOnly,
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
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshSettings {
    pub host: String,
    pub port: Option<u16>,
    pub username: Option<String>,
    pub jump_hosts: Vec<String>,
    pub auth: SshAuthTag,
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
    // In order: the first rule that matches a column wins. A save reaches every open session of the connection.
    pub masking_rules: Vec<MaskingRuleRecord>,
    pub color: Option<String>,
    pub group_id: Option<String>,
    pub last_opened_ms: Option<i64>,
    // Read only: a save keeps the stored tags, which change through tag_connections.
    pub tags: Vec<String>,
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
}

// A label several connections share; they name it by id, so a rename or a new colour reaches all of them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagRecord {
    pub id: String,
    pub name: String,
    pub color: String,
}

// Every list is in the library's own order: connections and groups by position, tags as they were made.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibrarySnapshot {
    pub connections: Vec<ConnectionRecord>,
    pub groups: Vec<GroupRecord>,
    pub favorites: Vec<String>,
    pub recent: Vec<String>,
    pub tags: Vec<TagRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ImportSummary {
    pub added: u32,
    pub updated: u32,
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
    pub async fn snapshot(&self) -> Result<LibrarySnapshot, CoreError> {
        self.blocking(|store| {
            let list = store.list_blocking()?;
            let tree = list.group_tree();
            let mut groups = Vec::new();
            for group in tree.walk() {
                groups.push(GroupRecord::from(group));
            }
            let mut connections: Vec<ConnectionRecord> = list
                .connections_in(None)
                .into_iter()
                .map(ConnectionRecord::from)
                .collect();
            for group in tree.walk() {
                connections.extend(
                    list.connections_in(Some(group.id))
                        .into_iter()
                        .map(ConnectionRecord::from),
                );
            }
            Ok(LibrarySnapshot {
                connections,
                groups,
                favorites: list.favorites.iter().map(Uuid::to_string).collect(),
                recent: list
                    .recent(RECENT_LIMIT)
                    .into_iter()
                    .map(|saved| saved.id.to_string())
                    .collect(),
                tags: list.tags.iter().map(TagRecord::from).collect(),
            })
        })
        .await
    }

    // Creates the connection when its id is empty or unknown, and stores the secrets the form holds.
    pub async fn save(
        &self,
        record: ConnectionRecord,
        secrets: ConnectionSecrets,
    ) -> Result<ConnectionRecord, CoreError> {
        let name = record.name.trim().to_owned();
        if name.is_empty() {
            return Err(CoreError::failed("library.name_required", "a connection needs a name"));
        }
        let group_id = optional_id(record.group_id.as_deref())?;
        let id = match record.id.trim() {
            "" => None,
            id => Some(parse_id(id)?),
        };
        let tls = tls_config(&record.tls)?;
        let typed = secrets.into_typed();
        let kinds = typed.iter().map(|(kind, _)| *kind).collect();
        let _held = self.hold_writes().await;
        // Read before anything is written, for a refused secret to put back.
        let previous = match id {
            Some(id) => self.held_values(id, kinds).await?,
            None => Vec::new(),
        };
        let (saved, before) = self
            .blocking(move |store| {
                if let Some(id) = id {
                    let mut before = None;
                    let updated = store.update_blocking(id, |saved| {
                        before = Some(saved.clone());
                        apply(&record, &tls, name.clone(), group_id, saved);
                    })?;
                    if let Some(updated) = updated {
                        return Ok((updated, before));
                    }
                }
                let mut created = blank(id.unwrap_or_else(Uuid::new_v4));
                apply(&record, &tls, name, group_id, &mut created);
                store.upsert_blocking(created.clone())?;
                let listed = store
                    .list_blocking()?
                    .connections
                    .iter()
                    .find(|saved| saved.id == created.id)
                    .cloned()
                    .unwrap_or(created);
                Ok((listed, None))
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
        Ok(ConnectionRecord::from(&saved))
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
        let name = name.trim().to_owned();
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

    pub async fn update_tag(&self, id: String, name: String, color: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let name = tag_name(&name)?;
        let color = tag_color(&color)?;
        self.blocking(move |store| Ok(store.update_tag_blocking(ConnectionTag { id, name, color })?))
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

    pub async fn create_group(&self, name: String, parent_id: Option<String>) -> Result<GroupRecord, CoreError> {
        let name = group_name(&name)?;
        let parent = optional_id(parent_id.as_deref())?;
        self.blocking(move |store| {
            Ok(GroupRecord::from(
                &store.create_group_blocking(ConnectionGroup::new(name, parent))?,
            ))
        })
        .await
    }

    pub async fn rename_group(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let name = group_name(&name)?;
        self.blocking(move |store| Ok(store.rename_group_blocking(id, name)?))
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

    // Merges a TablePro connections file; it carries no passwords.
    pub async fn import_file(&self, path: String) -> Result<ImportSummary, CoreError> {
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let path = PathBuf::from(path);
            let bytes = std::fs::read(&path).map_err(|error| {
                CoreError::failed("library.import_unreadable", format!("{}: {error}", path.display()))
            })?;
            let report = store.import_blocking(&path, &bytes)?;
            Ok(ImportSummary {
                added: u32::try_from(report.added).unwrap_or(u32::MAX),
                updated: u32::try_from(report.updated).unwrap_or(u32::MAX),
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

fn parse_ids(ids: &[String]) -> Result<Vec<Uuid>, CoreError> {
    ids.iter().map(|id| parse_id(id)).collect()
}

fn tag_name(name: &str) -> Result<ConnectionTagName, CoreError> {
    ConnectionTagName::new(name).map_err(|error| CoreError::failed(error.code(), error.to_string()))
}

fn tag_color(color: &str) -> Result<ConnectionColor, CoreError> {
    ConnectionColor::from_id(color.trim())
        .ok_or_else(|| CoreError::failed("library.unknown_color", format!("{color} is not a colour")))
}

fn optional_id(id: Option<&str>) -> Result<Option<Uuid>, CoreError> {
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
        masking_rules: Vec::new(),
        auth_mode: AuthMode::default(),
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: NetworkOptions::default(),
    }
}

// `tls` is `tls_config` of the record's settings, read before any write so a refused pair writes nothing.
pub(crate) fn apply(
    record: &ConnectionRecord,
    tls: &TlsConfig,
    name: String,
    group_id: Option<Uuid>,
    saved: &mut SavedConnection,
) {
    saved.name = name;
    saved.driver_id.clone_from(&record.driver_id);
    saved.host = record.host.trim().to_owned();
    saved.port = record.port;
    saved.database = record.database.trim().to_owned();
    saved.username = record.username.trim().to_owned();
    saved.auth_mode = match record.integrated_auth {
        true => AuthMode::Kerberos,
        false => AuthMode::Password,
    };
    saved.tls = tls.clone();
    saved.ssh = record.ssh.as_ref().map(saved_ssh);
    saved.safe_mode = record.safe_mode.into();
    saved.query_timeout_secs = record.query_timeout_secs;
    saved.masking_rules = saved_rules(&record.masking_rules);
    saved.color = record.color.as_deref().and_then(ConnectionColor::from_id);
    saved.group_id = group_id;
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

pub(crate) fn saved_ssh(settings: &SshSettings) -> SavedSshConfig {
    SavedSshConfig {
        host: settings.host.trim().to_owned(),
        port: settings.port,
        username: settings
            .username
            .as_ref()
            .map(|user| user.trim().to_owned())
            .filter(|user| !user.is_empty()),
        jump_hosts: settings
            .jump_hosts
            .iter()
            .map(|host| host.trim().to_owned())
            .filter(|host| !host.is_empty())
            .collect(),
        auth: match &settings.auth {
            SshAuthTag::Agent => SavedSshAuth::Agent,
            SshAuthTag::PrivateKey {
                path: key,
                has_passphrase,
            } => SavedSshAuth::PrivateKey {
                path: path(key.as_ref()),
                has_passphrase: *has_passphrase,
            },
            SshAuthTag::Password => SavedSshAuth::Password,
            SshAuthTag::KeyboardInteractive => SavedSshAuth::KeyboardInteractive,
        },
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
                client_certificate: saved
                    .tls
                    .client_identity
                    .as_ref()
                    .map(|identity| shown(&identity.certificate)),
                client_key: saved.tls.client_identity.as_ref().map(|identity| shown(&identity.key)),
                server_name: saved.tls.server_name.clone(),
            },
            ssh: saved.ssh.as_ref().map(|ssh| SshSettings {
                host: ssh.host.clone(),
                port: ssh.port,
                username: ssh.username.clone(),
                jump_hosts: ssh.jump_hosts.clone(),
                auth: match &ssh.auth {
                    SavedSshAuth::Agent => SshAuthTag::Agent,
                    SavedSshAuth::PrivateKey { path, has_passphrase } => SshAuthTag::PrivateKey {
                        path: path.as_deref().map(shown),
                        has_passphrase: *has_passphrase,
                    },
                    SavedSshAuth::Password => SshAuthTag::Password,
                    SavedSshAuth::KeyboardInteractive => SshAuthTag::KeyboardInteractive,
                },
            }),
            safe_mode: match saved.safe_mode {
                SafeModeLevel::Off => SafeModeTag::Off,
                SafeModeLevel::ConfirmWrites => SafeModeTag::ConfirmWrites,
                SafeModeLevel::ReadOnly => SafeModeTag::ReadOnly,
            },
            query_timeout_secs: saved.query_timeout_secs,
            masking_rules: saved.masking_rules.iter().map(MaskingRuleRecord::from).collect(),
            color: saved.color.map(|color| color.id().to_owned()),
            group_id: saved.group_id.map(|id| id.to_string()),
            last_opened_ms: saved.last_opened_at.map(|at: DateTime<Utc>| at.timestamp_millis()),
            tags: saved.tags.iter().map(Uuid::to_string).collect(),
        }
    }
}

impl From<&ConnectionGroup> for GroupRecord {
    fn from(group: &ConnectionGroup) -> Self {
        Self {
            id: group.id.to_string(),
            name: group.name.as_str().to_owned(),
            parent_id: group.parent_id.map(|id| id.to_string()),
            order: group.order,
            color: group.color.map(|color| color.id().to_owned()),
        }
    }
}

impl From<&ConnectionTag> for TagRecord {
    fn from(tag: &ConnectionTag) -> Self {
        Self {
            id: tag.id.to_string(),
            name: tag.name.as_str().to_owned(),
            color: tag.color.id().to_owned(),
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
