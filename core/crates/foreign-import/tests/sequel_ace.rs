#![expect(
    clippy::expect_used,
    reason = "the fixture helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignHost, ForeignImportError,
    ForeignImporter, ForeignKeychain, ForeignPlatform, ForeignSshAuth, ForeignSslMode, ImportRequest, Inventory,
    KeychainRead, PasswordOutcome, PasswordSource, SavedQueryContent, SavedQuerySupport,
};
use tokio_util::sync::CancellationToken;

const LIMIT: u64 = 64 * 1024;

fn home(scenario: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("sequel_ace")
        .join(scenario)
        .join("macos")
}

#[derive(Default)]
struct Keychain {
    passwords: HashMap<(String, String), String>,
    denied: Option<(String, String)>,
    asked: Mutex<Vec<(String, String)>>,
}

impl Keychain {
    fn with(passwords: &[(&str, &str, &str)]) -> Self {
        Self {
            passwords: passwords
                .iter()
                .map(|(service, account, password)| {
                    (((*service).to_owned(), (*account).to_owned()), (*password).to_owned())
                })
                .collect(),
            ..Self::default()
        }
    }

    fn asked(&self) -> Vec<(String, String)> {
        self.asked.lock().expect("the lock").clone()
    }
}

impl ForeignKeychain for Keychain {
    fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead {
        let key = (service.to_owned(), account.unwrap_or_default().to_owned());
        self.asked.lock().expect("the lock").push(key.clone());
        if self.denied.as_ref() == Some(&key) {
            return KeychainRead::Denied;
        }
        match self.passwords.get(&key) {
            Some(password) => KeychainRead::Found(SecretString::from(password.clone())),
            None => KeychainRead::NotFound,
        }
    }
}

#[derive(Default)]
struct Host {
    installed: Option<bool>,
    keychain: Option<Arc<Keychain>>,
}

impl ForeignHost for Host {
    fn installed(&self, _app: ForeignApp) -> Option<bool> {
        self.installed
    }

    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        self.keychain
            .clone()
            .map(|keychain| keychain as Arc<dyn ForeignKeychain>)
    }
}

fn importer_on(platform: ForeignPlatform, home: &Path, host: Host) -> ForeignImporter {
    ForeignImporter::new(
        ForeignApp::SequelAce,
        ForeignAppDirs::conventional(platform, home),
        Arc::new(host),
    )
}

fn importer(home: &Path, host: Host) -> ForeignImporter {
    importer_on(ForeignPlatform::MacOs, home, host)
}

fn request(include_passwords: bool, include_saved_queries: bool) -> ImportRequest {
    ImportRequest {
        include_passwords,
        include_saved_queries,
        saved_query_byte_limit: LIMIT,
    }
}

fn collect_with(home: &Path, host: Host, request: &ImportRequest) -> Result<CollectedImport, ForeignImportError> {
    importer(home, host).collect_blocking(request, &CancellationToken::new())
}

fn collect(scenario: &str, request: &ImportRequest) -> CollectedImport {
    collect_with(&home(scenario), Host::default(), request).expect("an import")
}

fn connection<'a>(import: &'a CollectedImport, name: &str) -> &'a CollectedConnection {
    import
        .connections
        .iter()
        .find(|connection| connection.settings.name == name)
        .expect("the connection")
}

fn password(connection: &CollectedConnection) -> Option<&str> {
    connection
        .credentials
        .as_ref()
        .and_then(|credentials| credentials.password.as_ref())
        .map(ExposeSecret::expose_secret)
}

fn ssh_password(connection: &CollectedConnection) -> Option<&str> {
    connection
        .credentials
        .as_ref()
        .and_then(|credentials| credentials.ssh_password.as_ref())
        .map(ExposeSecret::expose_secret)
}

fn asked(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(service, account)| ((*service).to_owned(), (*account).to_owned()))
        .collect()
}

