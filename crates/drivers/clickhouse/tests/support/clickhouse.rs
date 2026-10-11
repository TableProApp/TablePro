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
    (container, opts)
}

pub async fn connect(opts: ConnectOptions) -> Box<dyn tablepro_core::Connection> {
    ClickhouseDriver.connect(opts).await.expect("connect")
}
