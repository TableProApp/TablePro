use std::collections::BTreeMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::SecretKind;
use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AiPolicy, AuthMode, ClientIdentity, CommitResolutionSupport, ConnectOptions, Connection, DataModel, DatabaseDriver,
    DriverCapabilities, DriverError, DriverRegistry, EndpointKind, EstimateQuality, ExternalAccess, FileFormat,
    FileSignature, NetworkOption, NetworkOptions, ReadOnlyEnforcement, SafeModeLevel, ScriptExecution,
    ServerNameOverride, StatementStop, TlsCapabilities, TlsConfig, TlsMode, WriteAtomicity,
};
use tablepro_foreign_import::review::{
    ConnectionRow, ExistingConnection, ImportReview, ImportSelection, QueryAvailability, QueryStatus, QueryTarget,
    Resolution, ReviewInputs, RowNote, TlsFileReason, apply_blocking, plan, save_queries,
};
use tablepro_foreign_import::{
    CollectedConnection, CollectedImport, CollectedSavedQuery, ForeignApp, ForeignAppDirs, ForeignColor,
    ForeignConnection, ForeignCredentials, ForeignJumpHost, ForeignPlatform, ForeignSsh, ForeignSshAuth, ForeignSsl,
    ForeignSslMode, PasswordOutcome, SavedQueryContent,
};
use tablepro_storage::saved_queries::NewSavedQuery;
use tablepro_storage::{
    ConnectionColor, ConnectionList, ConnectionStore, QueryHistory, SavedConnection, SavedSshAuth, SavedSshConfig,
    StorageError, StoragePaths,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const ALL_MODES: &[TlsMode] = &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull];

const FULL_TLS: TlsCapabilities = TlsCapabilities {
    modes: ALL_MODES,
    default_mode: TlsMode::Disable,
    tls_ports: &[],
    ca_file: true,
    client_identity: true,
    server_name_override: ServerNameOverride::AnyRoute,
};

const fn network(default_port: u16, data_model: DataModel, tls: Option<TlsCapabilities>) -> DriverCapabilities {
    DriverCapabilities {
        data_model,
        endpoint: EndpointKind::Network { default_port },
        auth_modes: &[AuthMode::Password],
        username_required: true,
        tls,
        read_only: ReadOnlyEnforcement::SessionDefault,
        dml_writes: WriteAtomicity::Transactional,
        ddl_writes: WriteAtomicity::Transactional,
        script_execution: ScriptExecution::NativeBatch,
        commit_resolution: CommitResolutionSupport::Unavailable,
        row_count_estimate: EstimateQuality::Statistics,
        object_kinds: &[ObjectKind::Table],
        database_required: false,
        network_options: &[],
        statement_stop: StatementStop::Server,
    }
}

const fn file(suffix: &'static [&'static str]) -> DriverCapabilities {
    DriverCapabilities {
        endpoint: EndpointKind::File(FileFormat {
            signature: FileSignature {
                offset: 0,
                bytes: b"Test format\0",
            },
            suffixes: suffix,
            mime_types: &[],
            empty_file_is_database: true,
        }),
        auth_modes: &[],
        tls: None,
        ..network(0, DataModel::Relational, None)
    }
}

static MYSQL: DriverCapabilities = network(3306, DataModel::Relational, Some(FULL_TLS));
static POSTGRES: DriverCapabilities = network(
    5432,
    DataModel::Relational,
    Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Prefer, TlsMode::Require, TlsMode::VerifyFull],
        default_mode: TlsMode::Prefer,
        ..FULL_TLS
    }),
);
static MSSQL: DriverCapabilities = network(
    1433,
    DataModel::Relational,
    Some(TlsCapabilities {
        client_identity: false,
        ..FULL_TLS
    }),
);
static CLICKHOUSE: DriverCapabilities = network(8123, DataModel::Relational, Some(FULL_TLS));
static CASSANDRA: DriverCapabilities = network(9042, DataModel::Relational, Some(FULL_TLS));
static REDIS: DriverCapabilities = network(6379, DataModel::KeyValue, Some(FULL_TLS));
static MONGODB: DriverCapabilities = DriverCapabilities {
    network_options: &[NetworkOption::DnsSeedList, NetworkOption::AuthDatabase],
    ..network(27017, DataModel::Document, Some(FULL_TLS))
};
static SQLITE: DriverCapabilities = file(&["sqlite"]);
static DUCKDB: DriverCapabilities = file(&["duckdb"]);
static VERIFY_ONLY: DriverCapabilities = network(
    5432,
    DataModel::Relational,
    Some(TlsCapabilities {
        modes: &[TlsMode::VerifyFull],
        default_mode: TlsMode::VerifyFull,
        ca_file: false,
        ..FULL_TLS
    }),
);
static NO_VERIFY: DriverCapabilities = network(
    5432,
    DataModel::Relational,
    Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require],
        ..FULL_TLS
    }),
);
static NO_TLS: DriverCapabilities = network(5432, DataModel::Relational, None);

struct TestDriver {
    id: &'static str,
    capabilities: &'static DriverCapabilities,
}

// Written out as `async_trait` expands it, which this crate does not depend on.
impl DatabaseDriver for TestDriver {
    fn id(&self) -> &'static str {
        self.id
    }

    fn display_name(&self) -> &'static str {
        self.id
    }

    fn capabilities(&self) -> &'static DriverCapabilities {
        self.capabilities
    }

    fn connect<'life0, 'async_trait>(
        &'life0 self,
        _options: ConnectOptions,
        _cancel: CancellationToken,
    ) -> Pin<Box<dyn Future<Output = Result<Arc<dyn Connection>, DriverError>> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(DriverError::Cancelled) })
    }
}

fn registry(drivers: &[(&'static str, &'static DriverCapabilities)]) -> DriverRegistry {
    let mut registry = DriverRegistry::new();
    for (id, capabilities) in drivers {
        registry.register(Arc::new(TestDriver { id, capabilities }));
    }
    registry
}

fn drivers() -> DriverRegistry {
    registry(&[
        ("mysql", &MYSQL),
        ("postgres", &POSTGRES),
        ("mssql", &MSSQL),
        ("clickhouse", &CLICKHOUSE),
        ("cassandra", &CASSANDRA),
        ("redis", &REDIS),
        ("mongodb", &MONGODB),
        ("sqlite", &SQLITE),
        ("duckdb", &DUCKDB),
    ])
}

fn home() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(r"C:\Users\u")
    } else {
        PathBuf::from("/home/u")
    }
}

fn dirs() -> ForeignAppDirs {
    ForeignAppDirs::conventional(ForeignPlatform::Linux, &home())
}

fn settings() -> ForeignConnection {
    ForeignConnection {
        name: "Orders".to_owned(),
        host: "db.example.com".to_owned(),
        port: 5432,
        database: "orders".to_owned(),
        username: "app".to_owned(),
        engine: "PostgreSQL".to_owned(),
        ssh: None,
        ssl: None,
        color: None,
        additional_fields: BTreeMap::new(),
    }
}

fn named(name: &str) -> ForeignConnection {
    ForeignConnection {
        name: name.to_owned(),
        ..settings()
    }
}

fn on_host(name: &str, host: &str) -> ForeignConnection {
    ForeignConnection {
        host: host.to_owned(),
        ..named(name)
    }
}

fn connection(reference: &str, settings: ForeignConnection) -> CollectedConnection {
    CollectedConnection {
        reference: reference.to_owned(),
        settings,
        group_path: Vec::new(),
        credentials: None,
    }
}

fn query(reference: &str, name: &str, text: &str, connection: Option<&str>) -> CollectedSavedQuery {
    CollectedSavedQuery {
        reference: reference.to_owned(),
        name: name.to_owned(),
        content: SavedQueryContent::Text(text.to_owned()),
        keyword: None,
        folder_path: Vec::new(),
        connection: connection.map(str::to_owned),
        suggested: true,
    }
}

fn collected(connections: Vec<CollectedConnection>, saved_queries: Vec<CollectedSavedQuery>) -> CollectedImport {
    CollectedImport {
        app: ForeignApp::DBeaver,
        connections,
        saved_queries,
        passwords: PasswordOutcome::Read,
    }
}

fn library(connections: Vec<SavedConnection>) -> ConnectionList {
    ConnectionList {
        connections: Arc::from(connections),
        ..ConnectionList::default()
    }
}

