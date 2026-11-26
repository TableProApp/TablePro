// The personal kinds. A field CloudKit carries keeps its CloudKit name in snake case and its CloudKit values, so a
// move from iCloud maps names and nothing else. A map keyed by data, such as a driver's field ids, goes as a list of
// entries, since the server refuses a member whose name reads as a secret (0051, What syncs).

use super::Approval::{Always, Looser};
use super::Class::{Approval, ByEntry, DeviceOnly, Inert};
use super::Role::{Content, Placement};
use super::{Field, Type};
use crate::kind::Kind;

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

// A format stamp says how a record was written, not what it holds, so alone it revives nothing.
const SCHEMA_VERSION: Field = placed("schema_version", Type::Integer);

const TEXT: Type = Type::Text;

pub const COLORS: &[&str] = &[
    "None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Gray", "Teal",
];

// Strictest first, as the Mac's `SafeModeLevel.strictness` orders them.
pub const SAFE_MODE_LEVELS: &[&str] = &["readOnly", "safeModeFull", "safeMode", "alertFull", "alert", "silent"];

pub const AI_POLICIES: &[&str] = &["never", "askEachTime", "alwaysAllow"];

// The External Clients level (0036), strictest first.
pub const EXTERNAL_ACCESS: &[&str] = &["blocked", "readOnly", "readWrite"];

pub const SSL_MODES: &[&str] = &["Disabled", "Preferred", "Required", "Verify CA", "Verify Identity"];

// A connection's `type` is the Mac's `DatabaseType` name; these are the names of the engines the core links, by the
// core's driver id, as the Linux app's usage data names them. MariaDB runs on the MySQL driver and ScyllaDB on
// Cassandra's, so each reads as its driver's name.
pub const DRIVER_TYPES: &[(&str, &str)] = &[
    ("cassandra", "Cassandra"),
    ("clickhouse", "ClickHouse"),
    ("duckdb", "DuckDB"),
    ("mongodb", "MongoDB"),
    ("mssql", "SQL Server"),
    ("mysql", "MySQL"),
    ("postgres", "PostgreSQL"),
    ("redis", "Redis"),
    ("sqlite", "SQLite"),
];

// The wire's name for a core driver id; another id goes as it is.
pub fn wire_type(driver: &str) -> &str {
    DRIVER_TYPES
        .iter()
        .find(|(id, _)| *id == driver)
        .map_or(driver, |(_, name)| name)
}

// The core driver id for a wire name; a name no linked engine has stays as it is.
pub fn core_driver(name: &str) -> &str {
    DRIVER_TYPES
        .iter()
        .find(|(_, known)| *known == name)
        .map_or(name, |(id, _)| id)
}

const SSH_AUTH_METHODS: &[&str] = &["Password", "Private Key", "SSH Agent", "Keyboard Interactive", "None"];
const JUMP_AUTH_METHODS: &[&str] = &["Private Key", "SSH Agent"];
const TOTP_MODES: &[&str] = &["none", "auto_generate", "prompt_at_connect"];
const TOTP_ALGORITHMS: &[&str] = &["SHA1", "SHA256", "SHA512"];
const REMOTE_FILE_ACCESS: &[&str] = &["readOnlyCopy", "onServer"];
const PASSWORD_MODES: &[&str] = &["prompt", "stored", "pgpass"];
const ENVIRONMENTS: &[&str] = &["development", "testing", "production", "unassigned"];
const AUTH_MODES: &[&str] = &["password", "kerberos"];
// A reference to a secret held elsewhere (0044, Typed references). A file or a command never syncs.
const REFERENCE_KINDS: &[&str] = &["env", "onePassword", "vault", "awsSecretsManager", "vaultDatabaseRole"];
const VAULT_AUTH_METHODS: &[&str] = &["token", "approle", "oidc"];

const DESTINATION: super::Class = Approval(Always);

const JUMP_HOST: &[Field] = &[
    field("id", Type::Text, Inert),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("auth_method", Type::Enum(JUMP_AUTH_METHODS), DESTINATION),
    field("private_key_path", Type::Text, DESTINATION),
];

