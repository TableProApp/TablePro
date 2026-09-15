use std::collections::VecDeque;
use std::sync::Mutex;

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError};

use crate::{CallCounters, ConnectionScript, FakeConnection, lock};

#[derive(Debug, Default)]
pub struct FakeDriver {
    connects: Mutex<VecDeque<Result<ConnectionScript, DriverError>>>,
    connections: Mutex<Vec<CallCounters>>,
}

impl FakeDriver {
    pub fn new(connects: impl IntoIterator<Item = Result<ConnectionScript, DriverError>>) -> Self {
        Self {
            connects: Mutex::new(connects.into_iter().collect()),
            connections: Mutex::new(Vec::new()),
        }
    }

    pub fn connection_counters(&self) -> Vec<CallCounters> {
        lock(&self.connections).clone()
    }
}

#[async_trait]
impl DatabaseDriver for FakeDriver {
    fn id(&self) -> &'static str {
        "fake"
    }

    fn display_name(&self) -> &'static str {
        "Fake"
    }

    fn default_port(&self) -> u16 {
        1
    }

    async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let scripted = lock(&self.connects).pop_front();
        let script = scripted.unwrap_or_else(|| {
            Err(DriverError::Protocol(
                "FakeDriver has no scripted connect result".to_owned(),
            ))
        })?;
        let connection = FakeConnection::new(script);
        lock(&self.connections).push(connection.counters());
        Ok(Box::new(connection))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering;

    use super::*;

    #[tokio::test]
    async fn fake_driver_returns_scripted_connect_error() {
        let driver = FakeDriver::new([
            Err(DriverError::Auth { diagnostics: None }),
            Ok(ConnectionScript::default().with_ping(Ok(()))),
        ]);

        assert!(matches!(
            driver.connect(ConnectOptions::default()).await,
            Err(DriverError::Auth { diagnostics: None })
        ));

        let connection = driver.connect(ConnectOptions::default()).await.unwrap();
        connection.ping().await.unwrap();

        assert!(matches!(
            driver.connect(ConnectOptions::default()).await,
            Err(DriverError::Protocol(_))
        ));

        let counters = driver.connection_counters();
        assert_eq!(counters.len(), 1);
        assert_eq!(counters[0].ping.load(Ordering::SeqCst), 1);
    }
}
