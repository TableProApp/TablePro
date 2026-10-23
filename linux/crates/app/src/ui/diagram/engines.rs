//! The diagram read from real servers: a schema of 50 tables joined by
//! foreign keys, on PostgreSQL, MySQL, MariaDB, SQL Server and SQLite,
//! through the app's own connector and session, as the tab reads it.
//!
//! `node_00` points nowhere. Every other `node_N` points at its parent
//! in a binary tree through a nullable `parent_id`; every tenth also at
//! `node_00` through a unique, NOT NULL `owner_id`; and `node_01` at
//! itself through `manager_id`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{GuardedStatement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    FileEndpoint, ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget, TlsConfig, TlsMode,
    WorkspaceSettings, WriteBatch, WriteKind,
};
use tablepro_net::DirectTcpTransport;
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectRequest, ConnectServices, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    NoStoredCredentials, RequestTarget, Session, SessionDeps,
};
use tablepro_ssh::{SshRuntimeCell, SshServices};
use tablepro_test_fixtures::{
    FixtureCredentials, HbaMode, MssqlFixture, MysqlFixture, MysqlFlavour, MysqlOptions, PostgresFixture,
};
use tokio::sync::watch;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use super::fetch::{ReadProgress, read_diagram};
use super::model::SchemaDiagram;

const TABLES: usize = 50;
/// 49 parents, four owners and one manager.
const KEYS: usize = 54;
const CALL: Duration = Duration::from_secs(60);
/// The read of all 50 tables, two at a time, under Rosetta on a laptop.
const READ_LIMIT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Engine {
    Postgres,
    Mysql,
    Mariadb,
    Mssql,
    Sqlite,
}

impl Engine {
    fn quote(self, name: &str) -> String {
        match self {
            Self::Mysql | Self::Mariadb => format!("`{name}`"),
            Self::Mssql => format!("[{name}]"),
            Self::Postgres | Self::Sqlite => format!("\"{name}\""),
        }
    }
}

fn node(at: usize) -> String {
    format!("node_{at:02}")
}

/// The tables, created in an order where each key's table exists first.
fn create_statements(engine: Engine, schema: Option<&str>) -> Vec<String> {
    let qualify = |name: &str| match schema {
        Some(schema) => format!("{}.{}", engine.quote(schema), engine.quote(name)),
        None => engine.quote(name),
    };
    (0..TABLES)
        .map(|at| {
            let mut columns = vec!["id integer NOT NULL PRIMARY KEY".to_owned()];
            let mut keys = Vec::new();
            if at > 0 {
                columns.push("parent_id integer NULL".to_owned());
                keys.push(format!(
                    "FOREIGN KEY (parent_id) REFERENCES {} (id)",
                    qualify(&node((at - 1) / 2))
                ));
            }
            if at > 0 && at % 10 == 0 {
                columns.push("owner_id integer NOT NULL UNIQUE".to_owned());
                keys.push(format!("FOREIGN KEY (owner_id) REFERENCES {} (id)", qualify(&node(0))));
            }
            if at == 1 {
                columns.push("manager_id integer NULL".to_owned());
                keys.push(format!(
                    "FOREIGN KEY (manager_id) REFERENCES {} (id)",
                    qualify(&node(1))
                ));
            }
            columns.extend(keys);
            format!("CREATE TABLE {} ({})", qualify(&node(at)), columns.join(", "))
        })
        .collect()
}

/// What the case connects to, kept alive while it runs.
struct Server {
    request: ConnectRequest,
    /// The schema the diagram reads.
    scope: Option<String>,
    /// The container, or the SQLite file's folder, which goes when this
    /// does.
    _fixture: Box<dyn std::any::Any + Send>,
}

fn password(credentials: &FixtureCredentials) -> Credentials {
    Credentials::Password {
        username: credentials.username.clone(),
        password: SecretString::from(credentials.password.clone()),
    }
}

fn require() -> TlsConfig {
    TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    }
}

struct NetworkServer {
    driver: Arc<dyn DatabaseDriver>,
    host: String,
    port: u16,
    credentials: Credentials,
    database: String,
    tls: TlsConfig,
}

impl NetworkServer {
    fn endpoint(&self) -> NetworkEndpoint {
        NetworkEndpoint::new(&self.host, self.port).expect("a valid endpoint")
    }

    async fn admin(&self) -> Arc<dyn Connection> {
        let liveness = LivenessPolicy::DESKTOP;
        let options = ConnectOptions {
            target: ConnectTarget::Network(NetworkTarget {
                transport: Arc::new(DirectTcpTransport::new(self.endpoint(), &liveness)),
                credentials: self.credentials.clone(),
                database: Some(self.database.clone()),
                tls: self.tls.clone(),
                options: Default::default(),
            }),
            workspace_settings: WorkspaceSettings::workspace(false),
            liveness,
            environment: ConnectEnvironment::new("diagram-fill"),
        };
        self.driver
            .connect(options, CancellationToken::new())
            .await
            .expect("an admin connection")
    }

