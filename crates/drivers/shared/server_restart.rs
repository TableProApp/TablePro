use std::future::Future;
use std::time::{Duration, Instant};

use tablepro_core::DriverError;

/// Retry the driver's real connection and operation while a restarted service
/// finishes booting. Only connection failures, timeouts and Redis's startup
/// `broken pipe` are transient; authentication and query errors fail at once.
pub async fn retry_operation<F, Fut, T>(server: &str, mut operation: F) -> Result<T, String>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, DriverError>>,
{
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut attempts = 0_u32;
    let mut last_error = String::from("no attempt completed");

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "{server} did not recover after restart in {attempts} attempts; last transient error: {last_error}"
            ));
        }
        attempts += 1;
        let attempt_timeout = remaining.min(Duration::from_secs(10));
        match tokio::time::timeout(attempt_timeout, operation()).await {
            Ok(Ok(value)) => return Ok(value),
            Ok(Err(error)) if is_startup_transient(&error) => last_error = format!("{error:?}"),
            Ok(Err(error)) => {
                return Err(format!(
                    "{server} reconnect failed with a non-transient error: {error:?}"
                ));
            }
            Err(_) => last_error = format!("operation timed out after {attempt_timeout:?}"),
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

fn is_startup_transient(error: &DriverError) -> bool {
    match error {
        DriverError::ConnectionRefused | DriverError::Disconnected | DriverError::TimedOut => true,
        DriverError::Query { message, .. } => message.to_ascii_lowercase().contains("broken pipe"),
        _ => false,
    }
}
