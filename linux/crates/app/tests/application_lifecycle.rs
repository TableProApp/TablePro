//! Quitting a running TablePro, in process, over fake connections.
//!
//! Each case runs in a child process of its own: GTK allows one
//! application per process on the main thread, and the application id
//! can be registered on the bus only once at a time.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::cell::Cell;
use std::path::Path;
use std::process::{Command, ExitCode, Stdio};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_app::application::{AppServices, AppServicesParts, TableProApplication, WindowLaunch};
use tablepro_app::runtime::AppRuntime;
use tablepro_app::storage::AppStorage;
use tablepro_core::{AuthMode, DriverRegistry, EditorSession, LivenessPolicy, TlsConfig, TransactionState};
use tablepro_session::fakes::{FakeConnector, FakeEstablish};
use tablepro_session::operation::DefaultDeadlines;
use tablepro_storage::{AppSettings, SavedConnection, StoragePaths};
use tablepro_test_support::{
    CloseBehaviour, ConnectionScript, FakeConnection, FakeDriver, FakeEditorSession, FakeReply, FakeRun,
    FakeSecretVault, Replies,
};

const CASE: &str = "TABLEPRO_LIFECYCLE_CASE";
const CASES: &[&str] = &[
    "quit_waits_for_300ms_close_within_timeout_budget",
    "hanging_close_abandoned_at_close_timeout_and_run_returns",
    "cancelled_close_guard_keeps_app_running",
    "editor_session_close_keeps_app_alive_until_resolved",
];
/// A case that has not finished by now never will.
const CASE_LIMIT: Duration = Duration::from_secs(90);
const STEP_LIMIT: Duration = Duration::from_secs(20);

fn main() -> ExitCode {
    if let Ok(case) = std::env::var(CASE) {
        return child(&case);
    }
    parent()
}

/// A private session bus, so a TablePro the developer has open never
/// answers for the application under test.
fn parent() -> ExitCode {
    let display = Display::current();
    let bus = gio::TestDBus::new(gio::TestDBusFlags::NONE);
    bus.up();
    let mut failed = false;
    for case in CASES {
        match run_case(case, &display) {
            Ok(()) => eprintln!("{case}: ok"),
            Err(message) => {
                eprintln!("{case} failed: {message}");
                failed = true;
            }
        }
    }
    bus.down();
    if failed { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

/// `g_test_dbus_up` unsets `DISPLAY` along with the session bus, so the
/// display is read before and handed to each case.
struct Display(Vec<(&'static str, std::ffi::OsString)>);

impl Display {
    fn current() -> Self {
        Self(
            ["DISPLAY", "WAYLAND_DISPLAY"]
                .into_iter()
                .filter_map(|name| Some((name, std::env::var_os(name)?)))
                .collect(),
        )
    }
}

fn run_case(case: &str, display: &Display) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|error| format!("could not find the test binary: {error}"))?;
    // A file rather than a pipe: nobody reads a pipe while the case runs,
    // and a full one would stop it mid-write.
    let log = tempfile::NamedTempFile::new().map_err(|error| format!("no log file: {error}"))?;
    let stderr = log
        .reopen()
        .map_err(|error| format!("could not open the log file: {error}"))?;
    let mut child = Command::new(exe)
        .envs(display.0.iter().cloned())
        .env(CASE, case)
        .env("LC_ALL", "C.UTF-8")
        .env("GSETTINGS_BACKEND", "memory")
        .env_remove("LANGUAGE")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(stderr)
        .spawn()
        .map_err(|error| format!("could not start the case: {error}"))?;
    let deadline = Instant::now() + CASE_LIMIT + Duration::from_secs(10);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                break;
            }
            Err(error) => return Err(format!("could not wait for the case: {error}")),
        }
    }
    let status = child
        .wait()
        .map_err(|error| format!("could not wait for the case: {error}"))?;
    if status.success() {
        return Ok(());
    }
    let stderr = std::fs::read_to_string(log.path()).unwrap_or_default();
    Err(format!("exited with {status}:\n{stderr}"))
}

/// What a case scripts the fake connection and editor session to do.
struct Plan {
    connection_close: CloseBehaviour,
    close_timeout: Duration,
    editor: Option<EditorPlan>,
}

