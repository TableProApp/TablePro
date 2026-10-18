use std::path::{Path, PathBuf};

use secrecy::{ExposeSecret, SecretString};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination};
use tablepro_storage::{SavedSshAuth, SavedSshConfig};

pub use crate::services::ssh_environment::SshEnvironment;

/// How the SSH server is logged in to, in the order the combo shows
/// them. OpenSSH does the work for each; the app only picks which one
/// it tries first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SshAuthChoice {
    Agent,
    PrivateKey,
    Password,
    KeyboardInteractive,
}

impl SshAuthChoice {
    pub const ALL: [Self; 4] = [Self::Agent, Self::PrivateKey, Self::Password, Self::KeyboardInteractive];

    pub fn label(self) -> String {
        match self {
            Self::Agent => crate::i18n::gettext("SSH agent"),
            Self::PrivateKey => crate::i18n::gettext("Private key"),
            Self::Password => crate::i18n::gettext("Password"),
            Self::KeyboardInteractive => crate::i18n::gettext("Keyboard-interactive"),
        }
    }

    /// What the choice does, for the combo row's subtitle.
    pub fn description(self) -> String {
        match self {
            Self::Agent => crate::i18n::gettext("Keys from the SSH agent and your SSH configuration"),
            Self::PrivateKey => crate::i18n::gettext("A key file, unlocked with its passphrase if it has one"),
            Self::Password => crate::i18n::gettext("The SSH server's own password"),
            Self::KeyboardInteractive => crate::i18n::gettext("The SSH server asks its own questions, such as a code"),
        }
    }

    pub fn index(self) -> u32 {
        Self::ALL.iter().position(|choice| *choice == self).unwrap_or(0) as u32
    }

    pub fn from_index(index: u32) -> Self {
        Self::ALL.get(index as usize).copied().unwrap_or(Self::Agent)
    }

    /// An agent that is running already holds the keys the user logs in
    /// with everywhere else, so it goes first; a key on disk comes next.
    pub fn default_for(environment: &SshEnvironment) -> Self {
        if environment.agent {
            Self::Agent
        } else if environment.default_key.is_some() {
            Self::PrivateKey
        } else {
            Self::Password
        }
    }

    fn of_saved(auth: &SavedSshAuth) -> Self {
        match auth {
            SavedSshAuth::Agent => Self::Agent,
            SavedSshAuth::PrivateKey { .. } => Self::PrivateKey,
            SavedSshAuth::Password => Self::Password,
            SavedSshAuth::KeyboardInteractive => Self::KeyboardInteractive,
        }
    }
}

/// The SSH rows as typed. Port, username and jump hosts may be empty:
/// OpenSSH then takes them from the user's SSH configuration, which is
/// also where a host alias is resolved.
#[derive(Debug, Clone)]
pub struct SshFormState {
    pub host: String,
    pub port: String,
    pub user: String,
    pub jump_hosts: String,
    pub auth: SshAuthChoice,
    pub key_path: String,
    pub password: SecretString,
    pub passphrase: SecretString,
}

impl SshFormState {
    pub fn new(environment: &SshEnvironment) -> Self {
        Self {
            host: String::new(),
            port: String::new(),
            user: String::new(),
            jump_hosts: String::new(),
            auth: SshAuthChoice::default_for(environment),
            key_path: environment
                .default_key
                .as_deref()
                .map(|path| path.to_string_lossy().into_owned())
                .unwrap_or_default(),
            password: SecretString::from(String::new()),
            passphrase: SecretString::from(String::new()),
        }
    }

    /// The rows a saved SSH section fills. Secrets stay in the keyring.
    pub fn from_saved(saved: &SavedSshConfig) -> Self {
        let key_path = match &saved.auth {
            SavedSshAuth::PrivateKey { path, .. } => path.as_deref().map(Path::to_string_lossy).unwrap_or_default(),
            _ => Default::default(),
        };
        Self {
            host: saved.host.clone(),
            port: saved.port.map(|port| port.to_string()).unwrap_or_default(),
            user: saved.username.clone().unwrap_or_default(),
            jump_hosts: saved.jump_hosts.join(", "),
            auth: SshAuthChoice::of_saved(&saved.auth),
            key_path: key_path.into_owned(),
            password: SecretString::from(String::new()),
            passphrase: SecretString::from(String::new()),
        }
    }

