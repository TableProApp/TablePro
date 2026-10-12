use std::path::PathBuf;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{
    AuthMode, Credentials, DriverError, DriverRegistry, FileEndpoint, NetworkEndpoint, WorkspaceSettings,
};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination};
use tablepro_storage::{CredentialDemand, SavedConnection, SavedSshAuth, SavedSshConfig};

use super::{ConnectError, ConnectRequest, ConnectionMetadata, CredentialSource, RefreshedRequest, RequestTarget};

/// The request a saved connection makes, with its secrets read through
/// `credentials`.
///
/// The request is built with empty secrets and refreshed before it is
/// returned, so a saved login without its password can never reach a
/// driver: the credential source either fills it or fails.
pub async fn resolve_saved(
    saved: &SavedConnection,
    drivers: &DriverRegistry,
    credentials: &dyn CredentialSource,
    interaction: CredentialInteraction,
    demand: CredentialDemand,
) -> Result<RefreshedRequest, ConnectError> {
    let request = saved_request(saved, drivers)?;
    credentials.refresh(request, interaction, demand).await
}

fn saved_request(saved: &SavedConnection, drivers: &DriverRegistry) -> Result<ConnectRequest, ConnectError> {
    let driver = drivers
        .get(&saved.driver_id)
        .ok_or_else(|| ConnectError::UnknownDriver(saved.driver_id.clone()))?;
    let target = if driver.capabilities().is_file_based() {
        let endpoint = FileEndpoint::open_existing(PathBuf::from(&saved.database)).map_err(DriverError::from)?;
        RequestTarget::File(endpoint)
    } else {
        let endpoint = NetworkEndpoint::new(&saved.host, saved.port).map_err(DriverError::from)?;
        let ssh = saved
            .ssh
            .as_ref()
            .map(ssh_config)
            .transpose()
            .map_err(|failure| DriverError::from(tablepro_core::TransportError::Ssh(failure)))?;
        let credentials = match saved.auth_mode {
            AuthMode::Password => Credentials::Password {
                username: saved.username.clone(),
                password: SecretString::from(String::new()),
            },
            AuthMode::Kerberos => Credentials::Integrated,
        };
        RequestTarget::Network {
            endpoint,
            ssh,
            credentials,
            database: Some(saved.database.clone()).filter(|name| !name.trim().is_empty()),
            tls: saved.tls.clone(),
        }
    };
    Ok(ConnectRequest {
        metadata: ConnectionMetadata {
            id: saved.id,
            name: saved.name.clone(),
            driver_id: saved.driver_id.clone(),
        },
        driver,
        target,
        workspace_settings: WorkspaceSettings::workspace(saved.read_only),
    })
}