    fn request(&self) -> ConnectRequest {
        ConnectRequest {
            metadata: metadata(self.driver.as_ref()),
            driver: self.driver.clone(),
            target: RequestTarget::Network {
                endpoint: self.endpoint(),
                ssh: None,
                credentials: self.credentials.clone(),
                database: Some(self.database.clone()),
                tls: self.tls.clone(),
                options: Default::default(),
            },
            workspace_settings: WorkspaceSettings::workspace(false),
            safe_mode: tablepro_core::SafeModeLevel::Off,
        }
    }
}

fn metadata(driver: &dyn DatabaseDriver) -> ConnectionMetadata {
    ConnectionMetadata {
        id: uuid::Uuid::new_v4(),
        name: "Diagram".to_owned(),
        driver_id: driver.id().to_owned(),
    }
}

impl Server {
    async fn start(engine: Engine) -> Self {
        match engine {
            Engine::Postgres => Self::postgres().await,
            Engine::Mysql | Engine::Mariadb => Self::mysql(engine).await,
            Engine::Mssql => Self::mssql().await,
            Engine::Sqlite => Self::sqlite().await,
        }
    }

    /// The tables in a schema of their own, beside a table in `public`
    /// whose key points into it: neither is in the diagram.
    async fn postgres() -> Self {
        let fixture = PostgresFixture::start(HbaMode::Password)
            .await
            .expect("a PostgreSQL container");
        let server = NetworkServer {
            driver: Arc::new(tablepro_driver_postgres::PgDriver),
            host: fixture.host().to_owned(),
            port: fixture.port(),
            credentials: password(&fixture.password_credentials()),
            database: fixture.database().to_owned(),
            tls: TlsConfig::disabled(),
        };
        let mut statements = vec!["CREATE SCHEMA diagram".to_owned()];
        statements.extend(create_statements(Engine::Postgres, Some("diagram")));
        statements.push(
            "CREATE TABLE public.outsider (id integer PRIMARY KEY, node_id integer REFERENCES diagram.node_00 (id))"
                .to_owned(),
        );
        apply(server.admin().await.as_ref(), &statements).await;
        Self {
            request: server.request(),
            scope: Some("diagram".to_owned()),
            _fixture: Box::new(fixture),
        }
    }

    async fn mysql(engine: Engine) -> Self {
        let flavour = match engine {
            Engine::Mariadb => MysqlFlavour::Mariadb,
            _ => MysqlFlavour::Mysql,
        };
        let fixture = MysqlFixture::start_with(MysqlOptions::new(flavour).allowing_plaintext(), None)
            .await
            .expect("a MySQL container");
        let server = NetworkServer {
            driver: Arc::new(tablepro_driver_mysql::MysqlDriver),
            host: fixture.host().to_owned(),
            port: fixture.port(),
            credentials: password(&fixture.password_credentials()),
            database: fixture.database().to_owned(),
            tls: TlsConfig::disabled(),
        };
        apply(server.admin().await.as_ref(), &create_statements(engine, None)).await;
        Self {
            request: server.request(),
            scope: Some(fixture.database().to_owned()),
            _fixture: Box::new(fixture),
        }
    }

    async fn mssql() -> Self {
        let fixture = MssqlFixture::start().await.expect("a SQL Server container");
        let server = NetworkServer {
            driver: Arc::new(tablepro_driver_mssql::MssqlDriver),
            host: fixture.host().to_owned(),
            port: fixture.port(),
            credentials: password(&fixture.password_credentials()),
            database: "master".to_owned(),
            tls: require(),
        };
        apply(
            server.admin().await.as_ref(),
            &create_statements(Engine::Mssql, Some("dbo")),
        )
        .await;
        Self {
            request: server.request(),
            scope: Some("dbo".to_owned()),
            _fixture: Box::new(fixture),
        }
    }

    /// The main schema of a new file, which the sidebar lists with no
    /// schema name.
    async fn sqlite() -> Self {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path: PathBuf = dir.path().join("diagram.sqlite3");
        let driver: Arc<dyn DatabaseDriver> = Arc::new(tablepro_driver_sqlite::SqliteDriver);
        let options = ConnectOptions {
            target: ConnectTarget::File(FileEndpoint::create_new(path.clone()).expect("an absolute path")),
            workspace_settings: WorkspaceSettings::workspace(false),
            liveness: LivenessPolicy::DESKTOP,
            environment: ConnectEnvironment::new("diagram-fill"),
        };
        let admin = driver
            .connect(options, CancellationToken::new())
            .await
            .expect("the new file");
        apply(admin.as_ref(), &create_statements(Engine::Sqlite, None)).await;
        admin.close().await.expect("the file closes");
        Self {
            request: ConnectRequest {
                metadata: metadata(driver.as_ref()),
                driver,
                target: RequestTarget::File(FileEndpoint::open_existing(path).expect("an absolute path")),
                workspace_settings: WorkspaceSettings::workspace(false),
                safe_mode: tablepro_core::SafeModeLevel::Off,
            },
            scope: None,
            _fixture: Box::new(dir),
        }
    }
}

