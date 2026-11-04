#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, CollectedSavedQuery, ForeignApp, ForeignAppDirs, ForeignHost,
    ForeignImportError, ForeignImporter, ForeignKeychain, ForeignPlatform, ForeignSshAuth, ForeignSslMode,
    ImportRequest, Inventory, KeychainRead, PasswordOutcome, PasswordSource, PlainHost, SavedQueryContent,
    SavedQuerySupport,
};
use tokio_util::sync::CancellationToken;

const SHOP: &str = "11111111-1111-4111-8111-111111111111";
const MONGO: &str = "33333333-3333-4333-8333-333333333333";

#[derive(Default)]
struct Keychain {
    secrets: HashMap<String, KeychainRead>,
    deny_all: bool,
    reads: Mutex<Vec<(String, Option<String>)>>,
}

impl ForeignKeychain for Keychain {
    fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead {
        self.reads
            .lock()
            .expect("a lock")
            .push((service.to_owned(), account.map(str::to_owned)));
        if self.deny_all {
            return KeychainRead::Denied;
        }
        self.secrets.get(service).cloned().unwrap_or(KeychainRead::NotFound)
    }
}

impl Keychain {
    fn reads(&self) -> Vec<(String, Option<String>)> {
        self.reads.lock().expect("a lock").clone()
    }
}

struct Host {
    keychain: Arc<Keychain>,
}

impl ForeignHost for Host {
    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        Some(self.keychain.clone())
    }
}

fn fixture(scenario: &str, platform: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/datagrip")
        .join(scenario)
        .join(platform)
}

fn importer(dirs: ForeignAppDirs, host: Arc<dyn ForeignHost>) -> ForeignImporter {
    ForeignImporter::new(ForeignApp::DataGrip, dirs, host)
}

fn mac(scenario: &str, keychain: Arc<Keychain>) -> ForeignImporter {
    importer(
        ForeignAppDirs::conventional(ForeignPlatform::MacOs, &fixture(scenario, "macos")),
        Arc::new(Host { keychain }),
    )
}

fn plain(home: &Path, platform: ForeignPlatform) -> ForeignImporter {
    importer(ForeignAppDirs::conventional(platform, home), Arc::new(PlainHost))
}

fn request(include_passwords: bool, include_saved_queries: bool) -> ImportRequest {
    ImportRequest {
        include_passwords,
        include_saved_queries,
        saved_query_byte_limit: 1_000_000,
    }
}

fn collect(importer: &ForeignImporter, request: ImportRequest) -> CollectedImport {
    importer
        .collect_blocking(&request, &CancellationToken::new())
        .expect("an import")
}

fn connection<'a>(import: &'a CollectedImport, name: &str) -> &'a CollectedConnection {
    import
        .connections
        .iter()
        .find(|connection| connection.settings.name == name)
        .expect("a connection")
}

fn names(import: &CollectedImport) -> Vec<&str> {
    import
        .connections
        .iter()
        .map(|connection| connection.settings.name.as_str())
        .collect()
}

fn query<'a>(import: &'a CollectedImport, name: &str, connection: Option<&str>) -> Option<&'a CollectedSavedQuery> {
    import
        .saved_queries
        .iter()
        .find(|query| query.name == name && query.connection.as_deref() == connection)
}

fn text(query: &CollectedSavedQuery) -> &str {
    match &query.content {
        SavedQueryContent::Text(text) => text,
        SavedQueryContent::Oversized { .. } => panic!("expected text"),
    }
}

fn secret(value: Option<&SecretString>) -> Option<&str> {
    value.map(ExposeSecret::expose_secret)
}

fn connections_import(keychain: Arc<Keychain>) -> CollectedImport {
    collect(&mac("connections", keychain), request(false, false))
}

#[test]
fn datagrip_reads_passwords_from_a_keychain_and_consoles_as_saved_queries() {
    assert_eq!(ForeignApp::from_id("datagrip"), Some(ForeignApp::DataGrip));
    assert_eq!(ForeignApp::DataGrip.display_name(), "DataGrip");
    assert_eq!(ForeignApp::DataGrip.password_source(), PasswordSource::Keychain);
    assert_eq!(ForeignApp::DataGrip.saved_query_support(), SavedQuerySupport::Consoles);
}