struct EditorPlan {
    leaves: TransactionState,
    close: CloseBehaviour,
}

fn child(case: &str) -> ExitCode {
    std::thread::spawn(|| {
        std::thread::sleep(CASE_LIMIT);
        eprintln!("the case did not finish within {CASE_LIMIT:?}");
        std::process::exit(2);
    });
    match run_child(case) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn run_child(case: &str) -> Result<(), String> {
    let plan = match case {
        "quit_waits_for_300ms_close_within_timeout_budget" => Plan {
            connection_close: CloseBehaviour::Delay(Duration::from_millis(300)),
            close_timeout: Duration::from_secs(2),
            editor: None,
        },
        "hanging_close_abandoned_at_close_timeout_and_run_returns" => Plan {
            connection_close: CloseBehaviour::Hang,
            close_timeout: Duration::from_millis(200),
            editor: None,
        },
        "cancelled_close_guard_keeps_app_running" => Plan {
            connection_close: CloseBehaviour::Immediate,
            close_timeout: Duration::from_secs(2),
            editor: Some(EditorPlan {
                leaves: TransactionState::InTransaction,
                close: CloseBehaviour::Immediate,
            }),
        },
        "editor_session_close_keeps_app_alive_until_resolved" => Plan {
            connection_close: CloseBehaviour::Immediate,
            close_timeout: Duration::from_secs(2),
            editor: Some(EditorPlan {
                leaves: TransactionState::Idle,
                close: CloseBehaviour::Delay(Duration::from_millis(100)),
            }),
        },
        other => return Err(format!("no case named {other}")),
    };
    let world = World::build(&plan)?;
    let outcome = world.run(case);
    world.runtime.shutdown();
    outcome
}

/// A TablePro over fakes, with what the case reads after it exits.
struct World {
    runtime: AppRuntime,
    app: TableProApplication,
    connector: FakeConnector,
    editor: Option<Arc<FakeEditorSession>>,
    saved: SavedConnection,
    _dir: tempfile::TempDir,
}

impl World {
    fn build(plan: &Plan) -> Result<Self, String> {
        gio::resources_register_include!("tablepro.gresource")
            .map_err(|error| format!("could not register the resources: {error}"))?;
        let dir = tempfile::tempdir().map_err(|error| format!("no temporary directory: {error}"))?;
        let runtime = AppRuntime::build().map_err(|error| format!("no runtime: {error}"))?;
        let settings = Rc::new(settings(dir.path())?);
        let paths = StoragePaths::under(dir.path(), "tablepro", tablepro_app::config::APP_ID);
        let storage = AppStorage::new(paths, Arc::new(FakeSecretVault::new()), &runtime.tasks());

        let mut script = ConnectionScript {
            close: plan.connection_close,
            ..ConnectionScript::default()
        };
        script.probe.always(FakeReply::ok(()));
        script.list_schemas.always(FakeReply::ok(Vec::new()));
        script.list_objects.always(FakeReply::ok(Vec::new()));
        let editor = plan.editor.as_ref().map(|editor| {
            let mut runs = Replies::default();
            runs.always(FakeRun::completed(Vec::new()).leaving(editor.leaves));
            Arc::new(FakeEditorSession::with_close(runs, editor.close))
        });
        if let Some(editor) = &editor {
            let session: Arc<dyn EditorSession> = editor.clone();
            script.open_editor_session.always(FakeReply::ok(session));
        }
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(FakeDriver::connecting(
            &FakeDriver::FILE_CAPABILITIES,
            script.clone(),
        )));
        let connector = FakeConnector::new([]).always(FakeEstablish::Connect(script));
        let liveness = LivenessPolicy {
            close_timeout: plan.close_timeout,
            ..LivenessPolicy::DESKTOP
        };
        let services = AppServices::new(AppServicesParts {
            drivers,
            connector: Arc::new(connector.clone()),
            deadlines: Arc::new(DefaultDeadlines::new(liveness)),
            liveness,
            settings,
            storage,
            tasks: runtime.tasks(),
        });
        let saved = saved_connection(&dir.path().join("fake.db"));
        Ok(Self {
            app: TableProApplication::new(services),
            runtime,
            connector,
            editor,
            saved,
            _dir: dir,
        })
    }

    fn run(&self, case: &str) -> Result<(), String> {
        let steps = Steps::default();
        let saved = self.saved.clone();
        let (connector, editor, recorded) = (self.connector.clone(), self.editor.clone(), steps.clone());
        let case_name = case.to_owned();
        self.app.connect_startup(move |app| {
            let Some(window) = app.open_window(WindowLaunch::Connect(Box::new(saved.clone()))) else {
                fail("the application opened no window");
            };
            let (app, connector, editor, recorded, case) = (
                app.clone(),
                connector.clone(),
                editor.clone(),
                recorded.clone(),
                case_name.clone(),
            );
            glib::spawn_future_local(async move {
                if let Err(message) = script(&case, &app, &window, &connector, editor.as_deref(), &recorded).await {
                    fail(&message);
                }
            });
        });

        let code = self.app.run_with_args(&["tablepro"]);
        let returned = Instant::now();
        if code != glib::ExitCode::SUCCESS {
            return Err(format!("run() returned {code:?}"));
        }
        let quit_at = steps.quit_at.get().ok_or("the case never asked to quit")?;
        let took = returned.duration_since(quit_at);
        let connection = self
            .connector
            .connections()
            .into_iter()
            .next()
            .ok_or("no connection was made")?;
        check(case, &steps, &connection, self.editor.as_deref(), took)
    }
}

