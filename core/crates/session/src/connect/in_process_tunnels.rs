use std::sync::Arc;

use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, NetworkEndpoint, Transport, TransportError};
use tablepro_ssh::{InProcessSession, InProcessSsh, SshConfig};
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use super::{SshTunnel, SshTunnels};

impl SshTunnels for InProcessSsh {
    fn open(
        &self,
        config: &SshConfig,
        liveness: LivenessPolicy,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<Arc<dyn SshTunnel>, TransportError>> {
        let services = self.clone();
        let config = config.clone();
        Box::pin(async move {
            let session: Arc<dyn SshTunnel> =
                InProcessSession::connect(&config, &services, &liveness, interaction, cancel).await?;
            Ok(session)
        })
    }
}

impl SshTunnel for InProcessSession {
    fn forward(
        self: Arc<Self>,
        target: NetworkEndpoint,
        liveness: LivenessPolicy,
    ) -> BoxFuture<'static, Result<Arc<dyn Transport>, TransportError>> {
        Box::pin(async move { InProcessSession::forward(&self, target, &liveness).await })
    }

    fn closed(&self) -> WaitForCancellationFutureOwned {
        InProcessSession::closed(self)
    }

    fn destination(&self) -> &str {
        InProcessSession::destination(self)
    }

    fn first_hop_endpoint(&self) -> Option<&NetworkEndpoint> {
        Some(InProcessSession::first_hop_endpoint(self))
    }

    fn process_id(&self) -> Option<u32> {
        None
    }
}
