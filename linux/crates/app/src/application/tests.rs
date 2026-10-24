use std::cell::Cell;
use std::ops::ControlFlow;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{DriverRegistry, LivenessPolicy};
use tablepro_session::SessionKey;
use tablepro_session::fakes::{FakeConnector, FakeEstablish};
use tablepro_session::operation::DefaultDeadlines;
use tablepro_storage::StoragePaths;
use tablepro_storage::document::{decode_document, encode_document};
use tablepro_test_support::{ConnectionScript, FakeDriver, FakeReply, FakeSecretVault};

use super::*;
use crate::storage::AppStorage;
use crate::test_support::{MemorySettings, finish_on_main, wait_until};
use crate::workspace::{CloseDecision, InhibitReason, InhibitTarget, OpenSessionsRecord, WindowInhibitor};

const WAIT: Duration = Duration::from_secs(10);

/// What fake services need kept alive for as long as the test runs.
struct Backing {
    runtime: Option<crate::runtime::AppRuntime>,
    _settings: MemorySettings,
    dir: tempfile::TempDir,
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
    // Files open through a fake driver, so a restored file connects.
    let mut script = ConnectionScript::default();
    script.probe.always(FakeReply::ok(()));
    script.list_schemas.always(FakeReply::ok(Vec::new()));
    script.list_objects.always(FakeReply::ok(Vec::new()));
    let mut drivers = DriverRegistry::new();
    drivers.register(Arc::new(FakeDriver::connecting(
        &FakeDriver::FILE_CAPABILITIES,
        script.clone(),
    )));
    let services = AppServices::new(AppServicesParts {
        drivers,
        connector: Arc::new(FakeConnector::new([]).always(FakeEstablish::Connect(script))),
        deadlines: Arc::new(DefaultDeadlines::new(liveness)),
        liveness,
        settings: settings.get().clone(),
        storage,
        tasks: runtime.tasks(),
    });
    let backing = Backing {
        runtime: Some(runtime),
        _settings: settings,
        dir,
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
        Self::new_with(name, |services| services)
    }

    fn new_with(name: &str, adjust: impl FnOnce(AppServices) -> AppServices) -> Self {
        let (services, backing) = fake_services();
        let app = TableProApplication::new(adjust(services));
        app.set_application_id(Some(&format!("{}.Test.{name}", crate::config::APP_ID)));
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

    fn services(&self) -> Rc<AppServices> {
        self.app.services().expect("the application's services")
    }

    /// A database file in the test's directory, by the key it opens as.
    fn database(&self, name: &str) -> SessionKey {
        std::fs::write(self._backing.dir.path().join(name), b"").expect("create the database");
        self.file_key(name)
    }

    /// The key a file in the test's directory opens as, whether or not
    /// it is there.
    fn file_key(&self, name: &str) -> SessionKey {
        let dir = std::fs::canonicalize(self._backing.dir.path()).expect("the canonical directory");
        let uri = glib::filename_to_uri(dir.join(name), None).expect("a file URI");
        SessionKey::File(uri.to_string())
    }

    fn record_path(&self) -> std::path::PathBuf {
        self.services()
            .storage
            .paths()
            .workspaces_dir()
            .join(OpenSessionsRecord::FILE_NAME)
    }

    /// Write `keys` as the sessions open at the last quit.
    fn record(&self, keys: &[SessionKey]) {
        let path = self.record_path();
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("the workspaces directory");
        let bytes = encode_document(&OpenSessionsRecord::from_keys(keys)).expect("encode");
        std::fs::write(&path, bytes).expect("write the record");
    }

    /// The sessions recorded on disk, once every write has landed.
    fn recorded(&self) -> Vec<SessionKey> {
        finish_on_main(WAIT, self.services().open_sessions().settled()).expect("the writes to land");
        let path = self.record_path();
        let bytes = std::fs::read(&path).expect("the record");
        decode_document::<OpenSessionsRecord>(&path, &bytes)
            .expect("a record")
            .keys()
    }

    /// The window that claims `key`.
    fn window_for(&self, key: &SessionKey) -> gtk4::ApplicationWindow {
        let id = self
            .services()
            .sessions
            .window_for(key)
            .expect("a window claims the key");
        self.app
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<gtk4::ApplicationWindow>().ok())
            .find(|window| window.id() == id)
            .expect("the window")
    }

