use std::path::{Path, PathBuf};

use secrecy::SecretString;
use tablepro_core::credentials::{SecretKind, SecretSave};
use tablepro_core::{
    AuthMode, ClientIdentity, ConfigError, Credentials, DriverCapabilities, FileEndpoint, NetworkEndpoint,
    ServerNameOverride, TlsCapabilities, TlsConfig, TlsMode, TransportClass,
};
use tablepro_session::RequestTarget;
use tablepro_storage::{SavedConnection, SavedSshConfig};
use uuid::Uuid;

use super::form_errors::FormErrors;
use super::form_field::FormField;
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

    /// The settings a request carries. A row the driver does not show
    /// is left out rather than cleared, so looking at another driver
    /// and coming back keeps what was chosen.
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
            ca_file: self.ca_file.clone().filter(|_| caps.ca_file),
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

/// What the connect dialog holds, read from its rows in one go so a
/// connect works from a snapshot.
#[derive(Debug, Clone)]
pub struct ConnectForm {
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
    pub read_only: bool,
    pub ssh: Option<SshFormState>,
    pub file: Option<FileEndpoint>,
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
            read_only: false,
            ssh: None,
            file: None,
        }
    }

    /// The form a saved connection fills, for editing it after a failed
    /// connect. Secrets are not read: they live in the keyring.
    pub fn from_saved(saved: &SavedConnection, caps: &DriverCapabilities) -> Self {
        let mut form = Self::new(&saved.driver_id, caps);
        form.read_only = saved.read_only;
        if caps.is_file_based() {
            form.file = FileEndpoint::open_existing(PathBuf::from(&saved.database)).ok();
            return form;
        }
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
                if username.is_empty() {
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
        if caps.database_required && database.is_empty() {
            errors.push(
                FormField::Database,
                config_message(&ConfigError::DatabaseRequired),
                true,
            );
        }

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
            },
            ssh: saved_ssh,
        })
    }

    /// How the entry is named in the connection list.
    pub fn label(&self, caps: &DriverCapabilities) -> String {
        if caps.is_file_based() {
            return self
                .file
                .as_ref()
                .map(|file| file.path().display().to_string())
                .unwrap_or_default();
        }
        let host = self.host.trim();
        match self.auth {
            AuthMode::Kerberos => host.to_owned(),
            AuthMode::Password => format!("{}@{host}", self.username.trim()),
        }
    }

    /// The entry a successful connect writes. Colour, group and the
    /// last-opened time come from the entry it replaces, because this
    /// form does not show them.
    pub fn saved_connection(
        &self,
        caps: &DriverCapabilities,
        valid: &ValidatedForm,
        id: Uuid,
        existing: Option<&SavedConnection>,
    ) -> SavedConnection {
        let (host, port, database, username, tls, auth_mode) = match &valid.target {
            RequestTarget::File(endpoint) => (
                String::new(),
                0,
                endpoint.path().display().to_string(),
                String::new(),
                TlsConfig::disabled(),
                AuthMode::Password,
            ),
            RequestTarget::Network {
                endpoint,
                credentials,
                database,
                tls,
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
            ),
        };
        SavedConnection {
            id,
            name: self.label(caps),
            driver_id: self.driver_id.clone(),
            host,
            port,
            database,
            username,
            tls,
            read_only: self.read_only,
            auth_mode,
            ssh: valid.ssh.as_ref().map(|(saved, _)| saved.clone()),
            last_opened_at: existing.and_then(|saved| saved.last_opened_at),
            color: existing.and_then(|saved| saved.color),
            group: existing.and_then(|saved| saved.group.clone()),
        }
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

/// The saved entry the form describes again, so connecting twice to
/// the same database updates one entry instead of adding a second.
pub fn match_saved_connection(
    saved: &[SavedConnection],
    candidate: &SavedConnection,
    file_based: bool,
) -> Option<Uuid> {
    saved
        .iter()
        .find(|entry| same_connection(entry, candidate, file_based))
        .map(|entry| entry.id)
}

fn same_connection(entry: &SavedConnection, candidate: &SavedConnection, file_based: bool) -> bool {
    if entry.driver_id != candidate.driver_id || entry.database != candidate.database {
        return false;
    }
    // A file is reached by its path alone. Comparing the credentials
    // there would strand every entry an older build wrote with the
    // hidden Username row's leftover text.
    if file_based {
        return true;
    }
    entry.host == candidate.host
        && entry.port == candidate.port
        && entry.username == candidate.username
        && entry.auth_mode == candidate.auth_mode
        && entry.ssh == candidate.ssh
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
        caps(&drivers_postgres::PgDriver)
    }

    fn mysql() -> &'static DriverCapabilities {
        caps(&drivers_mysql::MysqlDriver)
    }

    fn mssql() -> &'static DriverCapabilities {
        caps(&drivers_mssql::MssqlDriver)
    }

    fn sqlite() -> &'static DriverCapabilities {
        caps(&drivers_sqlite::SqliteDriver)
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

    fn saved(driver_id: &str, username: &str, auth_mode: AuthMode) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "saved".into(),
            driver_id: driver_id.into(),
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            tls: TlsConfig::disabled(),
            read_only: false,
            auth_mode,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
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

    #[test]
    fn match_saved_connection_by_path_for_files() {
        let mut legacy = saved("sqlite", "postgres", AuthMode::Password);
        legacy.database = "/srv/app.db".into();
        let form = ConnectForm {
            file: Some(FileEndpoint::open_existing(PathBuf::from("/srv/app.db")).expect("absolute")),
            ..ConnectForm::new("sqlite", sqlite())
        };
        let valid = form.validate(sqlite()).expect("valid");
        let candidate = form.saved_connection(sqlite(), &valid, Uuid::new_v4(), None);

        assert_eq!(
            match_saved_connection(std::slice::from_ref(&legacy), &candidate, true),
            Some(legacy.id)
        );
    }

    #[test]
    fn match_saved_connection_distinguishes_user_and_auth() {
        let entry = saved("mssql", "sa", AuthMode::Password);
        let entries = std::slice::from_ref(&entry);
        let candidate = |username: &str, auth_mode: AuthMode| SavedConnection {
            id: Uuid::new_v4(),
            username: username.into(),
            auth_mode,
            ..entry.clone()
        };

        assert_eq!(
            match_saved_connection(entries, &candidate("sa", AuthMode::Password), false),
            Some(entry.id)
        );
        assert_eq!(
            match_saved_connection(entries, &candidate("other", AuthMode::Password), false),
            None
        );
        assert_eq!(
            match_saved_connection(entries, &candidate("", AuthMode::Kerberos), false),
            None
        );
        let finance = SavedConnection {
            database: "finance".into(),
            ..candidate("sa", AuthMode::Password)
        };
        assert_eq!(match_saved_connection(entries, &finance, false), None);
    }
}
