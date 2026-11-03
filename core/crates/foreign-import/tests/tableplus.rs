#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "the fixture helpers fail a test the way the test functions themselves do"
)]

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, CollectedSavedQuery, ForeignApp, ForeignAppDirs, ForeignColor, ForeignHost,
    ForeignImportError, ForeignImporter, ForeignKeychain, ForeignPlatform, ForeignSshAuth, ForeignSslMode,
    ImportRequest, Inventory, KeychainRead, PasswordOutcome, PasswordSource, SavedQueryContent, SavedQuerySupport,
};
use tokio_util::sync::CancellationToken;

const LIMIT: u64 = 900_000;
const SERVICE: &str = "com.tableplus.TablePlus";
const PLATFORMS: [ForeignPlatform; 3] = [ForeignPlatform::MacOs, ForeignPlatform::Windows, ForeignPlatform::Linux];

const CONNECTIONS_ONLY: ImportRequest = ImportRequest {
    include_passwords: false,
    include_saved_queries: false,
    saved_query_byte_limit: LIMIT,
};
const WITH_PASSWORDS: ImportRequest = ImportRequest {
    include_passwords: true,
    ..CONNECTIONS_ONLY
};
const WITH_SAVED_QUERIES: ImportRequest = ImportRequest {
    include_saved_queries: true,
    ..CONNECTIONS_ONLY
};

#[derive(Clone, Copy)]
enum Answer {
    Found(&'static str),
    Denied,
}

#[derive(Default)]
struct Keychain {
    answers: HashMap<String, Answer>,
    calls: Mutex<Vec<(String, String)>>,
}

impl Keychain {
    fn answering(answers: &[(&str, Answer)]) -> Arc<Self> {
        Arc::new(Self {
            answers: answers
                .iter()
                .map(|(account, answer)| ((*account).to_owned(), *answer))
                .collect(),
            calls: Mutex::new(Vec::new()),
        })
    }

    fn calls(&self) -> Vec<(String, String)> {
        self.calls.lock().expect("the calls").clone()
    }

    fn accounts_of(&self, connection_id: &str) -> BTreeSet<String> {
        let prefix = format!("{connection_id}_");
        self.calls()
            .into_iter()
            .map(|(_, account)| account)
            .filter(|account| account.starts_with(&prefix))
            .collect()
    }
}

impl ForeignKeychain for Keychain {
    fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead {
        let account = account.unwrap_or_default().to_owned();
        let answer = self.answers.get(&account).copied();
        self.calls
            .lock()
            .expect("the calls")
            .push((service.to_owned(), account));
        match answer {
            Some(Answer::Found(secret)) => KeychainRead::Found(SecretString::from(secret)),
            Some(Answer::Denied) => KeychainRead::Denied,
            None => KeychainRead::NotFound,
        }
    }
}

struct Host {
    keychain: Option<Arc<Keychain>>,
}

impl ForeignHost for Host {
    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        self.keychain
            .clone()
            .map(|keychain| keychain as Arc<dyn ForeignKeychain>)
    }
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/tableplus")
        .join(name)
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).expect("a folder");
    for child in fs::read_dir(from).expect("a fixture folder") {
        let child = child.expect("a fixture entry");
        let target = to.join(child.file_name());
        if child.file_type().expect("a file type").is_dir() {
            copy_tree(&child.path(), &target);
        } else {
            fs::copy(child.path(), target).expect("a copy");
        }
    }
}

fn writable(name: &str) -> tempfile::TempDir {
    let home = tempfile::tempdir().expect("a temp dir");
    copy_tree(&fixture(name), home.path());
    home
}

fn importer(platform: ForeignPlatform, home: &Path, keychain: Option<Arc<Keychain>>) -> ForeignImporter {
    ForeignImporter::new(
        ForeignApp::TablePlus,
        ForeignAppDirs::conventional(platform, home),
        Arc::new(Host { keychain }),
    )
}

fn try_collect(
    platform: ForeignPlatform,
    home: &Path,
    request: ImportRequest,
    keychain: Option<Arc<Keychain>>,
) -> Result<CollectedImport, ForeignImportError> {
    importer(platform, home, keychain).collect_blocking(&request, &CancellationToken::new())
}

fn collect(platform: ForeignPlatform, home: &Path, request: ImportRequest) -> CollectedImport {
    try_collect(platform, home, request, None).expect("an import")
}

fn macos(request: ImportRequest) -> CollectedImport {
    collect(ForeignPlatform::MacOs, &fixture("macos"), request)
}

fn macos_with_keychain(keychain: &Arc<Keychain>) -> CollectedImport {
    try_collect(
        ForeignPlatform::MacOs,
        &fixture("macos"),
        WITH_PASSWORDS,
        Some(Arc::clone(keychain)),
    )
    .expect("an import")
}

fn connection<'a>(collected: &'a CollectedImport, name: &str) -> &'a CollectedConnection {
    collected
        .connections
        .iter()
        .find(|connection| connection.settings.name == name)
        .unwrap_or_else(|| panic!("no connection named {name}"))
}

