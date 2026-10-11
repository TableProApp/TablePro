use std::sync::{LazyLock, Mutex as StdMutex};

use drivers_mysql::MysqlDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig, Value};
use testcontainers::ImageExt;
use testcontainers::core::{ExecCommand, IntoContainerPort, Mount, WaitFor};
use testcontainers::{ContainerAsync, GenericImage};
use testcontainers_modules::mysql::Mysql;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio::sync::{Mutex, MutexGuard, OnceCell};

struct Server {
    options: ConnectOptions,
    sql_mode: String,
}

pub(crate) struct TestDatabase {
    _container: Option<ContainerAsync<Mysql>>,
    _test_lock: Option<MutexGuard<'static, ()>>,
}

static SERVER: OnceCell<Server> = OnceCell::const_new();
static CONTAINER: StdMutex<Option<ContainerAsync<Mysql>>> = StdMutex::new(None);
static TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static MARIADB_SERVER: OnceCell<Server> = OnceCell::const_new();
static MARIADB_CONTAINER: StdMutex<Option<ContainerAsync<GenericImage>>> = StdMutex::new(None);
static MARIADB_TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

pub(crate) struct MariaDbTestDatabase {
    _container: Option<ContainerAsync<GenericImage>>,
    _test_lock: Option<MutexGuard<'static, ()>>,
}

async fn assert_tmpfs<I: testcontainers::Image>(container: &ContainerAsync<I>, path: &str) {
    let mut result = container.exec(ExecCommand::new(["cat", "/proc/mounts"])).await.unwrap();
    let mounts = String::from_utf8(result.stdout_to_vec().await.unwrap()).unwrap();
    assert!(mounts.lines().any(|line| {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        fields.get(1) == Some(&path) && fields.get(2) == Some(&"tmpfs")
    }));
}

pub(crate) async fn start_mysql() -> (TestDatabase, ConnectOptions) {
    start_mysql_with_durability(false).await
}

pub(crate) async fn start_mysql_durable() -> (TestDatabase, ConnectOptions) {
    start_mysql_with_durability(true).await
}

