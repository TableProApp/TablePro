// A Team Library connection as the Mac's bundle carries it (`ExportableConnection`, written by
// `ConnectionBundleExporter.teamShareableSettings`, read by `DatabaseConnection(importing:)`), so every platform maps a
// team copy one way. The bundle's values are the CloudKit record's, in the bundle's names, with the defaults left out:
// no tunnel unless it is on, no TLS while it is off, and no TOTP, remote file or Safe Mode member at its default. A team
// copy never carries startup commands, a tunnel command or Local only, and reads none: a teammate's copy runs nothing.

use serde_json::{Map, Value};
use tablepro_storage::{DeviceOnly, SavedConnection, SshProfile};
use uuid::Uuid;

use super::connection::{self, DriverNames};
use super::values::{text, uuid_at, uuid_value};

const CONNECT_TIMEOUT: &str = "connectTimeoutSeconds";
const QUERY_TIMEOUT: &str = "queryTimeoutSeconds";

// The CloudKit member each bundle member carries, in the bundle's order.
const MEMBERS: [(&str, &str); 10] = [
    ("name", "name"),
    ("host", "host"),
    ("port", "port"),
    ("database", "database"),
    ("username", "username"),
    ("type", "type"),
    ("color", "color"),
    ("iconName", "icon_name"),
    ("aiPolicy", "ai_policy"),
    ("redisDatabase", "redis_database"),
];

const SSH_MEMBERS: [(&str, &str); 12] = [
    ("host", "host"),
    ("port", "port"),
    ("username", "username"),
    ("authMethod", "auth_method"),
    ("privateKeyPath", "private_key_path"),
    ("agentSocketPath", "agent_socket_path"),
    ("totpMode", "totp_mode"),
    ("totpAlgorithm", "totp_algorithm"),
    ("totpDigits", "totp_digits"),
    ("totpPeriod", "totp_period"),
    ("remoteFilePath", "remote_file_path"),
    ("remoteFileAccess", "remote_file_access"),
];

const HOP_MEMBERS: [(&str, &str); 5] = [
    ("host", "host"),
    ("port", "port"),
    ("username", "username"),
    ("authMethod", "auth_method"),
    ("privateKeyPath", "private_key_path"),
];

const SSL_MEMBERS: [(&str, &str); 4] = [
    ("mode", "mode"),
    ("caCertificatePath", "ca_certificate_path"),
    ("clientCertificatePath", "client_certificate_path"),
    ("clientKeyPath", "client_key_path"),
];

fn defaulted(key: &str, value: &Value) -> bool {
    match key {
        "totpMode" => value == "none",
        "totpAlgorithm" => value == "SHA1",
        "totpDigits" => value == 6,
        "totpPeriod" => value == 30,
        "remoteFilePath" => value == "",
        "remoteFileAccess" => value == "readOnlyCopy",
        _ => false,
    }
}

fn renamed(from: &Value, members: &[(&str, &str)], to_bundle: bool) -> Map<String, Value> {
    let mut out = Map::new();
    for (bundle, wire) in members {
        let (source, target) = if to_bundle { (*wire, *bundle) } else { (*bundle, *wire) };
        if let Some(value) = from.get(source) {
            out.insert(target.to_owned(), value.clone());
        }
    }
    out
}

// The bundle a team publishes for the connection, with `profile` the SSH profile its tunnel follows on this device.
pub fn team_bundle(saved: &SavedConnection, profile: Option<&SshProfile>, names: DriverNames) -> Value {
    let wire = connection::to_wire(saved, false, profile, names);
    let mut out = renamed(&wire, &MEMBERS, true);
    if out.get("color").is_some_and(|color| color == "None") {
        out.remove("color");
    }
    if let Some(ssh) = wire
        .get("ssh_config")
        .filter(|ssh| ssh.get("enabled") == Some(&Value::Bool(true)))
    {
        let mut bundle = Map::new();
        bundle.insert("enabled".to_owned(), Value::Bool(true));
        bundle.extend(renamed(ssh, &SSH_MEMBERS, true));
        bundle.retain(|key, value| !defaulted(key, value));
        let hops: Vec<Value> = ssh
            .get("jump_hosts")
            .and_then(Value::as_array)
            .map(|hops| {
                hops.iter()
                    .map(|hop| Value::Object(renamed(hop, &HOP_MEMBERS, true)))
                    .collect()
            })
            .unwrap_or_default();
        if !hops.is_empty() {
            bundle.insert("jumpHosts".to_owned(), Value::Array(hops));
        }
        out.insert("sshConfig".to_owned(), Value::Object(bundle));
    }
    if let Some(ssl) = wire
        .get("ssl_config")
        .filter(|ssl| ssl.get("mode").and_then(Value::as_str) != Some("Disabled"))
    {
        out.insert("sslConfig".to_owned(), Value::Object(renamed(ssl, &SSL_MEMBERS, true)));
    }
    if let Some(profile) = saved.details.ssh_profile_id {
        out.insert("sshProfileId".to_owned(), uuid_value(profile));
    }
    if let Some(level) = wire.get("safe_mode_level").filter(|level| *level != "silent") {
        out.insert("safeModeLevel".to_owned(), level.clone());
    }
    let mut fields: Map<String, Value> = wire
        .get("additional_fields")
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| Some((text(entry, "id")?.to_owned(), entry.get("value")?.clone())))
                .collect()
        })
        .unwrap_or_default();
    if let Some(seconds) = fields
        .remove(CONNECT_TIMEOUT)
        .and_then(|raw| raw.as_str()?.parse::<i64>().ok())
    {
        out.insert(CONNECT_TIMEOUT.to_owned(), Value::from(seconds));
    }
    if let Some(seconds) = wire.get("query_timeout_seconds") {
        out.insert(QUERY_TIMEOUT.to_owned(), seconds.clone());
    }
    if !fields.is_empty() {
        out.insert("additionalFields".to_owned(), Value::Object(fields));
    }
    Value::Object(out)
}

