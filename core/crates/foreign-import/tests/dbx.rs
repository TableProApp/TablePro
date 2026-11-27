#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::ffi::CString;
use std::fs;
use std::path::Path;
use std::ptr;
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, DataProtection, ForeignApp, ForeignAppDirs, ForeignColor, ForeignConnection,
    ForeignCredentialManager, ForeignHost, ForeignImportError, ForeignImporter, ForeignKeychain, ForeignPlatform,
    ForeignSecretService, ForeignSshAuth, ForeignSslMode, ImportRequest, Inventory, KeychainRead, PasswordOutcome,
    PasswordSource, PlainHost, SavedQueryContent, SavedQuerySupport, SecretScope, TLS_SETTINGS_UNREAD,
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
    dirs: ForeignAppDirs,
    importer: ForeignImporter,
}

impl Home {
    fn with_store(platform: ForeignPlatform, sql: &str) -> Self {
        Self::with_host(platform, sql, Arc::new(PlainHost))
    }

    fn with_host(platform: ForeignPlatform, sql: &str, host: Arc<dyn ForeignHost>) -> Self {
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
            importer: ForeignImporter::new(ForeignApp::Dbx, dirs.clone(), host),
            dirs,
        }
    }

    fn fixture() -> Self {
        Self::with_store(ForeignPlatform::Linux, &fixture())
    }

    // DBX's own files beside its key: `<config>/dbx`, the folder of `default_key_path` on every platform.
    fn write_key_file(&self, name: &str, contents: &[u8]) {
        let folder = self.dirs.config.join("dbx");
        fs::create_dir_all(&folder).expect("DBX's key folder");
        fs::write(folder.join(name), contents).expect("a key file");
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
        home.importer.inventory_blocking().expect("an inventory"),
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
    assert_eq!(
        not_kept(settings(&collected, "c-mongo")),
        ["connectionString", TLS_SETTINGS_UNREAD]
    );
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

// The key the fixture's envelopes were written under, bytes 0 to 31, as DBX writes it to a store or its key file.
const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const HEX_KEY: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
// Bytes 32 to 63.
const OTHER_KEY: &str = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8";

const KEYCHAIN_ITEM: &str = "com.dbx.app.secret-store.v1 local-data-encryption-key";
const CREDENTIAL: &str = "local-data-encryption-key.com.dbx.app.secret-store.v1";
const SECRET_SERVICE_ITEM: &str =
    "Everywhere target=default service=com.dbx.app.secret-store.v1 username=local-data-encryption-key";
const OLDER_SECRET_SERVICE_ITEM: &str =
    "DefaultCollection service=com.dbx.app.secret-store.v1 username=local-data-encryption-key";

// A connection whose own SSH layer, after a disabled one, keeps its secrets by its id, each written by DBX under KEY.
const OWN_LAYER: &str = r#"
INSERT INTO connections VALUES ('c-key', '{"id":"c-key","name":"Keyed","db_type":"mysql","host":"10.0.0.9",
  "port":3306,"username":"app","password":"","database":null,"transport_layers":[
    {"type":"ssh","id":"l4","enabled":false,"host":"off.example.com","port":22},
    {"type":"ssh","id":"l5","enabled":true,"host":"edge.example.com","port":22,"user":"jump","key_path":"id_ed25519",
     "auth_method":"key+password"}],"ssl":false,"save_password":true}');
INSERT INTO connection_secrets VALUES
  ('c-key', 'password', '', 'dbxenc1.JhsTELUEW2NXLnrN.pLHf_zvxiWlspuIxR_a0bOUURgdwvd_1NzuK1L0'),
  ('c-key', 'transport_layers.l5.ssh_password', '', 'dbxenc1.7WFw-9QOO1lpI7GV.RqzaZEWcd2O5If-YL8jKg_h7-m5c9A6XVZI16iknTQ'),
  ('c-key', 'transport_layers.l5.ssh_key_passphrase', '',
   'dbxenc1.cmBWIEVZLNqfAZCM.o3hr6SQOyycruRrDn9Me68P-94vZ0PXBxddpPCRkRCyZL68');
"#;

// A shared bastion saved before DBX moved a profile's secrets out of its JSON, and one half moved: its own password
// stays and its blob, written by DBX under KEY, fills the empty passphrase.
const INLINE_PROFILES: &str = r#"
INSERT INTO tunnel_profiles VALUES ('tp2', '{"type":"ssh","id":"tp2","name":"Old bastion","enabled":true,
  "host":"old.internal","port":22,"user":"ops","password":"inline-profile-secret","key_passphrase":"",
  "auth_method":"password"}');
INSERT INTO tunnel_profiles VALUES ('tp3', '{"type":"ssh","id":"tp3","name":"Half moved","enabled":true,
  "host":"half.internal","port":22,"user":"ops","password":"inline-wins","key_path":"id_ed25519",
  "key_passphrase":"","auth_method":"key+password"}');
INSERT INTO connection_secrets VALUES ('tunnel_profile.tp3', 'config', '',
  'dbxenc1.M36IuxPGKr72kGPs.zbhwFsiZPWh82oYc4mo2_WGLuTN2I5BEaZO0QvMGQvIV4Y9afI8nlUw4zHGG_ou5Y0v9cRBNWVUu_ej_V46lLZJs-8fimZU8_5Yxf0tjFplB5B9bnA91UGA9i3ZkK9eM-rPLgkPE3Y1hLNZ01DcGaBwHZbcLh23fVCZfYmk6GyhDurOLZ48aUPEBVRxZsg3azRxTQsYzmTpi5rVGNdqqQMlM0_8r_2kysCVAixQUB_MT6s83M4ChN-vlQ_GsESYXUq4D19_iKxROz2k9ViMN1Qkv8LoPMAEZFZBhdYVoAWT6dZMWidPWLskhXxcF');
INSERT INTO connections VALUES ('c-old', '{"id":"c-old","name":"Behind the old bastion","db_type":"mysql",
  "host":"10.0.0.7","port":3306,"username":"app","password":"","database":null,
  "transport_layers":[{"type":"ssh","id":"l7","enabled":true,"host":"","port":22,"profile_id":"tp2"}],"ssl":false}');
INSERT INTO connections VALUES ('c-half', '{"id":"c-half","name":"Behind the half moved one","db_type":"mysql",
  "host":"10.0.0.8","port":3306,"username":"app","password":"","database":null,
  "transport_layers":[{"type":"ssh","id":"l8","enabled":true,"host":"","port":22,"profile_id":"tp3"}],"ssl":false}');
"#;

// The shop's password, written by DBX under OTHER_KEY.
const UNDER_ANOTHER_KEY: &str = "
INSERT INTO connection_secrets VALUES
  ('c-maria', 'password', '', 'dbxenc1.yOsqi_2kCXJJB1kz.JgcR-y8I7RdR-1UMjy3wpO9kfnL4R8djZjrhbEEv');
";

// One platform store: its answer to each lookup by what the lookup names, and every lookup it was asked.
#[derive(Default)]
struct Store {
    answers: HashMap<String, KeychainRead>,
    asked: Mutex<Vec<String>>,
}

impl Store {
    fn holding(item: &str, read: KeychainRead) -> Arc<Self> {
        Arc::new(Self {
            answers: HashMap::from([(item.to_owned(), read)]),
            ..Self::default()
        })
    }

    fn answer(&self, lookup: String) -> KeychainRead {
        let read = self.answers.get(&lookup).cloned().unwrap_or(KeychainRead::NotFound);
        self.asked.lock().expect("a lock").push(lookup);
        read
    }

    fn asked(&self) -> Vec<String> {
        self.asked.lock().expect("a lock").clone()
    }
}

impl ForeignKeychain for Store {
    fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead {
        self.answer(format!("{service} {}", account.unwrap_or("-")))
    }
}

impl ForeignCredentialManager for Store {
    fn read_generic(&self, target: &str) -> KeychainRead {
        self.answer(target.to_owned())
    }
}

impl ForeignSecretService for Store {
    fn search(&self, scope: SecretScope, attributes: &[(&str, &str)]) -> KeychainRead {
        let attributes: Vec<String> = attributes
            .iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect();
        self.answer(format!("{scope:?} {}", attributes.join(" ")))
    }
}

const SEAL: &[u8] = b"sealed for this user:";

// Stands in for DPAPI: a blob opens when it carries this user's seal and the entropy DBX seals its copy with.
struct Sealed;

impl DataProtection for Sealed {
    fn unprotect(&self, blob: &[u8], entropy: &[u8]) -> Option<Vec<u8>> {
        let service: Vec<u8> = "com.dbx.app.secret-store.v1"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        blob.strip_prefix(SEAL)
            .filter(|_| entropy == service.as_slice())
            .map(<[u8]>::to_vec)
    }
}

#[derive(Default)]
struct Host {
    keychain: Option<Arc<Store>>,
    credentials: Option<Arc<Store>>,
    protection: bool,
    secret_service: Option<Arc<Store>>,
}

impl ForeignHost for Host {
    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        self.keychain.clone().map(|store| store as Arc<dyn ForeignKeychain>)
    }

    fn credential_manager(&self) -> Option<Arc<dyn ForeignCredentialManager>> {
        self.credentials
            .clone()
            .map(|store| store as Arc<dyn ForeignCredentialManager>)
    }

    fn data_protection(&self) -> Option<Arc<dyn DataProtection>> {
        self.protection.then(|| Arc::new(Sealed) as Arc<dyn DataProtection>)
    }

    fn secret_service(&self) -> Option<Arc<dyn ForeignSecretService>> {
        self.secret_service
            .clone()
            .map(|store| store as Arc<dyn ForeignSecretService>)
    }
}