fn query<'a>(collected: &'a CollectedImport, name: &str) -> Option<&'a CollectedSavedQuery> {
    collected.saved_queries.iter().find(|query| query.name == name)
}

fn query_names(collected: &CollectedImport) -> BTreeSet<&str> {
    collected
        .saved_queries
        .iter()
        .map(|query| query.name.as_str())
        .collect()
}

fn field<'a>(connection: &'a CollectedConnection, key: &str) -> Option<&'a str> {
    connection.settings.additional_fields.get(key).map(String::as_str)
}

fn exposed(secret: Option<&SecretString>) -> Option<&str> {
    secret.map(|secret| secret.expose_secret())
}

fn text(query: &CollectedSavedQuery) -> &str {
    match &query.content {
        SavedQueryContent::Text(text) => text,
        SavedQueryContent::Oversized { .. } => panic!("{} is oversized", query.name),
    }
}

fn ssl_mode(collected: &CollectedImport, name: &str) -> Option<ForeignSslMode> {
    connection(collected, name).settings.ssl.as_ref().map(|ssl| ssl.mode)
}

#[test]
fn the_app_is_tableplus_reading_keychain_passwords_and_global_queries() {
    let app = ForeignApp::TablePlus;
    assert_eq!(app.id(), "tableplus");
    assert_eq!(app.display_name(), "TablePlus");
    assert_eq!(app.password_source(), PasswordSource::Keychain);
    assert_eq!(app.saved_query_support(), SavedQuerySupport::GlobalFolder);
    assert!(PLATFORMS.into_iter().all(|platform| app.runs_on(platform)));
}

#[test]
fn inventory_counts_every_readable_connection_and_every_non_empty_favorite() {
    let inventory = importer(ForeignPlatform::MacOs, &fixture("macos"), None).inventory_blocking();
    // The two entries with no name that collect skips are not counted.
    assert_eq!(
        inventory,
        Inventory {
            connections: 105,
            saved_queries: 6
        }
    );
}

#[test]
fn an_empty_home_has_nothing_on_any_platform() {
    let home = tempfile::tempdir().expect("a temp dir");
    for platform in PLATFORMS {
        let tableplus = importer(platform, home.path(), None);
        assert_eq!(tableplus.inventory_blocking(), Inventory::default());
        assert!(!tableplus.is_available_blocking());
        assert!(matches!(
            tableplus.collect_blocking(&CONNECTIONS_ONLY, &CancellationToken::new()),
            Err(ForeignImportError::FileNotFound {
                app: ForeignApp::TablePlus
            })
        ));
    }
}

#[test]
fn collect_reads_every_named_connection_and_skips_the_rest() {
    let collected = macos(CONNECTIONS_ONLY);
    assert_eq!(collected.app, ForeignApp::TablePlus);
    assert_eq!(collected.connections.len(), 105);
    assert!(importer(ForeignPlatform::MacOs, &fixture("macos"), None).is_available_blocking());
}

#[test]
fn collect_keys_each_connection_by_its_tableplus_id() {
    let collected = macos(CONNECTIONS_ONLY);
    assert_eq!(connection(&collected, "Bundle DB").reference, "conn-7");
    assert_eq!(collected.passwords, PasswordOutcome::NotRequested);
    assert!(collected.saved_queries.is_empty());
}

#[test]
fn collect_maps_every_driver_tableplus_writes() {
    let collected = macos(CONNECTIONS_ONLY);
    let mappings = [
        ("MicrosoftSQLServer", "SQL Server"),
        ("Mongo", "MongoDB"),
        ("Cockroach", "CockroachDB"),
        ("CloudflareD1", "Cloudflare D1"),
        ("LibSQL", "libSQL"),
        ("ElasticSearch", "Elasticsearch"),
        ("MySQL", "MySQL"),
        ("MariaDB", "MariaDB"),
        ("PostgreSQL", "PostgreSQL"),
        ("Redshift", "Redshift"),
        ("Redis", "Redis"),
        ("Oracle", "Oracle"),
        ("SQLite", "SQLite"),
        ("DuckDB", "DuckDB"),
        ("ClickHouse", "ClickHouse"),
        ("BigQuery", "BigQuery"),
        ("DynamoDB", "DynamoDB"),
        ("Snowflake", "Snowflake"),
        ("Cassandra", "Cassandra"),
        ("Vertica", "Vertica"),
        ("Greenplum", "Greenplum"),
    ];
    for (driver, engine) in mappings {
        assert_eq!(
            connection(&collected, &format!("Conn {driver}")).settings.engine,
            engine,
            "{driver}"
        );
    }
}

#[test]
fn collect_keeps_an_explicit_key_path_even_when_the_file_is_missing() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssh = connection(&collected, "SSH DB")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.host, "bastion.example.com");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.username, "deploy");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "/Users/test/.ssh/id_rsa");
    assert!(ssh.jump_hosts.is_empty());
}

#[test]
fn collect_drops_the_empty_key_placeholder_instead_of_building_a_fake_path() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssh = connection(&collected, "SSH Placeholder")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "");
}

