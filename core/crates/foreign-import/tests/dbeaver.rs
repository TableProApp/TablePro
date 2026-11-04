#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use secrecy::ExposeSecret;
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, CollectedSavedQuery, ForeignApp, ForeignAppDirs, ForeignColor, ForeignHost,
    ForeignImportError, ForeignImporter, ForeignPlatform, ForeignSshAuth, ForeignSslMode, ImportRequest, Inventory,
    PasswordOutcome, PlainHost, SavedQueryContent, TLS_SETTINGS_UNREAD,
};
use tokio_util::sync::CancellationToken;

const SYNC_LIMIT: u64 = 900_000;
const CONNECTIONS_ONLY: ImportRequest = request(false, false);
const WITH_PASSWORDS: ImportRequest = request(true, false);
const WITH_SAVED_QUERIES: ImportRequest = request(false, true);
const MACOS_CONNECTION_COUNT: usize = 57;

const fn request(include_passwords: bool, include_saved_queries: bool) -> ImportRequest {
    ImportRequest {
        include_passwords,
        include_saved_queries,
        saved_query_byte_limit: SYNC_LIMIT,
    }
}

struct InstalledHost(Option<bool>);

impl ForeignHost for InstalledHost {
    fn installed(&self, _app: ForeignApp) -> Option<bool> {
        self.0
    }
}

fn fixture(home: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/dbeaver")
        .join(home)
}

fn importer_with(platform: ForeignPlatform, home: &Path, host: Arc<dyn ForeignHost>) -> ForeignImporter {
    ForeignImporter::new(ForeignApp::DBeaver, ForeignAppDirs::conventional(platform, home), host)
}

fn importer(platform: ForeignPlatform, home: &Path) -> ForeignImporter {
    importer_with(platform, home, Arc::new(PlainHost))
}

fn macos() -> ForeignImporter {
    importer(ForeignPlatform::MacOs, &fixture("macos"))
}

fn collect(importer: &ForeignImporter, request: ImportRequest) -> CollectedImport {
    importer
        .collect_blocking(&request, &CancellationToken::new())
        .expect("an import")
}

fn collect_error(importer: &ForeignImporter) -> ForeignImportError {
    match importer.collect_blocking(&CONNECTIONS_ONLY, &CancellationToken::new()) {
        Ok(_) => panic!("expected the import to fail"),
        Err(error) => error,
    }
}

fn connection<'a>(import: &'a CollectedImport, name: &str) -> &'a CollectedConnection {
    import
        .connections
        .iter()
        .find(|connection| connection.settings.name == name)
        .unwrap_or_else(|| panic!("no connection named {name}"))
}

fn query<'a>(import: &'a CollectedImport, name: &str) -> &'a CollectedSavedQuery {
    import
        .saved_queries
        .iter()
        .find(|query| query.name == name)
        .unwrap_or_else(|| panic!("no saved query named {name}"))
}

fn password(connection: &CollectedConnection) -> Option<&str> {
    connection
        .credentials
        .as_ref()?
        .password
        .as_ref()
        .map(|secret| secret.expose_secret())
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).expect("a folder");
    for entry in fs::read_dir(from).expect("a fixture folder") {
        let entry = entry.expect("an entry");
        let target = to.join(entry.file_name());
        if entry.file_type().expect("a file type").is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).expect("a copy");
        }
    }
}

fn set_modified(path: &Path, modified: SystemTime) {
    File::options()
        .write(true)
        .open(path)
        .and_then(|file| file.set_modified(modified))
        .expect("a modification time");
}

#[test]
fn is_available_when_a_data_sources_file_exists_for_any_edition() {
    let home = fixture("macos-empty");
    assert!(importer(ForeignPlatform::MacOs, &home).is_available_blocking());
    // The macOS app looks past a missing bundle for DBeaver, whose data outlives it.
    assert!(importer_with(ForeignPlatform::MacOs, &home, Arc::new(InstalledHost(Some(false)))).is_available_blocking());
}

#[test]
fn is_unavailable_without_the_app_or_its_data() {
    let home = tempfile::tempdir().expect("a temp dir");
    assert!(!importer(ForeignPlatform::MacOs, home.path()).is_available_blocking());
}

