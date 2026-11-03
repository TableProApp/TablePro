#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::ffi::CString;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use secrecy::{ExposeSecret, SecretString};
use tablepro_foreign_import::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignHost, ForeignImportError, ForeignImporter,
    ForeignKeychain, ForeignPlatform, ForeignSshAuth, ForeignSslMode, ImportRequest, Inventory, KeychainRead,
    PasswordOutcome, PasswordSource, SavedQueryContent, SavedQuerySupport,
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

const BYTE_LIMIT: u64 = 900_000;

const CONNECTIONS_ONLY: ImportRequest = ImportRequest {
    include_passwords: false,
    include_saved_queries: false,
    saved_query_byte_limit: BYTE_LIMIT,
};
const WITH_PASSWORDS: ImportRequest = ImportRequest {
    include_passwords: true,
    ..CONNECTIONS_ONLY
};
const WITH_SAVED_QUERIES: ImportRequest = ImportRequest {
    include_saved_queries: true,
    ..CONNECTIONS_ONLY
};

// The schema and rows of the macOS tests; `more_connections.sql` runs after `queries.sql`.
const FOLDERS_DATABASE: &[&str] = &["connections.sql", "queries.sql"];
const FULL_DATABASE: &[&str] = &["connections.sql", "queries.sql", "more_connections.sql"];

#[derive(Default)]
struct RecordingKeychain {
    reads: AtomicUsize,
}

impl ForeignKeychain for RecordingKeychain {
    fn read_password(&self, _service: &str, _account: Option<&str>) -> KeychainRead {
        self.reads.fetch_add(1, Ordering::SeqCst);
        KeychainRead::Found(SecretString::from("from the keychain".to_owned()))
    }
}

#[derive(Default)]
struct TestHost {
    keychain: Arc<RecordingKeychain>,
    installed: Mutex<Option<bool>>,
}

impl ForeignHost for TestHost {
    fn installed(&self, _app: ForeignApp) -> Option<bool> {
        *self.installed.lock().expect("the flag")
    }

    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        Some(self.keychain.clone())
    }
}

struct Home {
    dir: TempDir,
    host: Arc<TestHost>,
}

impl Home {
    fn new() -> Self {
        Self {
            dir: tempfile::tempdir().expect("a home"),
            host: Arc::new(TestHost::default()),
        }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.dir.path().join(relative)
    }

    fn importer(&self, platform: ForeignPlatform) -> ForeignImporter {
        self.importer_with(ForeignAppDirs::conventional(platform, self.dir.path()))
    }

    fn importer_with(&self, dirs: ForeignAppDirs) -> ForeignImporter {
        ForeignImporter::new(ForeignApp::BeekeeperStudio, dirs, self.host.clone())
    }
}

const MAC_FOLDER: &str = "Library/Application Support/beekeeper-studio";

fn fixture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/beekeeper")
        .join(name);
    fs::read_to_string(path).expect("a fixture")
}

fn make_app_db(folder: &Path, scripts: &[&str]) {
    fs::create_dir_all(folder).expect("the data folder");
    let sql: Vec<String> = scripts.iter().map(|name| fixture(name)).collect();
    execute(&folder.join("app.db"), &sql.join("\n"));
}

