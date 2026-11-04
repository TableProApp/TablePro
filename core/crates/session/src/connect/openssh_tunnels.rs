use std::sync::Arc;

use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, NetworkEndpoint, Transport, TransportError};
use tablepro_ssh::{SshConfig, SshServices, SshSession};
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use super::{SshTunnel, SshTunnels};

impl SshTunnels for SshServices {
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
                SshSession::connect(&config, &services, &liveness, interaction, cancel).await?;
            Ok(session)
        })
    }
}

impl SshTunnel for SshSession {
    fn forward(
        self: Arc<Self>,
        target: NetworkEndpoint,
        liveness: LivenessPolicy,
    ) -> BoxFuture<'static, Result<Arc<dyn Transport>, TransportError>> {
        Box::pin(async move { SshSession::forward(&self, target, &liveness).await })
    }

    fn closed(&self) -> WaitForCancellationFutureOwned {
        SshSession::closed(self)
    }

    fn destination(&self) -> &str {
        SshSession::destination(self)
    }

    fn first_hop_endpoint(&self) -> Option<&NetworkEndpoint> {
        SshSession::first_hop_endpoint(self)
    }

    fn process_id(&self) -> Option<u32> {
        self.master_pid()
    }
}