    /// A quit polled once before anything else runs, so it finds the
    /// restore where it is now.
    fn quit_now(&self) -> std::pin::Pin<Box<impl Future<Output = CloseDecision> + use<>>> {
        let mut quit = Box::pin(QuitSequence::run(self.app.clone()));
        let polled = quit
            .as_mut()
            .poll(&mut std::task::Context::from_waker(std::task::Waker::noop()));
        assert!(polled.is_pending(), "the quit ended in its first poll");
        quit
    }

    /// Wait for every key to show its workspace in a window of its own.
    fn wait_for_sessions(&self, keys: &[SessionKey]) {
        let services = self.services();
        wait_until(WAIT, || {
            services.sessions.live_count() == keys.len()
                && keys.iter().all(|key| services.sessions.window_for(key).is_some())
        })
        .expect("the restored sessions to connect");
    }
}

impl Drop for TestApp {
    fn drop(&mut self) {
        for window in self.app.windows() {
            window.destroy();
        }
        crate::test_support::drain_main_context();
        if self.app.is_registered() {
            crate::test_support::end_application(&self.app);
        }
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
}

#[gtk4::test]
fn installed_application_accels_match_table() {
    use crate::test_support::shortcut_keys::keystroke;
    let test = TestApp::started("Accels");
    let installed = |action: &str| -> Vec<_> {
        test.app
            .accels_for_action(action)
            .iter()
            .map(|accel| keystroke(accel))
            .collect()
    };

    let application: Vec<_> = ACCELERATORS
        .iter()
        .filter(|entry| entry.scope == AcceleratorScope::Application)
        .collect();
    assert!(application.iter().any(|entry| entry.action == "win.close-current"));
    for entry in application {
        let table: Vec<_> = entry.triggers.iter().map(|accel| keystroke(accel)).collect();
        assert_eq!(installed(entry.action), table, "{}", entry.action);
    }
    let shortcuts: Vec<_> = triggers_for("app.shortcuts")
        .iter()
        .map(|accel| keystroke(accel))
        .collect();
    assert_eq!(shortcuts, [keystroke("<Primary>question")]);
    assert_eq!(installed("app.shortcuts"), shortcuts);
}

#[gtk4::test]
fn activate_opens_one_picker_and_then_presents_it() {
    let test = TestApp::started("Activate");

    test.app.activate();
    test.app.activate();
    wait_until(WAIT, || test.app.windows().len() == 1).expect("the picker");
    test.app.activate();
    let _ = wait_until(Duration::from_millis(300), || test.app.windows().len() > 1);

    assert_eq!(test.app.windows().len(), 1);
    assert_eq!(test.app.imp().windows.len(), 1);
}

#[gtk4::test]
fn activate_restores_the_recorded_sessions_in_order() {
    let test = TestApp::started("Restore");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(&[first.clone(), second.clone()]);

    test.app.activate();
    test.wait_for_sessions(&[first.clone(), second.clone()]);

    let services = test.services();
    let ids = [&first, &second].map(|key| services.sessions.window_for(key).expect("a window"));
    assert!(ids[0] < ids[1], "the windows opened out of the recorded order: {ids:?}");
    assert_eq!(
        test.app.windows().len(),
        2,
        "a picker opened beside the restored windows"
    );
    assert_eq!(services.open_sessions().keys(), [first, second]);
}

#[gtk4::test]
fn activate_restores_nothing_when_restore_session_false() {
    let test = TestApp::started("NoRestore");
    let first = test.database("first.db");
    test.record(std::slice::from_ref(&first));
    test.services()
        .settings
        .set_restore_session(false)
        .expect("turn restoring off");

    test.app.activate();

    assert_eq!(test.app.windows().len(), 1, "the picker did not open at once");
    let _ = wait_until(Duration::from_millis(500), || {
        test.services().sessions.window_for(&first).is_some()
    });
    assert_eq!(
        test.services().sessions.window_for(&first),
        None,
        "a session was restored"
    );
    assert_eq!(test.app.windows().len(), 1);
}

#[gtk4::test]
fn second_activate_does_not_restore_again() {
    let test = TestApp::started("RestoreOnce");
    let first = test.database("first.db");
    test.record(std::slice::from_ref(&first));
    test.app.activate();
    test.wait_for_sessions(std::slice::from_ref(&first));
    for window in test.app.windows() {
        window.destroy();
    }
    assert!(test.recorded().is_empty(), "a closed window's session stayed recorded");
    test.record(std::slice::from_ref(&first));

    test.app.activate();

    assert_eq!(test.app.windows().len(), 1, "the picker did not open at once");
    let _ = wait_until(Duration::from_millis(500), || {
        test.services().sessions.window_for(&first).is_some()
    });
    assert_eq!(
        test.services().sessions.window_for(&first),
        None,
        "the session was restored twice"
    );
}

/// A launch for a file skips activate, and the file's window must not
/// write over the sessions recorded at the last quit.
#[gtk4::test]
fn an_open_before_any_activate_restores_the_record_and_keeps_it() {
    let test = TestApp::started("OpenRestores");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(std::slice::from_ref(&first));
    let SessionKey::File(uri) = &second else {
        unreachable!("a database file opens as a file key");
    };

    test.app.open(&[gio::File::for_uri(uri)], "");
    test.wait_for_sessions(&[first.clone(), second.clone()]);

    assert_eq!(
        test.app.windows().len(),
        2,
        "a picker opened beside the restored and opened windows"
    );
    let mut recorded = test.recorded();
    recorded.sort_by_key(|key| key == &second);
    assert_eq!(recorded, [first, second]);
}

#[gtk4::test]
fn an_activate_while_the_record_loads_opens_nothing_more() {
    let test = TestApp::started("RestoreLoading");
    let first = test.database("first.db");
    test.record(std::slice::from_ref(&first));

    test.app.activate();
    test.app.activate();
    test.wait_for_sessions(std::slice::from_ref(&first));
    let _ = wait_until(Duration::from_millis(300), || test.app.windows().len() > 1);

    assert_eq!(
        test.app.windows().len(),
        1,
        "a picker opened beside the restored window"
    );
}

#[gtk4::test]
fn quit_keeps_keys_window_close_removes() {
    let test = TestApp::started("QuitRecord");
    let (closed, kept) = (test.database("closed.db"), test.database("kept.db"));
    test.record(&[closed.clone(), kept.clone()]);
    test.app.activate();
    test.wait_for_sessions(&[closed.clone(), kept.clone()]);
    let services = test.services();

    test.window_for(&closed).close();
    wait_until(WAIT, || services.sessions.window_for(&closed).is_none()).expect("the window to close");
    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Approved);
    assert!(test.app.windows().is_empty());
    assert_eq!(test.recorded(), [kept]);
}

