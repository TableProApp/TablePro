use std::fmt::Debug;
use std::sync::Arc;

use async_trait::async_trait;
use tokio::io::{AsyncRead, AsyncWrite};

use crate::{NetworkEndpoint, TransportError, TransportKind, TransportRoute};

pub trait TransportStream: AsyncRead + AsyncWrite + Send + Unpin + 'static {}

impl<T> TransportStream for T where T: AsyncRead + AsyncWrite + Send + Unpin + 'static {}

#[async_trait]
pub trait Transport: Send + Sync + Debug {
    fn service_endpoint(&self) -> &NetworkEndpoint;

    fn kind(&self) -> TransportKind;

    fn route(&self) -> TransportRoute;

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError>;

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError>;

    async fn explain_closed_stream(&self) -> Option<TransportError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokio_streams_box_as_transport_streams() {
        let (client, _server) = tokio::io::duplex(64);
        let stream: Box<dyn TransportStream> = Box::new(client);
        let transport: Option<Arc<dyn Transport>> = None;
        assert!(transport.is_none());
        drop(stream);
    }
}
