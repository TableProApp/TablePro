mod encryptor;
mod locations;
mod saved_queries;
mod sqlite;

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

use secrecy::{ExposeSecret, SecretString};
use tokio_util::sync::CancellationToken;

use self::sqlite::{Database, Row};
use crate::app::{AppReader, check_cancel};
use crate::collect::assemble;
use crate::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignConnection, ForeignConnectionRecord,
    ForeignCredentials, ForeignImportError, ForeignJumpHost, ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode,
    ImportRequest, Inventory, PasswordOutcome, engine,
};

const APP: ForeignApp = ForeignApp::BeekeeperStudio;

pub(crate) struct Beekeeper {
    data_dir: PathBuf,
}

impl Beekeeper {
    pub(crate) fn new(data_dir: PathBuf) -> Self {
        Self { data_dir }
    }

    pub(crate) fn locate(dirs: &ForeignAppDirs) -> Self {
        Self::new(locations::data_dir(dirs))
    }

    fn app_db(&self) -> PathBuf {
        self.data_dir.join(locations::APP_DB)
    }

    fn open(&self) -> Result<Database, ForeignImportError> {
        let path = self.app_db();
        if !path.exists() {
            return Err(ForeignImportError::FileNotFound { app: APP });
        }
        Database::open_read_only(&path).ok_or_else(|| ForeignImportError::parse("Could not open app.db"))
    }

    fn user_encryption_key(&self) -> Option<SecretString> {
        let payload = crate::files::read_capped_string(self.data_dir.join(".key")).ok()?;
        encryptor::decrypt_key_file(&payload).map(SecretString::from)
    }
}

impl AppReader for Beekeeper {
    fn has_data(&self) -> bool {
        self.app_db().exists()
    }

    fn inventory(&self) -> Inventory {
        let Ok(db) = self.open() else {
            return Inventory::default();
        };
        Inventory {
            // Only the rows collect imports: one with no connection type is skipped there.
            connections: read_saved_connections(&db).map_or(0, |rows| {
                rows.iter()
                    .filter(|row| map_driver(row.connection_type.as_deref()).is_some())
                    .count()
            }),
            saved_queries: saved_queries::count(&db),
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let db = self.open()?;
        let rows = read_saved_connections(&db)?;
        let folders = read_connection_folders(&db);
        let user_key = if request.include_passwords {
            self.user_encryption_key()
        } else {
            None
        };

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            check_cancel(cancel)?;
            let Some(engine) = map_driver(row.connection_type.as_deref()) else {
                tracing::warn!("skipping a Beekeeper connection with no connection type");
                continue;
            };
            records.push(record(&row, engine, &folders, user_key.as_ref()));
        }

        let saved_queries = if request.include_saved_queries {
            saved_queries::read(&db, request.saved_query_byte_limit, cancel)?
        } else {
            Vec::new()
        };
        let passwords = if request.include_passwords {
            PasswordOutcome::Read
        } else {
            PasswordOutcome::NotRequested
        };
        assemble(APP, records, saved_queries, passwords)
    }
}

fn record(
    row: &SavedConnectionRow,
    engine: String,
    folders: &HashMap<i64, String>,
    user_key: Option<&SecretString>,
) -> ForeignConnectionRecord {
    let port = row
        .port
        .and_then(|port| u16::try_from(port).ok())
        .unwrap_or_else(|| engine::default_port(&engine));
    let ssl = row.ssl.then(|| ssl(row, &engine));
    let settings = ForeignConnection {
        name: if row.name.is_empty() {
            "Untitled".to_owned()
        } else {
            row.name.clone()
        },
        host: if row.host.is_empty() {
            "localhost".to_owned()
        } else {
            row.host.clone()
        },
        port,
        database: row.default_database.clone().unwrap_or_default(),
        username: row.username.clone().unwrap_or_default(),
        engine,
        ssh: row.ssh_enabled.then(|| ssh(row)),
        ssl,
        color: map_color(row.label_color.as_deref()),
        additional_fields: BTreeMap::new(),
    };
    ForeignConnectionRecord {
        source_id: Some(row.id.to_string()),
        group_path: row
            .connection_folder_id
            .and_then(|id| folders.get(&id))
            .map(|name| vec![name.clone()])
            .unwrap_or_default(),
        credentials: user_key.and_then(|key| credentials(row, key.expose_secret())),
        settings,
    }
}

// Beekeeper's `ConnectionType` names, from `apps/studio/src/lib/db/types.ts`.
fn map_driver(raw: Option<&str>) -> Option<String> {
    let raw = raw.filter(|raw| !raw.is_empty())?;
    let mapped = match raw.to_lowercase().as_str() {
        "mysql" => "MySQL",
        "mariadb" => "MariaDB",
        "postgresql" | "postgres" => "PostgreSQL",
        "redshift" => "Redshift",
        "cockroachdb" => "CockroachDB",
        "sqlite" => "SQLite",
        "sqlserver" => "SQL Server",
        "oracle" => "Oracle",
        "mongodb" | "mongo" => "MongoDB",
        "redis" => "Redis",
        "cassandra" => "Cassandra",
        "clickhouse" => "ClickHouse",
        "bigquery" => "BigQuery",
        "duckdb" => "DuckDB",
        "libsql" => "libSQL",
        _ => return Some(engine::resolve(raw)),
    };
    Some(mapped.to_owned())
}

