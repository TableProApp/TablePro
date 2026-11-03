use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Utc};
use secrecy::SecretString;
use tablepro_core::credentials::{SecretKind, SecretVault};
use tablepro_core::{AuthMode, ClientIdentity, NetworkOptions, SafeModeLevel, TlsConfig, TlsMode};
use tablepro_session::runtime::Tasks;
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionStore, ConnectionTag, ConnectionTagName,
    SavedConnection, SavedSshAuth, SavedSshConfig, StorageError, english_secret_label,
};
use uuid::Uuid;

use crate::error::CoreError;
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TlsModeTag {
    Disable,
    Require,
    VerifyFull,
    Strict,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SafeModeTag {
    Off,
    ConfirmWrites,
    ReadOnly,
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
    pub color: Option<String>,
    pub group_id: Option<String>,
    pub last_opened_ms: Option<i64>,
    // Read only: a save keeps the stored tags, which change through tag_connections.
    pub tags: Vec<String>,
}

// Each secret as the form holds it: None keeps what is stored, an empty string is stored as one.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ConnectionSecrets {
    pub database_password: Option<String>,
    pub ssh_password: Option<String>,
    pub ssh_passphrase: Option<String>,
}

impl ConnectionSecrets {
    pub(crate) fn typed(&self) -> Vec<(SecretKind, SecretString)> {
        [
            (SecretKind::DatabasePassword, &self.database_password),
            (SecretKind::SshPassword, &self.ssh_password),
            (SecretKind::SshPassphrase, &self.ssh_passphrase),
        ]
        .into_iter()
        .filter_map(|(kind, secret)| secret.as_ref().map(|secret| (kind, SecretString::from(secret.clone()))))
        .collect()
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

#[derive(uniffi::Object)]
pub struct ConnectionLibrary {
    store: ConnectionStore,
    secrets: Arc<dyn SecretVault>,
    tasks: Tasks,
}

impl ConnectionLibrary {
    pub(crate) fn new(store: ConnectionStore, secrets: Arc<dyn SecretVault>, tasks: Tasks) -> Self {
        Self { store, secrets, tasks }
    }

    async fn blocking<T, F>(&self, work: F) -> Result<T, CoreError>
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
        let saved = self
            .blocking(move |store| {
                if let Some(id) = id
                    && let Some(updated) =
                        store.update_blocking(id, |saved| apply(&record, name.clone(), group_id, saved))?
                {
                    return Ok(updated);
                }
                let mut created = blank(id.unwrap_or_else(Uuid::new_v4));
                apply(&record, name, group_id, &mut created);
                store.upsert_blocking(created.clone())?;
                Ok(store
                    .list_blocking()?
                    .connections
                    .iter()
                    .find(|saved| saved.id == created.id)
                    .cloned()
                    .unwrap_or(created))
            })
            .await?;
        let vault = self.secrets.clone();
        let stored = saved.clone();
        on_runtime(&self.tasks, async move {
            for (kind, secret) in secrets.typed() {
                let label = english_secret_label(kind, &stored.secret_target(kind));
                vault
                    .store(stored.id, kind, &secret, &label)
                    .await
                    .map_err(secret_error)?;
            }
            Ok(())
        })
        .await?;
        Ok(ConnectionRecord::from(&saved))
    }

    pub async fn delete(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| {
            store.remove_blocking(id)?;
            Ok(())
        })
        .await?;
        let vault = self.secrets.clone();
        on_runtime(&self.tasks, async move {
            vault.delete_connection(id).await.map_err(secret_error)
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

pub(crate) fn apply(record: &ConnectionRecord, name: String, group_id: Option<Uuid>, saved: &mut SavedConnection) {
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
    saved.tls = tls_config(&record.tls);
    saved.ssh = record.ssh.as_ref().map(ssh_config);
    saved.safe_mode = match record.safe_mode {
        SafeModeTag::Off => SafeModeLevel::Off,
        SafeModeTag::ConfirmWrites => SafeModeLevel::ConfirmWrites,
        SafeModeTag::ReadOnly => SafeModeLevel::ReadOnly,
    };
    saved.query_timeout_secs = record.query_timeout_secs;
    saved.color = record.color.as_deref().and_then(ConnectionColor::from_id);
    saved.group_id = group_id;
}

fn path(text: Option<&String>) -> Option<PathBuf> {
    text.map(|text| text.trim())
        .filter(|text| !text.is_empty())
        .map(PathBuf::from)
}

fn tls_config(settings: &TlsSettings) -> TlsConfig {
    let mut config = match settings.mode {
        TlsModeTag::Disable => TlsConfig::disabled(),
        TlsModeTag::Require | TlsModeTag::VerifyFull | TlsModeTag::Strict => TlsConfig::verify_full(),
    };
    config.mode = match settings.mode {
        TlsModeTag::Disable => TlsMode::Disable,
        TlsModeTag::Require => TlsMode::Require,
        TlsModeTag::VerifyFull => TlsMode::VerifyFull,
        TlsModeTag::Strict => TlsMode::Strict,
    };
    config.ca_file = path(settings.ca_file.as_ref());
    config.client_identity = match (
        path(settings.client_certificate.as_ref()),
        path(settings.client_key.as_ref()),
    ) {
        (Some(certificate), Some(key)) => Some(ClientIdentity { certificate, key }),
        _ => None,
    };
    config.server_name = settings
        .server_name
        .as_ref()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty());
    config
}

fn ssh_config(settings: &SshSettings) -> SavedSshConfig {
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
                mode: match saved.tls.mode {
                    TlsMode::Disable => TlsModeTag::Disable,
                    TlsMode::Require => TlsModeTag::Require,
                    TlsMode::VerifyFull => TlsModeTag::VerifyFull,
                    TlsMode::Strict => TlsModeTag::Strict,
                },
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