#[test]
fn collect_keeps_a_bare_key_name_when_the_file_is_in_the_ssh_folder() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssh = connection(&collected, "SSH Bare Key")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.private_key_path, "~/.ssh/id_tableplus_fixture");
}

#[test]
fn collect_reads_password_sign_in_and_integer_flags_for_a_tunnel() {
    let collected = macos(CONNECTIONS_ONLY);
    let password = connection(&collected, "SSH Password DB")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(password.auth, ForeignSshAuth::Password);
    assert_eq!(password.private_key_path, "");
    assert_eq!(password.port, Some(22));

    let integers = connection(&collected, "SSH Integer Flags")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(integers.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(integers.private_key_path, "/keys/id_ed25519");
    assert!(connection(&collected, "No SSL").settings.ssh.is_none());
}

#[test]
fn collect_reads_tls_key_paths_in_tableplus_order_key_certificate_authority() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssl = connection(&collected, "SSL DB").settings.ssl.as_ref().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::Required);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/path/to/ca.pem"));
    assert_eq!(ssl.client_certificate_path.as_deref(), Some("/path/to/client-cert.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/path/to/client-key.pem"));
}

#[test]
fn collect_sets_no_tls_without_the_mode_key_and_preferred_for_mode_zero() {
    let collected = macos(CONNECTIONS_ONLY);
    assert!(connection(&collected, "No SSL").settings.ssl.is_none());
    assert_eq!(ssl_mode(&collected, "Prefer SSL"), Some(ForeignSslMode::Preferred));
}

#[test]
fn collect_reads_the_tls_mode_against_the_popup_of_the_drivers_own_form() {
    use ForeignSslMode::{Disabled, Preferred, Required, VerifyCa, VerifyIdentity};
    let collected = macos(CONNECTIONS_ONLY);
    let cases = [
        ("MySQL 0", Preferred),
        ("MySQL 1", Disabled),
        ("MySQL 2", Required),
        ("MySQL 3", VerifyCa),
        ("MySQL 4", VerifyIdentity),
        ("MariaDB 1", Required),
        ("MariaDB 2", VerifyIdentity),
        ("PostgreSQL 1", Disabled),
        ("PostgreSQL 2", Required),
        ("PostgreSQL 3", Preferred),
        ("PostgreSQL 4", VerifyCa),
        ("PostgreSQL 5", VerifyIdentity),
        ("Cockroach 5", VerifyIdentity),
        ("Redshift 4", VerifyCa),
        ("Cassandra 0", Disabled),
        ("Cassandra 2", VerifyCa),
        ("Cassandra 4", VerifyIdentity),
        ("Redis 0", Disabled),
        ("Redis 2", VerifyCa),
        ("ClickHouse 1", VerifyIdentity),
        ("ClickHouse 2", Required),
        ("Mongo 1", VerifyIdentity),
        ("ElasticSearch 1", VerifyIdentity),
        ("ElasticSearch 2", VerifyCa),
        ("ElasticSearch 3", Required),
        ("Oracle 1", Required),
    ];
    for (name, mode) in cases {
        assert_eq!(ssl_mode(&collected, name), Some(mode), "{name}");
    }
}

#[test]
fn collect_reads_the_tls_slots_each_drivers_own_form_writes() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssl = |name: &str| connection(&collected, name).settings.ssl.clone().expect("TLS");

    let cassandra = ssl("Cassandra TLS");
    assert_eq!(cassandra.client_key_path.as_deref(), Some("/path/to/cass-key.pem"));
    assert_eq!(
        cassandra.client_certificate_path.as_deref(),
        Some("/path/to/cass-cert.pem")
    );
    assert_eq!(cassandra.ca_certificate_path.as_deref(), Some("/path/to/cass-ca.pem"));

    let authority_only = ssl("Cassandra CA only");
    assert_eq!(
        authority_only.ca_certificate_path.as_deref(),
        Some("/path/to/cass-ca.pem")
    );
    assert_eq!(authority_only.client_key_path, None);
    assert_eq!(authority_only.client_certificate_path, None);

    let mongo = ssl("Mongo TLS");
    assert_eq!(
        mongo.client_certificate_path.as_deref(),
        Some("/path/to/mongo-certkey.pem")
    );
    assert_eq!(mongo.ca_certificate_path.as_deref(), Some("/path/to/mongo-ca.pem"));
    assert_eq!(mongo.client_key_path, None);

    let clickhouse = ssl("ClickHouse TLS");
    assert_eq!(
        clickhouse.ca_certificate_path.as_deref(),
        Some("/path/to/clickhouse-ca.pem")
    );
    assert_eq!(clickhouse.client_certificate_path, None);
    assert_eq!(clickhouse.client_key_path, None);

    let elasticsearch = ssl("Elasticsearch TLS");
    assert_eq!(elasticsearch.ca_certificate_path.as_deref(), Some("/path/to/es-ca.pem"));
    assert_eq!(elasticsearch.client_certificate_path, None);
}