#[test]
fn is_available_when_the_app_is_installed_without_data() {
    let home = tempfile::tempdir().expect("a temp dir");
    let installed = importer_with(ForeignPlatform::MacOs, home.path(), Arc::new(InstalledHost(Some(true))));
    assert!(installed.is_available_blocking());
}

#[test]
fn inventory_counts_connections_and_scripts_that_have_text() {
    assert_eq!(
        macos().inventory_blocking(),
        Inventory {
            connections: MACOS_CONNECTION_COUNT,
            saved_queries: 5,
        }
    );
}

#[test]
fn inventory_is_empty_when_the_data_is_missing() {
    let home = tempfile::tempdir().expect("a temp dir");
    assert_eq!(
        importer(ForeignPlatform::MacOs, home.path()).inventory_blocking(),
        Inventory::default()
    );
}

#[test]
fn collect_reads_every_connection() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_eq!(import.app, ForeignApp::DBeaver);
    assert_eq!(import.connections.len(), MACOS_CONNECTION_COUNT);
}

#[test]
fn providers_map_to_tablepro_engines() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let mappings = [
        ("Conn mysql", "MySQL"),
        ("Conn postgresql", "PostgreSQL"),
        ("Conn sqlite", "SQLite"),
        ("Conn sqlserver", "SQL Server"),
        ("Conn oracle", "Oracle"),
        ("Conn mongodb", "MongoDB"),
        ("Conn mongo", "MongoDB"),
        ("Conn redis", "Redis"),
        ("Conn clickhouse", "ClickHouse"),
        ("Conn mariadb", "MariaDB"),
        ("Conn tidb", "TiDB"),
        ("Conn cassandra", "Cassandra"),
    ];
    for (name, engine) in mappings {
        assert_eq!(connection(&import, name).settings.engine, engine, "{name}");
    }
}

#[test]
fn the_tidb_lakehouse_provider_is_not_imported_as_tidb() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_ne!(connection(&import, "Lake").settings.engine, "TiDB");
}

#[test]
fn an_unknown_provider_passes_through() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_eq!(connection(&import, "Unknown DB").settings.engine, "exoticdb");
}

#[test]
fn a_port_reads_from_a_number_or_a_string() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_eq!(connection(&import, "PG int port").settings.port, 5433);
    assert_eq!(connection(&import, "PG string port").settings.port, 5433);
}

#[test]
fn a_missing_port_takes_the_engine_s_default() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let defaults = [
        ("Conn postgresql", 5432),
        ("Conn mysql", 3306),
        ("Conn mongodb", 27_017),
        ("Conn redis", 6379),
        ("Conn sqlserver", 1433),
        ("Conn oracle", 1521),
        ("Conn clickhouse", 8123),
        ("Conn cassandra", 9042),
    ];
    for (name, port) in defaults {
        assert_eq!(connection(&import, name).settings.port, port, "{name}");
    }
}

#[test]
fn a_connection_without_name_or_host_takes_its_id_and_what_its_url_names_never_the_url() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let settings = &connection(&import, "no-name-and-host").settings;
    assert_eq!(settings.host, "localhost");
    assert_eq!(settings.port, 5432);
    assert_eq!(settings.database, "fromurl");
    assert_eq!(settings.username, "");
}

#[test]
fn an_ssh_tunnel_with_a_public_key_keeps_its_key_path() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let ssh = connection(&import, "SSH key PG")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.host, "bastion.example.com");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.username, "deploy");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "~/.ssh/id_rsa");
    assert!(ssh.jump_hosts.is_empty());
}

#[test]
fn an_ssh_tunnel_with_a_host_is_on_unless_disabled_and_a_bare_key_name_is_in_the_ssh_folder() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let ssh = connection(&import, "SSH bare key PG")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.private_key_path, "~/.ssh/id_ed25519");
    assert_eq!(ssh.port, None);
    assert!(connection(&import, "SSH disabled PG").settings.ssh.is_none());
}

#[test]
fn an_ssh_tunnel_with_the_agent_has_no_key_path() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let ssh = connection(&import, "SSH agent PG")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::Agent);
    assert_eq!(ssh.private_key_path, "");
}

#[test]
fn an_ssh_tunnel_with_a_password_has_no_key_path() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let ssh = connection(&import, "SSH password PG")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::Password);
    assert_eq!(ssh.private_key_path, "");
}

#[test]
fn an_ssh_port_reads_from_a_string() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let ssh = connection(&import, "SSH string port")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.port, Some(2222));
}

