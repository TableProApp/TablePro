// An SSH tunnel's members as the Mac's `SSHConfiguration` and `SSHJumpHost` encode them: every member written, an
// unset text as "", the port only when set, and paths under the home folder as `~/` (`SyncRecordMapper.makePortable`).
// A pull expands them again. A hop the store names no sign-in for reads as the agent, as the Mac reads a hop without
// one.

use std::path::{Path, PathBuf};

use serde_json::Value;
use tablepro_storage::{
    RemoteFileAccess, SavedSshAuth, SavedSshConfig, SshJumpAuth, SshJumpHost, SshTotp, SshTotpAlgorithm, SshTotpMode,
};

use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::values::{Object, clamped, integer, text, uuid, uuid_value};

const PASSWORD: &str = "Password";
const PRIVATE_KEY: &str = "Private Key";
const AGENT: &str = "SSH Agent";
const KEYBOARD: &str = "Keyboard Interactive";
const NO_AUTH: &str = "None";

fn home() -> Option<PathBuf> {
    std::env::home_dir().filter(|home| home.is_absolute())
}

// `PathPortability.contractHome`, on a component boundary.
pub(super) fn portable(path: &Path) -> String {
    let text = path.to_string_lossy();
    let Some(home) = home() else {
        return text.into_owned();
    };
    match path.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".to_owned(),
        Ok(rest) => format!("~/{}", rest.to_string_lossy()),
        Err(_) => text.into_owned(),
    }
}

// `PathPortability.expandHome`; "" is no path.
pub(super) fn local(raw: Option<&str>) -> Option<PathBuf> {
    let raw = raw.filter(|raw| !raw.is_empty())?;
    match (raw.strip_prefix("~/"), home()) {
        (Some(rest), Some(home)) => Some(home.join(rest)),
        _ => Some(PathBuf::from(raw)),
    }
}

pub(super) fn portable_or_empty(path: Option<&Path>) -> String {
    path.map(portable).unwrap_or_default()
}

fn auth_name(auth: &SavedSshAuth) -> &'static str {
    match auth {
        SavedSshAuth::Password => PASSWORD,
        SavedSshAuth::PrivateKey { .. } => PRIVATE_KEY,
        SavedSshAuth::Agent => AGENT,
        SavedSshAuth::KeyboardInteractive => KEYBOARD,
        SavedSshAuth::None => NO_AUTH,
    }
}

// `SSHAuthMethod(from:)`, with the spellings shipped iOS builds wrote; anything else reads as Password, as on the Mac.
fn auth_named(raw: Option<&str>, path: Option<PathBuf>, has_passphrase: bool) -> SavedSshAuth {
    match raw {
        Some(PRIVATE_KEY | "privateKey" | "publicKey") => SavedSshAuth::PrivateKey { path, has_passphrase },
        Some(AGENT | "sshAgent" | "agent") => SavedSshAuth::Agent,
        Some(KEYBOARD | "keyboardInteractive") => SavedSshAuth::KeyboardInteractive,
        Some(NO_AUTH | "none") => SavedSshAuth::None,
        _ => SavedSshAuth::Password,
    }
}

// The key file the record names: the key auth's own, else one kept while the auth is not a key.
fn key_path(ssh: &SavedSshConfig) -> Option<&Path> {
    match &ssh.auth {
        SavedSshAuth::PrivateKey { path, .. } => path.as_deref(),
        _ => ssh.kept_key_path.as_deref(),
    }
}

fn totp_mode(mode: SshTotpMode) -> &'static str {
    match mode {
        SshTotpMode::Off => "none",
        SshTotpMode::AutoGenerate => "auto_generate",
        SshTotpMode::PromptAtConnect => "prompt_at_connect",
    }
}

fn totp_mode_named(raw: Option<&str>) -> SshTotpMode {
    match raw {
        Some("auto_generate") => SshTotpMode::AutoGenerate,
        Some("prompt_at_connect") => SshTotpMode::PromptAtConnect,
        _ => SshTotpMode::Off,
    }
}

fn totp_algorithm(algorithm: SshTotpAlgorithm) -> &'static str {
    match algorithm {
        SshTotpAlgorithm::Sha1 => "SHA1",
        SshTotpAlgorithm::Sha256 => "SHA256",
        SshTotpAlgorithm::Sha512 => "SHA512",
    }
}

fn totp_algorithm_named(raw: Option<&str>) -> SshTotpAlgorithm {
    match raw {
        Some("SHA256") => SshTotpAlgorithm::Sha256,
        Some("SHA512") => SshTotpAlgorithm::Sha512,
        _ => SshTotpAlgorithm::Sha1,
    }
}

