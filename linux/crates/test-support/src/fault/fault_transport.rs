use std::io;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    LivenessPolicy, NetworkEndpoint, TimeoutPhase, Transport, TransportError, TransportKind, TransportRoute,
    TransportStream,
};
use tablepro_net::DirectTcpTransport;

use super::fault_state::FaultState;
use super::fault_stream::FaultStream;
use super::route_proxy::RouteProxy;

/// A transport that can lose its route on demand, for tests of what a
/// driver does when the network goes quiet.
///
/// Streams from `open()` carry the faults directly. `route()` points at
/// a private proxy socket that relays through the same faults, for
/// engines whose client library dials the route itself.
#[derive(Debug)]
pub struct FaultTransport {
    dialer: Arc<FaultDialer>,
    proxy: RouteProxy,
}

impl FaultTransport {
    /// Wrap `inner`. It needs a running tokio runtime, because the route
    /// proxy listens from the moment the transport exists.
    pub fn new(inner: Arc<dyn Transport>, liveness: &LivenessPolicy) -> io::Result<Self> {
        Self::sharing(inner, Arc::new(FaultState::default()), liveness.connect_timeout)
    }

    /// A direct TCP route to `endpoint`, the way the app dials a server
    /// without SSH.
    pub fn direct(endpoint: NetworkEndpoint, liveness: &LivenessPolicy) -> io::Result<Self> {
        Self::new(Arc::new(DirectTcpTransport::new(endpoint, liveness)), liveness)
    }

    fn sharing(inner: Arc<dyn Transport>, state: Arc<FaultState>, connect_timeout: Duration) -> io::Result<Self> {
        let dialer = Arc::new(FaultDialer {
            inner,
            state,
            connect_timeout,
        });
        let proxy = RouteProxy::start(dialer.clone())?;
        Ok(Self { dialer, proxy })
    }

    /// From now on nothing gets through: open streams stop answering and
    /// accept writes into nothing, and a new dial times out after the
    /// connect timeout, as it would against a dropped route.
    pub fn black_hole(&self) {
        self.dialer.state.black_hole();
    }

    pub fn is_black_holed(&self) -> bool {
        self.dialer.state.is_black_holed()
    }

    /// Stall reads on the first stream that writes `pattern`, from that
    /// write on. The stream's writes still go through, so the server
    /// gets the request and its answer is what goes missing.
    ///
    /// The pattern is matched against bytes on the wire, so it only
    /// finds plaintext.
    pub fn stall_reads_after_write_containing(&self, pattern: impl Into<Vec<u8>>) {
        self.dialer.state.arm_stall(pattern.into());
    }

    /// How many streams have had their reads stalled.
    pub fn stalls_triggered(&self) -> usize {
        self.dialer.state.stalls()
    }
}

#[async_trait]
impl Transport for FaultTransport {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        self.dialer.inner.service_endpoint()
    }

    fn kind(&self) -> TransportKind {
        self.dialer.inner.kind()
    }

    fn route(&self) -> TransportRoute {
        TransportRoute::UnixSocket(self.proxy.path().to_owned())
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        self.dialer.open().await
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        let inner = self.dialer.inner.reroute(endpoint.clone()).await?;
        let rerouted =
            Self::sharing(inner, self.dialer.state.clone(), self.dialer.connect_timeout).map_err(|error| {
                TransportError::Unreachable {
                    endpoint,
                    detail: error.to_string(),
                }
            })?;
        Ok(Arc::new(rerouted))
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        self.dialer.inner.explain_closed_stream().await
    }
}

/// What both `open()` and the route proxy dial through.
#[derive(Debug)]
pub(super) struct FaultDialer {
    inner: Arc<dyn Transport>,
    state: Arc<FaultState>,
    connect_timeout: Duration,
}

impl FaultDialer {
    pub(super) async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        if self.state.is_black_holed() {
            tokio::time::sleep(self.connect_timeout).await;
            return Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect,
            });
        }
        let stream = self.inner.open().await?;
        Ok(Box::new(FaultStream::new(stream, self.state.clone())))
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, UnixStream};
    use tokio::time::Instant;

    use super::*;

    const QUIET: Duration = Duration::from_millis(200);

    /// A loopback server that echoes every byte back.
    async fn echo_server() -> NetworkEndpoint {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut reader, mut writer) = stream.split();
                    let _ = tokio::io::copy(&mut reader, &mut writer).await;
                });
            }
        });
        NetworkEndpoint::new("127.0.0.1", port).unwrap()
    }

    async fn echoes<S: AsyncReadExt + AsyncWriteExt + Unpin>(stream: &mut S, message: &[u8]) -> bool {
        stream.write_all(message).await.unwrap();
        let mut reply = vec![0_u8; message.len()];
        matches!(
            tokio::time::timeout(QUIET, stream.read_exact(&mut reply)).await,
            Ok(Ok(_)) if reply == message
        )
    }

    #[tokio::test]
    async fn an_open_stream_goes_quiet_once_black_holed() {
        let transport = FaultTransport::direct(echo_server().await, &LivenessPolicy::DESKTOP).unwrap();
        let mut stream = transport.open().await.unwrap();
        assert!(echoes(&mut stream, b"before").await);

        transport.black_hole();

        assert!(transport.is_black_holed());
        assert!(!echoes(&mut stream, b"after").await, "a black-holed stream answered");
    }

    #[tokio::test]
    async fn the_route_proxy_relays_and_carries_the_black_hole() {
        let transport = FaultTransport::direct(echo_server().await, &LivenessPolicy::DESKTOP).unwrap();
        let TransportRoute::UnixSocket(path) = transport.route() else {
            panic!("the route is not the proxy socket");
        };
        let mut relayed = UnixStream::connect(&path).await.unwrap();
        assert!(echoes(&mut relayed, b"through the proxy").await);

        transport.black_hole();

        assert!(
            !echoes(&mut relayed, b"after").await,
            "the proxy relayed through a black hole"
        );
    }

    #[tokio::test]
    async fn only_the_stream_that_wrote_the_pattern_stops_reading() {
        let transport = FaultTransport::direct(echo_server().await, &LivenessPolicy::DESKTOP).unwrap();
        let mut committing = transport.open().await.unwrap();
        let mut resolving = transport.open().await.unwrap();
        transport.stall_reads_after_write_containing("COMMIT");

        assert!(
            echoes(&mut committing, b"COM").await,
            "half the pattern stalled the stream"
        );
        assert!(
            !echoes(&mut committing, b"MIT;").await,
            "the split pattern was not seen"
        );
        assert!(
            echoes(&mut resolving, b"COMMIT; SELECT status").await,
            "the stall was not one-shot"
        );
        assert_eq!(transport.stalls_triggered(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn a_dial_after_the_black_hole_times_out_at_the_connect_timeout() {
        let endpoint = NetworkEndpoint::new("127.0.0.1", 9).unwrap();
        let transport = FaultTransport::direct(endpoint, &LivenessPolicy::DESKTOP).unwrap();
        transport.black_hole();

        let started = Instant::now();
        let outcome = transport.open().await;

        assert!(matches!(
            outcome,
            Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect
            })
        ));
        assert_eq!(started.elapsed(), LivenessPolicy::DESKTOP.connect_timeout);
    }

    #[test]
    fn a_fault_transport_needs_a_runtime_rather_than_panicking() {
        let endpoint = NetworkEndpoint::new("127.0.0.1", 9).unwrap();

        assert!(FaultTransport::direct(endpoint, &LivenessPolicy::DESKTOP).is_err());
    }
}
