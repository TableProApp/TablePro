// A connection as the Mac writes it (`SyncRecordMapper.toCKRecord` over `LibraryRecordMapping`): the tunnel and TLS
// always, a link to an SSH profile only while the tunnel is on, and the optional members only when set. The fields only
// TablePro Sync carries go too; the CloudKit projection leaves them out. A pulled record is read as the Mac reads it,
// and a member it carries as the store's copy reads keeps the store's value, so what only the core holds (a Strict TLS
// mode, a teal colour, a hop OpenSSH signs in to) survives every pull that leaves it alone.

use std::collections::BTreeMap;

use serde_json::Value;
use tablepro_core::{
    AiPolicy, AuthMode, ClientIdentity, ExternalAccess, NetworkOptions, SafeModeLevel, TlsConfig, TlsMode,
};
use tablepro_records::cloudkit::library::{color_name, icon_for_symbol, symbol_for_icon};
use tablepro_records::schema::{core_driver, wire_type};
use tablepro_storage::{
    ConnectionDetails, ConnectionOrigin, DeviceOnly, KnownOrigin, SavedConnection, SavedSshConfig, SshProfile,
};
use uuid::Uuid;

use super::details::{reference_from_wire, reference_to_wire, route_from_wire, route_to_wire};
use super::tunnel::{
    hops_from_wire, hops_to_wire, keeps_passphrase, local, portable_or_empty, remote_access, remote_access_named,
    shared_from_wire, shared_to_wire,
};
use super::values::{Object, boolean, clamped, integer, text, unknown_members, uuid_at, uuid_value};
use crate::adapters::unsettled::{ROUTE_PUBLISHER, SSH_PROFILE_UNLINKED, TLS_MODE_UNSETTLED};

// Every member the store's model reads, so the rest are kept as a newer build wrote them: `project_id`, which the
// model does not hold yet, and the format stamp among them.
const MEMBERS: &[&str] = &[
    "name",
    "type",
    "host",
    "port",
    "database",
    "username",
    "color",
    "icon_name",
    "safe_mode_level",
    "sort_order",
    "group_id",
    "is_favorite",
    "tag_ids",
    "query_timeout_seconds",
    "ssh_config",
    "ssl_config",
    "additional_fields",
    "ai_policy",
    "ai_rules",
    "ai_always_allowed_tools",
    "redis_database",
    "startup_commands",
    "ssh_profile_id",
    "ssh_route",
    "external_access",
    "credential_profile_id",
    "credential_reference",
    "auth_mode",
    "network_options",
    "last_opened_at",
    "local_only",
    "is_sample",
    "origin",
    "password_source",
    "ssh_tunnel_mode",
    "cloudflare_tunnel_mode",
    "cloud_sql_proxy_mode",
    "socks_proxy_mode",
    "tunnel_command_mode",
    TLS_MODE_UNSETTLED,
    SSH_PROFILE_UNLINKED,
    ROUTE_PUBLISHER,
];

// How a host's store names a connection's engine: by the Mac's `DatabaseType` on the Apple apps, by the core's driver
// id on Linux and Windows. The wire always carries the Mac's name (0061, 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriverNames {
    Mac,
    Core,
}

impl DriverNames {
    fn wire_name(self, driver: &str) -> &str {
        match self {
            Self::Mac => driver,
            Self::Core => wire_type(driver),
        }
    }

    fn store_name(self, name: &str) -> &str {
        match self {
            Self::Mac => name,
            Self::Core => core_driver(name),
        }
    }
}

const CONNECT_TIMEOUT: &str = "connectTimeoutSeconds";
const QUERY_TIMEOUT: &str = "queryTimeoutSeconds";
const KAFKA_CONNECT_TIMEOUT: &str = "kafkaConnectTimeout";
const QUERY_TIMEOUT_MAX: u32 = 2_147_483;

const SAFE_MODES: [(SafeModeLevel, &str); 6] = [
    (SafeModeLevel::Silent, "silent"),
    (SafeModeLevel::Alert, "alert"),
    (SafeModeLevel::AlertFull, "alertFull"),
    (SafeModeLevel::SafeMode, "safeMode"),
    (SafeModeLevel::SafeModeFull, "safeModeFull"),
    (SafeModeLevel::ReadOnly, "readOnly"),
];