#[test]
fn a_tunnel_without_a_user_in_its_settings_takes_the_one_in_the_credentials_file() {
    for request in [CONNECTIONS_ONLY, WITH_PASSWORDS] {
        let import = collect(&macos(), request);
        let ssh = connection(&import, "SSH user from credentials")
            .settings
            .ssh
            .as_ref()
            .expect("a tunnel");
        assert_eq!(ssh.username, "tunnel-user");
    }
    let import = collect(&macos(), WITH_PASSWORDS);
    let credentials = connection(&import, "SSH user from credentials")
        .credentials
        .as_ref()
        .expect("credentials");
    assert_eq!(
        credentials.ssh_password.as_ref().map(|secret| secret.expose_secret()),
        Some("tunnel-secret")
    );
}

#[test]
fn no_ssh_tunnel_without_its_handler() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert!(connection(&import, "Local PG").settings.ssh.is_none());
}

#[test]
fn folders_become_group_paths_named_by_their_description() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_eq!(connection(&import, "Prod PG").group_path, ["Production Servers"]);
    assert_eq!(connection(&import, "Dev PG").group_path, ["Development Servers"]);
    assert!(connection(&import, "Local PG").group_path.is_empty());
}

#[test]
fn a_folder_without_a_description_is_named_by_its_path_component() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_eq!(connection(&import, "Team PG").group_path, ["team", "backend"]);
}

#[test]
fn passwords_decrypt_from_the_credentials_file() {
    let import = collect(&macos(), WITH_PASSWORDS);
    assert_eq!(import.passwords, PasswordOutcome::Read);
    assert_eq!(password(connection(&import, "PG with password")), Some("s3cr3t_p4ss"));
    let tunnel = connection(&import, "SSH password PG")
        .credentials
        .as_ref()
        .expect("credentials");
    assert_eq!(
        tunnel.ssh_password.as_ref().map(|secret| secret.expose_secret()),
        Some("tunnel-pass")
    );
    assert!(tunnel.password.is_none());
}

#[test]
fn without_passwords_no_credentials_are_kept() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert_eq!(import.passwords, PasswordOutcome::NotRequested);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn the_username_comes_from_the_credentials_file_even_without_passwords() {
    for request in [WITH_PASSWORDS, CONNECTIONS_ONLY] {
        let import = collect(&macos(), request);
        assert_eq!(connection(&import, "User from credentials").settings.username, "sameer");
    }
}

#[test]
fn the_username_falls_back_to_the_configuration() {
    let import = collect(&macos(), WITH_PASSWORDS);
    assert_eq!(
        connection(&import, "User from configuration").settings.username,
        "configuser"
    );
}

#[test]
fn the_credentials_username_wins_over_the_configuration() {
    let import = collect(&macos(), WITH_PASSWORDS);
    assert_eq!(connection(&import, "User in both").settings.username, "creduser");
}

#[test]
fn an_empty_credentials_username_falls_back_to_the_configuration() {
    let import = collect(&macos(), WITH_PASSWORDS);
    assert_eq!(
        connection(&import, "User empty in credentials").settings.username,
        "configuser"
    );
}

#[test]
fn invalid_json_is_a_parse_error() {
    let error = collect_error(&importer(ForeignPlatform::MacOs, &fixture("macos-invalid")));
    assert!(matches!(error, ForeignImportError::Parse { .. }), "{error:?}");
}

#[test]
fn no_connections_is_an_error() {
    let error = collect_error(&importer(ForeignPlatform::MacOs, &fixture("macos-empty")));
    assert!(matches!(error, ForeignImportError::NothingFound), "{error:?}");
}

#[test]
fn a_file_without_connections_is_unsupported() {
    let error = collect_error(&importer(ForeignPlatform::MacOs, &fixture("macos-no-connections")));
    assert!(
        matches!(error, ForeignImportError::UnsupportedFormat { .. }),
        "{error:?}"
    );
}

#[test]
fn a_missing_data_folder_is_file_not_found() {
    let home = tempfile::tempdir().expect("a temp dir");
    let error = collect_error(&importer(ForeignPlatform::MacOs, home.path()));
    assert!(
        matches!(
            error,
            ForeignImportError::FileNotFound {
                app: ForeignApp::DBeaver
            }
        ),
        "{error:?}"
    );
}

