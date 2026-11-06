//! Emptying a table and creating or dropping a database from the
//! sidebar: what each asks, what it refuses, what it runs and records,
//! and what it closes.

use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ddl::{CharacterSet, DatabaseChoices, DatabaseDefaults, InboundForeignKey, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::{SchemaInfo, TableRef};
use tablepro_core::{ForeignKeyInfo, SafeModeLevel, ServerInfo, Value, WriteReport};
use tablepro_storage::query_history::{HistoryPageRequest, HistoryQuery};
use tablepro_test_support::{CallCounters, FakeConnection, FakeReply};
use uuid::Uuid;

use super::super::catalog_ops::{TRUNCATE, droppable_schema};
use super::super::{OpenMode, Workspace, WorkspaceInput};
use super::shell_of;
use crate::runtime::DeliverInput;
use crate::services::change_tracker::RowKey;
use crate::services::save_batch::SaveTarget;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{descendants, drain_main_context, finish_on_main, wait_until};
use crate::ui::session_window::tests::{TestWindow, WAIT};
use crate::workspace::test_workspace::integer;
use crate::workspace::{PendingState, answer, visible_alert};

fn postgres() -> Arc<dyn SqlDialect> {
    Arc::new(tablepro_driver_postgres::PgDialect::new(&ServerInfo::new(
        "PostgreSQL",
        "18.0",
        18,
        0,
        0,
    )))
}

fn mysql() -> Arc<dyn SqlDialect> {
    Arc::new(tablepro_driver_mysql::MySqlDialect::new(
        tablepro_driver_mysql::MySqlFlavour::MySql,
        &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
    ))
}

fn users() -> TableRef {
    TableRef::new(Some("public".to_owned()), "users")
}

fn pointing_at_users(name: &str, table: TableRef, column: &str) -> InboundForeignKey {
    InboundForeignKey {
        child_compares_alike: true,
        name: name.to_owned(),
        table,
        columns: vec![column.to_owned()],
        referenced_columns: vec!["id".to_owned()],
    }
}

fn users_definition(inbound_foreign_keys: Vec<InboundForeignKey>) -> TableDefinition {
    TableDefinition {
        table: users(),
        columns: Vec::new(),
        primary_key: None,
        indexes: Vec::new(),
        foreign_keys: Vec::<ForeignKeyInfo>::new(),
        inbound_foreign_keys,
        source: None,
        options: None,
    }
}

/// A PostgreSQL connection that writes whatever it is sent, and whose
/// `users` table other tables point at through `keys`.
fn postgres_writing(name: &str, keys: Vec<InboundForeignKey>) -> TestWindow {
    postgres_pointing(name, vec![("users", keys)])
}

/// A PostgreSQL connection that writes whatever it is sent, where the
/// keys each `(table, keys)` lists point at that table, and nothing
/// points at any other.
fn postgres_pointing(name: &str, pointing: Vec<(&str, Vec<InboundForeignKey>)>) -> TestWindow {
    TestWindow::connected_with(name, |script| {
        script.dialect = postgres();
        script.write_batch.always(FakeReply::ok(WriteReport::new(vec![None])));
        for (table, keys) in pointing {
            script
                .fetch_inbound_foreign_keys
                .when_sql_contains(table, FakeReply::ok(keys));
        }
        script.fetch_inbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    })
}

fn public(name: &str) -> TableRef {
    TableRef::new(Some("public".to_owned()), name)
}

/// Open `table` in a tab of its own and leave an unsaved edit in it.
fn edit_in_a_tab(workspace: &Workspace, table: &str) -> Uuid {
    let before = workspace.open_tabs().unwrap_or_default();
    workspace
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::SelectTable {
            schema: Some("public".to_owned()),
            name: table.to_owned(),
            open_mode: OpenMode::NewTab,
        });
    let mut opened = None;
    wait_until(WAIT, || {
        opened = workspace
            .open_tabs()
            .and_then(|tabs| tabs.into_iter().find(|tab| !before.contains(tab)));
        opened.is_some()
    })
    .expect("the table's tab");
    let tab = opened.expect("the tab");
    let tracker = super::row_tracker(workspace, tab).expect("the table's tracker");
    let _ = tracker.set_target(SaveTarget {
        table: public(table),
        columns: vec![integer("id", true), integer("n", false)],
    });
    let _ = tracker.apply(TrackerEdit::Cell {
        row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
        col: 1,
        original: Value::Int(1),
        value: CellInput::Value(Value::Int(2)),
    });
    assert_eq!(tracker.pending_state(), PendingState::Unsaved);
    tab
}