fn review_in(
    collected: CollectedImport,
    library: ConnectionList,
    drivers: &DriverRegistry,
    file_exists: &dyn Fn(&Path) -> bool,
) -> ImportReview {
    let dirs = dirs();
    ImportReview::analyze(
        collected,
        ReviewInputs {
            drivers,
            library,
            dirs: &dirs,
            file_exists,
        },
    )
}

fn review(collected: CollectedImport, saved: Vec<SavedConnection>) -> ImportReview {
    review_in(collected, library(saved), &drivers(), &|_| true)
}

fn only_row(settings: ForeignConnection) -> ConnectionRow {
    review_with(settings, &drivers()).connections()[0].clone()
}

fn review_with(settings: ForeignConnection, drivers: &DriverRegistry) -> ImportReview {
    review_in(
        collected(vec![connection("c1", settings)], Vec::new()),
        library(Vec::new()),
        drivers,
        &|_| true,
    )
}

fn mapped(settings: ForeignConnection) -> Option<SavedConnection> {
    only_row(settings).connection
}

// A saved connection as this import writes the same settings, under an id of its own.
fn existing(settings: ForeignConnection, name: &str) -> Option<SavedConnection> {
    mapped(settings).map(|saved| SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        ..saved
    })
}

fn secret(value: &str) -> Option<SecretString> {
    Some(SecretString::from(value.to_owned()))
}

fn password(value: &str) -> Option<ForeignCredentials> {
    Some(ForeignCredentials {
        password: secret(value),
        ..ForeignCredentials::default()
    })
}

fn ssl(mode: ForeignSslMode) -> Option<ForeignSsl> {
    Some(ForeignSsl {
        mode,
        ca_certificate_path: None,
        client_certificate_path: None,
        client_key_path: None,
    })
}

fn tunnel(host: &str, auth: ForeignSshAuth, key: &str) -> Option<ForeignSsh> {
    Some(ForeignSsh {
        host: host.to_owned(),
        port: None,
        username: "deploy".to_owned(),
        auth,
        private_key_path: key.to_owned(),
        jump_hosts: Vec::new(),
    })
}

fn hop(host: &str, port: Option<u16>, username: &str, auth: ForeignSshAuth, key: &str) -> ForeignJumpHost {
    ForeignJumpHost {
        host: host.to_owned(),
        port,
        username: username.to_owned(),
        auth,
        private_key_path: key.to_owned(),
    }
}

#[test]
fn a_connection_matching_host_port_database_and_username_ignoring_case_and_spaces_is_a_duplicate() {
    let local = existing(named("Local Postgres"), "Local Postgres").expect("a saved connection");
    let imported = ForeignConnection {
        name: "Different Name".to_owned(),
        host: " db.example.com ".to_owned(),
        database: " ORDERS ".to_owned(),
        username: " APP ".to_owned(),
        engine: "MySQL".to_owned(),
        ..settings()
    };
    let review = review(
        collected(vec![connection("c1", imported)], Vec::new()),
        vec![local.clone()],
    );

    let row = &review.connections()[0];
    assert_eq!(
        row.duplicate,
        Some(ExistingConnection {
            id: local.id,
            name: "Local Postgres".to_owned()
        })
    );
    // Another engine signs in differently, so Replace would hand it the saved password.
    assert_eq!(row.resolutions, [Resolution::AddCopy]);
    assert!(!row.selected_by_default);
}

#[test]
fn another_ssh_server_tls_mode_or_engine_is_not_offered_replace() {
    let saved = ForeignConnection {
        ssl: ssl(ForeignSslMode::VerifyIdentity),
        ssh: tunnel("bastion.prod.internal", ForeignSshAuth::Agent, ""),
        ..settings()
    };
    let local = existing(saved.clone(), "Production").expect("a saved connection");
    let variants = [
        ForeignConnection {
            ssh: tunnel("bastion.attacker.example", ForeignSshAuth::Agent, ""),
            ..saved.clone()
        },
        ForeignConnection {
            ssh: None,
            ..saved.clone()
        },
        ForeignConnection {
            ssl: ssl(ForeignSslMode::Required),
            ..saved.clone()
        },
        ForeignConnection {
            engine: "MySQL".to_owned(),
            ..saved.clone()
        },
    ];
    for imported in variants {
        let review = review(
            collected(vec![connection("c1", imported)], Vec::new()),
            vec![local.clone()],
        );
        let row = &review.connections()[0];
        assert_eq!(row.duplicate.as_ref().map(|duplicate| duplicate.id), Some(local.id));
        assert_eq!(row.resolutions, [Resolution::AddCopy]);
    }
}

#[test]
fn a_duplicate_that_differs_only_in_how_it_is_shown_is_offered_replace() {
    let saved = ForeignConnection {
        ssl: ssl(ForeignSslMode::VerifyIdentity),
        ..settings()
    };
    let local = existing(saved.clone(), "Production").expect("a saved connection");
    let imported = ForeignConnection {
        name: "Production (laptop)".to_owned(),
        color: Some(ForeignColor::Red),
        host: " db.example.com ".to_owned(),
        ..saved
    };
    let review = review(
        collected(vec![connection("c1", imported)], Vec::new()),
        vec![local.clone()],
    );

    assert_eq!(
        review.connections()[0].resolutions,
        [Resolution::AddCopy, Resolution::Replace(local.id)]
    );
}

#[test]
fn a_duplicate_whose_saved_connection_guards_more_is_offered_as_copy_only() {
    let base = existing(settings(), "Production").expect("a saved connection");
    let guarded = [
        SavedConnection {
            safe_mode: SafeModeLevel::ConfirmWrites,
            ..base.clone()
        },
        SavedConnection {
            ai_policy: AiPolicy::Never,
            ..base.clone()
        },
        SavedConnection {
            query_timeout_secs: Some(30),
            ..base.clone()
        },
    ];
    for local in guarded {
        let review = review(collected(vec![connection("c1", settings())], Vec::new()), vec![local]);
        assert_eq!(review.connections()[0].resolutions, [Resolution::AddCopy]);
    }
}

#[test]
fn the_first_library_connection_with_a_matching_key_is_the_duplicate() {
    let first = existing(settings(), "First").expect("a saved connection");
    let second = existing(settings(), "Second").expect("a saved connection");
    let review = review(
        collected(vec![connection("c1", settings())], Vec::new()),
        vec![first.clone(), second],
    );

    assert_eq!(
        review.connections()[0].duplicate.as_ref().map(|duplicate| duplicate.id),
        Some(first.id)
    );
}

#[test]
fn a_different_username_on_the_same_host_is_not_a_duplicate() {
    let local = existing(settings(), "Orders").expect("a saved connection");
    let imported = ForeignConnection {
        username: "readonly".to_owned(),
        ..settings()
    };
    let review = review(collected(vec![connection("c1", imported)], Vec::new()), vec![local]);

    let row = &review.connections()[0];
    assert_eq!(row.duplicate, None);
    assert_eq!(row.resolutions, [Resolution::Add]);
    assert!(row.selected_by_default);
}

#[test]
fn redis_connections_differ_by_database_index_and_none_named_is_index_zero() {
    let redis = |database: &str| ForeignConnection {
        port: 6379,
        database: database.to_owned(),
        engine: "Redis".to_owned(),
        ..named("Cache")
    };
    let local = existing(redis("0"), "Cache").expect("a saved connection");
    let review = review(
        collected(
            vec![connection("c1", redis("1")), connection("c2", redis(""))],
            Vec::new(),
        ),
        vec![local],
    );

    assert_eq!(review.connections()[0].duplicate, None);
    assert!(review.connections()[1].duplicate.is_some());
}

#[test]
fn an_engine_no_driver_here_opens_is_unsupported_kept_as_written_and_not_selectable() {
    let without_mysql = registry(&[("postgres", &POSTGRES)]);
    for (engine, drivers) in [("Vertica", drivers()), ("MySQL", without_mysql)] {
        let imported = ForeignConnection {
            engine: engine.to_owned(),
            ..settings()
        };
        let review = review_with(imported, &drivers);
        let row = &review.connections()[0];
        assert_eq!(row.engine, engine);
        assert_eq!(row.connection, None);
        assert_eq!(
            row.notes,
            [RowNote::UnsupportedEngine {
                engine: engine.to_owned()
            }]
        );
        assert!(row.resolutions.is_empty());
        assert!(!row.selected_by_default);

        let mut selection = ImportSelection::defaults(&review);
        selection.set_selected(true, "c1", &review);
        assert_eq!(selection.resolution("c1"), None);
        assert!(plan(&review, &selection).is_empty());
    }
}

