use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

/// What a connection carries beyond where and how the core connects it: what runs and what is sent
/// from it, the profiles it links to and the fields its engine's plugin declares. An app that has no
/// use for one keeps it, so a connection another device saved comes back unchanged.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionDetails {
    /// SQL run on every new session of the connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub startup_sql: Option<String>,
    /// What the AI assistant is told about this connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai_rules: Option<String>,
    /// The assistant's tools that run here without asking.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub ai_allowed_tools: BTreeSet<String>,
    /// The SSH profile the tunnel follows; `ssh` holds what it was when last applied.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_profile_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_route: Option<SshRoute>,
    /// The credential profile whose user and password the connection signs in with.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_profile_id: Option<Uuid>,
    /// Where the password comes from instead of the secret store.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_reference: Option<CredentialReference>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub redis_database: Option<u32>,
    /// Fields a driver plugin declares, by the field id the driver reads. `field_trust` classes each.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub additional_fields: BTreeMap<String, String>,
}

impl ConnectionDetails {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

/// What never leaves this device: no export, link or sync carries it, and an import or a pull
/// keeps the device's own.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceOnly {
    /// Kept out of sync by the person.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub local_only: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_sample: bool,
    #[serde(default, skip_serializing_if = "ConnectionOrigin::is_this_device")]
    pub origin: ConnectionOrigin,
    /// A file or command that gives the password. It can run anything, so only this device's person sets it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password_source: Option<LocalPasswordSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloudflare_tunnel: Option<CloudflareTunnel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloud_sql_proxy: Option<CloudSqlProxy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socks_proxy: Option<SocksProxy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tunnel_command: Option<TunnelCommand>,
}

impl DeviceOnly {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

/// The route a Mac dialed for the connection after reading its `~/.ssh/config`, so a device without
/// that file reaches the same hops. `basis` digests the tunnel settings it was dialed from; once they
/// change, the route no longer applies.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshRoute {
    pub version: u32,
    pub publisher: Uuid,
    pub basis: String,
    #[serde(default)]
    pub hops: Vec<SshRouteHop>,
    pub target: SshRouteTarget,
    #[serde(flatten)]
    pub unknown: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshRouteHop {
    pub id: Uuid,
    pub alias: String,
    pub host: String,
    pub port: u16,
    pub username: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshRouteTarget {
    pub alias: String,
    pub host: String,
    pub port: u16,
    pub username: String,
}

/// A password kept elsewhere, named by data and never by a command or a file (core ADR 0044,
/// Secrets). A device resolves it with its own person's identity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CredentialReference {
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        json_key: Option<String>,
    },
    VaultDatabaseRole(VaultDatabaseRole),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VaultDatabaseRole {
    /// The Vault server, or the environment's when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    pub mount: String,
    pub role: String,
    pub auth: VaultAuth,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum VaultAuth {
    Token,
    AppRole {
        mount: String,
        role_id: String,
        secret_id_path: PathBuf,
    },
    Oidc {
        mount: String,
        role: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LocalPasswordSource {
    File {
        path: PathBuf,
    },
    Command {
        shell: String,
        /// How long a password the command gave is used again, in seconds.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reuse_seconds: Option<u32>,
    },
}

/// Where a connection came from. A value a newer build wrote is kept as it was.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ConnectionOrigin {
    Known(KnownOrigin),
    Other(String),
}

impl Default for ConnectionOrigin {
    fn default() -> Self {
        Self::Known(KnownOrigin::ThisDevice)
    }
}

impl ConnectionOrigin {
    pub fn is_this_device(&self) -> bool {
        *self == Self::Known(KnownOrigin::ThisDevice)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KnownOrigin {
    ThisDevice,
    Imported,
    Synced,
    Link,
    LinkedFolder,
    TeamLibrary,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudflareTunnel {
    pub access_hostname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_port: Option<u16>,
    pub auth_method: CloudflareAuth,
    #[serde(default)]
    pub expose_to_lan: bool,
    /// The `cloudflared` to run, or the one on the search path when empty.
    #[serde(default)]
    pub binary_path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloudflareAuth {
    BrowserSso,
    ServiceToken,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudSqlProxy {
    pub instance_connection_name: String,
    pub auth_mode: CloudSqlAuth,
    #[serde(default)]
    pub use_iam_auth: bool,
    #[serde(default)]
    pub use_private_ip: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_port: Option<u16>,
    #[serde(default)]
    pub binary_path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloudSqlAuth {
    ApplicationDefault,
    ServiceAccountKey,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SocksProxy {
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub username: String,
}

/// A command that opens the tunnel before connecting, such as `kubectl port-forward`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TunnelCommand {
    pub method: TunnelCommandMethod,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub executable_path: String,
    #[serde(default)]
    pub kubernetes_namespace: String,
    #[serde(default)]
    pub kubernetes_resource: String,
    #[serde(default)]
    pub kubernetes_context: String,
    #[serde(default)]
    pub aws_target: String,
    #[serde(default)]
    pub aws_profile: String,
    #[serde(default)]
    pub aws_region: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TunnelCommandMethod {
    Kubectl,
    AwsSsm,
    Custom,
}

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]
mod tests {
    use super::*;

    #[test]
    fn an_origin_a_newer_build_wrote_is_kept() {
        let origin: ConnectionOrigin = serde_json::from_str(r#""shared_vault""#).unwrap();

        assert_eq!(origin, ConnectionOrigin::Other("shared_vault".to_owned()));
        assert_eq!(serde_json::to_string(&origin).unwrap(), r#""shared_vault""#);
    }

    #[test]
    fn a_known_origin_reads_as_itself() {
        let origin: ConnectionOrigin = serde_json::from_str(r#""team_library""#).unwrap();

        assert_eq!(origin, ConnectionOrigin::Known(KnownOrigin::TeamLibrary));
    }

    #[test]
    fn a_vault_role_names_its_kind_beside_its_fields() {
        let reference = CredentialReference::VaultDatabaseRole(VaultDatabaseRole {
            address: None,
            mount: "database".to_owned(),
            role: "readonly".to_owned(),
            auth: VaultAuth::Oidc {
                mount: "oidc".to_owned(),
                role: "dev".to_owned(),
            },
        });

        let value = serde_json::to_value(&reference).unwrap();

        assert_eq!(
            value,
            serde_json::json!({
                "kind": "vault_database_role",
                "mount": "database",
                "role": "readonly",
                "auth": {"method": "oidc", "mount": "oidc", "role": "dev"}
            })
        );
        assert_eq!(serde_json::from_value::<CredentialReference>(value).unwrap(), reference);
    }
}
