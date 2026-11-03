mod credentials;
mod locations;
mod scripts;

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::Value;
use tokio_util::sync::CancellationToken;

use self::credentials::Credentials;
use self::locations::{ConfigFile, Project};
use crate::app::{AppReader, check_cancel};
use crate::apps::{jdbc, resolve_key_path};
use crate::collect::{PasswordOutcome, assemble};
use crate::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignConnection, ForeignConnectionRecord,
    ForeignCredentials, ForeignImportError, ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode, ImportRequest,
    Inventory, engine,
};

pub(crate) struct DBeaver {
    data_roots: Vec<PathBuf>,
}

impl DBeaver {
    pub(crate) fn new(data_roots: Vec<PathBuf>) -> Self {
        Self { data_roots }
    }

    pub(crate) fn locate(dirs: &ForeignAppDirs) -> Self {
        Self::new(locations::data_roots(dirs))
    }

    fn project(&self) -> Option<Project> {
        locations::find_project(&self.data_roots)
    }
}

impl AppReader for DBeaver {
    fn has_data(&self) -> bool {
        self.project().is_some()
    }

    fn inventory(&self) -> Inventory {
        let Some(project) = self.project() else {
            return Inventory::default();
        };
        Inventory {
            connections: project.configs.iter().map(connection_count).sum(),
            saved_queries: scripts::count(&project.path),
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let project = self.project().ok_or(ForeignImportError::FileNotFound {
            app: ForeignApp::DBeaver,
        })?;
        let sources = read_data_sources(&project)?;
        let folders = folder_descriptions(&sources);

        let mut records = Vec::new();
        for source in &sources {
            for (id, connection) in &source.connections {
                check_cancel(cancel)?;
                let settings = settings(id, connection, source.credentials.username(id));
                let credentials = request
                    .include_passwords
                    .then(|| source.credentials.secrets(id))
                    .flatten()
                    .map(|credentials| tunnel_secret_by_auth(credentials, &settings));
                records.push(ForeignConnectionRecord {
                    source_id: Some(id.clone()),
                    settings,
                    group_path: group_path(connection.get("folder").and_then(Value::as_str), &folders),
                    credentials,
                });
            }
        }
        // JSON objects have no order once parsed, so the review list is sorted.
        records.sort_by(|left, right| sort_key(left).cmp(&sort_key(right)));

        let saved_queries = if request.include_saved_queries {
            scripts::saved_queries(&project.path, request.saved_query_byte_limit, cancel)?
        } else {
            Vec::new()
        };
        let passwords = if request.include_passwords {
            PasswordOutcome::Read
        } else {
            PasswordOutcome::NotRequested
        };
        assemble(ForeignApp::DBeaver, records, saved_queries, passwords)
    }
}

fn sort_key(record: &ForeignConnectionRecord) -> (&str, &str) {
    (record.settings.name.as_str(), record.source_id.as_deref().unwrap_or(""))
}

struct DataSources {
    connections: BTreeMap<String, Value>,
    folders: BTreeMap<String, Value>,
    credentials: Credentials,
}

fn read_data_sources(project: &Project) -> Result<Vec<DataSources>, ForeignImportError> {
    let mut sources = Vec::with_capacity(project.configs.len());
    for config in &project.configs {
        match read_config(config) {
            Ok(source) => sources.push(source),
            // A broken extra file leaves the main file's connections importable.
            Err(error) if !config.is_default => {
                tracing::warn!(code = error.code(), file = %config.name, "skipped a DBeaver data sources file");
            }
            Err(error) => return Err(error),
        }
    }
    Ok(sources)
}

fn read_config(config: &ConfigFile) -> Result<DataSources, ForeignImportError> {
    let mut json = crate::files::read_capped(&config.path)
        .ok()
        .and_then(|data| json_object(&data))
        .ok_or_else(|| ForeignImportError::parse(format!("Could not parse {}", config.name)))?;
    let connections = json
        .remove("connections")
        .and_then(objects)
        .ok_or_else(|| ForeignImportError::unsupported(format!("Missing connections key in {}", config.name)))?;
    let folders = json.remove("folders").and_then(objects).unwrap_or_default();
    Ok(DataSources {
        connections,
        folders,
        credentials: Credentials::load(&config.credentials_path),
    })
}

fn connection_count(config: &ConfigFile) -> usize {
    crate::files::read_capped(&config.path)
        .ok()
        .and_then(|data| json_object(&data))
        .and_then(|mut json| json.remove("connections"))
        .and_then(object)
        .map_or(0, |connections| connections.len())
}

fn json_object(data: &[u8]) -> Option<BTreeMap<String, Value>> {
    let data = data.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(data);
    serde_json::from_slice(data).ok()
}

fn object(value: Value) -> Option<BTreeMap<String, Value>> {
    serde_json::from_value(value).ok()
}

// As the macOS app casts it: one entry that is not an object voids the whole map.
fn objects(value: Value) -> Option<BTreeMap<String, Value>> {
    object(value).filter(|entries| entries.values().all(Value::is_object))
}

// A folder defined in one file can hold connections of another, as DBeaver keeps one folder tree.
fn folder_descriptions(sources: &[DataSources]) -> BTreeMap<String, String> {
    let mut descriptions = BTreeMap::new();
    for source in sources {
        for (path, folder) in &source.folders {
            if let Some(description) = folder.get("description").and_then(Value::as_str)
                && !description.is_empty()
            {
                descriptions
                    .entry(path.clone())
                    .or_insert_with(|| description.to_owned());
            }
        }
    }
    descriptions
}

// A folder key is its full path; a folder's description, when set, is the name DBeaver shows.
fn group_path(folder: Option<&str>, descriptions: &BTreeMap<String, String>) -> Vec<String> {
    let Some(folder) = folder else {
        return Vec::new();
    };
    let components: Vec<&str> = folder.split('/').filter(|component| !component.is_empty()).collect();
    (0..components.len())
        .map(|index| {
            let key = components[..=index].join("/");
            match descriptions.get(&key) {
                Some(description) if !description.is_empty() => description.clone(),
                _ => components[index].to_owned(),
            }
        })
        .collect()
}

static NOTHING: Value = Value::Null;

// The tunnel keeps one secret: the password for password sign-in, the key's passphrase for a key.
// The macOS port always took it as a password, which a key tunnel then dropped.
fn tunnel_secret_by_auth(mut credentials: ForeignCredentials, settings: &ForeignConnection) -> ForeignCredentials {
    let key_tunnel = settings
        .ssh
        .as_ref()
        .is_some_and(|ssh| ssh.auth == ForeignSshAuth::PrivateKey);
    if key_tunnel && credentials.key_passphrase.is_none() {
        credentials.key_passphrase = credentials.ssh_password.take();
    }
    credentials
}

fn settings(id: &str, connection: &Value, credential_username: Option<&str>) -> ForeignConnection {
    let name = connection.get("name").and_then(Value::as_str).unwrap_or(id).to_owned();
    let engine = map_provider(connection.get("provider").and_then(Value::as_str).unwrap_or(""));
    let config = connection.get("configuration").unwrap_or(&NOTHING);
    let text = |key: &str| config.get(key).and_then(Value::as_str);
    // A connection given as a URL keeps only what the URL names, never the URL itself, which can
    // hold a password. The macOS port stored the whole URL as the database name.
    let endpoint = text("url")
        .filter(|_| text("host").is_none_or(str::is_empty))
        .and_then(|url| jdbc::parse(url, &jdbc::subprotocol(url)));
    let host = text("host")
        .filter(|host| !host.is_empty())
        .map(str::to_owned)
        .or_else(|| endpoint.as_ref().map(|endpoint| endpoint.host.clone()))
        .unwrap_or_else(|| "localhost".to_owned());
    let database = text("database")
        .map(str::to_owned)
        .or_else(|| endpoint.as_ref().map(|endpoint| endpoint.database.clone()))
        .unwrap_or_default();
    let username = [
        credential_username,
        text("user"),
        endpoint.as_ref().and_then(|endpoint| endpoint.username.as_deref()),
    ]
    .into_iter()
    .flatten()
    .find(|username| !username.is_empty())
    .unwrap_or("");
    // Read whether or not the host came from the URL: a seed list and an auth database live only there.
    let mut additional_fields = text("url").map(jdbc::url_fields).unwrap_or_default();
    // A URL-only connection keeps the TLS its URL asks for, which the macOS port dropped.
    let ssl = match ssl(config) {
        Some(ssl) => Some(ssl),
        None => text("url").and_then(|url| jdbc::url_ssl_or_mark(url, &mut additional_fields)),
    };
    ForeignConnection {
        name,
        host,
        port: port(config.get("port"))
            .or_else(|| endpoint.as_ref().and_then(|endpoint| endpoint.port))
            .unwrap_or_else(|| engine::default_port(&engine)),
        database,
        username: username.to_owned(),
        ssh: ssh(config),
        ssl,
        color: color(config),
        additional_fields,
        engine,
    }
}

fn map_provider(provider: &str) -> String {
    let known = match provider.to_lowercase().as_str() {
        "mysql" => "MySQL",
        "postgresql" => "PostgreSQL",
        "sqlite" => "SQLite",
        "sqlserver" => "SQL Server",
        "oracle" => "Oracle",
        "mongo" | "mongodb" => "MongoDB",
        "redis" => "Redis",
        "clickhouse" => "ClickHouse",
        "mariadb" => "MariaDB",
        "cassandra" => "Cassandra",
        _ => return engine::resolve(provider),
    };
    known.to_owned()
}

fn ssh(config: &Value) -> Option<ForeignSsh> {
    let tunnel = config
        .get("handlers")?
        .get("ssh_tunnel")
        .filter(|tunnel| tunnel.is_object())?;
    let properties = tunnel.get("properties").filter(|properties| properties.is_object());
    let property = |key: &str| properties.and_then(|properties| properties.get(key));
    let text = |key: &str| property(key).and_then(Value::as_str);

    let enabled = tunnel
        .get("enabled")
        .and_then(boolean)
        .unwrap_or_else(|| property("host").is_some());
    if !enabled {
        return None;
    }
    let auth_type = text("authType").unwrap_or("PASSWORD");
    let auth = match auth_type {
        "PUBLIC_KEY" => ForeignSshAuth::PrivateKey,
        "AGENT" => ForeignSshAuth::Agent,
        _ => ForeignSshAuth::Password,
    };
    let private_key_path = if auth == ForeignSshAuth::PrivateKey {
        resolve_key_path(text("keyPath").unwrap_or(""))
    } else {
        String::new()
    };
    Some(ForeignSsh {
        host: text("host").unwrap_or("").to_owned(),
        port: port(property("port")),
        username: text("username").unwrap_or("").to_owned(),
        auth,
        private_key_path,
        jump_hosts: Vec::new(),
    })
}

fn ssl(config: &Value) -> Option<ForeignSsl> {
    let handler = config
        .get("handlers")?
        .get("ssl")
        .filter(|handler| handler.is_object())?;
    if !handler.get("enabled").and_then(boolean).unwrap_or(false) {
        return None;
    }
    let text = |key: &str| {
        handler
            .get("properties")
            .and_then(|properties| properties.get(key))
            .and_then(Value::as_str)
    };
    let mode = match text("sslMode").unwrap_or("") {
        "require" => ForeignSslMode::Required,
        "verify-ca" => ForeignSslMode::VerifyCa,
        "verify-full" => ForeignSslMode::VerifyIdentity,
        _ => ForeignSslMode::Preferred,
    };
    Some(ForeignSsl {
        mode,
        ca_certificate_path: text("caCertPath").map(str::to_owned),
        client_certificate_path: text("clientCertPath").map(str::to_owned),
        client_key_path: text("clientKeyPath").map(str::to_owned),
    })
}

// DBeaver keeps any colour the user picks as `r,g,b`; only the clear hues map to a TablePro colour.
fn color(config: &Value) -> Option<ForeignColor> {
    let text = config.get("color")?.as_str().filter(|text| !text.is_empty())?;
    let components: Vec<i64> = text
        .split(',')
        .filter_map(|component| component.trim_matches([' ', '\t']).parse().ok())
        .collect();
    let [r, g, b, ..] = components[..] else {
        return None;
    };
    if r > 200 && g < 100 && b < 100 {
        Some(ForeignColor::Red)
    } else if r > 200 && g > 100 && g < 200 && b < 100 {
        Some(ForeignColor::Orange)
    } else if r > 200 && g > 200 && b < 100 {
        Some(ForeignColor::Yellow)
    } else if r < 100 && g > 150 && b < 100 {
        Some(ForeignColor::Green)
    } else if r < 100 && g < 100 && b > 200 {
        Some(ForeignColor::Blue)
    } else if r > 100 && g < 100 && b > 150 {
        Some(ForeignColor::Purple)
    } else {
        None
    }
}

// A port is a number or a numeric string; one outside 0...65535 counts as missing.
fn port(value: Option<&Value>) -> Option<u16> {
    let value = value?;
    let number = integer(value).or_else(|| value.as_str().and_then(|text| text.parse::<i64>().ok()))?;
    u16::try_from(number).ok()
}

fn integer(value: &Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return Some(number);
    }
    let number = value.as_f64()?;
    let whole = number.trunc();
    // A whole float such as `5432.0` reads as an integer, as it does for the macOS app.
    (whole == number && whole.abs() <= 9_007_199_254_740_992.0).then_some(whole as i64)
}

