//! Every page a session window shows, and the dialogs it opens, checked
//! for a control a screen reader reaches and cannot name.
//!
//! Each scenario starts a TablePro over fakes and walks it to the page,
//! on the main context, the way a user's clicks would. GTK records the
//! accessible properties only under GTK_A11Y=test. Pass scenario names
//! to run only those.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

mod audit;
#[path = "../support/settings_schema.rs"]
mod settings_schema;
mod world;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_app::application::WindowLaunch;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition, TableDefinition};
use tablepro_core::meta::{ObjectInfo, ObjectKind, RowCountEstimate, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::{ColumnInfo, DatabaseDriver, DriverError, DriverRegistry, QueryResult, ServerInfo, Value};
use tablepro_session::ConnectError;
use tablepro_session::fakes::{FakeConnector, FakeEstablish};
use tablepro_test_support::{ConnectionScript, FakeDriver, FakeReply};

use audit::{Finding, audit, descendants};
use world::{World, drain_main_context, wait_until};

type Scenario = fn() -> Result<Vec<Finding>, String>;

const SCENARIOS: [(&str, Scenario); 7] = [
    ("picker_page_controls_are_labelled", picker_page),
    ("connecting_page_controls_are_labelled", connecting_page),
    ("connect_failed_page_controls_are_labelled", connect_failed_page),
    ("workspace_controls_are_labelled", workspace),
    ("structure_forms_are_labelled", structure_forms),
    ("connect_dialog_fields_are_labelled", connect_dialog),
    ("preferences_dialog_fields_are_labelled", preferences_dialog),
];
/// A run that has not finished by now never will.
const RUN_LIMIT: Duration = Duration::from_secs(600);
const TABLE: &str = "orders";
const CELL: &str = "first order";

fn main() -> ExitCode {
    let wanted: Vec<String> = std::env::args().skip(1).filter(|arg| !arg.starts_with('-')).collect();
    if let Err(message) = init() {
        eprintln!("{message}");
        return ExitCode::FAILURE;
    }
    std::thread::spawn(|| {
        std::thread::sleep(RUN_LIMIT);
        eprintln!("the scenarios did not finish within {RUN_LIMIT:?}");
        std::process::exit(2);
    });
    let mut failed = false;
    for (name, scenario) in SCENARIOS {
        if !wanted.is_empty() && !wanted.iter().any(|filter| name.contains(filter.as_str())) {
            continue;
        }
        match scenario() {
            Ok(findings) if findings.is_empty() => eprintln!("{name}: ok"),
            Ok(findings) => {
                failed = true;
                eprintln!("{name}: {} unlabelled", findings.len());
                for finding in findings {
                    eprintln!("  {finding}");
                }
            }
            Err(message) => {
                failed = true;
                eprintln!("{name} failed: {message}");
            }
        }
    }
    if failed { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

fn init() -> Result<(), String> {
    gtk4::init().map_err(|error| format!("GTK could not start: {error}"))?;
    adw::init().map_err(|error| format!("libadwaita could not start: {error}"))?;
    if !audit::test_backend_active() {
        return Err("the GTK test accessibility backend is not active; run with GTK_A11Y=test".to_owned());
    }
    gio::resources_register_include!("tablepro.gresource")
        .map_err(|error| format!("could not register the resources: {error}"))?;
    // A page change or a dialog then finishes before the next step.
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_enable_animations(false);
    }
    Ok(())
}

fn picker_page() -> Result<Vec<Finding>, String> {
    let world = World::start("Picker", fake_driver(), FakeConnector::new([]))?;
    let window = world.open(WindowLaunch::Picker)?;
    let name = world.saved.name.clone();
    wait_until("the saved connection in the picker", || {
        shows(&window, "TableProPickerPage") && has_row(window.upcast_ref(), &name)
    })?;
    Ok(audit(&window))
}

fn connecting_page() -> Result<Vec<Finding>, String> {
    let world = World::start(
        "Connecting",
        fake_driver(),
        FakeConnector::new([FakeEstablish::UntilCancelled]),
    )?;
    let window = world.open(WindowLaunch::Connect(Box::new(world.saved.clone())))?;
    wait_until("the connecting page", || shows(&window, "TableProConnectingPage"))?;
    Ok(audit(&window))
}

fn connect_failed_page() -> Result<Vec<Finding>, String> {
    let refused = ConnectError::Driver(DriverError::Auth { diagnostics: None });
    let world = World::start(
        "ConnectFailed",
        fake_driver(),
        FakeConnector::new([FakeEstablish::Fail(refused)]),
    )?;
    let window = world.open(WindowLaunch::Connect(Box::new(world.saved.clone())))?;
    wait_until("the connect failed page", || {
        shows(&window, "TableProConnectFailedPage")
    })?;
    Ok(audit(&window))
}

/// A table tab, a structure tab and an editor tab, each audited while it
/// is the one in front, with the table's filter strip, the sidebar's
/// search and the editor's find and replace open, then the table tab
/// again with a cell's editor open.
fn workspace() -> Result<Vec<Finding>, String> {
    let (_world, window) = connected("Workspace")?;
    open_table(&window)?;
    open_filter_strip(&window)?;
    open_structure(&window)?;
    WidgetExt::activate_action(&window, "win.new-editor-tab", None)
        .map_err(|error| format!("win.new-editor-tab: {error}"))?;
    let mut editor = None;
    wait_until("the editor tab", || {
        editor = widgets_of(window.upcast_ref(), "TableProSqlEditor").pop();
        editor.is_some()
    })?;
    let editor = editor.ok_or("no editor")?;
    editor
        .activate_action("editor.find-replace", None)
        .map_err(|error| format!("editor.find-replace: {error}"))?;
    for search in descendants(window.upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::SearchBar>().ok())
    {
        search.set_search_mode(true);
    }

    let tabs = descendants(window.upcast_ref())
        .into_iter()
        .find_map(|widget| widget.downcast::<adw::TabView>().ok())
        .ok_or("the workspace has no tab view")?;
    if tabs.n_pages() != 3 {
        return Err(format!("{} tabs open, not 3", tabs.n_pages()));
    }
    let mut findings = Vec::new();
    for position in 0..tabs.n_pages() {
        tabs.set_selected_page(&tabs.nth_page(position));
        drain_main_context();
        merge(&mut findings, audit(&window));
    }
    tabs.set_selected_page(&tabs.nth_page(0));
    drain_main_context();
    open_cell_editor(&window)?;
    merge(&mut findings, audit(&window));
    Ok(findings)
}

/// The Add Index and Add Foreign Key forms of the structure tab.
fn structure_forms() -> Result<Vec<Finding>, String> {
    let (_world, window) = connected("StructureForms")?;
    open_structure(&window)?;
    let mut findings = Vec::new();
    for title in ["Add Index…", "Add Foreign Key…"] {
        let row = descendants(window.upcast_ref())
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::ButtonRow>().ok())
            .find(|row| row.title() == title)
            .ok_or_else(|| format!("the structure tab has no {title} row"))?;
        row.emit_by_name::<()>("activated", &[]);
        let mut shown = None;
        wait_until(title, || {
            shown = window.visible_dialog();
            shown.is_some()
        })?;
        let dialog = shown.ok_or("no dialog")?;
        drain_main_context();
        merge(&mut findings, audit(&dialog));
        dialog.close();
        wait_until("the form to close", || window.visible_dialog().is_none())?;
    }
    Ok(findings)
}

/// A window connected to `one_table`, on its workspace.
fn connected(name: &str) -> Result<(World, adw::ApplicationWindow), String> {
    let world = World::start(
        name,
        fake_driver(),
        FakeConnector::new([]).always(FakeEstablish::Connect(one_table())),
    )?;
    let window = world.open(WindowLaunch::Connect(Box::new(world.saved.clone())))?;
    wait_until("the table in the sidebar", || {
        shows(&window, "TableProWorkspace") && shows_text(window.upcast_ref(), TABLE)
    })?;
    Ok((world, window))
}

fn sidebar_action(window: &adw::ApplicationWindow, action: &str) -> Result<(), String> {
    let sidebar = descendants(window.upcast_ref())
        .into_iter()
        .find(|widget| widget.is::<gtk4::ListView>())
        .ok_or("the sidebar has no list")?;
    let table = (Some("public".to_owned()), TABLE.to_owned()).to_variant();
    sidebar
        .activate_action(action, Some(&table))
        .map_err(|error| format!("{action}: {error}"))
}

fn open_table(window: &adw::ApplicationWindow) -> Result<(), String> {
    sidebar_action(window, "sidebar.open-in-new-tab")?;
    wait_until("the table's rows", || shows_text(window.upcast_ref(), CELL))
}

fn open_structure(window: &adw::ApplicationWindow) -> Result<(), String> {
    sidebar_action(window, "sidebar.edit-structure")?;
    wait_until("the table's structure", || {
        widgets_of(window.upcast_ref(), "TableProStructureTab")
            .iter()
            .flat_map(descendants)
            .filter_map(|widget| widget.downcast::<gtk4::Stack>().ok())
            .any(|stack| stack.visible_child_name().as_deref() == Some("editor"))
    })
}

/// The table tab's filter strip, open on its rule editor with one rule.
fn open_filter_strip(window: &adw::ApplicationWindow) -> Result<(), String> {
    let tab = widgets_of(window.upcast_ref(), "TableProBrowseTab")
        .pop()
        .ok_or("no table tab")?;
    tab.activate_action("browse.filter", None)
        .map_err(|error| format!("browse.filter: {error}"))?;
    let strip = widgets_of(&tab, "TableProFilterStrip").pop().ok_or("no filter strip")?;
    strip
        .activate_action("filter.add-rule", None)
        .map_err(|error| format!("filter.add-rule: {error}"))?;
    for expander in descendants(&strip)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::Expander>().ok())
    {
        expander.set_expanded(true);
    }
    wait_until("the filter rule", || {
        !widgets_of(&strip, "TableProFilterRuleRow").is_empty()
    })
}

