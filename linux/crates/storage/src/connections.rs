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
    pub port: u16,
    pub username: String,
    pub auth: SavedSshAuth,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SavedSshAuth {
    Password,
    PrivateKey {
        path: PathBuf,
        #[serde(default)]
        has_passphrase: bool,
    },
}

#[derive(Debug, Serialize, Deserialize)]
struct ConnectionsFile {
    version: u32,
    connections: Vec<SavedConnection>,
}

pub async fn load_connections() -> Result<Vec<SavedConnection>, StorageError> {
    load_from(&connections_path()?).await
}

pub async fn save_connections(connections: &[SavedConnection]) -> Result<(), StorageError> {
    save_to(&connections_path()?, connections).await
}

pub async fn delete_connection(id: Uuid) -> Result<(), StorageError> {
    let mut existing = load_connections().await.unwrap_or_default();
    existing.retain(|c| c.id != id);
    save_connections(&existing).await
}

/// Stamp `last_opened_at = now()` on the matching connection. Called
/// once per successful open so the welcome view can sort recency-first.
/// No-op when `id` isn't in the file (e.g. an unsaved connection
/// opened from the dialog without ticking "Save"); the missing-id case
/// is silent because there is nothing to update.
pub async fn touch_last_opened(id: Uuid) -> Result<(), StorageError> {
    let mut existing = load_connections().await.unwrap_or_default();
    let mut hit = false;
    for c in existing.iter_mut() {
        if c.id == id {
            c.last_opened_at = Some(Utc::now());
            hit = true;
            break;
        }
    }
    if !hit {
        return Ok(());
    }
    save_connections(&existing).await
}

pub(crate) async fn load_from(path: &Path) -> Result<Vec<SavedConnection>, StorageError> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let bytes = tokio::fs::read(path).await?;
    let file: ConnectionsFile = serde_json::from_slice(&bytes)?;
    if file.version != CURRENT_VERSION {
        return Err(StorageError::Schema(format!(
            "connections.json version {} not supported (expected {})",
            file.version, CURRENT_VERSION,
        )));
    }
    Ok(file.connections)
}

pub(crate) async fn save_to(path: &Path, connections: &[SavedConnection]) -> Result<(), StorageError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let file = ConnectionsFile {
        version: CURRENT_VERSION,
        connections: connections.to_vec(),
    };
    let json = serde_json::to_vec_pretty(&file)?;
    let tmp = path.with_extension("json.tmp");
    tokio::fs::write(&tmp, &json).await?;
    tokio::fs::rename(&tmp, path).await?;
    Ok(())
}

fn connections_path() -> Result<PathBuf, StorageError> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| {
                let mut p = PathBuf::from(h);
                p.push(".config");
                p
            })
        })
        .ok_or_else(|| StorageError::Schema("neither XDG_CONFIG_HOME nor HOME is set".into()))?;
    Ok(base.join("tablepro").join("connections.json"))
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
    async fn ssh_config_round_trips() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("connections.json");
        let mut conn = sample_connection();
        conn.ssh = Some(SavedSshConfig {
            host: "bastion.example.com".into(),
            port: 22,
            username: "deploy".into(),
            auth: SavedSshAuth::PrivateKey {
                path: PathBuf::from("/home/u/.ssh/id_ed25519"),
                has_passphrase: true,
            },
        });
        save_to(&path, &[conn.clone()]).await.unwrap();
        let loaded = load_from(&path).await.unwrap();
        assert_eq!(loaded, vec![conn]);
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
}
