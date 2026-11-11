use std::net::SocketAddr;
use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    LivenessPolicy, NetworkEndpoint, TimeoutPhase, Transport, TransportError, TransportKind, TransportRoute,
    TransportStream,
};
use tokio::time::Instant;

use crate::dial::dial_addresses;

#[derive(Debug, Clone)]
pub struct DirectTcpTransport {
    endpoint: NetworkEndpoint,
    liveness: LivenessPolicy,
}

impl DirectTcpTransport {
    pub fn new(endpoint: NetworkEndpoint, liveness: &LivenessPolicy) -> Self {
        Self {
            endpoint,
            liveness: *liveness,
        }
    }
}

#[async_trait]
impl Transport for DirectTcpTransport {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        &self.endpoint
    }

    fn kind(&self) -> TransportKind {
        TransportKind::DirectTcp
    }

    fn route(&self) -> TransportRoute {
        TransportRoute::Tcp(self.endpoint.clone())
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        // The lookup shares the dial's deadline, since callers bound the whole open by the connect timeout.
        let deadline = Instant::now() + self.liveness.connect_timeout;
        let resolving = tokio::net::lookup_host((self.endpoint.host(), self.endpoint.port()));
        let addresses: Vec<SocketAddr> = match tokio::time::timeout_at(deadline, resolving).await {
            Ok(Ok(addresses)) => addresses.collect(),
            Ok(Err(error)) => {
                return Err(TransportError::NameResolution {
                    host: self.endpoint.host().to_owned(),
                    detail: error.to_string(),
                });
            }
            Err(_) => {
                return Err(TransportError::Timeout {
                    phase: TimeoutPhase::Connect,
                });
            }
        };
        if addresses.is_empty() {
            return Err(TransportError::NameResolution {
                host: self.endpoint.host().to_owned(),
                detail: "the name resolved to no addresses".to_owned(),
            });
        }
        let stream = dial_addresses(addresses, &self.endpoint, &self.liveness, deadline).await?;
        Ok(Box::new(stream))
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        Ok(Arc::new(Self::new(endpoint, &self.liveness)))
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn lookup_failure_is_name_resolution() {
        let endpoint = NetworkEndpoint::new("tablepro.invalid", 5432).unwrap();
        let transport = DirectTcpTransport::new(endpoint, &LivenessPolicy::DESKTOP);
        assert!(matches!(
            transport.open().await,
            Err(TransportError::NameResolution { host, .. }) if host == "tablepro.invalid"
        ));
        assert_eq!(transport.kind(), TransportKind::DirectTcp);
    }
}