fn found(key: &str) -> KeychainRead {
    KeychainRead::Found(SecretString::from(key))
}

fn secret_service(store: &Arc<Store>) -> Arc<Host> {
    Arc::new(Host {
        secret_service: Some(Arc::clone(store)),
        ..Host::default()
    })
}

fn shown(secret: Option<&SecretString>) -> Option<&str> {
    secret.map(ExposeSecret::expose_secret)
}

// The database password, the SSH password and the key passphrase a connection brings.
fn passwords<'a>(collected: &'a CollectedImport, reference: &str) -> [Option<&'a str>; 3] {
    connection(collected, reference)
        .credentials
        .as_ref()
        .map_or([None; 3], |credentials| {
            [
                shown(credentials.password.as_ref()),
                shown(credentials.ssh_password.as_ref()),
                shown(credentials.key_passphrase.as_ref()),
            ]
        })
}

#[test]
fn the_key_in_the_secret_service_opens_every_password_dbx_keeps() {
    let store = Store::holding(SECRET_SERVICE_ITEM, found(KEY));
    let home = Home::with_host(
        ForeignPlatform::Linux,
        &format!("{}{OWN_LAYER}", fixture()),
        secret_service(&store),
    );

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(
        passwords(&collected, "c-pg"),
        [
            Some("orders-db-secret"),
            Some("bastion-ssh-secret"),
            Some("bastion-key-passphrase")
        ],
        "the hop next to the database takes its secrets from the tunnel profile it names"
    );
    assert_eq!(
        passwords(&collected, "c-key"),
        [
            Some("key-db-secret"),
            Some("edge-ssh-secret"),
            Some("edge-key-passphrase")
        ]
    );
    assert_eq!(
        passwords(&collected, "c-legacy"),
        [None, Some("stored-ssh-secret"), None],
        "a row from before DBX encrypted it is read, and a password left in the JSON is not"
    );
    for reference in ["c-maria", "c-sqlite", "c-mongo", "c-cache"] {
        assert_eq!(passwords(&collected, reference), [None; 3], "{reference}");
    }
    assert_eq!(store.asked(), [SECRET_SERVICE_ITEM], "the key is looked up once");
    let everything = format!("{collected:?}");
    assert!(!everything.contains("orders-db-secret"), "a password is never printed");
}

