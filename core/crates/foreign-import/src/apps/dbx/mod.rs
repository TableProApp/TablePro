// DBX (t8y2/dbx), a Tauri app that keeps everything in one SQLite file, `dbx.db`. The shapes read here
// are those of `crates/dbx-core/src/persistence/storage.rs` and `crates/dbx-types/src/models/connection.rs`.

mod config;
mod locations;
mod store;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

use tokio_util::sync::CancellationToken;

use self::config::{Config, Layer, SshLayer};
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

// What a connection does on DBX that TablePro has no field for, keyed as the review lists it. None of
// these is carried: each one runs SQL, starts a command or routes the connection another way.
const PROXY: &str = "proxy";
const HTTP_TUNNEL: &str = "httpTunnel";
const SSH_TUNNEL: &str = "sshTunnel";
const PROXY_COMMAND: &str = "sshProxyCommand";
const INIT_SCRIPT: &str = "initScript";
const ATTACHED_DATABASES: &str = "attachedDatabases";
const CONNECTION_STRING: &str = "connectionString";

// The six swatches of DBX's connection dialog.
const SWATCHES: [(&str, ForeignColor); 6] = [
    ("#22c55e", ForeignColor::Green),
    ("#eab308", ForeignColor::Yellow),
    ("#f97316", ForeignColor::Orange),
    ("#ef4444", ForeignColor::Red),
    ("#3b82f6", ForeignColor::Blue),
    ("#a855f7", ForeignColor::Purple),
];

pub(crate) struct Dbx {
    data_dir: PathBuf,
}

impl Dbx {
    pub(crate) fn locate(dirs: &ForeignAppDirs) -> Self {
        Self {
            data_dir: locations::data_dir(dirs),
        }
    }

    fn store(&self) -> PathBuf {
        self.data_dir.join(locations::STORE)
    }

    fn open(&self) -> Result<Database, ForeignImportError> {
        let path = self.store();
        if !path.is_file() {
            return Err(ForeignImportError::FileNotFound { app: APP });
        }
        Database::open_read_only(&path).ok_or_else(|| ForeignImportError::parse("Could not open dbx.db"))
    }
}

struct Lookups {
    profiles: HashMap<String, Layer>,
    groups: HashMap<String, Vec<String>>,
    secret_names: HashMap<String, HashSet<String>>,
}

impl AppReader for Dbx {
    fn has_data(&self) -> bool {
        self.store().is_file()
    }

