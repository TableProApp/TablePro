use std::path::{Path, PathBuf};

use secrecy::SecretString;
use tablepro_core::credentials::SecretKind;
use tablepro_core::unicode_blank::is_default_ignorable;
use tablepro_core::{
    AiPolicy, AuthMode, ClientIdentity, DatabaseDriver, DriverCapabilities, ExternalAccess, NetworkOption,
    NetworkOptions, SafeModeLevel, TlsCapabilities, TlsConfig, TlsMode,
};
use tablepro_storage::{ConnectionColor, SavedConnection, SavedSshAuth, SavedSshConfig};
use uuid::Uuid;

use super::notes::{RowNote, TlsFileReason};
use crate::engine::{self, LocalFilePathField};
use crate::{
    ForeignAppDirs, ForeignColor, ForeignConnection, ForeignCredentials, ForeignJumpHost, ForeignSsh, ForeignSshAuth,
    ForeignSsl, ForeignSslMode,
};

const PROMPT_FOR_PASSWORD: &str = "promptForPassword";
// The macOS MongoDB driver's switch for a DNS seed list and its auth database, which the core
// keeps in NetworkOptions.
const MONGO_USE_SRV: &str = "mongoUseSrv";
const MONGO_AUTH_SOURCE: &str = "mongoAuthSource";

const DRIVER_IDS: &[(&str, &str)] = &[
    ("MySQL", "mysql"),
    ("MariaDB", "mysql"),
    ("PostgreSQL", "postgres"),
    ("SQLite", "sqlite"),
    ("DuckDB", "duckdb"),
    ("SQL Server", "mssql"),
    ("ClickHouse", "clickhouse"),
    ("Cassandra", "cassandra"),
    ("ScyllaDB", "cassandra"),
    ("Redis", "redis"),
    ("MongoDB", "mongodb"),
];

#[derive(Debug, Clone)]
pub struct ImportedSecret {
    pub kind: SecretKind,
    pub secret: SecretString,
}

pub(super) struct Mapped {
    pub(super) connection: SavedConnection,
    pub(super) notes: Vec<RowNote>,
    pub(super) secrets: Vec<ImportedSecret>,
}

pub(super) fn driver_id(engine: &str) -> Option<&'static str> {
    DRIVER_IDS
        .iter()
        .find(|(name, _)| *name == engine)
        .or_else(|| DRIVER_IDS.iter().find(|(name, _)| name.eq_ignore_ascii_case(engine)))
        .map(|(_, id)| *id)
}

pub(super) fn map(
    settings: &ForeignConnection,
    credentials: Option<&ForeignCredentials>,
    driver: &dyn DatabaseDriver,
    dirs: &ForeignAppDirs,
) -> Mapped {
    let caps = driver.capabilities();
    let mut notes = Vec::new();
    if settings
        .additional_fields
        .contains_key(crate::record::TLS_FROM_DRIVER_DEFAULT)
        && let Some(ssl) = &settings.ssl
    {
        notes.push(RowNote::TlsFromDriverDefault { mode: ssl.mode });
    }
    let file_based = caps.is_file_based();
    let (host, port, database, username, tls, auth_mode, ssh) = if file_based {
        if settings.ssh.is_some() {
            notes.push(RowNote::SshNotKept);
        }
        let tls = map_tls(settings.ssl.as_ref(), None, dirs, &mut notes);
        let path = dirs.expand_home(file_path(settings)).display().to_string();
        (String::new(), 0, path, String::new(), tls, AuthMode::Password, None)
    } else {
        let port = match settings.port {
            0 => caps.default_port().unwrap_or(0),
            port => port,
        };
        let tls = map_tls(settings.ssl.as_ref(), caps.tls.as_ref(), dirs, &mut notes);
        let ssh = settings
            .ssh
            .as_ref()
            .map(|ssh| map_ssh(ssh, credentials, dirs, &mut notes));
        (
            settings.host.trim().to_owned(),
            port,
            settings.database.clone(),
            settings.username.clone(),
            tls,
            caps.auth_modes.first().copied().unwrap_or_default(),
            ssh,
        )
    };
    let seed_list = settings
        .additional_fields
        .get(MONGO_USE_SRV)
        .is_some_and(|value| value == "true")
        && caps.network_options.contains(&NetworkOption::DnsSeedList);
    let auth_database = settings
        .additional_fields
        .get(MONGO_AUTH_SOURCE)
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty() && caps.network_options.contains(&NetworkOption::AuthDatabase));
    if settings.additional_fields.contains_key(crate::TLS_SETTINGS_UNREAD) {
        notes.push(RowNote::TlsSettingsNotRead);
    }
    let kept: Vec<&str> = [
        (seed_list, MONGO_USE_SRV),
        (auth_database.is_some(), MONGO_AUTH_SOURCE),
        (true, crate::TLS_SETTINGS_UNREAD),
        (true, crate::record::TLS_FROM_DRIVER_DEFAULT),
    ]
    .into_iter()
    .filter_map(|(kept, key)| kept.then_some(key))
    .collect();
    let dropped = dropped_fields(settings, &kept);
    if !dropped.is_empty() {
        notes.push(RowNote::FieldsNotKept { fields: dropped });
    }
    let connection = SavedConnection {
        id: Uuid::nil(),
        name: connection_name(&settings.name, &host, &database, &settings.engine),
        driver_id: driver.id().to_owned(),
        host,
        port,
        database,
        username,
        tls,
        safe_mode: SafeModeLevel::Off,
        external_access: ExternalAccess::default(),
        ai_policy: AiPolicy::default(),
        query_timeout_secs: None,
        auth_mode,
        ssh,
        last_opened_at: None,
        color: settings.color.map(color),
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: NetworkOptions {
            dns_seed_list: seed_list,
            auth_database,
            ..NetworkOptions::default()
        },
    };
    let secrets = secrets(&connection, caps, settings, credentials);
    Mapped {
        connection,
        notes,
        secrets,
    }
}