#[gtk4::test]
fn cancelled_quit_thaws_to_live_keys() {
    let test = TestApp::started("QuitCancelled");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(&[first.clone(), second.clone()]);
    test.app.activate();
    test.wait_for_sessions(&[first.clone(), second.clone()]);
    // Whichever window the quit asks first closes and raises a dialog
    // over the other, which takes that window's close request and so
    // cancels the quit.
    let windows: Vec<adw::ApplicationWindow> = test
        .app
        .windows()
        .into_iter()
        .filter_map(|window| window.downcast::<adw::ApplicationWindow>().ok())
        .collect();
    let [one, other] = windows.as_slice() else {
        panic!("{} windows, not two", windows.len());
    };
    let raised = Rc::new(Cell::new(false));
    for (closing, kept) in [(one, other), (other, one)] {
        let (kept, raised) = (kept.downgrade(), raised.clone());
        closing.connect_close_request(move |_| {
            if let Some(kept) = kept.upgrade()
                && !raised.replace(true)
            {
                adw::AlertDialog::new(Some("Busy"), None).present(Some(&kept));
            }
            glib::Propagation::Proceed
        });
    }

    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Cancelled);
    assert_eq!(test.app.windows().len(), 1);
    let services = test.services();
    let open: Vec<SessionKey> = [first, second]
        .into_iter()
        .filter(|key| services.sessions.window_for(key).is_some())
        .collect();
    assert_eq!(open.len(), 1, "{open:?}");
    assert_eq!(services.open_sessions().keys(), open);
    assert_eq!(test.recorded(), open);
}

