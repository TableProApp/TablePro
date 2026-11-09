#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::ffi::CString;
use std::fs;
use std::path::Path;
use std::ptr;
use std::sync::Arc;

use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignConnection,
    ForeignImportError, ForeignImporter, ForeignPlatform, ForeignSshAuth, ForeignSslMode, ImportRequest, Inventory,
    PasswordOutcome, PasswordSource, PlainHost, SavedQueryContent, SavedQuerySupport, TLS_SETTINGS_UNREAD,
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

const CONNECTIONS_ONLY: ImportRequest = ImportRequest {
    include_passwords: false,
    include_saved_queries: false,
    saved_query_byte_limit: 900_000,
};
const WITH_PASSWORDS: ImportRequest = ImportRequest {
    include_passwords: true,
    ..CONNECTIONS_ONLY
};
const WITH_SAVED_QUERIES: ImportRequest = ImportRequest {
    include_saved_queries: true,
    ..CONNECTIONS_ONLY
};

struct Home {
    _dir: TempDir,
    importer: ForeignImporter,
}

impl Home {
    fn with_store(platform: ForeignPlatform, sql: &str) -> Self {
        let dir = tempfile::tempdir().expect("a home");
        let dirs = ForeignAppDirs::conventional(platform, dir.path());
        // Tauri's app data directory for the bundle identifier `com.dbx.app`.
        let folder = match platform {
            ForeignPlatform::Windows => dirs.config.join("com.dbx.app"),
            ForeignPlatform::Linux | ForeignPlatform::MacOs => dirs.data.join("com.dbx.app"),
        };
        fs::create_dir_all(&folder).expect("the data folder");
        execute(&folder.join("dbx.db"), sql);
        Self {
            _dir: dir,
            importer: ForeignImporter::new(ForeignApp::Dbx, dirs, Arc::new(PlainHost)),
        }
    }

    fn fixture() -> Self {
        Self::with_store(ForeignPlatform::Linux, &fixture())
    }

    fn collect(&self, request: &ImportRequest) -> CollectedImport {
        self.importer
            .collect_blocking(request, &CancellationToken::new())
            .expect("an import")
    }
}

fn fixture() -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/dbx/dbx.sql");
    fs::read_to_string(path).expect("the fixture")
}

fn execute(path: &Path, sql: &str) {
    let path = CString::new(path.to_str().expect("a UTF-8 path")).expect("a path");
    let sql = CString::new(sql).expect("SQL");
    let flags = libsqlite3_sys::SQLITE_OPEN_READWRITE | libsqlite3_sys::SQLITE_OPEN_CREATE;
    let mut db = ptr::null_mut();
    // SAFETY: both strings are NUL-terminated and outlive the calls, the handle is closed once, and the exec
    // passes no callback.
    let (opened, executed) = unsafe {
        let opened = libsqlite3_sys::sqlite3_open_v2(path.as_ptr(), &mut db, flags, ptr::null());
        let executed = libsqlite3_sys::sqlite3_exec(db, sql.as_ptr(), None, ptr::null_mut(), ptr::null_mut());
        libsqlite3_sys::sqlite3_close(db);
        (opened, executed)
    };
    assert_eq!(
        (opened, executed),
        (libsqlite3_sys::SQLITE_OK, libsqlite3_sys::SQLITE_OK)
    );
}

fn connection<'a>(collected: &'a CollectedImport, reference: &str) -> &'a CollectedConnection {
    collected
        .connections
        .iter()
        .find(|connection| connection.reference == reference)
        .expect("the connection")
}

fn settings<'a>(collected: &'a CollectedImport, reference: &str) -> &'a ForeignConnection {
    &connection(collected, reference).settings
}

fn not_kept(settings: &ForeignConnection) -> Vec<&str> {
    settings.additional_fields.keys().map(String::as_str).collect()
}