#[test]
fn an_engine_differing_only_in_case_is_matched() {
    let row = only_row(ForeignConnection {
        engine: "postgresql".to_owned(),
        ..settings()
    });
    assert_eq!(row.connection.map(|saved| saved.driver_id).as_deref(), Some("postgres"));
    assert!(row.selected_by_default);
}

#[test]
fn a_duplicate_of_an_unsupported_engine_stays_a_duplicate() {
    let local = existing(settings(), "Orders").expect("a saved connection");
    let imported = ForeignConnection {
        engine: "Vertica".to_owned(),
        ..settings()
    };
    let review = review(collected(vec![connection("c1", imported)], Vec::new()), vec![local]);

    let row = &review.connections()[0];
    assert!(row.duplicate.is_some());
    assert_eq!(row.connection, None);
}

#[test]
fn missing_ssh_and_jump_host_keys_and_certificate_paths_each_warn() {
    let mut ssh = tunnel("bastion", ForeignSshAuth::PrivateKey, "~/.ssh/missing_key").expect("a tunnel");
    ssh.jump_hosts = vec![hop("jump", None, "u", ForeignSshAuth::Agent, "~/.ssh/jump")];
    let imported = ForeignConnection {
        ssh: Some(ssh),
        ssl: Some(ForeignSsl {
            mode: ForeignSslMode::VerifyIdentity,
            ca_certificate_path: Some("~/ca.pem".to_owned()),
            client_certificate_path: Some("~/client.pem".to_owned()),
            client_key_path: Some("~/client.key".to_owned()),
        }),
        ..settings()
    };
    let asked = std::sync::Mutex::new(Vec::new());
    let file_exists = |path: &Path| {
        if let Ok(mut asked) = asked.lock() {
            asked.push(path.to_path_buf());
        }
        false
    };
    let review = review_in(
        collected(vec![connection("c1", imported)], Vec::new()),
        library(Vec::new()),
        &drivers(),
        &file_exists,
    );

    assert_eq!(
        review.connections()[0].notes,
        [
            RowNote::SshKeyMissing {
                path: "~/.ssh/missing_key".to_owned()
            },
            RowNote::JumpHostKeyMissing {
                path: "~/.ssh/jump".to_owned()
            },
            RowNote::CaCertificateMissing {
                path: "~/ca.pem".to_owned()
            },
            RowNote::ClientCertificateMissing {
                path: "~/client.pem".to_owned()
            },
            RowNote::ClientKeyMissing {
                path: "~/client.key".to_owned()
            },
        ]
    );
    let asked = asked.into_inner().expect("the paths asked about");
    assert!(asked.contains(&home().join(".ssh/missing_key")));
    assert!(asked.contains(&home().join("ca.pem")));
}

#[test]
fn a_duplicate_carrying_saved_queries_defaults_to_keep_existing() {
    let local = existing(settings(), "Orders").expect("a saved connection");
    let review = review(
        collected(
            vec![connection("c1", settings()), connection("c2", named("Twin"))],
            vec![query("q1", "Locks", "select 1", Some("c1"))],
        ),
        vec![local.clone()],
    );

    let rows = review.connections();
    assert_eq!(rows[0].saved_query_count, 1);
    assert_eq!(
        rows[0].resolutions,
        [
            Resolution::KeepExisting(local.id),
            Resolution::AddCopy,
            Resolution::Replace(local.id)
        ]
    );
    assert_eq!(rows[1].saved_query_count, 0);
    assert_eq!(
        rows[1].resolutions,
        [Resolution::AddCopy, Resolution::Replace(local.id)]
    );
}

#[test]
fn exact_duplicate_queries_in_one_import_collapse_to_the_first() {
    let review = review(
        collected(
            vec![connection("c1", settings())],
            vec![
                query("q1", "Locks", "select 1", Some("c1")),
                query("q2", " locks ", "select 1\n", Some("c1")),
                query("q3", "Locks", "select 1", None),
                query("q4", "Locks", "select 2", Some("c1")),
            ],
        ),
        Vec::new(),
    );

    let references: Vec<&str> = review
        .saved_queries()
        .iter()
        .map(|row| row.reference.as_str())
        .collect();
    assert_eq!(references, ["q1", "q3", "q4"]);
    assert_eq!(review.connections()[0].saved_query_count, 2);
}

#[test]
fn query_rows_carry_their_connection_and_a_derived_name_when_blank() {
    let unsuggested = CollectedSavedQuery {
        suggested: false,
        ..query("q2", "Locks", "select 2", None)
    };
    let review = review(
        collected(
            vec![connection("c1", named("Orders"))],
            vec![query("q1", "  ", "-- Active users\nselect 1", Some("c1")), unsuggested],
        ),
        Vec::new(),
    );

    let scoped = review.query_row("q1").expect("the scoped row");
    assert_eq!(scoped.name, "Active users");
    assert_eq!(scoped.connection.as_deref(), Some("c1"));
    assert_eq!(scoped.connection_name.as_deref(), Some("Orders"));
    assert!(scoped.suggested);
    assert!(!scoped.too_large);

    let global = review.query_row("q2").expect("the global row");
    assert_eq!(global.connection, None);
    assert_eq!(global.connection_name, None);
    assert!(!global.suggested);
}

#[test]
fn a_query_past_the_library_limit_is_too_large_and_unread_files_follow_the_rest() {
    let large = "x".repeat(1024 * 1024 + 1);
    let oversized = CollectedSavedQuery {
        content: SavedQueryContent::Oversized { byte_count: 2_000_000 },
        suggested: false,
        ..query("q3", "Dump", "", Some("c1"))
    };
    let review = review(
        collected(
            vec![connection("c1", settings())],
            vec![
                oversized,
                query("q1", "Huge", &large, None),
                query("q2", "Small", "select 1", None),
            ],
        ),
        Vec::new(),
    );

    let rows = review.saved_queries();
    let references: Vec<&str> = rows.iter().map(|row| row.reference.as_str()).collect();
    assert_eq!(references, ["q1", "q2", "q3"]);
    assert_eq!(
        rows.iter().map(|row| row.too_large).collect::<Vec<_>>(),
        [true, false, true]
    );
    assert_eq!(rows[0].byte_count, 1024 * 1024 + 1);
    assert_eq!(rows[2].byte_count, 2_000_000);
    assert_eq!(rows[2].connection_name.as_deref(), Some("Orders"));
    assert_eq!(review.connections()[0].saved_query_count, 1);
}

#[test]
fn the_group_path_is_trimmed_without_blank_or_invalid_names_and_clamped_to_the_depth_limit() {
    let mut grouped = connection("c1", settings());
    grouped.group_path = ["Client A", " Production ", "  ", "Bad\u{7}Name", "EU", "Primary"]
        .map(str::to_owned)
        .to_vec();
    let review = review(collected(vec![grouped], Vec::new()), Vec::new());

    assert_eq!(review.connections()[0].group_path, ["Client A", "Production", "EU"]);
}

#[test]
fn the_review_keeps_what_the_collection_said_about_passwords() {
    let mut import = collected(vec![connection("c1", settings())], Vec::new());
    import.passwords = PasswordOutcome::LeftInKeychain;
    import.app = ForeignApp::DataGrip;
    let review = review(import, Vec::new());

    assert_eq!(review.passwords(), PasswordOutcome::LeftInKeychain);
    assert_eq!(review.app(), ForeignApp::DataGrip);
    assert!(review.library().connections.is_empty());
}

