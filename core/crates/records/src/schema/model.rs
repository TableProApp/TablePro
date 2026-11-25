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
}

use Target::{DeviceOnly, Id, Wire};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Model {
    pub name: &'static str,
    pub kind: Kind,
    pub members: &'static [(&'static str, Target)],
}

// `tablepro_storage::SavedConnection`. `ssh` present is `ssh_config.enabled`.
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
    ("safe_mode", Wire("safe_mode_level")),
    ("external_access", Wire("external_access")),
    ("ai_policy", Wire("ai_policy")),
    ("query_timeout_secs", Wire("query_timeout_seconds")),
    ("auth_mode", Wire("auth_mode")),
    ("ssh", Wire("ssh_config.enabled")),
    ("ssh.host", Wire("ssh_config.host")),
    ("ssh.port", Wire("ssh_config.port")),
    ("ssh.username", Wire("ssh_config.username")),
    ("ssh.jump_hosts", Wire("ssh_config.jump_hosts")),
    ("ssh.auth.kind", Wire("ssh_config.auth_method")),
    ("ssh.auth.path", Wire("ssh_config.private_key_path")),
    ("ssh.auth.has_passphrase", Wire("ssh_config.passphrase_stored")),
    ("last_opened_at", DeviceOnly),
    ("color", Wire("color")),
    ("group_id", Wire("group_id")),
    ("project_id", Wire("project_id")),
    ("order", Wire("sort_order")),
    ("tags", Wire("tag_ids")),
    ("icon", Wire("icon_name")),
    ("options.dns_seed_list", Wire("network_options.dns_seed_list")),
    ("options.auth_database", Wire("network_options.auth_database")),
    ("options.replica_set", Wire("network_options.replica_set")),
    ("options.more_hosts", Wire("network_options.more_hosts")),
    ("options.channel_binding", Wire("network_options.channel_binding")),
];

const CONNECTION_GROUP: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("parent_id", Wire("parent_id")),
    ("project_id", Wire("project_id")),
    ("order", Wire("sort_order")),
    ("color", Wire("color")),
    ("icon", Wire("icon_name")),
];

const CONNECTION_PROJECT: &[(&str, Target)] = &[
    ("id", Id),
    ("name", Wire("name")),
    ("order", Wire("sort_order")),
    ("color", Wire("color")),
    ("icon", Wire("icon_name")),
];

const CONNECTION_TAG: &[(&str, Target)] = &[("id", Id), ("name", Wire("name")), ("color", Wire("color"))];

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

// Pins stay on the device (0052, History).
const HISTORY_ENTRY: &[(&str, Target)] = &[
    ("id", Id),
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
        name: "ConnectionProject",
        kind: Kind::ConnectionProject,
        members: CONNECTION_PROJECT,
    },
    Model {
        name: "ConnectionTag",
        kind: Kind::Tag,
        members: CONNECTION_TAG,
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
