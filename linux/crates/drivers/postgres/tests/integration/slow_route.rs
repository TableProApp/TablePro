//! A route on which chosen requests reach the server late, as over a
//! congested link: the client's write and shutdown complete at once,
//! the way they do into a socket buffer, and the bytes arrive later.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{NetworkEndpoint, Transport, TransportError, TransportKind, TransportRoute, TransportStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

/// How a CancelRequest packet starts: its length, 16, then its code,
/// 80877102.
pub const CANCEL_REQUEST: [u8; 8] = [0, 0, 0, 16, 0x04, 0xd2, 0x16, 0x2e];

/// Bytes the route holds back, and for how long.
#[derive(Debug, Clone)]
pub struct Hold {
    pub pattern: Vec<u8>,
    pub delay: Duration,
}

impl Hold {
    pub fn new(pattern: &[u8], delay: Duration) -> Self {
        Self {
            pattern: pattern.to_vec(),
            delay,
        }
    }
}

#[derive(Debug)]
pub struct SlowRoute {
    inner: Arc<dyn Transport>,
    holds: Vec<Hold>,
}

impl SlowRoute {
    /// A stream that writes one of the patterns has everything from that
    /// write on delivered `delay` later. The patterns match plaintext.
    pub fn new(inner: Arc<dyn Transport>, holds: Vec<Hold>) -> Self {
        Self { inner, holds }
    }
}

#[async_trait]
impl Transport for SlowRoute {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        self.inner.service_endpoint()
    }

    fn kind(&self) -> TransportKind {
        self.inner.kind()
    }

    fn route(&self) -> TransportRoute {
        self.inner.route()
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        let server = self.inner.open().await?;
        let (client, relay) = tokio::io::duplex(64 * 1024);
        tokio::spawn(relay_through(relay, server, self.holds.clone()));
        Ok(Box::new(client))
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.inner.reroute(endpoint).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        None
    }
}

/// Relay one stream. The relay outlives the client's end, so bytes the
/// client wrote before it closed still reach the server.
async fn relay_through(relay: DuplexStream, server: Box<dyn TransportStream>, holds: Vec<Hold>) {
    let (mut from_client, mut to_client) = tokio::io::split(relay);
    let (mut from_server, mut to_server) = tokio::io::split(server);
    let upstream = async move {
        let mut chunk = vec![0_u8; 16 * 1024];
        loop {
            let read = from_client.read(&mut chunk).await.unwrap_or(0);
            let Some(bytes) = chunk.get(..read).filter(|bytes| !bytes.is_empty()) else {
                break;
            };
            if let Some(delay) = held_for(&holds, bytes) {
                tokio::time::sleep(delay).await;
            }
            if to_server.write_all(bytes).await.is_err() {
                return;
            }
        }
        let _ = to_server.shutdown().await;
    };
    let downstream = async move {
        let _ = tokio::io::copy(&mut from_server, &mut to_client).await;
        let _ = to_client.shutdown().await;
    };
    tokio::join!(upstream, downstream);
}

fn held_for(holds: &[Hold], bytes: &[u8]) -> Option<Duration> {
    holds
        .iter()
        .find(|hold| !hold.pattern.is_empty() && bytes.windows(hold.pattern.len()).any(|window| window == hold.pattern))
        .map(|hold| hold.delay)
}
