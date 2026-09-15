use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tablepro_core::AuthMode;
use uuid::Uuid;

use crate::error::StorageError;

const CURRENT_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedConnection {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    pub use_tls: bool,
    #[serde(default)]
    pub read_only: bool,
    #[serde(default)]
    pub auth_mode: AuthMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<SavedSshConfig>,
    /// Last successful open of this connection. Drives the welcome
    /// view's recency-first sort. `None` for connections saved before
    /// this field shipped (legacy files just deserialize into None);
    /// they sort after every connection that has been opened at least
    /// once and fall back to alphabetical against each other.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_opened_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSshConfig {
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub jump_hosts: Vec<String>,
    pub auth: SavedSshAuth,
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
}

#[derive(Debug, Serialize, Deserialize)]
struct ConnectionsFile {
    version: u32,
    connections: Vec<SavedConnection>,
}

/// The saved-connection list on disk. One store per storage root, so a
/// development build and an installed build never share a file.
#[derive(Debug, Clone)]
pub struct ConnectionStore {
    path: PathBuf,
}

impl ConnectionStore {
    pub fn new(paths: &crate::StoragePaths) -> Self {
        Self {
            path: paths.connections_file(),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn load(&self) -> Result<Vec<SavedConnection>, StorageError> {
        load_from(&self.path).await
    }

    pub async fn save(&self, connections: &[SavedConnection]) -> Result<(), StorageError> {
        save_to(&self.path, connections).await
    }

    pub async fn delete(&self, id: Uuid) -> Result<(), StorageError> {
        let mut existing = self.load().await.unwrap_or_default();
        existing.retain(|connection| connection.id != id);
        self.save(&existing).await
    }

    /// Stamp `last_opened_at = now()` on the matching connection, so the
    /// welcome view can sort recency-first. A connection opened from the
    /// dialog without ticking Save is not in the file, and that is not an
    /// error: there is nothing to update.
    pub async fn touch_last_opened(&self, id: Uuid) -> Result<(), StorageError> {
        let mut existing = self.load().await.unwrap_or_default();
        let Some(connection) = existing.iter_mut().find(|connection| connection.id == id) else {
            return Ok(());
        };
        connection.last_opened_at = Some(Utc::now());
        self.save(&existing).await
    }
}

async fn load_from(path: &Path) -> Result<Vec<SavedConnection>, StorageError> {
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(source) => {
            return Err(StorageError::Io {
                path: path.to_owned(),
                source,
            });
        }
    };
    let file: ConnectionsFile = serde_json::from_slice(&bytes)?;
    if file.version != CURRENT_VERSION {
        return Err(StorageError::Schema(format!(
            "connections.json version {} not supported (expected {})",
            file.version, CURRENT_VERSION,
        )));
    }
    Ok(file.connections)
}

async fn save_to(path: &Path, connections: &[SavedConnection]) -> Result<(), StorageError> {
    let file = ConnectionsFile {
        version: CURRENT_VERSION,
        connections: connections.to_vec(),
    };
    let json = serde_json::to_vec_pretty(&file)?;
    let path = path.to_owned();
    // The durable write blocks on fsync, which must not run on the GTK
    // thread or a tokio worker that other futures share.
    tokio::task::spawn_blocking(move || crate::fs::write_private_blocking(&path, &json))
        .await
        .map_err(|error| StorageError::Schema(format!("the connections write task failed: {error}")))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn sample_connection() -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Local Postgres".into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            username: "postgres".into(),
            use_tls: false,
            read_only: false,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
        }
    }

    #[tokio::test]
    async fn load_returns_empty_when_file_missing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let result = load_from(&path).await.unwrap();
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn save_then_load_round_trips() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let original = vec![sample_connection()];
        save_to(&path, &original).await.unwrap();
        let loaded = load_from(&path).await.unwrap();
        assert_eq!(original, loaded);
    }

    #[tokio::test]
    async fn save_creates_parent_directory() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested/dir/connections.json");
        save_to(&path, &[]).await.unwrap();
        assert!(path.exists());
    }

    #[tokio::test]
    async fn load_rejects_unknown_version() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        tokio::fs::write(&path, r#"{"version":999,"connections":[]}"#)
            .await
            .unwrap();
        let err = load_from(&path).await.unwrap_err();
        assert!(matches!(err, StorageError::Schema(_)));
    }

    #[tokio::test]
    async fn load_accepts_legacy_files_without_ssh_field() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let id = Uuid::new_v4();
        let legacy = format!(
            r#"{{"version":1,"connections":[{{
                "id":"{id}","name":"Old","driver_id":"postgres",
                "host":"localhost","port":5432,"database":"postgres",
                "username":"postgres","use_tls":false}}]}}"#
        );
        tokio::fs::write(&path, legacy).await.unwrap();
        let loaded = load_from(&path).await.unwrap();
        assert_eq!(loaded.len(), 1);
        assert!(loaded[0].ssh.is_none());
    }

    #[tokio::test]
    async fn saved_ssh_config_round_trips_optional_port_user_and_jumps() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let mut full = sample_connection();
        full.ssh = Some(SavedSshConfig {
            host: "bastion.example.com".into(),
            port: Some(2222),
            username: Some("deploy".into()),
            jump_hosts: vec!["ops@jump1:2200".into(), "[fd00::1]".into()],
            auth: SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: true,
            },
        });
        let mut minimal = sample_connection();
        minimal.ssh = Some(SavedSshConfig {
            host: "bastion".into(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        });

        save_to(&path, &[full.clone(), minimal.clone()]).await.unwrap();
        assert_eq!(load_from(&path).await.unwrap(), vec![full, minimal]);

        let raw: serde_json::Value = serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
        let minimal_ssh = &raw["connections"][1]["ssh"];
        assert!(minimal_ssh.get("port").is_none());
        assert!(minimal_ssh.get("username").is_none());
        assert!(minimal_ssh.get("jump_hosts").is_none());
    }

    #[test]
    fn each_ssh_auth_mode_round_trips() {
        let cases = [
            (SavedSshAuth::Agent, "agent"),
            (
                SavedSshAuth::PrivateKey {
                    path: None,
                    has_passphrase: false,
                },
                "private_key",
            ),
            (SavedSshAuth::Password, "password"),
            (SavedSshAuth::KeyboardInteractive, "keyboard_interactive"),
        ];
        for (auth, kind) in cases {
            let json = serde_json::to_value(&auth).unwrap();
            assert_eq!(json["kind"], kind);
            assert_eq!(serde_json::from_value::<SavedSshAuth>(json).unwrap(), auth);
        }
    }

    #[test]
    fn unknown_ssh_auth_kind_fails_to_parse() {
        assert!(serde_json::from_str::<SavedSshAuth>(r#"{"kind":"gssapi"}"#).is_err());
    }

    #[tokio::test]
    async fn auth_mode_defaults_to_password_on_a_legacy_file() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let id = Uuid::new_v4();
        let legacy = format!(
            r#"{{"version":1,"connections":[{{
                "id":"{id}","name":"Old","driver_id":"mssql",
                "host":"localhost","port":1433,"database":"db",
                "username":"sa","use_tls":false}}]}}"#
        );
        tokio::fs::write(&path, legacy).await.unwrap();
        let loaded = load_from(&path).await.unwrap();
        assert_eq!(loaded[0].auth_mode, AuthMode::Password);
    }

    #[tokio::test]
    async fn kerberos_is_written_as_snake_case_and_reads_back() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let mut conn = sample_connection();
        conn.auth_mode = AuthMode::Kerberos;
        save_to(&path, &[conn.clone()]).await.unwrap();
        let raw: serde_json::Value = serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
        assert_eq!(raw["connections"][0]["auth_mode"], "kerberos");
        assert_eq!(load_from(&path).await.unwrap(), vec![conn]);
    }

    /// Pins the reader against a file already on disk. Renaming the
    /// variant fails here instead of orphaning every saved connection:
    /// an unparseable file loads as empty, and the next successful
    /// connect writes that empty list back.
    #[tokio::test]
    async fn a_file_written_with_kerberos_still_loads() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let id = Uuid::new_v4();
        let on_disk = format!(
            r#"{{"version":1,"connections":[{{
                "id":"{id}","name":"Corp","driver_id":"mssql",
                "host":"sql.corp.example","port":1433,"database":"sales",
                "username":"","use_tls":true,"auth_mode":"kerberos"}}]}}"#
        );
        tokio::fs::write(&path, on_disk).await.unwrap();
        let loaded = load_from(&path).await.unwrap();
        assert_eq!(loaded[0].auth_mode, AuthMode::Kerberos);
    }
}