/// The OpenSSH configuration a saved SSH section describes, with no
/// secrets yet.
pub fn ssh_config(saved: &SavedSshConfig) -> Result<SshConfig, tablepro_core::SshFailure> {
    let destination = SshDestination::new(&saved.host, saved.port, saved.username.clone())?;
    let mut jump_hosts = Vec::new();
    for entry in &saved.jump_hosts {
        jump_hosts.extend(SshDestination::parse_jump_list(entry)?);
    }
    let auth = match &saved.auth {
        SavedSshAuth::Agent => SshAuth::Agent,
        SavedSshAuth::PrivateKey { path, .. } => SshAuth::PrivateKey {
            path: path.clone(),
            passphrase: None,
        },
        SavedSshAuth::Password => SshAuth::Password {
            password: SecretString::from(String::new()),
        },
        SavedSshAuth::KeyboardInteractive => SshAuth::KeyboardInteractive,
    };
    Ok(SshConfig {
        destination,
        jump_hosts,
        auth,
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use secrecy::ExposeSecret;
    use tablepro_core::credentials::{SecretKind, SecretVault};
    use tablepro_core::{ConfigError, SshFailure, TlsConfig, TransportError};
    use tablepro_storage::{KeyringCredentials, KeyringError};
    use tablepro_test_support::{ConnectionScript, FakeDriver, FakeSecretVault};
    use uuid::Uuid;

    use super::*;
    use crate::connect::NoStoredCredentials;

    fn drivers() -> DriverRegistry {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(FakeDriver::connecting(
            &FakeDriver::NETWORK_CAPABILITIES,
            ConnectionScript::default(),
        )));
        drivers
    }

    fn saved(ssh: Option<SavedSshConfig>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Prod".to_owned(),
            driver_id: "fake".to_owned(),
            host: "db.example.com".to_owned(),
            port: 5432,
            database: "shop".to_owned(),
            username: "app".to_owned(),
            tls: TlsConfig::verify_full(),
            read_only: true,
            auth_mode: AuthMode::Password,
            ssh,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    fn bastion(auth: SavedSshAuth) -> SavedSshConfig {
        SavedSshConfig {
            host: "bastion.example.com".to_owned(),
            port: Some(2222),
            username: Some("deploy".to_owned()),
            jump_hosts: vec!["ops@jump1:2200,jump2".to_owned()],
            auth,
        }
    }

    #[tokio::test]
    async fn a_saved_connection_resolves_with_its_stored_secrets() {
        let saved = saved(Some(bastion(SavedSshAuth::Password)));
        let vault = Arc::new(FakeSecretVault::new());
        vault
            .store(
                saved.id,
                SecretKind::DatabasePassword,
                &SecretString::from("db"),
                "label",
            )
            .await
            .unwrap();
        vault
            .store(saved.id, SecretKind::SshPassword, &SecretString::from("ssh"), "label")
            .await
            .unwrap();
        let credentials = KeyringCredentials::for_saved(vault, &saved);

        let refreshed = resolve_saved(
            &saved,
            &drivers(),
            &credentials,
            CredentialInteraction::Unattended,
            CredentialDemand::default(),
        )
        .await
        .unwrap();

        let request = refreshed.request;
        assert_eq!(request.metadata.id, saved.id);
        assert!(request.workspace_settings.read_only);
        let RequestTarget::Network {
            endpoint,
            ssh: Some(ssh),
            credentials: Credentials::Password { username, password },
            database,
            tls,
        } = request.target
        else {
            panic!("expected a network target over ssh with a password");
        };
        assert_eq!(endpoint.to_string(), "db.example.com:5432");
        assert_eq!(username, "app");
        assert_eq!(password.expose_secret(), "db");
        assert_eq!(database.as_deref(), Some("shop"));
        assert_eq!(tls, TlsConfig::verify_full());
        assert_eq!(ssh.destination.to_string(), "deploy@bastion.example.com:2222");
        let jumps: Vec<String> = ssh.jump_hosts.iter().map(ToString::to_string).collect();
        assert_eq!(jumps, ["ops@jump1:2200", "jump2"]);
        let SshAuth::Password { password } = ssh.auth else {
            panic!("expected ssh password auth");
        };
        assert_eq!(password.expose_secret(), "ssh");
    }

    #[tokio::test]
    async fn a_saved_password_that_is_not_stored_never_becomes_an_empty_login() {
        let saved = saved(None);
        let credentials = KeyringCredentials::for_saved(Arc::new(FakeSecretVault::new()), &saved);

        let refused = resolve_saved(
            &saved,
            &drivers(),
            &credentials,
            CredentialInteraction::Unattended,
            CredentialDemand::default(),
        )
        .await;

        assert_eq!(
            refused.unwrap_err(),
            ConnectError::Keyring(KeyringError::SecretNotStored {
                kind: SecretKind::DatabasePassword
            })
        );
    }

    #[tokio::test]
    async fn an_unknown_driver_and_a_bad_host_are_reported() {
        let mut unknown = saved(None);
        unknown.driver_id = "oracle".to_owned();
        let mut blank = saved(None);
        blank.host = "  ".to_owned();
        let mut bad_ssh = saved(Some(bastion(SavedSshAuth::Agent)));
        if let Some(ssh) = bad_ssh.ssh.as_mut() {
            ssh.host = "-oProxyCommand=evil".to_owned();
        }
        let resolve = |saved: SavedConnection| async move {
            resolve_saved(
                &saved,
                &drivers(),
                &NoStoredCredentials,
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await
        };

        assert_eq!(
            resolve(unknown).await.unwrap_err(),
            ConnectError::UnknownDriver("oracle".to_owned())
        );
        assert_eq!(
            resolve(blank).await.unwrap_err(),
            ConnectError::Driver(DriverError::Config(ConfigError::EmptyHost))
        );
        assert!(matches!(
            resolve(bad_ssh).await.unwrap_err(),
            ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
                SshFailure::InvalidDestination { .. }
            )))
        ));
    }

    #[tokio::test]
    async fn a_file_driver_opens_the_saved_path() {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(FakeDriver::connecting(
            &FakeDriver::FILE_CAPABILITIES,
            ConnectionScript::default(),
        )));
        let mut file = saved(None);
        file.database = "/srv/app.db".to_owned();

        let refreshed = resolve_saved(
            &file,
            &drivers,
            &NoStoredCredentials,
            CredentialInteraction::Unattended,
            CredentialDemand::default(),
        )
        .await
        .unwrap();

        let RequestTarget::File(endpoint) = refreshed.request.target else {
            panic!("a file driver resolved to a network target");
        };
        assert_eq!(endpoint.path(), std::path::Path::new("/srv/app.db"));
    }

    #[test]
    fn kerberos_logs_in_as_the_desktop_user() {
        let mut kerberos = saved(None);
        kerberos.auth_mode = AuthMode::Kerberos;

        let request = saved_request(&kerberos, &drivers()).unwrap();

        assert!(matches!(
            request.target,
            RequestTarget::Network {
                credentials: Credentials::Integrated,
                ..
            }
        ));
    }
}
