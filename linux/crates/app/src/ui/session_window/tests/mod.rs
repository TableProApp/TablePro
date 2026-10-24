mod notification;
mod open_file;

use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;
use libadwaita as adw;
use tablepro_core::{AuthMode, DriverError, DriverRegistry, LivenessPolicy, TlsConfig};
use tablepro_session::fakes::{FakeConnector, FakeCredentialSource, FakeEstablish};
use tablepro_session::operation::DefaultDeadlines;
use tablepro_session::runtime::CountingHold;
use tablepro_session::{ConnectError, CredentialSource, SessionKey};
use tablepro_storage::{SavedConnection, StoragePaths};
use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeDriver, FakeReply, FakeSecretVault};

use super::*;
use crate::application::{AppServicesParts, TableProApplication};
use crate::runtime::Delivery;
use crate::services::session_context::CredentialSourceFactory;
use crate::storage::AppStorage;
use crate::test_support::{MemorySettings, assert_labelled, descendants, drain_main_context, wait_until};

pub(crate) const WAIT: Duration = Duration::from_secs(10);

/// Every saved connection, whatever it is, reads its secrets from one
/// fake, so a test can count the reads.
struct FakeSources(FakeCredentialSource);

impl CredentialSourceFactory for FakeSources {
    fn for_connection(
        &self,
        _saved: Option<&SavedConnection>,
        _session_only: &[tablepro_core::credentials::SecretKind],
    ) -> Arc<dyn CredentialSource> {
        Arc::new(self.0.clone())
    }
}

/// What a scripted world can change before the application starts.
#[derive(Default)]
pub(crate) struct Script {
    pub connection: ConnectionScript,
    /// What each connect gets, before `connection` from then on.
    pub establish: Vec<FakeEstablish>,
    pub credentials: Option<FakeCredentialSource>,
    pub ssh: Option<tablepro_ssh::SshServices>,
    /// The saved connection logs in to a server with a password, rather
    /// than opening a file.
    pub network: bool,
    /// The saved connection reaches its server through this SSH tunnel,
    /// logging in to the database as the system user.
    pub tunnel: Option<tablepro_storage::SavedSshConfig>,
    /// The connection list on disk cannot be read, so it holds nothing.
    pub unreadable_list: bool,
    /// The saved connection's engine holds keys, not tables.
    pub keys: bool,
    /// The size the window opens at, as the settings remember it.
    pub window_size: Option<(i32, i32)>,
    /// Stands in for the file manager.
    pub revealer: Option<Rc<dyn crate::ui::file_reveal::FileRevealer>>,
}

/// A TablePro over fakes with one window open on the picker and `saved`
/// in its connection list. The application has an id of its own, so it
/// never meets another test's, or a TablePro the developer has open, on
/// the session bus.
pub(crate) struct TestWindow {
    pub app: TableProApplication,
    pub window: SessionWindow,
    pub services: Rc<AppServices>,
    pub hold: Rc<CountingHold>,
    pub connector: FakeConnector,
    pub saved: SavedConnection,
    /// The keyring every saved connection reads, unless the script
    /// brings its own credentials.
    pub vault: Arc<FakeSecretVault>,
    runtime: Option<crate::runtime::AppRuntime>,
    _settings: MemorySettings,
    _dir: tempfile::TempDir,
}

impl TestWindow {
    pub(crate) fn picker(name: &str) -> Self {
        Self::with_script(name, Script::default())
    }