#[test]
fn every_engine_maps_to_its_driver_and_a_network_port_of_zero_takes_the_default() {
    let cases = [
        ("MySQL", "mysql", 3306),
        ("MariaDB", "mysql", 3306),
        ("PostgreSQL", "postgres", 5432),
        ("SQL Server", "mssql", 1433),
        ("ClickHouse", "clickhouse", 8123),
        ("Cassandra", "cassandra", 9042),
        ("ScyllaDB", "cassandra", 9042),
        ("Redis", "redis", 6379),
        ("MongoDB", "mongodb", 27017),
    ];
    for (engine, driver_id, port) in cases {
        let saved = mapped(ForeignConnection {
            engine: engine.to_owned(),
            port: 0,
            ..settings()
        })
        .expect("a supported engine");
        assert_eq!((saved.driver_id.as_str(), saved.port), (driver_id, port), "{engine}");
        assert_eq!(saved.host, "db.example.com");
        assert_eq!(saved.database, "orders");
        assert_eq!(saved.username, "app");
    }
    let kept = mapped(ForeignConnection {
        port: 6543,
        ..settings()
    })
    .expect("a supported engine");
    assert_eq!(kept.port, 6543);
}

#[test]
fn a_file_engine_takes_the_expanded_path_and_no_host_port_user_or_tunnel() {
    for (engine, driver_id) in [("SQLite", "sqlite"), ("DuckDB", "duckdb")] {
        let row = only_row(ForeignConnection {
            engine: engine.to_owned(),
            database: "~/data/app.db".to_owned(),
            host: "localhost".to_owned(),
            ssh: tunnel("bastion", ForeignSshAuth::Agent, ""),
            ssl: ssl(ForeignSslMode::Required),
            ..settings()
        });
        let saved = row.connection.expect("a supported engine");
        assert_eq!(saved.driver_id, driver_id);
        assert_eq!(saved.database, home().join("data/app.db").display().to_string());
        assert_eq!((saved.host.as_str(), saved.port, saved.username.as_str()), ("", 0, ""));
        assert_eq!(saved.ssh, None);
        assert_eq!(saved.tls, TlsConfig::disabled());
        assert_eq!(
            row.notes,
            [
                RowNote::SshNotKept,
                RowNote::TlsNotKept {
                    from: ForeignSslMode::Required
                }
            ]
        );
    }
}

#[test]
fn a_duckdb_file_comes_from_the_field_the_macos_app_keeps_it_in() {
    let mut imported = ForeignConnection {
        engine: "DuckDB".to_owned(),
        database: String::new(),
        ..settings()
    };
    imported
        .additional_fields
        .insert("duckdbFilePath".to_owned(), "~/warehouse.duckdb".to_owned());
    let row = only_row(imported);

    assert_eq!(
        row.connection.map(|saved| saved.database),
        Some(home().join("warehouse.duckdb").display().to_string())
    );
    assert!(row.notes.is_empty());
}

#[test]
fn an_imported_connection_starts_as_a_new_one_does_in_the_app() {
    let saved = mapped(settings()).expect("a supported engine");
    assert_eq!(saved.safe_mode, SafeModeLevel::Off);
    assert_eq!(saved.external_access, ExternalAccess::ReadOnly);
    assert_eq!(saved.ai_policy, AiPolicy::Ask);
    assert_eq!(saved.query_timeout_secs, None);
    assert_eq!(saved.auth_mode, AuthMode::Password);
    assert_eq!(saved.options, NetworkOptions::default());
    assert_eq!((saved.tags.len(), saved.icon, saved.group_id), (0, None, None));
    assert_eq!(saved.tls, TlsConfig::disabled());
}

#[test]
fn each_tls_mode_maps_to_the_core_mode_and_a_change_is_noted() {
    let cases = [
        (None, TlsMode::Disable, false),
        (Some(ForeignSslMode::Disabled), TlsMode::Disable, false),
        (Some(ForeignSslMode::Preferred), TlsMode::Prefer, false),
        (Some(ForeignSslMode::Required), TlsMode::Require, false),
        (Some(ForeignSslMode::VerifyCa), TlsMode::VerifyFull, true),
        (Some(ForeignSslMode::VerifyIdentity), TlsMode::VerifyFull, false),
    ];
    for (mode, expected, noted) in cases {
        let row = only_row(ForeignConnection {
            ssl: mode.and_then(ssl),
            ..settings()
        });
        let saved = row.connection.expect("a supported engine");
        assert_eq!(saved.tls.mode, expected, "{mode:?}");
        let change = mode.map(|from| RowNote::TlsModeChanged { from, to: expected });
        assert_eq!(
            row.notes,
            change.filter(|_| noted).into_iter().collect::<Vec<_>>(),
            "{mode:?}"
        );
    }
}

#[test]
fn a_mode_the_driver_lacks_becomes_the_nearest_it_has_and_never_weaker_when_a_stronger_exists() {
    let cases = [
        (&VERIFY_ONLY, ForeignSslMode::Required, TlsMode::VerifyFull),
        (&VERIFY_ONLY, ForeignSslMode::Disabled, TlsMode::VerifyFull),
        (&NO_VERIFY, ForeignSslMode::VerifyIdentity, TlsMode::Require),
        (&REDIS, ForeignSslMode::Preferred, TlsMode::Require),
    ];
    for (capabilities, from, to) in cases {
        let row = review_with(
            ForeignConnection {
                ssl: ssl(from),
                ..settings()
            },
            &registry(&[("postgres", capabilities)]),
        )
        .connections()[0]
            .clone();
        assert_eq!(row.connection.map(|saved| saved.tls.mode), Some(to));
        assert_eq!(row.notes, [RowNote::TlsModeChanged { from, to }]);
    }

    let row = review_with(
        ForeignConnection {
            ssl: ssl(ForeignSslMode::Required),
            ..settings()
        },
        &registry(&[("postgres", &NO_TLS)]),
    )
    .connections()[0]
        .clone();
    assert_eq!(row.connection.map(|saved| saved.tls), Some(TlsConfig::disabled()));
    assert_eq!(
        row.notes,
        [RowNote::TlsNotKept {
            from: ForeignSslMode::Required
        }]
    );
}

fn with_ca(mode: ForeignSslMode, path: &str) -> ForeignConnection {
    ForeignConnection {
        ssl: Some(ForeignSsl {
            mode,
            ca_certificate_path: Some(path.to_owned()),
            client_certificate_path: None,
            client_key_path: None,
        }),
        ..settings()
    }
}

#[test]
fn a_ca_file_is_kept_only_with_verify_full_on_a_driver_that_takes_one_as_an_absolute_path() {
    let kept = mapped(with_ca(ForeignSslMode::VerifyIdentity, "~/ca.pem")).expect("a supported engine");
    assert_eq!(kept.tls.ca_file, Some(home().join("ca.pem")));

    let cases = [
        (with_ca(ForeignSslMode::Required, "~/ca.pem"), TlsFileReason::ModeLacks),
        (
            with_ca(ForeignSslMode::VerifyIdentity, "certs/ca.pem"),
            TlsFileReason::RelativePath,
        ),
    ];
    for (imported, reason) in cases {
        let path = imported
            .ssl
            .as_ref()
            .and_then(|ssl| ssl.ca_certificate_path.clone())
            .unwrap_or_default();
        let row = only_row(imported);
        assert_eq!(row.connection.and_then(|saved| saved.tls.ca_file), None);
        assert_eq!(row.notes, [RowNote::CaFileNotKept { path, reason }]);
    }

    let lacking = registry(&[("postgres", &VERIFY_ONLY)]);
    let row = review_with(with_ca(ForeignSslMode::VerifyIdentity, "/etc/ca.pem"), &lacking).connections()[0].clone();
    assert_eq!(row.connection.and_then(|saved| saved.tls.ca_file), None);
    assert_eq!(
        row.notes,
        [RowNote::CaFileNotKept {
            path: "/etc/ca.pem".to_owned(),
            reason: TlsFileReason::EngineLacks
        }]
    );
}

fn with_identity(
    mode: ForeignSslMode,
    certificate: Option<&str>,
    key: Option<&str>,
    engine: &str,
) -> ForeignConnection {
    ForeignConnection {
        engine: engine.to_owned(),
        ssl: Some(ForeignSsl {
            mode,
            ca_certificate_path: None,
            client_certificate_path: certificate.map(str::to_owned),
            client_key_path: key.map(str::to_owned),
        }),
        ..settings()
    }
}