fn pending(workspace: &Workspace, tab: Uuid) -> Option<PendingState> {
    super::row_tracker(workspace, tab).map(|tracker| tracker.pending_state())
}

fn confirm_writes(test: &TestWindow) {
    let session = test
        .workspace()
        .with_model(|model| model.context.active.get())
        .flatten()
        .expect("the session");
    assert!(session.set_safe_mode(SafeModeLevel::ConfirmWrites));
}

fn alert_titled(test: &TestWindow, heading: &str) -> adw::AlertDialog {
    let mut found = None;
    wait_until(WAIT, || {
        found = visible_alert(&test.window).filter(|alert| alert.heading().as_deref() == Some(heading));
        found.is_some()
    })
    .unwrap_or_else(|_| {
        panic!(
            "no alert {heading:?}, but {:?}",
            visible_alert(&test.window).and_then(|alert| alert.heading())
        )
    });
    found.expect("the alert")
}

fn shown_sql(root: &impl IsA<gtk::Widget>) -> String {
    descendants(root)
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::TextView>().ok())
        .map(|view| {
            let buffer = view.buffer();
            buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
        })
        .unwrap_or_default()
}

fn switch_titled(root: &impl IsA<gtk::Widget>, title: &str) -> adw::SwitchRow {
    descendants(root)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::SwitchRow>().ok())
        .find(|row| row.title() == title)
        .unwrap_or_else(|| panic!("no {title} switch"))
}

fn row_titles(root: &impl IsA<gtk::Widget>) -> Vec<String> {
    descendants(root)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
        .map(|row| row.title().to_string())
        .collect()
}

fn written(connection: &FakeConnection) -> Vec<String> {
    connection.observed_sql("write_batch").into_iter().flatten().collect()
}

fn toast_shown(test: &TestWindow, text: &str) -> bool {
    test.window.shell().is_some_and(|shell| {
        descendants(&shell.toast_overlay())
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk::Label>())
            .any(|label| label.label() == text)
    })
}

/// The statements the window's history holds, newest first.
fn recorded(test: &TestWindow) -> Vec<String> {
    let Some(store) = test.services.history().store() else {
        return Vec::new();
    };
    let search = test.services.tasks.spawn_task(async move {
        let everything = HistoryQuery::default();
        store.search_page(&everything, HistoryPageRequest::first(100)).await
    });
    match finish_on_main(WAIT, search) {
        Ok(Ok(Ok(page))) => page.entries.into_iter().map(|entry| entry.query).collect(),
        _ => Vec::new(),
    }
}

#[gtk4::test]
fn a_dropped_table_is_in_the_history() {
    let test = postgres_writing("DropRecorded", Vec::new());
    let availability = test.services.history().availability();
    wait_until(WAIT, || availability.borrow().is_ready()).expect("the query database to open");

    test.workspace()
        .with_model(|model| model.on_drop_table_confirmed(Some("public".to_owned()), "users".to_owned()));

    wait_until(WAIT, || {
        recorded(&test)
            .iter()
            .any(|query| query.contains("DROP TABLE") && query.contains("\"users\""))
    })
    .expect("the drop in the history");
}

#[gtk4::test]
fn a_read_only_connection_empties_nothing() {
    let test = TestWindow::connected_with("TruncateReadOnly", |script| {
        script.dialect = postgres();
        script.read_only = true;
    });

    test.workspace()
        .with_model(|model| model.on_truncate_table_prompt(users()));

    wait_until(WAIT, || toast_shown(&test, "This connection is read-only.")).expect("the refusal");
    drain_main_context();
    assert!(
        visible_alert(&test.window).is_none(),
        "a read-only connection asked to empty a table"
    );
    let counters = test.connection().counters();
    assert_eq!(CallCounters::get(&counters.fetch_table_definition), 0);
    assert_eq!(CallCounters::get(&counters.write_batch), 0);
}