    pub(crate) fn with_script(name: &str, script: Script) -> Self {
        init_gtk();
        let runtime = crate::test_support::test_runtime();
        let settings = MemorySettings::new();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let paths = StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID);
        let list_file = paths.connections_file();
        let vault = Arc::new(FakeSecretVault::new());
        let storage = AppStorage::new(paths, vault.clone(), &runtime.tasks());
        let Script {
            mut connection,
            establish,
            credentials,
            ssh,
            network,
            tunnel,
            unreadable_list,
            keys,
            window_size,
            revealer,
        } = script;
        if let Some(size) = window_size {
            remember_window_size(&settings, size);
        }
        let network = network || keys || tunnel.is_some();
        let saved = scripted_connection(network, tunnel, dir.path());
        if unreadable_list {
            write_unreadable_list(&list_file);
        } else {
            storage
                .connections()
                .upsert_blocking(saved.clone())
                .expect("save the test's connection");
        }
        connection.probe.always(FakeReply::ok(()));
        connection.list_schemas.always(FakeReply::ok(Vec::new()));
        // A test that lists the database's objects for every read keeps
        // its list.
        if !connection.list_objects.answers_always() {
            connection.list_objects.always(FakeReply::ok(Vec::new()));
        }
        let mut drivers = DriverRegistry::new();
        let capabilities = match (keys, network) {
            (true, _) => &FakeDriver::KEY_VALUE_CAPABILITIES,
            (false, true) => &FakeDriver::NETWORK_CAPABILITIES,
            (false, false) => &FakeDriver::FILE_CAPABILITIES,
        };
        drivers.register(Arc::new(FakeDriver::connecting(capabilities, connection.clone())));
        // A second file engine, as the app ships two, whose files a
        // handed-over file is told apart from by its header.
        if !network {
            drivers.register(Arc::new(
                FakeDriver::connecting(&FakeDriver::SIGNED_FILE_CAPABILITIES, connection.clone()).with_id("duckdb"),
            ));
        }
        let connector = FakeConnector::new(establish).always(FakeEstablish::Connect(connection));
        let liveness = LivenessPolicy::DESKTOP;
        let hold = Rc::new(CountingHold::new());
        let parts = AppServicesParts {
            drivers,
            connector: Arc::new(connector.clone()),
            deadlines: Arc::new(DefaultDeadlines::new(liveness)),
            liveness,
            settings: settings.get().clone(),
            storage,
            tasks: runtime.tasks(),
        };
        let mut services = scripted_services(parts, hold.clone(), credentials, ssh);
        if let Some(revealer) = revealer {
            services.file_revealer = revealer;
        }
        let (app, window) = open_picker_window(name, services);
        let services = app.services().expect("the application's services");
        let test = Self {
            app,
            window,
            services,
            hold,
            connector,
            saved,
            vault,
            runtime: Some(runtime),
            _settings: settings,
            _dir: dir,
        };
        test.wait_for_page("picker");
        test
    }

    /// A window that opened the saved connection and shows its
    /// workspace.
    pub(crate) fn connected(name: &str) -> Self {
        Self::connected_with(name, |_| {})
    }

    pub(crate) fn connected_with(name: &str, script: impl FnOnce(&mut ConnectionScript)) -> Self {
        let mut connection = ConnectionScript::default();
        script(&mut connection);
        let test = Self::with_script(
            name,
            Script {
                connection,
                ..Script::default()
            },
        );
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        test
    }

    pub(crate) fn wait_for_page(&self, name: &str) {
        wait_until(WAIT, || self.window.page_name() == name)
            .unwrap_or_else(|_| panic!("the window stayed on {}, not {name}", self.window.page_name()));
    }

    pub(crate) fn workspace(&self) -> Workspace {
        self.window.workspace().expect("the window shows a workspace")
    }

    pub(crate) fn key(&self) -> SessionKey {
        SessionKey::Saved(self.saved.id)
    }

    /// Where the test keeps its files, the fake database among them.
    pub(crate) fn dir(&self) -> &std::path::Path {
        self._dir.path()
    }

    /// The connection the last connect built.
    pub(crate) fn connection(&self) -> Arc<FakeConnection> {
        self.connector.connections().pop().expect("a connection")
    }

    /// Open an editor tab through its window action and run what it
    /// holds, which opens the tab's own editor session.
    pub(crate) fn run_in_new_editor_tab(&self) {
        let before = editors(&self.window);
        WidgetExt::activate_action(&self.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
        wait_until(WAIT, || editors(&self.window).len() == before.len() + 1).expect("a new editor tab");
        let editor = editors(&self.window)
            .into_iter()
            .find(|editor| !before.contains(editor))
            .expect("the new editor");
        editor.run();
        wait_until(WAIT, || !editor.is_running()).expect("the run to end");
    }
}

fn init_gtk() {
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_enable_animations(false);
    }
}

fn remember_window_size(settings: &MemorySettings, (width, height): (i32, i32)) {
    settings
        .get()
        .set_window_geometry(tablepro_storage::WindowGeometry {
            width,
            height,
            maximized: false,
        })
        .expect("store the window size");
}

/// The connection the script's world has saved: through `tunnel` when
/// it has one, to a server when `network`, else to a file under `dir`.
fn scripted_connection(
    network: bool,
    tunnel: Option<tablepro_storage::SavedSshConfig>,
    dir: &std::path::Path,
) -> SavedConnection {
    match tunnel {
        Some(tunnel) => SavedConnection {
            ssh: Some(tunnel),
            auth_mode: AuthMode::Kerberos,
            ..network_connection()
        },
        None if network => network_connection(),
        None => saved_connection(&dir.join("fake.db")),
    }
}

fn write_unreadable_list(list_file: &std::path::Path) {
    if let Some(parent) = list_file.parent() {
        std::fs::create_dir_all(parent).expect("the config directory");
    }
    std::fs::write(list_file, b"{ not json").expect("the unreadable list");
}