#[gtk4::test]
fn an_activate_after_an_approved_quit_restores_its_record() {
    let test = TestApp::started("QuitThenActivate");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(&[first.clone(), second.clone()]);
    test.app.activate();
    test.wait_for_sessions(&[first.clone(), second.clone()]);
    let services = test.services();
    // A session still closing keeps the process up once its window is gone.
    let closing = services.hold().acquire();
    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");
    assert_eq!(decision, CloseDecision::Approved);
    assert!(test.app.windows().is_empty());

    test.app.activate();
    test.wait_for_sessions(&[first.clone(), second.clone()]);

    assert_eq!(
        test.app.windows().len(),
        2,
        "a picker opened beside the restored windows"
    );
    test.window_for(&first).close();
    wait_until(WAIT, || services.sessions.window_for(&first).is_none()).expect("the window to close");
    assert_eq!(
        test.recorded(),
        [second],
        "a window closed after the restore stayed recorded"
    );
    drop(closing);
}

/// A launch that lands while an approved quit writes the record waits
/// for the write, then reopens what it wrote, once.
#[gtk4::test]
fn an_activate_during_the_quit_flush_restores_the_record_once_written() {
    let test = TestApp::started("QuitFlushActivate");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(&[first.clone(), second.clone()]);
    test.app.activate();
    test.wait_for_sessions(&[first.clone(), second.clone()]);
    let services = test.services();
    let closing = services.hold().acquire();
    let decision = Rc::new(std::cell::RefCell::new(None));
    let (app, slot) = (test.app.clone(), decision.clone());
    glib::spawn_future_local(async move {
        slot.replace(Some(QuitSequence::run(app).await));
    });

    let mut activated_during_flush = false;
    wait_until(WAIT, || {
        let flushing =
            decision.borrow().is_none() && test.app.windows().is_empty() && test.app.imp().quit_asking.get().is_none();
        if flushing && !activated_during_flush {
            test.app.activate();
            test.app.activate();
            activated_during_flush = true;
        }
        decision.borrow().is_some()
    })
    .expect("the quit to finish");

    assert!(
        activated_during_flush,
        "the quit ended before a launch could land in its flush"
    );
    assert_eq!(*decision.borrow(), Some(CloseDecision::Approved));
    test.wait_for_sessions(&[first.clone(), second.clone()]);
    let _ = wait_until(Duration::from_millis(300), || test.app.windows().len() > 2);
    assert_eq!(
        test.app.windows().len(),
        2,
        "a picker opened beside the restored windows"
    );
    assert_eq!(services.open_sessions().keys(), [first, second]);
    drop(closing);
}

/// The desktop file's New Window starts TablePro over D-Bus with that
/// action and no activate, and its window must not write over the
/// sessions recorded at the last quit.
#[gtk4::test]
fn a_new_window_before_any_activate_restores_the_record() {
    let test = TestApp::started("NewWindowRestores");
    let first = test.database("first.db");
    test.record(std::slice::from_ref(&first));

    test.app.activate_action("new-window", None);
    test.wait_for_sessions(std::slice::from_ref(&first));

    let _ = wait_until(Duration::from_millis(300), || test.app.windows().len() > 1);
    assert_eq!(
        test.app.windows().len(),
        1,
        "a picker opened beside the restored window"
    );
    assert_eq!(test.recorded(), [first]);
}

/// `--new-window` from a second launch reaches a process an approved
/// quit left running, which has nothing restored yet.
#[gtk4::test]
fn a_new_window_after_an_approved_quit_restores_its_record() {
    let test = TestApp::started("QuitThenNewWindow");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(&[first.clone(), second.clone()]);
    test.app.activate();
    test.wait_for_sessions(&[first.clone(), second.clone()]);
    let services = test.services();
    let closing = services.hold().acquire();
    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");
    assert_eq!(decision, CloseDecision::Approved);

    test.app.activate_action("new-window", None);
    test.wait_for_sessions(&[first.clone(), second.clone()]);

    assert_eq!(
        test.app.windows().len(),
        2,
        "a picker opened beside the restored windows"
    );
    assert_eq!(test.recorded(), [first, second]);
    drop(closing);
}

/// Over D-Bus, a quit can reach a process that nothing launched yet.
#[gtk4::test]
fn a_quit_before_any_launch_keeps_the_record() {
    let test = TestApp::started("QuitBeforeLaunch");
    let first = test.database("first.db");
    test.record(std::slice::from_ref(&first));

    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Approved);
    assert_eq!(test.recorded(), [first]);
}