#[test]
fn a_tunnel_profile_s_own_secrets_stand_and_its_blob_fills_the_empty_ones() {
    let store = Store::holding(SECRET_SERVICE_ITEM, found(KEY));
    let home = Home::with_host(
        ForeignPlatform::Linux,
        &format!("{}{INLINE_PROFILES}", fixture()),
        secret_service(&store),
    );

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(
        passwords(&collected, "c-old"),
        [None, Some("inline-profile-secret"), None]
    );
    assert_eq!(
        passwords(&collected, "c-half"),
        [None, Some("inline-wins"), Some("blob-passphrase")]
    );
}

#[test]
fn an_item_an_older_keyring_wrote_is_found_in_the_default_collection() {
    let store = Store::holding(OLDER_SECRET_SERVICE_ITEM, found(KEY));
    let home = Home::with_host(ForeignPlatform::Linux, &fixture(), secret_service(&store));

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));
    assert_eq!(store.asked(), [SECRET_SERVICE_ITEM, OLDER_SECRET_SERVICE_ITEM]);
}

#[test]
fn dbx_s_key_file_comes_before_the_store_and_only_a_host_with_a_store_reads_it() {
    let store = Store::holding(SECRET_SERVICE_ITEM, found(OTHER_KEY));
    let home = Home::with_host(ForeignPlatform::Linux, &fixture(), secret_service(&store));
    home.write_key_file("secret.key", format!("{HEX_KEY}\n").as_bytes());

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));
    assert!(store.asked().is_empty());

    let without_store = Home::fixture();
    without_store.write_key_file("secret.key", KEY.as_bytes());
    let collected = without_store.collect(&WITH_PASSWORDS);
    assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn a_key_file_that_holds_no_key_falls_through_to_the_store() {
    let store = Store::holding(SECRET_SERVICE_ITEM, found(KEY));
    let home = Home::with_host(ForeignPlatform::Linux, &fixture(), secret_service(&store));
    home.write_key_file("secret.key", b"not a key DBX writes");

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));
    assert_eq!(store.asked(), [SECRET_SERVICE_ITEM]);
}

