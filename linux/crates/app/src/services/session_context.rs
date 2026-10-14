use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::credentials::{CredentialInteraction, CredentialPrompter, SecretKind, SecretVault};
use tablepro_core::{DriverRegistry, LivenessPolicy};
use tablepro_session::operation::{DeadlinePolicy, OperationKind};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{Connector, CredentialSource, NoStoredCredentials, SessionDeps, SessionRegistry};
use tablepro_storage::{KeyringCredentials, SavedConnection};

use super::active_session::ActiveSession;

/// Everything a window needs to connect, run a session and close it,
/// built once in `run()` and shared on the GTK thread.
#[derive(Clone)]
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
    pub credentials: Rc<dyn CredentialSourceFactory>,
    pub active: ActiveSession,
}

/// Where a session's secrets come from at each connect and reconnect.
pub trait CredentialSourceFactory {
    /// A saved connection's keyring entries, or for a connection with no
    /// saved entry, only what its request carries.
    fn for_connection(&self, saved: Option<&SavedConnection>) -> Arc<dyn CredentialSource>;
}

/// The keyring, labelling what it remembers in the user's language.
pub struct KeyringSources {
    secrets: Arc<dyn SecretVault>,
}

impl KeyringSources {
    pub fn new(secrets: Arc<dyn SecretVault>) -> Self {
        Self { secrets }
    }
}

impl CredentialSourceFactory for KeyringSources {
    fn for_connection(&self, saved: Option<&SavedConnection>) -> Arc<dyn CredentialSource> {
        match saved {
            Some(saved) => Arc::new(
                KeyringCredentials::for_saved(self.secrets.clone(), saved).with_labeler(translated_secret_label),
            ),
            None => Arc::new(NoStoredCredentials),
        }
    }
}

impl SessionContext {
    /// A connect the user is waiting on may ask them for what is missing.
    pub fn attended(&self) -> CredentialInteraction {
        CredentialInteraction::Attended(self.prompter.clone())
    }

    /// What a session opened from `saved` reads its secrets from at
    /// every connect, or one opened without a saved entry.
    pub fn credentials_for(&self, saved: Option<&SavedConnection>) -> Arc<dyn CredentialSource> {
        self.credentials.for_connection(saved)
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