/// With no window yet, the quit can only come over D-Bus.
#[gtk4::test]
fn a_quit_while_the_record_loads_keeps_it_and_opens_nothing() {
    let test = TestApp::started("QuitWhileLoading");
    let (first, second) = (test.database("first.db"), test.database("second.db"));
    test.record(std::slice::from_ref(&first));
    let SessionKey::File(uri) = &second else {
        unreachable!("a database file opens as a file key");
    };

    test.app.activate();
    test.app.open(&[gio::File::for_uri(uri)], "");
    let decision = finish_on_main(WAIT, test.quit_now()).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Approved);
    let _ = wait_until(Duration::from_millis(500), || !test.app.windows().is_empty());
    assert!(test.app.windows().is_empty(), "a window opened after the quit");
    assert_eq!(test.recorded(), std::slice::from_ref(&first));
    test.app.activate();
    test.wait_for_sessions(std::slice::from_ref(&first));
    let _ = wait_until(Duration::from_millis(300), || test.app.windows().len() > 1);
    assert_eq!(
        test.app.windows().len(),
        1,
        "a file handed over before the quit opened after it"
    );
}

/// The read the quit waited out opens nothing, and the launch restores
/// the record once.
#[gtk4::test]
fn a_launch_during_a_quit_over_the_loading_record_restores_it_once() {
    let test = TestApp::started("QuitLoadingRelaunch");
    let first = test.database("first.db");
    test.record(std::slice::from_ref(&first));
    test.app.activate();
    let quit = test.quit_now();

    test.app.activate();
    let decision = finish_on_main(WAIT, quit).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Approved);
    test.wait_for_sessions(std::slice::from_ref(&first));
    let _ = wait_until(Duration::from_millis(300), || test.app.windows().len() > 1);
    assert_eq!(test.app.windows().len(), 1, "the record was restored twice");
    assert_eq!(test.services().open_sessions().keys(), [first]);
}

#[gtk4::test]
fn a_cancelled_quit_forgets_a_restore_that_failed_during_it() {
    let test = TestApp::started("QuitFailedRestore");
    let gone = test.file_key("gone.db");
    test.record(std::slice::from_ref(&gone));
    let services = test.services();
    // The restore fails while the quit waits on another window.
    services.open_sessions().freeze_for_quit();
    test.app.activate();
    wait_until(WAIT, || services.sessions.window_for(&gone).is_some()).expect("the failed connect's claim");
    // The window's close request dismisses the dialog instead, which
    // cancels the quit.
    adw::AlertDialog::new(Some("Busy"), None).present(Some(&test.window_for(&gone)));

    let decision = finish_on_main(WAIT, QuitSequence::run(test.app.clone())).expect("the quit to finish");

    assert_eq!(decision, CloseDecision::Cancelled);
    assert!(
        services.sessions.window_for(&gone).is_some(),
        "the failed connect's window closed"
    );
    assert!(test.recorded().is_empty(), "the failed restore stayed recorded");
}

#[gtk4::test]
fn a_quit_without_close_requests_keeps_the_sessions_recorded() {
    let test = TestApp::new("ShutdownRecord");
    let open = test.database("open.db");
    test.record(std::slice::from_ref(&open));
    let services = test.services();
    let connected = Rc::new(Cell::new(false));
    let (app, seen, key) = (test.app.downgrade(), connected.clone(), open.clone());
    let deadline = std::time::Instant::now() + WAIT;
    glib::timeout_add_local(Duration::from_millis(20), move || {
        let Some(app) = app.upgrade() else {
            return glib::ControlFlow::Break;
        };
        seen.set(services.sessions.live_count() == 1 && services.sessions.window_for(&key).is_some());
        if seen.get() || std::time::Instant::now() > deadline {
            #[expect(
                clippy::disallowed_methods,
                reason = "GTK quits this way when the session ends, without asking the windows"
            )]
            app.quit();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });

    let code = test.app.run_with_args(&["tablepro"]);

    assert_eq!(code, glib::ExitCode::SUCCESS);
    assert!(connected.get(), "the recorded session never opened");
    assert_eq!(test.recorded(), [open]);
}