// Where the macOS app keeps the engine's file, then the database field another importer fills.
fn file_path(settings: &ForeignConnection) -> &str {
    let field = match engine::local_file_path_field(&settings.engine) {
        Some(LocalFilePathField::AdditionalField(key)) => settings.additional_fields.get(key),
        Some(LocalFilePathField::Database) | None => None,
    };
    field
        .map(String::as_str)
        .filter(|path| !path.trim().is_empty())
        .unwrap_or(&settings.database)
}

fn dropped_fields(settings: &ForeignConnection, kept: &[&str]) -> Vec<String> {
    let path_field = match engine::local_file_path_field(&settings.engine) {
        Some(LocalFilePathField::AdditionalField(key)) => Some(key),
        _ => None,
    };
    settings
        .additional_fields
        .keys()
        .filter(|key| key.as_str() != PROMPT_FOR_PASSWORD && Some(key.as_str()) != path_field)
        .filter(|key| !kept.contains(&key.as_str()))
        .cloned()
        .collect()
}

// As the library reads a stored name, so an imported one cannot pass for a saved one.
fn connection_name(name: &str, host: &str, database: &str, engine: &str) -> String {
    let shown: String = name
        .chars()
        .filter(|c| !is_default_ignorable(*c))
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let shown = shown.trim();
    if !shown.is_empty() {
        return shown.to_owned();
    }
    let file_name = Path::new(database).file_name().and_then(|name| name.to_str());
    [Some(host), file_name]
        .into_iter()
        .flatten()
        .find(|candidate| !candidate.is_empty())
        .unwrap_or(engine)
        .to_owned()
}

fn color(color: ForeignColor) -> ConnectionColor {
    match color {
        ForeignColor::Red => ConnectionColor::Red,
        ForeignColor::Orange => ConnectionColor::Orange,
        ForeignColor::Yellow => ConnectionColor::Yellow,
        ForeignColor::Green => ConnectionColor::Green,
        ForeignColor::Blue => ConnectionColor::Blue,
        ForeignColor::Purple => ConnectionColor::Purple,
        ForeignColor::Pink => ConnectionColor::Pink,
        ForeignColor::Gray => ConnectionColor::Slate,
    }
}

fn natural_mode(mode: ForeignSslMode) -> TlsMode {
    match mode {
        ForeignSslMode::Disabled => TlsMode::Disable,
        ForeignSslMode::Preferred => TlsMode::Prefer,
        ForeignSslMode::Required => TlsMode::Require,
        ForeignSslMode::VerifyCa | ForeignSslMode::VerifyIdentity => TlsMode::VerifyFull,
    }
}

