//! TablePro killed with SIGKILL halfway through a grid save to a SQLite
//! file, then started again.
//!
//! The app runs in a child of this binary through `tablepro_app::run`, as
//! `tablepro <file>` starts it, so the process killed is the one that owns
//! the session and writes the file. A trigger keeps the save's second
//! UPDATE running, so the kill lands after the first one. The fresh start
//! is the `tablepro` binary.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use libadwaita::prelude::{AdwApplicationWindowExt, AlertDialogExt};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverError,
    FileEndpoint, ForeignKeyMode, RowLimit, Value, WorkspaceSettings, WriteBatch, WriteKind,
};
use tablepro_driver_sqlite::SqliteDriver;
use tablepro_test_support::conformance::test_liveness;
use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;

#[path = "support/app_bus.rs"]
mod app_bus;
#[path = "support/settings_schema.rs"]
mod settings_schema;

use app_bus::{WAIT, object_path, wait_for_exit, wait_until, wait_until_owned};

const APP_ID: &str = tablepro_app::config::APP_ID;
/// Names the marker directory, and makes the process the app.
const MARKERS: &str = "TABLEPRO_KILL_DURING_SAVE_MARKERS";
/// Written by the test once the first save is on disk everywhere.
const GO: &str = "go";
const PAGE_SIZE: u32 = 500;
const SIGKILL: i32 = 9;
const BEFORE: [&str; 3] = ["apple", "banana", "cherry"];
const FIRST_SAVE: [&str; 3] = ["apricot", "banana", "cherry"];

fn main() -> ExitCode {
    if let Some(markers) = std::env::var_os(MARKERS) {
        return app(PathBuf::from(markers));
    }
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

/// TablePro as `tablepro <file>` runs it, with a script on its main loop
/// that edits the grid and saves twice. Only the kill ends it.
fn app(markers: PathBuf) -> ExitCode {
    glib::spawn_future_local(async move {
        if let Err(message) = edit_and_save(&markers).await {
            eprintln!("{message}");
            std::process::exit(1);
        }
    });
    match tablepro_app::run() {
        Ok(code) => code.into(),
        Err(error) => {
            eprintln!("TablePro did not start: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn edit_and_save(markers: &Path) -> Result<(), String> {
    gio::Settings::new(APP_ID)
        .set_uint("default-page-size", PAGE_SIZE)
        .map_err(|error| format!("could not change a preference: {error}"))?;
    let window = until("a window", first_window).await?;
    let (list, position) = until("the items table in the sidebar", || table_row(&window, "items")).await?;
    list.emit_by_name::<()>("activate", &[&position]);
    edit_cell(&window, "apple", "apricot").await?;
    click_save(&window).await?;
    until("the first save to settle", || settled(&window, "apricot").then_some(())).await?;
    until("the go-ahead for the second save", || {
        markers.join(GO).exists().then_some(())
    })
    .await?;
    edit_cell(&window, "banana", "blueberry").await?;
    edit_cell(&window, "cherry", "cranberry").await?;
    click_save(&window).await?;
    // A save that fails before the kill says why in an alert.
    let alert = until("an alert", || {
        window
            .downcast_ref::<libadwaita::ApplicationWindow>()
            .and_then(AdwApplicationWindowExt::visible_dialog)
            .and_downcast::<libadwaita::AlertDialog>()
    })
    .await;
    match alert {
        Ok(alert) => Err(format!("{}: {}", alert.heading().unwrap_or_default(), alert.body())),
        Err(_) => Ok(()),
    }
}

fn runtime() -> Result<Runtime, String> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|error| format!("no runtime: {error}"))
}

fn first_window() -> Option<gtk4::Widget> {
    let app = gio::Application::default().and_downcast::<gtk4::Application>()?;
    app.windows().into_iter().next().map(Cast::upcast)
}

/// The sidebar's row for `name`, which opens its table when activated.
fn table_row(window: &gtk4::Widget, name: &str) -> Option<(gtk4::ListView, u32)> {
    descendants(window)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::ListView>().ok())
        .find_map(|list| {
            let model = list.model()?;
            let position = (0..model.n_items()).find(|&position| {
                model.item(position).is_some_and(|item| {
                    item.find_property("name").is_some()
                        && item.property_value("name").get::<String>().ok().as_deref() == Some(name)
                })
            })?;
            Some((list, position))
        })
}

/// Edit a cell the way Return on the focused cell, typing and Enter do.
async fn edit_cell(window: &gtk4::Widget, from: &str, to: &str) -> Result<(), String> {
    let cell = until(&format!("the cell showing {from}"), || cell_showing(window, from)).await?;
    // The column view's own cell widget around ours is what takes focus.
    let focusable = cell
        .parent()
        .ok_or_else(|| format!("the cell showing {from} is in no grid"))?;
    if !focusable.grab_focus() {
        return Err(format!("the cell showing {from} takes no focus"));
    }
    cell.activate_action("grid.edit", None)
        .map_err(|error| format!("grid.edit: {error}"))?;
    let field = until("the cell's editor", || first_of::<gtk4::Text>(&cell)).await?;
    field.set_text(to);
    field.emit_by_name::<()>("activate", &[]);
    until(&format!("the cell showing {to}"), || cell_showing(window, to))
        .await
        .map(drop)
}

fn cell_showing(root: &gtk4::Widget, text: &str) -> Option<gtk4::Widget> {
    descendants(root)
        .into_iter()
        .filter(|widget| widget.type_().name() == "TableProGridCell")
        .find(|cell| {
            descendants(cell)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk4::Inscription>().ok())
                .any(|display| display.is_visible() && display.text().as_deref() == Some(text))
        })
}