pub const SSH_CONFIG: &[Field] = &[
    field("enabled", Type::Boolean, DESTINATION),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("auth_method", Type::Enum(SSH_AUTH_METHODS), DESTINATION),
    field("private_key_path", Type::Text, DESTINATION),
    // Whether the key's passphrase is kept. The core's `has_passphrase`, which the server's secret rule refuses.
    field("passphrase_stored", Type::Boolean, Inert),
    field("agent_socket_path", Type::Text, DESTINATION),
    field("jump_hosts", Type::List(&Type::Object(JUMP_HOST)), DESTINATION),
    field("totp_mode", Type::Enum(TOTP_MODES), Inert),
    field("totp_algorithm", Type::Enum(TOTP_ALGORITHMS), Inert),
    field("totp_digits", Type::Integer, Inert),
    field("totp_period", Type::Integer, Inert),
    field(
        "remote_file_access",
        Type::Enum(REMOTE_FILE_ACCESS),
        Approval(Looser(REMOTE_FILE_ACCESS)),
    ),
    field("remote_file_path", Type::Text, DESTINATION),
];

pub const SSL_CONFIG: &[Field] = &[
    field("mode", Type::Enum(SSL_MODES), DESTINATION),
    field("ca_certificate_path", Type::Text, DESTINATION),
    field("client_certificate_path", Type::Text, DESTINATION),
    field("client_key_path", Type::Text, DESTINATION),
    field("server_name", Type::Text, DESTINATION),
];

// The route a Mac resolved from its SSH configuration and published (`PublishedSSHRoute`).
const ROUTE_HOP: &[Field] = &[
    field("alias", Type::Text, DESTINATION),
    field("host", Type::Text, DESTINATION),
    field("id", Type::Text, Inert),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
];

const ROUTE_TARGET: &[Field] = &[
    field("alias", Type::Text, DESTINATION),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
];

const SSH_ROUTE: &[Field] = &[
    field("basis", Type::Text, DESTINATION),
    field("hops", Type::List(&Type::Object(ROUTE_HOP)), DESTINATION),
    field("publisher", Type::Text, Inert),
    field("target", Type::Object(ROUTE_TARGET), DESTINATION),
    field("version", Type::Integer, Inert),
];

const VAULT_AUTH: &[Field] = &[
    field("method", Type::Enum(VAULT_AUTH_METHODS), DESTINATION),
    field("mount", Type::Text, DESTINATION),
    field("role_id", Type::Text, DESTINATION),
    field("secret_id_path", Type::Text, DESTINATION),
    field("role", Type::Text, DESTINATION),
];

const CREDENTIAL_REFERENCE: &[Field] = &[
    field("kind", Type::Enum(REFERENCE_KINDS), DESTINATION),
    field("variable", Type::Text, DESTINATION),
    field("reference", Type::Text, DESTINATION),
    field("path", Type::Text, DESTINATION),
    field("field", Type::Text, DESTINATION),
    field("secret_id", Type::Text, DESTINATION),
    field("json_key", Type::Text, DESTINATION),
    field("address", Type::Text, DESTINATION),
    field("mount", Type::Text, DESTINATION),
    field("role", Type::Text, DESTINATION),
    field("auth", Type::Object(VAULT_AUTH), DESTINATION),
];

const NETWORK_OPTIONS: &[Field] = &[
    field("dns_seed_list", Type::Boolean, DESTINATION),
    field("auth_database", Type::Text, DESTINATION),
    field("replica_set", Type::Text, DESTINATION),
    field("more_hosts", Type::List(&TEXT), DESTINATION),
    field("channel_binding", Type::Boolean, DESTINATION),
];