#[test]
fn collect_carries_no_tls_paths_for_a_driver_whose_form_has_no_file_pickers() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssl = connection(&collected, "Oracle TLS").settings.ssl.clone().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::Required);
    assert_eq!(ssl.ca_certificate_path, None);
    assert_eq!(ssl.client_certificate_path, None);
    assert_eq!(ssl.client_key_path, None);
}

#[test]
fn collect_drops_a_tls_mode_past_the_end_of_the_drivers_own_popup() {
    let collected = macos(CONNECTIONS_ONLY);
    for name in ["Unknown TLS", "Past MySQL", "Past Oracle"] {
        assert!(connection(&collected, name).settings.ssl.is_none(), "{name}");
    }
}

#[test]
fn collect_keeps_preferred_for_a_driver_whose_form_has_no_tls_picker() {
    let collected = macos(CONNECTIONS_ONLY);
    assert_eq!(ssl_mode(&collected, "SQL Server TLS"), Some(ForeignSslMode::Preferred));
    assert_eq!(ssl_mode(&collected, "Snowflake TLS"), Some(ForeignSslMode::Preferred));
}

#[test]
fn collect_treats_empty_tls_paths_as_none() {
    let collected = macos(CONNECTIONS_ONLY);
    let ssl = connection(&collected, "Empty TLS").settings.ssl.clone().expect("TLS");
    assert_eq!(ssl.ca_certificate_path, None);
    assert_eq!(ssl.client_certificate_path, None);
    assert_eq!(ssl.client_key_path, None);
}

#[test]
fn collect_keeps_groups_walking_up_through_each_groups_parent() {
    let collected = macos(CONNECTIONS_ONLY);
    let path = |name: &str| connection(&collected, name).group_path.clone();
    assert_eq!(path("Prod DB"), ["Production"]);
    assert_eq!(path("Dev DB"), ["Development"]);
    assert_eq!(path("Replica DB"), ["Production", "Replicas"]);
    assert!(path("Ungrouped").is_empty());
    assert!(path("Lost Group DB").is_empty());
}

#[test]
fn collect_reads_the_port_from_text_or_a_number() {
    let collected = macos(CONNECTIONS_ONLY);
    assert_eq!(connection(&collected, "Custom Port").settings.port, 5433);
    assert_eq!(connection(&collected, "Integer Port").settings.port, 6543);
}

#[test]
fn collect_uses_the_engines_default_port_when_none_is_saved() {
    let collected = macos(CONNECTIONS_ONLY);
    let cases = [
        ("MySQL No Port", 3306),
        ("PG No Port", 5432),
        ("Mongo No Port", 27017),
        ("Redis No Port", 6379),
        ("SQL Server No Port", 1433),
        ("Cockroach No Port", 26257),
        ("Redshift No Port", 5439),
        ("Vertica No Port", 0),
    ];
    for (name, port) in cases {
        assert_eq!(connection(&collected, name).settings.port, port, "{name}");
    }
}

#[test]
fn collect_without_passwords_reads_no_keychain() {
    let keychain = Keychain::answering(&[("conn-1_database", Answer::Found("s3cret"))]);
    let collected = try_collect(
        ForeignPlatform::MacOs,
        &fixture("macos"),
        CONNECTIONS_ONLY,
        Some(Arc::clone(&keychain)),
    )
    .expect("an import");
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
    assert!(keychain.calls().is_empty());
}

#[test]
fn collect_with_an_empty_connection_list_finds_nothing() {
    let outcome = try_collect(ForeignPlatform::MacOs, &fixture("macos-empty"), CONNECTIONS_ONLY, None);
    assert!(matches!(outcome, Err(ForeignImportError::NothingFound)));
}

#[test]
fn collect_with_only_unnamed_connections_finds_nothing() {
    let outcome = try_collect(
        ForeignPlatform::MacOs,
        &fixture("macos-invalid"),
        CONNECTIONS_ONLY,
        None,
    );
    assert!(matches!(outcome, Err(ForeignImportError::NothingFound)));
    // Entries collect cannot read are not counted as found.
    let inventory = importer(ForeignPlatform::MacOs, &fixture("macos-invalid"), None).inventory_blocking();
    assert_eq!(inventory.connections, 0);
}

#[test]
fn collect_refuses_a_connection_file_that_is_not_a_list_of_dictionaries() {
    let home = writable("macos-empty");
    let file = home
        .path()
        .join("Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist");
    fs::write(&file, "not a plist").expect("a file");
    let outcome = try_collect(ForeignPlatform::MacOs, home.path(), CONNECTIONS_ONLY, None);
    assert!(matches!(outcome, Err(ForeignImportError::UnsupportedFormat { .. })));
    assert_eq!(
        importer(ForeignPlatform::MacOs, home.path(), None).inventory_blocking(),
        Inventory::default()
    );
}

