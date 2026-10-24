//! Every format a released build wrote must still read.
//!
//! The fixtures are files as a release wrote them, and a later build
//! reads them as an upgrading user's would be read. Never edit one: a
//! format change appends an upgrade step, adds a fixture for the new
//! version, and updates the expected model here.

use std::error::Error;
use std::path::Path;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use tablepro_core::{AiPolicy, AuthMode, ClientIdentity, ExternalAccess, SafeModeLevel, TlsConfig, TlsMode};
use tablepro_storage::{
    ConnectionColor, ConnectionGroupName, ConnectionStore, SavedConnection, SavedSshAuth, SavedSshConfig, StoragePaths,
};
use uuid::Uuid;

type TestResult = Result<(), Box<dyn Error>>;

const CONNECTIONS_V1: &[u8] = include_bytes!("fixtures/connections-v1.json");
const CONNECTIONS_V2: &[u8] = include_bytes!("fixtures/connections-v2.json");

fn connections_from(root: &Path, bytes: &[u8]) -> Result<Arc<[SavedConnection]>, Box<dyn Error>> {
    let paths = StoragePaths::under(root, "tablepro", "app.tablepro.TablePro");
    let file = paths.connections_file();
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&file, bytes)?;
    Ok(ConnectionStore::new(&paths).load_blocking()?)
}

fn tls(mode: TlsMode) -> TlsConfig {
    TlsConfig {
        mode,
        ca_file: None,
        client_identity: None,
        server_name: None,
    }
}

fn opened(at: &str) -> Result<DateTime<Utc>, Box<dyn Error>> {
    Ok(DateTime::parse_from_rfc3339(at)?.with_timezone(&Utc))
}

/// A connection with every optional field at its default, for the
/// model below to fill in.
fn saved(id: &str, name: &str, driver_id: &str, host: &str, port: u16) -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        id: Uuid::parse_str(id)?,
        name: name.to_owned(),
        driver_id: driver_id.to_owned(),
        host: host.to_owned(),
        port,
        database: String::new(),
        username: String::new(),
        tls: tls(TlsMode::Disable),
        safe_mode: SafeModeLevel::Off,
        external_access: ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    })
}

fn ssh(host: &str, auth: SavedSshAuth) -> SavedSshConfig {
    SavedSshConfig {
        host: host.to_owned(),
        port: None,
        username: None,
        jump_hosts: Vec::new(),
        auth,
    }
}

fn connections_v1_model() -> Result<Vec<SavedConnection>, Box<dyn Error>> {
    let production = Some(ConnectionGroupName::new("Production")?);
    Ok(vec![
        SavedConnection {
            database: "app".to_owned(),
            username: "tablepro".to_owned(),
            ..saved(
                "0b6a8f3e-4d1c-4c5e-9a57-1f2d3c4b5a61",
                "Local Postgres",
                "postgres",
                "localhost",
                5432,
            )?
        },
        production_orders(production.clone())?,
        SavedConnection {
            database: "warehouse".to_owned(),
            tls: tls(TlsMode::Require),
            auth_mode: AuthMode::Kerberos,
            ssh: Some(ssh("gateway.corp.example", SavedSshAuth::Agent)),
            group: production,
            ..saved(
                "1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d",
                "Warehouse",
                "mssql",
                "sql.corp.example",
                1433,
            )?
        },
        events()?,
        SavedConnection {
            database: "app".to_owned(),
            username: "app".to_owned(),
            tls: tls(TlsMode::Require),
            ssh: Some(ssh("staging-bastion", SavedSshAuth::KeyboardInteractive)),
            last_opened_at: Some(opened("2026-09-30T17:05:42.123Z")?),
            ..saved(
                "3d4e5f60-7182-4934-a5b6-c7d8e9f0a1b2",
                "Staging",
                "postgres",
                "staging.example.com",
                5432,
            )?
        },
        SavedConnection {
            database: "/home/me/projects/app/app.sqlite3".to_owned(),
            ..saved("c0ffee00-1234-4abc-8def-0123456789ab", "app.sqlite3", "sqlite", "", 0)?
        },
        SavedConnection {
            username: "root".to_owned(),
            tls: tls(TlsMode::Require),
            ssh: Some(SavedSshConfig {
                port: Some(22),
                username: Some("root".to_owned()),
                ..ssh("legacy.example.com", SavedSshAuth::Password)
            }),
            color: Some(ConnectionColor::Slate),
            ..saved(
                "5a5b5c5d-6e6f-4071-8283-949596979899",
                "MariaDB legacy",
                "mysql",
                "127.0.0.1",
                3307,
            )?
        },
    ])
}

