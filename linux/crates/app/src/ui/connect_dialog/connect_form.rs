use std::path::{Path, PathBuf};

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{SecretKind, SecretSave};
use tablepro_core::{
    AiPolicy, AuthMode, ClientIdentity, ConfigError, Credentials, DriverCapabilities, ExternalAccess, FileEndpoint,
    NetworkEndpoint, NetworkOption, NetworkOptions, SafeModeLevel, ServerNameOverride, TlsCapabilities, TlsConfig,
    TlsMode, TransportClass,
};
use tablepro_session::RequestTarget;
use tablepro_storage::{ConnectionIcon, SavedConnection, SavedSshAuth, SavedSshConfig};
use uuid::Uuid;

use super::form_errors::FormErrors;
use super::form_field::FormField;
use crate::services::secret_change::SecretChange;
use crate::services::secret_changes::SecretChanges;
use crate::services::secret_labels;
use crate::ui::error_text::config_message;
use crate::ui::ssh_inputs::{SshFormState, SshInputError, SshSecretToStore};

/// The Security rows as chosen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TlsFormState {
    pub mode: TlsMode,
    pub ca_file: Option<PathBuf>,
    pub client_certificate: Option<PathBuf>,
    pub client_key: Option<PathBuf>,
    pub server_name: String,
}

impl TlsFormState {
    pub fn new(caps: Option<&TlsCapabilities>) -> Self {
        Self {
            mode: default_tls_mode(caps),
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: String::new(),
        }
    }

    pub fn from_config(config: &TlsConfig) -> Self {
        Self {
            mode: config.mode,
            ca_file: config.ca_file.clone(),
            client_certificate: config
                .client_identity
                .as_ref()
                .map(|identity| identity.certificate.clone()),
            client_key: config.client_identity.as_ref().map(|identity| identity.key.clone()),
            server_name: config.server_name.clone().unwrap_or_default(),
        }
    }

    /// The settings a request carries. A row the driver or the mode does
    /// not show is left out rather than cleared, so looking at another
    /// driver or mode and coming back keeps what was chosen.
    pub fn config(&self, caps: &TlsCapabilities, route: TransportClass) -> TlsConfig {
        if self.mode == TlsMode::Disable {
            return TlsConfig::disabled();
        }
        let client_identity = (caps.client_identity
            && (self.client_certificate.is_some() || self.client_key.is_some()))
        .then(|| ClientIdentity {
            certificate: self.client_certificate.clone().unwrap_or_default(),
            key: self.client_key.clone().unwrap_or_default(),
        });
        TlsConfig {
            mode: self.mode,
            ca_file: self
                .ca_file
                .clone()
                .filter(|_| caps.ca_file && self.mode == TlsMode::VerifyFull),
            client_identity,
            server_name: Some(self.server_name.trim().to_owned())
                .filter(|name| !name.is_empty() && shows_server_name(caps, route)),
        }
    }
}

/// Verify full is the only mode that proves who is on the other end,
/// so a new connection starts there whenever the driver offers it.
pub fn default_tls_mode(caps: Option<&TlsCapabilities>) -> TlsMode {
    match caps {
        Some(caps) if caps.modes.contains(&TlsMode::VerifyFull) => TlsMode::VerifyFull,
        Some(caps) => caps.modes.last().copied().unwrap_or(TlsMode::Disable),
        None => TlsMode::Disable,
    }
}

/// Whether the driver can check the certificate against another name
/// on this route. MySQL only can over an SSH forward, where the name it
/// dials is the forward's and never the certificate's.
pub fn shows_server_name(caps: &TlsCapabilities, route: TransportClass) -> bool {
    match caps.server_name_override {
        ServerNameOverride::AnyRoute => true,
        ServerNameOverride::SshForwardOnly => route == TransportClass::SshForward,
        ServerNameOverride::Unsupported => false,
    }
}

/// Whether the dialog, opened on a connection to `driver` over `route`,
/// shows the server name row. A driver without TLS shows none.
pub fn driver_shows_server_name(driver: Option<&DriverCapabilities>, route: TransportClass) -> bool {
    driver
        .and_then(|caps| caps.tls.as_ref())
        .is_some_and(|tls| shows_server_name(tls, route))
}

/// What the connect dialog holds, read from its rows in one go so a
/// connect works from a snapshot.
#[derive(Debug, Clone)]
pub struct ConnectForm {
    /// What the list calls the connection. Empty takes the name from
    /// where it connects, which then follows an edit of the host.
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    /// Set once the user types a port. A driver switch only moves the
    /// port while this is false, so a deliberate 6543 survives a look
    /// at another driver.
    pub port_edited: bool,
    pub database: String,
    pub auth: AuthMode,
    pub username: String,
    pub password: SecretString,
    pub remember_password: bool,
    pub tls: TlsFormState,
    pub safe_mode: SafeModeLevel,
    pub external_access: ExternalAccess,
    pub ai_policy: AiPolicy,
    pub ssh: Option<SshFormState>,
    pub file: Option<FileEndpoint>,
    /// The ids of the tags ticked in the Appearance group.
    pub tags: Vec<Uuid>,
    pub icon: Option<ConnectionIcon>,
    /// The engine's own options, kept across a look at another driver
    /// and sent only where the driver offers them.
    pub options: NetworkOptions,
}

/// A form that passed every check, ready to connect and to save.
#[derive(Clone)]
pub struct ValidatedForm {
    pub target: RequestTarget,
    pub ssh: Option<(SavedSshConfig, SshSecretToStore)>,
}

