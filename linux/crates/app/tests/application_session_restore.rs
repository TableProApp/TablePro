//! The windows open when TablePro quits open again at the next launch,
//! and a window the user closed first does not.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use gio::prelude::*;

const APP_ID: &str = tablepro_app::config::APP_ID;
/// Long enough for a cold start under a loaded CI runner.
const WAIT: Duration = Duration::from_secs(30);
const CALL_TIMEOUT_MS: i32 = 5_000;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut sandbox = Sandbox::new()?;
    // g_test_dbus_up unsets DISPLAY along with the session bus.
    sandbox.display = ["DISPLAY", "WAYLAND_DISPLAY"]
        .into_iter()
        .filter_map(|name| Some((name, std::env::var_os(name)?)))
        .collect();
    let bus = gio::TestDBus::new(gio::TestDBusFlags::NONE);
    bus.up();
    let outcome = bus
        .bus_address()
        .ok_or_else(|| "the test bus has no address".to_owned())
        .and_then(|address| launches(&sandbox, &address));
    bus.down();
    outcome
}

fn launches(sandbox: &Sandbox, address: &str) -> Result<(), String> {
    let connection = gio::DBusConnection::for_address_sync(
        address,
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        gio::Cancellable::NONE,
    )
    .map_err(|error| format!("could not connect to the test bus: {error}"))?;
    let first = sandbox.database("first.db")?;
    let second = sandbox.database("second.db")?;
    sandbox.record(&[first.as_str(), second.as_str()])?;

    sandbox.launch(address, "first", || {
        wait_until("both recorded windows", || window_ids(&connection).len() == 2)?;
        quit(&connection)
    })?;
    let recorded = sandbox.recorded()?;
    if recorded != [first.clone(), second.clone()] {
        return Err(format!("the quit left {recorded:?} recorded"));
    }

    sandbox.launch(address, "second", || {
        wait_until("both windows again", || window_ids(&connection).len() == 2)?;
        close_one_window(&connection)?;
        quit(&connection)
    })?;
    let recorded = sandbox.recorded()?;
    if recorded.len() != 1 {
        return Err(format!("closing a window before the quit left {recorded:?} recorded"));
    }

    sandbox.launch(address, "third", || {
        wait_until("the one window left", || window_ids(&connection).len() == 1)?;
        // The other window would open with it, so it would be here by now.
        std::thread::sleep(Duration::from_millis(500));
        let windows = window_ids(&connection).len();
        if windows != 1 {
            return Err(format!("{windows} windows after one was closed before the quit"));
        }
        quit(&connection)
    })
}

/// `win.close-current` closes the active tab, and the window once it
/// has none, as Ctrl+W does.
fn close_one_window(connection: &gio::DBusConnection) -> Result<(), String> {
    let ids = window_ids(connection);
    let id = ids.first().ok_or("no window to close")?;
    let path = format!("{}/window/{id}", object_path());
    for _ in 0..5 {
        activate(connection, &path, "close-current")?;
        let closed = wait_until("the window to close", || window_ids(connection).len() < ids.len());
        if closed.is_ok() {
            return Ok(());
        }
    }
    Err("close-current never closed the window".to_owned())
}

/// Ask the primary to quit the way the Quit menu item does.
fn quit(connection: &gio::DBusConnection) -> Result<(), String> {
    activate(connection, &object_path(), "quit")
}

fn activate(connection: &gio::DBusConnection, path: &str, action: &str) -> Result<(), String> {
    let no_parameter: Vec<glib::Variant> = Vec::new();
    let platform_data: HashMap<String, glib::Variant> = HashMap::new();
    let arguments = (action, no_parameter, platform_data).to_variant();
    connection
        .call_sync(
            Some(APP_ID),
            path,
            "org.gtk.Actions",
            "Activate",
            Some(&arguments),
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .map(drop)
        .map_err(|error| format!("{action} at {path} over D-Bus failed: {error}"))
}

fn name_has_owner(connection: &gio::DBusConnection) -> bool {
    connection
        .call_sync(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            Some(&(APP_ID,).to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.get::<(bool,)>())
        .is_some_and(|(owned,)| owned)
}

/// GtkApplication exports each window's actions at
/// `<object path>/window/<id>`, so the children of that node are the
/// open windows.
fn window_ids(connection: &gio::DBusConnection) -> Vec<String> {
    let Some((xml,)) = connection
        .call_sync(
            Some(APP_ID),
            &format!("{}/window", object_path()),
            "org.freedesktop.DBus.Introspectable",
            "Introspect",
            None,
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.get::<(String,)>())
    else {
        return Vec::new();
    };
    xml.split("<node name=\"")
        .skip(1)
        .filter_map(|rest| rest.split('"').next())
        .map(str::to_owned)
        .collect()
}

/// GApplication's object path: the id with dots as slashes.
fn object_path() -> String {
    format!("/{}", APP_ID.replace('.', "/").replace('-', "_"))
}

fn wait_for_exit(child: &mut Child) -> Result<ExitStatus, String> {
    let deadline = Instant::now() + WAIT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("tablepro did not exit within {WAIT:?}"));
            }
            Err(error) => return Err(format!("could not wait for tablepro: {error}")),
        }
    }
}