fn scripted_services(
    parts: AppServicesParts,
    hold: Rc<CountingHold>,
    credentials: Option<FakeCredentialSource>,
    ssh: Option<tablepro_ssh::SshServices>,
) -> AppServices {
    let mut services = AppServices::new(parts).with_hold(hold);
    if let Some(credentials) = credentials {
        services = services.with_credentials(Rc::new(FakeSources(credentials)));
    }
    if let Some(ssh) = ssh {
        services = services.with_ssh(ssh);
    }
    services
}

fn open_picker_window(name: &str, services: AppServices) -> (TableProApplication, SessionWindow) {
    let app = TableProApplication::new(services);
    app.set_application_id(Some(&format!("{}.Test.Window{name}", crate::config::APP_ID)));
    app.register(gio::Cancellable::NONE).expect("register the application");
    let window = app
        .open_window(WindowLaunch::Picker)
        .and_then(|window| window.downcast::<SessionWindow>().ok())
        .expect("a session window");
    (app, window)
}

impl Drop for TestWindow {
    fn drop(&mut self) {
        for window in self.app.windows() {
            crate::test_support::drop_focus(&window);
            window.destroy();
        }
        drain_main_context();
        crate::test_support::end_application(&self.app);
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

pub(crate) fn editors(window: &SessionWindow) -> Vec<crate::ui::editor::SqlEditor> {
    descendants(window)
        .into_iter()
        .filter_map(|widget| widget.downcast::<crate::ui::editor::SqlEditor>().ok())
        .collect()
}

fn saved_connection(database: &std::path::Path) -> SavedConnection {
    SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: "Fake".to_owned(),
        driver_id: "fake".to_owned(),
        host: String::new(),
        port: 0,
        database: database.display().to_string(),
        username: String::new(),
        tls: TlsConfig::verify_full(),
        safe_mode: tablepro_core::SafeModeLevel::Off,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

/// A server on this machine, so no reachability check runs.
fn network_connection() -> SavedConnection {
    SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: "Server".to_owned(),
        driver_id: "fake".to_owned(),
        host: "127.0.0.1".to_owned(),
        port: 5432,
        database: "shop".to_owned(),
        username: "app".to_owned(),
        tls: TlsConfig::verify_full(),
        safe_mode: tablepro_core::SafeModeLevel::Off,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

/// The connect dialog's Connect on a new entry for the file `endpoint`.
pub(crate) fn dialog_submission(endpoint: tablepro_core::FileEndpoint) -> ConnectSubmission {
    let mut request = FakeConnector::request().expect("a request");
    let mut connection = saved_connection(endpoint.path());
    connection.id = request.metadata.id;
    request.target = tablepro_session::RequestTarget::File(endpoint);
    ConnectSubmission {
        request,
        pending_save: tablepro_session::PendingSave {
            connection,
            secrets: Vec::new(),
            forget: Vec::new(),
            is_new: true,
        },
    }
}

pub(crate) fn refused() -> FakeEstablish {
    FakeEstablish::Fail(ConnectError::Driver(DriverError::Auth { diagnostics: None }))
}

#[gtk4::test]
fn a_connected_window_shows_the_workspace_and_claims_its_key() {
    let test = TestWindow::connected("Connects");

    assert_eq!(test.services.sessions.window_for(&test.key()), Some(test.window.id()));
    assert_eq!(test.services.sessions.live_count(), 1);
    assert!(
        test.window
            .lookup_action("disconnect")
            .is_some_and(|action| action.is_enabled())
    );
}

fn stored_level(test: &TestWindow) -> Option<tablepro_core::SafeModeLevel> {
    match test.services.storage.connections().snapshot().state {
        tablepro_storage::ConnectionListState::Ready(list) => list
            .connections
            .iter()
            .find(|saved| saved.id == test.saved.id)
            .map(|saved| saved.safe_mode),
        _ => None,
    }
}

fn pick_level(test: &TestWindow, target: &str) {
    WidgetExt::activate_action(&test.window, "win.safe-mode", Some(&target.to_variant()))
        .expect("the window's safe-mode action");
}

fn ticked_level(test: &TestWindow) -> Option<String> {
    test.window
        .lookup_action("safe-mode")
        .and_then(|action| action.state())
        .and_then(|state| state.get::<String>())
}

#[gtk4::test]
fn the_main_menu_moves_the_session_between_levels_that_write_and_saves_it() {
    let test = TestWindow::connected("SafeModeLive");
    assert_eq!(ticked_level(&test).as_deref(), Some("off"));

    pick_level(&test, "confirm-writes");
    wait_until(WAIT, || {
        stored_level(&test) == Some(tablepro_core::SafeModeLevel::ConfirmWrites)
    })
    .expect("the level saved back");

    let super::session_page::SessionPage::Workspace { session, .. } = &*test.window.imp().page.borrow() else {
        panic!("the window left its workspace");
    };
    assert_eq!(session.safe_mode(), tablepro_core::SafeModeLevel::ConfirmWrites);
    assert_eq!(ticked_level(&test).as_deref(), Some("confirm-writes"));
    assert_eq!(test.connector.calls().len(), 1, "a level that writes reconnected");
}

#[gtk4::test]
fn read_only_from_the_main_menu_saves_it_and_connects_again_read_only() {
    let test = TestWindow::connected("SafeModeReadOnly");

    pick_level(&test, "read-only");
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("a second connect");
    test.wait_for_page("workspace");

    let reopened = test.connector.calls().pop().expect("the reconnect").request;
    assert!(reopened.workspace_settings.read_only);
    assert_eq!(reopened.safe_mode, tablepro_core::SafeModeLevel::ReadOnly);
    assert_eq!(stored_level(&test), Some(tablepro_core::SafeModeLevel::ReadOnly));
    wait_until(WAIT, || ticked_level(&test).as_deref() == Some("read-only")).expect("Read-Only ticked");
}

#[gtk4::test]
fn the_levels_are_off_without_a_session() {
    let test = TestWindow::picker("SafeModePicker");

    assert!(
        test.window
            .lookup_action("safe-mode")
            .is_some_and(|action| !action.is_enabled())
    );
}

#[gtk4::test]
fn the_header_icon_buttons_are_labelled() {
    let test = TestWindow::connected("Labels");
    let picker = test.window.imp().picker.get().expect("the picker").clone();

    // The tab overview's own header is libadwaita's, outside the
    // workspace's breakpoint bin.
    let panes = test.workspace().imp().breakpoint_bin.get();
    for root in [picker.upcast::<gtk4::Widget>(), panes.upcast()] {
        let headers = descendants(&root)
            .into_iter()
            .filter(|widget| widget.is::<adw::HeaderBar>());
        let buttons: Vec<gtk4::Widget> = headers
            .flat_map(|header| descendants(&header))
            // A menu button's own toggle, and the tab button's inner
            // button, are labelled through their outer widget.
            .filter(|widget| {
                let inner = widget
                    .parent()
                    .is_some_and(|parent| parent.is::<gtk4::MenuButton>() || parent.is::<adw::TabButton>());
                widget.is::<gtk4::MenuButton>()
                    || widget.is::<adw::TabButton>()
                    || (widget.is::<gtk4::ToggleButton>() && !inner)
                    || widget
                        .downcast_ref::<gtk4::Button>()
                        .is_some_and(|button| button.icon_name().is_some() && !inner)
            })
            .collect();
        assert!(!buttons.is_empty(), "no header buttons under {}", root.type_().name());
        for button in buttons {
            assert_labelled(&button).unwrap_or_else(|problem| panic!("{problem:?}: {:?}", button.tooltip_text()));
        }
    }
}

fn shows_text(root: &impl IsA<gtk4::Widget>, text: &str) -> bool {
    descendants(root)
        .iter()
        .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
        .any(|label| label.label() == text)
}

#[gtk4::test]
fn toast_routes_to_current_page_overlay() {
    let test = TestWindow::picker("ToastRoutes");
    let picker = test.window.imp().picker.get().expect("the picker").clone();

    test.window.show_toast("on the picker");
    drain_main_context();
    assert!(shows_text(&picker.toast_overlay(), "on the picker"));

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    test.window.show_toast("on the workspace");
    drain_main_context();

    let workspace = test.workspace();
    assert!(shows_text(&workspace.toast_overlay(), "on the workspace"));
    assert!(!shows_text(&picker.toast_overlay(), "on the workspace"));
    assert!(
        workspace
            .toast_overlay()
            .ancestor(adw::TabOverview::static_type())
            .is_some(),
        "the workspace's toasts sit above the tab overview"
    );
}

#[gtk4::test]
fn the_connect_dialog_opens_once_over_its_own_window() {
    let test = TestWindow::picker("ConnectDialog");

    test.window.send(SessionWindowInput::OpenConnectDialog);
    test.window.send(SessionWindowInput::OpenConnectDialog);
    wait_until(WAIT, || test.window.imp().dialog.borrow().is_some()).expect("the connect dialog");
    drain_main_context();

    let dialogs = descendants(&test.window)
        .into_iter()
        .filter(|widget| widget.is::<crate::ui::connect_dialog::ConnectDialog>())
        .count();
    assert_eq!(dialogs, 1);
}

#[gtk4::test]
fn claiming_open_key_presents_owner_window() {
    let test = TestWindow::connected("Owner");
    let other = test
        .app
        .open_window(WindowLaunch::Picker)
        .and_then(|window| window.downcast::<SessionWindow>().ok())
        .expect("a second window");
    wait_until(WAIT, || other.page_name() == "picker").expect("the second window's picker");
    test.window.set_visible(false);

    other.send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    wait_until(WAIT, || test.window.is_visible()).expect("the owner to come forward");

    assert_eq!(other.page_name(), "picker", "the second window connected too");
    assert_eq!(test.connector.calls().len(), 1, "a second connection was built");
    assert_eq!(test.services.sessions.window_for(&test.key()), Some(test.window.id()));
}

#[gtk4::test]
fn f002_cancel_connect_discards_late_attempt() {
    let test = TestWindow::with_script(
        "CancelLate",
        Script {
            establish: vec![FakeEstablish::Late {
                after: Duration::from_millis(300),
                script: ConnectionScript::default(),
            }],
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connecting");
    // A cancel before the driver is asked builds no connection at all.
    wait_until(WAIT, || !test.connector.calls().is_empty()).expect("the connect to reach the driver");

    test.window.send(SessionWindowInput::CancelConnect);
    test.wait_for_page("picker");
    assert_eq!(
        test.services.sessions.window_for(&test.key()),
        None,
        "the claim outlived the cancel"
    );
    wait_until(WAIT, || {
        test.connector
            .connections()
            .first()
            .is_some_and(|connection| connection.is_closed())
    })
    .expect("the late connection to close");
    drain_main_context();

    assert_eq!(test.window.page_name(), "picker", "the late connect was adopted");
    assert_eq!(test.services.sessions.live_count(), 0);
}

#[gtk4::test]
fn a_connect_that_lands_after_its_window_closed_is_closed() {
    let test = TestWindow::picker("LandsAfterClose");
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connecting");
    // The connect ends on the runtime while the main loop waits, so its
    // answer reaches the window only after the window is gone.
    let deadline = std::time::Instant::now() + WAIT;
    while test.connector.connections().is_empty() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(100));

    test.window.destroy();
    let connection = test.connection();
    wait_until(WAIT, || connection.is_closed()).expect("the late connection to close");

    assert_eq!(test.services.sessions.live_count(), 0);
}

#[gtk4::test]
fn a_connect_still_queued_when_its_window_shuts_down_is_closed() {
    let test = TestWindow::picker("QueuedAtShutdown");
    let request = FakeConnector::request().expect("a request");
    let (pending, connection) = FakeConnector::pending_session(request, ConnectionScript::default());
    let attempt = SessionWindowCommand::Attempt {
        generation: tablepro_session::connect::AttemptGeneration::FIRST,
        result: Ok(Connected {
            pending,
            saved: None,
            warnings: Vec::new(),
            session_only: Vec::new(),
        }),
    };

    test.window.send(SessionWindowInput::Command(Box::new(attempt)));
    test.window.shutdown();

    wait_until(WAIT, || connection.is_closed()).expect("the queued connection to close");
}

#[gtk4::test]
fn a_failed_connect_shows_why_and_choose_connection_returns_to_the_picker() {
    let test = TestWindow::with_script(
        "Failed",
        Script {
            establish: vec![refused()],
            ..Script::default()
        },
    );

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");
    let page = test
        .window
        .content()
        .and_then(|child| child.downcast::<ConnectFailedPage>().ok())
        .expect("the failed page");
    assert!(page.message().is_some_and(|message| !message.is_empty()));
    assert!(
        test.window
            .lookup_action("retry-connect")
            .is_some_and(|action| action.is_enabled())
    );
    assert_eq!(test.services.sessions.window_for(&test.key()), Some(test.window.id()));

    WidgetExt::activate_action(&test.window, "win.cancel-connect", None).expect("win.cancel-connect");
    test.wait_for_page("picker");

    assert_eq!(test.services.sessions.window_for(&test.key()), None);
}

#[gtk4::test]
fn connecting_page_uses_spinner_paintable_and_cancel_action() {
    let test = TestWindow::with_script(
        "ConnectingPage",
        Script {
            establish: vec![FakeEstablish::UntilCancelled],
            ..Script::default()
        },
    );

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connecting");

    let page = test
        .window
        .content()
        .and_downcast::<ConnectingPage>()
        .expect("the connecting page");
    assert!(
        page.status_page()
            .paintable()
            .and_downcast::<adw::SpinnerPaintable>()
            .is_some(),
        "the status page draws no spinner"
    );
    assert_eq!(page.status_page().title(), "Connecting to Fake");
    let cancel = page.cancel_button();
    assert_eq!(cancel.action_name().as_deref(), Some("win.cancel-connect"));
    assert_eq!(test.window.default_widget(), Some(cancel.upcast()));
    assert_eq!(test.window.title().as_deref(), Some("Connecting"));
    assert_eq!(
        page.announced(),
        [(
            "Connecting to Fake".to_owned(),
            gtk4::AccessibleAnnouncementPriority::Medium
        )]
    );

    WidgetExt::activate_action(&test.window, "win.cancel-connect", None).expect("win.cancel-connect");
    test.wait_for_page("picker");
    assert_eq!(
        test.window.default_widget(),
        None,
        "Enter still reached the gone Cancel"
    );
}

#[gtk4::test]
fn failed_page_offers_retry_edit_and_choose() {
    let test = TestWindow::with_script(
        "FailedPage",
        Script {
            establish: vec![refused()],
            ..Script::default()
        },
    );

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");

    let page = test
        .window
        .content()
        .and_downcast::<ConnectFailedPage>()
        .expect("the failed page");
    let status = page.status_page();
    assert_eq!(status.icon_name().as_deref(), Some("network-error-symbolic"));
    assert_eq!(status.title(), "Could Not Connect");
    let [retry, edit, choose] = page.buttons();
    assert_eq!(retry.action_name().as_deref(), Some("win.retry-connect"));
    assert_eq!(edit.action_name().as_deref(), Some("win.edit-connection"));
    assert_eq!(choose.action_name().as_deref(), Some("win.cancel-connect"));
    assert!(edit.is_visible(), "a saved connection offered no Edit Connection");
    assert!(choose.has_css_class("flat"));
    assert!(
        test.window
            .lookup_action("edit-connection")
            .is_some_and(|action| action.is_enabled())
    );
    let default = test.window.default_widget().expect("a default button");
    assert!(
        default.is_visible() && default.has_css_class("suggested-action"),
        "Enter does not take the suggested way on"
    );
    assert_eq!(test.window.title().as_deref(), Some("Could Not Connect"));
    let message = page.message().expect("the reason");
    assert_eq!(
        page.announced(),
        [(
            format!("Could Not Connect. {message}"),
            gtk4::AccessibleAnnouncementPriority::High
        )]
    );
}

#[gtk4::test]
fn a_file_that_failed_offers_no_edit() {
    let test = TestWindow::picker("FailedFile");

    test.window.send(SessionWindowInput::OpenFile(gio::File::for_path(
        test.dir().join("gone.db"),
    )));
    test.wait_for_page("connect-failed");

    let page = test
        .window
        .content()
        .and_downcast::<ConnectFailedPage>()
        .expect("the failed page");
    assert!(!page.buttons()[1].is_visible());
    assert!(
        test.window
            .lookup_action("edit-connection")
            .is_some_and(|action| !action.is_enabled())
    );
}

#[gtk4::test]
fn edit_connection_opens_edit_dialog_and_retries_on_save() {
    let test = TestWindow::with_script(
        "EditRetries",
        Script {
            establish: vec![refused()],
            network: true,
            ..Script::default()
        },
    );
    let (vault, id) = (test.vault.clone(), test.saved.id);
    crate::test_support::finish_on_main(WAIT, async move {
        tablepro_core::credentials::SecretVault::store(
            &*vault,
            id,
            tablepro_core::credentials::SecretKind::DatabasePassword,
            &secrecy::SecretString::from("s3cret"),
            "label",
        )
        .await
    })
    .expect("the store to end")
    .expect("the password stored");
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");

    WidgetExt::activate_action(&test.window, "win.edit-connection", None).expect("win.edit-connection");
    let mut shown = None;
    wait_until(WAIT, || {
        shown = test
            .window
            .visible_dialog()
            .and_downcast::<crate::ui::connect_dialog::ConnectDialog>();
        shown.is_some()
    })
    .expect("the connect dialog");
    let dialog = shown.expect("the dialog");
    assert_eq!(dialog.editing().map(|saved| saved.id), Some(test.saved.id));
    assert_eq!(test.connector.calls().len(), 1);
    dialog.imp().port_row.set_value(6543.0);

    dialog.imp().connect_button.emit_clicked();

    test.wait_for_page("workspace");
    let calls = test.connector.calls();
    assert_eq!(calls.len(), 2, "Save did not connect again");
    let tablepro_session::RequestTarget::Network { endpoint, .. } = &calls[1].request.target else {
        panic!("expected a network target");
    };
    assert_eq!(endpoint.port(), 6543, "the retry connected to the entry as it was");
    assert_eq!(test.window.visible_dialog(), None, "the dialog stayed open");
}

#[gtk4::test]
fn a_close_while_the_page_is_read_does_not_panic() {
    let test = TestWindow::with_script(
        "CloseWhileRead",
        Script {
            establish: vec![refused()],
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");

    let page = test.window.imp().page.borrow();
    test.window.release_session();
    drop(page);

    assert_eq!(test.window.page_name(), "connect-failed");
}

#[gtk4::test]
fn retry_rereads_credentials() {
    let credentials = FakeCredentialSource::new();
    let test = TestWindow::with_script(
        "Retry",
        Script {
            establish: vec![refused()],
            credentials: Some(credentials.clone()),
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");
    let before = credentials.refreshes().len();

    test.window.send(SessionWindowInput::RetryConnect);
    test.wait_for_page("workspace");

    assert_eq!(credentials.refreshes().len(), before + 1);
}

#[gtk4::test]
fn retry_connects_to_the_entry_as_saved_now() {
    let test = TestWindow::with_script(
        "RetryEdited",
        Script {
            establish: vec![refused()],
            ..Script::default()
        },
    );
    let store = test.services.storage.connections().clone();
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");
    let mut renamed = test.saved.clone();
    renamed.name = "Renamed".to_owned();
    store.upsert_blocking(renamed).expect("edit the entry");

    test.window.send(SessionWindowInput::RetryConnect);
    test.wait_for_page("workspace");

    let names: Vec<String> = test
        .connector
        .calls()
        .iter()
        .map(|call| call.request.metadata.name.clone())
        .collect();
    assert_eq!(names, ["Fake", "Renamed"]);
}

#[gtk4::test]
fn retry_after_the_entry_was_deleted_returns_to_the_picker() {
    let test = TestWindow::with_script(
        "RetryDeleted",
        Script {
            establish: vec![refused()],
            ..Script::default()
        },
    );
    let store = test.services.storage.connections().clone();
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");
    store.remove_blocking(test.saved.id).expect("delete the entry");

    test.window.send(SessionWindowInput::RetryConnect);
    test.wait_for_page("picker");

    assert_eq!(test.connector.calls().len(), 1, "the deleted entry was connected to");
    assert_eq!(test.services.sessions.window_for(&test.key()), None);
}

#[gtk4::test]
fn missing_file_goes_to_connect_failed() {
    let test = TestWindow::picker("MissingFile");
    let missing = test._dir.path().join("gone.db");

    test.window
        .send(SessionWindowInput::OpenFile(gio::File::for_path(&missing)));
    test.wait_for_page("connect-failed");

    let message = test
        .window
        .content()
        .and_then(|child| child.downcast::<ConnectFailedPage>().ok())
        .and_then(|page| page.message())
        .expect("the failed page's message");
    assert!(message.contains("gone.db"), "{message}");
    assert!(test.connector.calls().is_empty(), "a missing file was connected to");
}

/// The page reads its description as markup, where the `&` would
/// leave the reason empty.
#[gtk4::test]
fn a_reason_with_an_ampersand_shows_on_the_failed_page() {
    let test = TestWindow::picker("MissingAmpersand");
    let missing = test._dir.path().join("R&D").join("gone.db");

    test.window
        .send(SessionWindowInput::OpenFile(gio::File::for_path(&missing)));
    test.wait_for_page("connect-failed");

    let message = test
        .window
        .content()
        .and_then(|child| child.downcast::<ConnectFailedPage>().ok())
        .and_then(|page| page.message())
        .expect("the failed page's message");
    assert!(message.contains("R&D"), "{message}");
}

#[gtk4::test]
fn a_file_whose_resolve_never_ran_goes_to_connect_failed() {
    let mut test = TestWindow::picker("ResolveStopped");
    let database = test._dir.path().join("local.db");
    // With the runtime gone, the resolve is cancelled before it starts.
    if let Some(runtime) = test.runtime.take() {
        runtime.shutdown();
    }

    test.window
        .send(SessionWindowInput::OpenFile(gio::File::for_path(&database)));
    test.wait_for_page("connect-failed");

    assert!(
        test.connector.calls().is_empty(),
        "a file nobody resolved was connected to"
    );
}

#[gtk4::test]
fn an_unsaved_file_opens_a_session_of_its_own() {
    let test = TestWindow::picker("File");
    let database = test._dir.path().join("local.db");
    std::fs::write(&database, b"").expect("seed");

    test.window
        .send(SessionWindowInput::OpenFile(gio::File::for_path(&database)));
    test.wait_for_page("workspace");

    let uri = glib::filename_to_uri(std::fs::canonicalize(&database).expect("canonical"), None)
        .expect("a uri")
        .to_string();
    assert_eq!(
        test.services.sessions.window_for(&SessionKey::File(uri)),
        Some(test.window.id())
    );
}

#[gtk4::test]
fn a_file_window_that_could_not_show_the_owner_stays_open_from_then_on() {
    let test = TestWindow::connected("OpenFileOwnerGone");
    let database = test._dir.path().join("local.db");
    std::fs::write(&database, b"").expect("seed");
    let uri = glib::filename_to_uri(std::fs::canonicalize(&database).expect("canonical"), None)
        .expect("a uri")
        .to_string();
    // An owner the application cannot bring forward.
    let _held = test
        .services
        .sessions
        .claim(SessionKey::File(uri), test.window.id() + 100)
        .expect("claim the file");
    let extra = test
        .app
        .open_window(WindowLaunch::OpenFile(gio::File::for_path(&database)))
        .and_then(|window| window.downcast::<SessionWindow>().ok())
        .expect("a window for the file");
    wait_until(WAIT, || !extra.imp().opening_file.get()).expect("the file to resolve");
    drain_main_context();
    assert_eq!(extra.page_name(), "picker");
    test.window.set_visible(false);

    extra.send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    wait_until(WAIT, || test.window.is_visible()).expect("the connection's window to come forward");
    drain_main_context();

    assert_eq!(test.app.windows().len(), 2, "the picker closed under the user");
    assert_eq!(extra.page_name(), "picker");
}

#[gtk4::test]
fn f002_late_show_create_reply_after_disconnect_is_dropped() {
    let test = TestWindow::connected_with("LateShowCreate", |script| {
        script.dialect = Arc::new(tablepro_driver_postgres::PgDialect::new(
            &tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0),
        ));
        script.fetch_table_definition.always(FakeReply::Late {
            after: Duration::from_millis(300),
            outcome: Ok(users_table()),
        });
    });
    let counters = test.connection().counters();
    let workspace = test.workspace().downgrade();
    let input = test.workspace().input().expect("the workspace's input");
    input.deliver(WorkspaceInput::ShowCreateTableForExisting {
        schema: Some("public".to_owned()),
        table: "users".to_owned(),
    });
    wait_until(WAIT, || CallCounters::get(&counters.fetch_table_definition) == 1)
        .expect("the definition was asked for");

    test.window.send(SessionWindowInput::Disconnect);
    test.wait_for_page("picker");
    drain_main_context();
    // The reply comes back through the workspace's input, which the
    // teardown closes before the reply is due.
    assert_eq!(
        input.try_deliver(WorkspaceInput::RefreshPage),
        Delivery::ReceiverGone,
        "the torn-down workspace still takes input"
    );
    let _ = wait_until(Duration::from_millis(600), || false);
    drain_main_context();

    assert!(workspace.upgrade().is_none(), "the workspace outlived its teardown");
    assert_eq!(test.window.page_name(), "picker");
    assert!(editors(&test.window).is_empty(), "the late reply opened an editor tab");
}

#[gtk4::test]
fn an_edit_kept_for_its_next_connect_is_written_under_a_hold() {
    let test = TestWindow::picker("PersistHeld");
    wait_until(WAIT, || test.hold.live() == 0).expect("nothing else to hold the process");
    let mut edited = test.saved.clone();
    edited.name = "Edited".to_owned();

    test.window.persist_pending_save(tablepro_session::PendingSave {
        connection: edited,
        secrets: Vec::new(),
        forget: Vec::new(),
        is_new: false,
    });
    assert_eq!(test.hold.live(), 1, "the write started without holding the process");
    wait_until(WAIT, || test.hold.live() == 0).expect("the hold to end");

    let stored = test
        .services
        .storage
        .connections()
        .load_blocking()
        .expect("the connection list");
    assert!(
        stored.iter().any(|saved| saved.name == "Edited"),
        "the hold ended before the write"
    );
}

#[gtk4::test]
fn quit_closes_a_connected_window_and_its_session() {
    let test = TestWindow::connected("Quit");
    let counters = test.connection().counters();

    let decision = crate::test_support::finish_on_main(WAIT, crate::application::QuitSequence::run(test.app.clone()))
        .expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Approved);
    wait_until(WAIT, || CallCounters::get(&counters.close) == 1).expect("the connection to close");
    assert!(test.app.windows().is_empty());
    assert_eq!(test.services.sessions.live_count(), 0);
}

#[expect(
    clippy::disallowed_methods,
    reason = "a test stands in for the catalogue a driver would read"
)]
fn users_table() -> tablepro_core::ddl::TableDefinition {
    use tablepro_core::column::{
        CatalogType, ColumnDefault, ColumnKind, ColumnType, ReadForm, SqlTypeExpr, TextLength,
    };
    use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition, TableDefinition};
    use tablepro_core::meta::TableRef;

    let column = ColumnDefinition::new(
        tablepro_core::ColumnInfo {
            name: "id".to_owned(),
            column_type: ColumnType {
                name: "text".to_owned(),
                kind: ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
                catalog: Some(CatalogType {
                    declaration: SqlTypeExpr::from_catalog_text("text"),
                    cast_target: SqlTypeExpr::from_catalog_text("text"),
                }),
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        },
        ColumnAttributes::default(),
    );
    TableDefinition {
        table: TableRef::new(Some("public".to_owned()), "users"),
        columns: vec![column],
        primary_key: None,
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: None,
    }
}