impl ConnectForm {
    pub fn new(driver_id: &str, caps: &DriverCapabilities) -> Self {
        Self {
            name: String::new(),
            driver_id: driver_id.to_owned(),
            host: String::new(),
            port: caps.default_port().unwrap_or(1),
            port_edited: false,
            database: String::new(),
            auth: caps.auth_modes.first().copied().unwrap_or_default(),
            username: String::new(),
            password: SecretString::from(String::new()),
            remember_password: true,
            tls: TlsFormState::new(caps.tls.as_ref()),
            safe_mode: SafeModeLevel::Off,
            external_access: ExternalAccess::default(),
            ai_policy: AiPolicy::default(),
            ssh: None,
            file: None,
            tags: Vec::new(),
            icon: None,
            options: NetworkOptions::default(),
        }
    }

    /// The form a saved connection fills, to edit it. Secrets are not
    /// read: they live in the keyring and never enter a widget. A name
    /// that is only where the connection goes is left empty, so it keeps
    /// following the host and user.
    pub fn from_saved(saved: &SavedConnection, caps: &DriverCapabilities) -> Self {
        let mut form = Self::new(&saved.driver_id, caps);
        form.safe_mode = saved.safe_mode;
        form.external_access = saved.external_access;
        form.ai_policy = saved.ai_policy;
        form.tags.clone_from(&saved.tags);
        form.icon = saved.icon;
        if caps.is_file_based() {
            form.file = FileEndpoint::open_existing(PathBuf::from(&saved.database)).ok();
        } else {
            form.host = saved.host.clone();
            form.port_edited = caps.default_port() != Some(saved.port);
            form.port = saved.port;
            form.database = saved.database.clone();
            form.username = saved.username.clone();
            if caps.supports(saved.auth_mode) {
                form.auth = saved.auth_mode;
            }
            form.tls = TlsFormState::from_config(&saved.tls);
            form.ssh = saved.ssh.as_ref().map(SshFormState::from_saved);
            form.options = saved.options.clone();
        }
        if saved.name != form.label(caps) {
            saved.name.clone_into(&mut form.name);
        }
        form
    }

    /// Look at another driver. Host, database and username stay: a look
    /// at another driver must not wipe what the user filled in.
    pub fn switch_driver(&mut self, driver_id: &str, caps: &DriverCapabilities) {
        driver_id.clone_into(&mut self.driver_id);
        if !self.port_edited
            && let Some(port) = caps.default_port()
        {
            self.port = port;
        }
        if !caps.auth_modes.is_empty() && !caps.supports(self.auth) {
            self.auth = caps.auth_modes.first().copied().unwrap_or_default();
        }
        if let Some(tls) = caps.tls.as_ref()
            && !tls.modes.contains(&self.tls.mode)
        {
            self.tls.mode = default_tls_mode(Some(tls));
        }
    }

    /// Check every row the driver shows and build where the connect
    /// goes, or say what is wrong with each row that is.
    pub fn validate(&self, caps: &DriverCapabilities) -> Result<ValidatedForm, FormErrors> {
        let mut errors = FormErrors::default();
        if caps.is_file_based() {
            return match &self.file {
                Some(endpoint) => Ok(ValidatedForm {
                    target: RequestTarget::File(endpoint.clone()),
                    ssh: None,
                }),
                None => {
                    errors.push(
                        FormField::File,
                        crate::i18n::gettext("Choose a database file, or create a new one."),
                        true,
                    );
                    Err(errors)
                }
            };
        }

        let endpoint = match NetworkEndpoint::new(&self.host, self.port) {
            Ok(endpoint) => Some(endpoint),
            Err(error) => {
                let (field, missing) = match error {
                    ConfigError::InvalidPort => (FormField::Port, false),
                    ConfigError::EmptyHost => (FormField::Host, true),
                    _ => (FormField::Host, false),
                };
                errors.push(field, config_message(&error), missing);
                None
            }
        };

        if !caps.supports(self.auth) {
            errors.push(
                FormField::AuthMode,
                config_message(&ConfigError::AuthModeUnsupported),
                false,
            );
        }
        let username = self.username.trim();
        let credentials = match self.auth {
            AuthMode::Password => {
                if username.is_empty() && caps.username_required {
                    errors.push(
                        FormField::Username,
                        crate::i18n::gettext("Enter the username to log in with."),
                        true,
                    );
                }
                Credentials::Password {
                    username: username.to_owned(),
                    password: self.password.clone(),
                }
            }
            AuthMode::Kerberos => Credentials::Integrated,
        };

        let database = self.database.trim();
        check_database(caps, database, &mut errors);

        let ssh = match self.ssh.as_ref().map(SshFormState::inputs).transpose() {
            Ok(ssh) => ssh,
            Err(error) => {
                errors.push(ssh_field(&error), error.message(), error.is_missing());
                None
            }
        };
        let route = if self.ssh.is_some() {
            TransportClass::SshForward
        } else {
            TransportClass::DirectTcp
        };

        let tls = match caps.tls.as_ref() {
            Some(tls_caps) => {
                let config = self.tls.config(tls_caps, route);
                if let Err(error) = config.validate(tls_caps, route) {
                    errors.push(tls_field(&error, &config), config_message(&error), false);
                }
                config
            }
            None => TlsConfig::disabled(),
        };

        let options = self.offered_options(caps);
        if let Err(error) = options.validate(caps, route) {
            errors.push(FormField::DnsSeedList, config_message(&error), false);
        }

        let Some(endpoint) = endpoint.filter(|_| errors.is_empty()) else {
            return Err(errors);
        };
        let (cfg, saved_ssh) = match ssh {
            Some(inputs) => (Some(inputs.cfg), Some((inputs.saved, inputs.secret_to_store))),
            None => (None, None),
        };
        Ok(ValidatedForm {
            target: RequestTarget::Network {
                endpoint,
                ssh: cfg,
                credentials,
                database: Some(database.to_owned()).filter(|name| !name.is_empty()),
                tls,
                options,
            },
            ssh: saved_ssh,
        })
    }