/// Version 2 replaced the read-only switch with the Safe Mode level;
/// its fixture has Staging asking before writes.
fn connections_v2_model() -> Result<Vec<SavedConnection>, Box<dyn Error>> {
    Ok(connections_v1_model()?
        .into_iter()
        .map(|connection| match connection.name.as_str() {
            "Staging" => SavedConnection {
                safe_mode: SafeModeLevel::ConfirmWrites,
                ..connection
            },
            _ => connection,
        })
        .collect())
}

fn production_orders(group: Option<ConnectionGroupName>) -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        database: "orders".to_owned(),
        username: "reporting".to_owned(),
        tls: TlsConfig {
            mode: TlsMode::VerifyFull,
            ca_file: Some("/home/me/certs/ca.pem".into()),
            client_identity: Some(ClientIdentity {
                certificate: "/home/me/certs/client.pem".into(),
                key: "/home/me/certs/client.key".into(),
            }),
            server_name: Some("mysql.example.com".to_owned()),
        },
        safe_mode: SafeModeLevel::ReadOnly,
        ssh: Some(SavedSshConfig {
            port: Some(2222),
            username: Some("deploy".to_owned()),
            jump_hosts: vec!["jump1.example.com".to_owned(), "ops@jump2.example.com:2200".to_owned()],
            ..ssh(
                "bastion",
                SavedSshAuth::PrivateKey {
                    path: Some("/home/me/.ssh/id_ed25519".into()),
                    has_passphrase: true,
                },
            )
        }),
        last_opened_at: Some(opened("2026-10-01T08:30:00Z")?),
        color: Some(ConnectionColor::Red),
        group,
        ..saved(
            "6f1e2d3c-4b5a-4968-8776-655443322110",
            "Production orders",
            "mysql",
            "db.internal.example",
            3306,
        )?
    })
}

fn events() -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        database: "default".to_owned(),
        username: "analyst".to_owned(),
        tls: tls(TlsMode::VerifyFull),
        ssh: Some(SavedSshConfig {
            username: Some("admin".to_owned()),
            ..ssh(
                "10.0.0.5",
                SavedSshAuth::PrivateKey {
                    path: None,
                    has_passphrase: false,
                },
            )
        }),
        color: Some(ConnectionColor::Teal),
        ..saved(
            "9c8b7a6f-5e4d-4c3b-a2a1-0f9e8d7c6b5a",
            "Events",
            "clickhouse",
            "clickhouse.example.com",
            8443,
        )?
    })
}

#[test]
fn a_version_1_connection_list_reads_as_it_was_written() -> TestResult {
    let root = tempfile::tempdir()?;

    let read = connections_from(root.path(), CONNECTIONS_V1)?;

    assert_eq!(read.as_ref(), connections_v1_model()?.as_slice());
    Ok(())
}

#[test]
fn a_version_1_read_only_switch_reads_as_a_safe_mode_level() -> TestResult {
    let root = tempfile::tempdir()?;

    let read = connections_from(root.path(), CONNECTIONS_V1)?;

    let levels: Vec<(&str, SafeModeLevel)> = read
        .iter()
        .map(|connection| (connection.name.as_str(), connection.safe_mode))
        .collect();
    assert!(levels.contains(&("Production orders", SafeModeLevel::ReadOnly)));
    assert!(
        levels
            .iter()
            .filter(|(name, _)| *name != "Production orders")
            .all(|(_, level)| *level == SafeModeLevel::Off)
    );
    Ok(())
}

#[test]
fn a_version_2_connection_list_reads_as_it_was_written() -> TestResult {
    let root = tempfile::tempdir()?;

    let read = connections_from(root.path(), CONNECTIONS_V2)?;

    assert_eq!(read.as_ref(), connections_v2_model()?.as_slice());
    Ok(())
}