/// The editor of the cell that shows `CELL`, opened from its menu the
/// way the Menu key opens it.
fn open_cell_editor(window: &adw::ApplicationWindow) -> Result<(), String> {
    let cell = widgets_of(window.upcast_ref(), "TableProGridCell")
        .into_iter()
        .find(|cell| shows_text(cell, CELL))
        .ok_or("no cell shows the row")?;
    let controllers = cell.observe_controllers();
    let menu = (0..controllers.n_items())
        .filter_map(|index| controllers.item(index).and_downcast::<gtk4::GestureClick>())
        .find(|gesture| gesture.button() == 3)
        .ok_or("the cell has no menu")?;
    menu.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
    for popover in descendants(window.upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::PopoverMenu>().ok())
    {
        popover.popdown();
    }
    drain_main_context();
    cell.activate_action("cell.edit", None)
        .map_err(|error| format!("cell.edit: {error}"))?;
    wait_until("the cell's editor", || {
        descendants(&cell)
            .iter()
            .any(|widget| widget.is::<gtk4::Text>() && widget.is_visible())
    })
}

/// The dialog for a new connection, on a server engine and then on a
/// file engine, with every section expanded.
fn connect_dialog() -> Result<Vec<Finding>, String> {
    let mut drivers = DriverRegistry::new();
    let engines: [Arc<dyn DatabaseDriver>; 2] = [
        Arc::new(tablepro_driver_postgres::PgDriver),
        Arc::new(tablepro_driver_sqlite::SqliteDriver),
    ];
    for engine in engines {
        drivers.register(engine);
    }
    let world = World::start("ConnectDialog", drivers, FakeConnector::new([]))?;
    let window = world.open(WindowLaunch::Picker)?;
    wait_until("the picker", || shows(&window, "TableProPickerPage"))?;
    WidgetExt::activate_action(&window, "win.new-connection", None)
        .map_err(|error| format!("win.new-connection: {error}"))?;
    let mut shown = None;
    wait_until("the connect dialog", || {
        shown = window.visible_dialog();
        shown.is_some()
    })?;
    let dialog = shown.ok_or("no dialog")?;

    let mut findings = Vec::new();
    for engine in ["PostgreSQL", "SQLite"] {
        choose_driver(&dialog, engine)?;
        expand_all(dialog.upcast_ref());
        drain_main_context();
        merge(&mut findings, audit(&dialog));
    }
    Ok(findings)
}

