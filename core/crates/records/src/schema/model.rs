// Where each member of the core's store models goes on the wire. A member a store gains with no row here fails the
// coverage test, and so counts as approval-required until it is classed (0044).

use crate::kind::Kind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    // The record id carries it.
    Id,
    // This member of the kind's wire schema, as a dotted path; for a history entry, of its sealed `entry`.
    Wire(&'static str),
    // Never pushed.
    DeviceOnly,
    // Keys a newer build wrote, kept and sent back as they came (0054, The engine).
    Kept,
}

use Target::{DeviceOnly, Id, Kept, Wire};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Model {
    pub name: &'static str,
    pub kind: Kind,
    pub members: &'static [(&'static str, Target)],
}

// `tablepro_storage::SavedConnection`. A tunnel switched off keeps its settings in `ssh_config`.
const SAVED_CONNECTION: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("driver_id", Wire("type")),
    ("host", Wire("host")),
    ("port", Wire("port")),
    ("database", Wire("database")),
    ("username", Wire("username")),
    ("tls.mode", Wire("ssl_config.mode")),
    ("tls.ca_file", Wire("ssl_config.ca_certificate_path")),
    (
        "tls.client_identity.certificate",
        Wire("ssl_config.client_certificate_path"),
    ),
    ("tls.client_identity.key", Wire("ssl_config.client_key_path")),
    ("tls.server_name", Wire("ssl_config.server_name")),
    ("tls.unknown", Kept),
    ("safe_mode", Wire("safe_mode_level")),
    ("external_access", Wire("external_access")),
    ("ai_policy", Wire("ai_policy")),
    ("query_timeout_secs", Wire("query_timeout_seconds")),
    ("auth_mode", Wire("auth_mode")),
    ("ssh", Wire("ssh_config")),
    ("ssh.enabled", Wire("ssh_config.enabled")),
    ("ssh.host", Wire("ssh_config.host")),
    ("ssh.port", Wire("ssh_config.port")),
    ("ssh.username", Wire("ssh_config.username")),
    ("ssh.jump_hosts.id", Wire("ssh_config.jump_hosts.id")),
    ("ssh.jump_hosts.host", Wire("ssh_config.jump_hosts.host")),
    ("ssh.jump_hosts.port", Wire("ssh_config.jump_hosts.port")),
    ("ssh.jump_hosts.username", Wire("ssh_config.jump_hosts.username")),
    ("ssh.jump_hosts.auth", Wire("ssh_config.jump_hosts.auth_method")),
    (
        "ssh.jump_hosts.key_path",
        Wire("ssh_config.jump_hosts.private_key_path"),
    ),
    ("ssh.auth.kind", Wire("ssh_config.auth_method")),
    ("ssh.auth.path", Wire("ssh_config.private_key_path")),
    ("ssh.auth.has_passphrase", Wire("ssh_config.passphrase_stored")),
    ("ssh.kept_key_path", Wire("ssh_config.private_key_path")),
    ("ssh.agent_socket", Wire("ssh_config.agent_socket_path")),
    ("ssh.totp.mode", Wire("ssh_config.totp_mode")),
    ("ssh.totp.algorithm", Wire("ssh_config.totp_algorithm")),
    ("ssh.totp.digits", Wire("ssh_config.totp_digits")),
    ("ssh.totp.period", Wire("ssh_config.totp_period")),
    ("ssh.remote_file.path", Wire("ssh_config.remote_file_path")),
    ("ssh.remote_file.access", Wire("ssh_config.remote_file_access")),
    ("ssh.unknown", Kept),
    ("last_opened_at", DeviceOnly),
    ("color", Wire("color")),
    ("group_id", Wire("group_id")),
    ("order", Wire("sort_order")),
    ("tags", Wire("tag_ids")),
    ("icon", Wire("icon_name")),
    ("options.dns_seed_list", Wire("network_options.dns_seed_list")),
    ("options.auth_database", Wire("network_options.auth_database")),
    ("options.replica_set", Wire("network_options.replica_set")),
    ("options.more_hosts", Wire("network_options.more_hosts")),
    ("options.channel_binding", Wire("network_options.channel_binding")),
    ("details.startup_sql", Wire("startup_commands")),
    ("details.ai_rules", Wire("ai_rules")),
    ("details.ai_allowed_tools", Wire("ai_always_allowed_tools")),
    ("details.ssh_profile_id", Wire("ssh_profile_id")),
    ("details.ssh_route", Wire("ssh_route")),
    ("details.credential_profile_id", Wire("credential_profile_id")),
    ("details.credential_reference", Wire("credential_reference")),
    ("details.redis_database", Wire("redis_database")),
    ("details.additional_fields", Wire("additional_fields")),
    ("device.local_only", DeviceOnly),
    ("device.is_sample", DeviceOnly),
    ("device.origin", DeviceOnly),
    ("device.password_source", DeviceOnly),
    ("device.cloudflare_tunnel", DeviceOnly),
    ("device.cloud_sql_proxy", DeviceOnly),
    ("device.socks_proxy", DeviceOnly),
    ("device.tunnel_command", DeviceOnly),
    ("unknown", Kept),
];