/// The bar a browse tab shows while it holds unsaved edits.
fn pending_bar(window: &gtk4::Widget) -> Option<gtk4::Widget> {
    descendants(window)
        .into_iter()
        .find(|widget| widget.type_().name() == "TableProPendingChangesBar")
}

async fn click_save(window: &gtk4::Widget) -> Result<(), String> {
    let save = until("the Save button", || {
        pending_bar(window)
            .into_iter()
            .flat_map(|bar| descendants(&bar))
            .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Save") && button.is_sensitive())
    })
    .await?;
    save.emit_clicked();
    Ok(())
}

/// The cell shows `text` and the bar of unsaved edits has gone.
fn settled(window: &gtk4::Widget, text: &str) -> bool {
    cell_showing(window, text).is_some()
        && pending_bar(window)
            .and_then(|bar| first_of::<gtk4::Revealer>(&bar))
            .is_some_and(|revealer| !revealer.reveals_child())
}

async fn until<T>(what: &str, mut probe: impl FnMut() -> Option<T>) -> Result<T, String> {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(found) = probe() {
            return Ok(found);
        }
        if Instant::now() >= deadline {
            return Err(format!("timed out waiting for {what}"));
        }
        glib::timeout_future(Duration::from_millis(20)).await;
    }
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

fn first_of<T: IsA<gtk4::Widget>>(root: &gtk4::Widget) -> Option<T> {
    descendants(root)
        .into_iter()
        .find_map(|widget| widget.downcast::<T>().ok())
}

fn run() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let runtime = runtime()?;
    runtime.block_on(create_items(&sandbox.database))?;
    let bus = gio::TestDBus::new(gio::TestDBusFlags::NONE);
    bus.up();
    let outcome = bus
        .bus_address()
        .ok_or_else(|| "the test bus has no address".to_owned())
        .and_then(|address| kill_during_save(&sandbox, &runtime, &address));
    bus.down();
    outcome
}

