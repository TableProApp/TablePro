mod consoles;
mod data_sources;
mod locations;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio_util::sync::CancellationToken;

use self::consoles::ConsoleSource;
use self::data_sources::{DataSource, Fragment, SshConfig, SshReference, SslProperties};
use self::locations::Location;
use crate::app::{AppReader, check_cancel};
use crate::apps::jetbrains::{CredentialStore, Lookup};
use crate::apps::{jdbc, resolve_key_path};
use crate::collect::{PasswordOutcome, assemble};
use crate::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignConnection, ForeignConnectionRecord, ForeignCredentials,
    ForeignImportError, ForeignKeychain, ForeignPlatform, ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode,
    ImportRequest, Inventory, engine,
};

pub(crate) struct DataGrip {
    roots: Vec<PathBuf>,
    home: PathBuf,
    platform: ForeignPlatform,
    keychain: Option<Arc<dyn ForeignKeychain>>,
}

struct ScannedSource {
    source: DataSource,
    config_dir: PathBuf,
}

#[derive(Default)]
struct Scan {
    sources: Vec<ScannedSource>,
    // Every uuid DataGrip lists, including one that maps to no connection.
    console_sources: Vec<ConsoleSource>,
}

struct CollectedCredentials {
    credentials: Option<ForeignCredentials>,
    stopped: bool,
}

impl DataGrip {
    pub(crate) fn new(
        roots: Vec<PathBuf>,
        home: PathBuf,
        platform: ForeignPlatform,
        keychain: Option<Arc<dyn ForeignKeychain>>,
    ) -> Self {
        Self {
            roots,
            home,
            platform,
            keychain,
        }
    }

    pub(crate) fn locate(dirs: &ForeignAppDirs, keychain: Option<Arc<dyn ForeignKeychain>>) -> Self {
        Self::new(
            locations::jetbrains_roots(dirs),
            dirs.home.clone(),
            dirs.platform,
            keychain,
        )
    }

    fn config_dirs(&self) -> Vec<PathBuf> {
        locations::config_dirs(&self.roots)
    }

    // Locations run newest config dir first, so the first copy of a uuid wins.
    fn scan(&self, locations: &[Location]) -> Scan {
        let mut resolved: HashMap<String, usize> = HashMap::new();
        let mut fragments: HashMap<String, Fragment> = HashMap::new();
        let mut order: Vec<String> = Vec::new();
        let mut sources: Vec<ScannedSource> = Vec::new();

        for location in locations {
            for fragment in fragments_at(location, &self.home) {
                if !resolved.contains_key(&fragment.uuid)
                    && let Some(source) = fragment.resolved()
                {
                    resolved.insert(fragment.uuid.clone(), sources.len());
                    sources.push(ScannedSource {
                        source,
                        config_dir: location.config_dir.clone(),
                    });
                }
                if !fragments.contains_key(&fragment.uuid) {
                    order.push(fragment.uuid.clone());
                    fragments.insert(fragment.uuid.clone(), fragment);
                }
            }
        }

        let console_sources = order
            .into_iter()
            .filter_map(|uuid| {
                let fragment = fragments.get(&uuid)?;
                let source = resolved
                    .get(&uuid)
                    .and_then(|&index| sources.get(index))
                    .map(|scanned| &scanned.source);
                let driver_ref = source
                    .map(|source| source.driver_ref.as_str())
                    .or(fragment.driver_ref.as_deref());
                let jdbc_url = source
                    .map(|source| source.jdbc_url.as_str())
                    .or(fragment.jdbc_url.as_deref());
                Some(ConsoleSource {
                    is_mongo: is_mongo(driver_ref, jdbc_url),
                    uuid,
                })
            })
            .collect();
        Scan {
            sources,
            console_sources,
        }
    }

    fn credential_store(&self, config_dir: &Path) -> CredentialStore {
        CredentialStore::new(config_dir.to_path_buf(), self.platform, self.keychain.clone())
    }

