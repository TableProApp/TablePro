//! A database file handed over D-Bus, the way Files' Open With does,
//! starts TablePro and opens a window on it. The same file again brings
//! that window forward; another file opens a second window.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

use gio::prelude::*;

const APP_ID: &str = tablepro_app::config::APP_ID;
/// Long enough for a cold start under a loaded CI runner.
const WAIT: Duration = Duration::from_secs(30);
/// The first Open waits for D-Bus to start the service.
const CALL_TIMEOUT_MS: i32 = 30_000;

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
    let root = tempfile::Builder::new()
        .prefix("open-files-")
        .tempdir_in(env!("CARGO_TARGET_TMPDIR"))
        .map_err(|error| format!("no temporary directory: {error}"))?;
    let sandbox = Sandbox::new(root.path())?;
    let bus = gio::TestDBus::new(gio::TestDBusFlags::NONE);
    bus.add_service_dir(&sandbox.services.to_string_lossy());
    bus.up();
    let outcome = bus
        .bus_address()
        .ok_or_else(|| "the test bus has no address".to_owned())
        .and_then(|address| opens(&sandbox, &address));
    bus.down();
    outcome
}

fn opens(sandbox: &Sandbox, address: &str) -> Result<(), String> {
    let connection = gio::DBusConnection::for_address_sync(
        address,
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        gio::Cancellable::NONE,
    )
    .map_err(|error| format!("could not connect to the test bus: {error}"))?;
    let first = sandbox.database("first.sqlite3")?;
    let second = sandbox.database("second.sqlite3")?;

    let outcome = open_twice_then_another(&connection, &first, &second);
    if name_has_owner(&connection) {
        let quitting = quit(&connection)
            .and_then(|()| wait_until("TablePro to exit after app.quit", || !name_has_owner(&connection)));
        if let (Ok(()), Err(message)) = (&outcome, quitting) {
            return Err(message);
        }
    }
    outcome
}

fn open_twice_then_another(connection: &gio::DBusConnection, first: &str, second: &str) -> Result<(), String> {
    open(connection, first)?;
    wait_until("a window on the first file", || window_ids(connection).len() == 1)?;
    let window = window_ids(connection)
        .first()
        .copied()
        .ok_or_else(|| "the first window went away".to_owned())?;
    // Until the window shows the file's workspace it has not claimed the
    // file, and a second Open could not find it.
    wait_until("the first file's workspace", || shows_workspace(connection, window))?;

    open(connection, first)?;
    std::thread::sleep(Duration::from_millis(500));
    let windows = window_ids(connection).len();
    if windows != 1 {
        return Err(format!("{windows} windows after opening the same file twice"));
    }

    open(connection, second)?;
    wait_until("a window on the second file", || window_ids(connection).len() == 2)
}