#[gtk4::test]
fn new_window_action_opens_another_window() {
    let test = TestApp::started("NewWindow");
    test.app.activate();
    wait_until(WAIT, || test.app.windows().len() == 1).expect("the picker");

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

mod mcp {
    use tablepro_core::{AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
    use tablepro_mcp::{McpHost, OpenOutcome, WriteApproval};
    use tablepro_storage::SavedConnection;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_util::sync::CancellationToken;
    use uuid::Uuid;

    use super::*;
    use crate::services::mcp_service::tests::{MemoryTokens, free_port};

    fn saved_file(test: &TestApp, name: &str, access: ExternalAccess) -> SavedConnection {
        let path = test._backing.dir.path().join(name);
        std::fs::write(&path, b"").expect("create the database");
        let saved = SavedConnection {
            id: Uuid::new_v4(),
            name: "Shop".to_owned(),
            driver_id: "fake".to_owned(),
            host: String::new(),
            port: 0,
            database: path.display().to_string(),
            username: String::new(),
            tls: TlsConfig::disabled(),
            safe_mode: SafeModeLevel::Off,
            external_access: access,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        };
        test.services()
            .storage
            .connections()
            .upsert_blocking(saved.clone())
            .expect("the saved connection");
        saved
    }

    /// Run a host call on the runtime, as the server does, while the main
    /// loop answers it.
    fn on_runtime<T: Send + 'static>(test: &TestApp, call: impl Future<Output = T> + Send + 'static) -> T {
        let running = test.services().tasks.spawn_task(call);
        finish_on_main(WAIT, running)
            .expect("the host to answer")
            .expect("the call's task")
    }

    fn approval(id: Uuid, cancel: CancellationToken) -> WriteApproval {
        WriteApproval {
            connection_id: id,
            connection_name: "Shop".to_owned(),
            sql: "DELETE FROM orders WHERE id = 1".to_owned(),
            destructive: false,
            cancel,
        }
    }

    fn opened(test: &TestApp, host: &Arc<mcp_bridge::GtkMcpHost>, saved: &SavedConnection) -> OpenOutcome {
        let (host, saved) = (host.clone(), saved.clone());
        on_runtime(test, async move { host.open(saved).await })
    }

    #[gtk4::test]
    fn a_client_opens_a_saved_connection_in_one_window_and_finds_its_session() {
        let test = TestApp::started("McpOpen");
        let host = test.app.answer_mcp(&test.services());
        let saved = saved_file(&test, "shop.db", ExternalAccess::ReadOnly);
        let id = saved.id;

        let first = opened(&test, &host, &saved);
        let windows = test.app.windows().len();
        let again = opened(&test, &host, &saved);
        let session = on_runtime(&test, {
            let host = host.clone();
            async move { host.session(id).await }
        });
        let open = on_runtime(&test, {
            let host = host.clone();
            async move { host.open_connections().await }
        });

        assert!(matches!(first, OpenOutcome::Open(_)), "{first:?}");
        assert!(matches!(again, OpenOutcome::Open(_)), "{again:?}");
        assert_eq!(windows, 1);
        assert_eq!(test.app.windows().len(), 1, "a second open made another window");
        assert!(session.is_some());
        assert_eq!(open, [id]);
    }

    #[gtk4::test]
    fn a_failed_connect_answers_closed_at_once_and_keeps_its_window() {
        let test = TestApp::started("McpFailed");
        let host = test.app.answer_mcp(&test.services());
        let saved = SavedConnection {
            driver_id: "missing".to_owned(),
            ..saved_file(&test, "shop.db", ExternalAccess::ReadOnly)
        };
        test.services()
            .storage
            .connections()
            .upsert_blocking(saved.clone())
            .expect("the saved connection");

        let first = opened(&test, &host, &saved);
        let asked_again = std::time::Instant::now();
        let again = opened(&test, &host, &saved);

        assert!(matches!(first, OpenOutcome::Closed), "{first:?}");
        assert!(matches!(again, OpenOutcome::Closed), "{again:?}");
        assert!(
            asked_again.elapsed() < Duration::from_secs(5),
            "the second answer waited for a connect"
        );
        assert!(
            test.services()
                .sessions
                .window_for(&SessionKey::Saved(saved.id))
                .is_some()
        );
        assert_eq!(test.app.windows().len(), 1);
    }

    #[gtk4::test]
    fn a_client_write_is_asked_in_the_connection_window_and_cancel_wins() {
        let test = TestApp::started("McpApprove");
        let host = test.app.answer_mcp(&test.services());
        let saved = saved_file(&test, "shop.db", ExternalAccess::ReadWrite);
        assert!(matches!(opened(&test, &host, &saved), OpenOutcome::Open(_)));
        let window = test.window_for(&SessionKey::Saved(saved.id));
        let ask = |cancel: CancellationToken| {
            let host = host.clone();
            let approval = approval(saved.id, cancel);
            test.services()
                .tasks
                .spawn_task(async move { host.approve(approval).await })
        };

        let approving = ask(CancellationToken::new());
        wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
        assert!(crate::workspace::answer(&window, "proceed"));
        let approved = finish_on_main(WAIT, approving).expect("an answer").expect("the task");

        let declining = ask(CancellationToken::new());
        wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
        assert!(crate::workspace::answer(&window, "cancel"));
        let declined = finish_on_main(WAIT, declining).expect("an answer").expect("the task");

        let gone = CancellationToken::new();
        let abandoned = ask(gone.clone());
        wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
        gone.cancel();
        let unanswered = finish_on_main(WAIT, abandoned).expect("an answer").expect("the task");

        assert!(approved);
        assert!(!declined);
        assert!(!unanswered);
        wait_until(WAIT, || crate::workspace::visible_alert(&window).is_none()).expect("the question to close");
    }

    #[gtk4::test]
    fn a_write_for_a_connection_no_window_has_is_refused_without_asking() {
        let test = TestApp::started("McpNoWindow");
        let host = test.app.answer_mcp(&test.services());

        let approved = on_runtime(&test, async move {
            host.approve(approval(Uuid::new_v4(), CancellationToken::new())).await
        });

        assert!(!approved);
        assert!(test.app.windows().is_empty());
    }

    /// One `tools/call` over HTTP, as a client sends it, answered with the
    /// tool's text.
    #[expect(
        clippy::disallowed_types,
        reason = "the request is written with json!, and its key order means nothing to the server"
    )]
    async fn call_tool(port: u16, token: String, tool: &'static str) -> String {
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": tool, "arguments": {} },
        })
        .to_string();
        let request = format!(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAuthorization: Bearer {token}\r\n\
             Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n\
             MCP-Protocol-Version: 2025-06-18\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("a connection to the server");
        stream.write_all(request.as_bytes()).await.expect("the request");
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).await.expect("the response");
        let text = String::from_utf8(raw).expect("a UTF-8 response");
        let (head, body) = text.split_once("\r\n\r\n").expect("a header block");
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        assert!(
            !head.to_ascii_lowercase().contains("transfer-encoding: chunked"),
            "{head}"
        );
        let message: serde_json::Value = serde_json::from_str(body).expect("a JSON-RPC reply");
        message["result"]["content"][0]["text"]
            .as_str()
            .expect("the tool's text")
            .to_owned()
    }

    #[gtk4::test]
    fn the_running_app_answers_a_client_with_the_connections_it_may_see() {
        let port = free_port();
        let tokens = Arc::new(MemoryTokens::default());
        let vault = tokens.clone();
        let test = TestApp::new_with("McpServe", move |services| {
            services.settings.set_mcp_server_port(port).expect("the port");
            services.settings.set_mcp_server_enabled(true).expect("the switch");
            services.with_mcp_tokens(vault)
        });
        test.app
            .register(gio::Cancellable::NONE)
            .expect("register the application");
        let readable = saved_file(&test, "shop.db", ExternalAccess::ReadOnly);
        let blocked = saved_file(&test, "hidden.db", ExternalAccess::Blocked);
        let service = test.services().mcp().expect("the server's service");
        wait_until(WAIT, || service.status().borrow().port() == Some(port)).expect("the server to run");
        let token = tokens.0.lock().expect("tokens").clone().expect("a stored token");

        let listed = on_runtime(&test, call_tool(port, token, "list_connections"));

        let listed: serde_json::Value = serde_json::from_str(&listed).expect("a JSON answer");
        let ids: Vec<&str> = listed["connections"]
            .as_array()
            .expect("connections")
            .iter()
            .filter_map(|connection| connection["id"].as_str())
            .collect();
        assert_eq!(ids, [readable.id.to_string()]);
        assert_ne!(ids[0], blocked.id.to_string());
        assert_eq!(listed["connections"][0]["is_open"], false);
    }
}
