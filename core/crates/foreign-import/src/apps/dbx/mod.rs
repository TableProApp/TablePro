// DBX (t8y2/dbx), a Tauri app. It keeps every connection as one JSON document in a row of
// `dbx.db`, and its passwords apart, encrypted under a key held in the system keyring, so only the
// connections are read.

mod locations;

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;
use tokio_util::sync::CancellationToken;

use crate::app::{AppReader, check_cancel};
use crate::apps::jdbc;
use crate::apps::sqlite::Database;
use crate::collect::assemble;
use crate::engine::{self, LocalFilePathField};
use crate::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignConnection, ForeignConnectionRecord,
    ForeignImportError, ForeignJumpHost, ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode, ImportRequest,
    Inventory, PasswordOutcome,
};

const APP: ForeignApp = ForeignApp::Dbx;

pub(crate) struct Dbx {
    data_dir: PathBuf,
}

impl Dbx {
    pub(crate) fn locate(dirs: &ForeignAppDirs) -> Self {
        Self {
            data_dir: locations::data_dir(dirs),
        }
    }

    fn open(&self) -> Result<Database, ForeignImportError> {
        let path = self.data_dir.join(locations::STORE);
        if !path.exists() {
            return Err(ForeignImportError::FileNotFound { app: APP });
        }
        Database::open_read_only(&path).ok_or_else(|| ForeignImportError::parse("Could not open dbx.db"))
    }

    // The JSON of each row. One that is not valid JSON is skipped, as the app skips it.
    fn configs(&self) -> Result<Vec<Config>, ForeignImportError> {
        let db = self.open()?;
        let Some(mut statement) = db.prepare("SELECT config_json FROM connections ORDER BY rowid") else {
            return Err(ForeignImportError::parse("dbx.db has no connections table"));
        };
        let mut configs = Vec::new();
        while let Some(row) = statement.next_row() {
            let Some(json) = row.text(0) else {
                continue;
            };
            match serde_json::from_str::<Config>(&json) {
                Ok(config) => configs.push(config),
                Err(error) => tracing::warn!(%error, "skipping a DBX connection that does not parse"),
            }
        }
        Ok(configs)
    }
}

impl AppReader for Dbx {
    fn has_data(&self) -> bool {
        self.data_dir.join(locations::STORE).exists()
    }

    fn inventory(&self) -> Inventory {
        Inventory {
            connections: self.configs().map_or(0, |configs| {
                configs.iter().filter(|config| engine_of(config).is_some()).count()
            }),
            saved_queries: 0,
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let configs = self.configs()?;
        let mut records = Vec::with_capacity(configs.len());
        for config in configs {
            check_cancel(cancel)?;
            let Some(engine) = engine_of(&config) else {
                tracing::warn!("skipping a DBX connection with no database type");
                continue;
            };
            records.push(record(&config, engine));
        }
        // The passwords are encrypted under a key in the system keyring, which this does not read.
        let passwords = if request.include_passwords {
            PasswordOutcome::LeftInKeychain
        } else {
            PasswordOutcome::NotRequested
        };
        assemble(APP, records, Vec::new(), passwords)
    }
}

// The fields of `ConnectionConfig` an import reads. The app has about seventy; a field this does
// not name is ignored, and one the app left out is its default.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct Config {
    id: String,
    name: String,
    db_type: String,
    host: String,
    port: Option<u16>,
    username: String,
    database: Option<String>,
    color: Option<String>,
    ssl: bool,
    // The driver parameters of the connection, `sslmode=verify-full&...`: the app has no TLS mode
    // field of its own, so the mode rides here.
    url_params: Option<String>,
    ca_cert_path: Option<String>,
    client_cert_path: Option<String>,
    client_key_path: Option<String>,
    transport_layers: Vec<Layer>,
}

// `#[serde(tag = "type")]` in the app: `ssh`, `proxy` and `http_tunnel`. Only SSH has a meaning here.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Layer {
    Ssh(SshLayer),
    #[serde(other)]
    Other,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct SshLayer {
    enabled: Option<bool>,
    host: String,
    port: Option<u16>,
    user: String,
    key_path: Option<String>,
    use_ssh_agent: bool,
}

fn engine_of(config: &Config) -> Option<String> {
    let raw = config.db_type.trim();
    if raw.is_empty() {
        return None;
    }
    // The app's `db_type` ids, each of which is the lowercase of an engine name TablePro has, but
    // for these.
    let mapped = match raw.to_lowercase().as_str() {
        "postgres" | "postgresql" => "PostgreSQL",
        "sqlserver" | "mssql" => "SQL Server",
        "mongodb" | "mongo" => "MongoDB",
        "duckdb" => "DuckDB",
        "sqlite" => "SQLite",
        _ => return Some(engine::resolve(raw)),
    };
    Some(mapped.to_owned())
}