#[test]
fn collect_maps_environments_to_colours() {
    let collected = macos(CONNECTIONS_ONLY);
    let color = |name: &str| connection(&collected, name).settings.color;
    assert_eq!(color("Staging"), Some(ForeignColor::Yellow));
    assert_eq!(color("Prod"), Some(ForeignColor::Red));
    assert_eq!(color("Test"), Some(ForeignColor::Blue));
    assert_eq!(color("Dev"), Some(ForeignColor::Green));
    assert_eq!(color("None"), None);
}

#[test]
fn collect_puts_a_file_path_in_the_field_its_engine_reads() {
    let collected = macos(CONNECTIONS_ONLY);
    let sqlite = connection(&collected, "Local SQLite");
    assert_eq!(sqlite.settings.database, "/Users/me/data.db");
    assert!(sqlite.settings.additional_fields.is_empty());

    let duckdb = connection(&collected, "Local DuckDB");
    assert_eq!(duckdb.settings.engine, "DuckDB");
    assert_eq!(field(duckdb, "duckdbFilePath"), Some("/Users/me/warehouse.duckdb"));
    assert_eq!(duckdb.settings.database, "");
    assert_eq!(duckdb.settings.port, 0);

    let server = connection(&collected, "Server Path");
    assert_eq!(server.settings.database, "sales");
    assert!(server.settings.additional_fields.is_empty());
}

#[test]
fn collect_reads_the_database_password_from_the_tableplus_keychain_service() {
    let keychain = Keychain::answering(&[("conn-1_database", Answer::Found("s3cret"))]);
    let collected = macos_with_keychain(&keychain);
    assert!(
        keychain
            .calls()
            .contains(&(SERVICE.to_owned(), "conn-1_database".to_owned()))
    );
    let credentials = connection(&collected, "Keychain DB")
        .credentials
        .as_ref()
        .expect("credentials");
    assert_eq!(exposed(credentials.password.as_ref()), Some("s3cret"));
    assert_eq!(collected.passwords, PasswordOutcome::Read);
}

