#![expect(
    clippy::expect_used,
    reason = "the fixture helpers fail a test the way the test functions themselves do"
)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use secrecy::ExposeSecret;
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, ForeignApp, ForeignAppDirs, ForeignHost, ForeignImportError, ForeignImporter,
    ForeignPlatform, ForeignSshAuth, ForeignSslMode, ImportRequest, Inventory, PasswordOutcome, PasswordSource,
    PlainHost, SavedQuerySupport,
};
use tokio_util::sync::CancellationToken;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("navicat")
        .join(name)
}

struct MissingApp;

impl ForeignHost for MissingApp {
    fn installed(&self, _app: ForeignApp) -> Option<bool> {
        Some(false)
    }
}

fn bare_importer(platform: ForeignPlatform, host: Arc<dyn ForeignHost>) -> (ForeignImporter, tempfile::TempDir) {
    let home = tempfile::tempdir().expect("a temp dir");
    let importer = ForeignImporter::new(
        ForeignApp::Navicat,
        ForeignAppDirs::conventional(platform, home.path()),
        host,
    );
    (importer, home)
}

fn import_of(
    file: PathBuf,
    platform: ForeignPlatform,
    request: &ImportRequest,
) -> Result<CollectedImport, ForeignImportError> {
    let (importer, _home) = bare_importer(platform, Arc::new(PlainHost));
    importer
        .with_file(file)
        .collect_blocking(request, &CancellationToken::new())
}

fn import(name: &str, request: &ImportRequest) -> Result<CollectedImport, ForeignImportError> {
    import_of(fixture(name), ForeignPlatform::current(), request)
}

fn connections(request: &ImportRequest) -> CollectedImport {
    import("connections.ncx", request).expect("an import")
}