#[gtk4::test]
fn under_confirm_writes_the_truncate_shows_its_sql_and_cancel_is_the_default() {
    let test = postgres_writing("TruncateConfirmWrites", Vec::new());
    confirm_writes(&test);

    test.workspace()
        .with_model(|model| model.on_truncate_table_prompt(users()));

    let alert = alert_titled(&test, "Truncate “public.users”?");
    let sql = shown_sql(&alert);
    assert!(sql.contains("TRUNCATE TABLE \"public\".\"users\""), "{sql}");
    assert!(alert.body().contains("asks before every change"), "{}", alert.body());
    assert_eq!(alert.default_response().as_deref(), Some("cancel"));
    assert_eq!(alert.close_response(), "cancel");
    assert_eq!(
        alert.response_appearance(TRUNCATE),
        adw::ResponseAppearance::Destructive
    );
    assert!(answer(&test.window, "cancel"));
    drain_main_context();
    assert!(written(&test.connection()).is_empty(), "a cancelled truncate ran");
}

#[gtk4::test]
fn a_table_other_tables_point_at_is_refused_where_the_server_refuses_it() {
    let shop_users = TableRef::new(Some("shop".to_owned()), "users");
    let mut definition = users_definition(vec![
        pointing_at_users(
            "orders_user",
            TableRef::new(Some("shop".to_owned()), "orders"),
            "user_id",
        ),
        pointing_at_users("users_parent", shop_users.clone(), "parent_id"),
    ]);
    definition.table = shop_users.clone();
    let test = TestWindow::connected_with("TruncateRefusedMySql", |script| {
        script.dialect = mysql();
        script.fetch_table_definition.always(FakeReply::ok(definition.clone()));
    });

    test.workspace()
        .with_model(|model| model.on_truncate_table_prompt(shop_users));

    let alert = alert_titled(&test, "Cannot Truncate Table");
    let body = alert.body();
    assert!(body.contains("orders (user_id)"), "{body}");
    assert!(body.contains("Drop those foreign keys first"), "{body}");
    assert!(
        !body.contains("parent_id"),
        "a key of the table on itself was named: {body}"
    );
    assert!(!alert.has_response(TRUNCATE), "the refusal offered the truncate");
    assert!(answer(&test.window, "close"));
    assert!(written(&test.connection()).is_empty());
}

#[gtk4::test]
fn on_postgres_cascade_lets_a_referenced_table_be_emptied_and_says_so_in_the_sql() {
    let test = postgres_writing(
        "TruncateCascade",
        vec![pointing_at_users(
            "orders_user",
            TableRef::new(Some("public".to_owned()), "orders"),
            "user_id",
        )],
    );
    confirm_writes(&test);

    test.workspace()
        .with_model(|model| model.on_truncate_table_prompt(users()));

    let alert = alert_titled(&test, "Truncate “public.users”?");
    assert!(alert.body().contains("orders points at it"), "{}", alert.body());
    assert!(
        !alert.is_response_enabled(TRUNCATE),
        "a referenced table could be emptied without Cascade"
    );
    assert!(!shown_sql(&alert).contains("CASCADE"));
    switch_titled(&alert, "Cascade").set_active(true);
    assert!(alert.is_response_enabled(TRUNCATE));
    let sql = shown_sql(&alert);
    assert!(sql.contains("CASCADE"), "{sql}");

    let connection = test.connection();
    assert!(answer(&test.window, TRUNCATE));
    wait_until(WAIT, || written(&connection).iter().any(|sql| sql.contains("CASCADE")))
        .expect("the truncate with Cascade");
}

#[gtk4::test]
fn a_new_database_waits_for_its_name_and_shows_only_its_engines_options() {
    let test = TestWindow::connected_with("NewDatabase", |script| {
        script.dialect = postgres();
        script.write_batch.always(FakeReply::ok(WriteReport::new(vec![None])));
        script.fetch_database_choices.always(FakeReply::ok(DatabaseChoices {
            owners: vec!["app".to_owned(), "reporting".to_owned()],
            defaults: DatabaseDefaults {
                owner: Some("app".to_owned()),
                ..DatabaseDefaults::default()
            },
            ..DatabaseChoices::default()
        }));
    });

    // A new PostgreSQL database opens beside the connection, which
    // connects again, so the connection asked is the one taken now.
    let connection = test.connection();
    test.workspace().with_model(|model| model.on_new_database_prompt());

    let mut form = None;
    wait_until(WAIT, || {
        form = test
            .window
            .visible_dialog()
            .filter(|dialog| dialog.title() == "New Database");
        form.is_some()
    })
    .expect("the New Database form");
    let form = form.expect("the form");
    let titles = row_titles(&form);
    for shown in ["Name", "Owner", "Template", "Encoding", "Locale"] {
        assert!(titles.iter().any(|title| title == shown), "no {shown} row: {titles:?}");
    }
    for hidden in ["Character set", "Collation", "Replication", "First collection"] {
        assert!(
            !titles.iter().any(|title| title == hidden),
            "a {hidden} row: {titles:?}"
        );
    }
    let create = descendants(&form)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        // An entry row's own apply button is suggested-action too.
        .find(|button| button.has_css_class("suggested-action") && button.label().as_deref() == Some("_Create"))
        .expect("the Create button");
    assert!(!create.is_sensitive(), "Create was on with no name");

    descendants(&form)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::EntryRow>().ok())
        .find(|row| row.title() == "Name")
        .expect("the name row")
        .set_text("shop");
    assert!(create.is_sensitive(), "Create stayed off with a name");
    create.emit_clicked();

    wait_until(WAIT, || {
        written(&connection)
            .iter()
            .any(|sql| sql.contains("CREATE DATABASE \"shop\""))
    })
    .expect("the CREATE DATABASE");
}

