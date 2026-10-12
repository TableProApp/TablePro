use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::credentials::{CredentialInteraction, CredentialPrompter, SecretKind, SecretVault};
use tablepro_core::{DriverRegistry, LivenessPolicy};
use tablepro_session::operation::{DeadlinePolicy, OperationKind};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{Connector, CredentialSource, SessionDeps, SessionRegistry};
use tablepro_storage::{KeyringCredentials, SavedConnection};

use super::active_session::ActiveSession;

/// Everything a window needs to connect, run a session and close it,
/// built once in `run()` and shared on the GTK thread.
pub struct SessionContext {
    pub drivers: Arc<DriverRegistry>,
    pub connector: Arc<dyn Connector>,
    pub deadlines: Arc<dyn DeadlinePolicy>,
    pub prompter: Arc<dyn CredentialPrompter>,
    pub secrets: Arc<dyn SecretVault>,
    pub sessions: Rc<SessionRegistry>,
    pub hold: Rc<dyn ProcessHold>,
    pub tasks: Tasks,
    pub liveness: LivenessPolicy,
    pub active: ActiveSession,
}

impl SessionContext {
    /// A connect the user is waiting on may ask them for what is missing.
    pub fn attended(&self) -> CredentialInteraction {
        CredentialInteraction::Attended(self.prompter.clone())
    }

    /// A saved connection's secrets, read from the keyring at every
    /// connect and labelled in the user's language when remembered.
    pub fn keyring_credentials(&self, saved: &SavedConnection) -> KeyringCredentials {
        KeyringCredentials::for_saved(self.secrets.clone(), saved).with_labeler(translated_secret_label)
    }

    /// What a started session reconnects with. A Retry the user presses
    /// may prompt again; the monitor's own retries never do.
    pub fn session_deps(&self, credentials: Arc<dyn CredentialSource>) -> SessionDeps {
        SessionDeps {
            connector: self.connector.clone(),
            credentials,
            deadlines: self.deadlines.clone(),
            tasks: self.tasks.clone(),
            prompter: Some(self.prompter.clone()),
        }
    }

    pub fn close_timeout(&self) -> Duration {
        self.deadlines
            .deadline(OperationKind::Close)
            .unwrap_or(self.liveness.close_timeout)
    }
}

#[cfg(test)]
impl SessionContext {
    /// A context whose connects never reach a server, for widget tests
    /// that only need the dialog's form.
    pub(crate) fn for_tests(drivers: DriverRegistry, tasks: Tasks) -> Rc<Self> {
        let liveness = LivenessPolicy::DESKTOP;
        let (prompter, _queue) = crate::ui::credential_prompt::GtkCredentialPrompter::new();
        Rc::new(Self {
            drivers: Arc::new(drivers),
            connector: Arc::new(tablepro_session::fakes::FakeConnector::new([])),
            deadlines: Arc::new(tablepro_session::operation::DefaultDeadlines::new(liveness)),
            prompter: Arc::new(prompter),
            secrets: Arc::new(tablepro_test_support::FakeSecretVault::new()),
            sessions: SessionRegistry::new(),
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            tasks,
            liveness,
            active: ActiveSession::new(),
        })
    }
}

impl std::fmt::Debug for SessionContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionContext")
            .field("drivers", &self.drivers.len())
            .field("sessions", &self.sessions)
            .field("active", &self.active)
            .finish_non_exhaustive()
    }
}

/// The keyring label for a secret the user chose to remember, in the
/// wording the connect dialog uses for the same secret.
fn translated_secret_label(kind: SecretKind, target: &str) -> String {
    super::secret_labels::label_for_target(kind, target)
}
