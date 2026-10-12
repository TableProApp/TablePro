use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tokio_util::sync::CancellationToken;

use super::{ConnectError, ConnectRequest, PendingSession};

/// Turns a request into a connected, not yet adopted, session.
///
/// A seam rather than a function so the window and the monitor can be
/// tested against a scripted connector.
pub trait Connector: Send + Sync {
    fn establish(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<PendingSession, ConnectError>>;
}
