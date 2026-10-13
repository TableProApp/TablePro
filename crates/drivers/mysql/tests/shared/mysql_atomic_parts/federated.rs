use super::*;
use secrecy::ExposeSecret;
use testcontainers::GenericImage;
use testcontainers::ImageExt;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers_modules::mysql::Mysql;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_failed_batch_federated_write_survives_rollback() {
    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd([
            "--default-authentication-plugin=mysql_native_password",
            "--federated",
            "--innodb-flush-log-at-trx-commit=0",
            "--innodb-doublewrite=0",
            "--sync-binlog=0",
        ])
        .start()
        .await
        .unwrap();
    let opts = ConnectOptions {
        host: container.get_host().await.unwrap().to_string(),
        port: container.get_host_port_ipv4(3306).await.unwrap(),
        database: "test".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        ..Default::default()
    };
    let conn = connect(opts.clone()).await;
    conn.execute("CREATE TABLE federated_remote_effects (id INT PRIMARY KEY) ENGINE=InnoDB")
        .await
        .unwrap();
    conn.execute("INSERT INTO federated_remote_effects VALUES (1)")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE federated_batch_effects (id INT PRIMARY KEY) ENGINE=FEDERATED \
         CONNECTION='mysql://root:tablepro_test@127.0.0.1:3306/test/federated_remote_effects'",
    )
    .await
    .unwrap();
    assert_federated_dml_effects_survive_rollback(conn.as_ref(), &opts).await;
    conn.close().await.unwrap();
    container.stop().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_failed_batch_federated_write_survives_rollback() {
    let (container, opts) = start_mariadb_with_federated().await;
    let conn = connect(opts.clone()).await;
    conn.execute("CREATE TABLE federated_remote_effects (id INT PRIMARY KEY) ENGINE=InnoDB")
        .await
        .unwrap();
    conn.execute("INSERT INTO federated_remote_effects VALUES (1)")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE federated_batch_effects (id INT PRIMARY KEY) ENGINE=FEDERATED \
         CONNECTION='mysql://root:tablepro_test@127.0.0.1:3306/test/federated_remote_effects'",
    )
    .await
    .unwrap();
    assert_federated_dml_effects_survive_rollback(conn.as_ref(), &opts).await;
    conn.close().await.unwrap();
    container.stop().await.unwrap();
}

async fn assert_federated_dml_effects_survive_rollback(conn: &dyn Connection, opts: &ConnectOptions) {
    let cases = [
        ("INSERT INTO federated_batch_effects VALUES (2)", vec![1, 2]),
        ("UPDATE federated_batch_effects SET id = 20 WHERE id = 2", vec![1, 20]),
        ("DELETE FROM federated_batch_effects WHERE id = 20", vec![1]),
    ];
    for (statement, expected_rows) in cases {
        let batch = vec![
            (statement.to_string(), vec![]),
            ("INSERT INTO missing_federated_batch_effects VALUES (3)".into(), vec![]),
        ];
        let error = conn
            .execute_in_transaction(&batch)
            .await
            .expect_err("the absent table must fail after the FEDERATED write");
        assert!(
            matches!(error, DriverError::Transaction { statement_index: 1, .. }),
            "the failed statement index must be preserved, got {error:?}"
        );
        assert_eq!(
            remote_federated_rows(opts).await,
            expected_rows,
            "remote effects from {statement} must remain after local rollback"
        );
    }
}

async fn start_mariadb_with_federated() -> (testcontainers::ContainerAsync<GenericImage>, ConnectOptions) {
    let image = GenericImage::new("mariadb", "11")
        .with_exposed_port(3306.tcp())
        .with_wait_for(WaitFor::message_on_stderr("port: 3306"))
        .with_env_var("MARIADB_ROOT_PASSWORD", "tablepro_test")
        .with_env_var("MARIADB_DATABASE", "test")
        .with_cmd(["mariadbd", "--plugin-load-add=ha_federated"]);
    let container = image.start().await.unwrap();
    let opts = ConnectOptions {
        host: container.get_host().await.unwrap().to_string(),
        port: container.get_host_port_ipv4(3306).await.unwrap(),
        database: "test".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        ..Default::default()
    };
    (container, opts)
}

async fn remote_federated_rows(opts: &ConnectOptions) -> Vec<i32> {
    let observer = sqlx::mysql::MySqlPoolOptions::new()
        .connect_with(
            sqlx::mysql::MySqlConnectOptions::new()
                .host(&opts.host)
                .port(opts.port)
                .username(&opts.username)
                .password(opts.password.expose_secret())
                .database(&opts.database),
        )
        .await
        .unwrap();
    let rows = sqlx::query_scalar::<_, i32>("SELECT id FROM federated_remote_effects ORDER BY id")
        .fetch_all(&observer)
        .await
        .unwrap();
    observer.close().await;
    rows
}
