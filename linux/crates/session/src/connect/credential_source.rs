use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialInteraction, SecretError, SecretKind, SecretSave};
use tablepro_storage::CredentialDemand;

use super::{ConnectError, ConnectRequest};

/// A request with its secrets filled in, and what the user asked to keep.
#[derive(Debug, Clone)]
pub struct RefreshedRequest {
    pub request: ConnectRequest,
    /// Secrets typed into a prompt with "Remember" on. They are stored
    /// only once the login they were typed for has worked.
    pub remember: Vec<SecretSave>,
}

/// Where a request's secrets come from at each connect.
///
/// Only secrets change: host, database and user stay as the request
/// has them, so a reconnect never retargets a live session.
pub trait CredentialSource: Send + Sync {
    fn refresh(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        demand: CredentialDemand,
    ) -> BoxFuture<'static, Result<RefreshedRequest, ConnectError>>;

    /// Keep secrets the user asked to remember. Returns the ones that
    /// could not be stored, so the caller can say so.
    fn remember(&self, saves: Vec<SecretSave>) -> BoxFuture<'static, Vec<(SecretKind, SecretError)>> {
        if !saves.is_empty() {
            tracing::debug!(count = saves.len(), "this credential source keeps nothing");
        }
        Box::pin(async { Vec::new() })
    }
}