// `tablepro_storage::SshProfile`. A kept passphrase is this device's to know; a profile is never off and opens no file.
const SSH_PROFILE: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("ssh.enabled", DeviceOnly),
    ("ssh.host", Wire("host")),
    ("ssh.port", Wire("port")),
    ("ssh.username", Wire("username")),
    ("ssh.jump_hosts.id", Wire("jump_hosts.id")),
    ("ssh.jump_hosts.host", Wire("jump_hosts.host")),
    ("ssh.jump_hosts.port", Wire("jump_hosts.port")),
    ("ssh.jump_hosts.username", Wire("jump_hosts.username")),
    ("ssh.jump_hosts.auth", Wire("jump_hosts.auth_method")),
    ("ssh.jump_hosts.key_path", Wire("jump_hosts.private_key_path")),
    ("ssh.auth.kind", Wire("auth_method")),
    ("ssh.auth.path", Wire("private_key_path")),
    ("ssh.auth.has_passphrase", DeviceOnly),
    ("ssh.kept_key_path", Wire("private_key_path")),
    ("ssh.agent_socket", Wire("agent_socket_path")),
    ("ssh.totp.mode", Wire("totp_mode")),
    ("ssh.totp.algorithm", Wire("totp_algorithm")),
    ("ssh.totp.digits", Wire("totp_digits")),
    ("ssh.totp.period", Wire("totp_period")),
    ("ssh.remote_file.path", DeviceOnly),
    ("ssh.remote_file.access", DeviceOnly),
    ("ssh.unknown", Kept),
];

// `tablepro_storage::CredentialProfile`. A password source, a reference included, never leaves the device, as on
// the Mac; the mode does.
const CREDENTIAL_PROFILE: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("username", Wire("username")),
    ("password.mode", Wire("password_mode")),
    ("password.reference", DeviceOnly),
    ("password.source", DeviceOnly),
    ("secure_field_ids", Wire("secure_field_ids")),
    ("order", Wire("sort_order")),
    ("unknown", Kept),
];

const TABLE_FOLDER: &[(&str, Target)] = &[
    ("id", Id),
    ("scope.connection_id", Wire("connection_id")),
    ("scope.database", Wire("database")),
    ("scope.schema", Wire("schema")),
    ("name", Wire("name")),
    ("created_at_ms", Wire("created_at")),
    ("updated_at_ms", Wire("updated_at")),
];

// The id is a digest of the table it files (0052, Derived ids).
const TABLE_FOLDER_ITEM: &[(&str, Target)] = &[
    ("table.connection_id", Wire("connection_id")),
    ("table.database", Wire("database")),
    ("table.schema", Wire("schema")),
    ("table.name", Wire("name")),
    ("folder_id", Wire("folder_id")),
];