    fn password_outcome(
        &self,
        request: &ImportRequest,
        stopped: bool,
        stores: &HashMap<PathBuf, CredentialStore>,
    ) -> PasswordOutcome {
        if !request.include_passwords {
            PasswordOutcome::NotRequested
        } else if stopped {
            PasswordOutcome::Stopped
        } else if self.keychain.is_none() && stores.values().any(|store| !store.kdbx_loaded()) {
            PasswordOutcome::LeftInKeychain
        } else {
            PasswordOutcome::Read
        }
    }
}

impl AppReader for DataGrip {
    fn has_data(&self) -> bool {
        !locations::locations(&self.config_dirs(), &self.home).is_empty()
    }

    fn inventory(&self) -> Inventory {
        let config_dirs = self.config_dirs();
        let scan = self.scan(&locations::locations(&config_dirs, &self.home));
        Inventory {
            connections: scan.sources.len(),
            saved_queries: consoles::count(&scan.console_sources, &config_dirs),
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let config_dirs = self.config_dirs();
        let locations = locations::locations(&config_dirs, &self.home);
        if locations.is_empty() {
            return Err(ForeignImportError::FileNotFound {
                app: ForeignApp::DataGrip,
            });
        }

        let scan = self.scan(&locations);
        let mut records = Vec::with_capacity(scan.sources.len());
        let mut stopped = false;
        let mut ssh_configs_by_dir: HashMap<PathBuf, HashMap<String, SshConfig>> = HashMap::new();
        let mut stores: HashMap<PathBuf, CredentialStore> = HashMap::new();

        for scanned in &scan.sources {
            check_cancel(cancel)?;
            let config_dir = &scanned.config_dir;
            let ssh_configs = ssh_configs_by_dir
                .entry(config_dir.clone())
                .or_insert_with(|| load_ssh_configs(config_dir, &self.home));

            let mut credentials = None;
            if request.include_passwords && !stopped {
                let store = stores
                    .entry(config_dir.clone())
                    .or_insert_with(|| self.credential_store(config_dir));
                let collected = collect_credentials(&scanned.source, ssh_configs, store);
                credentials = collected.credentials;
                stopped = collected.stopped;
            }

            records.push(ForeignConnectionRecord {
                source_id: Some(scanned.source.uuid.clone()),
                settings: make_connection(&scanned.source, ssh_configs),
                group_path: scanned.source.group_name.iter().cloned().collect(),
                credentials,
            });
        }

        let saved_queries = if request.include_saved_queries {
            consoles::saved_queries(
                &scan.console_sources,
                &config_dirs,
                request.saved_query_byte_limit,
                cancel,
            )?
        } else {
            Vec::new()
        };
        let passwords = self.password_outcome(request, stopped, &stores);
        assemble(ForeignApp::DataGrip, records, saved_queries, passwords)
    }
}

// The shared file carries the driver and URL, the local file the user name, SSH and SSL; per field the
// local file wins.
fn fragments_at(location: &Location, home: &Path) -> Vec<Fragment> {
    let mut by_uuid: HashMap<String, Fragment> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for path in std::iter::once(&location.data_sources).chain(location.local.as_ref()) {
        let Ok(data) = crate::files::read_capped(path) else {
            continue;
        };
        for fragment in data_sources::parse_fragments(&data, home) {
            match by_uuid.get_mut(&fragment.uuid) {
                Some(existing) => existing.merge(fragment),
                None => {
                    order.push(fragment.uuid.clone());
                    by_uuid.insert(fragment.uuid.clone(), fragment);
                }
            }
        }
    }
    order.into_iter().filter_map(|uuid| by_uuid.remove(&uuid)).collect()
}

fn load_ssh_configs(config_dir: &Path, home: &Path) -> HashMap<String, SshConfig> {
    crate::files::read_capped(config_dir.join("options").join("sshConfigs.xml"))
        .map(|data| data_sources::parse_ssh_configs(&data, home))
        .unwrap_or_default()
}

// `stopped` means the keychain refused or the KeePass file is locked, so no later row is read.
fn collect_credentials(
    source: &DataSource,
    ssh_configs: &HashMap<String, SshConfig>,
    store: &mut CredentialStore,
) -> CollectedCredentials {
    let mut credentials = ForeignCredentials::default();
    let mut stopped = false;

    match store.password(&source.uuid) {
        Lookup::Found(value) => credentials.password = Some(value),
        Lookup::Stopped => stopped = true,
        Lookup::NotFound => {}
    }

    let ssh = source
        .ssh
        .as_ref()
        .and_then(|reference| reference.config_id.as_deref())
        .and_then(|id| ssh_configs.get(id).map(|config| (id, config)));
    if !stopped && let Some((config_id, config)) = ssh {
        let port = config.port.unwrap_or(22);
        let uses_key = uses_key_authentication(
            config.auth_type.as_deref(),
            config.key_path.as_deref().unwrap_or_default(),
        );
        let lookup = if uses_key {
            store.ssh_key_passphrase(&config.host, port, config_id)
        } else {
            store.ssh_password(&config.host, port, config_id)
        };
        match lookup {
            Lookup::Found(value) if uses_key => credentials.key_passphrase = Some(value),
            Lookup::Found(value) => credentials.ssh_password = Some(value),
            Lookup::Stopped => stopped = true,
            Lookup::NotFound => {}
        }
    }

    CollectedCredentials {
        credentials: credentials.non_empty(),
        stopped,
    }
}

fn make_connection(source: &DataSource, ssh_configs: &HashMap<String, SshConfig>) -> ForeignConnection {
    let subprotocol = jdbc::subprotocol(&source.jdbc_url);
    let engine = map_driver_ref(&source.driver_ref, &subprotocol);
    let endpoint = jdbc::parse(&source.jdbc_url, &subprotocol);
    let port = endpoint
        .as_ref()
        .and_then(|endpoint| endpoint.port)
        .unwrap_or_else(|| engine::default_port(&engine));
    let (host, database, url_user) = match endpoint {
        Some(endpoint) => (endpoint.host, endpoint.database, endpoint.username),
        None => ("localhost".to_owned(), String::new(), None),
    };
    let mut additional_fields = jdbc::url_fields(&source.jdbc_url);
    // The macOS port read TLS from the XML alone, so a URL that asks for it imported in the clear.
    let ssl = match source.ssl.as_ref() {
        Some(ssl) => Some(make_ssl(ssl)),
        None => jdbc::url_ssl_or_mark(&source.jdbc_url, &mut additional_fields).or_else(|| {
            let mode = driver_default_mode(&engine, &subprotocol)?;
            jdbc::driver_default_ssl(&source.jdbc_url, source.tls_property, mode, &mut additional_fields)
        }),
    };
    ForeignConnection {
        name: source.name.clone(),
        host,
        port,
        database,
        username: Some(source.username.clone())
            .filter(|user| !user.is_empty())
            .or(url_user)
            .unwrap_or_default(),
        engine,
        ssh: make_ssh(source.ssh.as_ref(), ssh_configs),
        ssl,
        color: None,
        additional_fields,
    }
}

fn make_ssh(reference: Option<&SshReference>, ssh_configs: &HashMap<String, SshConfig>) -> Option<ForeignSsh> {
    let reference = reference?;
    let config = reference.config_id.as_ref().and_then(|id| ssh_configs.get(id));
    let host = config
        .map(|config| config.host.clone())
        .or_else(|| reference.inline_host.clone())
        .unwrap_or_default();
    if host.is_empty() {
        return None;
    }
    let key_path = config.and_then(|config| config.key_path.as_deref()).unwrap_or_default();
    let uses_key = uses_key_authentication(config.and_then(|config| config.auth_type.as_deref()), key_path);
    Some(ForeignSsh {
        host,
        port: config.and_then(|config| config.port).or(reference.inline_port),
        username: config
            .map(|config| config.username.clone())
            .or_else(|| reference.inline_user.clone())
            .unwrap_or_default(),
        auth: if uses_key {
            ForeignSshAuth::PrivateKey
        } else {
            ForeignSshAuth::Password
        },
        private_key_path: if uses_key {
            resolve_key_path(key_path)
        } else {
            String::new()
        },
        jump_hosts: Vec::new(),
    })
}

// DataGrip omits `authType` when the connection relies on the OpenSSH config, so a key path is the
// signal for key authentication.
fn uses_key_authentication(auth_type: Option<&str>, key_path: &str) -> bool {
    match auth_type.unwrap_or_default().to_uppercase().as_str() {
        "KEY_PAIR" | "PUBLIC_KEY" | "OPEN_SSH" => true,
        "PASSWORD" => false,
        _ => !key_path.is_empty(),
    }
}

fn make_ssl(ssl: &SslProperties) -> ForeignSsl {
    let mode = match ssl.mode.as_deref().unwrap_or_default().to_lowercase().as_str() {
        "require" | "required" => ForeignSslMode::Required,
        "verify_ca" | "verify-ca" => ForeignSslMode::VerifyCa,
        "verify_full" | "verify-full" => ForeignSslMode::VerifyIdentity,
        _ => ForeignSslMode::Preferred,
    };
    ForeignSsl {
        mode,
        ca_certificate_path: ssl.ca_cert_path.clone(),
        client_certificate_path: ssl.client_cert_path.clone(),
        client_key_path: ssl.client_key_path.clone(),
    }
}

// With "Use SSL" off DataGrip passes no TLS property, so the driver's own default applies: pgjdbc
// prefers TLS, Connector/J too, and mssql-jdbc 10.1 and later encrypts and checks the certificate.
// MariaDB Connector/J and jTDS start without TLS.
fn driver_default_mode(engine: &str, subprotocol: &str) -> Option<ForeignSslMode> {
    match (engine, subprotocol.to_lowercase().as_str()) {
        ("PostgreSQL", "postgresql") | ("MySQL", "mysql") => Some(ForeignSslMode::Preferred),
        ("SQL Server", "sqlserver") => Some(ForeignSslMode::VerifyIdentity),
        _ => None,
    }
}

fn is_mongo(driver_ref: Option<&str>, jdbc_url: Option<&str>) -> bool {
    let url = jdbc_url.unwrap_or_default();
    if url.to_lowercase().starts_with("mongodb") {
        return true;
    }
    map_driver_ref(driver_ref.unwrap_or_default(), &jdbc::subprotocol(url)) == "MongoDB"
}

fn map_driver_ref(driver_ref: &str, subprotocol: &str) -> String {
    let lowered = driver_ref.to_lowercase();
    let token = lowered.split('.').find(|part| !part.is_empty()).unwrap_or(&lowered);
    let engine = match token {
        "mysql" => "MySQL",
        "mariadb" => "MariaDB",
        "postgresql" | "postgres" => "PostgreSQL",
        "sqlite" => "SQLite",
        "sqlserver" | "mssql" | "jtds" => "SQL Server",
        "oracle" => "Oracle",
        "mongo" | "mongodb" => "MongoDB",
        "redis" => "Redis",
        "clickhouse" => "ClickHouse",
        "cassandra" => "Cassandra",
        "duckdb" => "DuckDB",
        "bigquery" => "BigQuery",
        "cockroach" | "cockroachdb" => "CockroachDB",
        "redshift" => "Redshift",
        _ => return map_subprotocol(subprotocol, driver_ref),
    };
    engine.to_owned()
}

fn map_subprotocol(subprotocol: &str, fallback: &str) -> String {
    let engine = match subprotocol.to_lowercase().as_str() {
        "mysql" => "MySQL",
        "mariadb" => "MariaDB",
        "postgresql" => "PostgreSQL",
        "sqlite" => "SQLite",
        "sqlserver" | "jtds" => "SQL Server",
        "oracle" => "Oracle",
        "mongodb" => "MongoDB",
        "redis" => "Redis",
        "clickhouse" => "ClickHouse",
        "cassandra" => "Cassandra",
        "duckdb" => "DuckDB",
        "bigquery" => "BigQuery",
        _ => return engine::resolve(fallback),
    };
    engine.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_driver_ref_decides_the_engine_before_the_url() {
        assert_eq!(map_driver_ref("mysql.8", "mysql"), "MySQL");
        assert_eq!(map_driver_ref("sqlserver.ms", "sqlserver"), "SQL Server");
        assert_eq!(map_driver_ref("sqlite.xerial", "sqlite"), "SQLite");
        assert_eq!(map_driver_ref("redshift", "redshift"), "Redshift");
        assert_eq!(map_driver_ref("custom.driver", "mariadb"), "MariaDB");
        assert_eq!(map_driver_ref(".mysql", ""), "MySQL");
    }

    fn source(driver_ref: &str, jdbc_url: &str) -> DataSource {
        DataSource {
            uuid: "uuid".to_owned(),
            name: "source".to_owned(),
            driver_ref: driver_ref.to_owned(),
            jdbc_url: jdbc_url.to_owned(),
            username: String::new(),
            group_name: None,
            ssh: None,
            ssl: None,
            tls_property: false,
        }
    }

    #[test]
    fn a_url_that_asks_for_tls_keeps_it_when_the_settings_name_none() {
        let verified = make_connection(
            &source("postgresql", "jdbc:postgresql://db.example.com/app?sslmode=verify-full"),
            &HashMap::new(),
        );
        assert_eq!(verified.ssl.map(|ssl| ssl.mode), Some(ForeignSslMode::VerifyIdentity));
        let plain = make_connection(
            &source("postgresql", "jdbc:postgresql://db.example.com/app"),
            &HashMap::new(),
        );
        assert_eq!(plain.ssl.map(|ssl| ssl.mode), Some(ForeignSslMode::Preferred));
        assert_eq!(
            plain.additional_fields.keys().collect::<Vec<_>>(),
            [crate::record::TLS_FROM_DRIVER_DEFAULT]
        );
        let disabled = make_connection(
            &source("postgresql", "jdbc:postgresql://db.example.com/app?sslmode=disable"),
            &HashMap::new(),
        );
        assert_eq!(disabled.ssl, None);
        assert!(disabled.additional_fields.is_empty());
        let unread = make_connection(
            &source("postgresql", "jdbc:postgresql://db.example.com/app?ssl=true"),
            &HashMap::new(),
        );
        assert_eq!(unread.ssl, None);
        assert_eq!(
            unread
                .additional_fields
                .get(crate::TLS_SETTINGS_UNREAD)
                .map(String::as_str),
            Some("true")
        );
    }

    #[test]
    fn a_native_mongo_url_keeps_its_server_and_its_seed_list() {
        let direct = make_connection(
            &source("mongo", "mongodb://mongo.example.com:27018/shop"),
            &HashMap::new(),
        );
        assert_eq!(
            (direct.host.as_str(), direct.port, direct.database.as_str()),
            ("mongo.example.com", 27018, "shop")
        );
        assert!(direct.additional_fields.is_empty());
        let seeded = make_connection(
            &source("mongo", "mongodb+srv://cluster0.example.net/app"),
            &HashMap::new(),
        );
        assert_eq!(seeded.host, "cluster0.example.net");
        assert_eq!(
            seeded.additional_fields.get(jdbc::MONGO_USE_SRV).map(String::as_str),
            Some("true")
        );
    }

    #[test]
    fn a_mongo_source_is_known_by_its_url_or_its_driver() {
        assert!(is_mongo(Some("unknown"), Some("mongodb://localhost:27017/x")));
        assert!(is_mongo(Some("mongo"), None));
        assert!(is_mongo(None, Some("jdbc:mongodb://h/db")));
        assert!(!is_mongo(Some("sqlite.xerial"), Some("jdbc:sqlite:/tmp/x.db")));
    }

    #[test]
    fn key_authentication_follows_the_auth_type_then_the_key_path() {
        assert!(uses_key_authentication(Some("open_ssh"), ""));
        assert!(!uses_key_authentication(Some("PASSWORD"), "/k"));
        assert!(uses_key_authentication(None, "/k"));
        assert!(!uses_key_authentication(None, ""));
    }
}