// Beekeeper writes the key with no final newline; the repository's editor settings add one to the fixture.
fn write_key_file(folder: &Path) {
    fs::write(folder.join(".key"), fixture(".key").trim_end()).expect("the key file");
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

fn collect(importer: &ForeignImporter, request: &ImportRequest) -> CollectedImport {
    importer
        .collect_blocking(request, &CancellationToken::new())
        .expect("an import")
}

fn mac_home(scripts: &[&str]) -> (Home, ForeignImporter) {
    let home = Home::new();
    make_app_db(&home.path(MAC_FOLDER), scripts);
    let importer = home.importer(ForeignPlatform::MacOs);
    (home, importer)
}

fn names(collected: &CollectedImport) -> Vec<&str> {
    collected
        .connections
        .iter()
        .map(|connection| connection.settings.name.as_str())
        .collect()
}

fn query_names(collected: &CollectedImport) -> Vec<&str> {
    collected
        .saved_queries
        .iter()
        .map(|query| query.name.as_str())
        .collect()
}

fn secret(value: Option<&SecretString>) -> Option<&str> {
    value.map(|value| value.expose_secret())
}

#[test]
fn local_workspace_connections_import_keyed_by_their_beekeeper_id() {
    let (_home, importer) = mac_home(FOLDERS_DATABASE);

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    assert_eq!(collected.app, ForeignApp::BeekeeperStudio);
    assert_eq!(names(&collected), ["Shop"]);
    let shop = &collected.connections[0];
    assert_eq!(shop.reference, "1");
    assert_eq!(shop.group_path, ["Production"]);
    assert_eq!(shop.settings.engine, "PostgreSQL");
    assert_eq!(shop.settings.host, "db.example.com");
    assert_eq!(shop.settings.port, 5432);
    assert_eq!(shop.settings.database, "shop");
    assert_eq!(shop.settings.username, "app");
    assert!(shop.settings.ssh.is_none());
    assert!(shop.settings.ssl.is_none());
    assert!(shop.credentials.is_none());
    assert!(collected.saved_queries.is_empty());
    assert_eq!(collected.passwords, PasswordOutcome::NotRequested);
}

#[test]
fn a_missing_app_db_is_file_not_found() {
    let home = Home::new();
    let outcome = home
        .importer(ForeignPlatform::MacOs)
        .collect_blocking(&WITH_SAVED_QUERIES, &CancellationToken::new());
    assert!(matches!(
        outcome,
        Err(ForeignImportError::FileNotFound {
            app: ForeignApp::BeekeeperStudio
        })
    ));
}

#[test]
fn a_file_that_is_not_a_database_is_an_unsupported_format() {
    let home = Home::new();
    let folder = home.path(MAC_FOLDER);
    fs::create_dir_all(&folder).expect("the data folder");
    fs::write(folder.join("app.db"), "not a database").expect("a file");

    let outcome = home
        .importer(ForeignPlatform::MacOs)
        .collect_blocking(&CONNECTIONS_ONLY, &CancellationToken::new());

    assert!(matches!(outcome, Err(ForeignImportError::UnsupportedFormat { .. })));
    assert_eq!(
        home.importer(ForeignPlatform::MacOs).inventory_blocking(),
        Inventory::default()
    );
}

#[test]
fn saved_queries_keep_their_folder_tree_under_the_app_folder() {
    let (_home, importer) = mac_home(FOLDERS_DATABASE);

    let collected = collect(&importer, &WITH_SAVED_QUERIES);

    let text: Vec<&str> = collected
        .saved_queries
        .iter()
        .filter(|query| matches!(query.content, SavedQueryContent::Text(_)))
        .map(|query| query.name.as_str())
        .collect();
    assert_eq!(text, ["Top customers", "Daily active users"]);

    let daily = &collected.saved_queries[1];
    assert_eq!(
        daily.content,
        SavedQueryContent::Text("select count(*) from sessions;".to_owned())
    );
    assert_eq!(daily.connection, None);
    assert_eq!(daily.keyword, None);
    assert_eq!(daily.folder_path, ["Beekeeper Studio", "Reports", "Daily"]);
    assert!(daily.suggested);

    let top = &collected.saved_queries[0];
    assert_eq!(
        top.content,
        SavedQueryContent::Text("select * from customers where region = ${region};".to_owned())
    );
    assert_eq!(top.folder_path, ["Beekeeper Studio"]);
}

#[test]
fn the_seeded_demo_query_and_blank_queries_are_skipped() {
    let (_home, importer) = mac_home(FOLDERS_DATABASE);

    let collected = collect(&importer, &WITH_SAVED_QUERIES);

    assert_eq!(query_names(&collected), ["Top customers", "Daily active users", "Huge"]);
}

#[test]
fn a_query_over_the_byte_limit_is_listed_as_oversized_in_its_folder() {
    let (_home, importer) = mac_home(FOLDERS_DATABASE);

    let collected = collect(&importer, &WITH_SAVED_QUERIES);

    let huge = collected
        .saved_queries
        .iter()
        .find(|query| query.name == "Huge")
        .expect("the query");
    assert_eq!(huge.content, SavedQueryContent::Oversized { byte_count: 900_001 });
    assert_eq!(huge.folder_path, ["Beekeeper Studio", "Reports"]);
    assert_eq!(huge.connection, None);
    assert!(!huge.suggested);
}

#[test]
fn a_query_at_the_byte_limit_imports_its_text() {
    let (_home, importer) = mac_home(FOLDERS_DATABASE);
    let request = ImportRequest {
        saved_query_byte_limit: 900_001,
        ..WITH_SAVED_QUERIES
    };

    let collected = collect(&importer, &request);

    let huge = collected
        .saved_queries
        .iter()
        .find(|query| query.name == "Huge")
        .expect("the query");
    assert_eq!(huge.content, SavedQueryContent::Text("x".repeat(900_001)));
}

#[test]
fn an_older_database_without_query_folders_imports_its_queries_flat() {
    let (_home, importer) = mac_home(&["connections.sql", "queries_without_folders.sql"]);

    let collected = collect(&importer, &WITH_SAVED_QUERIES);

    assert_eq!(query_names(&collected), ["Orders"]);
    assert_eq!(collected.saved_queries[0].folder_path, ["Beekeeper Studio"]);
}

#[test]
fn a_database_without_saved_queries_imports_its_connections() {
    let (_home, importer) = mac_home(&["connections.sql"]);

    let collected = collect(&importer, &WITH_SAVED_QUERIES);

    assert_eq!(collected.connections.len(), 1);
    assert!(collected.saved_queries.is_empty());
    assert_eq!(
        importer.inventory_blocking(),
        Inventory {
            connections: 1,
            saved_queries: 0
        }
    );
}

#[test]
fn inventory_counts_connections_and_queries_without_the_demo_or_blank_rows() {
    let (_home, importer) = mac_home(FOLDERS_DATABASE);

    assert_eq!(
        importer.inventory_blocking(),
        Inventory {
            connections: 1,
            saved_queries: 3
        }
    );
}

#[test]
fn cloud_workspace_queries_are_left_out() {
    let (_home, importer) = mac_home(FULL_DATABASE);

    let collected = collect(&importer, &WITH_SAVED_QUERIES);

    assert!(!query_names(&collected).contains(&"Cloud report"));
    // The two rows without a connection type are not imported, so they are not counted either.
    assert_eq!(
        importer.inventory_blocking(),
        Inventory {
            connections: 4,
            saved_queries: 3
        }
    );
}

#[test]
fn saved_queries_import_into_a_folder_named_after_the_app() {
    assert_eq!(
        ForeignApp::BeekeeperStudio.saved_query_support(),
        SavedQuerySupport::GlobalFolder
    );
}

#[test]
fn the_app_is_named_and_reads_passwords_from_its_own_files() {
    let app = ForeignApp::BeekeeperStudio;
    assert_eq!(app.id(), "beekeeperstudio");
    assert_eq!(ForeignApp::from_id("beekeeperstudio"), Some(app));
    assert_eq!(app.display_name(), "Beekeeper Studio");
    assert_eq!(app.password_source(), PasswordSource::AppFiles);
    assert!(app.picked_file_extensions().is_none());
}

#[test]
fn an_empty_home_has_nothing_on_any_platform() {
    let home = Home::new();
    for platform in [ForeignPlatform::MacOs, ForeignPlatform::Linux, ForeignPlatform::Windows] {
        let importer = home.importer(platform);
        assert_eq!(importer.inventory_blocking(), Inventory::default());
        assert!(!importer.is_available_blocking());
    }
}

#[test]
fn the_app_counts_as_available_when_its_database_is_there() {
    let (home, importer) = mac_home(&["connections.sql"]);
    assert!(importer.is_available_blocking());
    *home.host.installed.lock().expect("the flag") = Some(false);
    assert!(!importer.is_available_blocking());
}

#[test]
fn passwords_decrypt_with_the_key_from_the_key_file() {
    let (home, importer) = mac_home(FULL_DATABASE);
    write_key_file(&home.path(MAC_FOLDER));

    let collected = collect(&importer, &WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    let shop = collected.connections[0].credentials.as_ref().expect("Shop's password");
    assert_eq!(secret(shop.password.as_ref()), Some("hunter2"));
    assert_eq!(secret(shop.ssh_password.as_ref()), None);
    let tunnelled = collected.connections[1]
        .credentials
        .as_ref()
        .expect("the tunnel's passwords");
    assert_eq!(secret(tunnelled.password.as_ref()), Some("s3cret"));
    assert_eq!(secret(tunnelled.ssh_password.as_ref()), Some("ssh-pass"));
    assert_eq!(secret(tunnelled.key_passphrase.as_ref()), Some("key-phrase"));
    assert!(collected.connections[2].credentials.is_none());
    assert_eq!(home.host.keychain.reads.load(Ordering::SeqCst), 0);
}

#[test]
fn without_a_key_file_connections_import_without_passwords() {
    let (_home, importer) = mac_home(FULL_DATABASE);

    let collected = collect(&importer, &WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn passwords_are_not_read_unless_asked_for() {
    let (home, importer) = mac_home(FULL_DATABASE);
    write_key_file(&home.path(MAC_FOLDER));

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    assert_eq!(collected.passwords, PasswordOutcome::NotRequested);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn ssh_ssl_colors_and_defaults_map_as_on_macos() {
    let (_home, importer) = mac_home(FULL_DATABASE);

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    assert_eq!(names(&collected), ["Shop", "Tunnelled", "Untitled", "Lake"]);

    let tunnelled = &collected.connections[1];
    assert_eq!(tunnelled.settings.engine, "MySQL");
    assert_eq!(tunnelled.settings.port, 3307);
    assert_eq!(tunnelled.settings.color, Some(ForeignColor::Gray));
    assert!(tunnelled.group_path.is_empty());
    let ssh = tunnelled.settings.ssh.as_ref().expect("a tunnel");
    assert_eq!(ssh.host, "bastion.example.com");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.username, "deploy");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "~/.ssh/id_ed25519");
    assert_eq!(ssh.jump_hosts.len(), 1);
    let jump = &ssh.jump_hosts[0];
    assert_eq!(
        (jump.host.as_str(), jump.port, jump.username.as_str()),
        ("jump.example.com", Some(22), "hop")
    );
    assert_eq!(jump.auth, ForeignSshAuth::Agent);
    assert_eq!(jump.private_key_path, "");
    let ssl = tunnelled.settings.ssl.as_ref().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::VerifyIdentity);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/certs/ca.pem"));
    assert_eq!(ssl.client_certificate_path.as_deref(), Some("/certs/client.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/certs/client.key"));

    let untitled = &collected.connections[2];
    assert_eq!(untitled.reference, "4");
    assert_eq!(untitled.settings.host, "localhost");
    assert_eq!(untitled.settings.engine, "SQL Server");
    assert_eq!(untitled.settings.port, 1433);
    assert_eq!(untitled.settings.color, None);
    let ssh = untitled.settings.ssh.as_ref().expect("a tunnel");
    assert_eq!(
        (ssh.host.as_str(), ssh.port, ssh.auth),
        ("gateway", None, ForeignSshAuth::Password)
    );
    assert!(ssh.jump_hosts.is_empty());
    assert_eq!(
        untitled.settings.ssl.as_ref().map(|ssl| ssl.mode),
        Some(ForeignSslMode::VerifyIdentity)
    );

    let lake = &collected.connections[3];
    assert_eq!(lake.settings.engine, "acmedb");
    assert_eq!(lake.settings.port, 8000);
    let ssl = lake.settings.ssl.as_ref().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::Required);
    assert_eq!(ssl.ca_certificate_path, None);
}

#[test]
fn tls_verification_follows_what_each_engine_s_connector_does() {
    let (_home, importer) = mac_home(&["connections.sql", "queries.sql", "tls_connections.sql"]);

    let collected = collect(&importer, &CONNECTIONS_ONLY);

    let modes = [
        ("PG no files", ForeignSslMode::Required),
        ("PG with CA", ForeignSslMode::VerifyIdentity),
        ("PG unverified", ForeignSslMode::Required),
        ("MySQL no files", ForeignSslMode::Required),
        ("SQL Server", ForeignSslMode::VerifyIdentity),
        ("SQL Server trusted", ForeignSslMode::Required),
        ("Redis", ForeignSslMode::VerifyIdentity),
    ];
    for (name, mode) in modes {
        let connection = collected
            .connections
            .iter()
            .find(|connection| connection.settings.name == name)
            .expect("a connection");
        assert_eq!(
            connection.settings.ssl.as_ref().map(|ssl| ssl.mode),
            Some(mode),
            "{name}"
        );
    }
}

#[test]
fn a_cancelled_import_stops() {
    let (_home, importer) = mac_home(FULL_DATABASE);
    let cancel = CancellationToken::new();
    cancel.cancel();

    let outcome = importer.collect_blocking(&WITH_SAVED_QUERIES, &cancel);

    assert!(matches!(outcome, Err(ForeignImportError::Cancelled)));
}

#[test]
fn windows_reads_the_roaming_app_data_folder() {
    let home = Home::new();
    make_app_db(&home.path("AppData/Roaming/beekeeper-studio"), &["connections.sql"]);

    let collected = collect(&home.importer(ForeignPlatform::Windows), &CONNECTIONS_ONLY);

    assert_eq!(names(&collected), ["Shop"]);
}

#[test]
fn linux_reads_each_package_folder() {
    let folders = [
        ".config/beekeeper-studio",
        ".var/app/io.beekeeperstudio.Studio/config/beekeeper-studio",
        ".var/app/io.beekeeperstudio.desktop/config/beekeeper-studio",
        "snap/beekeeper-studio/current/.config/beekeeper-studio",
    ];
    for folder in folders {
        let home = Home::new();
        make_app_db(&home.path(folder), &["connections.sql"]);
        write_key_file(&home.path(folder));

        let collected = collect(&home.importer(ForeignPlatform::Linux), &WITH_PASSWORDS);

        assert_eq!(names(&collected), ["Shop"], "{folder}");
    }
}

#[test]
fn linux_reads_the_host_config_folder_when_it_is_not_the_default() {
    let home = Home::new();
    make_app_db(&home.path("xdg/beekeeper-studio"), &["connections.sql"]);
    let dirs = ForeignAppDirs {
        config: home.path("xdg"),
        ..ForeignAppDirs::conventional(ForeignPlatform::Linux, home.dir.path())
    };

    assert_eq!(names(&collect(&home.importer_with(dirs), &CONNECTIONS_ONLY)), ["Shop"]);
}

#[test]
fn linux_uses_the_copy_saved_to_last_when_several_packages_left_one() {
    let home = Home::new();
    let native = home.path(".config/beekeeper-studio");
    let flathub = home.path(".var/app/io.beekeeperstudio.Studio/config/beekeeper-studio");
    make_app_db(&native, &["connections.sql"]);
    make_app_db(&flathub, &["connections.sql"]);
    execute(
        &flathub.join("app.db"),
        "UPDATE saved_connection SET name = 'Shop on Flathub' WHERE id = 1;",
    );
    let set_age = |folder: &Path, seconds: u64| {
        let file = File::options()
            .write(true)
            .open(folder.join("app.db"))
            .expect("the database");
        file.set_modified(SystemTime::now() - Duration::from_secs(seconds))
            .expect("a time");
    };
    let importer = home.importer(ForeignPlatform::Linux);

    set_age(&native, 600);
    set_age(&flathub, 60);
    assert_eq!(names(&collect(&importer, &CONNECTIONS_ONLY)), ["Shop on Flathub"]);

    set_age(&native, 30);
    assert_eq!(names(&collect(&importer, &CONNECTIONS_ONLY)), ["Shop"]);
}