fn kill_during_save(sandbox: &Sandbox, runtime: &Runtime, address: &str) -> Result<(), String> {
    let bus = app_bus::connect(address)?;
    let mut app = AppProcess::start(sandbox, address)?;
    let probe = runtime.block_on(open(&sandbox.database))?;
    app.wait_until("the first save to commit", || {
        runtime
            .block_on(names(probe.as_ref()))
            .is_ok_and(|names| names == FIRST_SAVE)
    })?;
    runtime.block_on(close(probe.as_ref()))?;
    app.wait_until("the first save in the history", || {
        runtime
            .block_on(saved_history(&sandbox.history()))
            .is_ok_and(|saves| saves.len() == 1)
    })?;
    app.wait_until("the items tab in the saved tabs", || {
        workspaces(sandbox).is_ok_and(|workspaces| keeps_items_tab(&workspaces))
    })?;
    std::fs::write(sandbox.markers.join(GO), b"").map_err(|error| format!("could not write the go-ahead: {error}"))?;
    // The journal lives as long as the transaction. A save that committed
    // each UPDATE on its own would have none while the second one runs.
    app.wait_until("the second save to be in flight", || sandbox.journal().exists())?;
    let status = app.kill()?;
    if status.signal() != Some(SIGKILL) {
        return Err(format!("the app ended with {status}, not the kill"));
    }
    let journal = std::fs::metadata(sandbox.journal())
        .map_err(|error| format!("the kill left no journal, so no save was in flight: {error}"))?;
    eprintln!("killed with the save's journal on disk, {} bytes", journal.len());
    wait_until("the killed app to leave the bus", || !app_bus::name_has_owner(&bus))?;
    fresh_start(sandbox, address, &bus)?;
    runtime.block_on(check_database(sandbox))?;
    check_files(sandbox)
}

/// The app in a child process, killed when the test is done with it.
struct AppProcess {
    process: std::process::Child,
    log: PathBuf,
}

impl AppProcess {
    fn start(sandbox: &Sandbox, address: &str) -> Result<Self, String> {
        let exe = std::env::current_exe().map_err(|error| format!("could not find the test binary: {error}"))?;
        let log = sandbox.root.join("killed.log");
        // A file rather than a pipe: nobody reads a pipe while the app
        // runs, and a full one would stop it mid-write.
        let stderr = std::fs::File::create(&log).map_err(|error| format!("could not create the log: {error}"))?;
        let mut command = Command::new(exe);
        command.arg(&sandbox.database).env(MARKERS, &sandbox.markers);
        let process = sandbox
            .environment(&mut command, address)
            .stderr(stderr)
            .spawn()
            .map_err(|error| format!("could not start the app: {error}"))?;
        Ok(Self { process, log })
    }

