use std::cell::{OnceCell, RefCell};
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gio::prelude::SettingsExt as _;
use gtk4::glib::prelude::IsA;
use tablepro_account::{AccountStatus, FeatureAccess, RefreshTokenVault};
use tablepro_core::{ConnectEnvironment, DriverRegistry, LivenessPolicy};
use tablepro_linux_platform::{AppSettings, SecretStore};
use tablepro_mcp::{McpHost, TokenVault, ToolContext};
use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::operation::{DeadlinePolicy, DefaultDeadlines};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{ConnectServices, Connector, DriverConnector, SessionRegistry};
use tablepro_ssh::SshServices;
use tablepro_storage::{QueryHistory, StoragePaths};

use crate::config;
use crate::runtime::GioProcessHold;
use crate::services::account_service::{AccountHandle, AccountService, DesktopBrowser, KeyringRefreshToken};
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
use crate::services::telemetry::{Opened, PersonProperties, Telemetry, TelemetrySettings, architecture};
use crate::services::telemetry_connector::TelemetryConnector;
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
    // None in a test, which then stays signed out.
    account_tokens: Option<Arc<dyn RefreshTokenVault>>,
    account: RefCell<AccountService>,
    telemetry: Telemetry,
}

// The usage data follows the account, which a sign-out, a removed device or a refused sign-in leaves
// with none. Signed in without an entitlement, only /v2/me names it, which the account page reads.
// The value before the account restores is not one of these.
fn follow_account(handle: AccountHandle, telemetry: Telemetry) {
    let mut status = handle.status;
    glib::spawn_future_local(async move {
        while status.changed().await.is_ok() {
            let account_id = match &*status.borrow_and_update() {
                AccountStatus::SignedIn(held) => held.entitlement.as_ref().map(|it| Some(it.claims().sub.clone())),
                AccountStatus::SignedOut | AccountStatus::Offline(_) => Some(None),
            };
            if let Some(account_id) = account_id {
                telemetry.account_changed(account_id.as_deref());
            }
        }
    });
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
            account_tokens: None,
            account: RefCell::new(AccountService::signed_out()),
            telemetry: Telemetry::default(),
        }
    }

    /// A second launch builds this too before it hands its command line
    /// to the running instance, so what only the primary may do waits
    /// for `start`.
    pub fn production(drivers: DriverRegistry, settings: Rc<AppSettings>, paths: StoragePaths, tasks: Tasks) -> Self {
        let secrets = Arc::new(
            SecretStore::new(config::secret_schema()).with_item_labeler(crate::services::secret_labels::item_label),
        );
        let mcp_tokens: Arc<dyn TokenVault> = secrets.clone();
        let ai_keys: Arc<dyn tablepro_ai::ApiKeyVault> = secrets.clone();
        let account_tokens: Arc<dyn RefreshTokenVault> = Arc::new(KeyringRefreshToken(secrets.clone()));
        let storage = AppStorage::new(paths, secrets, &tasks);
        let ssh = SshServices::system(storage.paths().runtime.clone(), Path::new(config::LIBEXECDIR));
        let liveness = LivenessPolicy::DESKTOP;
        let deadlines: Arc<dyn DeadlinePolicy> = Arc::new(DefaultDeadlines::new(liveness));
        let connector = DriverConnector::new(
            ConnectServices {
                environment: ConnectEnvironment::new(config::VERSION),
                ssh: Arc::new(ssh.clone()),
                liveness,
            },
            deadlines.clone(),
        );
        let telemetry = Telemetry::default();
        let connector = TelemetryConnector::new(Arc::new(connector), telemetry.clone());
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
        services.account_tokens = Some(account_tokens);
        services.telemetry = telemetry;
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
        self.start_telemetry();
        if let Some(tokens) = self.account_tokens.clone() {
            let account = AccountService::start(
                &self.tasks,
                &self.storage.paths().account_file(),
                tokens,
                Arc::new(DesktopBrowser),
            );
            follow_account(account.handle(), self.telemetry.clone());
            drop(self.account.replace(account));
        }
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

    // The paid feature gate, by the server's feature code. No feature on Linux asks it yet.
    pub fn feature_access(&self, feature: &str) -> FeatureAccess {
        self.account.borrow().feature_access(feature)
    }

    pub(crate) fn account(&self) -> AccountHandle {
        self.account.borrow().handle()
    }

    // Back from the portal or another device, where a license slot may have been freed.
    pub(crate) fn app_became_active(&self) {
        if let Some(account) = self.account().account() {
            drop(
                self.tasks
                    .spawn_task(async move { account.refresh_past_device_limit().await }),
            );
        }
    }

    pub(crate) fn telemetry(&self) -> Telemetry {
        self.telemetry.clone()
    }

    // An empty key, as in every build without -Dposthog_key, makes no client at all.
    fn start_telemetry(&self) {
        self.start_telemetry_with(config::POSTHOG_KEY, config::POSTHOG_HOST);
    }

    pub(super) fn start_telemetry_with(&self, key: &str, host: &str) {
        let settings = TelemetrySettings {
            key: key.to_owned(),
            host: host.to_owned(),
            state_file: self.storage.paths().telemetry_file(),
            person: person_properties(),
        };
        self.telemetry
            .begin(settings, self.settings.share_usage_data(), &self.tasks);
        if !self.telemetry.has_project_key() {
            return;
        }
        let sessions = self.sessions.clone();
        let telemetry = self.telemetry.clone();
        let app_opened = move || telemetry.app_opened(open_sessions(&sessions));
        let opened = Rc::new(app_opened);
        let telemetry = self.telemetry.clone();
        let check = opened.clone();
        self.settings.gio().connect_changed(
            Some(tablepro_linux_platform::settings::keys::SHARE_USAGE_DATA),
            move |settings, key| {
                let sharing = settings.boolean(key);
                telemetry.set_sharing(sharing);
                if sharing {
                    check();
                }
            },
        );
        check_app_opened(APP_OPENED_DELAY, APP_OPENED_CHECK, move || {
            opened();
            glib::ControlFlow::Continue
        });
    }

    /// The database migrates and prunes on open, which is too slow to
    /// hold up the first window. The menu items that need it stay
    /// disabled until the service says how the open went.
    pub(crate) fn history(&self) -> HistoryService {
        self.history
            .get_or_init(|| {
                let preferences = HistoryPreferences::follow(&self.settings);
                HistoryService::start(self.storage.paths().clone(), preferences, &self.tasks)
                    .with_telemetry(self.telemetry.clone())
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
            column_layouts: self.storage.column_layouts().clone(),
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

const APP_OPENED_DELAY: Duration = Duration::from_secs(10);
const APP_OPENED_CHECK: Duration = Duration::from_secs(60 * 60);

// Restored sessions open first, as on macOS. The day is checked again each interval, so an app left open
// sends on each day it runs.
fn check_app_opened(delay: Duration, interval: Duration, mut check: impl FnMut() -> glib::ControlFlow + 'static) {
    glib::timeout_add_local_once(delay, move || {
        if check() == glib::ControlFlow::Continue {
            glib::timeout_add_local(interval, check);
        }
    });
}

// clients.md counts the connections open, as macOS's heartbeat did.
fn open_sessions(sessions: &SessionRegistry) -> Opened {
    let attached = sessions.attached_sessions();
    Opened {
        driver_ids: attached
            .iter()
            .map(|(_, session)| session.metadata().driver_id.clone())
            .collect(),
        connection_count: attached.len(),
    }
}

fn person_properties() -> PersonProperties {
    PersonProperties {
        app_version: config::VERSION.to_owned(),
        os_version: crate::services::account_service::os_name(),
        architecture: architecture(std::env::consts::ARCH).to_owned(),
        locale: interface_locale(),
    }
}

// Linux has no language setting of its own: the interface follows LC_MESSAGES, here without its codeset.
fn interface_locale() -> String {
    glib::language_names_with_category("LC_MESSAGES")
        .iter()
        .map(glib::GString::as_str)
        .find(|name| !name.contains(['.', '@']))
        .unwrap_or("C")
        .to_owned()
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

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Instant;

    use chrono::{TimeDelta, Utc};
    use tablepro_account::{
        Account, AccountError, AccountSettings, AppClient, CallbackPage, DeviceDescription, Endpoints, MachineId, fakes,
    };
    use tablepro_session::SessionKey;
    use tablepro_session::fakes::FakeConnector;
    use tablepro_test_support::ConnectionScript;
    use tokio::sync::watch;

    use super::*;
    use crate::runtime::AppRuntime;
    use crate::services::account_service::AccountStart;
    use crate::test_support::{
        Approving, CloudStub, FakeSession, MemoryKeyring, PostHogCollector, finish_on_main, test_runtime, wait_until,
    };

    const WAIT: Duration = Duration::from_secs(20);
    // The sub fakes::claims gives.
    const ACCOUNT: &str = "acct_01k8d6wk00f8xsr79e7x052rkk";

    #[derive(Clone, Copy)]
    enum Ending {
        RefusedRefreshToken,
        RemovedDevice,
    }

    // Signs in until `ended`, then ends the sign-in as `ending` says. The access token lasts less
    // than the margin the account keeps, so every call refreshes it first.
    fn cloud(machine: &MachineId, ending: Ending, ended: Arc<AtomicBool>) -> CloudStub {
        let mut claims = fakes::claims(Utc::now(), TimeDelta::days(14), &[]);
        claims.mid = machine.as_str().to_owned();
        claims.dev = "dev_here".to_owned();
        let entitlement = format!(
            r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
            fakes::sign(&claims).expect("a token")
        );
        let device = format!(
            r#"{{"id":"dev_here","machine_id":"{}","platform":"linux","name":"Ada's laptop","app_version":"0.1.0","os_version":"Ubuntu 26.04","created_at":"2026-10-29T00:00:00Z","last_seen_at":"2026-10-29T00:00:00Z"}}"#,
            machine.as_str()
        );
        let tokens =
            r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":30,"refresh_token":"stub-refresh"}"#;
        let revoked = r#"{"type":"about:blank","title":"Device revoked","status":403,"code":"device_revoked"}"#;
        CloudStub::start(move |method, path| {
            let ended = ended.load(Ordering::SeqCst);
            match (method, path, ending) {
                ("POST", "/oauth/token", Ending::RefusedRefreshToken) if ended => {
                    (400, r#"{"error":"invalid_grant"}"#.to_owned())
                }
                ("POST", "/oauth/token", _) => (200, tokens.to_owned()),
                ("POST", "/v2/devices", _) => (201, device.clone()),
                ("POST", "/v2/devices/dev_here/entitlement", Ending::RemovedDevice) if ended => {
                    (403, revoked.to_owned())
                }
                ("POST", "/v2/devices/dev_here/entitlement", _) => (200, entitlement.clone()),
                _ => (404, String::new()),
            }
        })
    }

    fn account(stub: &CloudStub, machine: MachineId, dir: &Path) -> (Account, AccountHandle) {
        let settings = AccountSettings {
            client: AppClient::LINUX,
            endpoints: Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints"),
            device: DeviceDescription {
                name: "Ada's laptop".to_owned(),
                app_version: "0.1.0".to_owned(),
                os_version: "Ubuntu 26.04".to_owned(),
            },
            machine_id: machine,
            keys: fakes::keys().expect("the test key"),
            account_file: dir.join("account.json"),
            callback_page: CallbackPage {
                finished: String::new(),
                unknown: String::new(),
            },
        };
        let (status, receiver) = watch::channel(AccountStatus::SignedOut);
        let account = Account::new(
            settings,
            Arc::new(MemoryKeyring::default()),
            Arc::new(Approving),
            status,
        )
        .expect("an account");
        let handle = AccountHandle {
            status: receiver,
            start: watch::channel(AccountStart::Starting).1,
            portal: String::new(),
        };
        (account, handle)
    }

    fn usage_data(collector: &PostHogCollector, state_file: &Path, runtime: &AppRuntime) -> Telemetry {
        let settings = TelemetrySettings {
            key: "phc_test".to_owned(),
            host: collector.url.clone(),
            state_file: state_file.to_owned(),
            person: PersonProperties {
                app_version: "0.1.0-test".to_owned(),
                os_version: "Ubuntu 26.04".to_owned(),
                architecture: "arm64".to_owned(),
                locale: "en_US".to_owned(),
            },
        };
        Telemetry::start(settings, true, &runtime.tasks())
    }

    // Who the events go out as: the anonymous ID, and the account once identified.
    fn kept_ids(state_file: &Path) -> Option<(String, Option<String>)> {
        let state: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(state_file).ok()?).ok()?;
        Some((
            state["anonymous_id"].as_str()?.to_owned(),
            state["identified"].as_str().map(str::to_owned),
        ))
    }

    // The GTK thread's futures, follow_account's among them, run while it waits.
    fn run(
        runtime: &AppRuntime,
        work: impl Future<Output = Result<(), AccountError>> + Send + 'static,
    ) -> Result<(), AccountError> {
        finish_on_main(WAIT, runtime.tasks().spawn_task(work))
            .expect("the work finished")
            .expect("the task ran")
    }

    fn signed_in_then_ended(ending: Ending) -> Result<(), AccountError> {
        let runtime = test_runtime();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let collector = PostHogCollector::start();
        let state_file = dir.path().join("telemetry.json");
        let telemetry = usage_data(&collector, &state_file, &runtime);
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let ended = Arc::new(AtomicBool::new(false));
        let stub = cloud(&machine, ending, ended.clone());
        let (account, handle) = account(&stub, machine, dir.path());
        follow_account(handle, telemetry.clone());
        wait_until(WAIT, || telemetry.is_sending()).expect("the usage data started");
        run(&runtime, {
            let account = account.clone();
            async move { account.sign_in(std::future::pending()).await }
        })
        .expect("signed in");
        wait_until(WAIT, || {
            kept_ids(&state_file).is_some_and(|(_, account_id)| account_id.as_deref() == Some(ACCOUNT))
        })
        .expect("identified as the account");
        let (anonymous_id, _) = kept_ids(&state_file).expect("the usage data's state");

        ended.store(true, Ordering::SeqCst);
        let refreshed = run(&runtime, {
            let account = account.clone();
            async move { account.refresh_entitlement().await }
        });

        wait_until(WAIT, || {
            kept_ids(&state_file)
                .is_some_and(|(anonymous, account_id)| account_id.is_none() && anonymous != anonymous_id)
        })
        .expect("reset to a new anonymous ID");
        telemetry.connection_attempted("sqlite");
        telemetry.flush();
        wait_until(WAIT, || !collector.named("connection_attempted").is_empty()).expect("the event sent");
        let (new_id, _) = kept_ids(&state_file).expect("the usage data's state");
        assert_eq!(collector.named("$identify")[0]["distinct_id"], ACCOUNT);
        // Only the user's own sign-out is an event: the account may be gone.
        assert!(collector.named("signed_out").is_empty());
        assert_eq!(
            collector.named("connection_attempted")[0]["distinct_id"],
            new_id.as_str()
        );
        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
        refreshed
    }

    #[gtk4::test]
    fn a_refused_refresh_token_only_resets_the_usage_data() {
        let refreshed = signed_in_then_ended(Ending::RefusedRefreshToken);

        assert!(matches!(refreshed, Err(AccountError::SignedOut)), "{refreshed:?}");
    }

    #[gtk4::test]
    fn a_removed_device_only_resets_the_usage_data() {
        let refreshed = signed_in_then_ended(Ending::RemovedDevice);

        assert!(matches!(refreshed, Err(AccountError::DeviceRevoked)), "{refreshed:?}");
    }

    #[test]
    fn app_opened_counts_each_attached_session_with_its_driver() {
        let runtime = test_runtime();
        let registry = SessionRegistry::new();
        let attached: Vec<_> = ["postgres", "sqlite", "postgres"]
            .into_iter()
            .map(|driver_id| {
                let mut request = FakeConnector::request().expect("a request");
                request.metadata.driver_id = driver_id.to_owned();
                let fake = FakeSession::start_for(request, ConnectionScript::default(), [], runtime.tasks());
                let claim = registry
                    .claim(SessionKey::Saved(uuid::Uuid::new_v4()), 1)
                    .expect("a claim");
                claim.attach(&fake.session);
                (claim, fake)
            })
            .collect();
        let _connecting = registry
            .claim(SessionKey::Saved(uuid::Uuid::new_v4()), 2)
            .expect("a claim");

        let mut opened = open_sessions(&registry);
        opened.driver_ids.sort();

        assert_eq!(opened.driver_ids, ["postgres", "postgres", "sqlite"]);
        assert_eq!(opened.connection_count, 3);
        drop(attached);
    }

    #[gtk4::test]
    fn app_opened_is_checked_after_the_delay_then_each_interval() {
        let started = Instant::now();
        let checks = Rc::new(RefCell::new(Vec::new()));
        let kept = checks.clone();
        check_app_opened(Duration::from_millis(300), Duration::from_millis(100), move || {
            kept.borrow_mut().push(started.elapsed());
            match kept.borrow().len() {
                3 => glib::ControlFlow::Break,
                _ => glib::ControlFlow::Continue,
            }
        });

        wait_until(WAIT, || checks.borrow().len() == 3).expect("three checks");
        let fourth = wait_until(Duration::from_millis(300), || checks.borrow().len() > 3);

        assert!(fourth.is_err(), "a check after the schedule stopped");
        let checks = checks.borrow();
        // glib times each interval from its dispatch, which is a moment before the check reads the clock.
        let slack = Duration::from_millis(10);
        assert!(checks[0] + slack >= Duration::from_millis(300), "{checks:?}");
        assert!(
            checks[1] - checks[0] + slack >= Duration::from_millis(100),
            "{checks:?}"
        );
        assert!(
            checks[2] - checks[1] + slack >= Duration::from_millis(100),
            "{checks:?}"
        );
    }

    #[test]
    fn this_build_sends_its_architecture_as_macos_names_it() {
        let sent = if cfg!(target_arch = "aarch64") {
            "arm64"
        } else {
            std::env::consts::ARCH
        };

        assert_eq!(person_properties().architecture, sent);
    }

    // glib reads the locale variables, which no test may change in a process running others.
    #[test]
    fn the_locale_is_the_interfaces_language_without_its_codeset() {
        let cases: [(&[(&str, &str)], &str); 5] = [
            (&[("LC_MESSAGES", "vi_VN.UTF-8"), ("LANG", "en_US.UTF-8")], "vi_VN"),
            (&[("LANGUAGE", "pt_BR:vi"), ("LC_MESSAGES", "vi_VN.UTF-8")], "pt_BR"),
            (&[("LC_MESSAGES", "sr_RS.UTF-8@latin")], "sr_RS"),
            (&[("LC_ALL", "de_DE.UTF-8"), ("LC_MESSAGES", "vi_VN.UTF-8")], "de_DE"),
            (&[], "C"),
        ];
        let module = module_path!().split_once("::").map_or("", |(_, path)| path);
        let name = format!("{module}::print_the_interface_locale");

        for (variables, expected) in cases {
            let mut child = std::process::Command::new(std::env::current_exe().expect("the test binary"));
            child.args(["--exact", &name, "--ignored", "--nocapture", "--test-threads=1"]);
            for variable in ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"] {
                child.env_remove(variable);
            }
            child.envs(variables.iter().copied());
            let output = child.output().expect("the child ran");
            let printed = String::from_utf8_lossy(&output.stdout);
            let locale = printed
                .split_once("interface locale: ")
                .and_then(|(_, rest)| rest.split_whitespace().next());

            assert_eq!(locale, Some(expected), "{variables:?}: {printed}");
        }
    }

    #[test]
    #[ignore = "the_locale_is_the_interfaces_language_without_its_codeset runs it with its own locale variables"]
    fn print_the_interface_locale() {
        println!("interface locale: {}", interface_locale());
    }
}