#[test]
fn the_app_is_known_by_its_id_and_reads_passwords_from_the_keychain() {
    let app = ForeignApp::SequelAce;
    assert_eq!(app.id(), "sequelace");
    assert_eq!(app.display_name(), "Sequel Ace");
    assert_eq!(ForeignApp::from_id("sequelace"), Some(app));
    assert_eq!(app.password_source(), PasswordSource::Keychain);
    assert_eq!(app.saved_query_support(), SavedQuerySupport::GlobalFolder);
    assert_eq!(app.picked_file_extensions(), None);
    assert!(app.runs_on(ForeignPlatform::MacOs));
    assert!(!app.runs_on(ForeignPlatform::Linux));
    assert!(!app.runs_on(ForeignPlatform::Windows));
}

#[test]
fn is_available_when_the_app_is_installed() {
    let empty = tempfile::tempdir().expect("a temp dir");
    let host = Host {
        installed: Some(true),
        ..Host::default()
    };
    assert!(importer(empty.path(), host).is_available_blocking());
}

#[test]
fn is_not_available_when_the_app_is_missing_even_with_a_favorites_file() {
    let host = Host {
        installed: Some(false),
        ..Host::default()
    };
    assert!(!importer(&home("full"), host).is_available_blocking());
}

#[test]
fn the_favorites_file_decides_when_the_platform_cannot_tell_if_the_app_is_installed() {
    let empty = tempfile::tempdir().expect("a temp dir");
    assert!(importer(&home("full"), Host::default()).is_available_blocking());
    assert!(!importer(empty.path(), Host::default()).is_available_blocking());
}

#[test]
fn nothing_is_read_off_macos() {
    let linux = importer_on(ForeignPlatform::Linux, &home("full"), Host::default());
    assert!(!linux.is_available_blocking());
    assert_eq!(linux.inventory_blocking(), Inventory::default());
    let outcome = linux.collect_blocking(&request(false, true), &CancellationToken::new());
    assert!(matches!(
        outcome,
        Err(ForeignImportError::FileNotFound {
            app: ForeignApp::SequelAce
        })
    ));
}

#[test]
fn inventory_counts_connections_in_every_group_and_query_favorites_with_text() {
    let inventory = importer(&home("full"), Host::default()).inventory_blocking();
    assert_eq!(
        inventory,
        Inventory {
            connections: 7,
            saved_queries: 2,
        }
    );
}

#[test]
fn inventory_is_empty_when_the_files_are_missing() {
    let empty = tempfile::tempdir().expect("a temp dir");
    assert_eq!(
        importer(empty.path(), Host::default()).inventory_blocking(),
        Inventory::default()
    );
}

#[test]
fn collect_reads_every_connection_as_mysql() {
    let import = collect("full", &request(false, false));
    assert_eq!(import.app, ForeignApp::SequelAce);
    assert_eq!(import.connections.len(), 7);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.settings.engine == "MySQL")
    );
}

#[test]
fn an_empty_group_adds_nothing() {
    let import = collect("full", &request(false, false));
    let names: Vec<&str> = import
        .connections
        .iter()
        .map(|connection| connection.settings.name.as_str())
        .collect();
    assert_eq!(
        names,
        [
            "Prod Main",
            "Prod Replica",
            "Local",
            "Staging EU",
            "Socket DB",
            "Unnamed Member",
            "Key By Name"
        ]
    );
}

#[test]
fn connections_are_keyed_by_their_sequel_ace_id() {
    let import = collect("full", &request(false, false));
    let references: Vec<&str> = import
        .connections
        .iter()
        .map(|connection| connection.reference.as_str())
        .collect();
    assert_eq!(
        references,
        ["1", "2", "42", "staging-eu", "-5034467137374584238", "4", "5"]
    );
}