    /// What is saved, which never holds a secret.
    pub fn saved(&self) -> Result<SavedSshConfig, SshInputError> {
        let host = self.host.trim();
        if host.is_empty() {
            return Err(SshInputError::HostRequired);
        }
        let port = match self.port.trim() {
            "" => None,
            text => Some(
                text.parse::<u16>()
                    .ok()
                    .filter(|port| *port != 0)
                    .ok_or(SshInputError::PortOutOfRange)?,
            ),
        };
        let user = Some(self.user.trim().to_owned()).filter(|user| !user.is_empty());
        if let Some(user) = &user
            && let Err(failure) = SshDestination::new("host", None, Some(user.clone()))
        {
            return Err(SshInputError::UserInvalid(failure.to_string()));
        }
        if let Err(failure) = SshDestination::new(host, port, None) {
            return Err(SshInputError::HostInvalid(failure.to_string()));
        }
        let jump_hosts = match self.jump_hosts.trim() {
            "" => Vec::new(),
            list => {
                SshDestination::parse_jump_list(list)
                    .map_err(|failure| SshInputError::JumpHostsInvalid(failure.to_string()))?;
                vec![list.to_owned()]
            }
        };
        let auth = match self.auth {
            SshAuthChoice::Agent => SavedSshAuth::Agent,
            SshAuthChoice::Password => SavedSshAuth::Password,
            SshAuthChoice::KeyboardInteractive => SavedSshAuth::KeyboardInteractive,
            SshAuthChoice::PrivateKey => {
                let path = self.key_path.trim();
                if path.is_empty() {
                    return Err(SshInputError::KeyPathRequired);
                }
                SavedSshAuth::PrivateKey {
                    path: Some(PathBuf::from(path)),
                    has_passphrase: !self.passphrase.expose_secret().is_empty(),
                }
            }
        };
        Ok(SavedSshConfig {
            host: host.to_owned(),
            port,
            username: user,
            jump_hosts,
            auth,
        })
    }

    /// The configuration a connect uses, the entry that is saved, and
    /// which secret the keyring should keep.
    pub fn inputs(&self) -> Result<SshInputs, SshInputError> {
        let saved = self.saved()?;
        let mut cfg = tablepro_session::connect::ssh_config(&saved)
            .map_err(|failure| SshInputError::HostInvalid(failure.to_string()))?;
        let secret_to_store = fill_secret(&mut cfg, self.password.clone(), self.passphrase.clone());
        Ok(SshInputs {
            cfg,
            saved,
            secret_to_store,
        })
    }
}

#[derive(Clone)]
pub struct SshInputs {
    pub cfg: SshConfig,
    pub saved: SavedSshConfig,
    pub secret_to_store: SshSecretToStore,
}

#[derive(Clone)]
pub enum SshSecretToStore {
    Password(SecretString),
    Passphrase(SecretString),
    None,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SshInputError {
    HostRequired,
    HostInvalid(String),
    PortOutOfRange,
    UserInvalid(String),
    JumpHostsInvalid(String),
    KeyPathRequired,
}

impl SshInputError {
    pub fn message(&self) -> String {
        match self {
            Self::HostRequired => crate::i18n::gettext("Enter the SSH server's host name or its alias."),
            Self::HostInvalid(detail) => {
                crate::i18n::gettext_f("The SSH host cannot be used: {detail}", &[("detail", detail)])
            }
            Self::PortOutOfRange => crate::i18n::gettext("The SSH port must be a number from 1 to 65535."),
            Self::UserInvalid(detail) => {
                crate::i18n::gettext_f("The SSH username cannot be used: {detail}", &[("detail", detail)])
            }
            Self::JumpHostsInvalid(detail) => {
                crate::i18n::gettext_f("The jump hosts cannot be used: {detail}", &[("detail", detail)])
            }
            Self::KeyPathRequired => crate::i18n::gettext("Choose the private key file."),
        }
    }