// The id a hop no build named gets on the Mac (`LibraryRecordMapping.derivedHopId`): a name-based UUID from its
// owner's id in lower case and its place, so every reading of the same hop names it alike.
fn derived_hop_id(owner: Uuid, index: usize) -> Uuid {
    let digest = Sha256::digest(format!("{}/hop/{index}", owner.hyphenated()).as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid::from_bytes(bytes)
}

fn hop_to_wire(hop: &SshJumpHost, owner: Uuid, index: usize) -> Value {
    Object::default()
        .put("id", uuid_value(hop.id.unwrap_or_else(|| derived_hop_id(owner, index))))
        .put("host", hop.host.as_str())
        .put_some("port", hop.port)
        .put("username", hop.username.clone().unwrap_or_default())
        .put(
            "auth_method",
            if hop.auth == Some(SshJumpAuth::PrivateKey) {
                PRIVATE_KEY
            } else {
                AGENT
            },
        )
        .put("private_key_path", portable_or_empty(hop.key_path.as_deref()))
        .done()
}

// A hop the record carries as the store's copy reads keeps that copy, so what the store holds and no record says, as
// a hop OpenSSH's own configuration signs in to, stays.
fn hop_from_wire(fields: &Value, stored: &[SshJumpHost], owner: Uuid) -> SshJumpHost {
    let kept = stored
        .iter()
        .enumerate()
        .find(|(index, hop)| hop_to_wire(hop, owner, *index) == *fields);
    if let Some((_, kept)) = kept {
        return kept.clone();
    }
    SshJumpHost {
        id: uuid(text(fields, "id")),
        host: text(fields, "host").unwrap_or_default().to_owned(),
        port: integer(fields, "port").map(clamped),
        username: text(fields, "username").filter(|name| !name.is_empty()).map(str::to_owned),
        auth: Some(match text(fields, "auth_method") {
            Some(PRIVATE_KEY | "privateKey" | "publicKey") => SshJumpAuth::PrivateKey,
            _ => SshJumpAuth::Agent,
        }),
        key_path: local(text(fields, "private_key_path")),
    }
}

pub(super) fn hops_to_wire(hops: &[SshJumpHost], owner: Uuid) -> Value {
    Value::Array(
        hops.iter()
            .enumerate()
            .map(|(index, hop)| hop_to_wire(hop, owner, index))
            .collect(),
    )
}

pub(super) fn hops_from_wire(fields: Option<&Value>, stored: &[SshJumpHost], owner: Uuid) -> Vec<SshJumpHost> {
    fields
        .and_then(Value::as_array)
        .map(|hops| hops.iter().map(|hop| hop_from_wire(hop, stored, owner)).collect())
        .unwrap_or_default()
}

// The members a tunnel and an SSH profile share, in the Mac's spelling.
pub(super) fn shared_to_wire(ssh: &SavedSshConfig, out: &mut Object) {
    out.put("host", ssh.host.as_str())
        .put_some("port", ssh.port)
        .put("username", ssh.username.clone().unwrap_or_default())
        .put("auth_method", auth_name(&ssh.auth))
        .put("private_key_path", portable_or_empty(key_path(ssh)))
        .put("agent_socket_path", portable_or_empty(ssh.agent_socket.as_deref()))
        .put("totp_mode", totp_mode(ssh.totp.mode))
        .put("totp_algorithm", totp_algorithm(ssh.totp.algorithm))
        .put("totp_digits", ssh.totp.digits)
        .put("totp_period", ssh.totp.period);
}

// What a tunnel or profile record says of the members both carry. The switch, the hops, the remote file and the keys
// a newer build wrote are the caller's; a key's passphrase flag is `has_passphrase`.
pub(super) fn shared_from_wire(fields: &Value, has_passphrase: bool) -> SavedSshConfig {
    let path = local(text(fields, "private_key_path"));
    let auth = auth_named(text(fields, "auth_method"), path.clone(), has_passphrase);
    let kept_key_path = match auth {
        SavedSshAuth::PrivateKey { .. } => None,
        _ => path,
    };
    SavedSshConfig {
        username: text(fields, "username").filter(|name| !name.is_empty()).map(str::to_owned),
        port: integer(fields, "port").map(clamped),
        kept_key_path,
        agent_socket: local(text(fields, "agent_socket_path")),
        totp: SshTotp {
            mode: totp_mode_named(text(fields, "totp_mode")),
            algorithm: totp_algorithm_named(text(fields, "totp_algorithm")),
            digits: integer(fields, "totp_digits").map_or(6, clamped),
            period: integer(fields, "totp_period").map_or(30, clamped),
        },
        ..SavedSshConfig::new(text(fields, "host").unwrap_or_default(), auth)
    }
}

// Whether the stored tunnel keeps a passphrase for its key, which only this device knows.
pub(super) fn keeps_passphrase(ssh: Option<&SavedSshConfig>) -> bool {
    ssh.is_some_and(|ssh| {
        matches!(
            ssh.auth,
            SavedSshAuth::PrivateKey {
                has_passphrase: true,
                ..
            }
        )
    })
}

pub(super) fn remote_access(access: RemoteFileAccess) -> &'static str {
    match access {
        RemoteFileAccess::ReadOnlyCopy => "readOnlyCopy",
        RemoteFileAccess::OnServer => "onServer",
    }
}

pub(super) fn remote_access_named(raw: Option<&str>) -> RemoteFileAccess {
    match raw {
        Some("onServer") => RemoteFileAccess::OnServer,
        _ => RemoteFileAccess::ReadOnlyCopy,
    }
}