#[test]
fn groups_keep_their_full_path_and_a_nameless_group_is_untitled() {
    let import = collect("full", &request(false, false));
    let paths: Vec<Vec<String>> = import
        .connections
        .iter()
        .map(|connection| connection.group_path.clone())
        .collect();
    let expected: [&[&str]; 7] = [
        &["Production"],
        &["Production"],
        &[],
        &["Staging", "EU"],
        &[],
        &["Untitled Group"],
        &["Untitled Group"],
    ];
    assert_eq!(
        paths,
        expected.map(|path| path.iter().map(|name| (*name).to_owned()).collect::<Vec<_>>())
    );
}

#[test]
fn an_ssh_connection_reads_its_tunnel_with_a_key() {
    let import = collect("full", &request(false, false));
    let replica = connection(&import, "Prod Replica");
    let ssh = replica.settings.ssh.as_ref().expect("a tunnel");
    assert_eq!(ssh.host, "bastion.example.com");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.username, "deploy");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "~/.ssh/id_ed25519");
    assert!(ssh.jump_hosts.is_empty());
    assert_eq!(replica.settings.host, "10.0.0.5");
    assert_eq!(replica.settings.port, 3307);
    assert_eq!(replica.settings.username, "replica");
    assert_eq!(replica.settings.database, "shop");
}

#[test]
fn an_ssh_tunnel_without_a_key_uses_password_auth() {
    let import = collect("full", &request(false, false));
    let ssh = connection(&import, "Staging EU")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::Password);
    assert_eq!(ssh.private_key_path, "");
    assert_eq!(ssh.username, "admin");
}

#[test]
fn an_ssh_port_reads_from_a_number_or_a_string() {
    let import = collect("full", &request(false, false));
    let port = |name: &str| connection(&import, name).settings.ssh.as_ref().expect("a tunnel").port;
    assert_eq!(port("Prod Replica"), Some(2222));
    assert_eq!(port("Staging EU"), Some(3333));
    assert_eq!(port("Key By Name"), None);
}

#[test]
fn a_bare_key_name_is_read_from_the_ssh_folder() {
    let import = collect("full", &request(false, false));
    let ssh = connection(&import, "Key By Name")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "~/.ssh/id_rsa");
}

#[test]
fn a_tcp_or_socket_connection_has_no_tunnel() {
    let import = collect("full", &request(false, false));
    assert!(connection(&import, "Local").settings.ssh.is_none());
    let socket = connection(&import, "Socket DB");
    assert!(socket.settings.ssh.is_none());
    assert_eq!(socket.settings.engine, "MySQL");
}

#[test]
fn ssl_is_required_with_its_certificate_paths() {
    let import = collect("full", &request(false, false));
    let ssl = connection(&import, "Prod Main").settings.ssl.as_ref().expect("ssl");
    assert_eq!(ssl.mode, ForeignSslMode::Required);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/path/to/ca.pem"));
    assert_eq!(ssl.client_certificate_path.as_deref(), Some("/path/to/client-cert.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/path/to/client-key.pem"));
}

#[test]
fn a_boolean_use_ssl_turns_ssl_on() {
    let import = collect("full", &request(false, false));
    let ssl = connection(&import, "Staging EU").settings.ssl.as_ref().expect("ssl");
    assert_eq!(ssl.mode, ForeignSslMode::Required);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some(""));
}

#[test]
fn there_is_no_ssl_when_use_ssl_is_zero() {
    let import = collect("full", &request(false, false));
    assert!(connection(&import, "Local").settings.ssl.is_none());
}

#[test]
fn an_empty_port_falls_back_to_the_mysql_default() {
    let import = collect("full", &request(false, false));
    let local = connection(&import, "Local");
    assert_eq!(local.settings.port, 3306);
    assert_eq!(local.settings.host, "127.0.0.1");
    assert_eq!(local.settings.database, "");
}

