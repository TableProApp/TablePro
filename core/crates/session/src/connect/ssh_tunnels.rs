use std::fmt;
use std::sync::Arc;

use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, NetworkEndpoint, Transport, TransportError};
use tablepro_ssh::SshConfig;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

/// How a connect reaches a server through SSH. The app passes in its
/// platform's transport, as it passes a `ProcessHold`: on Linux
/// `tablepro_ssh::SshServices`, the system OpenSSH client, and on Windows
/// `tablepro_ssh::InProcessSsh` (core ADR 0009).
pub trait SshTunnels: fmt::Debug + Send + Sync {
    fn open(
        &self,
        config: &SshConfig,
        liveness: LivenessPolicy,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<Arc<dyn SshTunnel>, TransportError>>;
}

/// One SSH session, which ends when the last holder drops it.
pub trait SshTunnel: Send + Sync {
    /// A transport to `target` through the session.
    fn forward(
        self: Arc<Self>,
        target: NetworkEndpoint,
        liveness: LivenessPolicy,
    ) -> BoxFuture<'static, Result<Arc<dyn Transport>, TransportError>>;

    /// Fires when the session ends.
    fn closed(&self) -> WaitForCancellationFutureOwned;

    /// The destination the user named, for the log.
    fn destination(&self) -> &str;

    /// Where the session's first TCP connection goes, when the transport
    /// knows it.
    fn first_hop_endpoint(&self) -> Option<&NetworkEndpoint>;

    /// The process that carries the session, if one does.
    fn process_id(&self) -> Option<u32>;
}