#[test]
fn an_empty_home_has_nothing_and_an_import_finds_no_files() {
    let home = tempfile::tempdir().expect("a temp dir");
    for platform in [ForeignPlatform::MacOs, ForeignPlatform::Linux, ForeignPlatform::Windows] {
        let importer = plain(home.path(), platform);
        assert_eq!(importer.inventory_blocking(), Inventory::default());
        assert!(!importer.is_available_blocking());
        let outcome = importer.collect_blocking(&request(true, true), &CancellationToken::new());
        assert!(matches!(
            outcome,
            Err(ForeignImportError::FileNotFound {
                app: ForeignApp::DataGrip
            })
        ));
    }
}

#[test]
fn the_inventory_counts_unique_data_sources() {
    let importer = mac("connections", Arc::default());
    assert!(importer.is_available_blocking());
    assert_eq!(
        importer.inventory_blocking(),
        Inventory {
            connections: 13,
            saved_queries: 0
        }
    );
}

#[test]
fn driver_refs_map_to_engines() {
    let import = connections_import(Arc::default());
    for (name, engine) in [
        ("my", "MySQL"),
        ("pg", "PostgreSQL"),
        ("ms", "SQL Server"),
        ("or", "Oracle"),
        ("lt", "SQLite"),
    ] {
        assert_eq!(connection(&import, name).settings.engine, engine, "{name}");
    }
}

#[test]
fn host_port_and_database_come_from_the_jdbc_url() {
    let import = connections_import(Arc::default());
    let settings = &connection(&import, "my").settings;
    assert_eq!(settings.host, "db.example.com");
    assert_eq!(settings.port, 3307);
    assert_eq!(settings.database, "shop");
    assert_eq!(settings.username, "root");
}

#[test]
fn a_url_without_a_port_takes_the_engines_default_port() {
    let import = connections_import(Arc::default());
    assert_eq!(connection(&import, "pg").settings.port, 5432);
}

#[test]
fn a_portless_redshift_url_takes_the_redshift_default_port() {
    let import = connections_import(Arc::default());
    let settings = &connection(&import, "rs").settings;
    assert_eq!(settings.engine, "Redshift");
    assert_eq!(settings.port, 5439);
}

#[test]
fn sqlite_keeps_its_file_path_as_the_database() {
    let import = connections_import(Arc::default());
    let settings = &connection(&import, "lt").settings;
    assert_eq!(settings.engine, "SQLite");
    assert_eq!(settings.database, "/Users/me/app.db");
}

#[test]
fn ssh_joins_the_config_from_the_local_file_infers_key_auth_and_expands_user_home() {
    let home = fixture("connections", "macos");
    let import = connections_import(Arc::default());
    let settings = &connection(&import, "ssh_key").settings;
    assert_eq!(settings.username, "appuser");
    let ssh = settings.ssh.as_ref().expect("ssh");
    assert_eq!(ssh.host, "bastion.example.com");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.username, "deploy");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, format!("{}/.ssh/id_ed25519", home.display()));
}

#[test]
fn an_explicit_password_auth_wins_over_a_key_path() {
    let import = connections_import(Arc::default());
    let ssh = connection(&import, "ssh_password").settings.ssh.as_ref().expect("ssh");
    assert_eq!(ssh.auth, ForeignSshAuth::Password);
    assert_eq!(ssh.private_key_path, "");
}

#[test]
fn disabled_ssh_properties_give_no_tunnel() {
    let import = connections_import(Arc::default());
    assert_eq!(connection(&import, "ssh_off").settings.ssh, None);
}

#[test]
fn ssh_and_ssl_the_local_file_disables_drop_what_the_shared_file_enables() {
    let import = collect(&mac("local-disables", Arc::default()), request(false, false));
    let off = &connection(&import, "turned_off").settings;
    assert_eq!(off.ssh, None);
    // With "Use SSL" off pgjdbc's own default applies, not the shared file's REQUIRE.
    assert_eq!(off.ssl.as_ref().map(|ssl| ssl.mode), Some(ForeignSslMode::Preferred));
    assert!(off.additional_fields.contains_key("tlsFromDriverDefault"));
    let on = &connection(&import, "left_on").settings;
    assert_eq!(
        on.ssh.as_ref().map(|ssh| ssh.host.as_str()),
        Some("bastion.example.com")
    );
    assert_eq!(on.ssl.as_ref().map(|ssl| ssl.mode), Some(ForeignSslMode::Required));
}