    /// The options this driver reads, with the rest left at their
    /// defaults so a look at another engine sends nothing it would refuse.
    pub fn offered_options(&self, caps: &DriverCapabilities) -> NetworkOptions {
        NetworkOptions {
            dns_seed_list: self.options.dns_seed_list && caps.offers(NetworkOption::DnsSeedList),
            auth_database: caps
                .offers(NetworkOption::AuthDatabase)
                .then(|| self.options.auth_database().map(str::to_owned))
                .flatten(),
        }
    }

    /// How the entry is named in the connection list: the name typed,
    /// or where it connects.
    pub fn display_name(&self, caps: &DriverCapabilities) -> String {
        match self.name.trim() {
            "" => self.label(caps),
            name => name.to_owned(),
        }
    }

    /// Where the entry connects, as a name.
    pub fn label(&self, caps: &DriverCapabilities) -> String {
        if caps.is_file_based() {
            return self
                .file
                .as_ref()
                .map(|file| file.path().display().to_string())
                .unwrap_or_default();
        }
        let host = self.host.trim();
        match (self.auth, self.username.trim()) {
            (AuthMode::Kerberos, _) | (AuthMode::Password, "") => host.to_owned(),
            (AuthMode::Password, username) => format!("{username}@{host}"),
        }
    }

    /// The entry a successful connect writes. Colour, group and the
    /// last-opened time come from the entry it replaces, because this
    /// form does not show them; its tags and icon are the form's.
    pub fn saved_connection(
        &self,
        caps: &DriverCapabilities,
        valid: &ValidatedForm,
        id: Uuid,
        existing: Option<&SavedConnection>,
    ) -> SavedConnection {
        let (host, port, database, username, tls, auth_mode, options) = match &valid.target {
            RequestTarget::File(endpoint) => (
                String::new(),
                0,
                endpoint.path().display().to_string(),
                String::new(),
                TlsConfig::disabled(),
                AuthMode::Password,
                NetworkOptions::default(),
            ),
            RequestTarget::Network {
                endpoint,
                credentials,
                database,
                tls,
                options,
                ..
            } => (
                endpoint.host().to_owned(),
                endpoint.port(),
                database.clone().unwrap_or_default(),
                match credentials {
                    Credentials::Password { username, .. } => username.clone(),
                    Credentials::Integrated => String::new(),
                },
                tls.clone(),
                credentials.mode(),
                options.clone(),
            ),
        };
        SavedConnection {
            id,
            name: self.display_name(caps),
            driver_id: self.driver_id.clone(),
            host,
            port,
            database,
            username,
            tls,
            safe_mode: self.safe_mode,
            external_access: self.external_access,
            ai_policy: self.ai_policy,
            auth_mode,
            ssh: valid.ssh.as_ref().map(|(saved, _)| saved.clone()),
            last_opened_at: existing.and_then(|saved| saved.last_opened_at),
            color: existing.and_then(|saved| saved.color),
            group: existing.and_then(|saved| saved.group.clone()),
            tags: self.tags.clone(),
            icon: self.icon,
            options,
        }
    }

    /// The entry a connect writes over `existing`, the entry the dialog
    /// was reopened on. An empty Name row there means no name was typed,
    /// so a name the user gave the entry stays; one that was only where
    /// it connects follows the form.
    pub fn submitted_connection(
        &self,
        caps: &DriverCapabilities,
        valid: &ValidatedForm,
        id: Uuid,
        existing: Option<&SavedConnection>,
    ) -> SavedConnection {
        let mut connection = self.saved_connection(caps, valid, id, existing);
        if let Some(existing) = existing
            && self.name.trim().is_empty()
            && existing.name != Self::from_saved(existing, caps).label(caps)
        {
            existing.name.clone_into(&mut connection.name);
        }
        connection
    }

    /// The secrets the entry is saved with. The database password goes
    /// in even when empty: a login with no password is still a login
    /// the keyring answers for.
    pub fn secrets_to_store(&self, valid: &ValidatedForm, saved: &SavedConnection) -> Vec<SecretSave> {
        let save = |kind, secret: &SecretString| SecretSave {
            kind,
            secret: secret.clone(),
            label: secret_labels::secret_label(kind, saved),
        };
        let mut secrets = Vec::new();
        if self.keeps_database_password(valid) {
            secrets.push(save(SecretKind::DatabasePassword, &self.password));
        }
        match valid.ssh.as_ref().map(|(_, secret)| secret) {
            Some(SshSecretToStore::Password(secret)) => secrets.push(save(SecretKind::SshPassword, secret)),
            Some(SshSecretToStore::Passphrase(secret)) => secrets.push(save(SecretKind::SshPassphrase, secret)),
            Some(SshSecretToStore::None) | None => {}
        }
        secrets
    }

    /// Secrets an earlier save of this entry may hold that the user now
    /// asked not to keep, so the next connect asks instead of using them.
    pub fn secrets_to_forget(&self, valid: &ValidatedForm) -> Vec<SecretKind> {
        let password_login = matches!(
            valid.target,
            RequestTarget::Network {
                credentials: Credentials::Password { .. },
                ..
            }
        );
        if password_login && !self.remember_password {
            vec![SecretKind::DatabasePassword]
        } else {
            Vec::new()
        }
    }

