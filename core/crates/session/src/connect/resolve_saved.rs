use std::path::PathBuf;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{
    AuthMode, ConfigError, Credentials, DriverError, DriverRegistry, FileEndpoint, NetworkEndpoint, QueryTimeout,
    WorkspaceSettings,
};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination};
use tablepro_storage::{CredentialDemand, SavedConnection, SavedSshAuth, SavedSshConfig, SshJumpAuth, SshJumpHost};

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
    // The file is on the SSH host, so opening the local path of the same name would open another database.
    if saved.ssh.as_ref().is_some_and(SavedSshConfig::opens_remote_file) {
        return Err(DriverError::from(ConfigError::RemoteFileOverSsh).into());
    }
    let target = if driver.capabilities().is_file_based() {
        let endpoint = FileEndpoint::open_existing(PathBuf::from(&saved.database)).map_err(DriverError::from)?;
        RequestTarget::File(endpoint)
    } else {
        let endpoint = NetworkEndpoint::new(&saved.host, saved.port).map_err(DriverError::from)?;
        let ssh = saved
            .ssh
            .as_ref()
            .filter(|ssh| ssh.enabled)
            .map(ssh_config)
            .transpose()
            .map_err(|problem| DriverError::from(tablepro_core::TransportError::Ssh(problem.into())))?;
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
            options: saved.options.clone(),
        }
    };
    // No app on the core asks before a read or for proof yet, so a level that does runs as Read-Only.
    let safe_mode = saved.safe_mode.enforced();
    Ok(ConnectRequest {
        metadata: ConnectionMetadata {
            id: saved.id,
            name: saved.name.clone(),
            driver_id: saved.driver_id.clone(),
        },
        driver,
        target,
        workspace_settings: WorkspaceSettings::workspace(safe_mode.blocks_writes())
            .with_editor_timeout(QueryTimeout::from_seconds(saved.query_timeout_secs)),
        safe_mode,
    })
}