/// Every page of the dialog, each audited while it is the one shown.
fn preferences_dialog() -> Result<Vec<Finding>, String> {
    let world = World::start("Preferences", fake_driver(), FakeConnector::new([]))?;
    let window = world.open(WindowLaunch::Picker)?;
    wait_until("the picker", || shows(&window, "TableProPickerPage"))?;
    world.app.activate_action("preferences", None);
    let mut shown = None;
    wait_until("the preferences dialog", || {
        shown = window.visible_dialog().and_downcast::<adw::PreferencesDialog>();
        shown.is_some()
    })?;
    let dialog = shown.ok_or("no dialog")?;

    // The pages the dialog switches between, which leaves out the one
    // libadwaita keeps for search results.
    let pages: Vec<adw::PreferencesPage> = descendants(dialog.upcast_ref())
        .into_iter()
        .filter(|widget| widget.parent().is_some_and(|parent| parent.is::<adw::ViewStack>()))
        .filter_map(|widget| widget.downcast::<adw::PreferencesPage>().ok())
        .collect();
    if pages.is_empty() {
        return Err("the dialog has no pages".to_owned());
    }
    let mut findings = Vec::new();
    for page in pages {
        dialog.set_visible_page(&page);
        drain_main_context();
        merge(&mut findings, audit(&dialog));
    }
    Ok(findings)
}