#[test]
fn a_cancelled_import_stops() {
    let cancel = CancellationToken::new();
    cancel.cancel();
    let outcome = macos().collect_blocking(&WITH_SAVED_QUERIES, &cancel);
    assert!(matches!(outcome, Err(ForeignImportError::Cancelled)));
}

#[test]
fn colours_map_from_rgb() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let colours = [
        ("Red", Some(ForeignColor::Red)),
        ("Orange", Some(ForeignColor::Orange)),
        ("Yellow", Some(ForeignColor::Yellow)),
        ("Green", Some(ForeignColor::Green)),
        ("Blue", Some(ForeignColor::Blue)),
        ("Purple", Some(ForeignColor::Purple)),
        ("Grey", None),
        ("No Color", None),
    ];
    for (name, colour) in colours {
        assert_eq!(connection(&import, name).settings.color, colour, "{name}");
    }
}

#[test]
fn connections_are_keyed_by_their_data_source_id_and_sorted_by_name_then_id() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let names: Vec<&str> = import.connections.iter().map(|c| c.settings.name.as_str()).collect();
    let mut sorted = names.clone();
    sorted.sort_unstable();
    assert_eq!(names, sorted);
    let twins: Vec<&str> = import
        .connections
        .iter()
        .filter(|c| c.settings.name == "Twin")
        .map(|c| c.reference.as_str())
        .collect();
    assert_eq!(twins, ["twin-a", "twin-b"]);
    assert_eq!(connection(&import, "PG with password").reference, "pg-1");
}

#[test]
fn ssl_modes_map_and_an_empty_postgres_mode_verifies_the_server() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let modes = [
        ("SSL Require", ForeignSslMode::Required),
        ("SSL Verify CA", ForeignSslMode::VerifyCa),
        ("SSL Verify Full", ForeignSslMode::VerifyIdentity),
        ("SSL Default", ForeignSslMode::VerifyIdentity),
    ];
    for (name, mode) in modes {
        let ssl = connection(&import, name).settings.ssl.as_ref().expect("SSL");
        assert_eq!(ssl.mode, mode, "{name}");
    }
}

#[test]
fn each_engine_s_tls_handler_is_read_by_its_own_name() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let modes = [
        ("MySQL SSL required", ForeignSslMode::Required),
        ("MySQL SSL verified", ForeignSslMode::VerifyCa),
        ("ClickHouse SSL", ForeignSslMode::Required),
    ];
    for (name, mode) in modes {
        let settings = &connection(&import, name).settings;
        assert_eq!(settings.ssl.as_ref().map(|ssl| ssl.mode), Some(mode), "{name}");
        assert!(!settings.additional_fields.contains_key(TLS_SETTINGS_UNREAD), "{name}");
    }
    let verified = connection(&import, "MySQL SSL verified")
        .settings
        .ssl
        .as_ref()
        .expect("SSL");
    assert_eq!(verified.ca_certificate_path.as_deref(), Some("/certs/mysql-ca.pem"));
}

#[test]
fn a_tls_handler_whose_mode_is_not_read_marks_the_connection_instead_of_turning_tls_off() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    for name in ["SQL Server SSL", "SSL Unknown Mode"] {
        let settings = &connection(&import, name).settings;
        assert_eq!(settings.ssl, None, "{name}");
        assert_eq!(
            settings.additional_fields.get(TLS_SETTINGS_UNREAD).map(String::as_str),
            Some("true"),
            "{name}"
        );
    }
}

#[test]
fn postgres_with_its_tls_handler_off_imports_the_tls_pgjdbc_prefers() {
    let import = collect(
        &importer(ForeignPlatform::Linux, &fixture("linux-tls-defaults")),
        CONNECTIONS_ONLY,
    );
    let cases = [
        (
            "PG no handler",
            Some(ForeignSslMode::Preferred),
            Some("tlsFromDriverDefault"),
        ),
        (
            "PG handler off",
            Some(ForeignSslMode::Preferred),
            Some("tlsFromDriverDefault"),
        ),
        ("PG driver property", None, Some(TLS_SETTINGS_UNREAD)),
        ("PG URL off", None, None),
        ("Redshift driver", None, None),
        ("MySQL no handler", None, None),
        ("SQL Server no handler", None, None),
    ];
    for (name, mode, marker) in cases {
        let settings = &connection(&import, name).settings;
        assert_eq!(settings.ssl.as_ref().map(|ssl| ssl.mode), mode, "{name}");
        let markers: Vec<&str> = settings
            .additional_fields
            .keys()
            .map(String::as_str)
            .filter(|key| [TLS_SETTINGS_UNREAD, "tlsFromDriverDefault"].contains(key))
            .collect();
        assert_eq!(markers, marker.into_iter().collect::<Vec<_>>(), "{name}");
    }
}