fn check(
    case: &str,
    steps: &Steps,
    connection: &FakeConnection,
    editor: Option<&FakeEditorSession>,
    took: Duration,
) -> Result<(), String> {
    match case {
        "quit_waits_for_300ms_close_within_timeout_budget" => {
            expect(connection.close_finished(), "run() returned before the close finished")?;
            expect(
                took >= Duration::from_millis(300),
                &format!("run() returned after {took:?}"),
            )?;
            expect(took < Duration::from_secs(2), &format!("the quit took {took:?}"))
        }
        "hanging_close_abandoned_at_close_timeout_and_run_returns" => {
            expect(connection.is_closed(), "the close never started")?;
            expect(!connection.close_finished(), "a hanging close finished")?;
            expect(
                took >= Duration::from_millis(200),
                &format!("run() returned after {took:?}"),
            )?;
            expect(took < Duration::from_secs(5), &format!("the quit took {took:?}"))
        }
        "cancelled_close_guard_keeps_app_running" => {
            expect(steps.kept_running.get(), "the cancelled quit closed the window")?;
            let editor = editor.ok_or("no editor session")?;
            expect(editor.is_closed(), "the editor session was left open")?;
            expect(connection.close_finished(), "the connection was left open")
        }
        "editor_session_close_keeps_app_alive_until_resolved" => {
            let editor = editor.ok_or("no editor session")?;
            expect(editor.is_closed(), "run() returned before the editor session closed")
        }
        other => Err(format!("no checks for {other}")),
    }
}

/// What the script running inside the application saw.
#[derive(Clone, Default)]
struct Steps {
    quit_at: Rc<Cell<Option<Instant>>>,
    kept_running: Rc<Cell<bool>>,
}

async fn script(
    case: &str,
    app: &TableProApplication,
    window: &adw::ApplicationWindow,
    connector: &FakeConnector,
    editor: Option<&FakeEditorSession>,
    steps: &Steps,
) -> Result<(), String> {
    let services = app.services().ok_or("the application has no services")?;
    until("the session", || services.sessions.live_count() == 1).await?;
    if let Some(editor) = editor {
        run_in_a_new_editor_tab(window, editor).await?;
    }
    steps.quit_at.set(Some(Instant::now()));
    app.activate_action("quit", None);
    if case != "cancelled_close_guard_keeps_app_running" {
        return Ok(());
    }

    answer(window, "Close With Open Transactions?", "cancel").await?;
    glib::timeout_future(Duration::from_millis(500)).await;
    let editor = editor.ok_or("no editor session")?;
    let connection = connector.connections().into_iter().next().ok_or("no connection")?;
    if app.windows().len() != 1 || editor.is_closed() || connection.is_closed() {
        return Err("the quit went on after the close was cancelled".to_owned());
    }
    steps.kept_running.set(true);

    steps.quit_at.set(Some(Instant::now()));
    app.activate_action("quit", None);
    answer(window, "Close With Open Transactions?", "close").await
}