#[test]
fn a_colour_index_maps_to_a_colour() {
    let import = collect("colors", &request(false, false));
    let colors: Vec<Option<ForeignColor>> = import
        .connections
        .iter()
        .map(|connection| connection.settings.color)
        .collect();
    assert_eq!(
        colors,
        [
            Some(ForeignColor::Red),
            Some(ForeignColor::Orange),
            Some(ForeignColor::Yellow),
            Some(ForeignColor::Green),
            Some(ForeignColor::Blue),
            Some(ForeignColor::Purple),
            Some(ForeignColor::Pink),
            Some(ForeignColor::Gray),
            None,
            None,
        ]
    );
}

#[test]
fn empty_favorites_have_nothing_to_import() {
    let outcome = collect_with(&home("empty"), Host::default(), &request(false, false));
    assert!(matches!(outcome, Err(ForeignImportError::NothingFound)));
}

#[test]
fn a_missing_favorites_file_is_not_found() {
    let empty = tempfile::tempdir().expect("a temp dir");
    let outcome = collect_with(empty.path(), Host::default(), &request(false, false));
    assert!(matches!(
        outcome,
        Err(ForeignImportError::FileNotFound {
            app: ForeignApp::SequelAce
        })
    ));
}

#[test]
fn a_favorites_file_that_is_not_a_property_list_fails_to_parse() {
    let outcome = collect_with(&home("corrupt"), Host::default(), &request(false, false));
    assert!(matches!(outcome, Err(ForeignImportError::Parse { .. })));
}

#[test]
fn favorites_without_a_root_are_an_unsupported_format() {
    let outcome = collect_with(&home("no-root"), Host::default(), &request(false, false));
    assert!(matches!(outcome, Err(ForeignImportError::UnsupportedFormat { .. })));
}

#[test]
fn without_passwords_no_keychain_item_is_read() {
    let keychain = Arc::new(Keychain::with(&[(
        "Sequel Ace : Prod Main (1)",
        "root@prod.example.com/shop",
        "x",
    )]));
    let host = Host {
        installed: None,
        keychain: Some(Arc::clone(&keychain)),
    };
    let import = collect_with(&home("full"), host, &request(false, false)).expect("an import");
    assert_eq!(import.passwords, PasswordOutcome::NotRequested);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
    assert!(keychain.asked().is_empty());
}

#[test]
fn passwords_are_read_under_the_apps_keychain_service_and_account() {
    let keychain = Arc::new(Keychain::with(&[
        (
            "Sequel Ace : Prod Main (1)",
            "root@prod.example.com/shop",
            "prod-secret",
        ),
        (
            "Sequel Ace SSHTunnel : Prod Replica (2)",
            "deploy@bastion.example.com",
            "tunnel-secret",
        ),
        (
            "Sequel Ace : Socket DB (-5034467137374584238)",
            "root@localhost/",
            "socket-secret",
        ),
    ]));
    let host = Host {
        installed: None,
        keychain: Some(Arc::clone(&keychain)),
    };
    let import = collect_with(&home("full"), host, &request(true, false)).expect("an import");

    assert_eq!(import.passwords, PasswordOutcome::Read);
    assert_eq!(password(connection(&import, "Prod Main")), Some("prod-secret"));
    let replica = connection(&import, "Prod Replica");
    assert_eq!(password(replica), None);
    assert_eq!(ssh_password(replica), Some("tunnel-secret"));
    assert_eq!(password(connection(&import, "Socket DB")), Some("socket-secret"));
    assert!(connection(&import, "Local").credentials.is_none());
    assert_eq!(
        keychain.asked(),
        asked(&[
            ("Sequel Ace : Prod Main (1)", "root@prod.example.com/shop"),
            ("Sequel Ace : Prod Replica (2)", "replica@10.0.0.5/shop"),
            ("Sequel Ace SSHTunnel : Prod Replica (2)", "deploy@bastion.example.com"),
            ("Sequel Ace : Local (42)", "root@127.0.0.1/"),
            ("Sequel Ace : Staging EU (staging-eu)", "app@staging.internal/staging"),
            (
                "Sequel Ace SSHTunnel : Staging EU (staging-eu)",
                "admin@bastion.eu.example.com"
            ),
            ("Sequel Ace : Socket DB (-5034467137374584238)", "root@localhost/"),
            ("Sequel Ace : Unnamed Member (4)", "root@member.example.com/"),
            ("Sequel Ace : Key By Name (5)", "root@keyed.internal/"),
            ("Sequel Ace SSHTunnel : Key By Name (5)", "ops@jump.example.com"),
        ])
    );
}

