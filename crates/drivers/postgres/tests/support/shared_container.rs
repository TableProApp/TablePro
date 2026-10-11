use std::sync::{LazyLock, Mutex as StdMutex};

use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig, Value};
use testcontainers::ContainerAsync;
use testcontainers::ImageExt;
use testcontainers::core::{ExecCommand, Mount};
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio::sync::{Mutex, MutexGuard, OnceCell};

struct Server {
    options: ConnectOptions,
}

pub(crate) struct TestDatabase {
    _container: Option<ContainerAsync<Postgres>>,
    _test_lock: Option<MutexGuard<'static, ()>>,
}

static SERVER: OnceCell<Server> = OnceCell::const_new();
static CONTAINER: StdMutex<Option<ContainerAsync<Postgres>>> = StdMutex::new(None);
static TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

pub(crate) async fn start_pg() -> (TestDatabase, ConnectOptions) {
    start_pg_with_durability(false).await
}

pub(crate) async fn start_pg_durable() -> (TestDatabase, ConnectOptions) {
    start_pg_with_durability(true).await
}

async fn start_pg_with_durability(durable: bool) -> (TestDatabase, ConnectOptions) {
    if can_reuse_server(
        &std::env::args().skip(1).collect::<Vec<_>>(),
        std::env::var_os("TABLEPRO_TEST_RUN_ID").is_some(),
    ) && !durable
    {
        let test_lock = TEST_LOCK.lock().await;
        let server = SERVER.get_or_init(start_shared_server).await;
        reset_server(server).await;
        return (
            TestDatabase {
                _container: None,
                _test_lock: Some(test_lock),
            },
            test_options(&server.options),
        );
    }
    let (container, server) = create_server(durable).await;
    (
        TestDatabase {
            _container: Some(container),
            _test_lock: None,
        },
        test_options(&server.options),
    )
}

fn test_options(options: &ConnectOptions) -> ConnectOptions {
    ConnectOptions {
        database: "test".into(),
        ..options.clone()
    }
}

fn can_reuse_server(args: &[String], runner_cleans_container: bool) -> bool {
    let serial = args.iter().any(|arg| arg == "--test-threads=1")
        || args
            .windows(2)
            .any(|pair| pair[0] == "--test-threads" && pair[1] == "1");
    let exact = args.iter().any(|arg| arg == "--exact");
    let selection = args.iter().find(|arg| !arg.starts_with('-') && *arg != "1");
    runner_cleans_container && serial && !exact && selection.is_none_or(|arg| arg == "value_contract")
}

async fn start_shared_server() -> Server {
    let (container, server) = create_server(false).await;
    *CONTAINER.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(container);
    server
}

async fn create_server(durable: bool) -> (ContainerAsync<Postgres>, Server) {
    let image = if durable {
        Postgres::default().with_fsync_enabled()
    } else {
        Postgres::default()
    }
    .with_tag("16-alpine");
    let image = if durable {
        image
    } else {
        image
            .with_cmd([
                "postgres",
                "-c",
                "fsync=off",
                "-c",
                "synchronous_commit=off",
                "-c",
                "full_page_writes=off",
            ])
            .with_mount(Mount::tmpfs_mount("/var/lib/postgresql/data"))
    };
    let image = match std::env::var("TABLEPRO_TEST_RUN_ID") {
        Ok(run_id) => image.with_label("com.tablepro.test-run", run_id),
        Err(_) => image,
    };
    let container = image.start().await.expect("start postgres container");
    let options = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: container.get_host_port_ipv4(5432).await.expect("port"),
        database: "postgres".into(),
        username: "postgres".into(),
        password: secrecy::SecretString::new("postgres".to_string().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    let connection = PgDriver.connect(options.clone()).await.expect("connect to postgres");
    connection
        .execute("CREATE DATABASE test TEMPLATE template0")
        .await
        .expect("create postgres test database");
    connection.close().await.expect("close postgres setup connection");
    (container, Server { options })
}

async fn reset_server(server: &Server) {
    let connection = PgDriver
        .connect(server.options.clone())
        .await
        .expect("connect to shared postgres");
    for statement in [
        "DROP DATABASE IF EXISTS test WITH (FORCE)",
        "CREATE DATABASE test TEMPLATE template0",
        "DROP DATABASE IF EXISTS alpha_db WITH (FORCE)",
        "ALTER ROLE postgres RESET search_path",
    ] {
        connection.execute(statement).await.expect("reset postgres test server");
    }
    connection.close().await.expect("close postgres setup connection");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_fixtures_reset_database_and_role_search_path() {
    {
        let (_fixture, options) = start_pg().await;
        let connection = PgDriver.connect(options).await.unwrap();
        connection
            .execute("CREATE TABLE fixture_isolation (value INT)")
            .await
            .unwrap();
        connection
            .execute("ALTER ROLE postgres SET search_path TO pg_catalog")
            .await
            .unwrap();
    }
    let (_fixture, options) = start_pg().await;
    let connection = PgDriver.connect(options).await.unwrap();
    assert!(connection.query("SELECT * FROM fixture_isolation").await.is_err());
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("public".into())]],
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_test_database_exists_for_an_exact_test_selection() {
    let (container, server) = create_server(false).await;
    let fixture = TestDatabase {
        _container: Some(container),
        _test_lock: None,
    };
    let options = test_options(&server.options);
    let connection = PgDriver.connect(options).await.unwrap();
    assert_eq!(
        connection.query("SELECT current_database()::text").await.unwrap().rows,
        vec![vec![Value::Text("test".into())]],
    );
    assert_eq!(
        connection
            .query("SELECT current_setting('fsync'), current_setting('synchronous_commit'), current_setting('full_page_writes')")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("off".into()), Value::Text("off".into()), Value::Text("off".into())]],
    );
    let container = fixture._container.as_ref().unwrap();
    let mut mounts = container.exec(ExecCommand::new(["cat", "/proc/mounts"])).await.unwrap();
    let mounts = String::from_utf8(mounts.stdout_to_vec().await.unwrap()).unwrap();
    assert!(mounts.lines().any(|line| {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        fields.get(1) == Some(&"/var/lib/postgresql/data") && fields.get(2) == Some(&"tmpfs")
    }));
}

#[test]
fn shared_server_requires_a_serial_complete_selection() {
    assert!(can_reuse_server(
        &["--include-ignored".into(), "--test-threads=1".into()],
        true
    ));
    assert!(can_reuse_server(
        &[
            "value_contract".into(),
            "--include-ignored".into(),
            "--test-threads=1".into()
        ],
        true
    ));
    assert!(!can_reuse_server(
        &["--include-ignored".into(), "--test-threads=1".into()],
        false
    ));
    assert!(!can_reuse_server(
        &["value_contract".into(), "--include-ignored".into()],
        true
    ));
    assert!(!can_reuse_server(
        &["value_contract".into(), "--exact".into(), "--test-threads=1".into()],
        true
    ));
    assert!(!can_reuse_server(
        &["specific_test".into(), "--test-threads=1".into()],
        true
    ));
}