#[gtk4::test]
fn tabs_closed_by_a_drop_cannot_be_reopened() {
    let test = postgres_writing("DropForgetsTabs", Vec::new());
    let workspace = test.workspace();
    workspace
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::SelectTable {
            schema: Some("public".to_owned()),
            name: "users".to_owned(),
            open_mode: OpenMode::NewTab,
        });
    wait_until(WAIT, || workspace.open_tabs().is_some_and(|tabs| tabs.len() == 1)).expect("the table's tab");

    workspace.with_model(|model| model.on_drop_table_confirmed(Some("public".to_owned()), "users".to_owned()));

    wait_until(WAIT, || workspace.open_tabs().is_some_and(|tabs| tabs.is_empty())).expect("the tab to close");
    assert!(
        shell_of(&workspace).imp().closed_tabs.borrow().is_empty(),
        "Reopen Closed Tab would open a table that is gone"
    );
}

#[gtk4::test]
fn a_database_change_or_a_refresh_lists_each_editor_tabs_databases_again() {
    let test = TestWindow::connected_with("RelistDatabases", |script| {
        script.dialect = postgres();
        script.list_databases.always(FakeReply::ok(vec![SchemaInfo {
            name: "shop".to_owned(),
            is_default: true,
            is_system: false,
        }]));
    });
    let workspace = test.workspace();
    let input = workspace.sender().expect("the workspace's input");
    let counters = test.connection().counters();
    input.deliver(WorkspaceInput::NewEditorTab);
    wait_until(WAIT, || CallCounters::get(&counters.list_databases) >= 1).expect("the new tab to list them");
    let listed = CallCounters::get(&counters.list_databases);

    input.deliver(WorkspaceInput::DatabasesChanged);
    wait_until(WAIT, || CallCounters::get(&counters.list_databases) > listed)
        .expect("a database change to list them again");
    let listed = CallCounters::get(&counters.list_databases);

    input.deliver(WorkspaceInput::RefreshCatalog);
    wait_until(WAIT, || CallCounters::get(&counters.list_databases) > listed).expect("a refresh to list them again");
}

/// Cascade empties the tables pointing at the table, and those pointing
/// at them: the Cascade row names them while it is on, and their tabs
/// lose their edits and read the tables again once it ran.
#[gtk4::test]
fn a_cascading_truncate_reloads_every_table_it_empties() {
    let test = postgres_pointing(
        "TruncateCascadeReach",
        vec![
            (
                "users",
                vec![pointing_at_users("orders_user", public("orders"), "user_id")],
            ),
            (
                "orders",
                vec![pointing_at_users("lines_order", public("lines"), "order_id")],
            ),
        ],
    );
    let workspace = test.workspace();
    let (orders, lines) = (edit_in_a_tab(&workspace, "orders"), edit_in_a_tab(&workspace, "lines"));
    let connection = test.connection();
    let counters = connection.counters();

    workspace.with_model(|model| model.on_truncate_table_prompt(users()));

    let alert = alert_titled(&test, "Truncate “public.users”?");
    let cascade = switch_titled(&alert, "Cascade");
    let subtitle = |row: &adw::SwitchRow| row.subtitle().map(|text| text.to_string()).unwrap_or_default();
    assert!(!subtitle(&cascade).contains("lines"), "{}", subtitle(&cascade));
    cascade.set_active(true);
    let named = subtitle(&cascade);
    assert!(named.contains("orders, lines"), "{named}");
    assert!(named.contains("unsaved changes"), "{named}");
    let reads = CallCounters::get(&counters.fetch_columns);
    assert!(answer(&test.window, TRUNCATE));

    wait_until(WAIT, || {
        pending(&workspace, orders) == Some(PendingState::Clean)
            && pending(&workspace, lines) == Some(PendingState::Clean)
    })
    .expect("the edits of every table the cascade emptied to go");
    // A tab behind the one in front can wait to read until it is shown.
    wait_until(WAIT, || CallCounters::get(&counters.fetch_columns) > reads)
        .expect("the tables' tabs to read them again");
    assert!(written(&connection).iter().any(|sql| sql.contains("CASCADE")));
}