fn request(include_passwords: bool, include_saved_queries: bool) -> ImportRequest {
    ImportRequest {
        include_passwords,
        include_saved_queries,
        saved_query_byte_limit: 64 * 1024,
    }
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

#[test]
fn the_app_is_known_by_its_id_and_reads_a_picked_ncx_export() {
    let app = ForeignApp::Navicat;
    assert_eq!(app.id(), "navicat");
    assert_eq!(app.display_name(), "Navicat");
    assert_eq!(ForeignApp::from_id("navicat"), Some(app));
    assert_eq!(app.picked_file_extensions(), Some(&["ncx"][..]));
    assert_eq!(app.password_source(), PasswordSource::AppFiles);
    assert!(app.runs_on(ForeignPlatform::MacOs));
    assert!(app.runs_on(ForeignPlatform::Linux));
    assert!(app.runs_on(ForeignPlatform::Windows));
}

#[test]
fn saved_queries_are_not_in_the_export() {
    assert_eq!(
        ForeignApp::Navicat.saved_query_support(),
        SavedQuerySupport::NotInExport
    );
}

#[test]
fn is_available_without_an_installed_app_or_a_file_on_every_platform() {
    for platform in [ForeignPlatform::MacOs, ForeignPlatform::Linux, ForeignPlatform::Windows] {
        let (importer, _home) = bare_importer(platform, Arc::new(MissingApp));
        assert!(importer.is_available_blocking());
        let (importer, _home) = bare_importer(platform, Arc::new(PlainHost));
        assert!(importer.is_available_blocking());
    }
}

#[test]
fn reads_the_same_export_on_every_platform() {
    for platform in [ForeignPlatform::MacOs, ForeignPlatform::Linux, ForeignPlatform::Windows] {
        let import = import_of(fixture("connections.ncx"), platform, &request(true, false)).expect("an import");
        assert_eq!(import.connections.len(), 10);
        assert_eq!(password(connection(&import, "Zero")), Some("This is a test"));
    }
}

#[test]
fn inventory_is_empty_without_a_file() {
    let (importer, _home) = bare_importer(ForeignPlatform::current(), Arc::new(PlainHost));
    assert_eq!(importer.inventory_blocking(), Inventory::default());
}

#[test]
fn inventory_counts_the_files_connections_and_never_any_saved_queries() {
    let (importer, _home) = bare_importer(ForeignPlatform::current(), Arc::new(PlainHost));
    let inventory = importer.with_file(fixture("connections.ncx")).inventory_blocking();
    assert_eq!(
        inventory,
        Inventory {
            connections: 10,
            saved_queries: 0,
        }
    );
}

#[test]
fn asking_for_saved_queries_still_imports_connections_only() {
    let import = connections(&request(true, true));
    assert_eq!(import.connections.len(), 10);
    assert!(import.saved_queries.is_empty());
}

#[test]
fn importing_without_a_file_fails() {
    let (importer, _home) = bare_importer(ForeignPlatform::current(), Arc::new(PlainHost));
    let outcome = importer.collect_blocking(&request(true, false), &CancellationToken::new());
    assert!(matches!(
        outcome,
        Err(ForeignImportError::FileNotFound {
            app: ForeignApp::Navicat
        })
    ));
}

#[test]
fn a_file_that_cannot_be_read_is_not_found() {
    let outcome = import("missing.ncx", &request(true, false));
    assert!(matches!(
        outcome,
        Err(ForeignImportError::FileNotFound {
            app: ForeignApp::Navicat
        })
    ));
}

#[test]
fn malformed_xml_is_a_parse_error() {
    let outcome = import("malformed.ncx", &request(true, false));
    assert!(matches!(outcome, Err(ForeignImportError::Parse { .. })));
}

#[test]
fn an_export_with_a_document_type_is_refused() {
    let outcome = import("doctype.ncx", &request(true, false));
    assert!(matches!(outcome, Err(ForeignImportError::Parse { .. })));
}

#[test]
fn a_file_with_no_connections_has_nothing_to_import() {
    let outcome = import("empty.ncx", &request(true, false));
    assert!(matches!(outcome, Err(ForeignImportError::NothingFound)));
}

#[test]
fn maps_every_known_conn_type() {
    let import = connections(&request(false, false));
    let engines: Vec<&str> = import.connections[..7]
        .iter()
        .map(|connection| connection.settings.engine.as_str())
        .collect();
    assert_eq!(
        engines,
        [
            "MySQL",
            "PostgreSQL",
            "MariaDB",
            "Oracle",
            "SQLite",
            "SQL Server",
            "MongoDB"
        ]
    );
}

#[test]
fn passes_an_unknown_conn_type_through_with_no_port() {
    let import = connections(&request(false, false));
    let exotic = connection(&import, "Exotic");
    assert_eq!(exotic.settings.engine, "EXOTICDB");
    assert_eq!(exotic.settings.port, 0);
}

#[test]
fn resolves_a_conn_type_tablepro_knows_under_another_case() {
    let import = connections(&request(false, false));
    let cockroach = connection(&import, "Cockroach");
    assert_eq!(cockroach.settings.engine, "CockroachDB");
    assert_eq!(cockroach.settings.port, 26_257);
}

#[test]
fn falls_back_to_the_default_port_when_port_is_empty() {
    let import = connections(&request(false, false));
    let postgres = connection(&import, "One");
    assert_eq!(postgres.settings.port, 5432);
    assert_eq!(postgres.settings.host, "pg.example.com");
    assert_eq!(postgres.settings.database, "analytics");
    assert_eq!(postgres.settings.username, "analyst");
}

#[test]
fn maps_sqlite_to_its_file_path() {
    let import = connections(&request(false, false));
    let sqlite = connection(&import, "Files");
    assert_eq!(sqlite.settings.engine, "SQLite");
    assert_eq!(sqlite.settings.database, "/Users/me/data.db");
    assert_eq!(sqlite.settings.host, "");
    assert_eq!(sqlite.settings.port, 0);
    assert_eq!(sqlite.settings.username, "");
}

#[test]
fn maps_an_ssh_tunnel() {
    let import = connections(&request(false, false));
    let ssh = connection(&import, "Zero").settings.ssh.as_ref().expect("a tunnel");
    assert_eq!(ssh.host, "bastion.example.com");
    assert_eq!(ssh.port, Some(2222));
    assert_eq!(ssh.username, "deploy");
    assert_eq!(ssh.auth, ForeignSshAuth::Password);
    assert_eq!(ssh.private_key_path, "");
    assert!(connection(&import, "One").settings.ssh.is_none());
}

#[test]
fn a_tunnel_that_does_not_use_a_password_uses_a_key() {
    let import = connections(&request(false, false));
    let ssh = connection(&import, "Reports & BI")
        .settings
        .ssh
        .as_ref()
        .expect("a tunnel");
    assert_eq!(ssh.auth, ForeignSshAuth::PrivateKey);
    assert_eq!(ssh.private_key_path, "~/.ssh/id_rsa");
    assert_eq!(ssh.port, None);
}

#[test]
fn maps_ssl_verify_mode_and_ca_path() {
    let import = connections(&request(false, false));
    let ssl = connection(&import, "One").settings.ssl.as_ref().expect("ssl");
    assert_eq!(ssl.mode, ForeignSslMode::VerifyCa);
    assert_eq!(ssl.ca_certificate_path.as_deref(), Some("/certs/ca.pem"));
    assert_eq!(ssl.client_certificate_path, None);
    assert_eq!(ssl.client_key_path, None);
    assert!(connection(&import, "Zero").settings.ssl.is_none());
}

#[test]
fn verify_full_is_verify_identity_with_the_client_certificate() {
    let import = connections(&request(false, false));
    let ssl = connection(&import, "Reports & BI").settings.ssl.as_ref().expect("ssl");
    assert_eq!(ssl.mode, ForeignSslMode::VerifyIdentity);
    assert_eq!(ssl.ca_certificate_path, None);
    assert_eq!(ssl.client_certificate_path.as_deref(), Some("/certs/client.pem"));
    assert_eq!(ssl.client_key_path.as_deref(), Some("/certs/client.key"));
}

#[test]
fn flags_and_types_match_in_any_case_and_blanks_take_defaults() {
    let import = connections(&request(false, false));
    let unnamed = &import.connections[9];
    assert_eq!(unnamed.settings.name, "Navicat");
    assert_eq!(unnamed.settings.host, "localhost");
    assert_eq!(unnamed.settings.engine, "MySQL");
    assert_eq!(
        unnamed.settings.ssl.as_ref().map(|ssl| ssl.mode),
        Some(ForeignSslMode::Preferred)
    );
}

#[test]
fn decrypts_the_database_and_ssh_passwords() {
    let import = connections(&request(true, false));
    let zero = connection(&import, "Zero");
    assert_eq!(password(zero), Some("This is a test"));
    assert_eq!(ssh_password(zero), Some("This is a test"));
}

#[test]
fn maps_credentials_to_the_right_connection_when_some_have_no_saved_password() {
    let import = connections(&request(true, false));
    assert_eq!(import.passwords, PasswordOutcome::Read);
    assert_eq!(
        import
            .connections
            .iter()
            .filter(|connection| connection.credentials.is_some())
            .count(),
        2
    );
    assert_eq!(password(&import.connections[0]), Some("This is a test"));
    assert!(import.connections[1].credentials.is_none());
    assert_eq!(password(&import.connections[2]), Some("Sup3rSecret!Pass"));
}

#[test]
fn skips_the_password_when_save_password_is_false() {
    let import = connections(&request(true, false));
    assert!(connection(&import, "One").credentials.is_none());
}

#[test]
fn a_password_that_does_not_decrypt_is_left_out() {
    let import = connections(&request(true, false));
    assert!(import.connections[9].credentials.is_none());
}

#[test]
fn skips_passwords_entirely_when_they_are_not_requested() {
    let import = connections(&request(false, false));
    assert_eq!(import.passwords, PasswordOutcome::NotRequested);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.credentials.is_none())
    );
}

