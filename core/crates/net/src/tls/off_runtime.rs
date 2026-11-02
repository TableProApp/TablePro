use tablepro_core::DriverError;

/// Run a driver's TLS setup on the blocking pool. It reads the CA and
/// client files and the system trust store, and a slow disk or mount
/// would otherwise hold a runtime worker, with the timers that bound
/// the connect on it.
pub async fn set_up_off_runtime<T: Send + 'static>(
    setup: impl FnOnce() -> Result<T, DriverError> + Send + 'static,
) -> Result<T, DriverError> {
    tokio::task::spawn_blocking(setup)
        .await
        .map_err(|error| DriverError::Protocol(format!("the TLS setup stopped: {error}")))?
}
