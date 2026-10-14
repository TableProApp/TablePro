use std::cell::OnceCell;
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib::prelude::IsA;
use tablepro_core::{ConnectEnvironment, DriverRegistry, LivenessPolicy};
use tablepro_session::operation::{DeadlinePolicy, DefaultDeadlines};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{ConnectServices, Connector, DriverConnector, SessionRegistry};
use tablepro_ssh::SshServices;
use tablepro_storage::{AppSettings, SecretStore, StoragePaths};

use crate::config;
use crate::runtime::GioProcessHold;
use crate::services::active_session::ActiveSession;
use crate::services::history_service::{HistoryService, publish_retention};
use crate::services::session_context::SessionContext;
use crate::storage::{AppStorage, SharedStorage};
use crate::ui::credential_prompt::{GtkCredentialPrompter, PromptQueue};

/// What every window of the application shares. GTK-thread only.
pub struct AppServices {
    pub drivers: Arc<DriverRegistry>,
    pub connector: Arc<dyn Connector>,
    pub deadlines: Arc<dyn DeadlinePolicy>,
    pub liveness: LivenessPolicy,
    pub sessions: Rc<SessionRegistry>,
    pub settings: Rc<AppSettings>,
    pub storage: SharedStorage,
    pub tasks: Tasks,
    /// Bound to the application once it exists, which is after this.
    hold: Rc<GioProcessHold>,
    history: OnceCell<HistoryService>,
    ssh: Option<SshServices>,
}

/// What `AppServices::new` builds from, for a caller that brings its own
/// connector and storage.
pub struct AppServicesParts {
    pub drivers: DriverRegistry,
    pub connector: Arc<dyn Connector>,
    pub deadlines: Arc<dyn DeadlinePolicy>,
    pub liveness: LivenessPolicy,
    pub settings: Rc<AppSettings>,
    pub storage: AppStorage,
    pub tasks: Tasks,
}

impl AppServices {
    pub fn new(parts: AppServicesParts) -> Self {
        let AppServicesParts {
            drivers,
            connector,
            deadlines,
            liveness,
            settings,
            storage,
            tasks,
        } = parts;
        Self {
            drivers: Arc::new(drivers),
            connector,
            deadlines,
            liveness,
            sessions: SessionRegistry::new(),
            settings,
            storage: Rc::new(storage),
            tasks,
            hold: Rc::new(GioProcessHold::default()),
            history: OnceCell::new(),
            ssh: None,
        }
    }

    /// A second launch builds this too before it hands its command line
    /// to the running instance, so what only the primary may do waits
    /// for `start`.
    pub fn production(drivers: DriverRegistry, settings: Rc<AppSettings>, paths: StoragePaths, tasks: Tasks) -> Self {
        let secrets = Arc::new(SecretStore::new(config::secret_schema()));
        let storage = AppStorage::new(paths, secrets, &tasks);
        let ssh = SshServices::system(storage.paths().runtime.clone(), Path::new(config::LIBEXECDIR));
        let liveness = LivenessPolicy::DESKTOP;
        let deadlines: Arc<dyn DeadlinePolicy> = Arc::new(DefaultDeadlines::new(liveness));
        let connector = DriverConnector::new(
            ConnectServices {
                environment: ConnectEnvironment::new(config::VERSION),
                ssh: ssh.clone(),
                liveness,
            },
            deadlines.clone(),
        );
        let mut services = Self::new(AppServicesParts {
            drivers,
            connector: Arc::new(connector),
            deadlines,
            liveness,
            settings,
            storage,
            tasks,
        });
        services.ssh = Some(ssh);
        services
    }

    /// The work only the primary instance does, from its startup.
    ///
    /// A missing askpass helper is logged rather than fatal: only SSH
    /// needs it, and the connect that tries says so in its own error. The
    /// sweep ends masters a crashed instance left behind, which would
    /// otherwise keep their tunnels open until the next reboot.
    pub(crate) fn start(&self) {
        drop(self.history());
        let Some(ssh) = self.ssh.clone() else {
            return;
        };
        if let Err(error) = ssh.verify_askpass_helper() {
            tracing::warn!(%error, "SSH connections will fail until the askpass helper is installed");
        }
        drop(self.tasks.spawn_task(async move {
            let ended = tablepro_ssh::sweep_stale_masters(&ssh).await;
            if ended > 0 {
                tracing::info!(ended, "ended SSH masters a previous instance left running");
            }
        }));
    }

    /// The database migrates and prunes on open, which is too slow to
    /// hold up the first window. The menu items that need it stay
    /// disabled until the service reports Ready.
    pub(crate) fn history(&self) -> HistoryService {
        self.history
            .get_or_init(|| {
                let retention = publish_retention(&self.settings);
                HistoryService::start(self.storage.paths().clone(), retention, &self.tasks)
            })
            .clone()
    }

    pub(crate) fn hold(&self) -> Rc<dyn ProcessHold> {
        self.hold.clone()
    }

    pub(crate) fn bind_application(&self, application: &impl IsA<gio::Application>) {
        self.hold.bind(application);
    }

    /// One window's view of the shared services: its own session slot,
    /// and its own credential prompts, which it shows over itself.
    pub(crate) fn window_context(&self) -> (Rc<SessionContext>, PromptQueue) {
        let (prompter, prompts) = GtkCredentialPrompter::new();
        let context = SessionContext {
            drivers: self.drivers.clone(),
            connector: self.connector.clone(),
            deadlines: self.deadlines.clone(),
            prompter: Arc::new(prompter),
            secrets: self.storage.secrets().clone(),
            sessions: self.sessions.clone(),
            hold: self.hold(),
            tasks: self.tasks.clone(),
            liveness: self.liveness,
            active: ActiveSession::new(),
        };
        (Rc::new(context), prompts)
    }
}

impl std::fmt::Debug for AppServices {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppServices")
            .field("drivers", &self.drivers.len())
            .field("sessions", &self.sessions)
            .field("history", &self.history.get().is_some())
            .finish_non_exhaustive()
    }
}