    fn wait_until(&mut self, what: &str, mut ready: impl FnMut() -> bool) -> Result<(), String> {
        let deadline = Instant::now() + WAIT;
        while !ready() {
            if let Ok(Some(status)) = self.process.try_wait() {
                return Err(format!("the app exited with {status} before {what}:\n{}", self.log()));
            }
            if Instant::now() >= deadline {
                return Err(format!("timed out waiting for {what}:\n{}", self.log()));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        Ok(())
    }

    /// `Child::kill` sends SIGKILL.
    fn kill(&mut self) -> Result<ExitStatus, String> {
        self.process
            .kill()
            .map_err(|error| format!("could not kill the app: {error}"))?;
        self.process
            .wait()
            .map_err(|error| format!("could not wait for the app: {error}"))
    }

    fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

impl Drop for AppProcess {
    fn drop(&mut self) {
        if matches!(self.process.try_wait(), Ok(None)) {
            let _ = self.process.kill();
            let _ = self.process.wait();
        }
    }
}

/// Start TablePro again over what the killed one left, wait for it to
/// restore the session and connect, and quit it.
fn fresh_start(sandbox: &Sandbox, address: &str, bus: &gio::DBusConnection) -> Result<(), String> {
    let log_path = sandbox.root.join("fresh-start.log");
    let log = std::fs::File::create(&log_path).map_err(|error| format!("could not create the log: {error}"))?;
    let mut command = Command::new(env!("CARGO_BIN_EXE_tablepro"));
    let mut child = sandbox
        .environment(&mut command, address)
        .stderr(log)
        .spawn()
        .map_err(|error| format!("could not start the fresh start: {error}"))?;
    let outcome = wait_until_owned(address)
        .and_then(|()| wait_until("the restored window to connect", || connected_window(bus)))
        .and_then(|()| app_bus::activate(bus, &object_path(), "quit"))
        .and_then(|()| wait_for_exit(&mut child))
        .and_then(|status| match status.success() {
            true => Ok(()),
            false => Err(format!("the fresh start exited with {status}")),
        });
    if outcome.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    outcome.map_err(|message| {
        let log = std::fs::read_to_string(&log_path).unwrap_or_default();
        format!("{message}\nfresh start stderr:\n{log}")
    })
}

/// One window, on a connected workspace: Disconnect is enabled only there.
fn connected_window(bus: &gio::DBusConnection) -> bool {
    let ids = app_bus::window_ids(bus);
    ids.len() == 1
        && ids
            .iter()
            .all(|id| action_enabled(bus, &format!("{}/window/{id}", object_path()), "disconnect"))
}

fn action_enabled(bus: &gio::DBusConnection, path: &str, action: &str) -> bool {
    bus.call_sync(
        Some(APP_ID),
        path,
        "org.gtk.Actions",
        "Describe",
        Some(&(action,).to_variant()),
        None,
        gio::DBusCallFlags::NONE,
        app_bus::CALL_TIMEOUT_MS,
        gio::Cancellable::NONE,
    )
    .ok()
    .and_then(|reply| reply.try_child_value(0))
    .and_then(|description| description.try_child_value(0))
    .and_then(|enabled| enabled.get::<bool>())
    .unwrap_or(false)
}

async fn check_database(sandbox: &Sandbox) -> Result<(), String> {
    let connection = open(&sandbox.database).await?;
    integrity(connection.as_ref(), "the database").await?;
    let names = names(connection.as_ref())
        .await
        .map_err(|error| format!("could not read the table: {error}"))?;
    if names != FIRST_SAVE {
        return Err(format!(
            "the table holds {names:?}: the first save alone is {FIRST_SAVE:?}"
        ));
    }
    // A lock the killed process held would make this wait and fail. The
    // save never reached COMMIT, so the journal was never synced: its
    // header is still zero, no opener replays it, and this write
    // replaces it.
    write(connection.as_ref(), &["UPDATE items SET name = 'apple' WHERE id = 1"]).await?;
    close(connection.as_ref()).await?;
    if sandbox.journal().exists() {
        return Err("a write after the fresh start left the journal in place".to_owned());
    }

    let history = open(&sandbox.history()).await?;
    integrity(history.as_ref(), "the history").await?;
    close(history.as_ref()).await?;
    let saves = saved_history(&sandbox.history()).await?;
    match saves.as_slice() {
        [(query, Value::Int(1), Value::Int(1))] if query.starts_with("UPDATE") => Ok(()),
        other => Err(format!("the history holds {other:?}, not the first save alone")),
    }
}

/// What the stores the fresh start read still hold, with nothing moved
/// aside as unreadable.
fn check_files(sandbox: &Sandbox) -> Result<(), String> {
    let uri = glib::filename_to_uri(&sandbox.database, None).map_err(|error| format!("no URI: {error}"))?;
    let sessions = read_json(&sandbox.workspaces().join("open-sessions.json"))?;
    if !sessions.to_string().contains(uri.as_str()) {
        return Err(format!("the open sessions are {sessions}, without {uri}"));
    }
    let workspaces = workspaces(sandbox)?;
    if !keeps_items_tab(&workspaces) {
        return Err(format!("no workspace keeps the items tab: {workspaces:?}"));
    }
    check_settings(sandbox)?;
    let moved_aside: Vec<PathBuf> = ["config", "data", "state"]
        .into_iter()
        .flat_map(|dir| files_under(&sandbox.root.join(dir)))
        .filter(|path| path.to_string_lossy().contains(".corrupt-"))
        .collect();
    match moved_aside.is_empty() {
        true => Ok(()),
        false => Err(format!("the fresh start moved files aside: {moved_aside:?}")),
    }
}

/// Each session's saved tabs.
fn workspaces(sandbox: &Sandbox) -> Result<Vec<serde_json::Value>, String> {
    std::fs::read_dir(sandbox.workspaces())
        .map_err(|error| format!("no workspaces directory: {error}"))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "json"))
        .filter(|path| !path.ends_with("open-sessions.json"))
        .map(|path| read_json(&path))
        .collect()
}

fn keeps_items_tab(workspaces: &[serde_json::Value]) -> bool {
    workspaces
        .iter()
        .any(|workspace| workspace.to_string().contains("\"items\""))
}

/// The keyfile backend writes from inside the app, unlike dconf's
/// service, so the killed process wrote this file itself.
fn check_settings(sandbox: &Sandbox) -> Result<(), String> {
    let path = sandbox.root.join("config/glib-2.0/settings/keyfile");
    let keyfile = glib::KeyFile::new();
    keyfile
        .load_from_file(&path, glib::KeyFileFlags::NONE)
        .map_err(|error| format!("the settings do not load: {error}"))?;
    let group = APP_ID.replace('.', "/");
    let size = keyfile
        .value(&group, "default-page-size")
        .ok()
        .and_then(|text| glib::Variant::parse(Some(glib::VariantTy::UINT32), &text).ok())
        .and_then(|value| value.get::<u32>());
    match size {
        Some(PAGE_SIZE) => Ok(()),
        other => Err(format!("the page size preference reads {other:?}, not {PAGE_SIZE}")),
    }
}

fn read_json(path: &Path) -> Result<serde_json::Value, String> {
    let bytes = std::fs::read(path).map_err(|error| format!("could not read {}: {error}", path.display()))?;
    serde_json::from_slice(&bytes).map_err(|error| format!("{} is not JSON: {error}", path.display()))
}

fn files_under(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_owned()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            match path.is_dir() {
                true => pending.push(path),
                false => found.push(path),
            }
        }
    }
    found
}