#[test]
fn a_client_identity_needs_both_files_tls_on_and_a_driver_that_takes_one() {
    let kept = mapped(with_identity(
        ForeignSslMode::Required,
        Some("~/client.pem"),
        Some("~/client.key"),
        "PostgreSQL",
    ))
    .expect("a supported engine");
    assert_eq!(
        kept.tls.client_identity,
        Some(ClientIdentity {
            certificate: home().join("client.pem"),
            key: home().join("client.key"),
        })
    );

    let cases = [
        (
            with_identity(ForeignSslMode::Required, Some("~/client.pem"), None, "PostgreSQL"),
            TlsFileReason::Incomplete,
        ),
        (
            with_identity(ForeignSslMode::Required, Some("~/c.pem"), Some("~/c.key"), "SQL Server"),
            TlsFileReason::EngineLacks,
        ),
        (
            with_identity(ForeignSslMode::Disabled, Some("~/c.pem"), Some("~/c.key"), "PostgreSQL"),
            TlsFileReason::ModeLacks,
        ),
        (
            with_identity(ForeignSslMode::Required, Some("c.pem"), Some("~/c.key"), "PostgreSQL"),
            TlsFileReason::RelativePath,
        ),
    ];
    for (imported, reason) in cases {
        let row = only_row(imported);
        assert_eq!(row.connection.and_then(|saved| saved.tls.client_identity), None);
        assert_eq!(row.notes, [RowNote::ClientIdentityNotKept { reason }]);
    }
}

#[test]
fn each_ssh_sign_in_maps_and_carries_only_its_own_secret() {
    let credentials = Some(ForeignCredentials {
        password: secret("db"),
        ssh_password: secret("ssh"),
        key_passphrase: secret("phrase"),
    });
    let cases = [
        (
            ForeignSshAuth::Password,
            "",
            SavedSshAuth::Password,
            SecretKind::SshPassword,
        ),
        (
            ForeignSshAuth::PrivateKey,
            "~/.ssh/id_ed25519",
            SavedSshAuth::PrivateKey {
                path: Some(home().join(".ssh/id_ed25519")),
                has_passphrase: true,
            },
            SecretKind::SshPassphrase,
        ),
    ];
    for (auth, key, expected, kind) in cases {
        let mut ssh = tunnel("bastion", auth, key).expect("a tunnel");
        ssh.port = Some(2222);
        let mut row = connection(
            "c1",
            ForeignConnection {
                ssh: Some(ssh),
                ..settings()
            },
        );
        row.credentials = credentials.clone();
        let review = review(collected(vec![row], Vec::new()), Vec::new());
        let row = &review.connections()[0];
        assert_eq!(
            row.connection.as_ref().and_then(|saved| saved.ssh.clone()),
            Some(SavedSshConfig {
                host: "bastion".to_owned(),
                port: Some(2222),
                username: Some("deploy".to_owned()),
                jump_hosts: Vec::new(),
                auth: expected,
            })
        );
        assert!(row.carries_credentials);
        assert!(row.notes.is_empty());
        assert_eq!(
            applied_secrets(&review),
            [
                (SecretKind::DatabasePassword, "db".to_owned()),
                (kind, secret_text(kind))
            ]
        );
    }
}

fn secret_text(kind: SecretKind) -> String {
    match kind {
        SecretKind::DatabasePassword => "db",
        SecretKind::SshPassword => "ssh",
        SecretKind::SshPassphrase => "phrase",
    }
    .to_owned()
}

fn applied_secrets(review: &ImportReview) -> Vec<(SecretKind, String)> {
    let dir = tempfile::tempdir();
    let Ok(dir) = dir else {
        return Vec::new();
    };
    let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro"));
    let selection = ImportSelection::defaults(review);
    let Ok(applied) = apply_blocking(review, &plan(review, &selection), &store) else {
        return Vec::new();
    };
    applied
        .connections
        .iter()
        .flat_map(|connection| &connection.secrets)
        .map(|secret| (secret.kind, secret.secret.expose_secret().to_owned()))
        .collect()
}

