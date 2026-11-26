// The CloudKit schema registry, which replaces Swift's `verifiedInProduction`: every record type and field the apps
// declare, whether Production holds it, and the wire field it carries. Only what Production holds is written; iCloud
// gains no record type or field (0054).

use crate::kind::Kind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloudType {
    String,
    Int64,
    Timestamp,
    Bytes,
    StringList,
}

impl CloudType {
    // As `production-schema.ckdb` spells it.
    pub const fn schema_name(self) -> &'static str {
        match self {
            Self::String => "STRING",
            Self::Int64 => "INT64",
            Self::Timestamp => "TIMESTAMP",
            Self::Bytes => "BYTES",
            Self::StringList => "LIST<STRING>",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Carries {
    // The record's own id, which the record name also holds.
    Own,
    // The wire field of this name.
    Wire(&'static str),
    // `modifiedAtLocal`, written on every save and read by nobody.
    Stamp,
    // Read by builds older than `safeModeLevel`; 1 when the level is `readOnly`.
    IsReadOnly,
    // Older iOS builds read a connection's colour here.
    ColorTag,
    // Builds older than `tagIds` read the first tag here.
    TagId,
    // Neither read nor written: `useSSHConfig` went with the per-connection switch in 0.38, and the Mac reads a
    // connection's SSH and TLS switches from their configurations, not iOS's `sshEnabled` and `sslEnabled`.
    Retired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CloudField {
    pub name: &'static str,
    pub ty: CloudType,
    pub deployed: bool,
    pub carries: Carries,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecordType {
    pub name: &'static str,
    pub prefix: &'static str,
    pub kind: Kind,
    pub deployed: bool,
    pub fields: &'static [CloudField],
}

impl RecordType {
    pub fn field(&self, name: &str) -> Option<&'static CloudField> {
        self.fields.iter().find(|field| field.name == name)
    }

    // What a save may name: deployed fields of a deployed type.
    pub fn writes(&self, field: &CloudField) -> bool {
        self.deployed && field.deployed
    }
}

const fn deployed(name: &'static str, ty: CloudType, carries: Carries) -> CloudField {
    CloudField {
        name,
        ty,
        deployed: true,
        carries,
    }
}

const fn wire(name: &'static str, ty: CloudType, key: &'static str) -> CloudField {
    deployed(name, ty, Carries::Wire(key))
}

// Declared by #4376 and not in Production yet.
const fn pending(name: &'static str, ty: CloudType, key: &'static str) -> CloudField {
    CloudField {
        name,
        ty,
        deployed: false,
        carries: Carries::Wire(key),
    }
}

use CloudType::{Bytes, Int64, String as Text, StringList, Timestamp};

const STAMPS: [CloudField; 2] = [
    deployed("modifiedAtLocal", Timestamp, Carries::Stamp),
    wire("schemaVersion", Int64, "schema_version"),
];

const CONNECTION: &[CloudField] = &[
    deployed("connectionId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("host", Text, "host"),
    wire("port", Int64, "port"),
    wire("database", Text, "database"),
    wire("username", Text, "username"),
    wire("type", Text, "type"),
    wire("color", Text, "color"),
    deployed("colorTag", Text, Carries::ColorTag),
    wire("iconName", Text, "icon_name"),
    wire("safeModeLevel", Text, "safe_mode_level"),
    wire("sortOrder", Int64, "sort_order"),
    wire("groupId", Text, "group_id"),
    deployed("tagId", Text, Carries::TagId),
    wire("tagIds", StringList, "tag_ids"),
    deployed("isReadOnly", Int64, Carries::IsReadOnly),
    deployed("sshEnabled", Int64, Carries::Retired),
    deployed("sslEnabled", Int64, Carries::Retired),
    wire("queryTimeoutSeconds", Int64, "query_timeout_seconds"),
    wire("sshConfigJson", Bytes, "ssh_config"),
    wire("sslConfigJson", Bytes, "ssl_config"),
    wire("additionalFieldsJson", Bytes, "additional_fields"),
    wire("aiPolicy", Text, "ai_policy"),
    wire("aiRules", Text, "ai_rules"),
    wire("aiAlwaysAllowedTools", StringList, "ai_always_allowed_tools"),
    wire("redisDatabase", Int64, "redis_database"),
    wire("startupCommands", Text, "startup_commands"),
    wire("sshProfileId", Text, "ssh_profile_id"),
    wire("sshRouteJson", Bytes, "ssh_route"),
    wire("isFavorite", Int64, "is_favorite"),
    pending("projectId", Text, "project_id"),
    STAMPS[0],
    STAMPS[1],
];

const GROUP: &[CloudField] = &[
    deployed("groupId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("color", Text, "color"),
    wire("iconName", Text, "icon_name"),
    wire("parentId", Text, "parent_id"),
    wire("sortOrder", Int64, "sort_order"),
    pending("projectId", Text, "project_id"),
    STAMPS[0],
    STAMPS[1],
];

const TAG: &[CloudField] = &[
    deployed("tagId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("color", Text, "color"),
    wire("isPreset", Int64, "is_preset"),
    STAMPS[0],
    STAMPS[1],
];

const SETTINGS: &[CloudField] = &[
    wire("category", Text, "category"),
    wire("settingsJson", Bytes, "options"),
    STAMPS[0],
    STAMPS[1],
];

const FAVORITE: &[CloudField] = &[
    deployed("favoriteId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("query", Text, "query"),
    wire("keyword", Text, "keyword"),
    wire("folderId", Text, "folder_id"),
    wire("connectionId", Text, "connection_id"),
    wire("sortOrder", Int64, "sort_order"),
    wire("createdAt", Timestamp, "created_at"),
    wire("updatedAt", Timestamp, "updated_at"),
    STAMPS[0],
    STAMPS[1],
];

const FAVORITE_FOLDER: &[CloudField] = &[
    deployed("folderId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("parentId", Text, "parent_id"),
    wire("connectionId", Text, "connection_id"),
    wire("sortOrder", Int64, "sort_order"),
    wire("createdAt", Timestamp, "created_at"),
    wire("updatedAt", Timestamp, "updated_at"),
    STAMPS[0],
    STAMPS[1],
];

const FAVORITE_TABLE: &[CloudField] = &[
    wire("connectionId", Text, "connection_id"),
    wire("name", Text, "name"),
    wire("database", Text, "database"),
    wire("schema", Text, "schema"),
    STAMPS[0],
    STAMPS[1],
];

const FAVORITE_DATABASE: &[CloudField] = &[
    wire("connectionId", Text, "connection_id"),
    wire("database", Text, "database"),
    wire("environment", Text, "environment"),
    STAMPS[0],
    STAMPS[1],
];

const SSH_PROFILE: &[CloudField] = &[
    deployed("profileId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("host", Text, "host"),
    wire("port", Int64, "port"),
    wire("username", Text, "username"),
    wire("authMethod", Text, "auth_method"),
    wire("privateKeyPath", Text, "private_key_path"),
    wire("agentSocketPath", Text, "agent_socket_path"),
    wire("jumpHostsJson", Bytes, "jump_hosts"),
    wire("totpMode", Text, "totp_mode"),
    wire("totpAlgorithm", Text, "totp_algorithm"),
    wire("totpDigits", Int64, "totp_digits"),
    wire("totpPeriod", Int64, "totp_period"),
    deployed("useSSHConfig", Int64, Carries::Retired),
    STAMPS[0],
    STAMPS[1],
];

const CREDENTIAL_PROFILE: &[CloudField] = &[
    deployed("profileId", Text, Carries::Own),
    wire("name", Text, "name"),
    wire("username", Text, "username"),
    wire("passwordMode", Text, "password_mode"),
    wire("secureFieldIdsJson", Bytes, "secure_field_ids"),
    wire("sortOrder", Int64, "sort_order"),
    STAMPS[0],
    STAMPS[1],
];

const TABLE_FOLDER: &[CloudField] = &[
    deployed("folderId", Text, Carries::Own),
    wire("connectionId", Text, "connection_id"),
    wire("database", Text, "database"),
    wire("schema", Text, "schema"),
    wire("name", Text, "name"),
    wire("createdAt", Timestamp, "created_at"),
    wire("updatedAt", Timestamp, "updated_at"),
    STAMPS[0],
    STAMPS[1],
];

const TABLE_FOLDER_ITEM: &[CloudField] = &[
    wire("connectionId", Text, "connection_id"),
    wire("database", Text, "database"),
    wire("schema", Text, "schema"),
    wire("name", Text, "name"),
    wire("folderId", Text, "folder_id"),
    STAMPS[0],
    STAMPS[1],
];

const PROJECT: &[CloudField] = &[
    CloudField {
        name: "projectId",
        ty: Text,
        deployed: false,
        carries: Carries::Own,
    },
    pending("name", Text, "name"),
    pending("color", Text, "color"),
    pending("iconName", Text, "icon_name"),
    pending("sortOrder", Int64, "sort_order"),
    CloudField {
        name: "modifiedAtLocal",
        ty: Timestamp,
        deployed: false,
        carries: Carries::Stamp,
    },
    pending("schemaVersion", Int64, "schema_version"),
];

const fn record_type(
    name: &'static str,
    prefix: &'static str,
    kind: Kind,
    fields: &'static [CloudField],
) -> RecordType {
    RecordType {
        name,
        prefix,
        kind,
        deployed: true,
        fields,
    }
}

// The 12 types iCloud carries today and #4376's `ConnectionProject`, the frozen set (0054).
pub const RECORD_TYPES: &[RecordType] = &[
    record_type("Connection", "Connection_", Kind::Connection, CONNECTION),
    record_type("ConnectionGroup", "Group_", Kind::Group, GROUP),
    record_type("ConnectionTag", "Tag_", Kind::Tag, TAG),
    record_type("AppSettings", "Settings_", Kind::MacosSettings, SETTINGS),
    record_type("SQLFavorite", "Favorite_", Kind::SavedQuery, FAVORITE),
    record_type(
        "SQLFavoriteFolder",
        "FavoriteFolder_",
        Kind::SavedQueryFolder,
        FAVORITE_FOLDER,
    ),
    record_type("FavoriteTable", "FavoriteTable_", Kind::FavouriteTable, FAVORITE_TABLE),
    record_type(
        "FavoriteDatabase",
        "FavoriteDatabase_",
        Kind::FavouriteDatabase,
        FAVORITE_DATABASE,
    ),
    record_type("SSHProfile", "SSHProfile_", Kind::SshProfile, SSH_PROFILE),
    record_type(
        "CredentialProfile",
        "CredentialProfile_",
        Kind::CredentialProfile,
        CREDENTIAL_PROFILE,
    ),
    record_type("TableFolder", "TableFolder_", Kind::TableFolder, TABLE_FOLDER),
    record_type(
        "TableFolderItem",
        "TableFolderItem_",
        Kind::TableFolderItem,
        TABLE_FOLDER_ITEM,
    ),
    RecordType {
        name: "ConnectionProject",
        prefix: "Project_",
        kind: Kind::ConnectionProject,
        deployed: false,
        fields: PROJECT,
    },
];

// Types Production holds that no build writes any more: `QueryHistory` left iCloud in #502, and `Users` is
// CloudKit's own.
pub const RETIRED_RECORD_TYPES: &[&str] = &["QueryHistory", "Users"];

pub fn record_type_named(name: &str) -> Option<&'static RecordType> {
    RECORD_TYPES.iter().find(|record_type| record_type.name == name)
}

pub fn record_type_of(kind: Kind) -> Option<&'static RecordType> {
    RECORD_TYPES.iter().find(|record_type| record_type.kind == kind)
}

// The CloudKit record name prefix, empty for a kind iCloud does not carry (0052, Long ids).
pub fn prefix(kind: Kind) -> &'static str {
    record_type_of(kind).map_or("", |record_type| record_type.prefix)
}
