use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    LivenessPolicy, NetworkEndpoint, TimeoutPhase, Transport, TransportError, TransportKind, TransportRoute,
    TransportStream,
};
use tokio::sync::oneshot;

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
        // russh keeps a channel confirmed after its opener stopped waiting, so the open finishes on a
        // task of its own, which drops a late channel to close it and gives up when the session ends.
        let opener = self.session.opener()?;
        let (opened, waiting) = oneshot::channel();
        let service = self.service.clone();
        tokio::spawn(async move {
            tokio::select! {
                () = opener.closed().cancelled() => {}
                result = opener.open(&service) => {
                    let _late = opened.send(result);
                }
            }
        });
        match tokio::time::timeout(self.liveness.ssh_channel_open_timeout, waiting).await {
            Ok(Ok(opened)) => opened,
            Ok(Err(_)) => Err(self.session.ended()),
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
