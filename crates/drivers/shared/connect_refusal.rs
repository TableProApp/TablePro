use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, TlsConfig};

/// Exercise the driver's real setup path against a local TCP endpoint with no
/// listener and require setup refusal to remain distinct from connection loss.
pub async fn assert_connection_refused<D: DatabaseDriver>(driver: &D) -> Result<(), String> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).map_err(|error| error.to_string())?;
    let port = listener.local_addr().map_err(|error| error.to_string())?.port();
    drop(listener);

    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        database: driver.default_database().into(),
        username: driver.default_username().into(),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    match driver.connect(options).await {
        Err(DriverError::ConnectionRefused) => Ok(()),
        Err(error) => Err(format!(
            "unused local port must map to ConnectionRefused, got {error:?}"
        )),
        Ok(_) => Err("unused local port unexpectedly accepted a connection".into()),
    }
}
