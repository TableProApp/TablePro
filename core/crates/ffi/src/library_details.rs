use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

use tablepro_storage::{
    CloudSqlAuth, CloudSqlProxy, CloudflareAuth, CloudflareTunnel, ConnectionDetails, ConnectionOrigin,
    CredentialPassword, CredentialProfile, CredentialReference, DeviceOnly, KnownOrigin, LocalPasswordSource,
    RemoveOutcome, SocksProxy, SshProfile, SshRoute, SshRouteHop, SshRouteTarget, StorageError, TunnelCommand,
    TunnelCommandMethod, VaultAuth, VaultDatabaseRole,
};
use uuid::Uuid;

use crate::error::CoreError;
use crate::library::{ConnectionLibrary, SshSettings, edited_ssh, parse_id, ssh_settings};

// What a connection carries beyond the form's fields: what runs and what is sent from it, its profile
// links and its plugin fields. Every app keeps these, and the ones it shows nothing for come back unchanged.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ConnectionDetailsRecord {
    pub startup_sql: Option<String>,
    pub ai_rules: Option<String>,
    pub ai_allowed_tools: Vec<String>,
    pub ssh_profile_id: Option<String>,
    pub ssh_route: Option<SshRouteRecord>,
    pub credential_profile_id: Option<String>,
    pub credential_reference: Option<CredentialReferenceRecord>,
    pub redis_database: Option<u32>,
    pub additional_fields: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshRouteRecord {
    pub version: u32,
    pub publisher: String,
    pub basis: String,
    pub hops: Vec<SshRouteHopRecord>,
    pub target: SshRouteTargetRecord,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshRouteHopRecord {
    pub id: String,
    pub alias: String,
    pub host: String,
    pub port: u16,
    pub username: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshRouteTargetRecord {
    pub alias: String,
    pub host: String,
    pub port: u16,
    pub username: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CredentialReferenceRecord {
    Env {
        variable: String,
    },
    OnePassword {
        reference: String,
    },
    Vault {
        path: String,
        field: String,
    },
    AwsSecretsManager {
        secret_id: String,
        json_key: Option<String>,
    },
    VaultDatabaseRole {
        address: Option<String>,
        mount: String,
        role: String,
        auth: VaultAuthRecord,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum VaultAuthRecord {
    Token,
    AppRole {
        mount: String,
        role_id: String,
        secret_id_path: String,
    },
    Oidc {
        mount: String,
        role: String,
    },
}

// What never leaves this device: no export, link or sync carries it.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct DeviceSettingsRecord {
    pub local_only: bool,
    pub is_sample: bool,
    // `this_device`, `imported`, `synced`, `link`, `linked_folder`, `team_library`, or one a newer build wrote.
    pub origin: String,
    pub password_source: Option<LocalPasswordSourceRecord>,
    pub cloudflare_tunnel: Option<CloudflareTunnelRecord>,
    pub cloud_sql_proxy: Option<CloudSqlProxyRecord>,
    pub socks_proxy: Option<SocksProxyRecord>,
    pub tunnel_command: Option<TunnelCommandRecord>,
    // Required may stand for the Mac's Preferred, as an earlier iOS build wrote both, until a pull shows which.
    #[uniffi(default = false)]
    pub tls_mode_unsettled: bool,
    // This device removed the SSH profile link, and no pull has shown the record without it yet.
    #[uniffi(default = false)]
    pub ssh_profile_unlinked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LocalPasswordSourceRecord {
    File { path: String },
    Command { shell: String, reuse_seconds: Option<u32> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CloudflareAuthTag {
    BrowserSso,
    ServiceToken,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloudflareTunnelRecord {
    pub access_hostname: String,
    pub local_port: Option<u16>,
    pub auth_method: CloudflareAuthTag,
    pub expose_to_lan: bool,
    pub binary_path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CloudSqlAuthTag {
    ApplicationDefault,
    ServiceAccountKey,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloudSqlProxyRecord {
    pub instance_connection_name: String,
    pub auth_mode: CloudSqlAuthTag,
    pub use_iam_auth: bool,
    pub use_private_ip: bool,
    pub local_port: Option<u16>,
    pub binary_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SocksProxyRecord {
    pub host: String,
    pub port: u16,
    pub username: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TunnelCommandMethodTag {
    Kubectl,
    AwsSsm,
    Custom,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TunnelCommandRecord {
    pub method: TunnelCommandMethodTag,
    pub command: String,
    pub executable_path: String,
    pub kubernetes_namespace: String,
    pub kubernetes_resource: String,
    pub kubernetes_context: String,
    pub aws_target: String,
    pub aws_profile: String,
    pub aws_region: String,
}

// SSH settings kept under a name, which connections follow by their details' ssh_profile_id.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshProfileRecord {
    // Empty for a profile not saved yet.
    pub id: String,
    pub name: String,
    pub ssh: SshSettings,
}

// A user and a password kept once, shared by every connection linked to it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CredentialProfileRecord {
    // Empty for a profile not saved yet.
    pub id: String,
    pub name: String,
    pub username: String,
    pub password: CredentialPasswordRecord,
    pub secure_field_ids: Vec<String>,
    pub order: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CredentialPasswordRecord {
    Stored,
    Prompt,
    Pgpass,
    Reference { reference: CredentialReferenceRecord },
    Local { source: LocalPasswordSourceRecord },
}

#[uniffi::export]
impl ConnectionLibrary {
    pub async fn connection_details(&self, id: String) -> Result<ConnectionDetailsRecord, CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| Ok(ConnectionDetailsRecord::from(&stored(store, id)?.details)))
            .await
    }

    // Replaces every detail; a route keeps the keys a newer build stored in it.
    pub async fn set_connection_details(&self, id: String, details: ConnectionDetailsRecord) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let mut details = ConnectionDetails::try_from(details)?;
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let updated = store.update_blocking(id, |saved| {
                if let (Some(next), Some(before)) = (details.ssh_route.as_mut(), saved.details.ssh_route.as_ref()) {
                    next.unknown.clone_from(&before.unknown);
                }
                saved.details = details;
            })?;
            updated
                .map(|_| ())
                .ok_or(StorageError::ConnectionNotFound { id }.into())
        })
        .await
    }

    pub async fn device_settings(&self, id: String) -> Result<DeviceSettingsRecord, CoreError> {
        let id = parse_id(&id)?;
        self.blocking(move |store| Ok(DeviceSettingsRecord::from(&stored(store, id)?.device)))
            .await
    }

    pub async fn set_device_settings(&self, id: String, settings: DeviceSettingsRecord) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let device = DeviceOnly::from(settings);
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let updated = store.update_blocking(id, |saved| saved.device = device)?;
            updated
                .map(|_| ())
                .ok_or(StorageError::ConnectionNotFound { id }.into())
        })
        .await
    }

    pub async fn ssh_profiles(&self) -> Result<Vec<SshProfileRecord>, CoreError> {
        self.blocking(|store| {
            Ok(store
                .list_blocking()?
                .ssh_profiles
                .iter()
                .map(SshProfileRecord::from)
                .collect())
        })
        .await
    }

    // Creates the profile when its id is empty or unknown; keys a newer build stored in it stay.
    pub async fn save_ssh_profile(&self, profile: SshProfileRecord) -> Result<SshProfileRecord, CoreError> {
        let id = new_or_parsed(&profile.id)?;
        let name = required_name(&profile.name)?;
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let list = store.list_blocking()?;
            let id = unclaimed(&list, id);
            let stored = list
                .ssh_profiles
                .iter()
                .find(|held| held.id == id)
                .map(|held| &held.ssh);
            let saved = SshProfile {
                id,
                name,
                ssh: edited_ssh(&profile.ssh, stored),
            };
            store.save_ssh_profile_blocking(saved.clone())?;
            Ok(SshProfileRecord::from(&saved))
        })
        .await
    }

    // Returns whether the profile was there.
    pub async fn delete_ssh_profile(&self, id: String) -> Result<bool, CoreError> {
        let id = parse_id(&id)?;
        let _held = self.hold_writes().await;
        self.blocking(move |store| Ok(store.delete_ssh_profile_blocking(id)? == RemoveOutcome::Removed))
            .await
    }

    pub async fn credential_profiles(&self) -> Result<Vec<CredentialProfileRecord>, CoreError> {
        self.blocking(|store| {
            Ok(store
                .list_blocking()?
                .credential_profiles
                .iter()
                .map(CredentialProfileRecord::from)
                .collect())
        })
        .await
    }

    // Creates the profile when its id is empty or unknown; keys a newer build stored in it stay.
    pub async fn save_credential_profile(
        &self,
        profile: CredentialProfileRecord,
    ) -> Result<CredentialProfileRecord, CoreError> {
        let id = new_or_parsed(&profile.id)?;
        let name = required_name(&profile.name)?;
        let password = CredentialPassword::from(profile.password);
        let username = profile.username;
        let secure_field_ids = profile.secure_field_ids;
        let order = profile.order;
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let list = store.list_blocking()?;
            let id = unclaimed(&list, id);
            let unknown = list
                .credential_profiles
                .iter()
                .find(|held| held.id == id)
                .map(|held| held.unknown.clone())
                .unwrap_or_default();
            let saved = CredentialProfile {
                id,
                name,
                username,
                password,
                secure_field_ids,
                order,
                unknown,
            };
            store.save_credential_profile_blocking(saved.clone())?;
            Ok(CredentialProfileRecord::from(&saved))
        })
        .await
    }

    // Returns whether the profile was there. Its stored password stays until the app deletes it.
    pub async fn delete_credential_profile(&self, id: String) -> Result<bool, CoreError> {
        let id = parse_id(&id)?;
        let _held = self.hold_writes().await;
        self.blocking(move |store| Ok(store.delete_credential_profile_blocking(id)? == RemoveOutcome::Removed))
            .await
    }
}

