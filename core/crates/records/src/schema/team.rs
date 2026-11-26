// The team library's kinds keep the keys the library and the facade already use: a folder's and a query's from
// `/v2` (0044, The library moves in), and a connection's from the bundle shipped Macs publish (`ExportableConnection`).

use super::Approval::{Always, Looser};
use super::Class::{Approval, ByEntry, Dropped, Inert};
use super::Role::{Content, Placement};
use super::personal::{AI_POLICIES, SAFE_MODE_LEVELS, SSL_MODES};
use super::{Field, Type};

const fn field(key: &'static str, ty: Type, class: super::Class) -> Field {
    Field {
        key,
        ty,
        class,
        role: Content,
    }
}

const fn placed(key: &'static str, ty: Type) -> Field {
    Field {
        key,
        ty,
        class: Inert,
        role: Placement,
    }
}

const DESTINATION: super::Class = Approval(Always);
const TEXT: Type = Type::Text;

pub const LIBRARY_FOLDER: &[Field] = &[
    field("name", Type::Text, Inert),
    placed("parent_client_id", Type::Text),
    placed("sort_order", Type::Integer),
];

pub const LIBRARY_QUERY: &[Field] = &[
    field("name", Type::Text, Inert),
    field("query", Type::Text, Inert),
    field("keyword", Type::Text, Inert),
    placed("folder_client_id", Type::Text),
    field("connection_client_id", Type::Text, Inert),
    placed("sort_order", Type::Integer),
];

const BUNDLE_JUMP_HOST: &[Field] = &[
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("authMethod", Type::Text, DESTINATION),
    field("privateKeyPath", Type::Text, DESTINATION),
];

pub const BUNDLE_SSH_CONFIG: &[Field] = &[
    field("enabled", Type::Boolean, DESTINATION),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("authMethod", Type::Text, DESTINATION),
    field("privateKeyPath", Type::Text, DESTINATION),
    field("agentSocketPath", Type::Text, DESTINATION),
    field("jumpHosts", Type::List(&Type::Object(BUNDLE_JUMP_HOST)), DESTINATION),
    field("totpMode", Type::Text, Inert),
    field("totpAlgorithm", Type::Text, Inert),
    field("totpDigits", Type::Integer, Inert),
    field("totpPeriod", Type::Integer, Inert),
    field("remoteFilePath", Type::Text, DESTINATION),
    field("remoteFileAccess", Type::Text, DESTINATION),
];

pub const BUNDLE_SSL_CONFIG: &[Field] = &[
    field("mode", Type::Enum(SSL_MODES), DESTINATION),
    field("caCertificatePath", Type::Text, DESTINATION),
    field("clientCertificatePath", Type::Text, DESTINATION),
    field("clientKeyPath", Type::Text, DESTINATION),
];

const TUNNEL_COMMAND: &[Field] = &[
    field("method", Type::Text, Dropped),
    field("command", Type::Text, Dropped),
    field("executablePath", Type::Text, Dropped),
    field("kubernetesNamespace", Type::Text, Dropped),
    field("kubernetesResource", Type::Text, Dropped),
    field("kubernetesContext", Type::Text, Dropped),
    field("awsTarget", Type::Text, Dropped),
    field("awsProfile", Type::Text, Dropped),
    field("awsRegion", Type::Text, Dropped),
];

pub const LIBRARY_CONNECTION: &[Field] = &[
    field("name", Type::Text, Inert),
    field("type", Type::Text, DESTINATION),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("database", Type::Text, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("sshConfig", Type::Object(BUNDLE_SSH_CONFIG), DESTINATION),
    field("sslConfig", Type::Object(BUNDLE_SSL_CONFIG), DESTINATION),
    field("color", Type::Text, Inert),
    field("iconName", Type::Text, Inert),
    field("sshProfileId", Type::Text, DESTINATION),
    field(
        "safeModeLevel",
        Type::Enum(SAFE_MODE_LEVELS),
        Approval(Looser(SAFE_MODE_LEVELS)),
    ),
    field("aiPolicy", Type::Enum(AI_POLICIES), Approval(Looser(AI_POLICIES))),
    field("connectTimeoutSeconds", Type::Integer, Inert),
    field("queryTimeoutSeconds", Type::Integer, Inert),
    field("additionalFields", Type::Map(&TEXT), ByEntry),
    field("redisDatabase", Type::Integer, DESTINATION),
    // 0044, Fields a pull applies only with approval: a team drops these on pull.
    field("startupCommands", Type::Text, Dropped),
    field("tunnelCommand", Type::Object(TUNNEL_COMMAND), Dropped),
    field("localOnly", Type::Boolean, Dropped),
];
