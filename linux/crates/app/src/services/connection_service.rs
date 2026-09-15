use std::sync::Arc;

use secrecy::SecretString;
use std::path::PathBuf;
use tablepro_core::{AuthMode, ConnectOptions, Connection, DriverRegistry, ReadOnlyConnection, TableInfo};

use tablepro_core::credentials::{SecretKind, SecretVault};
use tablepro_ssh::russh_tunnel::{SshAuth, SshConfig, SshError, SshTunnel};
use tablepro_storage::{SavedConnection, SavedSshAuth, SavedSshConfig};

use super::database_service::{self, ConnectionMetadata, ReconnectParams};

pub async fn open_saved(
    registry: Arc<DriverRegistry>,
    secrets: Arc<dyn SecretVault>,
    saved: SavedConnection,
) -> Result<Vec<TableInfo>, String> {
    let driver = registry
        .get(&saved.driver_id)
        .ok_or_else(|| format!("driver {} not registered", saved.driver_id))?;
    // Kerberos never had a secret of ours to store, so there is nothing
    // to read back.
    let password = match saved.auth_mode {
        AuthMode::Kerberos => SecretString::new(String::new().into()),
        AuthMode::Password => secrets
            .load(saved.id, SecretKind::DatabasePassword)
            .await
            .map_err(|error| crate::ui::error_text::secret_message(&error))?
            .found()
            .ok_or_else(|| {
                // An empty password here used to reach the driver and
                // come back as a confusing authentication failure.
                crate::i18n::gettext_f("No password is stored for “{name}”.", &[("name", &saved.name)])
            })?,
    };
    let id = saved.id;

    let ssh_cfg = match &saved.ssh {
        Some(ssh) => Some(resolve_saved_ssh(&secrets, id, ssh).await?),
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
            .map_err(|e| crate::ui::error_text::ssh_message(&e))?;
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
        return Err(crate::i18n::gettext_f(
            "The {driver} driver does not support Windows (Kerberos) authentication.",
            &[("driver", driver_name)],
        ));
    }
    Ok(())
}

pub(crate) enum InterimSshAuth {
    Password,
    PrivateKey { path: PathBuf, has_passphrase: bool },
}

pub(crate) struct InterimSshTarget {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: InterimSshAuth,
}

pub(crate) fn interim_ssh_target(saved: &SavedSshConfig) -> Result<InterimSshTarget, SshError> {
    let refuse = |setting| Err(SshError::RequiresOpenSsh { setting });
    if !saved.jump_hosts.is_empty() {
        return refuse("SSH jump hosts");
    }
    let Some(port) = saved.port else {
        return refuse("an SSH connection without a port");
    };
    let Some(username) = saved.username.clone() else {
        return refuse("an SSH connection without a user name");
    };
    let auth = match &saved.auth {
        SavedSshAuth::Password => InterimSshAuth::Password,
        SavedSshAuth::PrivateKey {
            path: Some(path),
            has_passphrase,
        } => InterimSshAuth::PrivateKey {
            path: path.clone(),
            has_passphrase: *has_passphrase,
        },
        SavedSshAuth::PrivateKey { path: None, .. } => return refuse("a private key without a path"),
        SavedSshAuth::Agent => return refuse("SSH agent authentication"),
        SavedSshAuth::KeyboardInteractive => return refuse("keyboard-interactive SSH authentication"),
    };
    Ok(InterimSshTarget {
        host: saved.host.clone(),
        port,
        username,
        auth,
    })
}

async fn resolve_saved_ssh(
    secrets: &Arc<dyn SecretVault>,
    id: uuid::Uuid,
    saved: &SavedSshConfig,
) -> Result<SshConfig, String> {
    let target = interim_ssh_target(saved).map_err(|error| crate::ui::error_text::ssh_message(&error))?;
    let auth = match target.auth {
        InterimSshAuth::Password => {
            let password = secrets
                .load(id, SecretKind::SshPassword)
                .await
                .map_err(|error| crate::ui::error_text::secret_message(&error))?
                .found()
                .ok_or_else(|| crate::i18n::gettext("No SSH password is stored for this connection."))?;
            SshAuth::Password { password }
        }
        InterimSshAuth::PrivateKey { path, has_passphrase } => {
            let passphrase = if has_passphrase {
                secrets
                    .load(id, SecretKind::SshPassphrase)
                    .await
                    .map_err(|error| crate::ui::error_text::secret_message(&error))?
                    .found()
            } else {
                None
            };
            SshAuth::PrivateKey { path, passphrase }
        }
    };
    Ok(SshConfig {
        host: target.host,
        port: target.port,
        username: target.username,
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
    fn interim_tunnel_refuses_agent_before_network_io() {
        let agent = SavedSshConfig {
            host: "bastion".into(),
            port: Some(22),
            username: Some("deploy".into()),
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        };
        assert!(matches!(
            interim_ssh_target(&agent),
            Err(SshError::RequiresOpenSsh {
                setting: "SSH agent authentication"
            })
        ));
        let refused = [
            SavedSshConfig {
                jump_hosts: vec!["jump1".into()],
                auth: SavedSshAuth::Password,
                ..agent.clone()
            },
            SavedSshConfig {
                port: None,
                auth: SavedSshAuth::Password,
                ..agent.clone()
            },
            SavedSshConfig {
                username: None,
                auth: SavedSshAuth::Password,
                ..agent.clone()
            },
            SavedSshConfig {
                auth: SavedSshAuth::PrivateKey {
                    path: None,
                    has_passphrase: false,
                },
                ..agent.clone()
            },
            SavedSshConfig {
                auth: SavedSshAuth::KeyboardInteractive,
                ..agent.clone()
            },
        ];
        for saved in refused {
            assert!(matches!(
                interim_ssh_target(&saved),
                Err(SshError::RequiresOpenSsh { .. })
            ));
        }
        let password = SavedSshConfig {
            auth: SavedSshAuth::Password,
            ..agent
        };
        assert!(interim_ssh_target(&password).is_ok_and(|target| target.port == 22 && target.username == "deploy"));
    }

    #[test]
    fn kerberos_is_refused_for_a_driver_that_cannot_perform_it() {
        assert!(check_auth_mode(AuthMode::Kerberos, false, "PostgreSQL").is_err());
        assert!(check_auth_mode(AuthMode::Kerberos, true, "SQL Server").is_ok());
        assert!(check_auth_mode(AuthMode::Password, false, "PostgreSQL").is_ok());
    }
}