fn wait_until(what: &str, mut ready: impl FnMut() -> bool) -> Result<(), String> {
    let deadline = Instant::now() + WAIT;
    while !ready() {
        if Instant::now() >= deadline {
            return Err(format!("timed out waiting for {what}"));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

/// Directories of the test's own, so every launch reads and writes
/// nothing of the developer's.
struct Sandbox {
    root: tempfile::TempDir,
    schemas: PathBuf,
    config: PathBuf,
    data: PathBuf,
    state: PathBuf,
    cache: PathBuf,
    runtime: PathBuf,
    display: Vec<(&'static str, std::ffi::OsString)>,
}

impl Sandbox {
    fn new() -> Result<Self, String> {
        let root = tempfile::tempdir().map_err(|error| format!("no temporary directory: {error}"))?;
        let dir = |name: &str| -> Result<PathBuf, String> {
            let path = root.path().join(name);
            std::fs::create_dir_all(&path).map_err(|error| format!("could not create {}: {error}", path.display()))?;
            Ok(path)
        };
        let sandbox = Self {
            schemas: dir("schemas")?,
            config: dir("config")?,
            data: dir("data")?,
            state: dir("state")?,
            cache: dir("cache")?,
            runtime: dir("runtime")?,
            display: Vec::new(),
            root,
        };
        private(&sandbox.runtime)?;
        compile_schema(&sandbox.schemas)?;
        Ok(sandbox)
    }

    /// An empty SQLite database, by the URI the application keys it by.
    fn database(&self, name: &str) -> Result<String, String> {
        let dir = std::fs::canonicalize(self.root.path())
            .map_err(|error| format!("could not resolve the sandbox: {error}"))?;
        let path = dir.join(name);
        std::fs::write(&path, b"").map_err(|error| format!("could not create {name}: {error}"))?;
        glib::filename_to_uri(&path, None)
            .map(|uri| uri.to_string())
            .map_err(|error| format!("no URI for {name}: {error}"))
    }

    fn record_path(&self) -> PathBuf {
        self.state
            .join(tablepro_app::config::storage_dir_name())
            .join("workspaces")
            .join("open-sessions.json")
    }

    /// Write the files as the sessions open at the last quit.
    fn record(&self, uris: &[&str]) -> Result<(), String> {
        let sessions: Vec<serde_json::Value> = uris
            .iter()
            .map(|uri| serde_json::json!({ "kind": "file", "uri": uri }))
            .collect();
        let record = serde_json::json!({ "version": 1, "sessions": sessions });
        let path = self.record_path();
        let parent = path.parent().ok_or("the record has no directory")?;
        std::fs::create_dir_all(parent).map_err(|error| format!("could not create {}: {error}", parent.display()))?;
        std::fs::write(&path, record.to_string()).map_err(|error| format!("could not write the record: {error}"))
    }

    /// The file URIs recorded, in order.
    fn recorded(&self) -> Result<Vec<String>, String> {
        let bytes = std::fs::read(self.record_path()).map_err(|error| format!("no record after the quit: {error}"))?;
        let record: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|error| format!("the record is not JSON: {error}"))?;
        let sessions = record["sessions"]
            .as_array()
            .ok_or_else(|| format!("the record lists no sessions: {record}"))?;
        sessions
            .iter()
            .map(|session| {
                session["uri"]
                    .as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| format!("a recorded session is not a file: {session}"))
            })
            .collect()
    }

    /// Start TablePro, run `steps` against it, and wait for it to exit
    /// with success.
    fn launch(&self, address: &str, name: &str, steps: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
        // A file rather than a pipe: nobody reads a pipe while the app
        // runs, and a full one would stop it mid-write.
        let log_path = self.root.path().join(format!("{name}.log"));
        let log = std::fs::File::create(&log_path).map_err(|error| format!("could not create the log: {error}"))?;
        let mut child = self
            .tablepro(address)
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .map_err(|error| format!("could not start the {name} launch: {error}"))?;
        let outcome = wait_until_owned(address)
            .and_then(|()| steps())
            .and_then(|()| wait_for_exit(&mut child))
            .and_then(|status| {
                if status.success() {
                    Ok(())
                } else {
                    Err(format!("the {name} launch exited with {status}"))
                }
            });
        if outcome.is_err() {
            let _ = child.kill();
            let _ = child.wait();
        }
        outcome.map_err(|message| {
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            format!("{message}\n{name} launch stderr:\n{log}")
        })
    }

    fn tablepro(&self, address: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_tablepro"));
        command
            .envs(self.display.iter().cloned())
            .env("DBUS_SESSION_BUS_ADDRESS", address)
            .env("LC_ALL", "C.UTF-8")
            .env("GSETTINGS_BACKEND", "memory")
            .env("GSETTINGS_SCHEMA_DIR", &self.schemas)
            .env("XDG_CONFIG_HOME", &self.config)
            .env("XDG_DATA_HOME", &self.data)
            .env("XDG_STATE_HOME", &self.state)
            .env("XDG_CACHE_HOME", &self.cache)
            .env("XDG_RUNTIME_DIR", &self.runtime)
            .env_remove("LANGUAGE")
            .stdin(Stdio::null());
        command
    }
}

fn wait_until_owned(address: &str) -> Result<(), String> {
    let connection = gio::DBusConnection::for_address_sync(
        address,
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        gio::Cancellable::NONE,
    )
    .map_err(|error| format!("could not connect to the test bus: {error}"))?;
    wait_until("the application to own its name", || name_has_owner(&connection))
}

/// GLib and the XDG base directory specification expect the runtime
/// directory to be private to the user.
fn private(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not make {} private: {error}", path.display()))
}

fn compile_schema(dir: &Path) -> Result<(), String> {
    let source = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../data")
        .join("app.tablepro.TablePro.gschema.xml");
    std::fs::copy(&source, dir.join("app.tablepro.TablePro.gschema.xml"))
        .map_err(|error| format!("could not stage the schema: {error}"))?;
    let output = Command::new("glib-compile-schemas")
        .arg(dir)
        .output()
        .map_err(|error| format!("could not run glib-compile-schemas: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "glib-compile-schemas failed: {}",
        String::from_utf8_lossy(&output.stderr)
    ))
}