#[test]
fn with_use_ssl_off_each_jdbc_driver_s_own_tls_default_is_imported() {
    let import = collect(
        &plain(&fixture("tls-defaults", "linux"), ForeignPlatform::Linux),
        request(false, false),
    );
    let defaulted = Some("tlsFromDriverDefault");
    let unread = Some("tlsSettingsUnread");
    let cases = [
        ("pg_default", Some(ForeignSslMode::Preferred), defaulted),
        ("pg_ssl_off", Some(ForeignSslMode::Preferred), defaulted),
        ("mysql_default", Some(ForeignSslMode::Preferred), defaulted),
        ("mssql_default", Some(ForeignSslMode::VerifyIdentity), defaulted),
        ("mssql_trusting_url", None, unread),
        ("pg_property_off", None, unread),
        ("mariadb_default", None, None),
        ("jtds_default", None, None),
    ];
    for (name, mode, marker) in cases {
        let settings = &connection(&import, name).settings;
        assert_eq!(settings.ssl.as_ref().map(|ssl| ssl.mode), mode, "{name}");
        let markers: Vec<&str> = settings
            .additional_fields
            .keys()
            .map(String::as_str)
            .filter(|key| ["tlsFromDriverDefault", "tlsSettingsUnread"].contains(key))
            .collect();
        assert_eq!(markers, marker.into_iter().collect::<Vec<_>>(), "{name}");
    }
}

#[test]
fn an_ssh_password_is_imported_from_c_kdbx() {
    let import = collect(&mac("connections", Arc::default()), request(true, false));
    let credentials = connection(&import, "ssh_kdbx")
        .credentials
        .as_ref()
        .expect("credentials");
    assert_eq!(secret(credentials.ssh_password.as_ref()), Some("ssh-pw"));
    assert_eq!(import.passwords, PasswordOutcome::Read);
}

#[test]
fn a_user_name_from_the_local_file_fills_the_shared_one() {
    let import = connections_import(Arc::default());
    assert_eq!(connection(&import, "user_local").settings.username, "postgres");
}

#[test]
fn ssl_config_comes_from_the_local_file_with_user_home_expanded() {
    let home = fixture("connections", "macos");
    let import = connections_import(Arc::default());
    let ssl = connection(&import, "tls").settings.ssl.as_ref().expect("ssl");
    assert_eq!(ssl.mode, ForeignSslMode::VerifyIdentity);
    let expected = |file: &str| Some(format!("{}/certs/{file}", home.display()));
    assert_eq!(ssl.ca_certificate_path, expected("ca.pem"));
    assert_eq!(ssl.client_certificate_path, expected("client.crt"));
    assert_eq!(ssl.client_key_path, expected("client.key"));
}

#[test]
fn the_group_name_becomes_a_group_and_the_uuid_the_reference() {
    let import = connections_import(Arc::default());
    let first = &import.connections[0];
    assert_eq!(first.settings.name, "my");
    assert_eq!(first.group_path, ["Production"]);
    assert_eq!(first.reference, "1");
}

#[test]
fn data_sources_sharing_a_uuid_import_once() {
    let import = connections_import(Arc::default());
    let copies: Vec<&CollectedConnection> = import
        .connections
        .iter()
        .filter(|connection| connection.reference.starts_with("dup"))
        .collect();
    assert_eq!(copies.len(), 1);
    assert_eq!(copies[0].settings.name, "A copy");
}

#[test]
fn the_keychain_is_asked_by_service_name_alone_before_c_kdbx() {
    let keychain = Arc::new(Keychain {
        secrets: HashMap::from([(
            "IntelliJ Platform DB \u{2014} 1".to_owned(),
            KeychainRead::Found(SecretString::from("kc-secret")),
        )]),
        ..Keychain::default()
    });
    let import = collect(&mac("connections", keychain.clone()), request(true, false));
    let password = |name: &str| {
        secret(
            connection(&import, name)
                .credentials
                .as_ref()
                .and_then(|credentials| credentials.password.as_ref()),
        )
        .map(str::to_owned)
    };
    assert_eq!(password("my").as_deref(), Some("kc-secret"));
    assert_eq!(password("pg").as_deref(), Some("pg-from-kdbx"));
    assert_eq!(password("ms"), None);
    assert_eq!(import.passwords, PasswordOutcome::Read);
    let reads = keychain.reads();
    assert_eq!(reads[0], ("IntelliJ Platform DB \u{2014} 1".to_owned(), None));
    assert!(reads.iter().all(|(_, account)| account.is_none()));
    assert!(reads.contains(&(
        "IntelliJ Platform SshConfigPassphrase \u{2014} bastion.example.com:2222 SSH1".to_owned(),
        None
    )));
}

