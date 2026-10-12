use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_storage::CredentialDemand;

use super::{ConnectError, ConnectRequest, CredentialSource, RefreshedRequest};

/// For a request that already carries every secret it needs: one typed
/// into the connect dialog, or a file with no login at all.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoStoredCredentials;

impl CredentialSource for NoStoredCredentials {
    fn refresh(
        &self,
        request: ConnectRequest,
        _interaction: CredentialInteraction,
        _demand: CredentialDemand,
    ) -> BoxFuture<'static, Result<RefreshedRequest, ConnectError>> {
        Box::pin(async move {
            Ok(RefreshedRequest {
                request,
                remember: Vec::new(),
            })
        })
    }
}
