use std::future::Future;

use drivers_mssql::MssqlDriver;
use secrecy::SecretString;
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError};
use testcontainers::ContainerAsync;
use testcontainers::ImageExt;
use testcontainers::core::Mount;
use testcontainers_modules::mssql_server::MssqlServer;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

pub(crate) async fn start_mssql(durable: bool) -> (ContainerAsync<MssqlServer>, ConnectOptions) {
    let image = MssqlServer::default()
        .with_accept_eula()
        .with_startup_timeout(std::time::Duration::from_secs(180));
    let container = if durable {
        image.start().await
    } else {
        image
            .with_mount(Mount::tmpfs_mount("/var/opt/mssql").with_mode(0o1777))
            .start()
            .await
    }
    .expect("start MSSQL container");
    let options = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: container.get_host_port_ipv4(1433).await.expect("port"),
        database: "master".into(),
        username: "sa".into(),
        password: SecretString::new(MssqlServer::DEFAULT_SA_PASSWORD.to_string().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        ..Default::default()
    };
    if let Err(error) = wait_for_authenticated_login(|| async {
        let connection = MssqlDriver.connect(options.clone()).await?;
        connection.query("SELECT 1").await?;
        connection.close().await
    })
    .await
    {
        let logs = container_logs(&container).await;
        panic!("SQL Server did not accept an authenticated query: {error}\n{logs}");
    }
    (container, options)
}

async fn wait_for_authenticated_login<F, Fut>(mut attempt: F) -> Result<(), DriverError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<(), DriverError>>,
{
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(DriverError::TimedOut);
        }
        match tokio::time::timeout_at(deadline, attempt()).await {
            Err(_) => return Err(DriverError::TimedOut),
            Ok(Ok(())) => return Ok(()),
            Ok(Err(DriverError::AuthFailed)) => {
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return Err(DriverError::AuthFailed);
                }
                tokio::time::sleep(std::time::Duration::from_millis(500).min(remaining)).await;
            }
            Ok(Err(error)) => return Err(error),
        }
    }
}

async fn container_logs(container: &ContainerAsync<MssqlServer>) -> String {
    let stdout = container.stdout_to_vec().await.unwrap_or_default();
    let stderr = container.stderr_to_vec().await.unwrap_or_default();
    format!(
        "SQL Server stdout:\n{}\nSQL Server stderr:\n{}",
        String::from_utf8_lossy(&stdout),
        String::from_utf8_lossy(&stderr)
    )
    .replace(MssqlServer::DEFAULT_SA_PASSWORD, "[redacted]")
}

#[tokio::test(start_paused = true)]
async fn mssql_startup_retries_authentication_until_server_upgrade_finishes() {
    let mut attempts = 0;
    wait_for_authenticated_login(|| {
        attempts += 1;
        async move {
            if attempts < 3 {
                Err(DriverError::AuthFailed)
            } else {
                Ok(())
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(attempts, 3);
}

#[tokio::test(start_paused = true)]
async fn mssql_startup_does_not_retry_non_authentication_errors() {
    let mut attempts = 0;
    let error = wait_for_authenticated_login(|| {
        attempts += 1;
        async { Err(DriverError::ConnectionRefused) }
    })
    .await
    .unwrap_err();
    assert!(matches!(error, DriverError::ConnectionRefused));
    assert_eq!(attempts, 1);
}

#[tokio::test(start_paused = true)]
async fn mssql_startup_stops_retrying_after_sixty_seconds() {
    let mut attempts = 0;
    let error = wait_for_authenticated_login(|| {
        attempts += 1;
        async { Err(DriverError::AuthFailed) }
    })
    .await
    .unwrap_err();
    assert!(matches!(error, DriverError::TimedOut));
    assert_eq!(attempts, 120);
}
