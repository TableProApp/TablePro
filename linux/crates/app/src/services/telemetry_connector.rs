use std::sync::Arc;

use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_session::{ConnectError, ConnectRequest, Connector, PendingSession};
use tokio_util::sync::CancellationToken;

use super::telemetry::Telemetry;

// Every connect goes through the app's connector, so one wrapper counts them all by engine.
pub struct TelemetryConnector {
    inner: Arc<dyn Connector>,
    telemetry: Telemetry,
}

impl TelemetryConnector {
    pub fn new(inner: Arc<dyn Connector>, telemetry: Telemetry) -> Self {
        Self { inner, telemetry }
    }
}

impl Connector for TelemetryConnector {
    fn establish(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<PendingSession, ConnectError>> {
        let driver_id = request.metadata.driver_id.clone();
        self.telemetry.connection_attempted(&driver_id);
        let telemetry = self.telemetry.clone();
        let connecting = self.inner.establish(request, interaction, cancel);
        Box::pin(async move {
            let connected = connecting.await;
            if connected.is_ok() {
                telemetry.connection_succeeded(&driver_id);
            }
            connected
        })
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use tablepro_session::fakes::{FakeConnector, FakeEstablish};
    use tablepro_test_support::ConnectionScript;

    use super::*;
    use crate::services::telemetry::{PersonProperties, TelemetrySettings};
    use crate::test_support::{PostHogCollector, test_runtime};

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "a test has no runtime of its own, so it drives the app's from outside"
    )]
    fn the_first_attempt_and_the_first_success_count_once_each() {
        let runtime = test_runtime();
        let collector = PostHogCollector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let settings = TelemetrySettings {
            key: "phc_test".to_owned(),
            host: collector.url.clone(),
            state_file: dir.path().join("telemetry.json"),
            person: PersonProperties {
                app_version: "0.1.0-test".to_owned(),
                os_version: "Ubuntu 26.04".to_owned(),
                architecture: "arm64".to_owned(),
                locale: "en_US".to_owned(),
            },
        };
        let telemetry = Telemetry::start(settings, true, &runtime.tasks());
        let started = Instant::now();
        while !telemetry.is_sending() {
            assert!(started.elapsed() < Duration::from_secs(20), "the client never started");
            std::thread::sleep(Duration::from_millis(20));
        }
        let fake = FakeConnector::new([
            FakeEstablish::Fail(ConnectError::Cancelled),
            FakeEstablish::Connect(ConnectionScript::default()),
            FakeEstablish::Connect(ConnectionScript::default()),
        ]);
        let connector = TelemetryConnector::new(Arc::new(fake), telemetry.clone());
        let request = || {
            let mut request = FakeConnector::request().expect("a request");
            request.metadata.driver_id = "postgres".to_owned();
            request
        };

        let tasks = runtime.tasks();
        let connected: Vec<bool> = (0..3)
            .map(|_| {
                tasks
                    .handle()
                    .block_on(connector.establish(
                        request(),
                        CredentialInteraction::Unattended,
                        CancellationToken::new(),
                    ))
                    .is_ok()
            })
            .collect();
        telemetry.flush();

        assert_eq!(connected, [false, true, true]);
        let started = Instant::now();
        while collector.named("connection_succeeded").is_empty() {
            assert!(started.elapsed() < Duration::from_secs(20), "the success never arrived");
            std::thread::sleep(Duration::from_millis(20));
        }
        let attempted = collector.named("connection_attempted");
        let succeeded = collector.named("connection_succeeded");
        assert_eq!((attempted.len(), succeeded.len()), (1, 1));
        assert_eq!(attempted[0]["properties"]["database_type"], "PostgreSQL");
        assert_eq!(succeeded[0]["properties"]["database_type"], "PostgreSQL");
    }
}