fn ssh(row: &SavedConnectionRow) -> ForeignSsh {
    let bastion = row
        .ssh_bastion_host
        .as_deref()
        .filter(|host| !host.is_empty())
        .map(|host| ForeignJumpHost {
            host: host.to_owned(),
            port: ssh_port(row.ssh_bastion_port),
            username: row.ssh_bastion_username.clone().unwrap_or_default(),
            auth: map_ssh_auth(row.ssh_bastion_mode.as_deref()),
            private_key_path: super::resolve_key_path(row.ssh_bastion_keyfile.as_deref().unwrap_or_default()),
        });
    ForeignSsh {
        host: row.ssh_host.clone().unwrap_or_default(),
        port: ssh_port(row.ssh_port),
        username: row.ssh_username.clone().unwrap_or_default(),
        auth: map_ssh_auth(row.ssh_mode.as_deref()),
        private_key_path: super::resolve_key_path(row.ssh_keyfile.as_deref().unwrap_or_default()),
        jump_hosts: bastion.into_iter().collect(),
    }
}

fn ssh_port(port: Option<i64>) -> Option<u16> {
    port.and_then(|port| u16::try_from(port).ok())
}

fn map_ssh_auth(mode: Option<&str>) -> ForeignSshAuth {
    match mode.map(str::to_lowercase).as_deref() {
        Some("keyfile") => ForeignSshAuth::PrivateKey,
        Some("agent") => ForeignSshAuth::Agent,
        _ => ForeignSshAuth::Password,
    }
}

fn ssl(row: &SavedConnectionRow, engine: &str) -> ForeignSsl {
    ForeignSsl {
        mode: ssl_mode(row, engine),
        ca_certificate_path: row.ssl_ca_file.clone(),
        client_certificate_path: row.ssl_cert_file.clone(),
        client_key_path: row.ssl_key_file.clone(),
    }
}

