use std::sync::Arc;

use tablepro_core::credentials::{CredentialInteraction, CredentialPrompter};

use super::{ReviewedHostKey, TrustedHostKey};
use crate::connect::{ConnectRequest, Connector, CredentialSource};

/// How the monitor reconnects: the same request, with its secrets read
/// again each attempt.
#[derive(Clone)]
pub struct ReconnectPlan {
    pub connector: Arc<dyn Connector>,
    pub request: ConnectRequest,
    pub credentials: Arc<dyn CredentialSource>,
    /// Asked only on a reconnect the user started with Retry. Backoff
    /// attempts run with nobody watching, so they never prompt.
    pub prompter: Option<Arc<dyn CredentialPrompter>>,
}

impl ReconnectPlan {
    /// `trusted` is a host key the user reviewed before asking for this
    /// attempt, answered for them when ssh shows it for that host.
    pub(crate) fn interaction(&self, user_asked: bool, trusted: Option<ReviewedHostKey>) -> CredentialInteraction {
        match (user_asked, trusted, &self.prompter) {
            (true, Some(reviewed), prompter) => {
                CredentialInteraction::Attended(Arc::new(TrustedHostKey::new(reviewed, prompter.clone())))
            }
            (true, None, Some(prompter)) => CredentialInteraction::Attended(prompter.clone()),
            _ => CredentialInteraction::Unattended,
        }
    }
}

impl std::fmt::Debug for ReconnectPlan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReconnectPlan")
            .field("request", &self.request)
            .field("prompter", &self.prompter.is_some())
            .finish_non_exhaustive()
    }
}