fn safe_mode_name(level: SafeModeLevel) -> &'static str {
    SAFE_MODES
        .iter()
        .find(|(known, _)| *known == level)
        .map_or("alert", |(_, name)| name)
}

// `SafeModeLevel(wireValue:isReadOnly:)`, with iOS's spellings; a level a newer build added asks before a write.
fn safe_mode_named(raw: Option<&str>) -> SafeModeLevel {
    match raw {
        None | Some("off") => SafeModeLevel::Silent,
        Some("confirmWrites") => SafeModeLevel::Alert,
        Some(name) => SAFE_MODES
            .iter()
            .find(|(_, known)| *known == name)
            .map_or(SafeModeLevel::Alert, |(level, _)| *level),
    }
}

fn tls_mode_name(mode: TlsMode) -> &'static str {
    match mode {
        TlsMode::Disable => "Disabled",
        TlsMode::Prefer => "Preferred",
        TlsMode::Require => "Required",
        TlsMode::VerifyCa => "Verify CA",
        TlsMode::VerifyFull | TlsMode::Strict => "Verify Identity",
    }
}

// A mode a newer build added checks the most this build can, as no Mac reads a record it cannot decode.
fn tls_mode_named(raw: Option<&str>) -> TlsMode {
    match raw {
        Some("Disabled" | "disable") => TlsMode::Disable,
        Some("Preferred") => TlsMode::Prefer,
        Some("Required" | "require") => TlsMode::Require,
        Some("Verify CA" | "verifyCa") => TlsMode::VerifyCa,
        Some(_) => TlsMode::VerifyFull,
        None => TlsMode::Disable,
    }
}

fn ai_policy_name(policy: AiPolicy) -> Option<&'static str> {
    match policy {
        AiPolicy::Ask => Some("askEachTime"),
        AiPolicy::Allow => Some("alwaysAllow"),
        AiPolicy::Never => Some("never"),
        AiPolicy::AppDefault => None,
    }
}

fn ai_policy_named(raw: Option<&str>) -> AiPolicy {
    match raw {
        Some("askEachTime") => AiPolicy::Ask,
        Some("alwaysAllow") => AiPolicy::Allow,
        Some("never") => AiPolicy::Never,
        _ => AiPolicy::AppDefault,
    }
}

fn external_access_name(access: ExternalAccess) -> &'static str {
    match access {
        ExternalAccess::Blocked => "blocked",
        ExternalAccess::ReadOnly => "readOnly",
        ExternalAccess::ReadWrite => "readWrite",
    }
}

// A level a newer build added reads as the strictest.
fn external_access_named(raw: Option<&str>) -> ExternalAccess {
    match raw {
        None | Some("readOnly") => ExternalAccess::ReadOnly,
        Some("readWrite") => ExternalAccess::ReadWrite,
        Some(_) => ExternalAccess::Blocked,
    }
}

fn auth_mode_named(raw: Option<&str>) -> AuthMode {
    match raw {
        Some("kerberos") => AuthMode::Kerberos,
        _ => AuthMode::Password,
    }
}

// `ConnectionColor(storedValue:)`: a connection's colour name in any case.
fn connection_color(raw: &str) -> Option<tablepro_storage::ConnectionColor> {
    tablepro_storage::ConnectionColor::ALL
        .into_iter()
        .find(|color| color_name(Some(*color)).eq_ignore_ascii_case(raw))
}

fn path_text(path: &std::path::Path) -> Option<&std::path::Path> {
    (!path.as_os_str().is_empty()).then_some(path)
}

fn tls_to_wire(tls: &TlsConfig) -> Value {
    let identity = tls.client_identity.as_ref();
    Object::default()
        .put("mode", tls_mode_name(tls.mode))
        .put("ca_certificate_path", portable_or_empty(tls.ca_file.as_deref()))
        .put(
            "client_certificate_path",
            portable_or_empty(identity.and_then(|identity| path_text(&identity.certificate))),
        )
        .put(
            "client_key_path",
            portable_or_empty(identity.and_then(|identity| path_text(&identity.key))),
        )
        .put_some("server_name", tls.server_name.as_deref())
        .done()
}