// What each Beekeeper connector hands its driver (`lib/db/clients/*/*Connector.ts`). The saved
// `trustServerCertificate` is SQL Server's alone, and TLS on replaces it there.
fn ssl_mode(row: &SavedConnectionRow, engine: &str) -> ForeignSslMode {
    let file = |path: &Option<String>| path.as_deref().is_some_and(|path| !path.is_empty());
    let (ca, cert, key) = (
        file(&row.ssl_ca_file),
        file(&row.ssl_cert_file),
        file(&row.ssl_key_file),
    );
    let verifies = match engine {
        "SQL Server" => !(ca && cert && key) || row.ssl_reject_unauthorized,
        // With no certificate file these connectors never check the server.
        "PostgreSQL" | "Redshift" | "CockroachDB" | "MySQL" | "MariaDB" | "TiDB" => {
            row.ssl_reject_unauthorized && (ca || cert || key)
        }
        _ => row.ssl_reject_unauthorized,
    };
    if verifies {
        ForeignSslMode::VerifyIdentity
    } else {
        ForeignSslMode::Required
    }
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

fn credentials(row: &SavedConnectionRow, key: &str) -> Option<ForeignCredentials> {
    let decrypt = |value: &Option<String>| {
        value
            .as_deref()
            .filter(|value| !value.is_empty())
            .and_then(|value| encryptor::decrypt_string(value, key))
            .map(SecretString::from)
    };
    ForeignCredentials {
        password: decrypt(&row.password),
        ssh_password: decrypt(&row.ssh_password),
        key_passphrase: decrypt(&row.ssh_keyfile_password),
    }
    .non_empty()
}

struct SavedConnectionRow {
    id: i64,
    name: String,
    connection_type: Option<String>,
    host: String,
    port: Option<i64>,
    username: Option<String>,
    default_database: Option<String>,
    password: Option<String>,
    ssl: bool,
    ssl_ca_file: Option<String>,
    ssl_cert_file: Option<String>,
    ssl_key_file: Option<String>,
    ssl_reject_unauthorized: bool,
    ssh_enabled: bool,
    ssh_host: Option<String>,
    ssh_port: Option<i64>,
    ssh_username: Option<String>,
    ssh_mode: Option<String>,
    ssh_keyfile: Option<String>,
    ssh_keyfile_password: Option<String>,
    ssh_password: Option<String>,
    ssh_bastion_host: Option<String>,
    ssh_bastion_port: Option<i64>,
    ssh_bastion_username: Option<String>,
    ssh_bastion_mode: Option<String>,
    ssh_bastion_keyfile: Option<String>,
    label_color: Option<String>,
    connection_folder_id: Option<i64>,
}

// A cloud workspace's rows have a positive workspaceId and belong to that workspace's server copy.
const SAVED_CONNECTIONS_SQL: &str = "
    SELECT id, name, connectionType, host, port, username, defaultDatabase, password,
           ssl, sslCaFile, sslCertFile, sslKeyFile, sslRejectUnauthorized,
           sshEnabled, sshHost, sshPort, sshUsername, sshMode, sshKeyfile, sshKeyfilePassword, sshPassword,
           sshBastionHost, sshBastionHostPort, sshBastionUsername, sshBastionMode, sshBastionKeyfile,
           labelColor, connectionFolderId
    FROM saved_connection
    WHERE workspaceId = -1
    ORDER BY id";

fn read_saved_connections(db: &Database) -> Result<Vec<SavedConnectionRow>, ForeignImportError> {
    let mut statement = db
        .prepare(SAVED_CONNECTIONS_SQL)
        .ok_or_else(|| ForeignImportError::unsupported("saved_connection schema mismatch"))?;
    let mut rows = Vec::new();
    while let Some(row) = statement.next_row() {
        rows.push(saved_connection(&row));
    }
    Ok(rows)
}

fn saved_connection(row: &Row<'_>) -> SavedConnectionRow {
    let flag = |column| row.int64(column) != 0;
    SavedConnectionRow {
        id: row.int64(0),
        name: row.text(1).unwrap_or_default(),
        connection_type: row.text(2),
        host: row.text(3).unwrap_or_default(),
        port: row.optional_int64(4),
        username: row.text(5),
        default_database: row.text(6),
        password: row.text(7),
        ssl: flag(8),
        ssl_ca_file: row.text(9),
        ssl_cert_file: row.text(10),
        ssl_key_file: row.text(11),
        ssl_reject_unauthorized: flag(12),
        ssh_enabled: flag(13),
        ssh_host: row.text(14),
        ssh_port: row.optional_int64(15),
        ssh_username: row.text(16),
        ssh_mode: row.text(17),
        ssh_keyfile: row.text(18),
        ssh_keyfile_password: row.text(19),
        ssh_password: row.text(20),
        ssh_bastion_host: row.text(21),
        ssh_bastion_port: row.optional_int64(22),
        ssh_bastion_username: row.text(23),
        ssh_bastion_mode: row.text(24),
        ssh_bastion_keyfile: row.text(25),
        label_color: row.text(26),
        connection_folder_id: row.optional_int64(27),
    }
}

fn read_connection_folders(db: &Database) -> HashMap<i64, String> {
    let Some(mut statement) = db.prepare("SELECT id, name FROM connection_folder") else {
        return HashMap::new();
    };
    let mut folders = HashMap::new();
    while let Some(row) = statement.next_row() {
        if let Some(name) = row.text(1).filter(|name| !name.is_empty()) {
            folders.insert(row.int64(0), name);
        }
    }
    folders
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_names_map_to_the_macos_engine_names() {
        let cases = [
            ("mysql", "MySQL"),
            ("MariaDB", "MariaDB"),
            ("postgres", "PostgreSQL"),
            ("postgresql", "PostgreSQL"),
            ("redshift", "Redshift"),
            ("cockroachdb", "CockroachDB"),
            ("sqlite", "SQLite"),
            ("sqlserver", "SQL Server"),
            ("oracle", "Oracle"),
            ("mongo", "MongoDB"),
            ("redis", "Redis"),
            ("cassandra", "Cassandra"),
            ("clickhouse", "ClickHouse"),
            ("bigquery", "BigQuery"),
            ("duckdb", "DuckDB"),
            ("libsql", "libSQL"),
        ];
        for (raw, engine) in cases {
            assert_eq!(map_driver(Some(raw)).as_deref(), Some(engine), "{raw}");
        }
        assert_eq!(map_driver(Some("SCYLLADB")).as_deref(), Some("ScyllaDB"));
        assert_eq!(map_driver(Some("acmedb")).as_deref(), Some("acmedb"));
        assert_eq!(map_driver(Some("")), None);
        assert_eq!(map_driver(None), None);
    }

    #[test]
    fn ssh_modes_and_label_colors_map_in_any_case() {
        assert_eq!(map_ssh_auth(Some("Keyfile")), ForeignSshAuth::PrivateKey);
        assert_eq!(map_ssh_auth(Some("agent")), ForeignSshAuth::Agent);
        assert_eq!(map_ssh_auth(Some("userpass")), ForeignSshAuth::Password);
        assert_eq!(map_ssh_auth(None), ForeignSshAuth::Password);
        assert_eq!(map_color(Some("GREY")), Some(ForeignColor::Gray));
        assert_eq!(map_color(Some("default")), None);
        assert_eq!(map_color(None), None);
    }
}