#[test]
fn stamps_each_connection_with_a_row_reference() {
    let import = connections(&request(true, false));
    assert_eq!(import.app, ForeignApp::Navicat);
    let references: Vec<&str> = import
        .connections
        .iter()
        .map(|connection| connection.reference.as_str())
        .collect();
    let expected: Vec<String> = (0..10).map(|index| format!("row-{index}")).collect();
    assert_eq!(references, expected);
    assert!(
        import
            .connections
            .iter()
            .all(|connection| connection.group_path.is_empty())
    );
}

#[test]
fn reading_stops_when_cancelled() {
    let cancel = CancellationToken::new();
    cancel.cancel();
    let (importer, _home) = bare_importer(ForeignPlatform::current(), Arc::new(PlainHost));
    let outcome = importer
        .with_file(fixture("connections.ncx"))
        .collect_blocking(&request(true, false), &cancel);
    assert!(matches!(outcome, Err(ForeignImportError::Cancelled)));
}

#[test]
fn a_saved_key_passphrase_is_imported_in_either_spelling_and_alone() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let file = dir.path().join("keys.ncx");
    std::fs::write(
        &file,
        r#"<?xml version="1.0" encoding="UTF-8"?>
<Connections Ver="1.5">
	<Connection ConnectionName="Lower" ConnType="MYSQL" Host="db" Port="3306" UserName="u" SavePassword="false" SSH="true" SSH_Host="bastion" SSH_UserName="ops" SSH_AuthenMethod="PUBLICKEY" SSH_PrivateKey="/keys/id" SSH_Passphrase="B75D320B6211468D63EB3B67C9E85933" SSH_SavePassphrase="true" SSH_SavePassword="false"/>
	<Connection ConnectionName="Upper" ConnType="MYSQL" Host="db" Port="3306" UserName="u" SavePassword="false" SSH="true" SSH_Host="bastion" SSH_UserName="ops" SSH_AuthenMethod="PUBLICKEY" SSH_PrivateKey="/keys/id" SSH_PassPhrase="B75D320B6211468D63EB3B67C9E85933" SSH_SavePassPhrase="true" SSH_SavePassword="false"/>
	<Connection ConnectionName="Unsaved" ConnType="MYSQL" Host="db" Port="3306" UserName="u" SavePassword="false" SSH="true" SSH_Host="bastion" SSH_UserName="ops" SSH_AuthenMethod="PUBLICKEY" SSH_PrivateKey="/keys/id" SSH_Passphrase="B75D320B6211468D63EB3B67C9E85933" SSH_SavePassphrase="false" SSH_SavePassword="false"/>
</Connections>
"#,
    )
    .expect("an export file");
    let import = import_of(file, ForeignPlatform::current(), &request(true, false)).expect("an import");
    let passphrase = |name: &str| {
        connection(&import, name)
            .credentials
            .as_ref()
            .and_then(|credentials| credentials.key_passphrase.as_ref())
            .map(|secret| secret.expose_secret().to_owned())
    };
    assert_eq!(passphrase("Lower").as_deref(), Some("This is a test"));
    assert_eq!(passphrase("Upper").as_deref(), Some("This is a test"));
    assert!(connection(&import, "Unsaved").credentials.is_none());
}