#[test]
fn a_refused_keychain_prompt_stops_every_later_read() {
    let mut keychain = Keychain::with(&[(
        "Sequel Ace : Prod Main (1)",
        "root@prod.example.com/shop",
        "prod-secret",
    )]);
    keychain.denied = Some((
        "Sequel Ace : Prod Replica (2)".to_owned(),
        "replica@10.0.0.5/shop".to_owned(),
    ));
    let keychain = Arc::new(keychain);
    let host = Host {
        installed: None,
        keychain: Some(Arc::clone(&keychain)),
    };
    let import = collect_with(&home("full"), host, &request(true, false)).expect("an import");

    assert_eq!(import.passwords, PasswordOutcome::Stopped);
    assert_eq!(password(connection(&import, "Prod Main")), Some("prod-secret"));
    assert_eq!(
        import
            .connections
            .iter()
            .filter(|connection| connection.credentials.is_some())
            .count(),
        1
    );
    assert_eq!(
        keychain.asked(),
        asked(&[
            ("Sequel Ace : Prod Main (1)", "root@prod.example.com/shop"),
            ("Sequel Ace : Prod Replica (2)", "replica@10.0.0.5/shop"),
        ])
    );
}

#[test]
fn passwords_stay_in_a_keychain_the_platform_cannot_read() {
    let import = collect("full", &request(true, false));
    assert_eq!(import.passwords, PasswordOutcome::LeftInKeychain);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn query_favorites_are_global_queries_with_placeholders_verbatim_and_the_tab_trigger_as_keyword() {
    let import = collect("full", &request(false, true));
    let names: Vec<&str> = import.saved_queries.iter().map(|query| query.name.as_str()).collect();
    assert_eq!(names, ["Recent orders", "Plain"]);

    let recent = &import.saved_queries[0];
    assert_eq!(
        recent.content,
        SavedQueryContent::Text("SELECT * FROM orders WHERE id > ${1:x};".to_owned())
    );
    assert_eq!(recent.keyword.as_deref(), Some("ro"));
    assert_eq!(recent.connection, None);
    assert_eq!(recent.folder_path, ["Sequel Ace"]);
    assert!(recent.suggested);
    assert_eq!(import.saved_queries[1].keyword, None);
}

#[test]
fn a_query_favorite_over_the_size_limit_is_listed_by_size() {
    let small = ImportRequest {
        saved_query_byte_limit: 10,
        ..request(false, true)
    };
    let import = collect("full", &small);
    let recent = &import.saved_queries[0];
    assert_eq!(
        recent.content,
        SavedQueryContent::Oversized {
            byte_count: "SELECT * FROM orders WHERE id > ${1:x};".len() as u64
        }
    );
    assert!(!recent.suggested);
    assert_eq!(
        import.saved_queries[1].content,
        SavedQueryContent::Text("SELECT 1;".to_owned())
    );
}

#[test]
fn query_favorites_are_read_only_when_saved_queries_are_requested() {
    let import = collect("full", &request(false, false));
    assert!(import.saved_queries.is_empty());
}

#[test]
fn a_missing_preferences_file_means_no_query_favorites() {
    let import = collect("colors", &request(false, true));
    assert_eq!(import.connections.len(), 10);
    assert!(import.saved_queries.is_empty());
}

#[test]
fn reading_stops_when_cancelled() {
    let cancel = CancellationToken::new();
    cancel.cancel();
    let outcome = importer(&home("full"), Host::default()).collect_blocking(&request(false, true), &cancel);
    assert!(matches!(outcome, Err(ForeignImportError::Cancelled)));
}