// The macOS app reads a JSON 0 or 1 as a flag too.
fn boolean(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(flag) => Some(*flag),
        Value::Number(_) => match integer(value) {
            Some(0) => Some(false),
            Some(1) => Some(true),
            _ => None,
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;

    use super::*;

    #[test]
    fn a_url_with_a_password_in_it_leaves_only_its_server_and_database() {
        let connection = parsed(
            r#"{"provider": "postgresql", "name": "cloud",
                "configuration": {"url": "jdbc:postgresql://admin:hunter2@db.cloud.example:6543/app?password=hunter2&sslmode=require"}}"#,
        );
        let settings = settings("cloud-id", &connection, None);
        assert_eq!(
            (settings.host.as_str(), settings.port, settings.database.as_str()),
            ("db.cloud.example", 6543, "app")
        );
        assert!(!format!("{settings:?}").contains("hunter2"));
        assert_eq!(settings.username, "admin");
        assert_eq!(settings.ssl.map(|ssl| ssl.mode), Some(ForeignSslMode::Required));
        assert_eq!(settings.additional_fields.get(crate::TLS_SETTINGS_UNREAD), None);
    }

    #[test]
    fn a_mongo_seed_list_url_keeps_its_seed_list_and_its_tls() {
        let connection = parsed(
            r#"{"provider": "mongodb", "name": "atlas",
                "configuration": {"url": "mongodb+srv://cluster0.example.net/app"}}"#,
        );
        let settings = settings("atlas-id", &connection, None);
        assert_eq!(settings.host, "cluster0.example.net");
        assert_eq!(
            settings.additional_fields.get("mongoUseSrv").map(String::as_str),
            Some("true")
        );
        assert_eq!(settings.ssl.map(|ssl| ssl.mode), Some(ForeignSslMode::VerifyIdentity));
    }

    #[test]
    fn a_mongo_url_beside_a_saved_host_still_gives_its_auth_database() {
        let connection = parsed(
            r#"{"provider": "mongodb", "name": "mongo",
                "configuration": {"host": "mongo.example.com", "port": "27017", "database": "shop",
                                  "url": "mongodb://mongo.example.com:27017/shop?authSource=admin"}}"#,
        );
        let settings = settings("mongo-id", &connection, None);
        assert_eq!(settings.host, "mongo.example.com");
        assert_eq!(
            settings.additional_fields.get("mongoAuthSource").map(String::as_str),
            Some("admin")
        );
    }

    #[test]
    fn a_key_tunnels_secret_is_the_keys_passphrase() {
        use secrecy::{ExposeSecret, SecretString};

        let connection = parsed(
            r#"{"provider": "postgresql", "name": "tunnelled",
                "configuration": {"host": "db", "handlers": {"ssh_tunnel": {"enabled": true,
                  "properties": {"host": "bastion", "authType": "PUBLIC_KEY", "keyPath": "~/.ssh/id"}}}}}"#,
        );
        let settings = settings("tunnelled-id", &connection, None);
        let credentials = ForeignCredentials {
            ssh_password: Some(SecretString::from("phrase")),
            ..ForeignCredentials::default()
        };
        let routed = tunnel_secret_by_auth(credentials, &settings);
        assert!(routed.ssh_password.is_none());
        assert_eq!(
            routed.key_passphrase.as_ref().map(ExposeSecret::expose_secret),
            Some("phrase")
        );
    }

    #[test]
    fn a_url_that_asks_to_verify_the_server_keeps_it() {
        let connection = parsed(
            r#"{"provider": "postgresql", "name": "verified",
                "configuration": {"url": "jdbc:postgresql://db.example.com/app?sslmode=verify-full"}}"#,
        );
        let settings = settings("verified-id", &connection, None);
        assert_eq!(settings.ssl.map(|ssl| ssl.mode), Some(ForeignSslMode::VerifyIdentity));
    }

    fn parsed(text: &str) -> Value {
        serde_json::from_str(text).expect("JSON")
    }

    #[test]
    fn a_port_is_a_number_a_whole_float_or_a_numeric_string_in_range() {
        assert_eq!(port(Some(&json!(5433))), Some(5433));
        assert_eq!(port(Some(&json!("5433"))), Some(5433));
        assert_eq!(port(Some(&json!(5433.0))), Some(5433));
        assert_eq!(port(Some(&json!(5433.5))), None);
        assert_eq!(port(Some(&json!(" 5433"))), None);
        assert_eq!(port(Some(&json!(70_000))), None);
        assert_eq!(port(Some(&json!(-1))), None);
        assert_eq!(port(Some(&json!(true))), None);
        assert_eq!(port(None), None);
    }

    #[test]
    fn a_flag_is_a_boolean_or_zero_or_one() {
        assert_eq!(boolean(&json!(true)), Some(true));
        assert_eq!(boolean(&json!(1)), Some(true));
        assert_eq!(boolean(&json!(0)), Some(false));
        assert_eq!(boolean(&json!(2)), None);
        assert_eq!(boolean(&json!("true")), None);
    }

    #[test]
    fn a_folder_path_takes_each_level_s_description_or_its_own_name() {
        let descriptions = BTreeMap::from([
            ("team".to_owned(), "Team".to_owned()),
            ("team/backend/db".to_owned(), String::new()),
        ]);
        assert_eq!(
            group_path(Some("team/backend/db"), &descriptions),
            ["Team", "backend", "db"]
        );
        assert_eq!(group_path(Some("/team//x/"), &descriptions), ["Team", "x"]);
        assert!(group_path(Some(""), &descriptions).is_empty());
        assert!(group_path(None, &descriptions).is_empty());
    }

    #[test]
    fn a_colour_needs_three_numbers_and_skips_the_rest() {
        let colour = |text: &str| color(&parsed(&format!(r#"{{"color": "{text}"}}"#)));
        assert_eq!(colour("255,0,0"), Some(ForeignColor::Red));
        assert_eq!(colour("x,255,0,0"), Some(ForeignColor::Red));
        assert_eq!(colour("255,0"), None);
        assert_eq!(colour(""), None);
        assert_eq!(color(&parsed(r#"{"color": 255}"#)), None);
    }

    #[test]
    fn a_connections_value_with_a_non_object_entry_is_unsupported() {
        let directory = tempfile::tempdir().expect("a temp dir");
        let path = directory.path().join("data-sources.json");
        fs::write(&path, r#"{"connections": {"a": {}, "b": "text"}}"#).expect("a file");
        let config = ConfigFile {
            name: "data-sources.json".to_owned(),
            path,
            credentials_path: directory.path().join("credentials-config.json"),
            is_default: true,
        };
        assert!(matches!(
            read_config(&config),
            Err(ForeignImportError::UnsupportedFormat { .. })
        ));
        assert_eq!(connection_count(&config), 2);
    }
}