#[test]
fn an_agent_tunnel_keeps_no_password_a_blank_port_and_user_are_left_out_and_a_relative_key_is_dropped() {
    let mut agent = tunnel(" bastion ", ForeignSshAuth::Agent, "").expect("a tunnel");
    agent.port = Some(0);
    agent.username = " ".to_owned();
    let mut row = connection(
        "c1",
        ForeignConnection {
            ssh: Some(agent),
            ..settings()
        },
    );
    row.credentials = Some(ForeignCredentials {
        ssh_password: secret("ssh"),
        ..ForeignCredentials::default()
    });
    let review = review(collected(vec![row], Vec::new()), Vec::new());
    let ssh = review.connections()[0]
        .connection
        .as_ref()
        .and_then(|saved| saved.ssh.clone());
    assert_eq!(
        ssh,
        Some(SavedSshConfig {
            host: "bastion".to_owned(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        })
    );
    assert!(!review.connections()[0].carries_credentials);

    let row = only_row(ForeignConnection {
        ssh: tunnel("bastion", ForeignSshAuth::PrivateKey, "keys/id"),
        ..settings()
    });
    assert_eq!(
        row.connection.and_then(|saved| saved.ssh).map(|ssh| ssh.auth),
        Some(SavedSshAuth::PrivateKey {
            path: None,
            has_passphrase: false
        })
    );
    assert_eq!(
        row.notes,
        [RowNote::SshKeyNotKept {
            path: "keys/id".to_owned()
        }]
    );
}

#[test]
fn jump_hosts_become_hops_and_what_a_hop_cannot_keep_is_noted() {
    let mut ssh = tunnel("bastion", ForeignSshAuth::Agent, "").expect("a tunnel");
    ssh.jump_hosts = vec![
        hop(" jump1 ", Some(2200), "ops", ForeignSshAuth::Agent, ""),
        hop("fd00::1", None, "", ForeignSshAuth::PrivateKey, "~/.ssh/jump"),
        hop("bad,host", None, "ops", ForeignSshAuth::Agent, ""),
        hop("", None, "ops", ForeignSshAuth::Agent, ""),
        hop("j3", Some(0), "me", ForeignSshAuth::Password, ""),
    ];
    let row = only_row(ForeignConnection {
        ssh: Some(ssh),
        ..settings()
    });

    assert_eq!(
        row.connection.and_then(|saved| saved.ssh).map(|ssh| ssh.jump_hosts),
        Some(vec![
            "ops@jump1:2200".to_owned(),
            "[fd00::1]".to_owned(),
            "me@j3".to_owned()
        ])
    );
    assert_eq!(
        row.notes,
        [
            RowNote::JumpHostKeyNotKept {
                host: "fd00::1".to_owned(),
                path: "~/.ssh/jump".to_owned()
            },
            RowNote::JumpHostNotKept {
                host: "bad,host".to_owned()
            },
            RowNote::JumpHostNotKept { host: String::new() },
            RowNote::JumpHostPasswordNotKept { host: "j3".to_owned() },
        ]
    );
}

#[test]
fn each_colour_keeps_its_name_and_gray_becomes_slate() {
    let cases = [
        (ForeignColor::Red, ConnectionColor::Red),
        (ForeignColor::Orange, ConnectionColor::Orange),
        (ForeignColor::Yellow, ConnectionColor::Yellow),
        (ForeignColor::Green, ConnectionColor::Green),
        (ForeignColor::Blue, ConnectionColor::Blue),
        (ForeignColor::Purple, ConnectionColor::Purple),
        (ForeignColor::Pink, ConnectionColor::Pink),
        (ForeignColor::Gray, ConnectionColor::Slate),
    ];
    for (foreign, expected) in cases {
        let saved = mapped(ForeignConnection {
            color: Some(foreign),
            ..settings()
        });
        assert_eq!(saved.and_then(|saved| saved.color), Some(expected));
    }
}

#[test]
fn a_database_password_is_kept_for_a_login_but_not_for_a_file_or_a_connection_that_prompts() {
    let with_password = |settings: ForeignConnection| {
        let mut row = connection("c1", settings);
        row.credentials = password("secret");
        review(collected(vec![row], Vec::new()), Vec::new())
    };
    let login = with_password(settings());
    assert_eq!(
        applied_secrets(&login),
        [(SecretKind::DatabasePassword, "secret".to_owned())]
    );

    let sqlite = with_password(ForeignConnection {
        engine: "SQLite".to_owned(),
        database: "/srv/app.db".to_owned(),
        ..settings()
    });
    assert!(!sqlite.connections()[0].carries_credentials);

    let mut prompting = settings();
    prompting
        .additional_fields
        .insert("promptForPassword".to_owned(), "true".to_owned());
    let prompting = with_password(prompting);
    assert!(!prompting.connections()[0].carries_credentials);
    assert!(prompting.connections()[0].notes.is_empty());
}

#[test]
fn a_field_the_core_has_no_home_for_is_noted() {
    let mut imported = settings();
    imported
        .additional_fields
        .insert("awsRegion".to_owned(), "eu-west-1".to_owned());
    imported
        .additional_fields
        .insert("promptForPassword".to_owned(), "true".to_owned());
    let row = only_row(imported);

    assert_eq!(
        row.notes,
        [RowNote::FieldsNotKept {
            fields: vec!["awsRegion".to_owned()]
        }]
    );
}

#[test]
fn a_name_loses_what_cannot_be_seen_and_a_blank_one_names_the_host_or_file() {
    assert_eq!(
        mapped(named("Pro\u{200b}d\tA ")).map(|saved| saved.name).as_deref(),
        Some("Prod A")
    );
    assert_eq!(
        mapped(named(" ")).map(|saved| saved.name).as_deref(),
        Some("db.example.com")
    );
    let file = ForeignConnection {
        engine: "SQLite".to_owned(),
        database: "/srv/app.db".to_owned(),
        ..named("")
    };
    assert_eq!(mapped(file).map(|saved| saved.name).as_deref(), Some("app.db"));
    assert_eq!(only_row(named(" ")).name, " ");
}

struct Duplicates {
    review: ImportReview,
    existing: Uuid,
}

// Two rows duplicate one saved connection, a third is new.
fn duplicates(with_queries: bool) -> Option<Duplicates> {
    let local = existing(settings(), "Orders")?;
    let queries = if with_queries {
        vec![query("q1", "Locks", "select 1", Some("c1"))]
    } else {
        Vec::new()
    };
    let review = review(
        collected(
            vec![
                connection("c1", named("First")),
                connection("c2", named("Second")),
                connection("c3", on_host("New", "new.example.com")),
            ],
            queries,
        ),
        vec![local.clone()],
    );
    Some(Duplicates {
        review,
        existing: local.id,
    })
}

#[test]
fn defaults_select_new_connections_and_leave_duplicates_unchecked() {
    let Duplicates { review, .. } = duplicates(false).expect("a review");
    let selection = ImportSelection::defaults(&review);

    assert_eq!(selection.resolution("c1"), None);
    assert_eq!(selection.resolution("c2"), None);
    assert_eq!(selection.resolution("c3"), Some(Resolution::Add));
    assert!(selection.is_selected("c3"));
    assert!(!selection.is_selected("c1"));
}

#[test]
fn checking_a_duplicate_gives_the_row_default() {
    let Duplicates { review, existing } = duplicates(true).expect("a review");
    let mut selection = ImportSelection::defaults(&review);

    selection.set_selected(true, "c1", &review);
    selection.set_selected(true, "c2", &review);

    assert_eq!(selection.resolution("c1"), Some(Resolution::KeepExisting(existing)));
    assert_eq!(selection.resolution("c2"), Some(Resolution::AddCopy));
}

#[test]
fn a_second_replace_of_the_same_connection_is_refused() {
    let Duplicates { review, existing } = duplicates(false).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c1", &review);
    selection.set_selected(true, "c2", &review);

    assert!(selection.resolve("c1", Resolution::Replace(existing), &review));
    assert!(!selection.resolve("c2", Resolution::Replace(existing), &review));
    assert_eq!(selection.resolution("c2"), Some(Resolution::AddCopy));

    let second = review.connection_row("c2").expect("the second row");
    assert_eq!(selection.offered_resolutions(second), [Resolution::AddCopy]);
    let first = review.connection_row("c1").expect("the first row");
    assert_eq!(
        selection.offered_resolutions(first),
        [Resolution::AddCopy, Resolution::Replace(existing)]
    );
}

#[test]
fn unchecking_the_row_that_holds_a_replace_frees_the_target() {
    let Duplicates { review, existing } = duplicates(false).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c1", &review);
    selection.set_selected(true, "c2", &review);
    selection.resolve("c1", Resolution::Replace(existing), &review);

    selection.set_selected(false, "c1", &review);

    assert_eq!(selection.resolution("c1"), None);
    assert!(selection.resolve("c2", Resolution::Replace(existing), &review));
}

#[test]
fn checking_again_a_row_whose_replace_is_now_held_falls_back_to_its_default() {
    let Duplicates { review, existing } = duplicates(false).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c1", &review);
    selection.resolve("c1", Resolution::Replace(existing), &review);
    selection.set_selected(false, "c1", &review);
    selection.set_selected(true, "c2", &review);
    selection.resolve("c2", Resolution::Replace(existing), &review);

    selection.set_selected(true, "c1", &review);

    assert_eq!(selection.resolution("c1"), Some(Resolution::AddCopy));
    assert_eq!(selection.resolution("c2"), Some(Resolution::Replace(existing)));
}

#[test]
fn a_choice_survives_unchecking_and_checking_the_row_again() {
    let Duplicates { review, existing } = duplicates(false).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c1", &review);
    selection.resolve("c1", Resolution::Replace(existing), &review);

    selection.set_selected(false, "c1", &review);
    selection.set_selected(true, "c1", &review);

    assert_eq!(selection.resolution("c1"), Some(Resolution::Replace(existing)));
}

#[test]
fn a_resolution_the_row_does_not_offer_is_refused() {
    let Duplicates { review, existing } = duplicates(false).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c1", &review);

    let attempts = [
        selection.resolve("c1", Resolution::Add, &review),
        selection.resolve("c1", Resolution::Replace(Uuid::new_v4()), &review),
        selection.resolve("c1", Resolution::KeepExisting(existing), &review),
        selection.resolve("c3", Resolution::AddCopy, &review),
        selection.resolve("missing", Resolution::Add, &review),
    ];

    assert_eq!(attempts, [false; 5]);
    assert_eq!(selection.resolution("c1"), Some(Resolution::AddCopy));
}

#[test]
fn a_query_override_is_stored_until_changed() {
    let Duplicates { review, .. } = duplicates(true).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    let row = review.query_row("q1").expect("the query row");
    assert_eq!(selection.query_override("q1"), None);
    assert!(selection.wants_query(row));

    selection.set_included(false, "q1");
    assert_eq!(selection.query_override("q1"), Some(false));
    assert!(!selection.wants_query(row));

    selection.set_included(true, "q1");
    assert_eq!(selection.query_override("q1"), Some(true));
}

#[test]
fn add_writes_a_new_entry_replace_names_the_saved_id_and_keep_existing_writes_nothing() {
    let replaced = existing(on_host("Old", "replace.example.com"), "Old").expect("a saved connection");
    let kept = existing(on_host("Kept", "kept.example.com"), "Kept").expect("a saved connection");
    let review = review(
        collected(
            vec![
                connection("c1", named("Fresh")),
                connection("c2", on_host("Replacement", "replace.example.com")),
                connection("c3", on_host("Kept", "kept.example.com")),
            ],
            vec![query("q1", "Locks", "select 1", Some("c3"))],
        ),
        vec![replaced.clone(), kept.clone()],
    );
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c2", &review);
    assert!(selection.resolve("c2", Resolution::Replace(replaced.id), &review));
    selection.set_selected(true, "c3", &review);

    let plan = plan(&review, &selection);

    let planned = plan.connections();
    assert_eq!(
        planned.iter().map(|p| p.reference.as_str()).collect::<Vec<_>>(),
        ["c1", "c2"]
    );
    assert_eq!(planned[0].replaces, None);
    assert_eq!(planned[0].connection.name, "Fresh");
    assert_eq!(planned[1].replaces, Some(replaced.id));
    assert_eq!(planned[1].connection.id, replaced.id);
    assert_eq!(planned[1].connection.name, "Replacement");
    assert_eq!(plan.kept_connections(), [("c3".to_owned(), kept.id)]);
    assert_eq!(plan.queries()[0].target(), QueryTarget::Existing(kept.id));
}

#[test]
fn only_written_rows_bring_their_group_path() {
    let kept = existing(on_host("Kept", "kept.example.com"), "Kept").expect("a saved connection");
    let grouped = |reference: &str, settings: ForeignConnection, group: &str| CollectedConnection {
        group_path: vec![group.to_owned()],
        ..connection(reference, settings)
    };
    let review = review(
        collected(
            vec![
                grouped("c1", named("One"), "Team A"),
                grouped("c2", on_host("Two", "two"), "Team B"),
                grouped("c3", on_host("Kept", "kept.example.com"), "Team C"),
            ],
            vec![query("q1", "Locks", "select 1", Some("c3"))],
        ),
        vec![kept.clone()],
    );
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(false, "c2", &review);
    selection.set_selected(true, "c3", &review);

    let plan = plan(&review, &selection);

    assert_eq!(plan.connections().len(), 1);
    let path: Vec<&str> = plan.connections()[0]
        .group_path
        .iter()
        .map(|name| name.as_str())
        .collect();
    assert_eq!(path, ["Team A"]);
    assert_eq!(plan.kept_connections(), [("c3".to_owned(), kept.id)]);
}

#[test]
fn a_plan_with_nothing_to_write_is_empty() {
    let review = review(collected(vec![connection("c1", settings())], Vec::new()), Vec::new());
    let mut selection = ImportSelection::defaults(&review);
    assert!(!plan(&review, &selection).is_empty());

    selection.set_selected(false, "c1", &review);
    assert!(plan(&review, &selection).is_empty());
}

fn available(included: bool) -> Option<QueryStatus> {
    Some(QueryStatus {
        availability: QueryAvailability::Available,
        included,
    })
}

fn unavailable(availability: QueryAvailability) -> Option<QueryStatus> {
    Some(QueryStatus {
        availability,
        included: false,
    })
}

#[test]
fn a_query_whose_connection_is_not_imported_is_skipped_and_one_with_none_cannot_import() {
    let review = review(
        collected(
            vec![connection("c1", settings())],
            vec![
                query("q1", "Scoped", "select 1", Some("c1")),
                query("q2", "Global", "select 2", None),
            ],
        ),
        Vec::new(),
    );
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(false, "c1", &review);
    selection.set_included(true, "q1");
    selection.set_included(true, "q2");

    let plan = plan(&review, &selection);

    assert_eq!(
        plan.query_status("q1"),
        unavailable(QueryAvailability::ConnectionSkipped)
    );
    assert_eq!(plan.query_status("q2"), unavailable(QueryAvailability::NoConnection));
    assert!(plan.queries().is_empty());
    assert!(plan.is_empty());
}

#[test]
fn a_query_another_selected_row_adds_is_held_back_and_keeps_its_own_choice_for_when_that_row_goes() {
    let local = existing(settings(), "Orders").expect("a saved connection");
    let review = review(
        collected(
            vec![connection("c1", named("One")), connection("c2", named("Two"))],
            vec![
                query("q1", "Locks", "select 1", Some("c1")),
                query("q2", "Locks", "select 1", Some("c2")),
            ],
        ),
        vec![local.clone()],
    );
    let select_both = |selection: &mut ImportSelection| {
        selection.set_selected(true, "c1", &review);
        selection.set_selected(true, "c2", &review);
    };
    let planned = |selection: &ImportSelection| {
        plan(&review, selection)
            .queries()
            .iter()
            .map(|query| query.reference.clone())
            .collect::<Vec<_>>()
    };

    let mut both = ImportSelection::defaults(&review);
    select_both(&mut both);
    let both_plan = plan(&review, &both);
    assert_eq!(
        both_plan.kept_connections(),
        [("c1".to_owned(), local.id), ("c2".to_owned(), local.id)]
    );
    assert_eq!(
        both_plan.query_status("q2"),
        unavailable(QueryAvailability::AddedByAnotherRow)
    );
    assert_eq!(planned(&both), ["q1"]);

    both.set_included(false, "q1");
    assert_eq!(planned(&both), ["q2"]);

    both.set_included(false, "q2");
    assert!(planned(&both).is_empty());
}

#[test]
fn a_second_query_of_one_name_on_one_connection_is_held_back_since_a_save_would_overwrite_the_first() {
    let review = review(
        collected(
            vec![connection("c1", settings())],
            vec![
                query("q1", "Report", "select 1", Some("c1")),
                query("q2", "Report", "select 2", Some("c1")),
                query("q3", "report", "select 3", Some("c1")),
            ],
        ),
        Vec::new(),
    );
    let plan = plan(&review, &ImportSelection::defaults(&review));

    assert_eq!(plan.query_status("q1"), available(true));
    assert_eq!(
        plan.query_status("q2"),
        unavailable(QueryAvailability::AddedByAnotherRow)
    );
    assert_eq!(plan.query_status("q3"), available(true));
}

#[test]
fn replace_scopes_queries_to_the_replaced_connection_and_as_copy_to_the_new_one() {
    let Duplicates { review, existing } = duplicates(true).expect("a review");
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c1", &review);

    assert!(selection.resolve("c1", Resolution::Replace(existing), &review));
    assert_eq!(
        plan(&review, &selection).queries()[0].target(),
        QueryTarget::Existing(existing)
    );

    assert!(selection.resolve("c1", Resolution::AddCopy, &review));
    assert_eq!(
        plan(&review, &selection).queries()[0].target(),
        QueryTarget::Imported("c1")
    );
}

#[test]
fn an_unchecked_query_reserves_nothing_for_the_rows_after_it() {
    let review = review(
        collected(
            vec![connection("c1", settings())],
            vec![
                query("q1", "Report", "select 1", Some("c1")),
                query("q2", "Report", "select 2", Some("c1")),
            ],
        ),
        Vec::new(),
    );
    let mut selection = ImportSelection::defaults(&review);
    selection.set_included(false, "q1");

    let plan = plan(&review, &selection);

    assert_eq!(plan.query_status("q1"), available(false));
    assert_eq!(plan.query_status("q2"), available(true));
    assert_eq!(plan.queries().len(), 1);
}

#[test]
fn an_unsuggested_query_starts_unchecked_and_can_be_checked() {
    let unsuggested = CollectedSavedQuery {
        suggested: false,
        ..query("q1", "Script-3", "select 1", Some("c1"))
    };
    let review = review(
        collected(vec![connection("c1", settings())], vec![unsuggested]),
        Vec::new(),
    );
    let mut selection = ImportSelection::defaults(&review);

    assert_eq!(plan(&review, &selection).query_status("q1"), available(false));
    selection.set_included(true, "q1");
    assert_eq!(plan(&review, &selection).queries().len(), 1);
}

#[test]
fn a_too_large_query_or_too_long_name_is_never_included_even_when_checked() {
    let oversized = CollectedSavedQuery {
        content: SavedQueryContent::Oversized { byte_count: 2_000_000 },
        ..query("q2", "Dump", "", Some("c1"))
    };
    let review = review(
        collected(
            vec![connection("c1", settings())],
            vec![
                query("q1", "Huge", &"x".repeat(1024 * 1024 + 1), Some("c1")),
                oversized,
                query("q3", &"n".repeat(201), "select 1", Some("c1")),
                query("q4", &"n".repeat(200), "select 1", Some("c1")),
            ],
        ),
        Vec::new(),
    );
    let mut selection = ImportSelection::defaults(&review);
    for reference in ["q1", "q2", "q3", "q4"] {
        selection.set_included(true, reference);
    }

    let plan = plan(&review, &selection);

    assert_eq!(plan.query_status("q1"), unavailable(QueryAvailability::TooLarge));
    assert_eq!(plan.query_status("q2"), unavailable(QueryAvailability::TooLarge));
    assert_eq!(plan.query_status("q3"), unavailable(QueryAvailability::NameTooLong));
    assert_eq!(plan.query_status("q4"), available(true));
    assert_eq!(plan.query_statuses().len(), 4);
}

fn store_in(dir: &Path) -> ConnectionStore {
    ConnectionStore::new(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
}

fn credentialed(reference: &str, settings: ForeignConnection, secret: &str) -> CollectedConnection {
    CollectedConnection {
        credentials: password(secret),
        ..connection(reference, settings)
    }
}

#[test]
fn the_write_adds_groups_copies_and_replacements_and_hands_back_secrets_in_plan_order() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = store_in(dir.path());
    let held = existing(on_host("Orders", "dup.example.com"), "Orders").expect("a saved connection");
    store.upsert_blocking(held.clone()).expect("a save");

    let mut grouped = credentialed("c1", named("Add"), "one");
    grouped.group_path = vec!["Work".to_owned(), "Staging".to_owned()];
    let review = review_in(
        collected(
            vec![
                grouped,
                credentialed("c2", on_host("Orders", "dup.example.com"), "two"),
                credentialed("c3", on_host("Replace", "dup.example.com"), "three"),
                credentialed("c4", on_host("Unselected", "four"), "four"),
            ],
            Vec::new(),
        ),
        store.list_blocking().expect("the list"),
        &drivers(),
        &|_| true,
    );
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c2", &review);
    selection.set_selected(true, "c3", &review);
    assert!(selection.resolve("c3", Resolution::Replace(held.id), &review));
    selection.set_selected(false, "c4", &review);

    let applied = apply_blocking(&review, &plan(&review, &selection), &store).expect("the write");

    let summary: Vec<(&str, bool, String)> = applied
        .connections
        .iter()
        .map(|applied| {
            let secret = applied
                .secrets
                .iter()
                .map(|s| s.secret.expose_secret().to_owned())
                .collect();
            (applied.reference.as_str(), applied.replaced, secret)
        })
        .collect();
    assert_eq!(
        summary,
        [
            ("c1", false, "one".to_owned()),
            ("c2", false, "two".to_owned()),
            ("c3", true, "three".to_owned())
        ]
    );
    assert_eq!(applied.connections[2].connection.id, held.id);
    assert_eq!(applied.connections[1].connection.name, "Orders (imported)");
    assert!(
        applied
            .connections
            .iter()
            .all(|applied| applied.secrets[0].kind == SecretKind::DatabasePassword)
    );

    let after = store.list_blocking().expect("the list");
    assert_eq!(after.connections.len(), 3);
    let leaf = applied.connections[0].connection.group_id.expect("a group");
    assert_eq!(after.group_tree().label(leaf).as_deref(), Some("Work / Staging"));
}

#[test]
fn a_library_changed_since_the_review_is_refused() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = store_in(dir.path());
    let review = review_in(
        collected(vec![connection("c1", settings())], Vec::new()),
        store.list_blocking().expect("the list"),
        &drivers(),
        &|_| true,
    );
    let meanwhile = existing(on_host("Meanwhile", "elsewhere"), "Meanwhile").expect("a saved connection");
    store.upsert_blocking(meanwhile).expect("a save");

    let refused = apply_blocking(&review, &plan(&review, &ImportSelection::defaults(&review)), &store);

    assert!(matches!(refused, Err(StorageError::ImportOutdated)));
    assert_eq!(store.list_blocking().expect("the list").connections.len(), 1);
}