async fn start_mysql_with_durability(durable: bool) -> (TestDatabase, ConnectOptions) {
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

pub(crate) async fn start_mariadb() -> (MariaDbTestDatabase, ConnectOptions) {
    if can_reuse_server(
        &std::env::args().skip(1).collect::<Vec<_>>(),
        std::env::var_os("TABLEPRO_TEST_RUN_ID").is_some(),
    ) {
        let test_lock = MARIADB_TEST_LOCK.lock().await;
        let server = MARIADB_SERVER.get_or_init(start_shared_mariadb).await;
        reset_server(server).await;
        return (
            MariaDbTestDatabase {
                _container: None,
                _test_lock: Some(test_lock),
            },
            test_options(&server.options),
        );
    }
    let (container, server) = create_mariadb_server().await;
    (
        MariaDbTestDatabase {
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

async fn start_shared_mariadb() -> Server {
    let (container, server) = create_mariadb_server().await;
    *MARIADB_CONTAINER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(container);
    server
}

async fn create_server(durable: bool) -> (ContainerAsync<Mysql>, Server) {
    let image = Mysql::default().with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test");
    let image = if durable {
        image.with_cmd(["--default-authentication-plugin=mysql_native_password"])
    } else {
        image
            .with_cmd([
                "--default-authentication-plugin=mysql_native_password",
                "--innodb-flush-log-at-trx-commit=0",
                "--innodb-doublewrite=0",
                "--sync-binlog=0",
            ])
            .with_mount(Mount::tmpfs_mount("/var/lib/mysql"))
    };
    let image = match std::env::var("TABLEPRO_TEST_RUN_ID") {
        Ok(run_id) => image.with_label("com.tablepro.test-run", run_id),
        Err(_) => image,
    };
    let container = image.start().await.expect("start mysql container");
    let options = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: container.get_host_port_ipv4(3306).await.expect("port"),
        database: "mysql".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    let connection = MysqlDriver.connect(options.clone()).await.expect("connect to mysql");
    let result = connection
        .query("SELECT @@GLOBAL.sql_mode")
        .await
        .expect("read mysql sql_mode");
    let Some(Value::Text(sql_mode)) = result.rows.first().and_then(|row| row.first()) else {
        panic!("unexpected mysql sql_mode result: {:?}", result.rows);
    };
    connection.close().await.expect("close mysql setup connection");
    (
        container,
        Server {
            options,
            sql_mode: sql_mode.clone(),
        },
    )
}

async fn create_mariadb_server() -> (ContainerAsync<GenericImage>, Server) {
    let image = GenericImage::new("mariadb", "11")
        .with_exposed_port(3306.tcp())
        .with_wait_for(WaitFor::message_on_stderr("port: 3306"))
        .with_env_var("MARIADB_ROOT_PASSWORD", "tablepro_test")
        .with_env_var("MARIADB_DATABASE", "test")
        .with_cmd([
            "mariadbd",
            "--innodb-flush-log-at-trx-commit=0",
            "--innodb-doublewrite=0",
            "--sync-binlog=0",
        ])
        .with_mount(Mount::tmpfs_mount("/var/lib/mysql"));
    let image = match std::env::var("TABLEPRO_TEST_RUN_ID") {
        Ok(run_id) => image.with_label("com.tablepro.test-run", run_id),
        Err(_) => image,
    };
    let container = image.start().await.expect("start mariadb container");
    let options = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: container.get_host_port_ipv4(3306).await.expect("port"),
        database: "mysql".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    let connection = MysqlDriver.connect(options.clone()).await.expect("connect to mariadb");
    let result = connection
        .query("SELECT @@GLOBAL.sql_mode")
        .await
        .expect("read mariadb sql_mode");
    let Some(Value::Text(sql_mode)) = result.rows.first().and_then(|row| row.first()) else {
        panic!("unexpected mariadb sql_mode result: {:?}", result.rows);
    };
    connection.close().await.expect("close mariadb setup connection");
    (
        container,
        Server {
            options,
            sql_mode: sql_mode.clone(),
        },
    )
}

async fn reset_server(server: &Server) {
    let connection = MysqlDriver
        .connect(server.options.clone())
        .await
        .expect("connect to shared database");
    connection
        .execute("DROP DATABASE IF EXISTS test")
        .await
        .expect("drop prior test database");
    connection
        .execute("CREATE DATABASE test")
        .await
        .expect("create fresh test database");
    connection
        .execute("DROP DATABASE IF EXISTS alpha_db")
        .await
        .expect("remove prior database-list fixture");
    let sql_mode = format!("SET GLOBAL sql_mode = '{}'", server.sql_mode.replace('\'', "''"));
    connection.execute(&sql_mode).await.expect("reset global sql_mode");
    connection.close().await.expect("close database setup connection");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_fixtures_reset_the_database_on_one_server() {
    {
        let (_fixture, options) = start_mysql().await;
        let connection = MysqlDriver.connect(options).await.unwrap();
        connection
            .execute("CREATE TABLE fixture_isolation (value INT)")
            .await
            .unwrap();
    }
    let (_fixture, options) = start_mysql().await;
    let connection = MysqlDriver.connect(options).await.unwrap();
    assert!(
        connection
            .query("SHOW TABLES LIKE 'fixture_isolation'")
            .await
            .unwrap()
            .rows
            .is_empty()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mariadb_fixtures_reset_the_database_on_one_server() {
    let reuse = can_reuse_server(
        &std::env::args().skip(1).collect::<Vec<_>>(),
        std::env::var_os("TABLEPRO_TEST_RUN_ID").is_some(),
    );
    let first;
    {
        let (_fixture, options) = start_mariadb().await;
        first = (options.host.clone(), options.port);
        let connection = MysqlDriver.connect(options).await.unwrap();
        connection
            .execute("CREATE TABLE fixture_isolation (value INT)")
            .await
            .unwrap();
    }
    let (_fixture, options) = start_mariadb().await;
    if reuse {
        assert_eq!((options.host.clone(), options.port), first);
    }
    let connection = MysqlDriver.connect(options).await.unwrap();
    assert!(
        connection
            .query("SHOW TABLES LIKE 'fixture_isolation'")
            .await
            .unwrap()
            .rows
            .is_empty()
    );
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

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_disposable_storage_disables_durable_flushes() {
    let (container, server) = create_server(false).await;
    let fixture = TestDatabase {
        _container: Some(container),
        _test_lock: None,
    };
    let options = test_options(&server.options);
    let connection = MysqlDriver.connect(options).await.unwrap();
    assert_eq!(
        connection
            .query("SELECT @@GLOBAL.innodb_flush_log_at_trx_commit, @@GLOBAL.innodb_doublewrite, @@GLOBAL.sync_binlog")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(0), Value::Text("OFF".into()), Value::Int(0)]],
    );
    assert_tmpfs(fixture._container.as_ref().unwrap(), "/var/lib/mysql").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mariadb_disposable_storage_disables_durable_flushes() {
    let (container, server) = create_mariadb_server().await;
    let fixture = MariaDbTestDatabase {
        _container: Some(container),
        _test_lock: None,
    };
    let options = test_options(&server.options);
    let connection = MysqlDriver.connect(options).await.unwrap();
    assert_eq!(
        connection
            .query("SELECT @@GLOBAL.innodb_flush_log_at_trx_commit, @@GLOBAL.innodb_doublewrite, @@GLOBAL.sync_binlog")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(0), Value::Text("OFF".into()), Value::Int(0)]],
    );
    assert_tmpfs(fixture._container.as_ref().unwrap(), "/var/lib/mysql").await;
}