fn stored(store: &tablepro_storage::ConnectionStore, id: Uuid) -> Result<tablepro_storage::SavedConnection, CoreError> {
    store
        .list_blocking()?
        .connections
        .iter()
        .find(|saved| saved.id == id)
        .cloned()
        .ok_or_else(|| StorageError::ConnectionNotFound { id }.into())
}

// A profile this build cannot read keeps its id, and the links and secrets filed under it.
fn unclaimed(list: &tablepro_storage::ConnectionList, id: Uuid) -> Uuid {
    if list.unreadable_profiles.contains(&id) {
        Uuid::new_v4()
    } else {
        id
    }
}

fn new_or_parsed(id: &str) -> Result<Uuid, CoreError> {
    match id.trim() {
        "" => Ok(Uuid::new_v4()),
        id => parse_id(id),
    }
}

fn required_name(name: &str) -> Result<String, CoreError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(CoreError::failed("library.name_required", "a profile needs a name"));
    }
    Ok(name.to_owned())
}

fn optional_uuid(id: Option<&str>) -> Result<Option<Uuid>, CoreError> {
    id.map(str::trim).filter(|id| !id.is_empty()).map(parse_id).transpose()
}

impl From<&ConnectionDetails> for ConnectionDetailsRecord {
    fn from(details: &ConnectionDetails) -> Self {
        Self {
            startup_sql: details.startup_sql.clone(),
            ai_rules: details.ai_rules.clone(),
            ai_allowed_tools: details.ai_allowed_tools.iter().cloned().collect(),
            ssh_profile_id: details.ssh_profile_id.map(|id| id.to_string()),
            ssh_route: details.ssh_route.as_ref().map(SshRouteRecord::from),
            credential_profile_id: details.credential_profile_id.map(|id| id.to_string()),
            credential_reference: details
                .credential_reference
                .as_ref()
                .map(CredentialReferenceRecord::from),
            redis_database: details.redis_database,
            additional_fields: details
                .additional_fields
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect(),
        }
    }
}