// Half a client identity keeps its empty side, as the library holds one, so a connect refuses it.
fn tls_from_wire(fields: Option<&Value>) -> TlsConfig {
    let fields = fields.unwrap_or(&Value::Null);
    let certificate = local(text(fields, "client_certificate_path"));
    let key = local(text(fields, "client_key_path"));
    let client_identity = (certificate.is_some() || key.is_some()).then(|| ClientIdentity {
        certificate: certificate.unwrap_or_default(),
        key: key.unwrap_or_default(),
    });
    TlsConfig {
        mode: tls_mode_named(text(fields, "mode")),
        ca_file: local(text(fields, "ca_certificate_path")),
        client_identity,
        server_name: text(fields, "server_name")
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_owned),
        unknown: BTreeMap::new(),
    }
}

// The tunnel as the Mac writes it: a connection with none writes `SSHConfiguration()`, and one linked to a profile
// this device holds goes with the profile's settings and its own remote file (`syncedTunnel(of:)`).
fn tunnel_to_wire(saved: &SavedConnection, profile: Option<&SshProfile>) -> Value {
    let none = SavedSshConfig {
        enabled: false,
        ..SavedSshConfig::new("", tablepro_storage::SavedSshAuth::Password)
    };
    let own = saved.ssh.as_ref().unwrap_or(&none);
    let (settings, owner) = match profile {
        Some(profile) if own.enabled => (&profile.ssh, profile.id),
        _ => (own, saved.id),
    };
    let mut out = Object::default();
    shared_to_wire(settings, &mut out);
    out.put("enabled", own.enabled)
        .put("jump_hosts", hops_to_wire(&settings.jump_hosts, owner))
        .put("remote_file_path", own.remote_file.path.clone().unwrap_or_default())
        .put("remote_file_access", remote_access(own.remote_file.access));
    // TablePro Sync's alone: the CloudKit projection leaves it out (0061, 4).
    if let tablepro_storage::SavedSshAuth::PrivateKey { has_passphrase, .. } = settings.auth {
        out.put("passphrase_stored", has_passphrase);
    }
    out.done()
}

fn tunnel_from_wire(
    saved: &SavedConnection,
    fields: Option<&Value>,
    stored: Option<&SavedSshConfig>,
) -> Option<SavedSshConfig> {
    let linked = saved.details.ssh_profile_id.is_some();
    let Some(fields) = fields else {
        return linked.then(|| SavedSshConfig::new("", tablepro_storage::SavedSshAuth::Password));
    };
    let has_passphrase = boolean(fields, "passphrase_stored").unwrap_or_else(|| keeps_passphrase(stored));
    let mut ssh = shared_from_wire(fields, has_passphrase);
    ssh.enabled = linked || boolean(fields, "enabled").unwrap_or(false);
    ssh.jump_hosts = hops_from_wire(
        fields.get("jump_hosts"),
        stored.map_or(&[][..], |stored| stored.jump_hosts.as_slice()),
        saved.id,
    );
    ssh.remote_file.path = text(fields, "remote_file_path")
        .filter(|path| !path.is_empty())
        .map(str::to_owned);
    ssh.remote_file.access = remote_access_named(text(fields, "remote_file_access"));
    if let Some(stored) = stored {
        ssh.unknown.clone_from(&stored.unknown);
    }
    // A switched-off tunnel holding only the defaults is no tunnel, as the Mac stores one.
    let probe = SavedConnection {
        ssh: Some(ssh.clone()),
        ..saved.clone()
    };
    let empty = SavedConnection {
        ssh: None,
        ..saved.clone()
    };
    (ssh.enabled || tunnel_to_wire(&probe, None) != tunnel_to_wire(&empty, None)).then_some(ssh)
}

