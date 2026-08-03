use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::{AuthMode, ConnectOptions, Connection, DriverRegistry, ReadOnlyConnection, TableInfo};
use tablepro_ssh::{SshConfig, SshTunnel};
use tablepro_storage::{SavedConnection, SavedSshAuth, load_password, load_ssh_passphrase, load_ssh_password};

use super::database_service::{self, ConnectionMetadata, ReconnectParams};

pub async fn open_saved(registry: Arc<DriverRegistry>, saved: SavedConnection) -> Result<Vec<TableInfo>, String> {
    let driver = registry
        .get(&saved.driver_id)
        .ok_or_else(|| format!("driver {} not registered", saved.driver_id))?;
    // Kerberos never had a secret of ours to store, so there is nothing
    // to read back.
    let password = match saved.auth_mode {
        AuthMode::Kerberos => SecretString::new(String::new().into()),
        AuthMode::Password => load_password(saved.id)
            .await
            .ok()
            .flatten()
            .unwrap_or_else(|| SecretString::new(String::new().into())),
    };
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
        service_endpoint: None,
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
    check_auth_mode(opts.auth_mode, driver.supports_integrated_auth(), driver.display_name())?;
    let tunnel = if let Some(cfg) = ssh {
        let remote = (std::mem::take(&mut opts.host), opts.port);
        let tun = SshTunnel::open(cfg, remote.0.clone(), remote.1)
            .await
            .map_err(|e| format!("ssh: {e}"))?;
        redirect_through_tunnel(&mut opts, remote, (tun.local_host().to_string(), tun.local_port()));
        Some(tun)
    } else {
        None
    };
    let raw = driver
        .connect(opts)
        .await
        .map_err(|e| crate::ui::error_text::driver_message(&e))?;
    let conn = if read_only { ReadOnlyConnection::wrap(raw) } else { raw };
    Ok((conn, tunnel))
}

/// The socket has to point at the local forward while the service keeps
/// its own name: without the remembered endpoint Kerberos would ask the
/// KDC for MSSQLSvc/127.0.0.1:<ephemeral port>, and TLS would validate
/// the certificate against the same wrong name.
fn redirect_through_tunnel(opts: &mut ConnectOptions, remote: (String, u16), local: (String, u16)) {
    opts.service_endpoint = Some(remote);
    opts.host = local.0;
    opts.port = local.1;
}

/// A saved connection carries its auth mode, so a file edited by hand
/// can name a mode the driver never implements. Password would then be
/// sent as an empty string and the login would fail as a credential
/// problem rather than a configuration one.
fn check_auth_mode(mode: AuthMode, supports_integrated: bool, driver_name: &str) -> Result<(), String> {
    if mode == AuthMode::Kerberos && !supports_integrated {
        return Err(
            crate::tr!("The {driver} driver does not support Windows (Kerberos) authentication.")
                .replace("{driver}", driver_name),
        );
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tunnel_moves_the_socket_and_keeps_the_service_name() {
        let mut opts = ConnectOptions {
            host: "127.0.0.1".into(),
            port: 54321,
            ..Default::default()
        };
        redirect_through_tunnel(
            &mut opts,
            ("sql.corp.example".into(), 1433),
            ("127.0.0.1".into(), 54321),
        );
        assert_eq!(opts.host, "127.0.0.1");
        assert_eq!(opts.port, 54321);
        assert_eq!(opts.service_address(), ("sql.corp.example", 1433));
    }

    #[test]
    fn kerberos_is_refused_for_a_driver_that_cannot_perform_it() {
        assert!(check_auth_mode(AuthMode::Kerberos, false, "PostgreSQL").is_err());
        assert!(check_auth_mode(AuthMode::Kerberos, true, "SQL Server").is_ok());
        assert!(check_auth_mode(AuthMode::Password, false, "PostgreSQL").is_ok());
    }
}
