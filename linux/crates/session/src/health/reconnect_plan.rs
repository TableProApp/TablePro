use std::sync::Arc;

use tablepro_core::credentials::{CredentialInteraction, CredentialPrompter};

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
    pub(crate) fn interaction(&self, user_asked: bool) -> CredentialInteraction {
        match (&self.prompter, user_asked) {
            (Some(prompter), true) => CredentialInteraction::Attended(prompter.clone()),
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