// The driver's fields as the Mac syncs them: none a secret or the host sets, the query timeout in its own member, and
// the connect timeout written only when valid (`syncedAdditionalFields`).
fn fields_to_wire(saved: &SavedConnection) -> Option<Value> {
    let held = &saved.details.additional_fields;
    let mut fields = tablepro_storage::field_trust::syncable_fields(held);
    fields.remove(QUERY_TIMEOUT);
    let connect = match held.get(CONNECT_TIMEOUT) {
        Some(raw) => raw.parse::<i64>().ok(),
        None if saved.driver_id == "Kafka" => held.get(KAFKA_CONNECT_TIMEOUT).and_then(|raw| raw.parse().ok()),
        None => None,
    };
    fields.remove(CONNECT_TIMEOUT);
    if let Some(seconds) = connect.filter(|seconds| (1..=600).contains(seconds)) {
        fields.insert(CONNECT_TIMEOUT.to_owned(), seconds.to_string());
    }
    (!fields.is_empty()).then(|| {
        Value::Array(
            fields
                .into_iter()
                .map(|(id, value)| Object::default().put("id", id).put("value", value).done())
                .collect(),
        )
    })
}

fn fields_from_wire(fields: Option<&Value>) -> BTreeMap<String, String> {
    fields
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| Some((text(entry, "id")?.to_owned(), text(entry, "value")?.to_owned())))
                .collect()
        })
        .unwrap_or_default()
}

fn options_to_wire(options: &NetworkOptions) -> Option<Value> {
    if options.is_default() {
        return None;
    }
    let mut out = Object::default();
    if options.dns_seed_list {
        out.put("dns_seed_list", true);
    }
    out.put_some("auth_database", options.auth_database.as_deref())
        .put_some("replica_set", options.replica_set.as_deref());
    if !options.more_hosts.is_empty() {
        out.put("more_hosts", options.more_hosts.clone());
    }
    if options.channel_binding {
        out.put("channel_binding", true);
    }
    Some(out.done())
}

fn options_from_wire(fields: Option<&Value>) -> NetworkOptions {
    let Some(fields) = fields else {
        return NetworkOptions::default();
    };
    NetworkOptions {
        dns_seed_list: boolean(fields, "dns_seed_list").unwrap_or(false),
        auth_database: text(fields, "auth_database").map(str::to_owned),
        replica_set: text(fields, "replica_set").map(str::to_owned),
        more_hosts: fields
            .get("more_hosts")
            .and_then(Value::as_array)
            .map(|hosts| hosts.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default(),
        channel_binding: boolean(fields, "channel_binding").unwrap_or(false),
    }
}

fn non_empty(text: Option<&String>) -> Option<&str> {
    text.map(String::as_str).filter(|text| !text.is_empty())
}

pub(super) fn to_wire(
    saved: &SavedConnection,
    favorite: bool,
    profile: Option<&SshProfile>,
    names: DriverNames,
) -> Value {
    let details = &saved.details;
    let tunnel_on = saved.ssh.as_ref().is_some_and(|ssh| ssh.enabled);
    let mut out = Object::default();
    out.put("name", saved.name.as_str())
        .put("type", names.wire_name(&saved.driver_id))
        .put("host", saved.host.as_str())
        .put("port", saved.port)
        .put("database", saved.database.as_str())
        .put("username", saved.username.as_str())
        .put("color", color_name(saved.color))
        .put_some("icon_name", saved.icon.as_ref().and_then(symbol_for_icon))
        .put("safe_mode_level", safe_mode_name(saved.safe_mode))
        .put("sort_order", saved.order)
        .put("is_favorite", favorite)
        .put_some(
            "query_timeout_seconds",
            saved.query_timeout_secs.filter(|seconds| *seconds <= QUERY_TIMEOUT_MAX),
        )
        .put_some("group_id", saved.group_id.map(uuid_value))
        .put_some("ai_policy", ai_policy_name(saved.ai_policy))
        .put_some("ai_rules", non_empty(details.ai_rules.as_ref()))
        .put_some("redis_database", details.redis_database)
        .put_some("startup_commands", non_empty(details.startup_sql.as_ref()))
        .put_some(
            "ssh_profile_id",
            details.ssh_profile_id.filter(|_| tunnel_on).map(uuid_value),
        )
        .put_some("ssh_route", details.ssh_route.as_ref().map(route_to_wire))
        .put("ssh_config", tunnel_to_wire(saved, profile))
        .put("ssl_config", tls_to_wire(&saved.tls))
        .put_some("additional_fields", fields_to_wire(saved))
        .put("external_access", external_access_name(saved.external_access))
        .put_some("credential_profile_id", details.credential_profile_id.map(uuid_value))
        .put_some(
            "credential_reference",
            details.credential_reference.as_ref().map(reference_to_wire),
        )
        .put(
            "auth_mode",
            if saved.auth_mode == AuthMode::Kerberos {
                "kerberos"
            } else {
                "password"
            },
        )
        .put_some("network_options", options_to_wire(&saved.options));
    if !saved.tags.is_empty() {
        out.put(
            "tag_ids",
            saved.tags.iter().copied().map(uuid_value).collect::<Vec<_>>(),
        );
    }
    if !details.ai_allowed_tools.is_empty() {
        out.put(
            "ai_always_allowed_tools",
            details.ai_allowed_tools.iter().cloned().collect::<Vec<_>>(),
        );
    }
    if saved.device.tls_mode_unsettled {
        out.put(TLS_MODE_UNSETTLED, true);
    }
    if saved.device.ssh_profile_unlinked {
        out.put(SSH_PROFILE_UNLINKED, true);
    }
    for (key, value) in &saved.unknown {
        out.keep(key, value.clone());
    }
    out.done()
}

// The store's copy a pulled record is read against: the connection, whether it is a favourite, and the profile its
// tunnel follows on this device.
#[derive(Clone, Copy)]
pub(super) struct Held<'a> {
    pub saved: &'a SavedConnection,
    pub favorite: bool,
    pub profile: Option<&'a SshProfile>,
}

