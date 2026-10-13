use tokio_util::sync::CancellationToken;

use super::RequestStamp;

/// What a request carries while it runs: the stamp its reply comes back
/// with, and the token that stops it once a newer request replaces it.
#[derive(Debug, Clone)]
pub struct RequestTicket {
    pub stamp: RequestStamp,
    pub cancel: CancellationToken,
}
