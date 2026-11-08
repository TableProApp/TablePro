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
    ForeignApp, ForeignAppDirs, ForeignColor, ForeignImportError, ForeignImporter, ForeignPlatform, ForeignSshAuth,
    ForeignSslMode, ImportRequest, Inventory, PasswordOutcome, PasswordSource, PlainHost,
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

const CONNECTIONS_ONLY: ImportRequest = ImportRequest {
    include_passwords: false,
    include_saved_queries: false,
    saved_query_byte_limit: 900_000,
};

// The schema `crates/dbx-core/src/persistence/storage.rs` of t8y2/dbx creates, with rows as it writes them: the
// password cleared out of the JSON and kept encrypted in `connection_secrets`.
const STORE: &str = r#"
CREATE TABLE connections (id TEXT PRIMARY KEY, config_json TEXT NOT NULL);
CREATE TABLE connection_secrets (
    connection_id TEXT NOT NULL, key TEXT NOT NULL, secret TEXT NOT NULL, secret_enc TEXT,
    PRIMARY KEY (connection_id, key)
);
INSERT INTO connections VALUES ('c1', '{"id":"c1","name":"Orders","db_type":"postgres","host":"db.example.com","port":5433,
  "username":"ada","password":"","database":"orders","color":"red","ssl":true,"ca_cert_path":"/certs/ca.pem",
  "client_cert_path":"/certs/client.pem","client_key_path":"/certs/client.key",
  "transport_layers":[{"type":"proxy","host":"proxy.example.com"},
    {"type":"ssh","enabled":true,"host":"bastion.example.com","port":2222,"user":"jump","key_path":"id_ed25519"}]}');
INSERT INTO connections VALUES ('c2', '{"id":"c2","name":"Reports","db_type":"mysql","host":"","username":"root"}');
INSERT INTO connections VALUES ('c3', '{"id":"c3","name":"Local file","db_type":"sqlite","host":"/data/app.db"}');
INSERT INTO connections VALUES ('c4', '{"id":"c4","name":"Hosted","db_type":"sqlserver","host":"mssql.example.com","port":0,
  "ssl":true,"transport_layers":[{"type":"ssh","enabled":false,"host":"unused"}]}');
INSERT INTO connections VALUES ('c5', 'this is not json');
INSERT INTO connections VALUES ('c6', '{"id":"c6","name":"No type","db_type":""}');
INSERT INTO connection_secrets VALUES ('c1', 'password', '', 'dbxenc1.AAAA.BBBB');
"#;

struct Home {
    dir: TempDir,
}

impl Home {
    fn with_store(platform: ForeignPlatform, sql: &str) -> (Self, ForeignImporter) {
        let home = Self {
            dir: tempfile::tempdir().expect("a home"),
        };
        let dirs = ForeignAppDirs::conventional(platform, home.dir.path());
        let folder = match platform {
            ForeignPlatform::Windows => dirs.config.join("com.dbx.app"),
            _ => dirs.data.join("com.dbx.app"),
        };
        fs::create_dir_all(&folder).expect("the data folder");
        execute(&folder.join("dbx.db"), sql);
        let importer = ForeignImporter::new(ForeignApp::Dbx, dirs, Arc::new(PlainHost));
        (home, importer)
    }
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

fn collect(importer: &ForeignImporter, request: &ImportRequest) -> tablepro_foreign_import::CollectedImport {
    importer
        .collect_blocking(request, &CancellationToken::new())
        .expect("an import")
}

#[test]
fn connections_import_with_their_engine_port_tunnel_and_certificates() {
    let (_home, importer) = Home::with_store(ForeignPlatform::Linux, STORE);

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    assert_eq!(collected.app, ForeignApp::Dbx);
    let names: Vec<&str> = collected.connections.iter().map(|c| c.settings.name.as_str()).collect();
    assert_eq!(names, ["Orders", "Reports", "Local file", "Hosted"]);

    let orders = &collected.connections[0];
    assert_eq!(orders.reference, "c1");
    let settings = &orders.settings;
    assert_eq!(
        (
            settings.engine.as_str(),
            settings.host.as_str(),
            settings.port,
            settings.username.as_str(),
            settings.database.as_str()
        ),
        ("PostgreSQL", "db.example.com", 5433, "ada", "orders")
    );
    assert_eq!(settings.color, Some(ForeignColor::Red));
    let ssh = settings.ssh.as_ref().expect("the SSH tunnel, past the proxy layer");
    assert_eq!(
        (ssh.host.as_str(), ssh.port, ssh.username.as_str(), ssh.auth),
        ("bastion.example.com", Some(2222), "jump", ForeignSshAuth::PrivateKey)
    );
    assert_eq!(ssh.private_key_path, "~/.ssh/id_ed25519");
    let ssl = settings.ssl.as_ref().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::VerifyCa);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/certs/ca.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/certs/client.key"));
}

#[test]
fn an_empty_host_and_a_zero_port_fall_back_to_the_engines_defaults() {
    let (_home, importer) = Home::with_store(ForeignPlatform::Linux, STORE);

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    let reports = &collected.connections[1].settings;
    assert_eq!(
        (reports.host.as_str(), reports.port, reports.engine.as_str()),
        ("localhost", 3306, "MySQL")
    );
    let hosted = &collected.connections[3].settings;
    assert_eq!((hosted.engine.as_str(), hosted.port), ("SQL Server", 1433));
    assert!(
        hosted.ssh.is_none(),
        "a tunnel the app has switched off is not imported"
    );
    assert_eq!(hosted.ssl.as_ref().map(|ssl| ssl.mode), Some(ForeignSslMode::Required));
}

#[test]
fn a_file_database_keeps_its_path_in_the_database_field() {
    let (_home, importer) = Home::with_store(ForeignPlatform::Linux, STORE);

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    let local = &collected.connections[2].settings;
    assert_eq!(
        (
            local.engine.as_str(),
            local.host.as_str(),
            local.database.as_str(),
            local.port
        ),
        ("SQLite", "", "/data/app.db", 0)
    );
}

#[test]
fn a_row_that_is_not_json_or_has_no_type_is_left_out_and_counted_out() {
    let (_home, importer) = Home::with_store(ForeignPlatform::Linux, STORE);

    assert_eq!(
        importer.inventory_blocking(),
        Inventory {
            connections: 4,
            saved_queries: 0
        }
    );
}

#[test]
fn passwords_stay_in_the_apps_encrypted_store() {
    let (_home, importer) = Home::with_store(ForeignPlatform::Linux, STORE);
    let with_passwords = ImportRequest {
        include_passwords: true,
        ..CONNECTIONS_ONLY
    };

    let collected = collect(&importer, &with_passwords);

    assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
    assert_eq!(
        collect(&importer, &CONNECTIONS_ONLY).passwords,
        PasswordOutcome::NotRequested
    );
    assert_eq!(ForeignApp::Dbx.password_source(), PasswordSource::Keychain);
}

#[test]
fn the_store_is_found_where_tauri_keeps_it_on_each_platform() {
    for platform in [ForeignPlatform::Linux, ForeignPlatform::MacOs, ForeignPlatform::Windows] {
        let (_home, importer) = Home::with_store(platform, STORE);

        assert!(importer.is_available_blocking(), "{platform:?}");
        assert_eq!(importer.inventory_blocking().connections, 4, "{platform:?}");
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