#[test]
fn collect_asks_for_the_database_tunnel_and_key_passphrase_accounts() {
    let keychain = Keychain::answering(&[]);
    macos_with_keychain(&keychain);
    let expected: BTreeSet<String> = ["conn-1_database", "conn-1_server", "conn-1_server_key"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    assert_eq!(keychain.accounts_of("conn-1"), expected);
    assert!(keychain.calls().iter().all(|(service, _)| service == SERVICE));
}

#[test]
fn collect_leaves_credentials_empty_and_goes_on_when_nothing_is_stored() {
    let keychain = Keychain::answering(&[]);
    let collected = macos_with_keychain(&keychain);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
    assert_eq!(collected.passwords, PasswordOutcome::Read);
}

#[test]
fn collect_stops_reading_after_a_refused_keychain_prompt() {
    let keychain = Keychain::answering(&[("conn-1_database", Answer::Denied)]);
    let collected = macos_with_keychain(&keychain);
    assert_eq!(collected.passwords, PasswordOutcome::Stopped);
    assert_eq!(keychain.calls(), [(SERVICE.to_owned(), "conn-1_database".to_owned())]);
    assert_eq!(collected.connections.len(), 105);
}

#[test]
fn collect_carries_ask_every_time_and_command_line_across_as_a_prompt() {
    let collected = macos(CONNECTIONS_ONLY);
    assert_eq!(field(connection(&collected, "Ask"), "promptForPassword"), Some("true"));
    assert_eq!(
        field(connection(&collected, "Command"), "promptForPassword"),
        Some("true")
    );
    for name in ["Stored", "Absent", "Unknown", "No Password"] {
        assert_eq!(field(connection(&collected, name), "promptForPassword"), None, "{name}");
    }
}

#[test]
fn collect_keeps_the_local_file_path_beside_the_prompt() {
    let collected = macos(CONNECTIONS_ONLY);
    let libsql = connection(&collected, "libSQL Ask");
    assert_eq!(field(libsql, "libsqlFilePath"), Some("/Users/me/local.db"));
    assert_eq!(field(libsql, "promptForPassword"), Some("true"));
}

#[test]
fn collect_sets_no_prompt_where_the_engine_signs_in_its_own_way() {
    let collected = macos(CONNECTIONS_ONLY);
    let duckdb = connection(&collected, "DuckDB Ask");
    assert_eq!(field(duckdb, "duckdbFilePath"), Some("/Users/me/warehouse.duckdb"));
    assert_eq!(field(duckdb, "promptForPassword"), None);
    assert_eq!(field(connection(&collected, "DynamoDB Ask"), "promptForPassword"), None);
}

#[test]
fn collect_skips_the_keychain_for_a_database_password_tableplus_does_not_store() {
    let keychain = Keychain::answering(&[("pm-ask_database", Answer::Found("stale"))]);
    let collected = macos_with_keychain(&keychain);
    assert!(!keychain.accounts_of("pm-ask").contains("pm-ask_database"));
    let password = connection(&collected, "Ask")
        .credentials
        .as_ref()
        .and_then(|credentials| credentials.password.as_ref());
    assert!(password.is_none());
}

#[test]
fn collect_skips_the_tunnel_password_but_keeps_the_key_passphrase() {
    let keychain = Keychain::answering(&[
        ("pm-ask-ssh_server", Answer::Found("stale")),
        ("pm-ask-ssh_server_key", Answer::Found("passphrase")),
    ]);
    let collected = macos_with_keychain(&keychain);
    let expected: BTreeSet<String> = ["pm-ask-ssh_database", "pm-ask-ssh_server_key"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    assert_eq!(keychain.accounts_of("pm-ask-ssh"), expected);
    let credentials = connection(&collected, "Ask SSH")
        .credentials
        .as_ref()
        .expect("credentials");
    assert!(credentials.ssh_password.is_none());
    assert_eq!(exposed(credentials.key_passphrase.as_ref()), Some("passphrase"));
}

#[test]
fn collect_reads_the_keychain_for_a_mode_tableplus_has_not_shipped_yet() {
    let keychain = Keychain::answering(&[("pm-unknown_database", Answer::Found("s3cret"))]);
    let collected = macos_with_keychain(&keychain);
    let unknown = connection(&collected, "Unknown");
    let credentials = unknown.credentials.as_ref().expect("credentials");
    assert_eq!(exposed(credentials.password.as_ref()), Some("s3cret"));
    assert_eq!(field(unknown, "promptForPassword"), None);
}

#[test]
fn collect_carries_a_dynamodb_region_and_access_key_into_its_sign_in_fields() {
    let collected = macos(CONNECTIONS_ONLY);
    let orders = connection(&collected, "Orders");
    assert_eq!(orders.settings.engine, "DynamoDB");
    assert_eq!(field(orders, "awsRegion"), Some("eu-west-1"));
    assert_eq!(field(orders, "awsAccessKeyId"), Some("AKIAEXAMPLE"));
    assert_eq!(field(orders, "awsAuthMethod"), Some("credentials"));

    let no_region = connection(&collected, "Orders No Region");
    assert_eq!(field(no_region, "awsRegion"), None);
    assert_eq!(field(no_region, "awsAccessKeyId"), None);
    assert_eq!(field(no_region, "awsAuthMethod"), Some("credentials"));

    let shop = connection(&collected, "Shop");
    assert_eq!(field(shop, "awsRegion"), None);
    assert_eq!(field(shop, "awsAuthMethod"), None);
}

#[test]
fn collect_reads_every_favorite_as_a_global_query_under_the_tableplus_folder() {
    let collected = macos(WITH_SAVED_QUERIES);
    assert_eq!(
        query_names(&collected),
        BTreeSet::from(["tp_top", "tp_root_kw", "nested", "two.dots", "notes", "deep"])
    );

    let top = query(&collected, "tp_top").expect("tp_top");
    assert_eq!(text(top), "SELECT 1;");
    assert_eq!(top.keyword, None);
    assert_eq!(top.connection, None);
    assert_eq!(top.folder_path, ["TablePlus"]);
    assert_eq!(
        query(&collected, "tp_root_kw").expect("tp_root_kw").keyword.as_deref(),
        Some("kwone")
    );

    let nested = query(&collected, "nested").expect("nested");
    assert_eq!(text(nested), "-- c\nSELECT 3;\n");
    assert_eq!(nested.keyword.as_deref(), Some("kwnested"));
    assert_eq!(nested.folder_path, ["TablePlus", "Folder A"]);

    let deep = query(&collected, "deep").expect("deep");
    assert_eq!(text(deep), "SELECT 'Việt ✓';");
    assert_eq!(deep.folder_path, ["TablePlus", "Folder A", "Sub"]);

    assert!(collected.saved_queries.iter().all(|query| query.suggested));
}

#[test]
fn collect_keeps_the_first_keyword_of_the_tag_file_that_has_no_space() {
    let home = writable("macos");
    fs::write(
        home.path()
            .join("Library/Application Support/com.tinyapp.TablePlus/Data/Favorite/tp_top.sql.tag"),
        "Tp Space Kw,tpok,later",
    )
    .expect("a tag file");
    let collected = collect(ForeignPlatform::MacOs, home.path(), WITH_SAVED_QUERIES);
    assert_eq!(
        query(&collected, "tp_top").expect("tp_top").keyword.as_deref(),
        Some("tpok")
    );
    assert_eq!(
        query(&collected, "tp_root_kw").expect("tp_root_kw").keyword.as_deref(),
        Some("kwone")
    );
}

#[test]
fn a_favorite_over_the_size_limit_is_listed_by_size_only() {
    let home = writable("macos");
    let huge = "x".repeat(900_001);
    fs::write(
        home.path()
            .join("Library/Application Support/com.tinyapp.TablePlus/Data/Favorite/huge.sql"),
        huge,
    )
    .expect("a file");
    let collected = collect(ForeignPlatform::MacOs, home.path(), WITH_SAVED_QUERIES);
    let oversized = query(&collected, "huge").expect("huge");
    assert_eq!(oversized.content, SavedQueryContent::Oversized { byte_count: 900_001 });
    assert_eq!(oversized.folder_path, ["TablePlus"]);
    assert!(!oversized.suggested);
}

#[test]
fn the_setapp_edition_is_read_when_only_it_is_there() {
    let home = fixture("macos-setapp");
    let collected = collect(ForeignPlatform::MacOs, &home, WITH_SAVED_QUERIES);
    let names: Vec<&str> = collected
        .connections
        .iter()
        .map(|connection| connection.settings.name.as_str())
        .collect();
    assert_eq!(names, ["Setapp DB"]);
    assert_eq!(query_names(&collected), BTreeSet::from(["setapp", "shared"]));
}

#[test]
fn a_shared_favorites_folder_lands_under_its_own_name_inside_the_tableplus_folder() {
    let home = fixture("macos-setapp");
    let collected = collect(ForeignPlatform::MacOs, &home, WITH_SAVED_QUERIES);
    let shared = query(&collected, "shared").expect("shared");
    assert_eq!(shared.keyword.as_deref(), Some("kwshared"));
    assert_eq!(shared.folder_path, ["TablePlus", "tp_shared"]);
    let inventory = importer(ForeignPlatform::MacOs, &home, None).inventory_blocking();
    assert_eq!(
        inventory,
        Inventory {
            connections: 1,
            saved_queries: 2
        }
    );
}

#[test]
fn the_shared_connection_path_holds_the_connection_files_directly() {
    let collected = collect(ForeignPlatform::MacOs, &fixture("macos-shared"), CONNECTIONS_ONLY);
    assert_eq!(collected.connections.len(), 1);
    let moved = connection(&collected, "Moved DB");
    assert_eq!(moved.group_path, ["Moved"]);
}

#[test]
fn the_shared_query_path_moves_the_favorites_to_its_favorite_folder() {
    let collected = collect(ForeignPlatform::MacOs, &fixture("macos-shared"), WITH_SAVED_QUERIES);
    assert_eq!(query_names(&collected), BTreeSet::from(["custom"]));
}

#[test]
fn a_macos_keychain_left_unreachable_leaves_the_passwords_there() {
    let collected =
        try_collect(ForeignPlatform::MacOs, &fixture("macos-setapp"), WITH_PASSWORDS, None).expect("an import");
    assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
}

fn quoted(path: &Path) -> String {
    serde_json::to_string(path).expect("a path")
}

fn windows_home() -> tempfile::TempDir {
    let home = writable("windows");
    let base = home.path().join("AppData/Local/com.tinyapp.TablePlus");
    let sources = format!(
        r#"{{"sources":[{{"id":"local","name":"Local","path":{}}},{{"id":"team","name":"Team","path":{}}}]}}"#,
        quoted(&base.join("Data")),
        quoted(&home.path().join("Team")),
    );
    fs::write(base.join("ConnectionSources.json"), sources).expect("a file");
    let setting = format!(
        r#"{{"favorites":[{{"path":{}}}],"theme":1}}"#,
        quoted(&home.path().join("Team Queries"))
    );
    fs::write(base.join("Setting.json"), setting).expect("a file");
    home
}

#[test]
fn windows_reads_the_local_folder_then_every_listed_connection_source() {
    let home = windows_home();
    let collected = collect(ForeignPlatform::Windows, home.path(), CONNECTIONS_ONLY);
    let names: Vec<&str> = collected
        .connections
        .iter()
        .map(|connection| connection.settings.name.as_str())
        .collect();
    assert_eq!(
        names,
        ["Win MySQL", "Win SQLite", "Win DuckDB", "Win Postgres", "Team Redis"]
    );
    assert_eq!(connection(&collected, "Team Redis").group_path, ["Shared"]);
    assert_eq!(
        importer(ForeignPlatform::Windows, home.path(), None).inventory_blocking(),
        Inventory {
            connections: 5,
            saved_queries: 2
        }
    );
}

#[test]
fn windows_reads_integer_flags_nested_groups_and_the_macos_keys() {
    let home = windows_home();
    let collected = collect(ForeignPlatform::Windows, home.path(), CONNECTIONS_ONLY);
    let mysql = connection(&collected, "Win MySQL");
    assert_eq!(mysql.group_path, ["Servers", "EU"]);
    assert_eq!(mysql.settings.color, Some(ForeignColor::Red));
    let ssh = mysql.settings.ssh.as_ref().expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "C:\\Users\\me\\.ssh\\id_ed25519");
    let ssl = mysql.settings.ssl.as_ref().expect("TLS");
    assert_eq!(ssl.mode, ForeignSslMode::Required);
    assert_eq!(ssl.client_key_path.as_deref(), Some("C:\\tls\\client.key"));
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("C:\\tls\\ca.pem"));

    assert_eq!(
        connection(&collected, "Win SQLite").group_path,
        ["Servers", "EU", "Prod"]
    );
    let postgres = connection(&collected, "Win Postgres");
    assert_eq!(postgres.settings.engine, "PostgreSQL");
    assert_eq!(
        postgres.settings.ssl.as_ref().map(|ssl| ssl.mode),
        Some(ForeignSslMode::VerifyCa)
    );
    assert_eq!(field(postgres, "promptForPassword"), Some("true"));
}

