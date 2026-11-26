use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSshConfig {
    // Off keeps the settings, as the macOS form keeps them while the tunnel is switched off.
    #[serde(default = "switched_on", skip_serializing_if = "is_on")]
    pub enabled: bool,
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty", with = "jump_list")]
    pub jump_hosts: Vec<SshJumpHost>,
    pub auth: SavedSshAuth,
    // A key file kept while auth is not a key, as the macOS form keeps it; a key auth holds its own in `auth`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kept_key_path: Option<PathBuf>,
    // None is the agent SSH_AUTH_SOCK names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_socket: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "SshTotp::is_default")]
    pub totp: SshTotp,
    #[serde(default, skip_serializing_if = "SshRemoteFile::is_default")]
    pub remote_file: SshRemoteFile,
    #[serde(flatten)]
    pub unknown: BTreeMap<String, Value>,
}

impl SavedSshConfig {
    pub fn new(host: impl Into<String>, auth: SavedSshAuth) -> Self {
        Self {
            enabled: true,
            host: host.into(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth,
            kept_key_path: None,
            agent_socket: None,
            totp: SshTotp::default(),
            remote_file: SshRemoteFile::default(),
            unknown: BTreeMap::new(),
        }
    }

    // A tunnel to a database file on the SSH host, which only the macOS app opens.
    pub fn opens_remote_file(&self) -> bool {
        self.enabled && self.remote_file.path.as_deref().is_some_and(|path| !path.is_empty())
    }

    // What a form that edits where the tunnel goes and how it signs in leaves out keeps its stored value.
    pub fn kept_over(mut self, stored: Option<&Self>) -> Self {
        if let Some(stored) = stored {
            self.agent_socket.clone_from(&stored.agent_socket);
            self.totp = stored.totp;
            self.remote_file.clone_from(&stored.remote_file);
            self.unknown.clone_from(&stored.unknown);
            self.keep_hops_from(stored);
            // A form with no None choice shows it as the agent, which both transports try after none.
            if stored.auth == SavedSshAuth::None && self.auth == SavedSshAuth::Agent {
                self.auth = SavedSshAuth::None;
            }
            self.kept_key_path = match (&self.auth, &stored.auth) {
                (SavedSshAuth::PrivateKey { .. }, _) => None,
                (_, SavedSshAuth::PrivateKey { path: Some(path), .. }) => Some(path.clone()),
                _ => stored.kept_key_path.clone(),
            };
        }
        self
    }

    // A hop typed again as text has no id, auth or key; one that reaches the same place keeps the stored hop's.
    pub fn keep_hops_from(&mut self, stored: &Self) {
        for (index, hop) in self.jump_hosts.iter_mut().enumerate() {
            if !hop.is_plain() {
                continue;
            }
            let same = stored
                .jump_hosts
                .get(index)
                .filter(|held| held.same_place(hop))
                .or_else(|| stored.jump_hosts.iter().find(|held| held.same_place(hop)));
            if let Some(held) = same {
                hop.clone_from(held);
            }
        }
    }
}

fn switched_on() -> bool {
    true
}

fn is_on(enabled: &bool) -> bool {
    *enabled
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SavedSshAuth {
    Agent,
    PrivateKey {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<PathBuf>,
        #[serde(default)]
        has_passphrase: bool,
    },
    Password,
    KeyboardInteractive,
    // The server asks for nothing.
    None,
}

// Stored as OpenSSH writes it, `user@host:port`, while it says nothing more, so a build that keeps hops as text reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshJumpHost {
    pub id: Option<Uuid>,
    pub host: String,
    pub port: Option<u16>,
    pub username: Option<String>,
    // None tries what OpenSSH's own configuration says.
    pub auth: Option<SshJumpAuth>,
    pub key_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SshJumpAuth {
    Agent,
    PrivateKey,
}

impl SshJumpHost {
    pub fn new(host: impl Into<String>, port: Option<u16>, username: Option<String>) -> Self {
        Self {
            id: None,
            host: host.into(),
            port,
            username,
            auth: None,
            key_path: None,
        }
    }

    // What does not read as a port stays in the host, for the connect to refuse.
    pub fn parse_list(list: &str) -> Vec<Self> {
        list.split(',')
            .map(str::trim)
            .filter(|entry| !entry.is_empty())
            .map(Self::parse)
            .collect()
    }

    fn parse(entry: &str) -> Self {
        let (username, rest) = match entry.rsplit_once('@') {
            Some((user, rest)) => (Some(user.to_owned()), rest),
            None => (None, entry),
        };
        let (host, port) = match rest.strip_prefix('[').and_then(|inner| inner.split_once(']')) {
            Some((host, "")) => (host, None),
            Some((host, after)) => match after.strip_prefix(':').and_then(|port| port.parse().ok()) {
                Some(port) => (host, Some(port)),
                None => (rest, None),
            },
            None => match rest.rsplit_once(':') {
                Some((host, port)) if !host.contains(':') => match port.parse().ok() {
                    Some(port) => (host, Some(port)),
                    None => (rest, None),
                },
                _ => (rest, None),
            },
        };
        Self::new(host, port, username)
    }

    pub fn destination(&self) -> String {
        let mut text = String::new();
        if let Some(user) = &self.username {
            text.push_str(user);
            text.push('@');
        }
        if self.host.contains(':') {
            text.push('[');
            text.push_str(&self.host);
            text.push(']');
        } else {
            text.push_str(&self.host);
        }
        if let Some(port) = self.port {
            text.push(':');
            text.push_str(&port.to_string());
        }
        text
    }

    pub fn is_plain(&self) -> bool {
        self.id.is_none() && self.auth.is_none() && self.key_path.is_none()
    }

    // Text only while it reads back as this hop, so a host or user with a comma, a bracket or a blank in it stays whole.
    fn reads_back_as_text(&self) -> bool {
        self.is_plain() && Self::parse_list(&self.destination()) == std::slice::from_ref(self)
    }

    pub fn same_place(&self, other: &Self) -> bool {
        self.host == other.host && self.port == other.port && self.username == other.username
    }
}

// The secret is in the secret store.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshTotp {
    #[serde(default)]
    pub mode: SshTotpMode,
    #[serde(default)]
    pub algorithm: SshTotpAlgorithm,
    #[serde(default = "SshTotp::default_digits")]
    pub digits: u32,
    #[serde(default = "SshTotp::default_period")]
    pub period: u32,
}

impl SshTotp {
    fn default_digits() -> u32 {
        6
    }