/// Add what `more` found that `findings` does not already hold, since a
/// control seen on two passes is one finding.
fn merge(findings: &mut Vec<Finding>, more: Vec<Finding>) {
    for finding in more {
        if !findings.contains(&finding) {
            findings.push(finding);
        }
    }
}

fn fake_driver() -> DriverRegistry {
    let mut drivers = DriverRegistry::new();
    drivers.register(Arc::new(FakeDriver::connecting(
        &FakeDriver::FILE_CAPABILITIES,
        ConnectionScript::default(),
    )));
    drivers
}

/// A connection whose catalog lists one table, with its rows and its
/// definition, in an engine whose structure can be edited.
fn one_table() -> ConnectionScript {
    let mut script = ConnectionScript {
        dialect: Arc::new(tablepro_driver_postgres::PgDialect::new(&ServerInfo::new(
            "PostgreSQL",
            "18.0",
            18,
            0,
            0,
        ))),
        ..ConnectionScript::default()
    };
    let columns = vec![column("id", true), column("note", false)];
    script.probe.always(FakeReply::ok(()));
    script.list_schemas.always(FakeReply::ok(vec![SchemaInfo {
        name: "public".to_owned(),
        is_default: true,
        is_system: false,
    }]));
    script.list_objects.always(FakeReply::ok(vec![ObjectInfo {
        schema: Some("public".to_owned()),
        name: TABLE.to_owned(),
        kind: ObjectKind::Table,
    }]));
    script.fetch_columns.always(FakeReply::ok(columns.clone()));
    script.fetch_indexes.always(FakeReply::ok(Vec::new()));
    script.fetch_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(1));
    script.table_estimate.always(FakeReply::ok(TableEstimate {
        rows: RowCountEstimate::Approximate(1),
        heap_blocks: None,
    }));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(1), Value::Text(CELL.to_owned())]],
    )));
    script.fetch_table_definition.always(FakeReply::ok(TableDefinition {
        table: TableRef::new(Some("public".to_owned()), TABLE),
        columns: columns
            .into_iter()
            .map(|column| ColumnDefinition::new(column, ColumnAttributes::default()))
            .collect(),
        primary_key: None,
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: None,
    }));
    script
}

fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

/// Whether the window's content is the page of class `name`.
fn shows(window: &adw::ApplicationWindow, name: &str) -> bool {
    window.content().is_some_and(|page| page.type_().name() == name)
}

fn widgets_of(root: &gtk4::Widget, name: &str) -> Vec<gtk4::Widget> {
    descendants(root)
        .into_iter()
        .filter(|widget| widget.type_().name() == name)
        .collect()
}

/// Whether a label, or a grid cell's inscription, under `root` shows
/// `text`.
fn shows_text(root: &gtk4::Widget, text: &str) -> bool {
    descendants(root).iter().any(|widget| {
        widget
            .downcast_ref::<gtk4::Label>()
            .is_some_and(|label| label.label() == text)
            || widget
                .downcast_ref::<gtk4::Inscription>()
                .is_some_and(|cell| cell.text().as_deref() == Some(text))
    })
}

fn has_row(root: &gtk4::Widget, title: &str) -> bool {
    descendants(root)
        .iter()
        .filter_map(|widget| widget.downcast_ref::<adw::PreferencesRow>())
        .any(|row| row.title() == title)
}

fn choose_driver(dialog: &adw::Dialog, engine: &str) -> Result<(), String> {
    let row = descendants(dialog.upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ComboRow>().ok())
        .find(|row| row.title() == "Driver")
        .ok_or("the dialog has no Driver row")?;
    let names = row
        .model()
        .and_downcast::<gtk4::StringList>()
        .ok_or("the Driver row lists no names")?;
    let position = (0..names.n_items())
        .find(|position| names.string(*position).as_deref() == Some(engine))
        .ok_or_else(|| format!("the Driver row does not offer {engine}"))?;
    row.set_selected(position);
    Ok(())
}

/// Open every expander row, as a user would to see what it holds.
fn expand_all(root: &gtk4::Widget) {
    for row in descendants(root)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ExpanderRow>().ok())
    {
        if row.shows_enable_switch() {
            row.set_enable_expansion(true);
        }
        row.set_expanded(true);
    }
}
