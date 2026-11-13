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
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionIcon, ConnectionList, ConnectionStore,
    ConnectionTag, ConnectionTagName, GroupIcon, SavedConnection, SavedSshAuth, SavedSshConfig, StoragePaths,
    SymbolName,
};
use uuid::Uuid;

type TestResult = Result<(), Box<dyn Error>>;

const CONNECTIONS_V1: &[u8] = include_bytes!("fixtures/connections-v1.json");

fn connections_from(root: &Path, bytes: &[u8]) -> Result<Arc<[SavedConnection]>, Box<dyn Error>> {
    Ok(list_from(root, bytes)?.connections)
}

fn list_from(root: &Path, bytes: &[u8]) -> Result<ConnectionList, Box<dyn Error>> {
    let paths = StoragePaths::under(root, "tablepro", "app.tablepro.TablePro");
    let file = paths.connections_file();
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&file, bytes)?;
    Ok(ConnectionStore::new(&paths).list_blocking()?)
}

fn production() -> Result<ConnectionGroup, Box<dyn Error>> {
    Ok(ConnectionGroup {
        id: Uuid::parse_str("2a378134-5812-82b4-84aa-ed5c6c3cf409")?,
        color: Some(ConnectionColor::Red),
        icon: Some(GroupIcon::Named(ConnectionIcon::Shield)),
        ..ConnectionGroup::new(ConnectionGroupName::new("Production")?, None)
    })
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
        query_timeout_secs: None,
        masking_rules: Vec::new(),
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
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

fn local_postgres() -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        database: "app".to_owned(),
        username: "tablepro".to_owned(),
        order: 1,
        ..saved(
            "0b6a8f3e-4d1c-4c5e-9a57-1f2d3c4b5a61",
            "Local Postgres",
            "postgres",
            "localhost",
            5432,
        )?
    })
}

fn production_orders(group_id: Uuid, tag: Uuid) -> Result<SavedConnection, Box<dyn Error>> {
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
        external_access: ExternalAccess::Blocked,
        ai_policy: AiPolicy::Never,
        query_timeout_secs: Some(300),
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
        group_id: Some(group_id),
        tags: vec![tag],
        icon: Some(ConnectionIcon::Shield),
        ..saved(
            "6f1e2d3c-4b5a-4968-8776-655443322110",
            "Production orders",
            "mysql",
            "db.internal.example",
            3306,
        )?
    })
}

fn warehouse(group_id: Uuid) -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        database: "warehouse".to_owned(),
        tls: tls(TlsMode::Require),
        auth_mode: AuthMode::Kerberos,
        ssh: Some(ssh("gateway.corp.example", SavedSshAuth::Agent)),
        group_id: Some(group_id),
        order: 1,
        ..saved(
            "1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d",
            "Warehouse",
            "mssql",
            "sql.corp.example",
            1433,
        )?
    })
}

fn events(group_id: Uuid) -> Result<SavedConnection, Box<dyn Error>> {
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
        group_id: Some(group_id),
        ..saved(
            "9c8b7a6f-5e4d-4c3b-a2a1-0f9e8d7c6b5a",
            "Events",
            "clickhouse",
            "clickhouse.example.com",
            8443,
        )?
    })
}

fn staging() -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        database: "app".to_owned(),
        username: "app".to_owned(),
        tls: tls(TlsMode::Require),
        safe_mode: SafeModeLevel::ConfirmWrites,
        external_access: ExternalAccess::ReadWrite,
        ai_policy: AiPolicy::Allow,
        ssh: Some(ssh("staging-bastion", SavedSshAuth::KeyboardInteractive)),
        last_opened_at: Some(opened("2026-09-30T17:05:42.123Z")?),
        ..saved(
            "3d4e5f60-7182-4934-a5b6-c7d8e9f0a1b2",
            "Staging",
            "postgres",
            "staging.example.com",
            5432,
        )?
    })
}

fn app_sqlite() -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        database: "/home/me/projects/app/app.sqlite3".to_owned(),
        order: 2,
        ..saved("c0ffee00-1234-4abc-8def-0123456789ab", "app.sqlite3", "sqlite", "", 0)?
    })
}

