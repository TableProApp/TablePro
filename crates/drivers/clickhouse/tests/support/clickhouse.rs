use drivers_clickhouse::ClickhouseDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig};
use testcontainers::core::wait::HttpWaitStrategy;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

pub async fn start_clickhouse() -> (ContainerAsync<GenericImage>, ConnectOptions) {
    let container = GenericImage::new("clickhouse/clickhouse-server", "24.8")
        .with_exposed_port(8123.tcp())
        .with_wait_for(WaitFor::http(
            HttpWaitStrategy::new("/ping")
                .with_port(8123.tcp())
                .with_expected_status_code(200u16),
        ))
        .with_env_var("CLICKHOUSE_USER", "default")
        .with_env_var("CLICKHOUSE_PASSWORD", "tablepro")
        .with_env_var("CLICKHOUSE_DB", "default")
        .with_env_var("CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT", "1")
        .with_startup_timeout(std::time::Duration::from_secs(180))
        .start()
        .await
        .expect("start clickhouse container");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(8123).await.expect("port");
    let opts = ConnectOptions {
        host,
        port,
        database: "default".into(),
        username: "default".into(),
        password: secrecy::SecretString::new("tablepro".to_string().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    wait_until_queryable(&opts).await;
    (container, opts)
}

async fn wait_until_queryable(opts: &ConnectOptions) {
    let mut last_error = String::new();
    for _ in 0..120 {
        match ClickhouseDriver.connect(opts.clone()).await {
            Ok(connection) => match connection.execute("SELECT 1").await {
                Ok(_) => return,
                Err(error) => last_error = format!("{error:?}"),
            },
            Err(error) => last_error = format!("{error:?}"),
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    panic!("clickhouse accepted /ping but never answered SELECT 1 within 60s: {last_error}");
}

pub async fn connect(opts: ConnectOptions) -> Box<dyn tablepro_core::Connection> {
    ClickhouseDriver.connect(opts).await.expect("connect")
}