const CONNECTION_GROUP: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("parent_id", Wire("parent_id")),
    ("order", Wire("sort_order")),
    ("color", Wire("color")),
    ("icon", Wire("icon_name")),
];

const CONNECTION_TAG: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("color", Wire("color")),
    ("is_preset", Wire("is_preset")),
];

const FAVOURITE_TABLE: &[(&str, Target)] = &[
    ("connection_id", Wire("connection_id")),
    ("database", Wire("database")),
    ("schema", Wire("schema")),
    ("name", Wire("name")),
];

const FAVOURITE_DATABASE: &[(&str, Target)] = &[
    ("connection_id", Wire("connection_id")),
    ("database", Wire("database")),
    ("environment", Wire("environment")),
];

// The connection's name is a display copy the store keeps beside the id.
const SAVED_QUERY: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("query", Wire("query")),
    ("connection_id", Wire("connection_id")),
    ("connection_name", DeviceOnly),
    ("keyword", Wire("keyword")),
    ("folder_id", Wire("folder_id")),
    ("order", Wire("sort_order")),
    ("created_at", Wire("created_at")),
    ("updated_at", Wire("updated_at")),
];

const SAVED_QUERY_FOLDER: &[(&str, Target)] = &[
    ("id", Id),
    ("connection_id", Wire("connection_id")),
    ("name", Wire("name")),
    ("parent_id", Wire("parent_id")),
    ("order", Wire("sort_order")),
    ("created_at", Wire("created_at")),
    ("updated_at", Wire("updated_at")),
];

// The rowid and pins stay on the device (0052, History).
const HISTORY_ENTRY: &[(&str, Target)] = &[
    ("id", DeviceOnly),
    ("record_id", Id),
    ("query", Wire("query")),
    ("driver_id", Wire("database_type")),
    ("connection_id", Wire("connection_id")),
    ("connection_name", Wire("connection_name")),
    ("executed_at", Wire("executed_at")),
    ("duration_ms", Wire("duration_ms")),
    ("rows_affected", Wire("row_count")),
    ("success", Wire("succeeded")),
    ("cancelled", Wire("cancelled")),
    ("pinned", DeviceOnly),
    ("error", Wire("error")),
];

pub const MODELS: &[Model] = &[
    Model {
        name: "SavedConnection",
        kind: Kind::Connection,
        members: SAVED_CONNECTION,
    },
    Model {
        name: "ConnectionGroup",
        kind: Kind::Group,
        members: CONNECTION_GROUP,
    },
    Model {
        name: "ConnectionTag",
        kind: Kind::Tag,
        members: CONNECTION_TAG,
    },
    Model {
        name: "SshProfile",
        kind: Kind::SshProfile,
        members: SSH_PROFILE,
    },
    Model {
        name: "CredentialProfile",
        kind: Kind::CredentialProfile,
        members: CREDENTIAL_PROFILE,
    },
    Model {
        name: "TableFolder",
        kind: Kind::TableFolder,
        members: TABLE_FOLDER,
    },
    Model {
        name: "TableFolderItem",
        kind: Kind::TableFolderItem,
        members: TABLE_FOLDER_ITEM,
    },
    Model {
        name: "FavouriteTable",
        kind: Kind::FavouriteTable,
        members: FAVOURITE_TABLE,
    },
    Model {
        name: "FavouriteDatabase",
        kind: Kind::FavouriteDatabase,
        members: FAVOURITE_DATABASE,
    },
    Model {
        name: "SavedQuery",
        kind: Kind::SavedQuery,
        members: SAVED_QUERY,
    },
    Model {
        name: "SavedQueryFolder",
        kind: Kind::SavedQueryFolder,
        members: SAVED_QUERY_FOLDER,
    },
    Model {
        name: "query_history::Entry",
        kind: Kind::HistoryEntry,
        members: HISTORY_ENTRY,
    },
];

pub fn model(name: &str) -> Option<&'static Model> {
    MODELS.iter().find(|model| model.name == name)
}
