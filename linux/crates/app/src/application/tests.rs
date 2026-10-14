use std::cell::Cell;
use std::ops::ControlFlow;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use libadwaita as adw;
use tablepro_core::{DriverRegistry, LivenessPolicy};
use tablepro_session::fakes::FakeConnector;
use tablepro_session::operation::DefaultDeadlines;
use tablepro_storage::StoragePaths;
use tablepro_test_support::FakeSecretVault;

use super::*;
use crate::storage::AppStorage;
use crate::test_support::{MemorySettings, finish_on_main, wait_until};
use crate::workspace::{CloseDecision, InhibitReason, InhibitTarget, WindowInhibitor};

const WAIT: Duration = Duration::from_secs(10);

/// What fake services need kept alive for as long as the test runs.
struct Backing {
    runtime: Option<crate::runtime::AppRuntime>,
    _settings: MemorySettings,
    _dir: tempfile::TempDir,
}

impl Drop for Backing {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

fn fake_services() -> (AppServices, Backing) {
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_enable_animations(false);
    }
    let runtime = crate::test_support::test_runtime();
    let settings = MemorySettings::new();
    let dir = tempfile::tempdir().expect("a temporary directory");
    let paths = StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID);
    let storage = AppStorage::new(paths, Arc::new(FakeSecretVault::new()), &runtime.tasks());
    let liveness = LivenessPolicy::DESKTOP;
    let services = AppServices::new(AppServicesParts {
        drivers: DriverRegistry::new(),
        connector: Arc::new(FakeConnector::new([])),
        deadlines: Arc::new(DefaultDeadlines::new(liveness)),
        liveness,
        settings: settings.get().clone(),
        storage,
        tasks: runtime.tasks(),
    });
    let backing = Backing {
        runtime: Some(runtime),
        _settings: settings,
        _dir: dir,
    };
    (services, backing)
}

/// An application over fakes, under an id of its own so it never meets
/// another test's application, or a TablePro the developer has open, on
/// the session bus.
struct TestApp {
    app: TableProApplication,
    _backing: Backing,
}

impl TestApp {
    fn new(name: &str) -> Self {
        let (services, backing) = fake_services();
        let app = TableProApplication::new(services);
        app.set_application_id(Some(&format!("{}.Test.{name}", crate::config::SCHEMA_ID)));
        Self { app, _backing: backing }
    }

    fn started(name: &str) -> Self {
        let test = Self::new(name);
        test.app
            .register(gio::Cancellable::NONE)
            .expect("register the application");
        test
    }

    fn window(&self) -> adw::ApplicationWindow {
        self.app.open_window(WindowLaunch::Picker).expect("a window")
    }
}

impl Drop for TestApp {
    fn drop(&mut self) {
        for window in self.app.windows() {
            window.destroy();
        }
        crate::test_support::drain_main_context();
    }
}

/// Grants every inhibition, as a session manager would.
struct GrantingSession;

impl InhibitTarget for GrantingSession {
    fn inhibit(&self, _flags: gtk4::ApplicationInhibitFlags, _reason: &str) -> u32 {
        1
    }

    fn uninhibit(&self, _cookie: u32) {}
}

#[gtk4::test]
fn new_builds_on_the_configured_id_and_resources() {
    let (services, _backing) = fake_services();

    let app = TableProApplication::new(services);

    assert_eq!(app.application_id().as_deref(), Some(crate::config::APP_ID));
    assert_eq!(
        app.resource_base_path().as_deref(),
        Some(crate::config::RESOURCE_BASE_PATH)
    );
    assert!(app.services().is_some());
    assert!(glib::Object::new::<TableProApplication>().services().is_none());
}

#[gtk4::test]
fn new_window_option_registered_before_parse() {
    let test = TestApp::new("Parse");
    let seen = Rc::new(Cell::new(false));
    let sink = seen.clone();
    test.app.connect_handle_local_options(move |_, options| {
        sink.set(options.contains("new-window"));
        ControlFlow::Break(glib::ExitCode::SUCCESS)
    });

    let code = test.app.run_with_args(&["tablepro", "--new-window"]);

    assert_eq!(code, glib::ExitCode::SUCCESS, "GApplication refused --new-window");
    assert!(seen.get(), "handle-local-options did not see --new-window");
}

#[gtk4::test]
fn handle_local_options_new_window_on_primary_continues() {
    let test = TestApp::new("Primary");
    let options = glib::VariantDict::new(None);
    options.insert_value("new-window", &true.to_variant());

    let flow = test.app.imp().handle_local_options(&options);

    assert!(matches!(flow, ControlFlow::Continue(())), "{flow:?}");
    assert!(test.app.is_registered() && !test.app.is_remote());
}

