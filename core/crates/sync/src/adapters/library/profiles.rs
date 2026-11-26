// SSH and credential profiles as the Mac's mapper writes them (`SyncRecordMapper`, SSH Profile and Credential Profile).
// A profile's hops go only when it has some. A credential profile sends its password's mode and never where the
// password comes from: a reference or a local source goes as Prompt, as the Mac sends a source, and a pull that leaves
// the mode as the store's copy reads keeps the store's password.

use serde_json::Value;
use tablepro_storage::{CredentialPassword, CredentialProfile, SshProfile};
use uuid::Uuid;

use super::tunnel::{hops_from_wire, hops_to_wire, keeps_passphrase, shared_from_wire, shared_to_wire};
use super::values::{Object, clamped, integer, text, unknown_members};

const SSH_MEMBERS: &[&str] = &[
    "name",
    "host",
    "port",
    "username",
    "auth_method",
    "private_key_path",
    "agent_socket_path",
    "jump_hosts",
    "totp_mode",
    "totp_algorithm",
    "totp_digits",
    "totp_period",
];

pub(super) fn ssh_to_wire(profile: &SshProfile) -> Value {
    let mut out = Object::default();
    out.put("name", profile.name.as_str());
    shared_to_wire(&profile.ssh, &mut out);
    if !profile.ssh.jump_hosts.is_empty() {
        out.put("jump_hosts", hops_to_wire(&profile.ssh.jump_hosts, profile.id));
    }
    for (key, value) in &profile.ssh.unknown {
        out.keep(key, value.clone());
    }
    out.done()
}

// A profile is never off and opens no remote file, so those stay as the store holds them.
pub(super) fn ssh(id: Uuid, fields: &Value, stored: Option<&SshProfile>) -> SshProfile {
    let held = stored.map(|stored| &stored.ssh);
    let mut ssh = shared_from_wire(fields, keeps_passphrase(held));
    ssh.jump_hosts = hops_from_wire(
        fields.get("jump_hosts"),
        held.map_or(&[][..], |ssh| ssh.jump_hosts.as_slice()),
        id,
    );
    if let Some(held) = held {
        ssh.enabled = held.enabled;
        ssh.remote_file.clone_from(&held.remote_file);
    }
    ssh.unknown = unknown_members(fields, SSH_MEMBERS);
    let name = text(fields, "name")
        .map(str::to_owned)
        .or_else(|| stored.map(|stored| stored.name.clone()))
        .unwrap_or_default();
    SshProfile { id, name, ssh }
}

const CREDENTIAL_MEMBERS: &[&str] = &["name", "username", "password_mode", "secure_field_ids", "sort_order"];

fn password_mode(password: &CredentialPassword) -> &'static str {
    match password {
        CredentialPassword::Stored => "stored",
        CredentialPassword::Pgpass => "pgpass",
        CredentialPassword::Prompt | CredentialPassword::Reference { .. } | CredentialPassword::Local { .. } => "prompt",
    }
}

// `SyncRecordMapper.passwordMode(fromPortable:)`: anything but Prompt and pgpass reads as stored.
fn password_named(raw: Option<&str>) -> CredentialPassword {
    match raw {
        Some("pgpass") => CredentialPassword::Pgpass,
        Some("prompt") => CredentialPassword::Prompt,
        _ => CredentialPassword::Stored,
    }
}

pub(super) fn credential_to_wire(profile: &CredentialProfile) -> Value {
    let mut out = Object::default();
    out.put("name", profile.name.as_str())
        .put("username", profile.username.as_str())
        .put("password_mode", password_mode(&profile.password));
    if !profile.secure_field_ids.is_empty() {
        out.put("secure_field_ids", profile.secure_field_ids.clone());
    }
    out.put("sort_order", profile.order);
    for (key, value) in &profile.unknown {
        out.keep(key, value.clone());
    }
    out.done()
}

pub(super) fn credential(id: Uuid, fields: &Value, stored: Option<&CredentialProfile>) -> CredentialProfile {
    let mode = text(fields, "password_mode");
    let password = match stored {
        Some(stored) if mode == Some(password_mode(&stored.password)) => stored.password.clone(),
        _ => password_named(mode),
    };
    let secure_field_ids = fields
        .get("secure_field_ids")
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    CredentialProfile {
        id,
        name: text(fields, "name")
            .map(str::to_owned)
            .or_else(|| stored.map(|stored| stored.name.clone()))
            .unwrap_or_default(),
        username: text(fields, "username").unwrap_or_default().to_owned(),
        password,
        secure_field_ids,
        order: integer(fields, "sort_order").map_or(0, clamped),
        unknown: unknown_members(fields, CREDENTIAL_MEMBERS),
    }
}