fn strength(mode: TlsMode) -> u8 {
    match mode {
        TlsMode::Disable => 0,
        TlsMode::Prefer => 1,
        TlsMode::Require => 2,
        TlsMode::VerifyFull => 3,
        TlsMode::Strict => 4,
    }
}

// The weakest mode at least as strong as the one wanted, or the strongest below it when none is.
fn nearest_mode(wanted: TlsMode, offered: &[TlsMode]) -> Option<TlsMode> {
    let floor = strength(wanted);
    let stronger = offered
        .iter()
        .copied()
        .filter(|mode| strength(*mode) >= floor)
        .min_by_key(|mode| strength(*mode));
    stronger.or_else(|| offered.iter().copied().max_by_key(|mode| strength(*mode)))
}

fn written(path: Option<&str>) -> Option<&str> {
    path.filter(|path| !path.trim().is_empty())
}

// The path as an absolute one, None for none written, Err for a relative one.
fn absolute_path(raw: Option<&str>, dirs: &ForeignAppDirs) -> Result<Option<PathBuf>, ()> {
    let Some(raw) = raw.map(str::trim).filter(|raw| !raw.is_empty()) else {
        return Ok(None);
    };
    let path = dirs.expand_home(raw);
    if path.is_absolute() { Ok(Some(path)) } else { Err(()) }
}

fn map_tls(
    ssl: Option<&ForeignSsl>,
    caps: Option<&TlsCapabilities>,
    dirs: &ForeignAppDirs,
    notes: &mut Vec<RowNote>,
) -> TlsConfig {
    let from = ssl.map_or(ForeignSslMode::Disabled, |ssl| ssl.mode);
    let wanted = natural_mode(from);
    let Some((caps, mode)) = caps.and_then(|caps| nearest_mode(wanted, caps.modes).map(|mode| (caps, mode))) else {
        if from != ForeignSslMode::Disabled {
            notes.push(RowNote::TlsNotKept { from });
        }
        return TlsConfig::disabled();
    };
    if mode != wanted || from == ForeignSslMode::VerifyCa {
        notes.push(RowNote::TlsModeChanged { from, to: mode });
    }
    let mut config = TlsConfig {
        mode,
        ..TlsConfig::disabled()
    };
    let Some(ssl) = ssl else {
        return config;
    };
    config.ca_file = ca_file(ssl, caps, mode, dirs, notes);
    config.client_identity = client_identity(ssl, caps, mode, dirs, notes);
    config
}

fn ca_file(
    ssl: &ForeignSsl,
    caps: &TlsCapabilities,
    mode: TlsMode,
    dirs: &ForeignAppDirs,
    notes: &mut Vec<RowNote>,
) -> Option<PathBuf> {
    let written = written(ssl.ca_certificate_path.as_deref())?;
    let refused = |reason| {
        Some(RowNote::CaFileNotKept {
            path: written.to_owned(),
            reason,
        })
    };
    let (kept, note) = if !caps.ca_file {
        (None, refused(TlsFileReason::EngineLacks))
    } else if mode != TlsMode::VerifyFull {
        (None, refused(TlsFileReason::ModeLacks))
    } else {
        match absolute_path(Some(written), dirs) {
            Ok(path) => (path, None),
            Err(()) => (None, refused(TlsFileReason::RelativePath)),
        }
    };
    notes.extend(note);
    kept
}

fn client_identity(
    ssl: &ForeignSsl,
    caps: &TlsCapabilities,
    mode: TlsMode,
    dirs: &ForeignAppDirs,
    notes: &mut Vec<RowNote>,
) -> Option<ClientIdentity> {
    let certificate = written(ssl.client_certificate_path.as_deref());
    let key = written(ssl.client_key_path.as_deref());
    let mut refused = |reason| {
        notes.push(RowNote::ClientIdentityNotKept { reason });
        None
    };
    let (certificate, key) = match (certificate, key) {
        (None, None) => return None,
        (Some(certificate), Some(key)) => (certificate, key),
        _ => return refused(TlsFileReason::Incomplete),
    };
    if !caps.client_identity {
        return refused(TlsFileReason::EngineLacks);
    }
    if mode == TlsMode::Disable {
        return refused(TlsFileReason::ModeLacks);
    }
    match (absolute_path(Some(certificate), dirs), absolute_path(Some(key), dirs)) {
        (Ok(Some(certificate)), Ok(Some(key))) => Some(ClientIdentity { certificate, key }),
        _ => refused(TlsFileReason::RelativePath),
    }
}