/// Open an editor tab through its window action and run what it holds,
/// which opens the tab's own editor session.
async fn run_in_a_new_editor_tab(window: &adw::ApplicationWindow, editor: &FakeEditorSession) -> Result<(), String> {
    WidgetExt::activate_action(window, "win.open-editor", None).map_err(|error| format!("win.open-editor: {error}"))?;
    let mut run = None;
    until("the editor's Run button", || {
        run = descendants(window.upcast_ref())
            .into_iter()
            .filter(|widget| widget.type_().name() == "TableProSqlEditor")
            .flat_map(|editor| descendants(&editor))
            .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Run"));
        run.is_some()
    })
    .await?;
    let run = run.ok_or("no Run button")?;
    run.emit_clicked();
    until("the run to reach the editor session", || !editor.texts().is_empty()).await?;
    until("the run to end", || run.is_sensitive()).await
}

/// Wait for the alert headed `heading` and click its `response`.
async fn answer(window: &adw::ApplicationWindow, heading: &str, response: &str) -> Result<(), String> {
    let mut shown = None;
    until(heading, || {
        shown = window
            .visible_dialog()
            .and_downcast::<adw::AlertDialog>()
            .filter(|alert| alert.heading().as_deref() == Some(heading));
        shown.is_some()
    })
    .await?;
    let alert = shown.ok_or("no alert")?;
    let label = alert.response_label(response);
    let button = descendants(alert.upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
        .find(|button| button.label().as_deref() == Some(label.as_str()))
        .ok_or_else(|| format!("“{heading}” has no {response} button"))?;
    button.emit_clicked();
    Ok(())
}

async fn until(what: &str, mut ready: impl FnMut() -> bool) -> Result<(), String> {
    let deadline = Instant::now() + STEP_LIMIT;
    while !ready() {
        if Instant::now() >= deadline {
            return Err(format!("timed out waiting for {what}"));
        }
        glib::timeout_future(Duration::from_millis(10)).await;
    }
    Ok(())
}

fn descendants(root: &gtk4::Widget) -> Vec<gtk4::Widget> {
    let mut found = Vec::new();
    let mut pending: Vec<gtk4::Widget> = root.first_child().into_iter().collect();
    while let Some(widget) = pending.pop() {
        pending.extend(widget.next_sibling());
        pending.extend(widget.first_child());
        found.push(widget);
    }
    found
}

fn expect(holds: bool, otherwise: &str) -> Result<(), String> {
    if holds { Ok(()) } else { Err(otherwise.to_owned()) }
}

/// A step that cannot go on leaves the application holding windows and
/// connections, so the case ends here rather than waiting on them.
fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1);
}

fn saved_connection(database: &Path) -> SavedConnection {
    SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: "Fake".to_owned(),
        driver_id: "fake".to_owned(),
        host: String::new(),
        port: 0,
        database: database.display().to_string(),
        username: String::new(),
        tls: TlsConfig::verify_full(),
        read_only: false,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
    }
}

/// The schema compiled into the case's own directory behind a memory
/// backend, so the case never reads or writes the developer's settings.
fn settings(dir: &Path) -> Result<AppSettings, String> {
    let schemas = dir.join("schemas");
    std::fs::create_dir_all(&schemas).map_err(|error| format!("could not create the schema directory: {error}"))?;
    let source = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../data")
        .join("app.tablepro.TablePro.gschema.xml");
    std::fs::copy(&source, schemas.join("app.tablepro.TablePro.gschema.xml"))
        .map_err(|error| format!("could not stage the schema: {error}"))?;
    let output = Command::new("glib-compile-schemas")
        .arg(&schemas)
        .output()
        .map_err(|error| format!("could not run glib-compile-schemas: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "glib-compile-schemas failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    AppSettings::with_backend(
        tablepro_app::config::SCHEMA_ID,
        &schemas,
        &gio::memory_settings_backend_new(),
    )
    .map_err(|error| format!("could not open the settings: {error}"))
}