pub const CONNECTION: &[Field] = &[
    field("name", Type::Text, Inert),
    field("type", Type::Text, DESTINATION),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("database", Type::Text, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("color", Type::Enum(COLORS), Inert),
    field("icon_name", Type::Text, Inert),
    field(
        "safe_mode_level",
        Type::Enum(SAFE_MODE_LEVELS),
        Approval(Looser(SAFE_MODE_LEVELS)),
    ),
    placed("sort_order", Type::Integer),
    placed("group_id", Type::Reference(Kind::Group)),
    placed("project_id", Type::Reference(Kind::ConnectionProject)),
    placed("is_favorite", Type::Boolean),
    field("tag_ids", Type::List(&Type::Reference(Kind::Tag)), Inert),
    field("query_timeout_seconds", Type::Integer, Inert),
    field("ssh_config", Type::Object(SSH_CONFIG), DESTINATION),
    field("ssl_config", Type::Object(SSL_CONFIG), DESTINATION),
    // Each driver field by its id.
    field("additional_fields", Type::Entries(&TEXT), ByEntry),
    field("ai_policy", Type::Enum(AI_POLICIES), Approval(Looser(AI_POLICIES))),
    field("ai_rules", Type::Text, Approval(Always)),
    field("ai_always_allowed_tools", Type::List(&TEXT), Approval(Always)),
    field("redis_database", Type::Integer, DESTINATION),
    field("startup_commands", Type::Text, Approval(Always)),
    field("ssh_profile_id", Type::Reference(Kind::SshProfile), DESTINATION),
    field("ssh_route", Type::Object(SSH_ROUTE), DESTINATION),
    // TablePro Sync only: iCloud carries none of these (0054).
    field(
        "external_access",
        Type::Enum(EXTERNAL_ACCESS),
        Approval(Looser(EXTERNAL_ACCESS)),
    ),
    field(
        "credential_profile_id",
        Type::Reference(Kind::CredentialProfile),
        DESTINATION,
    ),
    field("credential_reference", Type::Object(CREDENTIAL_REFERENCE), DESTINATION),
    field("auth_mode", Type::Enum(AUTH_MODES), DESTINATION),
    field("network_options", Type::Object(NETWORK_OPTIONS), DESTINATION),
    SCHEMA_VERSION,
    // What stays on the device (0044, What syncs, Never).
    field("last_opened_at", Type::Millis, DeviceOnly),
    field("local_only", Type::Boolean, DeviceOnly),
    field("is_sample", Type::Boolean, DeviceOnly),
    field("origin", Type::Text, DeviceOnly),
    field("password_source", Type::Text, DeviceOnly),
    field("ssh_tunnel_mode", Type::Text, DeviceOnly),
    field("cloudflare_tunnel_mode", Type::Text, DeviceOnly),
    field("cloud_sql_proxy_mode", Type::Text, DeviceOnly),
    field("socks_proxy_mode", Type::Text, DeviceOnly),
    field("tunnel_command_mode", Type::Text, DeviceOnly),
    // The device's marks on a copy an earlier iOS build wrote, which the engine reads against the base.
    field("tls_mode_unsettled", Type::Boolean, DeviceOnly),
    field("ssh_profile_unlinked", Type::Boolean, DeviceOnly),
    // This device's id, which names the SSH routes it publishes, so the engine knows a route it may clear.
    field("route_publisher", Type::Text, DeviceOnly),
];

pub const GROUP: &[Field] = &[
    field("name", Type::Text, Inert),
    field("color", Type::Enum(COLORS), Inert),
    field("icon_name", Type::Text, Inert),
    placed("parent_id", Type::Reference(Kind::Group)),
    placed("sort_order", Type::Integer),
    placed("project_id", Type::Reference(Kind::ConnectionProject)),
    SCHEMA_VERSION,
];

pub const TAG: &[Field] = &[
    field("name", Type::Text, Inert),
    field("color", Type::Enum(COLORS), Inert),
    field("is_preset", Type::Boolean, Inert),
    SCHEMA_VERSION,
];

pub const SSH_PROFILE: &[Field] = &[
    field("name", Type::Text, Inert),
    field("host", Type::Text, DESTINATION),
    field("port", Type::Integer, DESTINATION),
    field("username", Type::Text, DESTINATION),
    field("auth_method", Type::Enum(SSH_AUTH_METHODS), DESTINATION),
    field("private_key_path", Type::Text, DESTINATION),
    field("agent_socket_path", Type::Text, DESTINATION),
    field("jump_hosts", Type::List(&Type::Object(JUMP_HOST)), DESTINATION),
    field("totp_mode", Type::Enum(TOTP_MODES), Inert),
    field("totp_algorithm", Type::Enum(TOTP_ALGORITHMS), Inert),
    field("totp_digits", Type::Integer, Inert),
    field("totp_period", Type::Integer, Inert),
    SCHEMA_VERSION,
];

pub const CREDENTIAL_PROFILE: &[Field] = &[
    field("name", Type::Text, Inert),
    field("username", Type::Text, DESTINATION),
    field("password_mode", Type::Enum(PASSWORD_MODES), Approval(Always)),
    field("secure_field_ids", Type::List(&TEXT), Inert),
    placed("sort_order", Type::Integer),
    SCHEMA_VERSION,
];

// `updated_at` moves with whichever edit made it, so alone it revives nothing.
pub const SAVED_QUERY: &[Field] = &[
    field("name", Type::Text, Inert),
    field("query", Type::Text, Inert),
    field("keyword", Type::Text, Inert),
    field("connection_id", Type::Reference(Kind::Connection), Inert),
    placed("folder_id", Type::Reference(Kind::SavedQueryFolder)),
    placed("sort_order", Type::Integer),
    field("created_at", Type::Millis, Inert),
    placed("updated_at", Type::Millis),
    SCHEMA_VERSION,
];

pub const SAVED_QUERY_FOLDER: &[Field] = &[
    field("name", Type::Text, Inert),
    field("connection_id", Type::Reference(Kind::Connection), Inert),
    placed("parent_id", Type::Reference(Kind::SavedQueryFolder)),
    placed("sort_order", Type::Integer),
    field("created_at", Type::Millis, Inert),
    placed("updated_at", Type::Millis),
    SCHEMA_VERSION,
];

// A favourite's id is a digest of what it names, so its fields carry the names (0052, Long ids).
pub const FAVOURITE_TABLE: &[Field] = &[
    field("connection_id", Type::Reference(Kind::Connection), Inert),
    field("database", Type::Text, Inert),
    field("schema", Type::Text, Inert),
    field("name", Type::Text, Inert),
    SCHEMA_VERSION,
];

pub const FAVOURITE_DATABASE: &[Field] = &[
    field("connection_id", Type::Reference(Kind::Connection), Inert),
    field("database", Type::Text, Inert),
    field("environment", Type::Enum(ENVIRONMENTS), Inert),
    SCHEMA_VERSION,
];

pub const TABLE_FOLDER: &[Field] = &[
    field("connection_id", Type::Reference(Kind::Connection), Inert),
    field("database", Type::Text, Inert),
    field("schema", Type::Text, Inert),
    field("name", Type::Text, Inert),
    field("created_at", Type::Millis, Inert),
    placed("updated_at", Type::Millis),
    SCHEMA_VERSION,
];

pub const TABLE_FOLDER_ITEM: &[Field] = &[
    field("connection_id", Type::Reference(Kind::Connection), Inert),
    field("database", Type::Text, Inert),
    field("schema", Type::Text, Inert),
    field("name", Type::Text, Inert),
    placed("folder_id", Type::Reference(Kind::TableFolder)),
    SCHEMA_VERSION,
];

pub const CONNECTION_PROJECT: &[Field] = &[
    field("name", Type::Text, Inert),
    field("color", Type::Enum(COLORS), Inert),
    field("icon_name", Type::Text, Inert),
    placed("sort_order", Type::Integer),
    SCHEMA_VERSION,
];

// One record per category (0044, Settings). A long category's id is a digest, so the category rides in the fields.
pub const SETTINGS: &[Field] = &[
    field("category", Type::Text, Inert),
    field("options", Type::Options, ByEntry),
    SCHEMA_VERSION,
];