impl TryFrom<ConnectionDetailsRecord> for ConnectionDetails {
    type Error = CoreError;

    fn try_from(record: ConnectionDetailsRecord) -> Result<Self, CoreError> {
        Ok(Self {
            startup_sql: record.startup_sql,
            ai_rules: record.ai_rules,
            ai_allowed_tools: record.ai_allowed_tools.into_iter().collect(),
            ssh_profile_id: optional_uuid(record.ssh_profile_id.as_deref())?,
            ssh_route: record.ssh_route.map(SshRoute::try_from).transpose()?,
            credential_profile_id: optional_uuid(record.credential_profile_id.as_deref())?,
            credential_reference: record.credential_reference.map(CredentialReference::from),
            redis_database: record.redis_database,
            additional_fields: record.additional_fields.into_iter().collect::<BTreeMap<_, _>>(),
        })
    }
}

impl From<&SshRoute> for SshRouteRecord {
    fn from(route: &SshRoute) -> Self {
        Self {
            version: route.version,
            publisher: route.publisher.to_string(),
            basis: route.basis.clone(),
            hops: route
                .hops
                .iter()
                .map(|hop| SshRouteHopRecord {
                    id: hop.id.to_string(),
                    alias: hop.alias.clone(),
                    host: hop.host.clone(),
                    port: hop.port,
                    username: hop.username.clone(),
                })
                .collect(),
            target: SshRouteTargetRecord {
                alias: route.target.alias.clone(),
                host: route.target.host.clone(),
                port: route.target.port,
                username: route.target.username.clone(),
            },
        }
    }
}