#[test]
fn a_connection_imports_with_its_tunnel_chain_certificates_colour_and_group() {
    let home = Home::fixture();

    let collected = home.collect(&CONNECTIONS_ONLY);

    assert_eq!(collected.app, ForeignApp::Dbx);
    let orders = connection(&collected, "c-pg");
    assert_eq!(orders.group_path, ["Production", "EU"]);
    assert!(orders.credentials.is_none());
    let settings = &orders.settings;
    assert_eq!(
        (
            settings.name.as_str(),
            settings.engine.as_str(),
            settings.host.as_str(),
            settings.port,
            settings.username.as_str(),
            settings.database.as_str()
        ),
        ("Orders", "PostgreSQL", "db.example.com", 5433, "ada", "orders")
    );
    assert_eq!(settings.color, Some(ForeignColor::Red));
    assert!(settings.additional_fields.is_empty());

    let ssh = settings.ssh.as_ref().expect("the tunnel");
    assert_eq!(
        (ssh.host.as_str(), ssh.port, ssh.username.as_str(), ssh.auth),
        ("bastion.internal", Some(2200), "ops", ForeignSshAuth::Agent),
        "the last hop takes its settings from the tunnel profile it names"
    );
    assert_eq!(ssh.jump_hosts.len(), 1, "the first hop goes first");
    let edge = &ssh.jump_hosts[0];
    assert_eq!(
        (edge.host.as_str(), edge.port, edge.username.as_str(), edge.auth),
        ("edge.example.com", Some(22), "jump", ForeignSshAuth::PrivateKey)
    );
    assert_eq!(edge.private_key_path, "~/.ssh/id_ed25519");

    let ssl = settings.ssl.as_ref().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::VerifyIdentity);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/certs/ca.pem"));
    assert_eq!(ssl.client_certificate_path.as_deref(), Some("/certs/client.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/certs/client.key"));
}

#[test]
fn rows_import_in_order_and_one_dbx_cannot_read_is_left_out() {
    let home = Home::fixture();

    let collected = home.collect(&CONNECTIONS_ONLY);

    let references: Vec<&str> = collected
        .connections
        .iter()
        .map(|connection| connection.reference.as_str())
        .collect();
    assert_eq!(
        references,
        [
            "c-pg", "c-maria", "c-sqlite", "c-duck", "c-legacy", "c-mongo", "c-gone", "c-cache", "c-hive"
        ]
    );
    assert_eq!(
        home.importer.inventory_blocking(),
        Inventory {
            connections: 9,
            saved_queries: 4
        }
    );
    assert_eq!(settings(&collected, "c-hive").engine, "hive");
}

#[test]
fn a_driver_profile_an_empty_host_and_a_zero_port_take_the_engines_defaults() {
    let home = Home::fixture();

    let collected = home.collect(&CONNECTIONS_ONLY);

    let shop = connection(&collected, "c-maria");
    assert_eq!(shop.group_path, ["Production"]);
    assert_eq!(
        (
            shop.settings.engine.as_str(),
            shop.settings.host.as_str(),
            shop.settings.port
        ),
        ("MariaDB", "localhost", 3306)
    );
    assert_eq!(shop.settings.color, Some(ForeignColor::Blue));
    assert!(shop.settings.ssl.is_none());
    assert_eq!(connection(&collected, "c-cache").group_path, ["Caches"]);
    assert_eq!(settings(&collected, "c-cache").color, Some(ForeignColor::Purple));
}

#[test]
fn a_file_database_keeps_its_path_where_the_engine_reads_it() {
    let home = Home::fixture();

    let collected = home.collect(&CONNECTIONS_ONLY);

    let local = settings(&collected, "c-sqlite");
    assert_eq!(
        (
            local.engine.as_str(),
            local.host.as_str(),
            local.database.as_str(),
            local.port
        ),
        ("SQLite", "", "~/data/app.db", 0)
    );
    let analytics = settings(&collected, "c-duck");
    assert_eq!(analytics.engine, "DuckDB");
    assert_eq!(
        analytics.additional_fields.get("duckdbFilePath").map(String::as_str),
        Some("/data/warehouse.duckdb")
    );
}

#[test]
fn a_connection_saved_before_transport_layers_keeps_its_tunnel() {
    let home = Home::fixture();

    let collected = home.collect(&WITH_PASSWORDS);

    let legacy = connection(&collected, "c-legacy");
    let ssh = legacy.settings.ssh.as_ref().expect("the tunnel");
    assert_eq!(
        (ssh.host.as_str(), ssh.port, ssh.username.as_str(), ssh.auth),
        ("bastion.example.com", Some(2222), "jump", ForeignSshAuth::PrivateKey)
    );
    assert_eq!(ssh.private_key_path, "~/.ssh/id_rsa");
    assert!(ssh.jump_hosts.is_empty());
    assert!(
        legacy.credentials.is_none(),
        "a password an older DBX left in the JSON is not read"
    );
}

