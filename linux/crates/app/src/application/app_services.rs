use std::cell::OnceCell;
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib::prelude::IsA;
use tablepro_core::{ConnectEnvironment, DriverRegistry, LivenessPolicy};
use tablepro_mcp::{McpHost, TokenVault, ToolContext};
use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::operation::{DeadlinePolicy, DefaultDeadlines};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{ConnectServices, Connector, DriverConnector, SessionRegistry};
use tablepro_ssh::SshServices;
use tablepro_storage::{AppSettings, QueryHistory, SecretStore, StoragePaths};

use crate::config;
use crate::runtime::GioProcessHold;
use crate::services::active_session::ActiveSession;
use crate::services::ai_service::AiService;
use crate::services::connection_deletion::ConnectionDeletion;
use crate::services::history_preferences::HistoryPreferences;
use crate::services::history_service::HistoryService;
use crate::services::mcp_service::McpService;
use crate::services::saved_connection_editor::SavedConnectionEditor;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::services::session_context::{CredentialSourceFactory, KeyringSources, SessionContext};
use crate::services::snippet_library::SnippetLibrary;
use crate::storage::{AppStorage, SharedStorage};
use crate::ui::credential_prompt::{GtkCredentialPrompter, PromptQueue};
use crate::ui::file_reveal::{FileLauncherRevealer, FileRevealer};
use crate::workspace::OpenSessions;

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
    /// The saved connections every picker shows, following the store.
    pub saved_connections: Rc<SavedConnectionList>,
    /// Edits, copies and regroups saved connections with their secrets.
    pub saved_connection_editor: SavedConnectionEditor,
    /// Shows a file selected in the file manager.
    pub(crate) file_revealer: Rc<dyn FileRevealer>,
    /// The AI provider the settings name, with its key in the keyring.
    pub(crate) ai: AiService,
    /// The SQL editor's snippets, read from the snippets folder.
    pub snippets: Rc<SnippetLibrary>,
    /// Where each session's secrets come from.
    credentials: Rc<dyn CredentialSourceFactory>,
    /// Bound to the application once it exists, which is after this.
    application_hold: Rc<GioProcessHold>,
    /// What keeps the process alive while a close or a save finishes.
    hold: Rc<dyn ProcessHold>,
    /// Which sessions the windows show, for the next launch to reopen.
    open_sessions: Rc<OpenSessions>,
    history: OnceCell<HistoryService>,
    ssh: Option<SshServices>,
    /// Where the MCP access token is kept. `None` in a test that brings
    /// none, which then runs no server.
    mcp_tokens: Option<Arc<dyn TokenVault>>,
    mcp: OnceCell<McpService>,
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
        let application_hold = Rc::new(GioProcessHold::default());
        let open_sessions = OpenSessions::new(storage.workspaces().clone(), application_hold.clone());
        let drivers = Arc::new(drivers);
        let saved_connections = SavedConnectionList::follow(storage.connections(), drivers.clone());
        let saved_connection_editor =
            SavedConnectionEditor::new(storage.connections().clone(), storage.secrets().clone(), tasks.clone());
        let ai = AiService::new(settings.clone(), tasks.clone(), None);
        let snippets = SnippetLibrary::new(storage.paths().snippets_dir());
        Self {
            drivers,
            connector,
            deadlines,
            liveness,
            sessions: SessionRegistry::new(),
            settings,
            credentials: Rc::new(KeyringSources::new(storage.secrets().clone())),
            storage: Rc::new(storage),
            tasks,
            saved_connections,
            saved_connection_editor,
            file_revealer: Rc::new(FileLauncherRevealer),
            ai,
            snippets,
            hold: application_hold.clone(),
            application_hold,
            open_sessions,
            history: OnceCell::new(),
            ssh: None,
            mcp_tokens: None,
            mcp: OnceCell::new(),
        }
    }

    /// A second launch builds this too before it hands its command line
    /// to the running instance, so what only the primary may do waits
    /// for `start`.
    pub fn production(drivers: DriverRegistry, settings: Rc<AppSettings>, paths: StoragePaths, tasks: Tasks) -> Self {
        let secrets = Arc::new(SecretStore::new(config::secret_schema()));
        let mcp_tokens: Arc<dyn TokenVault> = secrets.clone();
        let ai_keys: Arc<dyn tablepro_ai::ApiKeyVault> = secrets.clone();
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
        services.mcp_tokens = Some(mcp_tokens);
        services.ai = AiService::new(services.settings.clone(), services.tasks.clone(), Some(ai_keys));
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
    /// disabled until the service says how the open went.
    pub(crate) fn history(&self) -> HistoryService {
        self.history
            .get_or_init(|| {
                let preferences = HistoryPreferences::follow(&self.settings);
                HistoryService::start(self.storage.paths().clone(), preferences, &self.tasks)
            })
            .clone()
    }

    /// Run the MCP server while its preference is on, from the primary
    /// instance's startup.
    pub(crate) fn start_mcp(&self, host: Arc<dyn McpHost>) {
        let Some(tokens) = self.mcp_tokens.clone() else {
            return;
        };
        let context = ToolContext {
            host,
            connections: self.storage.connections().clone(),
        };
        let service = McpService::start(self.settings.clone(), self.tasks.clone(), tokens, context);
        if let Err(service) = self.mcp.set(service) {
            service.stop();
        }
    }

    pub(crate) fn stop_mcp(&self) {
        if let Some(service) = self.mcp.get() {
            service.stop();
        }
    }

    /// `None` before startup and in an instance that only hands its
    /// command line over.
    pub(crate) fn mcp(&self) -> Option<McpService> {
        self.mcp.get().cloned()
    }

    #[cfg(test)]
    pub(crate) fn with_mcp_tokens(mut self, tokens: Arc<dyn TokenVault>) -> Self {
        self.mcp_tokens = Some(tokens);
        self
    }

    /// The OpenSSH client and its helpers. `None` in a test that brings
    /// none.
    pub(crate) fn ssh(&self) -> Option<SshServices> {
        self.ssh.clone()
    }

    pub(crate) fn hold(&self) -> Rc<dyn ProcessHold> {
        self.hold.clone()
    }

    /// What deletes a saved connection and everything kept for it, with
    /// `history` as the history database, or `None` when it did not
    /// open.
    pub(crate) fn connection_deletion(&self, history: Option<QueryHistory>) -> ConnectionDeletion {
        ConnectionDeletion {
            secrets: self.storage.secrets().clone(),
            connections: Arc::new(StoreConnectionWrites::new(
                self.storage.connections().clone(),
                self.tasks.clone(),
            )),
            column_widths: self.storage.column_widths().clone(),
            filters: self.storage.filter_settings().clone(),
            workspaces: self.storage.workspaces().clone(),
            history,
            spawner: self.tasks.clone(),
        }
    }

    pub(crate) fn open_sessions(&self) -> &Rc<OpenSessions> {
        &self.open_sessions
    }

    pub(crate) fn bind_application(&self, application: &impl IsA<gio::Application>) {
        self.application_hold.bind(application);
    }

    /// A test reads the holds, or stands in for the keyring.
    #[cfg(test)]
    pub(crate) fn with_hold(mut self, hold: Rc<dyn ProcessHold>) -> Self {
        self.open_sessions = OpenSessions::new(self.storage.workspaces().clone(), hold.clone());
        self.hold = hold;
        self
    }

    #[cfg(test)]
    pub(crate) fn with_ssh(mut self, ssh: SshServices) -> Self {
        self.ssh = Some(ssh);
        self
    }

    #[cfg(test)]
    pub(crate) fn with_credentials(mut self, credentials: Rc<dyn CredentialSourceFactory>) -> Self {
        self.credentials = credentials;
        self
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
            credentials: self.credentials.clone(),
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
