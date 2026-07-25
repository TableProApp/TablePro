use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::{ConnectOptions, Connection, DriverRegistry, ReadOnlyConnection, TableInfo};
use tablepro_ssh::{SshConfig, SshTunnel};
use tablepro_storage::{SavedConnection, SavedSshAuth, load_password, load_ssh_passphrase, load_ssh_password};

use super::database_service::{self, ConnectionMetadata, ReconnectParams};

pub async fn open_saved(registry: Arc<DriverRegistry>, saved: SavedConnection) -> Result<Vec<TableInfo>, String> {
    let driver = registry
        .get(&saved.driver_id)
        .ok_or_else(|| format!("driver {} not registered", saved.driver_id))?;
    let password = load_password(saved.id)
        .await
        .ok()
        .flatten()
        .unwrap_or_else(|| SecretString::new(String::new().into()));
    let id = saved.id;

    let ssh_cfg = match &saved.ssh {
        Some(ssh) => Some(resolve_saved_ssh(id, ssh).await?),
        None => None,
    };

    let opts = ConnectOptions {
        host: saved.host,
        port: saved.port,
        database: saved.database,
        username: saved.username,
        password,
        use_tls: saved.use_tls,
        auth_mode: saved.auth_mode,
    };

    let (conn, tunnel) = establish(&*driver, opts.clone(), ssh_cfg.clone(), saved.read_only).await?;
    let tables = conn.list_tables().await.map_err(|e| format!("list_tables: {e}"))?;
    let metadata = ConnectionMetadata {
        id,
        name: saved.name.clone(),
        driver_id: saved.driver_id.clone(),
    };
    let params = ReconnectParams {
        driver,
        opts,
        ssh: ssh_cfg,
        read_only: saved.read_only,
    };
    database_service::instance().add(id, metadata, conn, tunnel, saved.read_only, params);
    Ok(tables)
}

pub async fn establish(
    driver: &dyn tablepro_core::DatabaseDriver,
    mut opts: ConnectOptions,
    ssh: Option<SshConfig>,
    read_only: bool,
) -> Result<(Box<dyn Connection>, Option<SshTunnel>), String> {
    let tunnel = if let Some(cfg) = ssh {
        let remote_host = std::mem::take(&mut opts.host);
        let remote_port = opts.port;
        let tun = SshTunnel::open(cfg, remote_host, remote_port)
            .await
            .map_err(|e| format!("ssh: {e}"))?;
        opts.host = tun.local_host().to_string();
        opts.port = tun.local_port();
        Some(tun)
    } else {
        None
    };
    let raw = driver.connect(opts).await.map_err(|e| format!("connect: {e}"))?;
    let conn = if read_only { ReadOnlyConnection::wrap(raw) } else { raw };
    Ok((conn, tunnel))
}

async fn resolve_saved_ssh(id: uuid::Uuid, saved: &tablepro_storage::SavedSshConfig) -> Result<SshConfig, String> {
    let auth = match &saved.auth {
        SavedSshAuth::Password => {
            let pw = load_ssh_password(id)
                .await
                .map_err(|e| format!("load ssh password: {e}"))?
                .ok_or_else(|| "ssh password not in keyring".to_string())?;
            tablepro_ssh::SshAuth::Password { password: pw }
        }
        SavedSshAuth::PrivateKey { path, has_passphrase } => {
            let passphrase = if *has_passphrase {
                load_ssh_passphrase(id)
                    .await
                    .map_err(|e| format!("load ssh passphrase: {e}"))?
            } else {
                None
            };
            tablepro_ssh::SshAuth::PrivateKey {
                path: path.clone(),
                passphrase,
            }
        }
    };
    Ok(SshConfig {
        host: saved.host.clone(),
        port: saved.port,
        username: saved.username.clone(),
        auth,
    })
}
