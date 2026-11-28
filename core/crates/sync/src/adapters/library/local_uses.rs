// What a connection from another origin (a team's copy, a shared folder's file) would use of this device when it
// connects: the SSH credentials it signs in with and the files or sockets it opens. Another account picked the server,
// so an app asks the person once per destination before the first connect, the one list for every platform. The SSH
// uses follow this core's transports (`tablepro_ssh`): every sign-in method but a named key may try the agent and the
// default key files, and a hop tries the agent, the connection's key and the default keys. What `~/.ssh/config` adds
// for a host, such as a ProxyJump, is the SSH client's to add.

use std::path::PathBuf;

use serde::Deserialize;
use tablepro_storage::{SavedConnection, SavedSshAuth};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalUse {
    SshAgent { host: String, port: u16 },
    SshKeyFile { host: String, port: u16, path: PathBuf },
    SshDefaultKeys { host: String, port: u16 },
    SshProfile { id: Uuid },
    // A database file or a server's socket on this device.
    File { path: String },
}

const SSH_PORT: u16 = 22;
const ATTACHED: &str = "attachedDatabases";
// Each file field with the mode field that switches it on; a mode other than `local` (remote, MotherDuck) reads none.
const FILE_FIELDS: [(&str, &str); 2] = [("duckdbFilePath", "duckdbMode"), ("libsqlFilePath", "libsqlMode")];
const SOCKET_FIELD: &str = "localSocketPath";

#[derive(Deserialize)]
struct Attached {
    path: String,
}

// A path that names no file here: MotherDuck's `md:`, a URL, or an in-memory database.
fn remote(path: &str) -> bool {
    path.starts_with("md:") || path.contains("://") || path == ":memory:"
}

fn local_path(value: Option<&String>) -> Option<String> {
    value
        .map(|value| value.trim())
        .filter(|value| !value.is_empty() && !remote(value))
        .map(str::to_owned)
}

// `file_based` is whether the connection's driver opens `database` as a file on this device.
pub fn shared_row_local_uses(saved: &SavedConnection, file_based: bool) -> Vec<LocalUse> {
    let mut uses = Vec::new();
    let tunnel = saved.ssh.as_ref().filter(|ssh| ssh.enabled);
    if let Some(ssh) = tunnel {
        let named_key = match &ssh.auth {
            SavedSshAuth::PrivateKey { path: Some(path), .. } => Some(path.clone()),
            _ => None,
        };
        let (host, port) = (ssh.host.clone(), ssh.port.unwrap_or(SSH_PORT));
        match &named_key {
            Some(path) => uses.push(LocalUse::SshKeyFile {
                host,
                port,
                path: path.clone(),
            }),
            None => {
                uses.push(LocalUse::SshAgent {
                    host: host.clone(),
                    port,
                });
                uses.push(LocalUse::SshDefaultKeys { host, port });
            }
        }
        for hop in &ssh.jump_hosts {
            let (host, port) = (hop.host.clone(), hop.port.unwrap_or(SSH_PORT));
            uses.push(LocalUse::SshAgent {
                host: host.clone(),
                port,
            });
            if let Some(path) = hop.key_path.clone().or_else(|| named_key.clone()) {
                uses.push(LocalUse::SshKeyFile {
                    host: host.clone(),
                    port,
                    path,
                });
            }
            uses.push(LocalUse::SshDefaultKeys { host, port });
        }
    }
    if let Some(id) = saved.details.ssh_profile_id {
        uses.push(LocalUse::SshProfile { id });
    }
    // A file on the SSH host is opened there, never here.
    if file_based
        && !tunnel.is_some_and(|ssh| ssh.opens_remote_file())
        && let Some(path) = local_path(Some(&saved.database))
    {
        uses.push(LocalUse::File { path });
    }
    let fields = &saved.details.additional_fields;
    for (field, mode) in FILE_FIELDS {
        if fields.get(mode).is_some_and(|mode| mode != "local") {
            continue;
        }
        if let Some(path) = local_path(fields.get(field)) {
            uses.push(LocalUse::File { path });
        }
    }
    let attached: Vec<Attached> = fields
        .get(ATTACHED)
        .and_then(|list| serde_json::from_str(list).ok())
        .unwrap_or_default();
    for path in attached
        .into_iter()
        .filter_map(|attached| local_path(Some(&attached.path)))
    {
        uses.push(LocalUse::File { path });
    }
    // A tunnel goes to its forwarded port, never this device's socket.
    if tunnel.is_none()
        && let Some(path) = local_path(fields.get(SOCKET_FIELD))
    {
        uses.push(LocalUse::File { path });
    }
    let mut seen = Vec::new();
    uses.retain(|used| {
        let first = !seen.contains(used);
        if first {
            seen.push(used.clone());
        }
        first
    });
    uses
}

#[cfg(test)]
#[path = "local_uses_tests.rs"]
mod tests;