/// Left to the server, a MySQL database takes the server's own
/// collation, which need not be its character set's default.
#[gtk4::test]
fn the_collation_left_to_the_server_names_the_servers_own() {
    let set = |name: &str, collations: &[&str]| CharacterSet {
        name: name.to_owned(),
        default_collation: collations[0].to_owned(),
        collations: collations.iter().map(|collation| (*collation).to_owned()).collect(),
    };
    let test = TestWindow::connected_with("NewDatabaseCollation", |script| {
        script.dialect = mysql();
        script.fetch_database_choices.always(FakeReply::ok(DatabaseChoices {
            character_sets: vec![
                set("utf8mb4", &["utf8mb4_0900_ai_ci", "utf8mb4_unicode_ci"]),
                set("latin1", &["latin1_swedish_ci", "latin1_bin"]),
            ],
            defaults: DatabaseDefaults {
                character_set: Some("utf8mb4".to_owned()),
                collation: Some("utf8mb4_unicode_ci".to_owned()),
                ..DatabaseDefaults::default()
            },
            ..DatabaseChoices::default()
        }));
    });

    test.workspace().with_model(|model| model.on_new_database_prompt());

    let mut form = None;
    wait_until(WAIT, || {
        form = test
            .window
            .visible_dialog()
            .filter(|dialog| dialog.title() == "New Database");
        form.is_some()
    })
    .expect("the New Database form");
    let form = form.expect("the form");
    let combo = |title: &str| {
        descendants(&form)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::ComboRow>().ok())
            .find(|row| row.title() == title)
            .unwrap_or_else(|| panic!("no {title} row"))
    };
    let first_entry = |row: &adw::ComboRow| {
        row.model()
            .and_downcast::<gtk::StringList>()
            .and_then(|entries| entries.string(0))
            .map(|entry| entry.to_string())
    };
    let (character_set, collation) = (combo("Character set"), combo("Collation"));

    assert_eq!(first_entry(&collation).as_deref(), Some("Default (utf8mb4_unicode_ci)"));
    character_set.set_selected(2);
    assert_eq!(first_entry(&collation).as_deref(), Some("Default (latin1_swedish_ci)"));
    character_set.set_selected(0);
    assert_eq!(first_entry(&collation).as_deref(), Some("Default (utf8mb4_unicode_ci)"));
}

#[test]
fn a_schema_named_like_its_database_can_be_dropped_where_schemas_are_not_databases() {
    let schema = |name: &str, is_default: bool| SchemaInfo {
        name: name.to_owned(),
        is_default,
        is_system: false,
    };
    let schemas = [
        schema("public", true),
        schema("shop", false),
        schema("pg_temp_3", false),
    ];

    assert!(droppable_schema(&schemas, Some("shop"), &*postgres(), "shop"));
    assert!(!droppable_schema(&schemas, Some("shop"), &*postgres(), "public"));
    assert!(!droppable_schema(&schemas, Some("shop"), &*postgres(), "pg_temp_3"));
    assert!(!droppable_schema(&schemas, Some("shop"), &*postgres(), "missing"));
    assert!(
        !droppable_schema(&schemas, Some("shop"), &*mysql(), "shop"),
        "MySQL dropped the database the session is in"
    );
}

#[test]
fn the_tables_that_point_at_one_are_named_once_each() {
    let keys = [
        pointing_at_users("a", TableRef::new(Some("public".to_owned()), "orders"), "user_id"),
        pointing_at_users("b", TableRef::new(Some("public".to_owned()), "orders"), "buyer_id"),
        pointing_at_users("c", TableRef::new(Some("audit".to_owned()), "log"), "actor_id"),
    ];

    assert_eq!(
        super::super::catalog_ops::referencing_tables(&users(), &keys),
        ["orders", "audit.log"]
    );
}