/// Run `statements` as one schema-change batch.
async fn apply(connection: &dyn Connection, statements: &[String]) {
    let steps = statements
        .iter()
        .map(|sql| {
            let mut builder = StatementBuilder::new();
            builder.push_sql(sql);
            GuardedStatement::unguarded(builder.finish())
        })
        .collect();
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified(node(0)),
        steps,
        ForeignKeyMode::Enforced,
    );
    connection
        .write_batch(
            &batch,
            CallOptions::new(Some(Instant::now() + CALL), CancellationToken::new()),
        )
        .await
        .expect("the tables are created");
}

async fn connect(request: &ConnectRequest, tasks: &Tasks) -> Arc<Session> {
    let liveness = LivenessPolicy::DESKTOP;
    let deadlines = Arc::new(DefaultDeadlines::new(liveness));
    let connector = Arc::new(DriverConnector::new(
        ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh: SshServices {
                runtime: Arc::new(SshRuntimeCell::new(std::env::temp_dir().join("tablepro-diagram"))),
                ssh_program: PathBuf::from("ssh"),
                ssh_keygen_program: PathBuf::from("ssh-keygen"),
                askpass_program: PathBuf::from("/nonexistent/tablepro-askpass"),
                config_file: None,
            },
            liveness,
        },
        deadlines.clone(),
    ));
    let pending = connector
        .establish(
            request.clone(),
            CredentialInteraction::Unattended,
            CancellationToken::new(),
        )
        .await
        .unwrap_or_else(|error| panic!("the session did not connect: {error}"));
    Session::start(
        pending,
        SessionDeps {
            connector,
            credentials: Arc::new(NoStoredCredentials),
            deadlines,
            tasks: tasks.clone(),
            prompter: None,
        },
    )
}

fn check(diagram: &SchemaDiagram, schema: Option<&str>) {
    let names: Vec<String> = diagram.tables.iter().map(|table| table.table.name.clone()).collect();
    let expected: Vec<String> = (0..TABLES).map(node).collect();
    assert_eq!(names, expected, "the schema's tables and nothing else");
    for table in &diagram.tables {
        assert_eq!(table.table.schema.as_deref(), schema, "{}", table.table.name);
        let id = table.columns.first().expect("a column");
        assert!(id.name == "id" && id.primary_key, "{}: {id:?}", table.table.name);
    }
    assert_eq!(diagram.relations.len(), KEYS, "{:#?}", diagram.relations);
    let named = |at: usize| diagram.tables[at].table.name.as_str();
    for relation in &diagram.relations {
        let (from, to) = (named(relation.from), named(relation.to));
        let column = &diagram.tables[relation.from].columns[relation.from_columns[0]];
        match column.name.as_str() {
            "parent_id" => assert!(relation.optional && !relation.unique, "{from} -> {to}"),
            "owner_id" => {
                assert_eq!(to, "node_00");
                assert!(!relation.optional && relation.unique, "{from} -> {to}");
            }
            "manager_id" => assert_eq!((from, to), ("node_01", "node_01")),
            other => panic!("a key on {from}.{other}"),
        }
        assert_eq!(diagram.tables[relation.to].columns[relation.to_columns[0]].name, "id");
        assert!(column.foreign_key);
    }
    let node_07 = diagram
        .position_of(&TableRef::new(schema.map(str::to_owned), "node_07"))
        .expect("node_07");
    assert_eq!(
        diagram.neighbours(node_07),
        (vec!["node_03"], vec!["node_15", "node_16"])
    );
}

async fn case(engine: Engine) {
    let tasks = crate::test_support::paused_tasks();
    let server = Server::start(engine).await;
    let session = connect(&server.request, &tasks).await;
    let (progress, watching) = watch::channel(ReadProgress::default());

    let read = tokio::time::timeout(
        READ_LIMIT,
        read_diagram(
            session.clone(),
            server.scope.clone(),
            CancellationToken::new(),
            progress,
        ),
    )
    .await
    .unwrap_or_else(|_| panic!("{engine:?}: the read took longer than {READ_LIMIT:?}"));

    let diagram = read.unwrap_or_else(|failure| panic!("{engine:?}: {}", failure.message()));
    check(&diagram, server.scope.as_deref());
    assert_eq!(
        *watching.borrow(),
        ReadProgress {
            done: TABLES,
            total: TABLES
        }
    );
    let _ = session.begin_shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn postgres_schema_of_50_tables_draws_its_keys() {
    case(Engine::Postgres).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mysql_database_of_50_tables_draws_its_keys() {
    case(Engine::Mysql).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mariadb_database_of_50_tables_draws_its_keys() {
    case(Engine::Mariadb).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn sql_server_schema_of_50_tables_draws_its_keys() {
    case(Engine::Mssql).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sqlite_file_of_50_tables_draws_its_keys() {
    case(Engine::Sqlite).await;
}