#[test]
fn a_tls_handler_set_to_disable_turns_tls_off() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let settings = &connection(&import, "SSL Off").settings;
    assert_eq!(settings.ssl, None);
    assert!(!settings.additional_fields.contains_key(TLS_SETTINGS_UNREAD));
}

#[test]
fn in_url_mode_the_url_names_the_server_over_leftover_manual_fields() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let url = &connection(&import, "URL mode").settings;
    assert_eq!(
        (url.host.as_str(), url.port, url.database.as_str()),
        ("new.example.com", 6543, "current")
    );
    let manual = &connection(&import, "Manual mode").settings;
    assert_eq!(
        (manual.host.as_str(), manual.port, manual.database.as_str()),
        ("manual.example.com", 5433, "manual")
    );
}

#[test]
fn ssl_certificate_paths_are_kept() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    let ssl = connection(&import, "SSL Certs").settings.ssl.as_ref().expect("SSL");
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/path/to/ca.pem"));
    assert_eq!(ssl.client_certificate_path.as_deref(), Some("/path/to/cert.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/path/to/key.pem"));
}

#[test]
fn no_ssl_when_the_handler_is_missing_or_disabled() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert!(connection(&import, "Local PG").settings.ssl.is_none());
    assert!(connection(&import, "SSL Disabled").settings.ssl.is_none());
}

#[test]
fn a_script_is_bound_to_the_data_source_dbeaver_opens_it_on() {
    let import = collect(&macos(), WITH_SAVED_QUERIES);
    let daily = query(&import, "Daily users");
    assert_eq!(daily.content, SavedQueryContent::Text("select ${days};".to_owned()));
    assert_eq!(daily.connection.as_deref(), Some("pg-1"));
    assert_eq!(daily.folder_path, ["Reports"]);
    assert!(daily.suggested);
}

#[test]
fn an_unbound_script_is_global_under_the_dbeaver_folder() {
    let import = collect(&macos(), WITH_SAVED_QUERIES);
    let unbound = query(&import, "Unbound");
    assert_eq!(unbound.connection, None);
    assert_eq!(unbound.folder_path, ["DBeaver"]);
    assert!(unbound.suggested);
}

#[test]
fn a_script_bound_to_an_unknown_data_source_is_global_and_unchecked() {
    let import = collect(&macos(), WITH_SAVED_QUERIES);
    let elsewhere = query(&import, "Elsewhere");
    assert_eq!(elsewhere.connection, None);
    assert_eq!(elsewhere.folder_path, ["DBeaver"]);
    assert!(!elsewhere.suggested);
}

#[test]
fn default_named_scripts_start_unchecked_and_empty_files_are_skipped() {
    let import = collect(&macos(), WITH_SAVED_QUERIES);
    let names: BTreeSet<&str> = import.saved_queries.iter().map(|query| query.name.as_str()).collect();
    assert_eq!(
        names,
        BTreeSet::from(["Script", "Script-3", "Daily users", "Unbound", "Elsewhere"])
    );
    let script = query(&import, "Script");
    assert_eq!(script.connection.as_deref(), Some("pg-1"));
    assert!(!script.suggested);
    assert!(!query(&import, "Script-3").suggested);
}

#[test]
fn a_script_over_the_sync_limit_is_listed_as_oversized() {
    let home = tempfile::tempdir().expect("a temp dir");
    copy_tree(&fixture("macos"), home.path());
    let scripts = home.path().join("Library/DBeaverData/workspace6/General/Scripts");
    fs::write(scripts.join("Big.sql"), "-".repeat(1_048_576)).expect("a script");

    let import = collect(&importer(ForeignPlatform::MacOs, home.path()), WITH_SAVED_QUERIES);
    let big = query(&import, "Big");
    assert_eq!(big.content, SavedQueryContent::Oversized { byte_count: 1_048_576 });
    assert_eq!(big.connection, None);
    assert_eq!(big.folder_path, ["DBeaver"]);
    assert!(!big.suggested);
}