// A pulled record as the store's model. A member the record carries as the store's copy reads keeps the store's value.
pub(super) fn model(id: Uuid, fields: &Value, held: Option<Held<'_>>, names: DriverNames) -> (SavedConnection, bool) {
    let mut saved = read(id, fields, held.map(|held| held.saved), names);
    let mut favorite = boolean(fields, "is_favorite").unwrap_or(false);
    if let Some(held) = held {
        keep(&mut saved, &mut favorite, fields, held, names);
    }
    (saved, favorite)
}

fn read(id: Uuid, fields: &Value, stored: Option<&SavedConnection>, names: DriverNames) -> SavedConnection {
    let mut additional_fields = fields_from_wire(fields.get("additional_fields"));
    let legacy_timeout = additional_fields
        .remove(QUERY_TIMEOUT)
        .and_then(|raw| raw.parse::<i64>().ok());
    let query_timeout_secs = integer(fields, "query_timeout_seconds")
        .or(legacy_timeout)
        .filter(|seconds| (0..=i64::from(QUERY_TIMEOUT_MAX)).contains(seconds))
        .map(clamped);
    let details = ConnectionDetails {
        startup_sql: text(fields, "startup_commands")
            .filter(|sql| !sql.is_empty())
            .map(str::to_owned),
        ai_rules: text(fields, "ai_rules")
            .filter(|rules| !rules.is_empty())
            .map(str::to_owned),
        ai_allowed_tools: fields
            .get("ai_always_allowed_tools")
            .and_then(Value::as_array)
            .map(|tools| tools.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default(),
        ssh_profile_id: uuid_at(fields, "ssh_profile_id"),
        ssh_route: fields.get("ssh_route").and_then(route_from_wire),
        credential_profile_id: uuid_at(fields, "credential_profile_id"),
        credential_reference: fields.get("credential_reference").and_then(reference_from_wire),
        redis_database: integer(fields, "redis_database").map(clamped),
        additional_fields,
    };
    let mut saved = SavedConnection {
        id,
        name: text(fields, "name").unwrap_or_default().to_owned(),
        driver_id: names.store_name(text(fields, "type").unwrap_or_default()).to_owned(),
        host: text(fields, "host").unwrap_or("localhost").to_owned(),
        port: integer(fields, "port").map_or(0, clamped),
        database: text(fields, "database").unwrap_or_default().to_owned(),
        username: text(fields, "username").unwrap_or_default().to_owned(),
        tls: tls_from_wire(fields.get("ssl_config")),
        safe_mode: safe_mode_named(text(fields, "safe_mode_level")),
        external_access: external_access_named(text(fields, "external_access")),
        ai_policy: ai_policy_named(text(fields, "ai_policy")),
        query_timeout_secs,
        auth_mode: auth_mode_named(text(fields, "auth_mode")),
        ssh: None,
        last_opened_at: None,
        color: text(fields, "color").and_then(connection_color),
        group_id: uuid_at(fields, "group_id"),
        // Sync carries no project yet (core ADR 0067), so a pulled connection keeps the one this device stored.
        project_id: stored.and_then(|stored| stored.project_id),
        order: integer(fields, "sort_order").map_or(0, clamped),
        tags: fields
            .get("tag_ids")
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(|id| super::values::uuid(id.as_str())).collect())
            .unwrap_or_default(),
        icon: text(fields, "icon_name").and_then(icon_for_symbol),
        options: options_from_wire(fields.get("network_options")),
        details,
        device: DeviceOnly {
            origin: ConnectionOrigin::Known(KnownOrigin::Synced),
            tls_mode_unsettled: boolean(fields, TLS_MODE_UNSETTLED).unwrap_or(false),
            ssh_profile_unlinked: boolean(fields, SSH_PROFILE_UNLINKED).unwrap_or(false),
            ..DeviceOnly::default()
        },
        unknown: unknown_members(fields, MEMBERS),
    };
    saved.ssh = tunnel_from_wire(
        &saved,
        fields.get("ssh_config"),
        stored.and_then(|stored| stored.ssh.as_ref()),
    );
    saved
}