fn map_ssh(
    ssh: &ForeignSsh,
    credentials: Option<&ForeignCredentials>,
    dirs: &ForeignAppDirs,
    notes: &mut Vec<RowNote>,
) -> SavedSshConfig {
    let auth = match ssh.auth {
        ForeignSshAuth::Password => SavedSshAuth::Password,
        ForeignSshAuth::Agent => SavedSshAuth::Agent,
        ForeignSshAuth::PrivateKey => {
            let path = absolute_path(Some(&ssh.private_key_path), dirs).unwrap_or_else(|()| {
                notes.push(RowNote::SshKeyNotKept {
                    path: ssh.private_key_path.clone(),
                });
                None
            });
            SavedSshAuth::PrivateKey {
                path,
                has_passphrase: credentials.is_some_and(|credentials| credentials.key_passphrase.is_some()),
            }
        }
    };
    let jump_hosts = ssh
        .jump_hosts
        .iter()
        .filter_map(|jump| jump_host(jump, notes))
        .collect();
    SavedSshConfig {
        host: ssh.host.trim().to_owned(),
        port: ssh.port.filter(|port| *port != 0),
        username: Some(ssh.username.trim().to_owned()).filter(|user| !user.is_empty()),
        jump_hosts,
        auth,
    }
}

// One `user@host:port` hop of the list ssh -J takes, or None when the hop cannot be written as one.
fn jump_host(jump: &ForeignJumpHost, notes: &mut Vec<RowNote>) -> Option<String> {
    let host = jump.host.trim();
    let host = host
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(host);
    let user = jump.username.trim();
    let breaks_list = |part: &str, extra: &[char]| {
        part.chars()
            .any(|c| c.is_whitespace() || c == ',' || extra.contains(&c))
    };
    if host.is_empty() || breaks_list(host, &['@', '[', ']']) || breaks_list(user, &[]) {
        notes.push(RowNote::JumpHostNotKept {
            host: jump.host.clone(),
        });
        return None;
    }
    match jump.auth {
        ForeignSshAuth::Password => notes.push(RowNote::JumpHostPasswordNotKept { host: host.to_owned() }),
        ForeignSshAuth::PrivateKey if !jump.private_key_path.trim().is_empty() => {
            notes.push(RowNote::JumpHostKeyNotKept {
                host: host.to_owned(),
                path: jump.private_key_path.clone(),
            });
        }
        ForeignSshAuth::PrivateKey | ForeignSshAuth::Agent => {}
    }
    let mut hop = String::new();
    if !user.is_empty() {
        hop.push_str(user);
        hop.push('@');
    }
    if host.contains(':') {
        hop.push_str(&format!("[{host}]"));
    } else {
        hop.push_str(host);
    }
    if let Some(port) = jump.port.filter(|port| *port != 0) {
        hop.push_str(&format!(":{port}"));
    }
    Some(hop)
}

fn secrets(
    connection: &SavedConnection,
    caps: &DriverCapabilities,
    settings: &ForeignConnection,
    credentials: Option<&ForeignCredentials>,
) -> Vec<ImportedSecret> {
    let Some(credentials) = credentials else {
        return Vec::new();
    };
    let prompts = settings
        .additional_fields
        .get(PROMPT_FOR_PASSWORD)
        .is_some_and(|value| value == "true");
    let signs_in_with_password =
        !caps.is_file_based() && caps.supports(AuthMode::Password) && connection.auth_mode == AuthMode::Password;
    let ssh_auth = connection.ssh.as_ref().map(|ssh| &ssh.auth);
    let wanted = [
        (
            SecretKind::DatabasePassword,
            &credentials.password,
            signs_in_with_password && !prompts,
        ),
        (
            SecretKind::SshPassword,
            &credentials.ssh_password,
            matches!(ssh_auth, Some(SavedSshAuth::Password)),
        ),
        (
            SecretKind::SshPassphrase,
            &credentials.key_passphrase,
            matches!(ssh_auth, Some(SavedSshAuth::PrivateKey { .. })),
        ),
    ];
    wanted
        .into_iter()
        .filter(|(_, _, kept)| *kept)
        .filter_map(|(kind, secret, _)| secret.clone().map(|secret| ImportedSecret { kind, secret }))
        .collect()
}
