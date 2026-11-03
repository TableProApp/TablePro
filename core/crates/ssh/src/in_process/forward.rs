use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    LivenessPolicy, NetworkEndpoint, TimeoutPhase, Transport, TransportError, TransportKind, TransportRoute,
    TransportStream,
};

use super::session::InProcessSession;

// Each stream is a direct-tcpip channel of the session, so nothing listens on the machine.
#[derive(Debug)]
pub struct InProcessForward {
    session: Arc<InProcessSession>,
    service: NetworkEndpoint,
    liveness: LivenessPolicy,
}

impl InProcessForward {
    pub(crate) fn new(session: Arc<InProcessSession>, service: NetworkEndpoint, liveness: &LivenessPolicy) -> Self {
        Self {
            session,
            service,
            liveness: *liveness,
        }
    }
}

#[async_trait]
impl Transport for InProcessForward {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        &self.service
    }

    fn kind(&self) -> TransportKind {
        TransportKind::SshForward {
            destination: self.session.destination().to_owned(),
        }
    }

    fn route(&self) -> TransportRoute {
        TransportRoute::InProcess
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        if self.session.is_closed() {
            return Err(self.session.ended());
        }
        let opening = self.session.open_channel(&self.service);
        match tokio::time::timeout(self.liveness.ssh_channel_open_timeout, opening).await {
            Ok(opened) => opened,
            Err(_) => Err(TransportError::Timeout {
                phase: TimeoutPhase::SshChannelOpen,
            }),
        }
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.session.forward(endpoint, &self.liveness).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        self.session.is_closed().then(|| self.session.ended())
    }
}