/// The OpenSSH configuration a saved SSH section describes, with no
/// secrets yet.
pub fn ssh_config(saved: &SavedSshConfig) -> Result<SshConfig, tablepro_core::SshDestinationProblem> {
    let destination = SshDestination::new(&saved.host, saved.port, saved.username.clone())?;
    let jump_hosts = saved
        .jump_hosts
        .iter()
        .map(jump_destination)
        .collect::<Result<_, _>>()?;
    let auth = match &saved.auth {
        // Both transports try the none method first, so a server that asks for nothing lets the tunnel in.
        SavedSshAuth::Agent | SavedSshAuth::None => SshAuth::Agent,
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

// A hop with a key of its own is refused rather than signed in to with another key: -J takes only where a hop goes.
fn jump_destination(hop: &SshJumpHost) -> Result<SshDestination, tablepro_core::SshDestinationProblem> {
    if hop.auth == Some(SshJumpAuth::PrivateKey) {
        return Err(tablepro_core::SshDestinationProblem::JumpHostKey { host: hop.host.clone() });
    }
    SshDestination::new(&hop.host, hop.port, hop.username.clone())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use secrecy::ExposeSecret;
    use tablepro_core::credentials::{SecretKind, SecretVault};
    use tablepro_core::{
        SafeModeLevel, SshDestinationPart, SshDestinationProblem, SshFailure, TlsConfig, TransportError,
    };
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
            safe_mode: tablepro_core::SafeModeLevel::ReadOnly,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            query_timeout_secs: None,
            auth_mode: AuthMode::Password,
            ssh,
            last_opened_at: None,
            color: None,
            group_id: None,
            project_id: None,
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
            details: Default::default(),
            device: Default::default(),
            unknown: Default::default(),
        }
    }

    fn bastion(auth: SavedSshAuth) -> SavedSshConfig {
        SavedSshConfig {
            port: Some(2222),
            username: Some("deploy".to_owned()),
            jump_hosts: SshJumpHost::parse_list("ops@jump1:2200,jump2"),
            ..SavedSshConfig::new("bastion.example.com", auth)
        }
    }

    async fn resolve_unattended(saved: &SavedConnection) -> Result<RefreshedRequest, ConnectError> {
        resolve_saved(
            saved,
            &drivers(),
            &NoStoredCredentials,
            CredentialInteraction::Unattended,
            CredentialDemand::default(),
        )
        .await
    }

    #[tokio::test]
    async fn a_tunnel_switched_off_is_not_dialed_and_none_auth_tries_the_agent() {
        let mut off = saved(Some(bastion(SavedSshAuth::Agent)));
        if let Some(ssh) = off.ssh.as_mut() {
            ssh.enabled = false;
        }
        let none = saved(Some(bastion(SavedSshAuth::None)));

        let request = resolve_unattended(&off).await.unwrap().request;
        let RequestTarget::Network { ssh, .. } = request.target else {
            panic!("expected a network target");
        };
        assert!(ssh.is_none(), "a tunnel switched off was dialed");
        let request = resolve_unattended(&none).await.unwrap().request;
        let RequestTarget::Network { ssh: Some(ssh), .. } = request.target else {
            panic!("expected a network target over ssh");
        };
        assert!(matches!(ssh.auth, SshAuth::Agent));
    }

    #[tokio::test]
    async fn a_hop_with_its_own_key_and_a_remote_file_are_refused() {
        let mut keyed = saved(Some(bastion(SavedSshAuth::Agent)));
        let mut remote = saved(Some(bastion(SavedSshAuth::Agent)));
        if let Some(ssh) = keyed.ssh.as_mut() {
            ssh.jump_hosts[0].auth = Some(SshJumpAuth::PrivateKey);
        }
        if let Some(ssh) = remote.ssh.as_mut() {
            ssh.remote_file.path = Some("~/app.db".to_owned());
        }

        assert_eq!(
            resolve_unattended(&keyed).await.unwrap_err(),
            ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
                SshFailure::InvalidDestination {
                    problem: SshDestinationProblem::JumpHostKey {
                        host: "jump1".to_owned()
                    }
                }
            )))
        );
        assert_eq!(
            resolve_unattended(&remote).await.unwrap_err(),
            ConnectError::Driver(DriverError::Config(ConfigError::RemoteFileOverSsh))
        );
    }

    #[tokio::test]
    async fn a_level_that_asks_for_more_than_this_app_can_runs_read_only() {
        for (level, runs) in [
            (SafeModeLevel::Silent, SafeModeLevel::Silent),
            (SafeModeLevel::Alert, SafeModeLevel::Alert),
            (SafeModeLevel::AlertFull, SafeModeLevel::ReadOnly),
            (SafeModeLevel::SafeMode, SafeModeLevel::ReadOnly),
            (SafeModeLevel::SafeModeFull, SafeModeLevel::ReadOnly),
        ] {
            let mut connection = saved(None);
            connection.safe_mode = level;

            let request = resolve_unattended(&connection).await.unwrap().request;

            assert_eq!(request.safe_mode, runs, "{level:?}");
            assert_eq!(
                request.workspace_settings.read_only,
                runs == SafeModeLevel::ReadOnly,
                "{level:?}"
            );
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

        assert!(refreshed.typed.is_empty(), "{:?}", refreshed.typed);
        let request = refreshed.request;
        assert_eq!(request.metadata.id, saved.id);
        assert!(request.workspace_settings.read_only);
        let RequestTarget::Network {
            endpoint,
            ssh: Some(ssh),
            credentials: Credentials::Password { username, password },
            database,
            tls,
            options: _,
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
    async fn the_kinds_typed_into_a_prompt_are_reported() {
        use tablepro_core::credentials::PromptReply;
        use tablepro_test_support::FakePrompter;

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
        let credentials = KeyringCredentials::for_saved(vault, &saved);
        let prompter = Arc::new(FakePrompter::new([PromptReply::Submitted {
            values: vec![SecretString::from("ssh")],
            remember: false,
        }]));

        let refreshed = resolve_saved(
            &saved,
            &drivers(),
            &credentials,
            CredentialInteraction::Attended(prompter),
            CredentialDemand::default(),
        )
        .await
        .unwrap();

        assert_eq!(refreshed.typed, [SecretKind::SshPassword]);
        assert!(refreshed.remember.is_empty());
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
    async fn the_connection_query_timeout_reaches_the_session_settings() {
        let resolve = |seconds: Option<u32>| async move {
            let mut saved = saved(None);
            saved.query_timeout_secs = seconds;
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
            let credentials = KeyringCredentials::for_saved(vault, &saved);
            resolve_saved(
                &saved,
                &drivers(),
                &credentials,
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await
            .unwrap()
            .request
            .workspace_settings
            .editor_timeout
        };

        assert_eq!(resolve(None).await, QueryTimeout::Preference);
        assert_eq!(resolve(Some(0)).await, QueryTimeout::Off);
        assert_eq!(
            resolve(Some(300)).await,
            QueryTimeout::After(std::time::Duration::from_secs(300))
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
        assert_eq!(
            resolve(bad_ssh).await.unwrap_err(),
            ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
                SshFailure::InvalidDestination {
                    problem: SshDestinationProblem::LeadingDash {
                        part: SshDestinationPart::Host
                    }
                }
            )))
        );
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

    #[tokio::test]
    async fn a_file_on_the_ssh_host_is_refused_rather_than_opened_here() {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(FakeDriver::connecting(
            &FakeDriver::FILE_CAPABILITIES,
            ConnectionScript::default(),
        )));
        let mut remote = saved(Some(bastion(SavedSshAuth::Agent)));
        remote.database = "/srv/app.db".to_owned();
        if let Some(ssh) = remote.ssh.as_mut() {
            ssh.remote_file.path = Some("/srv/app.db".to_owned());
        }

        let refused = resolve_saved(
            &remote,
            &drivers,
            &NoStoredCredentials,
            CredentialInteraction::Unattended,
            CredentialDemand::default(),
        )
        .await
        .unwrap_err();

        assert_eq!(
            refused,
            ConnectError::Driver(DriverError::Config(ConfigError::RemoteFileOverSsh))
        );
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