    /// What saving this form over `original` does to each secret. A
    /// typed secret replaces the stored one and an empty row keeps it; a
    /// secret the edited connection no longer logs in with is removed,
    /// as is the password when Remember is off. `original_caps` are the
    /// capabilities of the driver `original` was saved with.
    pub fn secret_changes(
        &self,
        original: &SavedConnection,
        original_caps: &DriverCapabilities,
        valid: &ValidatedForm,
    ) -> SecretChanges {
        let had_password = !original_caps.is_file_based() && original.auth_mode == AuthMode::Password;
        let typed = |secret: &SecretString| !secret.expose_secret().is_empty();
        let database_password = match valid.target {
            RequestTarget::Network {
                credentials: Credentials::Password { .. },
                ..
            } if self.remember_password && typed(&self.password) => SecretChange::Replace(self.password.clone()),
            RequestTarget::Network {
                credentials: Credentials::Password { .. },
                ..
            } if self.remember_password => SecretChange::Keep,
            _ if had_password => SecretChange::Remove,
            _ => SecretChange::Keep,
        };
        let original_ssh = original.ssh.as_ref().map(|ssh| &ssh.auth);
        let (ssh_password, ssh_passphrase) = match valid.ssh.as_ref() {
            Some((saved, SshSecretToStore::Password(secret))) => (
                if typed(secret) {
                    SecretChange::Replace(secret.clone())
                } else {
                    SecretChange::Keep
                },
                passphrase_left_unused(original, &saved.auth),
            ),
            Some((saved, SshSecretToStore::Passphrase(secret))) => (
                password_left_unused(original_ssh),
                if typed(secret) {
                    SecretChange::Replace(secret.clone())
                } else {
                    passphrase_left_unused(original, &saved.auth)
                },
            ),
            Some((saved, SshSecretToStore::None)) => (
                password_left_unused(original_ssh),
                passphrase_left_unused(original, &saved.auth),
            ),
            None => (
                password_left_unused(original_ssh),
                if original.has_stored_passphrase() {
                    SecretChange::Remove
                } else {
                    SecretChange::Keep
                },
            ),
        };
        SecretChanges {
            database_password,
            ssh_password,
            ssh_passphrase,
        }
    }

    /// The secrets whose rows hold a typed value. A Test logs in with
    /// these over the keyring's whatever Remember says, since the
    /// keyring may still hold the one they replace.
    pub fn typed_secrets(&self, valid: &ValidatedForm) -> Vec<SecretKind> {
        let typed = |secret: &SecretString| !secret.expose_secret().is_empty();
        let password_login = matches!(
            valid.target,
            RequestTarget::Network {
                credentials: Credentials::Password { .. },
                ..
            }
        );
        let mut kinds = Vec::new();
        if password_login && typed(&self.password) {
            kinds.push(SecretKind::DatabasePassword);
        }
        match valid.ssh.as_ref().map(|(_, secret)| secret) {
            Some(SshSecretToStore::Password(secret)) if typed(secret) => kinds.push(SecretKind::SshPassword),
            Some(SshSecretToStore::Passphrase(secret)) if typed(secret) => kinds.push(SecretKind::SshPassphrase),
            _ => {}
        }
        kinds
    }

    fn keeps_database_password(&self, valid: &ValidatedForm) -> bool {
        self.remember_password
            && matches!(
                valid.target,
                RequestTarget::Network {
                    credentials: Credentials::Password { .. },
                    ..
                }
            )
    }
}

/// An SSH password the edited connection no longer logs in with.
fn password_left_unused(original: Option<&SavedSshAuth>) -> SecretChange {
    match original {
        Some(SavedSshAuth::Password) => SecretChange::Remove,
        _ => SecretChange::Keep,
    }
}

/// A stored passphrase unlocks one key file, so it goes once the edited
/// connection logs in another way or with another key.
fn passphrase_left_unused(original: &SavedConnection, edited: &SavedSshAuth) -> SecretChange {
    let same_key =
        matches!(edited, SavedSshAuth::PrivateKey { path, .. } if path.as_deref() == original.ssh_key_path());
    if original.has_stored_passphrase() && !same_key {
        SecretChange::Remove
    } else {
        SecretChange::Keep
    }
}

fn ssh_field(error: &SshInputError) -> FormField {
    match error {
        SshInputError::HostRequired | SshInputError::HostInvalid(_) => FormField::SshHost,
        SshInputError::PortOutOfRange => FormField::SshPort,
        SshInputError::UserInvalid(_) => FormField::SshUser,
        SshInputError::JumpHostsInvalid(_) => FormField::SshJumpHosts,
        SshInputError::KeyPathRequired => FormField::SshKeyPath,
    }
}

/// The Security row a TLS problem belongs to.
pub fn tls_field(error: &ConfigError, config: &TlsConfig) -> FormField {
    let identity = config.client_identity.as_ref();
    let is_certificate = |path: &Path| identity.is_some_and(|identity| identity.certificate == path);
    match error {
        ConfigError::UnsupportedTlsMode => FormField::Encryption,
        ConfigError::CaFileUnsupported | ConfigError::CaFile { .. } => FormField::CaFile,
        ConfigError::ClientIdentityFile { path, .. } if !is_certificate(path) => FormField::ClientKey,
        ConfigError::ClientIdentityIncomplete
            if identity.is_some_and(|identity| !identity.certificate.as_os_str().is_empty()) =>
        {
            FormField::ClientKey
        }
        ConfigError::RelativePath if config.ca_file.as_deref().is_some_and(Path::is_relative) => FormField::CaFile,
        ConfigError::RelativePath if identity.is_some_and(|identity| identity.key.is_relative()) => {
            FormField::ClientKey
        }
        ConfigError::InvalidServerName | ConfigError::ServerNameOverrideUnsupported { .. } => FormField::ServerName,
        _ => FormField::ClientCertificate,
    }
}