impl TryFrom<SshRouteRecord> for SshRoute {
    type Error = CoreError;

    fn try_from(record: SshRouteRecord) -> Result<Self, CoreError> {
        Ok(Self {
            version: record.version,
            publisher: parse_id(&record.publisher)?,
            basis: record.basis,
            hops: record
                .hops
                .into_iter()
                .map(|hop| {
                    Ok(SshRouteHop {
                        id: parse_id(&hop.id)?,
                        alias: hop.alias,
                        host: hop.host,
                        port: hop.port,
                        username: hop.username,
                    })
                })
                .collect::<Result<_, CoreError>>()?,
            target: SshRouteTarget {
                alias: record.target.alias,
                host: record.target.host,
                port: record.target.port,
                username: record.target.username,
            },
            unknown: BTreeMap::new(),
        })
    }
}

impl From<&CredentialReference> for CredentialReferenceRecord {
    fn from(reference: &CredentialReference) -> Self {
        match reference {
            CredentialReference::Env { variable } => Self::Env {
                variable: variable.clone(),
            },
            CredentialReference::OnePassword { reference } => Self::OnePassword {
                reference: reference.clone(),
            },
            CredentialReference::Vault { path, field } => Self::Vault {
                path: path.clone(),
                field: field.clone(),
            },
            CredentialReference::AwsSecretsManager { secret_id, json_key } => Self::AwsSecretsManager {
                secret_id: secret_id.clone(),
                json_key: json_key.clone(),
            },
            CredentialReference::VaultDatabaseRole(role) => Self::VaultDatabaseRole {
                address: role.address.clone(),
                mount: role.mount.clone(),
                role: role.role.clone(),
                auth: match &role.auth {
                    VaultAuth::Token => VaultAuthRecord::Token,
                    VaultAuth::AppRole {
                        mount,
                        role_id,
                        secret_id_path,
                    } => VaultAuthRecord::AppRole {
                        mount: mount.clone(),
                        role_id: role_id.clone(),
                        secret_id_path: secret_id_path.display().to_string(),
                    },
                    VaultAuth::Oidc { mount, role } => VaultAuthRecord::Oidc {
                        mount: mount.clone(),
                        role: role.clone(),
                    },
                },
            },
        }
    }
}

impl From<CredentialReferenceRecord> for CredentialReference {
    fn from(record: CredentialReferenceRecord) -> Self {
        match record {
            CredentialReferenceRecord::Env { variable } => Self::Env { variable },
            CredentialReferenceRecord::OnePassword { reference } => Self::OnePassword { reference },
            CredentialReferenceRecord::Vault { path, field } => Self::Vault { path, field },
            CredentialReferenceRecord::AwsSecretsManager { secret_id, json_key } => {
                Self::AwsSecretsManager { secret_id, json_key }
            }
            CredentialReferenceRecord::VaultDatabaseRole {
                address,
                mount,
                role,
                auth,
            } => Self::VaultDatabaseRole(VaultDatabaseRole {
                address,
                mount,
                role,
                auth: match auth {
                    VaultAuthRecord::Token => VaultAuth::Token,
                    VaultAuthRecord::AppRole {
                        mount,
                        role_id,
                        secret_id_path,
                    } => VaultAuth::AppRole {
                        mount,
                        role_id,
                        secret_id_path: PathBuf::from(secret_id_path),
                    },
                    VaultAuthRecord::Oidc { mount, role } => VaultAuth::Oidc { mount, role },
                },
            }),
        }
    }
}

const ORIGINS: [(KnownOrigin, &str); 6] = [
    (KnownOrigin::ThisDevice, "this_device"),
    (KnownOrigin::Imported, "imported"),
    (KnownOrigin::Synced, "synced"),
    (KnownOrigin::Link, "link"),
    (KnownOrigin::LinkedFolder, "linked_folder"),
    (KnownOrigin::TeamLibrary, "team_library"),
];