#[test]
fn no_scripts_are_read_unless_saved_queries_are_requested() {
    let import = collect(&macos(), CONNECTIONS_ONLY);
    assert!(import.saved_queries.is_empty());
}

#[test]
fn linux_reads_every_data_sources_file_with_its_own_credentials_file() {
    let linux = importer(ForeignPlatform::Linux, &fixture("linux"));
    assert_eq!(linux.inventory_blocking().connections, 2);

    let import = collect(&linux, WITH_PASSWORDS);
    let names: Vec<&str> = import.connections.iter().map(|c| c.settings.name.as_str()).collect();
    assert_eq!(names, ["From second file", "Linux native"]);
    let native = connection(&import, "Linux native");
    assert_eq!(native.settings.username, "native-user");
    assert_eq!(password(native), Some("native-pass"));
    let second = connection(&import, "From second file");
    assert_eq!(second.settings.username, "reporter");
    assert_eq!(password(second), Some("sub-pass"));
    // The folder is defined in the main file, which DBeaver shares across files.
    assert_eq!(second.group_path, ["Shared Servers"]);
}

#[test]
fn linux_finds_the_flatpak_the_snap_the_old_folder_name_and_a_custom_data_folder() {
    let homes = [
        ("linux-flatpak", "Flatpak PG"),
        ("linux-snap", "Snap PG"),
        ("linux-hidden-folder", "Old install PG"),
    ];
    for (home, name) in homes {
        let import = collect(&importer(ForeignPlatform::Linux, &fixture(home)), CONNECTIONS_ONLY);
        assert_eq!(import.connections.len(), 1, "{home}");
        assert_eq!(import.connections[0].settings.name, name, "{home}");
    }

    let home = fixture("linux-xdg");
    let mut dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, &home);
    dirs.data = home.join("xdg-data");
    let custom = ForeignImporter::new(ForeignApp::DBeaver, dirs, Arc::new(PlainHost));
    assert_eq!(
        collect(&custom, CONNECTIONS_ONLY).connections[0].settings.name,
        "Custom data PG"
    );
}

#[test]
fn linux_reads_the_root_whose_data_file_changed_last() {
    let home = tempfile::tempdir().expect("a temp dir");
    copy_tree(&fixture("linux"), home.path());
    copy_tree(&fixture("linux-flatpak"), home.path());
    let native = home.path().join(".local/share/DBeaverData/workspace6/General/.dbeaver");
    let flatpak = home
        .path()
        .join(".var/app/io.dbeaver.DBeaverCommunity/data/DBeaverData/workspace6/General/.dbeaver");
    let earlier = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    let later = earlier + Duration::from_secs(60);
    for file in ["data-sources.json", "data-sources-2.json", "data-sources-broken.json"] {
        set_modified(&native.join(file), earlier);
    }
    set_modified(&flatpak.join("data-sources.json"), later);
    let linux = importer(ForeignPlatform::Linux, home.path());
    assert_eq!(
        collect(&linux, CONNECTIONS_ONLY).connections[0].settings.name,
        "Flatpak PG"
    );

    set_modified(&native.join("data-sources-2.json"), later + Duration::from_secs(60));
    let names: Vec<String> = collect(&linux, CONNECTIONS_ONLY)
        .connections
        .into_iter()
        .map(|c| c.settings.name)
        .collect();
    assert_eq!(names, ["From second file", "Linux native"]);
}

#[test]
fn windows_reads_the_roaming_app_data_folder_with_the_same_key() {
    let import = collect(&importer(ForeignPlatform::Windows, &fixture("windows")), WITH_PASSWORDS);
    let windows = connection(&import, "Windows PG");
    assert_eq!(windows.settings.username, "winuser");
    assert_eq!(password(windows), Some("windows-pass"));
}

#[test]
fn each_platform_reads_only_its_own_location() {
    assert!(!importer(ForeignPlatform::Linux, &fixture("macos")).is_available_blocking());
    assert!(!importer(ForeignPlatform::MacOs, &fixture("linux")).is_available_blocking());
    assert!(!importer(ForeignPlatform::Windows, &fixture("linux")).is_available_blocking());
}