fn record(config: &Config, engine: String) -> ForeignConnectionRecord {
    let file_field = engine::local_file_path_field(&engine);
    let mut additional_fields = BTreeMap::new();
    // A file engine's path is kept where the host goes.
    let (host, database) = match (file_field, config.host.is_empty()) {
        (Some(LocalFilePathField::Database), false) => (String::new(), config.host.clone()),
        (Some(LocalFilePathField::AdditionalField(field)), false) => {
            additional_fields.insert(field.to_owned(), config.host.clone());
            (String::new(), String::new())
        }
        _ => (
            if config.host.is_empty() {
                "localhost".to_owned()
            } else {
                config.host.clone()
            },
            config.database.clone().unwrap_or_default(),
        ),
    };
    let port = match config.port {
        Some(port) if port != 0 => port,
        _ if file_field.is_some() => 0,
        _ => engine::default_port(&engine),
    };
    let ssh = config.transport_layers.iter().find_map(|layer| match layer {
        Layer::Ssh(ssh) if ssh.enabled != Some(false) && !ssh.host.is_empty() => Some(ssh_of(ssh)),
        _ => None,
    });
    let ssl = ssl_of(config, &mut additional_fields);
    let settings = ForeignConnection {
        name: if config.name.is_empty() {
            "Untitled".to_owned()
        } else {
            config.name.clone()
        },
        host,
        port,
        database,
        username: config.username.clone(),
        engine,
        ssh,
        ssl,
        color: map_color(config.color.as_deref()),
        additional_fields,
    };
    ForeignConnectionRecord {
        source_id: Some(config.id.clone()).filter(|id| !id.is_empty()),
        group_path: Vec::new(),
        credentials: None,
        settings,
    }
}

fn ssh_of(layer: &SshLayer) -> ForeignSsh {
    let key = layer.key_path.as_deref().unwrap_or_default();
    let auth = if layer.use_ssh_agent {
        ForeignSshAuth::Agent
    } else if key.is_empty() {
        ForeignSshAuth::Password
    } else {
        ForeignSshAuth::PrivateKey
    };
    ForeignSsh {
        host: layer.host.clone(),
        port: layer.port,
        username: layer.user.clone(),
        auth,
        private_key_path: super::resolve_key_path(key),
        jump_hosts: Vec::<ForeignJumpHost>::new(),
    }
}

// The app has no TLS mode field: `ssl` turns TLS on, a CA file makes it check the server, and a
// `sslmode` driver parameter can name any mode, even with `ssl` off. The parameter wins when it names
// one, so a verified connection is not imported as an unverified one, and TLS set in a way this does
// not read marks the record, so the review asks instead of importing the connection off.
fn ssl_of(config: &Config, fields: &mut BTreeMap<String, String>) -> Option<ForeignSsl> {
    let named = |path: &Option<String>| path.clone().filter(|path| !path.is_empty());
    let params = config
        .url_params
        .as_deref()
        .unwrap_or_default()
        .trim()
        .trim_start_matches('?');
    let from_params = if params.is_empty() {
        None
    } else {
        let sets_other_tls = params
            .split(['&', ';'])
            .filter_map(|pair| pair.split_once('='))
            .map(|(key, _)| key.trim().to_lowercase())
            .any(|key| key != "sslmode" && jdbc::is_tls_parameter(&key));
        if sets_other_tls {
            fields.insert(crate::TLS_SETTINGS_UNREAD.to_owned(), "true".to_owned());
        }
        jdbc::url_ssl_or_mark(&format!("dbx://host/?{params}"), fields)
    };
    let (ca, cert, key) = (
        named(&config.ca_cert_path),
        named(&config.client_cert_path),
        named(&config.client_key_path),
    );
    // What `ssl` and the files imply, which a parameter may raise but never lower.
    let implied = match (config.ssl, ca.is_some()) {
        (true, true) => Some(ForeignSslMode::VerifyCa),
        (true, false) => Some(ForeignSslMode::Required),
        (false, _) => None,
    };
    let mode = match (from_params.map(|ssl| ssl.mode), implied) {
        (Some(named), Some(implied)) => stricter(named, implied),
        (Some(mode), None) | (None, Some(mode)) => mode,
        (None, None) => return None,
    };
    Some(ForeignSsl {
        mode,
        ca_certificate_path: ca,
        client_certificate_path: cert,
        client_key_path: key,
    })
}

fn stricter(a: ForeignSslMode, b: ForeignSslMode) -> ForeignSslMode {
    let rank = |mode: ForeignSslMode| match mode {
        ForeignSslMode::Disabled => 0,
        ForeignSslMode::Preferred => 1,
        ForeignSslMode::Required => 2,
        ForeignSslMode::VerifyCa => 3,
        ForeignSslMode::VerifyIdentity => 4,
    };
    if rank(b) > rank(a) { b } else { a }
}

fn map_color(raw: Option<&str>) -> Option<ForeignColor> {
    match raw?.to_lowercase().as_str() {
        "red" => Some(ForeignColor::Red),
        "orange" => Some(ForeignColor::Orange),
        "yellow" => Some(ForeignColor::Yellow),
        "green" => Some(ForeignColor::Green),
        "blue" => Some(ForeignColor::Blue),
        "purple" => Some(ForeignColor::Purple),
        "pink" => Some(ForeignColor::Pink),
        "gray" | "grey" => Some(ForeignColor::Gray),
        _ => None,
    }
}