fn mariadb(group_id: Uuid) -> Result<SavedConnection, Box<dyn Error>> {
    Ok(SavedConnection {
        username: "root".to_owned(),
        tls: tls(TlsMode::Require),
        ssh: Some(SavedSshConfig {
            port: Some(22),
            username: Some("root".to_owned()),
            ..ssh("legacy.example.com", SavedSshAuth::Password)
        }),
        color: Some(ConnectionColor::Slate),
        group_id: Some(group_id),
        ..saved(
            "5a5b5c5d-6e6f-4071-8283-949596979899",
            "MariaDB legacy",
            "mysql",
            "127.0.0.1",
            3307,
        )?
    })
}

/// Nested groups with colours and icons, each connection's place in its
/// group, a tag, and the favourites in order.
fn connections_v1_model() -> Result<ConnectionList, Box<dyn Error>> {
    let production = production()?;
    let analytics = Uuid::parse_str("f1e2d3c4-b5a6-4978-8695-a4b3c2d1e0f9")?;
    let clickhouse = Uuid::parse_str("e7d6c5b4-a392-4180-9f7e-6d5c4b3a2918")?;
    let retired = Uuid::parse_str("4c3b2a19-0817-4f6e-8d5c-4b3a29180716")?;
    let critical = ConnectionTag {
        id: Uuid::parse_str("b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e")?,
        name: ConnectionTagName::new("critical")?,
        color: ConnectionColor::Red,
    };
    let connections = vec![
        local_postgres()?,
        production_orders(production.id, critical.id)?,
        warehouse(production.id)?,
        events(clickhouse)?,
        staging()?,
        app_sqlite()?,
        mariadb(retired)?,
    ];
    let groups = vec![
        production,
        ConnectionGroup {
            id: analytics,
            order: 1,
            icon: SymbolName::new("chart.bar.xaxis").map(GroupIcon::Symbol),
            ..ConnectionGroup::new(ConnectionGroupName::new("Analytics")?, None)
        },
        ConnectionGroup {
            id: clickhouse,
            color: Some(ConnectionColor::Teal),
            ..ConnectionGroup::new(ConnectionGroupName::new("ClickHouse")?, Some(analytics))
        },
        ConnectionGroup {
            id: retired,
            ..ConnectionGroup::new(ConnectionGroupName::new("Retired")?, Some(clickhouse))
        },
        ConnectionGroup {
            id: Uuid::parse_str("8a7b6c5d-4e3f-4a2b-9c1d-0e9f8a7b6c5d")?,
            order: 2,
            color: Some(ConnectionColor::Slate),
            ..ConnectionGroup::new(ConnectionGroupName::new("Archive")?, None)
        },
    ];
    let favorites = vec![
        Uuid::parse_str("3d4e5f60-7182-4934-a5b6-c7d8e9f0a1b2")?,
        Uuid::parse_str("6f1e2d3c-4b5a-4968-8776-655443322110")?,
    ];
    Ok(ConnectionList::new(connections, vec![critical])
        .with_groups(groups)
        .with_favorites(favorites))
}

fn assert_same_library(read: &ConnectionList, model: &ConnectionList) {
    assert_eq!(read.connections.as_ref(), model.connections.as_ref());
    assert_eq!(read.groups.as_ref(), model.groups.as_ref());
    assert_eq!(read.tags.as_ref(), model.tags.as_ref());
    assert_eq!(read.favorites.as_ref(), model.favorites.as_ref());
}

/// An imported copy of the fixture, as the store holds it.
fn imported() -> Result<(tempfile::TempDir, ConnectionStore), Box<dyn Error>> {
    let root = tempfile::tempdir()?;
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let store = ConnectionStore::new(&paths);
    store.import_blocking(Path::new("/tmp/connections-v1.json"), CONNECTIONS_V1)?;
    Ok((root, store))
}