    fn inventory(&self) -> Inventory {
        let Ok(db) = self.open() else {
            return Inventory::default();
        };
        Inventory {
            connections: configs(&db).map_or(0, |configs| configs.len()),
            saved_queries: store::saved_sql_count(&db),
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let db = self.open()?;
        let configs = configs(&db)?;
        let lookups = Lookups {
            profiles: store::tunnel_profiles(&db),
            groups: store::group_paths(&db),
            secret_names: store::secret_names(&db),
        };
        let mut records = Vec::with_capacity(configs.len());
        for (config, engine) in configs {
            check_cancel(cancel)?;
            records.push(record(&config, engine, &lookups));
        }
        let saved_queries = if request.include_saved_queries {
            store::saved_sql(&db, request.saved_query_byte_limit, cancel)?
        } else {
            Vec::new()
        };
        // DBX encrypts every secret under a key it keeps in the system keyring.
        let passwords = if request.include_passwords {
            PasswordOutcome::LeftInKeychain
        } else {
            PasswordOutcome::NotRequested
        };
        assemble(APP, records, saved_queries, passwords)
    }
}

// A row that is not valid JSON or names no engine is left out, as DBX leaves out a row it cannot read.
fn configs(db: &Database) -> Result<Vec<(Config, String)>, ForeignImportError> {
    let configs = store::connection_rows(db)?
        .iter()
        .filter_map(|json| match serde_json::from_str::<Config>(json) {
            Ok(config) => {
                let engine = engine_of(&config);
                if engine.is_none() {
                    tracing::warn!("skipping a DBX connection with no database type");
                }
                engine.map(|engine| (config, engine))
            }
            Err(error) => {
                tracing::warn!(%error, "skipping a DBX connection that does not parse");
                None
            }
        })
        .collect();
    Ok(configs)
}

// DBX's `db_type` ids, from `plugins/connection-types`, with the driver profiles TablePro has an engine
// for. Any other id goes through as the engine's name, which the review reports when no driver opens it.
fn engine_of(config: &Config) -> Option<String> {
    let db_type = config.db_type.trim().to_lowercase();
    if db_type.is_empty() {
        return None;
    }
    let profile = config
        .driver_profile
        .as_deref()
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    let name = match (db_type.as_str(), profile.as_str()) {
        ("mysql", "mariadb") => "MariaDB",
        ("mysql", "tidb") => "TiDB",
        ("mysql", "oceanbase") => "OceanBase",
        ("postgres", "cockroachdb") => "CockroachDB",
        ("postgres", _) => "PostgreSQL",
        ("sqlserver", _) => "SQL Server",
        ("kingbase", _) => "KingbaseES",
        ("saphana", _) => "SAP HANA",
        ("prestosql", _) => "Presto",
        ("cloudflare-d1", _) => "Cloudflare D1",
        _ => return Some(engine::resolve(&db_type)),
    };
    Some(name.to_owned())
}

fn record(config: &Config, engine: String, lookups: &Lookups) -> ForeignConnectionRecord {
    let mut fields = BTreeMap::new();
    let file_field = engine::local_file_path_field(&engine);
    // A file engine keeps its file's path where the host goes.
    let (host, port, database) = match file_field {
        Some(LocalFilePathField::Database) => (String::new(), 0, config.host.clone()),
        Some(LocalFilePathField::AdditionalField(field)) => {
            if !config.host.trim().is_empty() {
                fields.insert(field.to_owned(), config.host.clone());
            }
            (String::new(), 0, String::new())
        }
        None => (
            if config.host.trim().is_empty() {
                "localhost".to_owned()
            } else {
                config.host.clone()
            },
            match config.port {
                0 => engine::default_port(&engine),
                port => port,
            },
            config.database.clone().unwrap_or_default(),
        ),
    };

    let (hops, lost) = config.route(&lookups.profiles);
    let kept_apart = |name: &str| {
        lookups
            .secret_names
            .get(&config.id)
            .is_some_and(|names| names.contains(name))
    };
    let written = |value: &Option<String>| value.as_deref().is_some_and(|value| !value.trim().is_empty());
    let connection_string = written(&config.connection_string) || kept_apart("connection_string");
    let startup = [
        (written(&config.init_script) || kept_apart("init_script"), INIT_SCRIPT),
        (!config.attached_databases.is_empty(), ATTACHED_DATABASES),
        (connection_string, CONNECTION_STRING),
    ];
    let not_kept = lost
        .into_iter()
        .chain(startup.into_iter().filter_map(|(set, key)| set.then_some(key)));
    for key in not_kept {
        fields.insert(key.to_owned(), "true".to_owned());
    }

    // DBX saves driver parameters with the secrets it encrypts, and connects through a connection string
    // in place of the host, so the TLS either one sets cannot be read.
    let tls_unread = file_field.is_none() && (kept_apart("url_params") || connection_string);
    let ssl = ssl_of(config, &engine, tls_unread, &mut fields);
    let settings = ForeignConnection {
        name: if config.name.trim().is_empty() {
            "Untitled".to_owned()
        } else {
            config.name.clone()
        },
        host,
        port,
        database,
        username: config.username.clone(),
        engine,
        ssh: ssh_of(&hops),
        ssl,
        color: color_of(config.color.as_deref()),
        additional_fields: fields,
    };
    ForeignConnectionRecord {
        source_id: Some(config.id.clone()).filter(|id| !id.is_empty()),
        group_path: lookups.groups.get(&config.id).cloned().unwrap_or_default(),
        credentials: None,
        settings,
    }
}

fn ssh_of(hops: &[SshLayer]) -> Option<ForeignSsh> {
    let (target, jumps) = hops.split_last()?;
    let (auth, private_key_path) = sign_in(target);
    let jump_hosts = jumps
        .iter()
        .map(|hop| {
            let (auth, private_key_path) = sign_in(hop);
            ForeignJumpHost {
                host: hop.host.clone(),
                port: Some(hop.port),
                username: hop.user.clone(),
                auth,
                private_key_path,
            }
        })
        .collect();
    Some(ForeignSsh {
        host: target.host.clone(),
        port: Some(target.port),
        username: target.user.clone(),
        auth,
        private_key_path,
        jump_hosts,
    })
}

// `auth_method` names the one way DBX signs in. A connection saved before it tried a key, a password,
// then the agent, by which of them it had.
fn sign_in(hop: &SshLayer) -> (ForeignSshAuth, String) {
    let key = super::resolve_key_path(hop.key_path.trim());
    let auth = match hop.auth_method.trim() {
        "agent" => ForeignSshAuth::Agent,
        "key" | "key+password" => ForeignSshAuth::PrivateKey,
        "password" | "none" => ForeignSshAuth::Password,
        _ if !key.is_empty() => ForeignSshAuth::PrivateKey,
        _ if hop.use_ssh_agent => ForeignSshAuth::Agent,
        _ => ForeignSshAuth::Password,
    };
    match auth {
        ForeignSshAuth::PrivateKey => (auth, key),
        ForeignSshAuth::Agent | ForeignSshAuth::Password => (auth, String::new()),
    }
}

// DBX has no TLS mode field: `ssl` turns TLS on, a CA file has MySQL check the server, and an
// `sslmode` driver parameter can name any mode. The stricter of the two is kept, so no connection
// imports weaker than DBX may open it, and TLS set some other way marks the record for the review.
fn ssl_of(config: &Config, engine: &str, unread: bool, fields: &mut BTreeMap<String, String>) -> Option<ForeignSsl> {
    let params = if unread {
        fields.insert(crate::TLS_SETTINGS_UNREAD.to_owned(), "true".to_owned());
        ""
    } else {
        config
            .url_params
            .as_deref()
            .unwrap_or_default()
            .trim()
            .trim_start_matches('?')
    };
    let url = format!("dbx://host/?{params}");
    let named = jdbc::url_ssl_or_mark(&url, fields).map(|ssl| ssl.mode);
    let file = |path: &str| Some(path.trim().to_owned()).filter(|path| !path.is_empty());
    let ca = file(&config.ca_cert_path);
    let implied = match (config.ssl, ca.is_some()) {
        (true, true) => Some(ForeignSslMode::VerifyCa),
        (true, false) => Some(ForeignSslMode::Required),
        (false, _) => None,
    };
    let mode = match (named, implied) {
        (Some(named), Some(implied)) => stricter(named, implied),
        (Some(mode), None) | (None, Some(mode)) => mode,
        // DBX writes libpq's own default into the URL of a connection that names no mode.
        (None, None) if matches!(engine, "PostgreSQL" | "CockroachDB" | "Redshift") => {
            return jdbc::driver_default_ssl(&url, unread, ForeignSslMode::Preferred, fields);
        }
        (None, None) => return None,
    };
    Some(ForeignSsl {
        mode,
        ca_certificate_path: ca,
        client_certificate_path: file(&config.client_cert_path),
        client_key_path: file(&config.client_key_path),
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

// A swatch, else the clear hue of a custom `#rrggbb`.
fn color_of(raw: Option<&str>) -> Option<ForeignColor> {
    let raw = raw?.trim().to_ascii_lowercase();
    if let Some((_, color)) = SWATCHES.iter().find(|(swatch, _)| *swatch == raw) {
        return Some(*color);
    }
    let digits = raw.strip_prefix('#').filter(|digits| digits.len() == 6)?;
    let channel = |at: usize| {
        digits
            .get(at..at + 2)
            .and_then(|pair| i64::from_str_radix(pair, 16).ok())
    };
    super::rgb_color(channel(0)?, channel(2)?, channel(4)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(json: &str) -> Config {
        serde_json::from_str(json).expect("a config")
    }

    #[test]
    fn every_swatch_and_a_clear_custom_hue_map_to_a_colour() {
        for (swatch, color) in SWATCHES {
            assert_eq!(color_of(Some(swatch)), Some(color));
        }
        assert_eq!(color_of(Some(" #EF4444 ")), Some(ForeignColor::Red));
        assert_eq!(color_of(Some("#1020f0")), Some(ForeignColor::Blue));
        assert_eq!(color_of(Some("#808080")), None);
        assert_eq!(color_of(Some("red")), None);
        assert_eq!(color_of(Some("#fff")), None);
        assert_eq!(color_of(Some("")), None);
        assert_eq!(color_of(None), None);
    }

    #[test]
    fn a_driver_profile_names_the_engine_it_is() {
        let engine = |db_type: &str, profile: &str| {
            engine_of(&config(&format!(
                r#"{{"db_type":"{db_type}","driver_profile":"{profile}"}}"#
            )))
        };

        assert_eq!(engine("mysql", "mariadb").as_deref(), Some("MariaDB"));
        assert_eq!(engine("mysql", "polardb").as_deref(), Some("MySQL"));
        assert_eq!(engine("postgres", "cockroachdb").as_deref(), Some("CockroachDB"));
        assert_eq!(engine("postgres", "").as_deref(), Some("PostgreSQL"));
        assert_eq!(engine("sqlserver", "").as_deref(), Some("SQL Server"));
        assert_eq!(engine("duckdb", "").as_deref(), Some("DuckDB"));
        assert_eq!(engine("hive", "").as_deref(), Some("hive"));
        assert_eq!(engine(" ", "").as_deref(), None);
    }

    #[test]
    fn each_hop_signs_in_the_way_it_names() {
        let hop = |json: &str| sign_in(&serde_json::from_str::<SshLayer>(json).expect("a hop"));

        assert_eq!(
            hop(r#"{"auth_method":"key","key_path":"id_ed25519"}"#),
            (ForeignSshAuth::PrivateKey, "~/.ssh/id_ed25519".to_owned())
        );
        assert_eq!(
            hop(r#"{"auth_method":"agent","key_path":"id_ed25519"}"#),
            (ForeignSshAuth::Agent, String::new())
        );
        assert_eq!(
            hop(r#"{"auth_method":"password","use_ssh_agent":true}"#),
            (ForeignSshAuth::Password, String::new())
        );
        assert_eq!(
            hop(r#"{"key_path":"/keys/id"}"#),
            (ForeignSshAuth::PrivateKey, "/keys/id".to_owned())
        );
        assert_eq!(hop(r#"{"use_ssh_agent":true}"#), (ForeignSshAuth::Agent, String::new()));
        assert_eq!(hop("{}"), (ForeignSshAuth::Password, String::new()));
    }
}