#[test]
fn macos_asks_the_keychain_for_dbx_s_item_and_a_refusal_stops_the_rest() {
    let keychain = Store::holding(KEYCHAIN_ITEM, found(KEY));
    let host = Arc::new(Host {
        keychain: Some(Arc::clone(&keychain)),
        ..Host::default()
    });
    let home = Home::with_host(ForeignPlatform::MacOs, &fixture(), host);

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));
    assert_eq!(keychain.asked(), [KEYCHAIN_ITEM]);

    let refused = Store::holding(KEYCHAIN_ITEM, KeychainRead::Denied);
    let host = Arc::new(Host {
        keychain: Some(Arc::clone(&refused)),
        ..Host::default()
    });
    let home = Home::with_host(ForeignPlatform::MacOs, &fixture(), host);
    let collected = home.collect(&WITH_PASSWORDS);
    assert_eq!(collected.passwords, PasswordOutcome::Stopped);
    assert_eq!(passwords(&collected, "c-pg"), [None; 3]);
    assert_eq!(
        passwords(&collected, "c-legacy")[1],
        Some("stored-ssh-secret"),
        "a row DBX never encrypted needs no key"
    );
    assert_eq!(refused.asked(), [KEYCHAIN_ITEM], "a refused key is asked for once");
}

#[test]
fn windows_reads_the_credential_then_the_copy_dbx_seals_to_the_user() {
    let credentials = Store::holding(CREDENTIAL, found(KEY));
    let host = Arc::new(Host {
        credentials: Some(Arc::clone(&credentials)),
        ..Host::default()
    });
    let home = Home::with_host(ForeignPlatform::Windows, &fixture(), host);
    let collected = home.collect(&WITH_PASSWORDS);
    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));
    assert_eq!(credentials.asked(), [CREDENTIAL]);

    let emptied = Arc::new(Store::default());
    let mirror = [b"DBXDPAPI1".as_slice(), SEAL, KEY.as_bytes()].concat();
    let host = Arc::new(Host {
        credentials: Some(Arc::clone(&emptied)),
        protection: true,
        ..Host::default()
    });
    let home = Home::with_host(ForeignPlatform::Windows, &fixture(), host);
    home.write_key_file("secret-store.key.dpapi", &mirror);
    let collected = home.collect(&WITH_PASSWORDS);
    assert_eq!(collected.passwords, PasswordOutcome::Read);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));
    assert_eq!(emptied.asked(), [CREDENTIAL]);

    let host = Arc::new(Host {
        credentials: Some(Arc::new(Store::default())),
        ..Host::default()
    });
    let home = Home::with_host(ForeignPlatform::Windows, &fixture(), host);
    home.write_key_file("secret-store.key.dpapi", &mirror);
    let collected = home.collect(&WITH_PASSWORDS);
    assert_eq!(
        collected.passwords,
        PasswordOutcome::Stopped,
        "the copy opens only through the user's data protection"
    );
}

#[test]
fn an_envelope_another_key_wrote_stays_shut_and_the_review_says_some_were_not_read() {
    let store = Store::holding(SECRET_SERVICE_ITEM, found(KEY));
    let home = Home::with_host(
        ForeignPlatform::Linux,
        &format!("{}{UNDER_ANOTHER_KEY}", fixture()),
        secret_service(&store),
    );

    let collected = home.collect(&WITH_PASSWORDS);

    assert_eq!(collected.passwords, PasswordOutcome::Stopped);
    assert_eq!(passwords(&collected, "c-maria"), [None; 3]);
    assert_eq!(passwords(&collected, "c-pg")[0], Some("orders-db-secret"));

    let wrong = Store::holding(SECRET_SERVICE_ITEM, found(OTHER_KEY));
    let home = Home::with_host(ForeignPlatform::Linux, &fixture(), secret_service(&wrong));
    let collected = home.collect(&WITH_PASSWORDS);
    assert_eq!(collected.passwords, PasswordOutcome::Stopped);
    assert_eq!(passwords(&collected, "c-pg"), [None; 3]);

    let none = Arc::new(Store::default());
    let home = Home::with_host(ForeignPlatform::Linux, &fixture(), secret_service(&none));
    assert_eq!(
        home.collect(&WITH_PASSWORDS).passwords,
        PasswordOutcome::Stopped,
        "with no key anywhere, DBX itself cannot open them"
    );
}

