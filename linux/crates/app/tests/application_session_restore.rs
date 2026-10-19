//! The windows open when TablePro quits open again at the next launch,
//! and a window the user closed first does not.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::Duration;

#[path = "support/app_bus.rs"]
mod app_bus;
#[path = "support/settings_schema.rs"]
mod settings_schema;

use app_bus::{activate, object_path, wait_for_exit, wait_until, wait_until_owned, window_ids};

const APP_ID: &str = tablepro_app::config::APP_ID;

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
    let connection = app_bus::connect(address)?;
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
        settings_schema::compile(&sandbox.schemas, &[APP_ID])?;
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
        let sessions: Vec<String> = uris
            .iter()
            .map(|uri| format!(r#"{{"kind":"file","uri":{}}}"#, serde_json::Value::from(*uri)))
            .collect();
        let record = format!(r#"{{"version":1,"sessions":[{}]}}"#, sessions.join(","));
        let path = self.record_path();
        let parent = path.parent().ok_or("the record has no directory")?;
        std::fs::create_dir_all(parent).map_err(|error| format!("could not create {}: {error}", parent.display()))?;
        std::fs::write(&path, record).map_err(|error| format!("could not write the record: {error}"))
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

/// GLib and the XDG base directory specification expect the runtime
/// directory to be private to the user.
fn private(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not make {} private: {error}", path.display()))
}