fn origin_name(origin: &ConnectionOrigin) -> String {
    match origin {
        ConnectionOrigin::Known(known) => ORIGINS
            .iter()
            .find(|(each, _)| each == known)
            .map_or_else(String::new, |(_, name)| (*name).to_owned()),
        ConnectionOrigin::Other(name) => name.clone(),
    }
}

fn origin_from(name: &str) -> ConnectionOrigin {
    match ORIGINS.iter().find(|(_, each)| *each == name) {
        Some((known, _)) => ConnectionOrigin::Known(*known),
        None if name.is_empty() => ConnectionOrigin::default(),
        None => ConnectionOrigin::Other(name.to_owned()),
    }
}

impl From<&DeviceOnly> for DeviceSettingsRecord {
    fn from(device: &DeviceOnly) -> Self {
        Self {
            local_only: device.local_only,
            is_sample: device.is_sample,
            origin: origin_name(&device.origin),
            password_source: device.password_source.as_ref().map(|source| match source {
                LocalPasswordSource::File { path } => LocalPasswordSourceRecord::File {
                    path: path.display().to_string(),
                },
                LocalPasswordSource::Command { shell, reuse_seconds } => LocalPasswordSourceRecord::Command {
                    shell: shell.clone(),
                    reuse_seconds: *reuse_seconds,
                },
            }),
            cloudflare_tunnel: device.cloudflare_tunnel.as_ref().map(|tunnel| CloudflareTunnelRecord {
                access_hostname: tunnel.access_hostname.clone(),
                local_port: tunnel.local_port,
                auth_method: match tunnel.auth_method {
                    CloudflareAuth::BrowserSso => CloudflareAuthTag::BrowserSso,
                    CloudflareAuth::ServiceToken => CloudflareAuthTag::ServiceToken,
                },
                expose_to_lan: tunnel.expose_to_lan,
                binary_path: tunnel.binary_path.clone(),
            }),
            cloud_sql_proxy: device.cloud_sql_proxy.as_ref().map(|proxy| CloudSqlProxyRecord {
                instance_connection_name: proxy.instance_connection_name.clone(),
                auth_mode: match proxy.auth_mode {
                    CloudSqlAuth::ApplicationDefault => CloudSqlAuthTag::ApplicationDefault,
                    CloudSqlAuth::ServiceAccountKey => CloudSqlAuthTag::ServiceAccountKey,
                },
                use_iam_auth: proxy.use_iam_auth,
                use_private_ip: proxy.use_private_ip,
                local_port: proxy.local_port,
                binary_path: proxy.binary_path.clone(),
            }),
            socks_proxy: device.socks_proxy.as_ref().map(|proxy| SocksProxyRecord {
                host: proxy.host.clone(),
                port: proxy.port,
                username: proxy.username.clone(),
            }),
            tunnel_command: device.tunnel_command.as_ref().map(|command| TunnelCommandRecord {
                method: match command.method {
                    TunnelCommandMethod::Kubectl => TunnelCommandMethodTag::Kubectl,
                    TunnelCommandMethod::AwsSsm => TunnelCommandMethodTag::AwsSsm,
                    TunnelCommandMethod::Custom => TunnelCommandMethodTag::Custom,
                },
                command: command.command.clone(),
                executable_path: command.executable_path.clone(),
                kubernetes_namespace: command.kubernetes_namespace.clone(),
                kubernetes_resource: command.kubernetes_resource.clone(),
                kubernetes_context: command.kubernetes_context.clone(),
                aws_target: command.aws_target.clone(),
                aws_profile: command.aws_profile.clone(),
                aws_region: command.aws_region.clone(),
            }),
            tls_mode_unsettled: device.tls_mode_unsettled,
            ssh_profile_unlinked: device.ssh_profile_unlinked,
        }
    }
}