#[test]
fn windows_keeps_a_file_engines_path_from_the_host_field() {
    let home = windows_home();
    let collected = collect(ForeignPlatform::Windows, home.path(), CONNECTIONS_ONLY);
    let sqlite = connection(&collected, "Win SQLite");
    assert_eq!(sqlite.settings.database, "C:\\data\\app.db");
    assert_eq!(sqlite.settings.host, "localhost");
    let duckdb = connection(&collected, "Win DuckDB");
    assert_eq!(field(duckdb, "duckdbFilePath"), Some("C:\\data\\lake.duckdb"));
    assert_eq!(duckdb.settings.port, 0);
}

#[test]
fn windows_reads_favorites_with_keywords_and_shared_folders() {
    let home = windows_home();
    let collected = collect(ForeignPlatform::Windows, home.path(), WITH_SAVED_QUERIES);
    let report = query(&collected, "report").expect("report");
    assert_eq!(report.keyword.as_deref(), Some("daily"));
    assert_eq!(report.folder_path, ["TablePlus"]);
    assert_eq!(
        query(&collected, "team").expect("team").folder_path,
        ["TablePlus", "Team Queries"]
    );
}

#[test]
fn windows_follows_the_shared_query_path_in_its_settings() {
    let home = windows_home();
    let setting = format!(r#"{{"sharedQueryPath":{}}}"#, quoted(&home.path().join("Queries")));
    fs::write(
        home.path().join("AppData/Local/com.tinyapp.TablePlus/Setting.json"),
        setting,
    )
    .expect("a file");
    let collected = collect(ForeignPlatform::Windows, home.path(), WITH_SAVED_QUERIES);
    assert_eq!(query_names(&collected), BTreeSet::from(["moved"]));
}

#[test]
fn windows_leaves_passwords_in_its_credential_store() {
    let home = windows_home();
    let keychain = Keychain::answering(&[]);
    let collected = try_collect(
        ForeignPlatform::Windows,
        home.path(),
        WITH_PASSWORDS,
        Some(Arc::clone(&keychain)),
    )
    .expect("an import");
    assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
    assert!(keychain.calls().is_empty());
}

#[test]
fn linux_reads_the_json_connections_with_their_nested_groups() {
    let collected = collect(ForeignPlatform::Linux, &fixture("linux"), CONNECTIONS_ONLY);
    assert_eq!(collected.connections.len(), 3);

    let postgres = connection(&collected, "Linux Postgres");
    assert_eq!(postgres.reference, "lx-1");
    assert_eq!(postgres.settings.engine, "PostgreSQL");
    assert_eq!(postgres.settings.host, "db.internal");
    assert_eq!(postgres.settings.port, 5433);
    assert_eq!(postgres.settings.username, "app");
    assert_eq!(postgres.settings.database, "shop");
    assert_eq!(postgres.group_path, ["Work", "Databases"]);
    let ssh = postgres.settings.ssh.as_ref().expect("a tunnel");
    assert_eq!(ssh.host, "bastion");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "/home/me/.ssh/id_ed25519");
    assert!(postgres.settings.ssl.is_none());
    // Its `ssl-mode` has no known meaning, so it is marked as TLS not read rather than dropped.
    assert_eq!(field(postgres, "tlsSettingsUnread"), Some("true"));
    assert_eq!(postgres.settings.color, None);

    let sqlite = connection(&collected, "Linux SQLite");
    assert_eq!(sqlite.settings.database, "/home/me/data.db");
    assert!(sqlite.settings.ssh.is_none());
    assert_eq!(field(sqlite, "tlsSettingsUnread"), None);

    let command = connection(&collected, "Linux Command");
    assert_eq!(command.settings.port, 3306);
    assert_eq!(field(command, "promptForPassword"), Some("true"));
}

#[test]
fn linux_reads_queries_without_keywords_and_its_shared_folders() {
    let home = writable("linux");
    let settings = format!(
        r#"{{"theme":2,"shared-folder-paths":[{}]}}"#,
        quoted(&home.path().join("Shared"))
    );
    fs::write(home.path().join(".tableplus/settings/settings.json"), settings).expect("a file");
    let collected = collect(ForeignPlatform::Linux, home.path(), WITH_SAVED_QUERIES);
    assert_eq!(query_names(&collected), BTreeSet::from(["daily", "monthly", "team"]));
    let monthly = query(&collected, "monthly").expect("monthly");
    assert_eq!(monthly.keyword, None);
    assert_eq!(monthly.folder_path, ["TablePlus", "Reports"]);
    assert_eq!(
        query(&collected, "team").expect("team").folder_path,
        ["TablePlus", "Shared"]
    );
}

#[test]
fn linux_leaves_passwords_in_the_secret_service() {
    let collected = try_collect(ForeignPlatform::Linux, &fixture("linux"), WITH_PASSWORDS, None).expect("an import");
    assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
    assert!(
        collected
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}
