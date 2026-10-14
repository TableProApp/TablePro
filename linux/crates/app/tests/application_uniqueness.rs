//! One TablePro per session: a second launch hands its command line to
//! the running one over D-Bus and exits.

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
    // A file rather than a pipe: nobody reads a pipe while the primary
    // runs, and a full one would stop it mid-write.
    let log_path = sandbox.root().join("primary.log");
    let log = std::fs::File::create(&log_path).map_err(|error| format!("could not create the log: {error}"))?;
    let mut primary = sandbox
        .tablepro(address, &[])
        .stdout(Stdio::null())
        .stderr(log)
        .spawn()
        .map_err(|error| format!("could not start the primary: {error}"))?;

    let outcome = with_primary(sandbox, address, &connection);
    if outcome.is_ok() {
        quit(&connection)?;
        let status = wait_for_exit(&mut primary)?;
        if !status.success() {
            return Err(format!("the primary exited with {status} after app.quit"));
        }
        return Ok(());
    }
    let _ = primary.kill();
    let _ = primary.wait();
    let log = std::fs::read_to_string(&log_path).unwrap_or_default();
    outcome.map_err(|message| format!("{message}\nprimary stderr:\n{log}"))
}

fn with_primary(sandbox: &Sandbox, address: &str, connection: &gio::DBusConnection) -> Result<(), String> {
    wait_until("the primary to own its name", || name_has_owner(connection))?;
    wait_until("the primary's first window", || window_count(connection) == 1)?;

    let plain = launch(sandbox, address, &[])?;
    if !plain.success() {
        return Err(format!("a second plain launch exited with {plain}"));
    }
    let new_window = launch(sandbox, address, &["--new-window"])?;
    if !new_window.success() {
        return Err(format!("a launch with --new-window exited with {new_window}"));
    }

    wait_until("the second window", || window_count(connection) >= 2)?;
    // The plain launch's activation reached the primary first, so a
    // window it opened by mistake would be here by now.
    std::thread::sleep(Duration::from_millis(500));
    let windows = window_count(connection);
    if windows != 2 {
        return Err(format!("{windows} windows after one plain launch and one --new-window"));
    }
    Ok(())
}

/// Ask the primary to quit the way the Quit menu item does.
fn quit(connection: &gio::DBusConnection) -> Result<(), String> {
    let no_parameter: Vec<glib::Variant> = Vec::new();
    let platform_data: HashMap<String, glib::Variant> = HashMap::new();
    let arguments = ("quit", no_parameter, platform_data).to_variant();
    connection
        .call_sync(
            Some(APP_ID),
            &object_path(),
            "org.gtk.Actions",
            "Activate",
            Some(&arguments),
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .map(drop)
        .map_err(|error| format!("app.quit over D-Bus failed: {error}"))
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
fn window_count(connection: &gio::DBusConnection) -> usize {
    connection
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
        .map_or(0, |(xml,)| xml.matches("<node name=").count())
}

/// GApplication's object path: the id with dots as slashes.
fn object_path() -> String {
    format!("/{}", APP_ID.replace('.', "/").replace('-', "_"))
}

fn launch(sandbox: &Sandbox, address: &str, arguments: &[&str]) -> Result<ExitStatus, String> {
    let mut child = sandbox
        .tablepro(address, arguments)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("could not launch tablepro {arguments:?}: {error}"))?;
    wait_for_exit(&mut child)
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

    fn root(&self) -> &Path {
        self.root.path()
    }

    fn tablepro(&self, address: &str, arguments: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_tablepro"));
        command
            .args(arguments)
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