/// The table the grid edits, and a trigger that runs a long count before
/// an UPDATE that finds a row this save already changed: the second
/// UPDATE of a two-row save runs until the kill, or past the statement
/// timeout.
async fn create_items(path: &Path) -> Result<(), String> {
    let endpoint = FileEndpoint::create_new(path.to_owned()).map_err(|error| format!("{}: {error}", path.display()))?;
    let connection = connect(endpoint).await?;
    let rows = BEFORE
        .iter()
        .enumerate()
        .map(|(index, name)| format!("({}, '{name}')", index + 1))
        .collect::<Vec<_>>()
        .join(", ");
    write(
        connection.as_ref(),
        &[
            "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
            &format!("INSERT INTO items VALUES {rows}"),
            "CREATE TABLE burn (n INTEGER)",
            "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 1000) \
             INSERT INTO burn SELECT n FROM c",
            "CREATE TRIGGER items_second_change BEFORE UPDATE OF name ON items \
             WHEN EXISTS (SELECT 1 FROM items WHERE name IN ('blueberry', 'cranberry')) \
             BEGIN SELECT count(*) FROM burn AS a, burn AS b, burn AS c; END",
        ],
    )
    .await?;
    close(connection.as_ref()).await
}

async fn open(path: &Path) -> Result<Arc<dyn Connection>, String> {
    let endpoint =
        FileEndpoint::open_existing(path.to_owned()).map_err(|error| format!("{}: {error}", path.display()))?;
    connect(endpoint).await
}

async fn connect(endpoint: FileEndpoint) -> Result<Arc<dyn Connection>, String> {
    let options = ConnectOptions {
        target: ConnectTarget::File(endpoint),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness: test_liveness(),
        environment: ConnectEnvironment::new("test"),
    };
    SqliteDriver
        .connect(options, CancellationToken::new())
        .await
        .map_err(|error| format!("could not open the file: {error}"))
}

async fn close(connection: &dyn Connection) -> Result<(), String> {
    connection
        .close()
        .await
        .map_err(|error| format!("could not close the file: {error}"))
}

fn call() -> CallOptions {
    CallOptions::new(Some(tokio::time::Instant::now() + WAIT), CancellationToken::new())
}

fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

async fn write(connection: &dyn Connection, statements: &[&str]) -> Result<(), String> {
    let steps = statements
        .iter()
        .map(|sql| GuardedStatement::unguarded(statement(sql)))
        .collect();
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("items"),
        steps,
        ForeignKeyMode::Enforced,
    );
    connection
        .write_batch(&batch, call())
        .await
        .map(drop)
        .map_err(|error| format!("could not write {statements:?}: {error}"))
}

async fn rows(connection: &dyn Connection, sql: &str) -> Result<Vec<Vec<Value>>, DriverError> {
    connection
        .query_bound(&statement(sql), RowLimit::EDITOR_DEFAULT, call())
        .await
        .map(|result| result.rows)
}