    /// Whether the row is only empty. An empty row is not marked as an
    /// error before the user has typed anything into it.
    pub fn is_missing(&self) -> bool {
        matches!(self, Self::HostRequired | Self::KeyPathRequired)
    }
}

/// Put the typed secret into the configuration the rows produced, and
/// say which one the keyring should keep. A key with no passphrase typed
/// keeps none, so ssh asks for it itself if the key needs one.
fn fill_secret(cfg: &mut SshConfig, password: SecretString, passphrase: SecretString) -> SshSecretToStore {
    match &mut cfg.auth {
        SshAuth::Password { password: slot } => {
            *slot = password.clone();
            SshSecretToStore::Password(password)
        }
        SshAuth::PrivateKey { passphrase: slot, .. } => {
            if passphrase.expose_secret().is_empty() {
                return SshSecretToStore::None;
            }
            *slot = Some(passphrase.clone());
            SshSecretToStore::Passphrase(passphrase)
        }
        SshAuth::Agent | SshAuth::KeyboardInteractive => SshSecretToStore::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(auth: SshAuthChoice) -> SshFormState {
        SshFormState {
            host: " bastion.example.com ".to_owned(),
            port: "2222".to_owned(),
            user: "deploy".to_owned(),
            jump_hosts: String::new(),
            auth,
            key_path: "/home/deploy/.ssh/id_ed25519".to_owned(),
            password: SecretString::from("s3cret"),
            passphrase: SecretString::from(""),
        }
    }

    #[test]
    fn every_auth_choice_round_trips_through_its_index() {
        for choice in SshAuthChoice::ALL {
            assert_eq!(SshAuthChoice::from_index(choice.index()), choice);
        }
        assert_eq!(SshAuthChoice::from_index(99), SshAuthChoice::Agent);
    }

    #[test]
    fn agent_is_the_default_when_one_runs_then_a_key_then_a_password() {
        let key = Some(PathBuf::from("/home/u/.ssh/id_ed25519"));
        let cases = [
            (true, key.clone(), SshAuthChoice::Agent),
            (true, None, SshAuthChoice::Agent),
            (false, key, SshAuthChoice::PrivateKey),
            (false, None, SshAuthChoice::Password),
        ];
        for (agent, default_key, expected) in cases {
            let environment = SshEnvironment { agent, default_key };
            assert_eq!(SshAuthChoice::default_for(&environment), expected, "{environment:?}");
        }
    }

    #[test]
    fn port_user_and_jump_hosts_may_come_from_the_ssh_config() {
        let alias = SshFormState {
            host: "prod-bastion".to_owned(),
            port: String::new(),
            user: "  ".to_owned(),
            ..rows(SshAuthChoice::Agent)
        };

        let saved = alias.saved().expect("an alias alone is enough");

        assert_eq!(saved.host, "prod-bastion");
        assert_eq!(saved.port, None);
        assert_eq!(saved.username, None);
        assert!(saved.jump_hosts.is_empty());
        assert_eq!(saved.auth, SavedSshAuth::Agent);
    }

    #[test]
    fn ssh_key_auth_requires_path() {
        let missing = SshFormState {
            key_path: "  ".to_owned(),
            ..rows(SshAuthChoice::PrivateKey)
        };
        assert_eq!(missing.saved(), Err(SshInputError::KeyPathRequired));

        let key = rows(SshAuthChoice::PrivateKey).saved().expect("a key login");
        assert_eq!(
            key.auth,
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/deploy/.ssh/id_ed25519")),
                has_passphrase: false,
            }
        );
    }

    #[test]
    fn a_bad_row_names_the_row_it_is_in() {
        let cases = [
            (
                SshFormState {
                    host: String::new(),
                    ..rows(SshAuthChoice::Agent)
                },
                "host required",
            ),
            (
                SshFormState {
                    port: "70000".to_owned(),
                    ..rows(SshAuthChoice::Agent)
                },
                "port",
            ),
            (
                SshFormState {
                    port: "0".to_owned(),
                    ..rows(SshAuthChoice::Agent)
                },
                "port",
            ),
            (
                SshFormState {
                    user: "-oProxyCommand=x".to_owned(),
                    ..rows(SshAuthChoice::Agent)
                },
                "user",
            ),
            (
                SshFormState {
                    jump_hosts: "jump1,,jump2".to_owned(),
                    ..rows(SshAuthChoice::Agent)
                },
                "jump",
            ),
        ];
        for (state, row) in cases {
            let error = state.saved().expect_err(row);
            let matches = match row {
                "host required" => error == SshInputError::HostRequired,
                "port" => error == SshInputError::PortOutOfRange,
                "user" => matches!(error, SshInputError::UserInvalid(_)),
                _ => matches!(error, SshInputError::JumpHostsInvalid(_)),
            };
            assert!(matches, "{row}: {error:?}");
        }
    }

    #[test]
    fn a_saved_section_fills_the_rows_it_came_from() {
        let typed = SshFormState {
            jump_hosts: "ops@jump1:2200, jump2".to_owned(),
            ..rows(SshAuthChoice::KeyboardInteractive)
        };
        let saved = typed.saved().expect("valid rows");

        let refilled = SshFormState::from_saved(&saved);

        assert_eq!(refilled.saved(), Ok(saved));
        assert_eq!(refilled.auth, SshAuthChoice::KeyboardInteractive);
        assert!(
            refilled.password.expose_secret().is_empty(),
            "a secret came back from the entry"
        );
    }

    #[test]
    fn a_password_login_carries_and_keeps_the_typed_password() {
        let inputs = rows(SshAuthChoice::Password).inputs().expect("valid rows");

        let SshAuth::Password { password } = &inputs.cfg.auth else {
            panic!("expected password auth");
        };
        assert_eq!(password.expose_secret(), "s3cret");
        assert!(matches!(inputs.secret_to_store, SshSecretToStore::Password(_)));
    }

    #[test]
    fn a_key_with_no_passphrase_typed_keeps_none() {
        let without = rows(SshAuthChoice::PrivateKey).inputs().expect("valid rows");
        assert!(matches!(without.secret_to_store, SshSecretToStore::None));

        let with = SshFormState {
            passphrase: SecretString::from("phrase"),
            ..rows(SshAuthChoice::PrivateKey)
        }
        .inputs()
        .expect("valid rows");
        let SshAuth::PrivateKey { passphrase, .. } = &with.cfg.auth else {
            panic!("expected key auth");
        };
        assert_eq!(passphrase.as_ref().map(ExposeSecret::expose_secret), Some("phrase"));
        assert!(matches!(with.secret_to_store, SshSecretToStore::Passphrase(_)));
    }

    #[test]
    fn agent_and_keyboard_interactive_keep_no_secret() {
        for auth in [SshAuthChoice::Agent, SshAuthChoice::KeyboardInteractive] {
            let inputs = rows(auth).inputs().expect("valid rows");
            assert!(matches!(inputs.secret_to_store, SshSecretToStore::None), "{auth:?}");
        }
    }
}