#[test]
fn what_runs_sql_or_a_command_or_routes_elsewhere_is_named_and_never_carried() {
    let home = Home::fixture();

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(not_kept(settings(&collected, "c-maria")), ["proxy"]);
    assert_eq!(not_kept(settings(&collected, "c-sqlite")), ["attachedDatabases"]);
    assert_eq!(
        not_kept(settings(&collected, "c-duck")),
        ["duckdbFilePath", "initScript"]
    );
    assert_eq!(not_kept(settings(&collected, "c-mongo")), ["connectionString"]);
    assert_eq!(not_kept(settings(&collected, "c-cache")), ["sshProxyCommand"]);
    let gone = settings(&collected, "c-gone");
    assert_eq!(not_kept(gone), ["sshTunnel"]);
    assert!(gone.ssh.is_none());
    let cache = settings(&collected, "c-cache").ssh.as_ref().expect("the tunnel");
    assert_eq!(
        (cache.host.as_str(), cache.auth),
        ("bastion.example.com", ForeignSshAuth::Agent)
    );

    let everything = format!("{collected:?}");
    for value in [
        "INSTALL httpfs",
        "cloudflared",
        "socks.example.com",
        "/data/logs.db",
        "inline-legacy-secret",
        "inline-ssh-secret",
        "dbxenc1",
    ] {
        assert!(!everything.contains(value), "{value} was carried into the import");
    }
}

#[test]
fn passwords_stay_in_the_keyring_dbx_encrypts_them_under() {
    let home = Home::fixture();

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
    assert_eq!(home.collect(&CONNECTIONS_ONLY).passwords, PasswordOutcome::NotRequested);
    assert_eq!(ForeignApp::Dbx.password_source(), PasswordSource::Keychain);
}

#[test]
fn saved_sql_lands_with_its_connection_and_the_default_query_starts_unchecked() {
    let home = Home::fixture();
    assert_eq!(ForeignApp::Dbx.saved_query_support(), SavedQuerySupport::Scripts);
    assert!(home.collect(&CONNECTIONS_ONLY).saved_queries.is_empty());

    let collected = home.collect(&WITH_SAVED_QUERIES);

    let queries: Vec<(&str, Option<&str>, Vec<&str>, bool)> = collected
        .saved_queries
        .iter()
        .map(|query| {
            (
                query.name.as_str(),
                query.connection.as_deref(),
                query.folder_path.iter().map(String::as_str).collect(),
                query.suggested,
            )
        })
        .collect();
    assert_eq!(
        queries,
        [
            ("revenue.sql", Some("c-pg"), vec!["Reports", "Monthly"], true),
            ("default.sql", Some("c-pg"), vec![], false),
            ("orphan.sql", None, vec!["DBX"], false),
            ("huge.sql", Some("c-maria"), vec![], false),
        ]
    );
    assert_eq!(
        collected.saved_queries[0].content,
        SavedQueryContent::Text("SELECT sum(total) FROM orders".to_owned())
    );
    assert_eq!(
        collected.saved_queries[3].content,
        SavedQueryContent::Oversized { byte_count: 900_001 }
    );
}

#[test]
fn the_store_is_found_where_tauri_keeps_it_on_each_platform() {
    for platform in [ForeignPlatform::Linux, ForeignPlatform::MacOs, ForeignPlatform::Windows] {
        let home = Home::with_store(platform, &fixture());

        assert!(home.importer.is_available_blocking(), "{platform:?}");
        assert_eq!(home.importer.inventory_blocking().connections, 9, "{platform:?}");
    }
}

#[test]
fn no_store_means_the_app_is_not_there() {
    let home = tempfile::tempdir().expect("a home");
    let dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, home.path());
    let importer = ForeignImporter::new(ForeignApp::Dbx, dirs, Arc::new(PlainHost));

    assert!(!importer.is_available_blocking());
    let error = importer
        .collect_blocking(&CONNECTIONS_ONLY, &CancellationToken::new())
        .expect_err("nothing to read");
    assert!(matches!(
        error,
        ForeignImportError::FileNotFound { app: ForeignApp::Dbx }
    ));
}

// A view that never ends, under the name of the table read: opening the store must not run it.
#[test]
fn sql_the_store_holds_never_runs() {
    let home = Home::with_store(
        ForeignPlatform::Linux,
        "CREATE VIEW connections AS WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) \
         SELECT x AS rowid, '{\"id\":\"v\",\"db_type\":\"mysql\"}' AS config_json FROM n;",
    );

    assert_eq!(home.importer.inventory_blocking(), Inventory::default());
    let outcome = home
        .importer
        .collect_blocking(&CONNECTIONS_ONLY, &CancellationToken::new());
    assert!(matches!(outcome, Err(ForeignImportError::Parse { .. })));
}