async fn names(connection: &dyn Connection) -> Result<Vec<String>, DriverError> {
    let rows = rows(connection, "SELECT name FROM items ORDER BY id").await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| match row.into_iter().next() {
            Some(Value::Text(name)) => Some(name),
            _ => None,
        })
        .collect())
}

async fn integrity(connection: &dyn Connection, what: &str) -> Result<(), String> {
    let rows = rows(connection, "PRAGMA integrity_check")
        .await
        .map_err(|error| format!("could not check {what}: {error}"))?;
    match rows.as_slice() {
        [row] if row.as_slice() == [Value::Text("ok".to_owned())] => Ok(()),
        other => Err(format!("{what} fails its integrity check: {other:?}")),
    }
}

/// Each entry of the query history: its SQL, rows affected and success.
async fn saved_history(path: &Path) -> Result<Vec<(String, Value, Value)>, String> {
    let connection = open(path).await?;
    let read = rows(
        connection.as_ref(),
        "SELECT query, rows_affected, success FROM history ORDER BY id",
    )
    .await;
    close(connection.as_ref()).await?;
    let read = read.map_err(|error| format!("could not read the history: {error}"))?;
    Ok(read
        .into_iter()
        .filter_map(|row| match <[Value; 3]>::try_from(row) {
            Ok([Value::Text(query), rows, success]) => Some((query, rows, success)),
            _ => None,
        })
        .collect())
}

/// Directories of the test's own, so neither launch reads or writes
/// anything of the developer's.
struct Sandbox {
    _temporary: tempfile::TempDir,
    root: PathBuf,
    schemas: PathBuf,
    markers: PathBuf,
    database: PathBuf,
    display: Vec<(&'static str, std::ffi::OsString)>,
}

impl Sandbox {
    fn new() -> Result<Self, String> {
        let temporary = tempfile::tempdir().map_err(|error| format!("no temporary directory: {error}"))?;
        // The app keys a file session by its real path.
        let root = std::fs::canonicalize(temporary.path())
            .map_err(|error| format!("could not resolve the sandbox: {error}"))?;
        for dir in ["schemas", "markers", "config", "data", "state", "cache", "runtime"] {
            std::fs::create_dir_all(root.join(dir)).map_err(|error| format!("could not create {dir}: {error}"))?;
        }
        // GLib and the XDG base directory specification expect the
        // runtime directory to be private to the user.
        std::fs::set_permissions(root.join("runtime"), std::fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("could not make the runtime directory private: {error}"))?;
        settings_schema::compile(&root.join("schemas"), &[APP_ID])?;
        Ok(Self {
            _temporary: temporary,
            schemas: root.join("schemas"),
            markers: root.join("markers"),
            database: root.join("items.db"),
            // g_test_dbus_up unsets DISPLAY along with the session bus.
            display: ["DISPLAY", "WAYLAND_DISPLAY"]
                .into_iter()
                .filter_map(|name| Some((name, std::env::var_os(name)?)))
                .collect(),
            root,
        })
    }

    fn storage(&self) -> PathBuf {
        self.root.join("state").join(tablepro_app::config::storage_dir_name())
    }

    fn history(&self) -> PathBuf {
        self.storage().join("history.db")
    }

    fn workspaces(&self) -> PathBuf {
        self.storage().join("workspaces")
    }

    fn journal(&self) -> PathBuf {
        let mut journal = self.database.clone().into_os_string();
        journal.push("-journal");
        PathBuf::from(journal)
    }

    /// Both launches run on the test's bus and directories, with
    /// GSettings in a file under them.
    fn environment<'a>(&self, command: &'a mut Command, address: &str) -> &'a mut Command {
        let root = &self.root;
        command
            .envs(self.display.iter().cloned())
            .env("DBUS_SESSION_BUS_ADDRESS", address)
            .env("LC_ALL", "C.UTF-8")
            .env("GSETTINGS_BACKEND", "keyfile")
            .env("GSETTINGS_SCHEMA_DIR", &self.schemas)
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("XDG_DATA_HOME", root.join("data"))
            .env("XDG_STATE_HOME", root.join("state"))
            .env("XDG_CACHE_HOME", root.join("cache"))
            .env("XDG_RUNTIME_DIR", root.join("runtime"))
            .env_remove("LANGUAGE")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
    }
}