#[test]
fn a_refused_keychain_stops_reading_passwords() {
    let keychain = Arc::new(Keychain {
        deny_all: true,
        ..Keychain::default()
    });
    let import = collect(&mac("connections", keychain.clone()), request(true, false));
    assert_eq!(import.passwords, PasswordOutcome::Stopped);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
    assert_eq!(keychain.reads().len(), 1);
}

#[test]
fn no_password_is_read_unless_requested() {
    let keychain = Arc::new(Keychain::default());
    let import = collect(&mac("connections", keychain.clone()), request(false, false));
    assert_eq!(import.passwords, PasswordOutcome::NotRequested);
    assert!(keychain.reads().is_empty());
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn a_cancelled_import_stops() {
    let cancel = CancellationToken::new();
    cancel.cancel();
    let outcome = mac("connections", Arc::default()).collect_blocking(&request(true, true), &cancel);
    assert!(matches!(outcome, Err(ForeignImportError::Cancelled)));
}

#[test]
fn consoles_come_from_each_data_sources_newest_config_dir() {
    let import = collect(&mac("consoles", Arc::default()), request(false, true));
    let mut shop: Vec<&str> = import
        .saved_queries
        .iter()
        .filter(|query| query.connection.as_deref() == Some(SHOP))
        .map(|query| query.name.as_str())
        .collect();
    shop.sort_unstable();
    assert_eq!(
        shop,
        [
            "Console_7",
            "console",
            "console_1",
            "dg_sample_monthly",
            "dg_sample_report"
        ]
    );
    let report = query(&import, "dg_sample_report", Some(SHOP)).expect("a report");
    assert_eq!(text(report), "select * from dg_sample_items;");
    assert!(query(&import, "dg_sample_legacy", Some(SHOP)).is_none());
    let monthly = query(&import, "dg_sample_monthly", Some(SHOP)).expect("a monthly report");
    assert_eq!(monthly.folder_path, ["reports"]);
}

#[test]
fn default_console_names_start_unchecked_and_user_named_ones_checked() {
    let import = collect(&mac("consoles", Arc::default()), request(false, true));
    for name in ["console", "console_1", "Console_7"] {
        assert!(
            !query(&import, name, Some(SHOP)).expect("a console").suggested,
            "{name}"
        );
    }
    for name in ["dg_sample_report", "dg_sample_monthly"] {
        assert!(query(&import, name, Some(SHOP)).expect("a console").suggested, "{name}");
    }
}

#[test]
fn js_consoles_are_read_only_for_a_mongodb_data_source() {
    let import = collect(&mac("consoles", Arc::default()), request(false, true));
    let mongo = query(&import, "console", Some(MONGO)).expect("a mongo console");
    assert_eq!(text(mongo), "db.dg_sample_items.find()");
    assert!(!mongo.suggested);
    assert!(query(&import, "script", Some(SHOP)).is_none());
}

#[test]
fn a_data_source_that_imports_no_connection_keeps_its_consoles_global_and_unchecked() {
    let import = collect(&mac("consoles", Arc::default()), request(false, true));
    assert_eq!(names(&import), ["dg_sample_shop", "dg_sample_mongo"]);
    let unmapped = query(&import, "dg_unmapped_query", None).expect("an unmapped console");
    assert_eq!(unmapped.folder_path, ["DataGrip"]);
    assert!(!unmapped.suggested);
}

#[test]
fn orphan_folders_history_scratches_hidden_blank_and_foreign_files_are_skipped() {
    let import = collect(&mac("consoles", Arc::default()), request(false, true));
    let found: Vec<&str> = import.saved_queries.iter().map(|query| query.name.as_str()).collect();
    for skipped in ["dg_sample_orphan", "scratch", "console_3", "notes", ".hidden_console"] {
        assert!(!found.contains(&skipped), "{skipped}");
    }
    assert!(!import.saved_queries.iter().any(|query| text(query).contains("history")));
    assert_eq!(import.saved_queries.len(), 7);
}

#[test]
fn a_data_source_uuid_that_is_not_a_uuid_never_becomes_a_console_path() {
    let import = collect(&mac("escape", Arc::default()), request(false, true));
    assert_eq!(names(&import), ["dg_sample_escape"]);
    assert!(import.saved_queries.is_empty());
}

#[test]
fn a_custom_default_file_name_decides_which_consoles_are_auto_named() {
    let import = collect(&mac("scratches-name", Arc::default()), request(false, true));
    assert!(!query(&import, "dg_sample_q", Some(SHOP)).expect("a console").suggested);
    assert!(
        !query(&import, "dg_sample_q_2", Some(SHOP))
            .expect("a console")
            .suggested
    );
    assert!(query(&import, "console", Some(SHOP)).expect("a console").suggested);
}

#[test]
fn no_consoles_are_read_unless_saved_queries_are_requested() {
    let import = collect(&mac("consoles", Arc::default()), request(false, false));
    assert!(import.saved_queries.is_empty());
}

#[test]
fn the_inventory_counts_consoles_that_have_text() {
    assert_eq!(
        mac("consoles", Arc::default()).inventory_blocking(),
        Inventory {
            connections: 2,
            saved_queries: 7
        }
    );
}

#[test]
fn linux_reads_the_config_folder_projects_recent_projects_and_the_flatpak_folder() {
    let import = collect(
        &plain(&fixture("roots", "linux"), ForeignPlatform::Linux),
        request(false, false),
    );
    assert_eq!(
        names(&import),
        [
            "shared_new",
            "flatpak_only",
            "pg_native",
            "default_project",
            "project_source"
        ]
    );
    assert_eq!(connection(&import, "shared_new").settings.host, "new.example.com");
    let project = &connection(&import, "project_source").settings;
    assert_eq!(project.engine, "MariaDB");
    assert_eq!(project.username, "shop_user");
}

#[test]
fn a_custom_xdg_config_folder_is_searched_first_and_wins_a_tie() {
    let home = fixture("roots", "linux");
    let dirs = ForeignAppDirs {
        config: home.join("xdg-config"),
        ..ForeignAppDirs::conventional(ForeignPlatform::Linux, &home)
    };
    let import = collect(&importer(dirs, Arc::new(PlainHost)), request(false, false));
    assert_eq!(
        names(&import),
        [
            "shared_xdg",
            "flatpak_only",
            "pg_native",
            "default_project",
            "project_source"
        ]
    );
}

#[test]
fn passwords_on_linux_stay_in_the_keyring_without_a_keepass_file() {
    let import = collect(
        &plain(&fixture("roots", "linux"), ForeignPlatform::Linux),
        request(true, false),
    );
    assert_eq!(import.passwords, PasswordOutcome::LeftInKeychain);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn a_legacy_raw_pdb_pwd_opens_c_kdbx_on_linux() {
    let import = collect(
        &plain(&fixture("legacy-key", "linux"), ForeignPlatform::Linux),
        request(true, false),
    );
    assert_eq!(import.passwords, PasswordOutcome::Read);
    let credentials = connection(&import, "legacy_mysql")
        .credentials
        .as_ref()
        .expect("credentials");
    assert_eq!(secret(credentials.password.as_ref()), Some("legacy-secret"));
}

#[test]
fn windows_reads_the_roaming_jetbrains_folder() {
    let import = collect(
        &plain(&fixture("roaming", "windows"), ForeignPlatform::Windows),
        request(false, false),
    );
    let settings = &connection(&import, "win_sql").settings;
    assert_eq!(settings.engine, "SQL Server");
    assert_eq!(settings.host, "sql.example.com");
    assert_eq!(settings.database, "Sales");
    assert_eq!(import.passwords, PasswordOutcome::NotRequested);
}

#[test]
fn a_crypt_32_main_key_on_windows_stops_reading_passwords() {
    let import = collect(
        &plain(&fixture("roaming", "windows"), ForeignPlatform::Windows),
        request(true, false),
    );
    assert_eq!(import.passwords, PasswordOutcome::Stopped);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}