impl From<DeviceSettingsRecord> for DeviceOnly {
    fn from(record: DeviceSettingsRecord) -> Self {
        Self {
            local_only: record.local_only,
            is_sample: record.is_sample,
            origin: origin_from(&record.origin),
            password_source: record.password_source.map(LocalPasswordSource::from),
            cloudflare_tunnel: record.cloudflare_tunnel.map(|tunnel| CloudflareTunnel {
                access_hostname: tunnel.access_hostname,
                local_port: tunnel.local_port,
                auth_method: match tunnel.auth_method {
                    CloudflareAuthTag::BrowserSso => CloudflareAuth::BrowserSso,
                    CloudflareAuthTag::ServiceToken => CloudflareAuth::ServiceToken,
                },
                expose_to_lan: tunnel.expose_to_lan,
                binary_path: tunnel.binary_path,
            }),
            cloud_sql_proxy: record.cloud_sql_proxy.map(|proxy| CloudSqlProxy {
                instance_connection_name: proxy.instance_connection_name,
                auth_mode: match proxy.auth_mode {
                    CloudSqlAuthTag::ApplicationDefault => CloudSqlAuth::ApplicationDefault,
                    CloudSqlAuthTag::ServiceAccountKey => CloudSqlAuth::ServiceAccountKey,
                },
                use_iam_auth: proxy.use_iam_auth,
                use_private_ip: proxy.use_private_ip,
                local_port: proxy.local_port,
                binary_path: proxy.binary_path,
            }),
            socks_proxy: record.socks_proxy.map(|proxy| SocksProxy {
                host: proxy.host,
                port: proxy.port,
                username: proxy.username,
            }),
            tunnel_command: record.tunnel_command.map(|command| TunnelCommand {
                method: match command.method {
                    TunnelCommandMethodTag::Kubectl => TunnelCommandMethod::Kubectl,
                    TunnelCommandMethodTag::AwsSsm => TunnelCommandMethod::AwsSsm,
                    TunnelCommandMethodTag::Custom => TunnelCommandMethod::Custom,
                },
                command: command.command,
                executable_path: command.executable_path,
                kubernetes_namespace: command.kubernetes_namespace,
                kubernetes_resource: command.kubernetes_resource,
                kubernetes_context: command.kubernetes_context,
                aws_target: command.aws_target,
                aws_profile: command.aws_profile,
                aws_region: command.aws_region,
            }),
            tls_mode_unsettled: record.tls_mode_unsettled,
            ssh_profile_unlinked: record.ssh_profile_unlinked,
        }
    }
}

impl From<LocalPasswordSourceRecord> for LocalPasswordSource {
    fn from(record: LocalPasswordSourceRecord) -> Self {
        match record {
            LocalPasswordSourceRecord::File { path } => Self::File {
                path: PathBuf::from(path),
            },
            LocalPasswordSourceRecord::Command { shell, reuse_seconds } => Self::Command { shell, reuse_seconds },
        }
    }
}

impl From<&SshProfile> for SshProfileRecord {
    fn from(profile: &SshProfile) -> Self {
        Self {
            id: profile.id.to_string(),
            name: profile.name.clone(),
            ssh: ssh_settings(&profile.ssh),
        }
    }
}

impl From<&CredentialProfile> for CredentialProfileRecord {
    fn from(profile: &CredentialProfile) -> Self {
        Self {
            id: profile.id.to_string(),
            name: profile.name.clone(),
            username: profile.username.clone(),
            password: match &profile.password {
                CredentialPassword::Stored => CredentialPasswordRecord::Stored,
                CredentialPassword::Prompt => CredentialPasswordRecord::Prompt,
                CredentialPassword::Pgpass => CredentialPasswordRecord::Pgpass,
                CredentialPassword::Reference { reference } => CredentialPasswordRecord::Reference {
                    reference: CredentialReferenceRecord::from(reference),
                },
                CredentialPassword::Local { source } => CredentialPasswordRecord::Local {
                    source: match source {
                        LocalPasswordSource::File { path } => LocalPasswordSourceRecord::File {
                            path: path.display().to_string(),
                        },
                        LocalPasswordSource::Command { shell, reuse_seconds } => LocalPasswordSourceRecord::Command {
                            shell: shell.clone(),
                            reuse_seconds: *reuse_seconds,
                        },
                    },
                },
            },
            secure_field_ids: profile.secure_field_ids.clone(),
            order: profile.order,
        }
    }
}

impl From<CredentialPasswordRecord> for CredentialPassword {
    fn from(record: CredentialPasswordRecord) -> Self {
        match record {
            CredentialPasswordRecord::Stored => Self::Stored,
            CredentialPasswordRecord::Prompt => Self::Prompt,
            CredentialPasswordRecord::Pgpass => Self::Pgpass,
            CredentialPasswordRecord::Reference { reference } => Self::Reference {
                reference: CredentialReference::from(reference),
            },
            CredentialPasswordRecord::Local { source } => Self::Local {
                source: LocalPasswordSource::from(source),
            },
        }
    }
}