// Each member whose pulled value is the one the store's copy writes keeps the store's typed value.
fn keep(saved: &mut SavedConnection, favorite: &mut bool, fields: &Value, held: Held<'_>, names: DriverNames) {
    let stored = held.saved;
    let written = to_wire(stored, held.favorite, held.profile, names);
    let same = |key: &str| fields.get(key) == written.get(key);
    let details = &mut saved.details;
    let kept = &stored.details;
    if same("name") {
        saved.name.clone_from(&stored.name);
    }
    if same("type") {
        saved.driver_id.clone_from(&stored.driver_id);
    }
    if same("color") {
        saved.color = stored.color;
    }
    if same("icon_name") {
        saved.icon.clone_from(&stored.icon);
    }
    if same("safe_mode_level") {
        saved.safe_mode = stored.safe_mode;
    }
    if same("sort_order") {
        saved.order = stored.order;
    }
    if same("is_favorite") {
        *favorite = held.favorite;
    }
    if same("query_timeout_seconds") && same("additional_fields") {
        saved.query_timeout_secs = stored.query_timeout_secs;
    }
    if same("tag_ids") {
        saved.tags.clone_from(&stored.tags);
    }
    if same("ai_policy") {
        saved.ai_policy = stored.ai_policy;
    }
    if same("ai_rules") {
        details.ai_rules.clone_from(&kept.ai_rules);
    }
    if same("startup_commands") {
        details.startup_sql.clone_from(&kept.startup_sql);
    }
    if same("ssh_route") {
        details.ssh_route.clone_from(&kept.ssh_route);
    }
    if same("ssh_config") && same("ssh_profile_id") {
        saved.ssh.clone_from(&stored.ssh);
        details.ssh_profile_id = kept.ssh_profile_id;
    }
    if same("ssl_config") {
        saved.tls.clone_from(&stored.tls);
    }
    // What sync never carries of the driver's fields stays as this device holds it, whatever the pull changed.
    if same("additional_fields") {
        details.additional_fields.clone_from(&kept.additional_fields);
    } else {
        let pulled = std::mem::take(&mut details.additional_fields);
        details.additional_fields = tablepro_storage::field_trust::with_device_fields(pulled, &kept.additional_fields);
    }
    if same("external_access") {
        saved.external_access = stored.external_access;
    }
    if same("credential_reference") {
        details.credential_reference.clone_from(&kept.credential_reference);
    }
    if same("network_options") {
        saved.options.clone_from(&stored.options);
    }
    saved.device = DeviceOnly {
        tls_mode_unsettled: saved.device.tls_mode_unsettled,
        ssh_profile_unlinked: saved.device.ssh_profile_unlinked,
        ..stored.device.clone()
    };
    saved.last_opened_at = stored.last_opened_at;
}