#[test]
fn a_version_1_connection_list_reads_as_it_was_written() -> TestResult {
    let root = tempfile::tempdir()?;

    let read = list_from(root.path(), CONNECTIONS_V1)?;

    assert_same_library(&read, &connections_v1_model()?);
    let tree = read.group_tree();
    let labels: Vec<String> = tree.walk().iter().filter_map(|group| tree.label(group.id)).collect();
    assert_eq!(
        labels,
        [
            "Production",
            "Analytics",
            "Analytics / ClickHouse",
            "Analytics / ClickHouse / Retired",
            "Archive"
        ]
    );
    Ok(())
}

#[test]
fn a_version_1_list_writes_back_as_it_was_read() -> TestResult {
    let (_root, store) = imported()?;
    let imported = store.list_blocking()?;

    let exported = store.export_blocking()?;
    let again = tempfile::tempdir()?;
    let read = list_from(again.path(), &exported)?;

    assert_same_library(&read, &imported);
    let model = connections_v1_model()?;
    assert_eq!(imported.groups.as_ref(), model.groups.as_ref());
    assert_eq!(imported.favorites.as_ref(), model.favorites.as_ref());
    assert!(String::from_utf8_lossy(&exported).contains("\"version\": 1"));
    Ok(())
}

#[test]
fn a_version_1_connection_list_imports_without_its_last_opened_times() -> TestResult {
    let (_root, store) = imported()?;

    let expected: Vec<SavedConnection> = connections_v1_model()?
        .connections
        .iter()
        .map(|connection| SavedConnection {
            last_opened_at: None,
            ..connection.clone()
        })
        .collect();
    assert_eq!(store.load_blocking()?.as_ref(), expected.as_slice());
    Ok(())
}

#[test]
fn an_external_access_level_writes_back_as_it_was_set() -> TestResult {
    let (_root, store) = imported()?;
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

    let expected: Vec<ExternalAccess> = connections_v1_model()?
        .connections
        .iter()
        .map(|connection| match connection.id == first {
            true => ExternalAccess::Blocked,
            false => connection.external_access,
        })
        .collect();
    let levels: Vec<ExternalAccess> = read.iter().map(|connection| connection.external_access).collect();
    assert_eq!(levels, expected);
    Ok(())
}

#[test]
fn an_ai_policy_writes_back_as_it_was_set() -> TestResult {
    let (_root, store) = imported()?;
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

    assert_eq!(
        read.iter()
            .find(|connection| connection.id == first)
            .map(|connection| connection.ai_policy),
        Some(AiPolicy::Never)
    );
    Ok(())
}

#[test]
fn a_connection_without_a_query_timeout_follows_preferences_and_writes_back_without_it() -> TestResult {
    let (_root, store) = imported()?;

    let exported = String::from_utf8(store.export_blocking()?)?;

    let timeouts: Vec<Option<u32>> = store
        .load_blocking()?
        .iter()
        .map(|connection| connection.query_timeout_secs)
        .collect();
    assert_eq!(timeouts.iter().filter(|timeout| timeout.is_some()).count(), 1);
    assert_eq!(exported.matches("query_timeout_secs").count(), 1, "{exported}");
    Ok(())
}

#[test]
fn a_query_timeout_writes_back_as_it_was_set() -> TestResult {
    let (_root, store) = imported()?;
    let ids: Vec<_> = store.load_blocking()?.iter().map(|connection| connection.id).collect();
    let [first, second, ..] = ids.as_slice() else {
        return Err("the fixture has fewer than two connections".into());
    };
    store.update_blocking(*first, |connection| connection.query_timeout_secs = Some(120))?;
    store.update_blocking(*second, |connection| connection.query_timeout_secs = Some(0))?;

    let exported = store.export_blocking()?;
    let again = tempfile::tempdir()?;
    let read = connections_from(again.path(), &exported)?;
    let seconds = |id| {
        read.iter()
            .find(|connection| connection.id == id)
            .and_then(|connection| connection.query_timeout_secs)
    };

    assert!(String::from_utf8_lossy(&exported).contains("\"query_timeout_secs\": 120"));
    assert_eq!(seconds(*first), Some(120));
    assert_eq!(seconds(*second), Some(0));
    Ok(())
}