/// What Files sends for Open With on a D-Bus activatable application.
fn open(connection: &gio::DBusConnection, uri: &str) -> Result<(), String> {
    let platform_data: HashMap<String, glib::Variant> = HashMap::new();
    let arguments = (vec![uri.to_owned()], platform_data).to_variant();
    connection
        .call_sync(
            Some(APP_ID),
            &object_path(),
            "org.freedesktop.Application",
            "Open",
            Some(&arguments),
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .map(drop)
        .map_err(|error| format!("Open({uri}) over D-Bus failed: {error}"))
}

/// Ask TablePro to quit the way the Quit menu item does.
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
            gio::DBusCallFlags::NO_AUTO_START,
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
fn window_ids(connection: &gio::DBusConnection) -> Vec<u32> {
    let xml = connection
        .call_sync(
            Some(APP_ID),
            &format!("{}/window", object_path()),
            "org.freedesktop.DBus.Introspectable",
            "Introspect",
            None,
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.get::<(String,)>())
        .map(|(xml,)| xml)
        .unwrap_or_default();
    xml.split("<node name=\"")
        .skip(1)
        .filter_map(|rest| rest.split('"').next()?.parse().ok())
        .collect()
}

/// Disconnect is enabled only while a window shows a workspace.
fn shows_workspace(connection: &gio::DBusConnection, window: u32) -> bool {
    connection
        .call_sync(
            Some(APP_ID),
            &format!("{}/window/{window}", object_path()),
            "org.gtk.Actions",
            "Describe",
            Some(&("disconnect",).to_variant()),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.child_value(0).child_value(0).get::<bool>())
        .unwrap_or(false)
}

/// GApplication's object path: the id with dots as slashes, as GTK's
/// window paths `<object path>/window/<id>` build on.
fn object_path() -> String {
    format!("/{}", APP_ID.replace('.', "/").replace('-', "_"))
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

/// Directories of the test's own, so the started TablePro reads and
/// writes nothing of the developer's.
struct Sandbox {
    root: PathBuf,
    services: PathBuf,
}

impl Sandbox {
    fn new(root: &Path) -> Result<Self, String> {
        let dir = |name: &str| -> Result<PathBuf, String> {
            let path = root.join(name);
            std::fs::create_dir_all(&path).map_err(|error| format!("could not create {}: {error}", path.display()))?;
            Ok(path)
        };
        let schemas = dir("schemas")?;
        let runtime = dir("runtime")?;
        private(&runtime)?;
        compile_schema(&schemas)?;
        let mut environment = vec![
            ("LC_ALL".to_owned(), PathBuf::from("C.UTF-8")),
            ("GSETTINGS_BACKEND".to_owned(), PathBuf::from("memory")),
            ("GSETTINGS_SCHEMA_DIR".to_owned(), schemas),
            ("XDG_CONFIG_HOME".to_owned(), dir("config")?),
            ("XDG_DATA_HOME".to_owned(), dir("data")?),
            ("XDG_STATE_HOME".to_owned(), dir("state")?),
            ("XDG_CACHE_HOME".to_owned(), dir("cache")?),
            ("XDG_RUNTIME_DIR".to_owned(), runtime),
        ];
        // GTestDBus clears DISPLAY once it is up, so the display goes
        // into the service's own environment.
        for name in ["DISPLAY", "WAYLAND_DISPLAY"] {
            if let Some(value) = std::env::var_os(name) {
                environment.push((name.to_owned(), PathBuf::from(value)));
            }
        }
        let services = dir("services")?;
        write_service(&services, &environment)?;
        Ok(Self {
            root: root.to_path_buf(),
            services,
        })
    }

    /// An empty file, which SQLite reads as an empty database, by URI.
    fn database(&self, name: &str) -> Result<String, String> {
        let path = self.root.join(name);
        std::fs::write(&path, b"").map_err(|error| format!("could not create {}: {error}", path.display()))?;
        Ok(gio::File::for_path(&path).uri().to_string())
    }
}

/// The D-Bus service file that starts this build's binary, with the
/// sandbox set in its Exec line rather than in this process.
fn write_service(dir: &Path, environment: &[(String, PathBuf)]) -> Result<(), String> {
    let mut exec = vec!["/usr/bin/env".to_owned()];
    for (name, value) in environment {
        exec.push(quoted(&format!("{name}={}", value.display()))?);
    }
    exec.push(quoted(env!("CARGO_BIN_EXE_tablepro"))?);
    exec.push("--gapplication-service".to_owned());
    let service = format!("[D-BUS Service]\nName={APP_ID}\nExec={}\n", exec.join(" "));
    let path = dir.join(format!("{APP_ID}.service"));
    std::fs::write(&path, service).map_err(|error| format!("could not write {}: {error}", path.display()))
}

/// dbus-daemon splits Exec the way a shell does.
fn quoted(word: &str) -> Result<String, String> {
    if word.contains('\'') {
        return Err(format!("cannot quote {word} for a D-Bus service file"));
    }
    Ok(format!("'{word}'"))
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