// `PortableSSLMode(carrying:)`, in the CloudKit record's names; a mode no build names checks as Required, so a team copy
// never connects in the clear on a guess.
fn ssl_mode(raw: Option<&str>) -> &'static str {
    let key: String = raw
        .unwrap_or_default()
        .to_lowercase()
        .chars()
        .filter(|character| !character.is_whitespace() && *character != '_' && *character != '-')
        .collect();
    match key.as_str() {
        "disabled" | "disable" => "Disabled",
        "preferred" | "prefer" => "Preferred",
        "verifyca" => "Verify CA",
        "verifyidentity" | "verifyfull" => "Verify Identity",
        _ => "Required",
    }
}

// A team item's bundle as a connection with id `id`. `holds_profile` says whether this device holds an SSH profile, the
// only one the copy may link. What the bundle has no place for (tags, group, project, favourite, credential profile,
// and every device-only setting) reads as the default.
pub fn team_connection(
    id: Uuid,
    bundle: &Value,
    names: DriverNames,
    holds_profile: impl Fn(Uuid) -> bool,
) -> SavedConnection {
    let mut wire = renamed(bundle, &MEMBERS, false);
    if let Some(ssh) = bundle.get("sshConfig") {
        let mut tunnel = renamed(ssh, &SSH_MEMBERS, false);
        tunnel.insert(
            "enabled".to_owned(),
            Value::Bool(ssh.get("enabled").and_then(Value::as_bool).unwrap_or(false)),
        );
        let hops: Vec<Value> = ssh
            .get("jumpHosts")
            .and_then(Value::as_array)
            .map(|hops| {
                hops.iter()
                    .map(|hop| Value::Object(renamed(hop, &HOP_MEMBERS, false)))
                    .collect()
            })
            .unwrap_or_default();
        tunnel.insert("jump_hosts".to_owned(), Value::Array(hops));
        wire.insert("ssh_config".to_owned(), Value::Object(tunnel));
    }
    if let Some(ssl) = bundle.get("sslConfig") {
        let mut tls = renamed(ssl, &SSL_MEMBERS, false);
        tls.insert("mode".to_owned(), Value::from(ssl_mode(text(ssl, "mode"))));
        wire.insert("ssl_config".to_owned(), Value::Object(tls));
    }
    if let Some(profile) = uuid_at(bundle, "sshProfileId").filter(|profile| holds_profile(*profile)) {
        wire.insert("ssh_profile_id".to_owned(), uuid_value(profile));
    }
    wire.insert(
        "safe_mode_level".to_owned(),
        bundle.get("safeModeLevel").cloned().unwrap_or(Value::Null),
    );
    let mut fields: Map<String, Value> = bundle
        .get("additionalFields")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let legacy = |key: &str, fields: &mut Map<String, Value>| {
        fields.remove(key).and_then(|raw| raw.as_str()?.parse::<i64>().ok())
    };
    let legacy_connect = legacy(CONNECT_TIMEOUT, &mut fields);
    let legacy_query = legacy(QUERY_TIMEOUT, &mut fields);
    if let Some(seconds) = bundle
        .get(CONNECT_TIMEOUT)
        .and_then(Value::as_i64)
        .or(legacy_connect)
        .filter(|seconds| (1..=600).contains(seconds))
    {
        fields.insert(CONNECT_TIMEOUT.to_owned(), Value::from(seconds.to_string()));
    }
    if let Some(seconds) = bundle.get(QUERY_TIMEOUT).and_then(Value::as_i64).or(legacy_query) {
        wire.insert("query_timeout_seconds".to_owned(), Value::from(seconds));
    }
    let entries: Vec<Value> = fields
        .into_iter()
        .map(|(key, value)| {
            Value::Object(Map::from_iter([
                ("id".to_owned(), Value::from(key)),
                ("value".to_owned(), value),
            ]))
        })
        .collect();
    if !entries.is_empty() {
        wire.insert("additional_fields".to_owned(), Value::Array(entries));
    }
    wire.retain(|_, value| !value.is_null());
    let (mut saved, _) = connection::model(id, &Value::Object(wire), None, names);
    if saved.host.trim().is_empty() {
        "localhost".clone_into(&mut saved.host);
    }
    saved.device = DeviceOnly::default();
    saved
}

#[cfg(test)]
#[path = "bundle_tests.rs"]
mod tests;
