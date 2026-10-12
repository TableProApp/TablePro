use std::sync::Arc;

use tablepro_core::credentials::CredentialPrompter;

use crate::connect::{Connector, CredentialSource};
use crate::operation::DeadlinePolicy;
use crate::runtime::Tasks;

/// What a session needs from the app beyond its first connection.
#[derive(Clone)]
pub struct SessionDeps {
    pub connector: Arc<dyn Connector>,
    pub credentials: Arc<dyn CredentialSource>,
    pub deadlines: Arc<dyn DeadlinePolicy>,
    pub tasks: Tasks,
    /// Asked for secrets on a reconnect the user started with Retry.
    /// `None` keeps every reconnect unattended.
    pub prompter: Option<Arc<dyn CredentialPrompter>>,
}

impl std::fmt::Debug for SessionDeps {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionDeps")
            .field("tasks", &self.tasks)
            .field("prompter", &self.prompter.is_some())
            .finish_non_exhaustive()
    }
}