/// A database a connection needs and lacks, or a key-value engine's
/// database that is not a number.
fn check_database(caps: &DriverCapabilities, database: &str, errors: &mut FormErrors) {
    if caps.database_required && database.is_empty() {
        errors.push(
            FormField::Database,
            config_message(&ConfigError::DatabaseRequired),
            true,
        );
    }
    if caps.is_key_value()
        && let Err(error) = tablepro_core::keyspace::database_number(Some(database))
    {
        errors.push(FormField::Database, config_message(&error), false);
    }
}

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;
    use tablepro_core::DatabaseDriver;
    use tablepro_storage::SavedSshAuth;

    use super::*;
    use crate::ui::ssh_inputs::{SshAuthChoice, SshEnvironment};

    fn caps(driver: &dyn DatabaseDriver) -> &'static DriverCapabilities {
        driver.capabilities()
    }

    fn postgres() -> &'static DriverCapabilities {
        caps(&tablepro_driver_postgres::PgDriver)
    }

    fn mysql() -> &'static DriverCapabilities {
        caps(&tablepro_driver_mysql::MysqlDriver)
    }

    fn mssql() -> &'static DriverCapabilities {
        caps(&tablepro_driver_mssql::MssqlDriver)
    }

    fn sqlite() -> &'static DriverCapabilities {
        caps(&tablepro_driver_sqlite::SqliteDriver)
    }

    fn redis() -> &'static DriverCapabilities {
        caps(&tablepro_driver_redis::RedisDriver)
    }

    fn mongodb() -> &'static DriverCapabilities {
        caps(&tablepro_driver_mongodb::MongoDriver)
    }

    fn filled(driver_id: &str, caps: &DriverCapabilities) -> ConnectForm {
        ConnectForm {
            host: "db.example.com".to_owned(),
            database: "sales".to_owned(),
            username: "app".to_owned(),
            password: SecretString::from("s3cret"),
            ..ConnectForm::new(driver_id, caps)
        }
    }

    fn network(target: &RequestTarget) -> (&NetworkEndpoint, &Credentials, Option<&str>, &TlsConfig) {
        match target {
            RequestTarget::Network {
                endpoint,
                credentials,
                database,
                tls,
                ..
            } => (endpoint, credentials, database.as_deref(), tls),
            RequestTarget::File(_) => panic!("expected a network target"),
        }
    }

    #[test]
    fn verify_full_is_default() {
        for caps in [postgres(), mysql(), mssql()] {
            assert_eq!(ConnectForm::new("x", caps).tls.mode, TlsMode::VerifyFull);
        }
        let form = filled("postgres", postgres());
        let valid = form.validate(postgres()).expect("a valid form");
        assert_eq!(network(&valid.target).3, &TlsConfig::verify_full());
    }

    #[test]
    fn kerberos_rejected_when_driver_lacks_it() {
        let form = ConnectForm {
            auth: AuthMode::Kerberos,
            ..filled("postgres", postgres())
        };

        let errors = form.validate(postgres()).err().expect("an unsupported login");

        assert!(errors.has(FormField::AuthMode), "{errors:?}");
        assert!(mssql().supports(AuthMode::Kerberos));
        let kerberos = ConnectForm {
            auth: AuthMode::Kerberos,
            ..filled("mssql", mssql())
        };
        let valid = kerberos.validate(mssql()).expect("SQL Server takes Kerberos");
        assert!(matches!(network(&valid.target).1, Credentials::Integrated));
    }

    fn options_of(target: &RequestTarget) -> &NetworkOptions {
        match target {
            RequestTarget::Network { options, .. } => options,
            RequestTarget::File(_) => panic!("expected a network target"),
        }
    }

    #[test]
    fn mongodb_options_are_sent_and_saved_and_another_engine_sends_none() {
        let form = ConnectForm {
            options: NetworkOptions {
                dns_seed_list: true,
                auth_database: Some(" admin ".to_owned()),
            },
            ..filled("mongodb", mongodb())
        };

        let valid = form.validate(mongodb()).expect("a seed list with a login database");
        let saved = form.saved_connection(mongodb(), &valid, Uuid::new_v4(), None);
        let restored = ConnectForm::from_saved(&saved, mongodb());

        let sent = options_of(&valid.target);
        assert!(sent.dns_seed_list);
        assert_eq!(sent.auth_database.as_deref(), Some("admin"));
        assert_eq!(&saved.options, sent);
        assert_eq!(&restored.options, sent);
        let elsewhere = form.validate(postgres()).expect("PostgreSQL ignores them");
        assert!(options_of(&elsewhere.target).is_default());
    }

    #[test]
    fn a_seed_list_through_ssh_is_refused_on_its_row() {
        let form = ConnectForm {
            driver_id: "mongodb".to_owned(),
            options: NetworkOptions {
                dns_seed_list: true,
                ..NetworkOptions::default()
            },
            ..tunnelled(SshAuthChoice::Agent, "", "")
        };

        let errors = form.validate(mongodb()).err().expect("a seed list over SSH");

        assert!(errors.has(FormField::DnsSeedList), "{errors:?}");
    }

    #[test]
    fn redis_logs_in_with_a_password_alone_on_a_numbered_database() {
        let form = ConnectForm {
            username: String::new(),
            database: " 3 ".to_owned(),
            ..filled("redis", redis())
        };

        let valid = form.validate(redis()).expect("a password alone and a number");

        assert_eq!(network(&valid.target).2, Some("3"));
        assert_eq!(
            form.label(redis()),
            "db.example.com",
            "an empty username named the entry"
        );
        let named = ConnectForm {
            database: "sales".to_owned(),
            ..form.clone()
        };
        let errors = named.validate(redis()).err().expect("a name is not a database number");
        assert!(errors.has(FormField::Database), "{errors:?}");
        let anonymous = ConnectForm {
            username: String::new(),
            ..filled("postgres", postgres())
        };
        let errors = anonymous
            .validate(postgres())
            .err()
            .expect("PostgreSQL needs a username");
        assert!(errors.has(FormField::Username), "{errors:?}");
    }

    #[test]
    fn mysql_requires_database() {
        let empty = ConnectForm {
            database: "  ".to_owned(),
            ..filled("mysql", mysql())
        };
        let errors = empty.validate(mysql()).err().expect("MySQL needs a database");
        assert!(errors.has(FormField::Database), "{errors:?}");

        let postgres_empty = ConnectForm {
            database: String::new(),
            ..filled("postgres", postgres())
        };
        let valid = postgres_empty
            .validate(postgres())
            .expect("PostgreSQL opens the user's own database");
        assert_eq!(network(&valid.target).2, None, "an empty database was sent as a name");
    }

    #[test]
    fn client_identity_never_reaches_mssql() {
        let mut form = filled("mssql", mssql());
        form.tls.client_certificate = Some(PathBuf::from("/etc/tls/client.pem"));
        form.tls.client_key = Some(PathBuf::from("/etc/tls/client.key"));

        let valid = form.validate(mssql()).expect("the hidden rows are left out");
        assert_eq!(network(&valid.target).3.client_identity, None);

        let tls = form
            .tls
            .config(postgres().tls.as_ref().expect("tls"), TransportClass::DirectTcp);
        assert!(tls.client_identity.is_some(), "PostgreSQL lost the client certificate");
        let refused = TlsConfig {
            client_identity: tls.client_identity.clone(),
            ..TlsConfig::verify_full()
        }
        .validate(mssql().tls.as_ref().expect("tls"), TransportClass::DirectTcp)
        .expect_err("SQL Server takes no client certificate");
        assert_eq!(tls_field(&refused, &tls), FormField::ClientCertificate);
    }

    #[test]
    fn a_half_chosen_client_identity_points_at_the_missing_file() {
        let mut form = filled("postgres", postgres());
        form.tls.client_certificate = Some(PathBuf::from("/etc/tls/client.pem"));

        let errors = form.validate(postgres()).err().expect("an incomplete identity");

        assert!(errors.has(FormField::ClientKey), "{errors:?}");
    }

    #[test]
    fn file_driver_requires_file() {
        let form = ConnectForm::new("sqlite", sqlite());
        let errors = form.validate(sqlite()).err().expect("no file chosen");
        assert!(errors.has(FormField::File));
        assert!(
            errors.shown_on(FormField::File).is_none(),
            "an untouched row is painted red"
        );

        let path = PathBuf::from("/srv/app.db");
        let chosen = ConnectForm {
            file: Some(FileEndpoint::create_new(path.clone()).expect("absolute")),
            ..form
        };
        let valid = chosen.validate(sqlite()).expect("a file was chosen");
        let RequestTarget::File(endpoint) = valid.target else {
            panic!("expected a file target");
        };
        assert_eq!(endpoint.path(), path);
        assert_eq!(endpoint.mode(), tablepro_core::FileOpenMode::CreateNew);
    }

    #[test]
    fn ssh_key_auth_requires_path() {
        let mut form = filled("postgres", postgres());
        form.ssh = Some(SshFormState {
            host: "bastion".to_owned(),
            key_path: String::new(),
            auth: SshAuthChoice::PrivateKey,
            ..SshFormState::new(&SshEnvironment::default())
        });

        let errors = form.validate(postgres()).err().expect("a key login with no key");

        assert!(errors.has(FormField::SshKeyPath), "{errors:?}");
    }

    #[test]
    fn port_follows_endpoint_default_until_edited() {
        let mut form = ConnectForm::new("postgres", postgres());
        assert_eq!(form.port, 5432);

        form.switch_driver("mysql", mysql());
        assert_eq!(form.port, 3306);

        form.port = 6543;
        form.port_edited = true;
        form.switch_driver("mssql", mssql());
        assert_eq!(form.port, 6543, "a typed port was replaced");
    }

    #[test]
    fn driver_switch_keeps_host_database_username() {
        let mut form = filled("postgres", postgres());

        form.switch_driver("mysql", mysql());
        form.switch_driver("sqlite", sqlite());
        form.switch_driver("mssql", mssql());

        assert_eq!(form.host, "db.example.com");
        assert_eq!(form.database, "sales");
        assert_eq!(form.username, "app");
    }

    #[test]
    fn the_server_name_row_shows_where_the_driver_can_check_another_name() {
        assert!(!driver_shows_server_name(Some(mysql()), TransportClass::DirectTcp));
        assert!(driver_shows_server_name(Some(mysql()), TransportClass::SshForward));
        assert!(driver_shows_server_name(Some(postgres()), TransportClass::DirectTcp));
        assert!(!driver_shows_server_name(Some(sqlite()), TransportClass::DirectTcp));
        assert!(!driver_shows_server_name(None, TransportClass::SshForward));
    }

    #[test]
    fn hidden_fields_are_omitted_from_request() {
        let mut form = filled("mssql", mssql());
        form.auth = AuthMode::Kerberos;
        form.tls.mode = TlsMode::Disable;
        form.tls.ca_file = Some(PathBuf::from("/etc/tls/ca.pem"));
        form.tls.server_name = "db.internal".to_owned();

        let valid = form.validate(mssql()).expect("valid");
        let (_, credentials, _, tls) = network(&valid.target);
        assert!(matches!(credentials, Credentials::Integrated), "a password was sent");
        assert_eq!(tls, &TlsConfig::disabled(), "Disable still carried TLS files");

        let mut mysql_form = filled("mysql", mysql());
        mysql_form.tls.server_name = "db.internal".to_owned();
        let direct = mysql_form.validate(mysql()).expect("valid");
        assert_eq!(
            network(&direct.target).3.server_name,
            None,
            "MySQL cannot override the name over direct TCP"
        );

        let mut file_form = ConnectForm::new("sqlite", sqlite());
        file_form.host = "db.example.com".to_owned();
        file_form.ssh = Some(SshFormState::new(&SshEnvironment::default()));
        file_form.file = Some(FileEndpoint::open_existing(PathBuf::from("/srv/app.db")).expect("absolute"));
        let file = file_form.validate(sqlite()).expect("valid");
        assert!(matches!(file.target, RequestTarget::File(_)));
        assert!(file.ssh.is_none());
    }

    #[test]
    fn a_kerberos_form_saves_no_username_and_keeps_no_password() {
        let form = ConnectForm {
            auth: AuthMode::Kerberos,
            ..filled("mssql", mssql())
        };
        let valid = form.validate(mssql()).expect("valid");

        let entry = form.saved_connection(mssql(), &valid, Uuid::new_v4(), None);

        assert_eq!(entry.username, "");
        assert_eq!(entry.auth_mode, AuthMode::Kerberos);
        assert!(form.secrets_to_store(&valid, &entry).is_empty());
    }

    #[test]
    fn remember_off_keeps_no_password_and_forgets_the_old_one() {
        let remembering = filled("postgres", postgres());
        let valid = remembering.validate(postgres()).expect("valid");
        let entry = remembering.saved_connection(postgres(), &valid, Uuid::new_v4(), None);
        let stored = remembering.secrets_to_store(&valid, &entry);
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].kind, SecretKind::DatabasePassword);
        assert_eq!(stored[0].secret.expose_secret(), "s3cret");
        assert!(remembering.secrets_to_forget(&valid).is_empty());

        let forgetting = ConnectForm {
            remember_password: false,
            ..remembering
        };
        assert!(forgetting.secrets_to_store(&valid, &entry).is_empty());
        assert_eq!(forgetting.secrets_to_forget(&valid), vec![SecretKind::DatabasePassword]);
    }

    #[test]
    fn a_saved_entry_fills_the_form_it_was_saved_from() {
        let mut form = filled("postgres", postgres());
        form.port = 6543;
        form.port_edited = true;
        form.tls.ca_file = Some(PathBuf::from("/etc/tls/ca.pem"));
        form.ssh = Some(SshFormState {
            host: "bastion".to_owned(),
            auth: SshAuthChoice::Agent,
            ..SshFormState::new(&SshEnvironment::default())
        });
        let valid = form.validate(postgres()).expect("valid");
        let entry = form.saved_connection(postgres(), &valid, Uuid::new_v4(), None);

        let refilled = ConnectForm::from_saved(&entry, postgres());

        assert_eq!(refilled.host, "db.example.com");
        assert_eq!(refilled.port, 6543);
        assert!(refilled.port_edited);
        assert_eq!(refilled.tls, form.tls);
        let ssh = refilled.ssh.expect("the SSH section came back");
        assert_eq!(ssh.host, "bastion");
        assert_eq!(entry.ssh.as_ref().map(|ssh| &ssh.auth), Some(&SavedSshAuth::Agent));
    }

    fn saved_from(form: &ConnectForm, caps: &DriverCapabilities) -> SavedConnection {
        let valid = form.validate(caps).expect("valid");
        form.saved_connection(caps, &valid, Uuid::new_v4(), None)
    }

    fn changes(form: &ConnectForm, original: &SavedConnection, caps: &DriverCapabilities) -> SecretChanges {
        let valid = form.validate(caps).expect("valid");
        form.secret_changes(original, postgres(), &valid)
    }

    fn is_keep(change: &SecretChange) -> bool {
        matches!(change, SecretChange::Keep)
    }

    fn is_remove(change: &SecretChange) -> bool {
        matches!(change, SecretChange::Remove)
    }

    fn replaced_with(change: &SecretChange) -> Option<&str> {
        match change {
            SecretChange::Replace(secret) => Some(secret.expose_secret()),
            SecretChange::Keep | SecretChange::Remove => None,
        }
    }

    #[test]
    fn connect_form_from_saved_prefills_without_secrets() {
        let mut typed = filled("postgres", postgres());
        typed.name = "Shop".to_owned();
        typed.safe_mode = SafeModeLevel::ConfirmWrites;
        let saved = saved_from(&typed, postgres());

        let form = ConnectForm::from_saved(&saved, postgres());

        assert_eq!(form.name, "Shop");
        assert_eq!(form.host, "db.example.com");
        assert_eq!(form.database, "sales");
        assert_eq!(form.username, "app");
        assert_eq!(form.safe_mode, SafeModeLevel::ConfirmWrites);
        assert_eq!(form.password.expose_secret(), "", "a secret reached the form");
    }

    #[test]
    fn a_name_that_is_where_it_connects_follows_the_host() {
        let saved = saved_from(&filled("postgres", postgres()), postgres());
        assert_eq!(saved.name, "app@db.example.com");

        let mut form = ConnectForm::from_saved(&saved, postgres());
        assert_eq!(form.name, "", "the derived name was copied into the Name row");
        form.host = "db2.example.com".to_owned();

        assert_eq!(saved_from(&form, postgres()).name, "app@db2.example.com");
        form.name = "  Shop ".to_owned();
        assert_eq!(saved_from(&form, postgres()).name, "Shop");
    }

    #[test]
    fn the_tags_and_icon_go_through_the_form_and_back() {
        let tag = Uuid::new_v4();
        let saved = SavedConnection {
            tags: vec![tag],
            icon: Some(ConnectionIcon::Shield),
            ..saved_from(&filled("postgres", postgres()), postgres())
        };

        let form = ConnectForm::from_saved(&saved, postgres());
        assert_eq!(form.tags, [tag]);
        assert_eq!(form.icon, Some(ConnectionIcon::Shield));

        let untagged = ConnectForm {
            tags: Vec::new(),
            icon: None,
            ..form
        };
        let valid = untagged.validate(postgres()).expect("valid");
        let written = untagged.saved_connection(postgres(), &valid, saved.id, Some(&saved));
        assert!(written.tags.is_empty(), "the entry's tags came back over the form's");
        assert_eq!(written.icon, None);
    }

    #[test]
    fn a_reopened_entry_keeps_the_name_the_user_gave_it() {
        let form = filled("postgres", postgres());
        let valid = form.validate(postgres()).expect("valid");
        let renamed = SavedConnection {
            name: "Shop".to_owned(),
            ..saved_from(&form, postgres())
        };

        let submitted = form.submitted_connection(postgres(), &valid, renamed.id, Some(&renamed));
        assert_eq!(submitted.name, "Shop", "the connect undid the rename");

        let named = ConnectForm {
            name: "Shop (EU)".to_owned(),
            ..form.clone()
        };
        let valid = named.validate(postgres()).expect("valid");
        assert_eq!(
            named
                .submitted_connection(postgres(), &valid, renamed.id, Some(&renamed))
                .name,
            "Shop (EU)"
        );
    }

    #[test]
    fn a_derived_name_follows_the_form_on_a_connect() {
        let derived = saved_from(&filled("postgres", postgres()), postgres());
        let moved = ConnectForm {
            host: "db2.example.com".to_owned(),
            ..filled("postgres", postgres())
        };
        let valid = moved.validate(postgres()).expect("valid");

        let submitted = moved.submitted_connection(postgres(), &valid, derived.id, Some(&derived));

        assert_eq!(submitted.name, "app@db2.example.com");
    }

    #[test]
    fn typed_secrets_ignore_remember() {
        let mut form = filled("postgres", postgres());
        form.remember_password = false;
        let valid = form.validate(postgres()).expect("valid");
        assert_eq!(form.typed_secrets(&valid), [SecretKind::DatabasePassword]);

        form.password = SecretString::from(String::new());
        let valid = form.validate(postgres()).expect("valid");
        assert!(form.typed_secrets(&valid).is_empty());

        let tunnelled = tunnelled(SshAuthChoice::PrivateKey, "/home/u/.ssh/id_ed25519", "phrase");
        let valid = tunnelled.validate(postgres()).expect("valid");
        assert_eq!(
            tunnelled.typed_secrets(&valid),
            [SecretKind::DatabasePassword, SecretKind::SshPassphrase]
        );
    }

    #[test]
    fn secret_changes_from_form() {
        let original = saved_from(&filled("postgres", postgres()), postgres());
        let mut form = ConnectForm::from_saved(&original, postgres());

        let untouched = changes(&form, &original, postgres());
        assert!(is_keep(&untouched.database_password));
        assert!(is_keep(&untouched.ssh_password));
        assert!(is_keep(&untouched.ssh_passphrase));

        form.password = SecretString::from("n3w");
        assert_eq!(
            replaced_with(&changes(&form, &original, postgres()).database_password),
            Some("n3w")
        );

        form.remember_password = false;
        assert!(is_remove(&changes(&form, &original, postgres()).database_password));

        let kerberos_original = saved_from(&filled("mssql", mssql()), mssql());
        let kerberos = ConnectForm {
            auth: AuthMode::Kerberos,
            ..ConnectForm::from_saved(&kerberos_original, mssql())
        };
        let valid = kerberos.validate(mssql()).expect("valid");
        let moved = kerberos.secret_changes(&kerberos_original, mssql(), &valid);
        assert!(
            is_remove(&moved.database_password),
            "Password to Kerberos left the password stored"
        );
    }

    #[test]
    fn a_file_connection_has_no_password_to_remove() {
        let form = ConnectForm {
            file: Some(FileEndpoint::open_existing(PathBuf::from("/srv/app.db")).expect("absolute")),
            ..ConnectForm::new("sqlite", sqlite())
        };
        let original = saved_from(&form, sqlite());
        let valid = form.validate(sqlite()).expect("valid");

        let changes = form.secret_changes(&original, sqlite(), &valid);

        assert!(
            is_keep(&changes.database_password),
            "a file connection's edit asks the keyring"
        );
    }

    fn tunnelled(auth: SshAuthChoice, key_path: &str, passphrase: &str) -> ConnectForm {
        ConnectForm {
            ssh: Some(SshFormState {
                host: "bastion".to_owned(),
                auth,
                key_path: key_path.to_owned(),
                password: SecretString::from(String::new()),
                passphrase: SecretString::from(passphrase),
                ..SshFormState::new(&SshEnvironment::default())
            }),
            ..filled("postgres", postgres())
        }
    }

    #[test]
    fn an_ssh_secret_the_edit_no_longer_uses_is_removed() {
        let mut by_password = tunnelled(SshAuthChoice::Password, "", "");
        if let Some(ssh) = by_password.ssh.as_mut() {
            ssh.password = SecretString::from("tunnel");
        }
        let original = saved_from(&by_password, postgres());

        let agent = tunnelled(SshAuthChoice::Agent, "", "");
        assert!(is_remove(&changes(&agent, &original, postgres()).ssh_password));
        let kept = tunnelled(SshAuthChoice::Password, "", "");
        assert!(is_keep(&changes(&kept, &original, postgres()).ssh_password));
    }

    #[test]
    fn a_passphrase_goes_with_its_key_file() {
        let original = saved_from(
            &tunnelled(SshAuthChoice::PrivateKey, "/home/u/.ssh/id_ed25519", "phrase"),
            postgres(),
        );
        assert!(original.has_stored_passphrase());

        let same_key = tunnelled(SshAuthChoice::PrivateKey, "/home/u/.ssh/id_ed25519", "");
        assert!(is_keep(&changes(&same_key, &original, postgres()).ssh_passphrase));
        let other_key = tunnelled(SshAuthChoice::PrivateKey, "/home/u/.ssh/id_rsa", "");
        assert!(is_remove(&changes(&other_key, &original, postgres()).ssh_passphrase));
        let typed = tunnelled(SshAuthChoice::PrivateKey, "/home/u/.ssh/id_rsa", "other");
        assert_eq!(
            replaced_with(&changes(&typed, &original, postgres()).ssh_passphrase),
            Some("other")
        );
        let untunnelled = filled("postgres", postgres());
        assert!(is_remove(&changes(&untunnelled, &original, postgres()).ssh_passphrase));
    }
}