#[test]
fn queries_land_on_their_connections_and_a_name_the_connection_holds_is_left_alone() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = store_in(dir.path());
    let held = existing(on_host("Kept", "kept.example.com"), "Kept").expect("a saved connection");
    store.upsert_blocking(held.clone()).expect("a save");
    let review = review_in(
        collected(
            vec![
                connection("c1", named("Fresh")),
                connection("c2", on_host("Kept", "kept.example.com")),
            ],
            vec![
                query("q1", " Report ", "select 1", Some("c1")),
                query("q2", "Locks", "select 2", Some("c2")),
                query("q3", "Sizes", "select 3", Some("c2")),
            ],
        ),
        store.list_blocking().expect("the list"),
        &drivers(),
        &|_| true,
    );
    let mut selection = ImportSelection::defaults(&review);
    selection.set_selected(true, "c2", &review);
    assert_eq!(selection.resolution("c2"), Some(Resolution::KeepExisting(held.id)));

    let applied = apply_blocking(&review, &plan(&review, &selection), &store).expect("the write");
    assert_eq!(applied.connections.len(), 1);
    let fresh = applied.connections[0].connection.id;
    let targets: Vec<(&str, &str, Uuid, &str)> = applied
        .queries
        .iter()
        .map(|imported| {
            let NewSavedQuery {
                name,
                connection_id,
                connection_name,
                ..
            } = &imported.query;
            (
                imported.reference.as_str(),
                name.as_str(),
                *connection_id,
                connection_name.as_str(),
            )
        })
        .collect();
    assert_eq!(
        targets,
        [
            ("q1", "Report", fresh, "Fresh"),
            ("q2", "Locks", held.id, "Kept"),
            ("q3", "Sizes", held.id, "Kept")
        ]
    );

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("a runtime");
    let outcome = runtime.block_on(async {
        let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
        let saved_queries = QueryHistory::open(&paths).await.expect("the history").saved_queries();
        saved_queries
            .save(NewSavedQuery {
                name: "Locks".to_owned(),
                query: "select 'mine'".to_owned(),
                connection_id: held.id,
                connection_name: "Kept".to_owned(),
            })
            .await
            .expect("a saved query");
        let outcome = save_queries(&applied, &saved_queries).await;
        let mine = saved_queries.list(Some(held.id)).await.expect("the queries");
        (outcome, mine)
    });

    let (outcome, mine) = outcome;
    assert_eq!((outcome.added, outcome.already_saved, outcome.failed), (2, 1, 0));
    let locks = mine
        .iter()
        .find(|query| query.name == "Locks")
        .expect("the user's query");
    assert_eq!(locks.query, "select 'mine'");
}