#[gtk4::test]
fn handle_local_options_without_new_window_does_not_register() {
    let test = TestApp::new("Plain");

    let flow = test.app.imp().handle_local_options(&glib::VariantDict::new(None));

    assert!(matches!(flow, ControlFlow::Continue(())), "{flow:?}");
    assert!(!test.app.is_registered());
}

#[gtk4::test]
fn startup_installs_the_app_actions_and_their_accels() {
    let test = TestApp::started("Actions");

    for action in ["new-window", "quit", "preferences", "about"] {
        assert!(test.app.lookup_action(action).is_some(), "app.{action} is missing");
    }
    for (action, _) in APP_ACCELS {
        assert!(!test.app.accels_for_action(action).is_empty(), "{action} has no accel");
    }
}

#[gtk4::test]
fn activate_opens_one_picker_and_then_presents_it() {
    let test = TestApp::started("Activate");

    test.app.activate();
    test.app.activate();

    assert_eq!(test.app.windows().len(), 1);
    assert_eq!(test.app.imp().windows.len(), 1);
}

#[gtk4::test]
fn new_window_action_opens_another_window() {
    let test = TestApp::started("NewWindow");
    test.window();

    test.app.activate_action("new-window", None);

    assert_eq!(test.app.windows().len(), 2);
    assert_eq!(test.app.imp().windows.len(), 2);
}

#[gtk4::test]
fn a_window_before_startup_is_refused() {
    let test = TestApp::new("Early");

    assert!(test.app.open_window(WindowLaunch::Picker).is_none());
    assert_eq!(test.app.imp().windows.len(), 0);
}

#[gtk4::test]
fn a_removed_window_takes_its_controller_with_it() {
    let test = TestApp::started("Removed");
    let window = test.window();
    assert_eq!(test.app.imp().windows.len(), 1);

    window.destroy();

    assert_eq!(test.app.imp().windows.len(), 0);
}

#[gtk4::test]
fn present_window_finds_the_window_by_id() {
    let test = TestApp::started("Present");
    let window = test.window();
    window.set_visible(false);

    assert!(test.app.present_window(window.id()));
    assert!(window.is_visible());
    assert!(!test.app.present_window(window.id() + 100));
}

#[gtk4::test]
fn query_end_presents_inhibiting_window() {
    let test = TestApp::started("QueryEnd");
    let idle = test.window();
    let busy = test.window();
    for window in [&idle, &busy] {
        window.set_visible(false);
    }
    let mut inhibitor = WindowInhibitor::new(GrantingSession);
    inhibitor.update(Some(InhibitReason::UnsavedChanges));
    test.app
        .imp()
        .windows
        .get(busy.id())
        .expect("the busy window")
        .set_inhibitor(inhibitor);

    test.app.emit_by_name::<()>("query-end", &[]);

    assert!(busy.is_visible(), "the window holding logout back stayed hidden");
    assert!(!idle.is_visible(), "a window with nothing to lose was brought forward");
    assert_eq!(test.app.present_inhibiting_window(), Some(busy.id()));
}

#[gtk4::test]
fn quit_closes_every_window_through_its_close_flow() {
    let test = TestApp::started("Quit");
    let first = test.window();
    let second = test.window();
    let requests = Rc::new(Cell::new(0));
    for window in [&first, &second] {
        let requests = requests.clone();
        window.connect_close_request(move |_| {
            requests.set(requests.get() + 1);
            glib::Propagation::Proceed
        });
    }

    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Approved);
    assert_eq!(requests.get(), 2, "a window closed without a close request");
    assert!(!first.is_visible() && !second.is_visible());
    assert!(test.app.windows().is_empty());
    assert_eq!(test.app.imp().windows.len(), 0);
    assert_eq!(test.app.imp().quit_asking.get(), None);
}

#[gtk4::test]
fn request_quit_runs_once_and_clears_when_done() {
    let test = TestApp::started("RequestQuit");
    test.window();

    test.app.request_quit();
    assert!(test.app.imp().quit.borrow().is_some());
    wait_until(WAIT, || test.app.imp().quit.borrow().is_none()).expect("the quit to finish");

    assert!(test.app.windows().is_empty());
}

#[gtk4::test]
fn a_second_quit_request_brings_the_asking_window_forward() {
    let test = TestApp::started("QuitAgain");
    let asking = test.window();
    asking.set_visible(false);
    let pending = glib::spawn_future_local(std::future::pending::<CloseDecision>());
    test.app.imp().quit.replace(Some(pending));
    test.app.imp().quit_asking.set(Some(asking.id()));

    test.app.request_quit();

    assert!(asking.is_visible(), "the window the quit waits on stayed hidden");
    assert_eq!(test.app.windows().len(), 1, "a second quit started over");
    if let Some(pending) = test.app.imp().quit.take() {
        pending.abort();
    }
}