#[test]
fn the_store_is_never_asked_when_no_envelope_needs_opening() {
    let store = Arc::new(Store::default());
    let home = Home::with_host(ForeignPlatform::Linux, &fixture(), secret_service(&store));
    assert_eq!(home.collect(&CONNECTIONS_ONLY).passwords, PasswordOutcome::NotRequested);
    assert!(store.asked().is_empty());

    let home = Home::with_host(ForeignPlatform::Linux, TLS_STORE, secret_service(&store));
    assert_eq!(
        home.collect(&WITH_PASSWORDS).passwords,
        PasswordOutcome::Read,
        "the driver parameters and connection string DBX encrypts are not passwords"
    );
    assert!(store.asked().is_empty());
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
        assert_eq!(
            home.importer.inventory_blocking().expect("an inventory").connections,
            9,
            "{platform:?}"
        );
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

    assert!(matches!(
        home.importer.inventory_blocking(),
        Err(ForeignImportError::Parse { .. })
    ));
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
INSERT INTO connections VALUES ('t10', '{"id":"t10","name":"Parameters apart","db_type":"postgres","host":"h",
  "ssl":false,"url_params":null}');
INSERT INTO connections VALUES ('t11', '{"id":"t11","name":"Verified, parameters apart","db_type":"postgres",
  "host":"h","ssl":true,"ca_cert_path":"/certs/ca.pem","url_params":null}');
INSERT INTO connections VALUES ('t12', '{"id":"t12","name":"By URI","db_type":"mongodb","host":"mongo.internal",
  "port":27017,"ssl":false,"connection_string":null}');
INSERT INTO connections VALUES ('t13', '{"id":"t13","name":"File with parameters","db_type":"sqlite",
  "host":"/data/app.db","ssl":false,"url_params":null}');
CREATE TABLE connection_secrets (connection_id TEXT NOT NULL, key TEXT NOT NULL, secret TEXT NOT NULL,
  secret_enc TEXT, PRIMARY KEY (connection_id, key));
INSERT INTO connection_secrets VALUES ('t10', 'url_params', '', 'dbxenc1.cGFyYW1zLXQxMA.c3NsbW9kZQ'),
  ('t11', 'url_params', '', 'dbxenc1.cGFyYW1zLXQxMQ.c3NsbW9kZQ'),
  ('t12', 'connection_string', '', 'dbxenc1.c3RyaW5nLXQxMg.bW9uZ29kYg'),
  ('t13', 'url_params', '', 'dbxenc1.cGFyYW1zLXQxMw.ZXh0ZW5zaW9u');
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

// DBX saves `url_params` and a connection string among the secrets it encrypts and leaves null in the JSON.
#[test]
fn tls_dbx_keeps_encrypted_is_unread_and_no_default_stands_in_for_it() {
    let home = Home::with_store(ForeignPlatform::Linux, TLS_STORE);

    let collected = home.collect(&CONNECTIONS_ONLY);

    let mode = |reference: &str| settings(&collected, reference).ssl.as_ref().map(|ssl| ssl.mode);
    for unread in ["t10", "t11", "t12"] {
        assert!(
            settings(&collected, unread)
                .additional_fields
                .contains_key(TLS_SETTINGS_UNREAD),
            "{unread} was imported as though its TLS were known"
        );
    }
    assert_eq!(mode("t10"), None);
    assert_eq!(not_kept(settings(&collected, "t10")), [TLS_SETTINGS_UNREAD]);
    assert_eq!(
        mode("t11"),
        Some(ForeignSslMode::VerifyCa),
        "what `ssl` and the CA file say still holds"
    );
    assert_eq!(mode("t12"), None);
    assert!(
        not_kept(settings(&collected, "t13")).is_empty(),
        "a database file has no TLS to read"
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