#[test]
fn a_mongo_seed_list_and_auth_database_become_the_cores_options_and_are_dropped_where_no_driver_reads_them() {
    let seeded = ForeignConnection {
        engine: "MongoDB".to_owned(),
        host: "cluster0.example.net".to_owned(),
        port: 27017,
        additional_fields: [
            ("mongoUseSrv".to_owned(), "true".to_owned()),
            ("mongoAuthSource".to_owned(), "admin".to_owned()),
        ]
        .into(),
        ..settings()
    };
    let row = only_row(seeded.clone());
    let options = row.connection.expect("a supported engine").options;
    assert!(options.dns_seed_list);
    assert_eq!(options.auth_database.as_deref(), Some("admin"));
    assert!(row.notes.is_empty(), "{:?}", row.notes);

    let elsewhere = only_row(ForeignConnection {
        engine: "PostgreSQL".to_owned(),
        ..seeded
    });
    assert!(!elsewhere.connection.expect("a supported engine").options.dns_seed_list);
    assert_eq!(
        elsewhere.notes,
        [RowNote::FieldsNotKept {
            fields: vec!["mongoAuthSource".to_owned(), "mongoUseSrv".to_owned()]
        }]
    );
}

#[test]
fn tls_settings_the_importer_could_not_read_are_noted_and_leave_the_row_unchecked() {
    let unread = ForeignConnection {
        additional_fields: [("tlsSettingsUnread".to_owned(), "true".to_owned())].into(),
        ..settings()
    };
    let row = only_row(unread);
    assert_eq!(row.notes, [RowNote::TlsSettingsNotRead]);
    assert!(!row.selected_by_default);
    assert!(row.connection.is_some(), "the row can still be checked by hand");
}

#[test]
fn tls_the_other_app_used_with_its_ssl_setting_off_is_noted_and_keeps_the_row_checked() {
    let defaulted = |mode| ForeignConnection {
        ssl: Some(ForeignSsl {
            mode,
            ca_certificate_path: None,
            client_certificate_path: None,
            client_key_path: None,
        }),
        additional_fields: [("tlsFromDriverDefault".to_owned(), "true".to_owned())].into(),
        ..settings()
    };

    let preferred = only_row(defaulted(ForeignSslMode::Preferred));
    assert_eq!(
        preferred.notes,
        [RowNote::TlsFromDriverDefault {
            mode: ForeignSslMode::Preferred
        }]
    );
    assert!(preferred.selected_by_default);
    assert_eq!(
        preferred.connection.expect("a supported engine").tls.mode,
        TlsMode::Prefer
    );

    let verified = only_row(defaulted(ForeignSslMode::VerifyIdentity));
    assert_eq!(
        verified.notes,
        [RowNote::TlsFromDriverDefault {
            mode: ForeignSslMode::VerifyIdentity
        }]
    );
    assert_eq!(
        verified.connection.expect("a supported engine").tls.mode,
        TlsMode::VerifyFull
    );

    let without_tls = only_row(ForeignConnection {
        ssl: None,
        ..defaulted(ForeignSslMode::Required)
    });
    assert!(without_tls.notes.is_empty(), "{:?}", without_tls.notes);
}
