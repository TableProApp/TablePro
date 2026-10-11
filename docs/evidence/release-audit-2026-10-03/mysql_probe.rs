use std::io::Write;

use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, TlsConfig, Value};
use testcontainers::ImageExt;
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mysql::Mysql;

#[macro_export]
macro_rules! tr {
    ($text:expr) => {
        $text.to_string()
    };
}

mod error_text {
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/ui/error_text.rs"));
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tablepro_transport::install_crypto_provider();
    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .start()
        .await?;
    let connection = drivers_mysql::MysqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await?.to_string(),
            port: container.get_host_port_ipv4(3306).await?,
            database: "test".into(),
            username: "root".into(),
            password: secrecy::SecretString::new("tablepro_test".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await?;
    let mut output = std::io::stdout().lock();
    let sql = "SELECT 1 AS id, 'text' AS label WHERE false";
    let positive = connection.query("SELECT 1 AS id, 'text' AS label WHERE true").await?;
    let shared = connection.query(sql).await?;
    let mut transaction = connection.begin().await?;
    let empty = transaction.query(sql).await?;
    transaction.rollback().await?;
    writeln!(output, "projection columns: nonempty={}, shared-empty={}, transaction-empty={}", positive.columns.len(), shared.columns.len(), empty.columns.len())?;
    if positive.columns.len() != 2 || !shared.columns.is_empty() || !empty.columns.is_empty() {
        return Err("zero-row metadata gap no longer reproduced".into());
    }

    connection.execute("CREATE TABLE audit_items (id integer PRIMARY KEY)").await?;
    let statements = vec![
        ("INSERT INTO audit_items VALUES (1)".into(), vec![]),
        ("CREATE TABLE audit_ddl (id integer)".into(), vec![]),
        ("INSERT INTO audit_missing_table VALUES (2)".into(), vec![]),
    ];
    let error = connection
        .execute_in_transaction(&statements)
        .await
        .err()
        .ok_or("the failing batch unexpectedly succeeded")?;
    let persisted = connection.query("SELECT id FROM audit_items ORDER BY id").await?;
    writeln!(output, "batch error: {error:?}")?;
    writeln!(output, "persisted rows after claimed rollback: {:?}", persisted.rows)?;
    writeln!(output, "UI message: {}", error_text::driver_message(&error))?;
    if !matches!(error, DriverError::Transaction { statement_index: 2, .. })
        || persisted.rows != vec![vec![Value::Int(1)]]
    {
        return Err("implicit-commit rollback claim no longer reproduced".into());
    }
    Ok(())
}