    fn default_period() -> u32 {
        30
    }

    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }
}

impl Default for SshTotp {
    fn default() -> Self {
        Self {
            mode: SshTotpMode::default(),
            algorithm: SshTotpAlgorithm::default(),
            digits: Self::default_digits(),
            period: Self::default_period(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SshTotpMode {
    #[default]
    Off,
    AutoGenerate,
    PromptAtConnect,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SshTotpAlgorithm {
    #[default]
    Sha1,
    Sha256,
    Sha512,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshRemoteFile {
    // As typed: `~` and a relative path resolve on the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default)]
    pub access: RemoteFileAccess,
}

impl SshRemoteFile {
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteFileAccess {
    // A read-only copy fetched over SFTP, which a connection saved before the live mode reads as.
    #[default]
    ReadOnlyCopy,
    // Statements run on the server against the live file.
    OnServer,
}

mod jump_list {
    use std::path::PathBuf;

    use serde::ser::SerializeSeq;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use uuid::Uuid;

    use super::{SshJumpAuth, SshJumpHost};

    #[derive(Serialize, Deserialize)]
    struct Hop {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<Uuid>,
        host: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        port: Option<u16>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        username: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        auth: Option<SshJumpAuth>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        key_path: Option<PathBuf>,
    }

    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Stored {
        Text(String),
        Hop(Hop),
    }

    pub(super) fn serialize<S: Serializer>(hops: &[SshJumpHost], serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(hops.len()))?;
        for hop in hops {
            if hop.reads_back_as_text() {
                seq.serialize_element(&hop.destination())?;
            } else {
                seq.serialize_element(&Hop {
                    id: hop.id,
                    host: hop.host.clone(),
                    port: hop.port,
                    username: hop.username.clone(),
                    auth: hop.auth,
                    key_path: hop.key_path.clone(),
                })?;
            }
        }
        seq.end()
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<SshJumpHost>, D::Error> {
        let mut hops = Vec::new();
        for stored in Vec::<Stored>::deserialize(deserializer)? {
            match stored {
                Stored::Text(list) => hops.extend(SshJumpHost::parse_list(&list)),
                Stored::Hop(hop) => hops.push(SshJumpHost {
                    id: hop.id,
                    host: hop.host,
                    port: hop.port,
                    username: hop.username,
                    auth: hop.auth,
                    key_path: hop.key_path,
                }),
            }
        }
        Ok(hops)
    }
}

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]
mod tests {
    use serde_json::json;

    use super::*;

    fn read(value: Value) -> SavedSshConfig {
        serde_json::from_value(value).expect("ssh settings")
    }

    #[test]
    fn a_list_written_as_text_reads_hop_by_hop_and_writes_back_as_text() {
        let ssh = read(json!({
            "host": "bastion",
            "jump_hosts": ["ops@jump1:2200, jump2", "[::1]:22"],
            "auth": {"kind": "agent"}
        }));

        assert_eq!(
            ssh.jump_hosts,
            vec![
                SshJumpHost::new("jump1", Some(2200), Some("ops".to_owned())),
                SshJumpHost::new("jump2", None, None),
                SshJumpHost::new("::1", Some(22), None),
            ]
        );
        assert_eq!(
            serde_json::to_value(&ssh).expect("json")["jump_hosts"],
            json!(["ops@jump1:2200", "jump2", "[::1]:22"])
        );
    }

    #[test]
    fn a_hop_with_an_id_or_a_key_is_an_object() {
        let id = Uuid::new_v4();
        let ssh = read(json!({
            "host": "bastion",
            "jump_hosts": [
                {"id": id, "host": "jump", "username": "ops", "auth": "private_key", "key_path": "/k"},
                "plain"
            ],
            "auth": {"kind": "none"}
        }));

        assert_eq!(ssh.auth, SavedSshAuth::None);
        assert_eq!(ssh.jump_hosts[0].id, Some(id));
        assert_eq!(ssh.jump_hosts[0].auth, Some(SshJumpAuth::PrivateKey));
        assert_eq!(
            serde_json::to_value(&ssh).expect("json")["jump_hosts"],
            json!([
                {"id": id, "host": "jump", "username": "ops", "auth": "private_key", "key_path": "/k"},
                "plain"
            ])
        );
    }

    #[test]
    fn a_hop_the_text_form_would_change_is_written_whole() {
        let mut ssh = SavedSshConfig::new("bastion", SavedSshAuth::Agent);
        ssh.jump_hosts = vec![
            SshJumpHost::new(" edge ", Some(22), Some("ops".to_owned())),
            SshJumpHost::new("a,b", None, None),
            SshJumpHost::new("jump", None, Some("me@corp".to_owned())),
            SshJumpHost::new("plain", Some(2222), None),
        ];

        let written = serde_json::to_value(&ssh).expect("json");
        let read: SavedSshConfig = serde_json::from_value(written.clone()).expect("ssh settings");

        assert_eq!(read.jump_hosts, ssh.jump_hosts);
        assert_eq!(written["jump_hosts"][3], json!("plain:2222"));
    }

    #[test]
    fn what_does_not_read_as_a_port_stays_in_the_host() {
        assert_eq!(
            SshJumpHost::parse_list("jump:ssh, [::1, a@b@c:7"),
            vec![
                SshJumpHost::new("jump:ssh", None, None),
                SshJumpHost::new("[::1", None, None),
                SshJumpHost::new("c", Some(7), Some("a@b".to_owned())),
            ]
        );
    }

    #[test]
    fn a_tunnel_switched_off_keeps_its_settings_and_a_newer_key() {
        let ssh = read(json!({
            "enabled": false,
            "host": "bastion",
            "auth": {"kind": "password"},
            "agent_socket": "~/.1password/agent.sock",
            "kept_key_path": "~/.ssh/id_ed25519",
            "totp": {"mode": "auto_generate", "algorithm": "sha256", "digits": 8, "period": 30},
            "remote_file": {"path": "~/app.db", "access": "on_server"},
            "compression": true
        }));

        assert!(!ssh.enabled);
        assert_eq!(ssh.kept_key_path, Some(PathBuf::from("~/.ssh/id_ed25519")));
        assert_eq!(ssh.totp.digits, 8);
        assert_eq!(ssh.remote_file.access, RemoteFileAccess::OnServer);
        assert_eq!(ssh.unknown.get("compression"), Some(&json!(true)));
        let written = serde_json::to_value(&ssh).expect("json");
        assert_eq!(written["enabled"], json!(false));
        assert_eq!(written["compression"], json!(true));
        assert_eq!(read(written), ssh);
    }

    #[test]
    fn the_defaults_are_left_out() {
        let ssh = SavedSshConfig::new("bastion", SavedSshAuth::Agent);

        assert_eq!(
            serde_json::to_value(&ssh).expect("json"),
            json!({"host": "bastion", "auth": {"kind": "agent"}})
        );
    }

    #[test]
    fn a_form_edit_keeps_what_the_form_does_not_show() {
        let mut stored = SavedSshConfig::new(
            "bastion",
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/k")),
                has_passphrase: false,
            },
        );
        stored.agent_socket = Some(PathBuf::from("~/agent.sock"));
        stored.totp.mode = SshTotpMode::PromptAtConnect;
        stored.unknown.insert("compression".to_owned(), json!(true));

        let edited = SavedSshConfig::new("other", SavedSshAuth::Password).kept_over(Some(&stored));

        assert_eq!(edited.host, "other");
        assert_eq!(edited.auth, SavedSshAuth::Password);
        assert_eq!(edited.kept_key_path, Some(PathBuf::from("/k")));
        assert_eq!(edited.agent_socket, stored.agent_socket);
        assert_eq!(edited.totp, stored.totp);
        assert_eq!(edited.unknown, stored.unknown);
        let none = SavedSshConfig::new("bastion", SavedSshAuth::None);
        assert_eq!(
            SavedSshConfig::new("bastion", SavedSshAuth::Agent)
                .kept_over(Some(&none))
                .auth,
            SavedSshAuth::None
        );
    }

    #[test]
    fn a_hop_typed_again_keeps_the_stored_hops_id_and_key() {
        let mut stored = SavedSshConfig::new("bastion", SavedSshAuth::Agent);
        let held = SshJumpHost {
            id: Some(Uuid::new_v4()),
            auth: Some(SshJumpAuth::PrivateKey),
            key_path: Some(PathBuf::from("/k")),
            ..SshJumpHost::new("jump", Some(22), Some("ops".to_owned()))
        };
        stored.jump_hosts = vec![held.clone()];
        let mut typed = stored.clone();
        typed.jump_hosts = SshJumpHost::parse_list("other, ops@jump:22");

        typed.keep_hops_from(&stored);

        assert_eq!(typed.jump_hosts, vec![SshJumpHost::new("other", None, None), held]);
    }
}