#[test]
fn a_version_2_list_writes_back_as_it_was_read() -> TestResult {
    let root = tempfile::tempdir()?;
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let store = ConnectionStore::new(&paths);
    store.import_blocking(Path::new("/tmp/connections-v2.json"), CONNECTIONS_V2)?;

    let exported = store.export_blocking()?;
    let again = tempfile::tempdir()?;
    let read = connections_from(again.path(), &exported)?;

    assert_eq!(read.as_ref(), store.load_blocking()?.as_ref());
    assert!(String::from_utf8_lossy(&exported).contains("\"safe_mode\": \"confirm_writes\""));
    Ok(())
}

#[test]
fn a_list_written_before_external_access_lets_clients_read_only() -> TestResult {
    let root = tempfile::tempdir()?;

    let read = connections_from(root.path(), CONNECTIONS_V2)?;

    assert!(!String::from_utf8_lossy(CONNECTIONS_V2).contains("external_access"));
    assert!(
        read.iter()
            .all(|connection| connection.external_access == ExternalAccess::ReadOnly)
    );
    Ok(())
}

#[test]
fn an_external_access_level_writes_back_as_it_was_set() -> TestResult {
    let root = tempfile::tempdir()?;
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let store = ConnectionStore::new(&paths);
    store.import_blocking(Path::new("/tmp/connections-v2.json"), CONNECTIONS_V2)?;
    let first = store.load_blocking()?.first().map(|connection| connection.id);
    let Some(first) = first else {
        return Err("the fixture has no connections".into());
    };
    store.update_blocking(first, |connection| {
        connection.external_access = ExternalAccess::Blocked;
    })?;

    let exported = store.export_blocking()?;
    let again = tempfile::tempdir()?;
    let read = connections_from(again.path(), &exported)?;

    assert!(String::from_utf8_lossy(&exported).contains("\"external_access\": \"blocked\""));
    let levels: Vec<ExternalAccess> = read.iter().map(|connection| connection.external_access).collect();
    assert_eq!(levels.iter().filter(|level| level.is_blocked()).count(), 1);
    assert_eq!(
        read.iter()
            .find(|connection| connection.id == first)
            .map(|c| c.external_access),
        Some(ExternalAccess::Blocked)
    );
    Ok(())
}

#[test]
fn a_list_written_before_the_ai_policy_asks_before_sending() -> TestResult {
    let root = tempfile::tempdir()?;

    let read = connections_from(root.path(), CONNECTIONS_V2)?;

    assert!(!String::from_utf8_lossy(CONNECTIONS_V2).contains("ai_policy"));
    assert!(read.iter().all(|connection| connection.ai_policy == AiPolicy::Ask));
    Ok(())
}

#[test]
fn an_ai_policy_writes_back_as_it_was_set() -> TestResult {
    let root = tempfile::tempdir()?;
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let store = ConnectionStore::new(&paths);
    store.import_blocking(Path::new("/tmp/connections-v2.json"), CONNECTIONS_V2)?;
    let first = store.load_blocking()?.first().map(|connection| connection.id);
    let Some(first) = first else {
        return Err("the fixture has no connections".into());
    };
    store.update_blocking(first, |connection| {
        connection.ai_policy = AiPolicy::Never;
    })?;

    let exported = store.export_blocking()?;
    let again = tempfile::tempdir()?;
    let read = connections_from(again.path(), &exported)?;

    assert!(String::from_utf8_lossy(&exported).contains("\"ai_policy\": \"never\""));
    assert_eq!(
        read.iter()
            .find(|connection| connection.id == first)
            .map(|connection| connection.ai_policy),
        Some(AiPolicy::Never)
    );
    Ok(())
}

#[test]
fn a_version_1_connection_list_imports_as_it_was_written() -> TestResult {
    let root = tempfile::tempdir()?;
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let store = ConnectionStore::new(&paths);

    let report = store.import_blocking(Path::new("/tmp/connections-v1.json"), CONNECTIONS_V1)?;

    assert_eq!(report.total(), connections_v1_model()?.len());
    // An import never takes the file's last-opened times.
    let imported: Vec<SavedConnection> = connections_v1_model()?
        .into_iter()
        .map(|connection| SavedConnection {
            last_opened_at: None,
            ..connection
        })
        .collect();
    assert_eq!(store.load_blocking()?.as_ref(), imported.as_slice());
    Ok(())
}