const TLS_STORE: &str = r#"
CREATE TABLE connections (id TEXT PRIMARY KEY, config_json TEXT NOT NULL);
INSERT INTO connections VALUES ('t1', '{"id":"t1","name":"Mode only","db_type":"postgres","host":"h","ssl":false,
  "url_params":"sslmode=require&application_name=x"}');
INSERT INTO connections VALUES ('t2', '{"id":"t2","name":"Verified","db_type":"postgres","host":"h","ssl":true,
  "ca_cert_path":"/certs/ca.pem","url_params":"?sslmode=verify-full"}');
INSERT INTO connections VALUES ('t3', '{"id":"t3","name":"Off","db_type":"postgres","host":"h","ssl":false,
  "url_params":"sslmode=disable"}');
INSERT INTO connections VALUES ('t4', '{"id":"t4","name":"Unknown mode","db_type":"postgres","host":"h","ssl":false,
  "url_params":"sslmode=surprise"}');
INSERT INTO connections VALUES ('t5', '{"id":"t5","name":"Other driver key","db_type":"mysql","host":"h","ssl":false,
  "url_params":"ssl-mode=VERIFY_IDENTITY"}');
INSERT INTO connections VALUES ('t6', '{"id":"t6","name":"Postgres default","db_type":"postgres","host":"h",
  "ssl":false,"url_params":"application_name=x"}');
INSERT INTO connections VALUES ('t7', '{"id":"t7","name":"CA and require","db_type":"postgres","host":"h","ssl":true,
  "ca_cert_path":"/certs/ca.pem","url_params":"sslmode=require"}');
INSERT INTO connections VALUES ('t8', '{"id":"t8","name":"MySQL plain","db_type":"mysql","host":"h","ssl":false}');
INSERT INTO connections VALUES ('t9', '{"id":"t9","name":"Switched on","db_type":"sqlserver","host":"h","ssl":true}');
"#;

#[test]
fn a_tls_mode_in_the_driver_parameters_is_kept_and_never_weakened() {
    let home = Home::with_store(ForeignPlatform::Linux, TLS_STORE);

    let collected = home.collect(&CONNECTIONS_ONLY);

    let mode = |reference: &str| settings(&collected, reference).ssl.as_ref().map(|ssl| ssl.mode);
    assert_eq!(mode("t1"), Some(ForeignSslMode::Required));
    assert_eq!(mode("t2"), Some(ForeignSslMode::VerifyIdentity));
    assert_eq!(
        settings(&collected, "t2")
            .ssl
            .as_ref()
            .and_then(|ssl| ssl.ca_certificate_path.as_deref()),
        Some("/certs/ca.pem")
    );
    assert_eq!(mode("t3"), None, "a mode turned off stays off");
    assert_eq!(
        mode("t7"),
        Some(ForeignSslMode::VerifyCa),
        "a parameter must not lower what the CA file implies"
    );
    assert_eq!(mode("t8"), None);
    assert_eq!(mode("t9"), Some(ForeignSslMode::Required));
    for unread in ["t4", "t5"] {
        assert!(
            settings(&collected, unread)
                .additional_fields
                .contains_key(TLS_SETTINGS_UNREAD),
            "{unread} was imported with its TLS setting as though it had none"
        );
    }
    assert!(
        !settings(&collected, "t1")
            .additional_fields
            .contains_key(TLS_SETTINGS_UNREAD)
    );
}

#[test]
fn postgres_with_no_mode_named_prefers_tls_as_dbx_asks_libpq_to() {
    let home = Home::with_store(ForeignPlatform::Linux, TLS_STORE);

    let collected = home.collect(&CONNECTIONS_ONLY);

    let fallback = settings(&collected, "t6");
    assert_eq!(
        fallback.ssl.as_ref().map(|ssl| ssl.mode),
        Some(ForeignSslMode::Preferred)
    );
    assert!(fallback.additional_fields.contains_key("tlsFromDriverDefault"));
    let legacy = Home::fixture().collect(&CONNECTIONS_ONLY);
    assert_eq!(
        settings(&legacy, "c-legacy").ssl.as_ref().map(|ssl| ssl.mode),
        Some(ForeignSslMode::Preferred)
    );
}
