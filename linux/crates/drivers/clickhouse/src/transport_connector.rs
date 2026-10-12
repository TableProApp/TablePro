use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use http::Uri;
use hyper_util::rt::TokioIo;
use tablepro_core::{TimeoutPhase, Transport, TransportError};
use tower_service::Service;

use crate::transport_io::TransportIo;

type Connecting = Pin<Box<dyn Future<Output = Result<TokioIo<TransportIo>, TransportError>> + Send>>;

/// hyper's connector, dialling every connection through the target's
/// transport rather than resolving the URL.
///
/// The URL only names the service for the Host header and the TLS name:
/// the stream comes from `Transport::open`, so the same path serves a
/// direct socket and an SSH forward, and an SSH forward never reaches a
/// DNS lookup of a name only the far side can resolve.
#[derive(Clone)]
pub(crate) struct TransportConnector {
    transport: Arc<dyn Transport>,
    connect_timeout: Duration,
}

impl TransportConnector {
    pub(crate) fn new(transport: Arc<dyn Transport>, connect_timeout: Duration) -> Self {
        Self {
            transport,
            connect_timeout,
        }
    }
}

impl Service<Uri> for TransportConnector {
    type Response = TokioIo<TransportIo>;
    type Error = TransportError;
    // Boxed, because hyper-util's `Connect` needs a future that is both
    // `Unpin` and `Send`.
    type Future = Connecting;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, _destination: Uri) -> Self::Future {
        let transport = self.transport.clone();
        let bound = self.connect_timeout;
        Box::pin(async move {
            match tokio::time::timeout(bound, transport.open()).await {
                Ok(opened) => opened.map(|stream| TokioIo::new(TransportIo::new(stream))),
                Err(_) => Err(TransportError::Timeout {
                    phase: TimeoutPhase::Connect,
                }),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use tablepro_core::{NetworkEndpoint, TransportKind, TransportRoute, TransportStream};

    use super::*;

    #[derive(Debug)]
    struct NeverAnswers {
        service: NetworkEndpoint,
    }

    #[async_trait]
    impl Transport for NeverAnswers {
        fn service_endpoint(&self) -> &NetworkEndpoint {
            &self.service
        }

        fn kind(&self) -> TransportKind {
            TransportKind::DirectTcp
        }

        fn route(&self) -> TransportRoute {
            TransportRoute::Tcp(self.service.clone())
        }

        async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
            std::future::pending().await
        }

        async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
            Ok(Arc::new(Self { service: endpoint }))
        }

        async fn explain_closed_stream(&self) -> Option<TransportError> {
            None
        }
    }

    fn assert_unpin_send<T: Unpin + Send + 'static>() {}

    #[test]
    fn future_is_unpin_send() {
        assert_unpin_send::<<TransportConnector as Service<Uri>>::Future>();
    }

    #[tokio::test(start_paused = true)]
    async fn timeout_maps_connect_phase() {
        let service = NetworkEndpoint::new("db.example.com", 8123).expect("an endpoint");
        let mut connector = TransportConnector::new(Arc::new(NeverAnswers { service }), Duration::from_secs(3));

        let outcome = connector.call(Uri::from_static("http://db.example.com:8123")).await;

        assert!(
            matches!(
                outcome,
                Err(TransportError::Timeout {
                    phase: TimeoutPhase::Connect
                })
            ),
            "a dial that never answered gave {:?}",
            outcome.err()
        );
    }
}
