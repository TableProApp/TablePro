//! A connection's other databases open beside it and live and go with
//! its session (0030).

use std::time::Duration;

use gtk4::prelude::*;
use libadwaita::prelude::*;
use tablepro_core::WriteReport;
use tablepro_session::SessionKey;
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, CloseBehaviour, ConnectionScript, FakeReply};

use super::{Script, TestWindow, WAIT, editors, pick_level, refused};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::SessionWindowInput;
use crate::workspace::{answer, visible_alert};

const ANALYTICS: &str = "analytics";

/// A server connection whose password is stored, which another of its
/// databases opens with, unasked. `establish` is what each connect gets
/// before the test's connection from then on.
fn network_window(name: &str, establish: Vec<FakeEstablish>) -> TestWindow {
    network_window_with(
        name,
        Script {
            establish,
            ..Script::default()
        },
    )
}

fn network_window_with(name: &str, script: Script) -> TestWindow {
    let test = TestWindow::with_script(
        name,
        Script {
            network: true,
            ..script
        },
    );
    let (vault, id) = (test.vault.clone(), test.saved.id);
    crate::test_support::finish_on_main(WAIT, async move {
        tablepro_core::credentials::SecretVault::store(
            &*vault,
            id,
            tablepro_core::credentials::SecretKind::DatabasePassword,
            &secrecy::SecretString::from("s3cret"),
            "label",
        )
        .await
    })
    .expect("the store to end")
    .expect("the password stored");
    test
}

fn connect(test: &TestWindow) {
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
}

fn analytics(test: &TestWindow) -> SessionKey {
    SessionKey::SavedIn {
        id: test.saved.id,
        database: ANALYTICS.to_owned(),
    }
}

/// A connection that answers what a workspace asks as it opens.
fn answering() -> FakeEstablish {
    FakeEstablish::Connect(answering_script())
}

fn answering_script() -> ConnectionScript {
    let mut connection = ConnectionScript::default();
    connection.probe.always(FakeReply::ok(()));
    connection.list_schemas.always(FakeReply::ok(Vec::new()));
    connection.list_objects.always(FakeReply::ok(Vec::new()));
    connection
}

/// The connection connects; another of its databases never answers
/// until its open is stopped.
fn opening_never_ends() -> Vec<FakeEstablish> {
    vec![answering(), FakeEstablish::UntilCancelled]
}

#[gtk4::test]
fn another_database_opens_beside_the_connection_and_goes_with_it() {
    let test = network_window("OtherDatabase", Vec::new());
    connect(&test);
    let sibling = analytics(&test);

    test.window.open_database(test.saved.id, ANALYTICS.to_owned());

    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open");
    let session = test.window.held_session(&sibling).expect("the database's session");
    assert_eq!(session.database(), Some(ANALYTICS));
    let calls = test.connector.calls();
    assert!(
        !calls.last().expect("a connect for the database").attended,
        "opening the database asked for a secret"
    );
    assert_eq!(test.window.workspaces().len(), 2, "the database has no workspace");

    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    drain_main_context();
    assert_eq!(
        test.connector.calls().len(),
        calls.len(),
        "the open database opened again"
    );

    test.window.send(SessionWindowInput::DisconnectSession(test.key()));
    wait_until(WAIT, || test.window.held_session(&sibling).is_none()).expect("the database to go with it");
    assert_eq!(test.services.sessions.window_for(&sibling), None);
}

/// A database still opening when its connection disconnects stops, and
/// its key is free for the next connect to open it again.
#[gtk4::test]
fn a_database_still_opening_goes_with_its_connection() {
    let test = network_window("OtherDatabaseOpening", opening_never_ends());
    connect(&test);
    let sibling = analytics(&test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("the database to start opening");
    assert_eq!(
        test.services.sessions.window_for(&sibling),
        Some(test.window.id()),
        "the opening holds no claim"
    );

    test.window.send(SessionWindowInput::DisconnectSession(test.key()));

    wait_until(WAIT, || test.services.sessions.window_for(&sibling).is_none()).expect("the opening to let its key go");
    connect(&test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open again");
}

/// Closing the window stops a database still opening and lets its key
/// go.
#[gtk4::test]
fn a_database_still_opening_goes_with_the_window() {
    let test = network_window("OtherDatabaseWindowClosed", opening_never_ends());
    connect(&test);
    let sibling = analytics(&test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("the database to start opening");

    test.window.close();

    wait_until(WAIT, || test.services.sessions.window_for(&sibling).is_none()).expect("the opening to let its key go");
}

/// A level on the other side of Read-Only reconnects the connection, and
/// its other databases open again beside it at that level.
#[gtk4::test]
fn read_only_reopens_the_other_databases_at_the_new_level() {
    let test = network_window("OtherDatabaseReadOnly", Vec::new());
    connect(&test);
    let sibling = analytics(&test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open");
    let before = test.window.held_session(&sibling).expect("the database's session");

    pick_level(&test, "read-only");

    wait_until(WAIT, || {
        test.window
            .held_session(&sibling)
            .is_some_and(|session| !std::sync::Arc::ptr_eq(&session, &before))
    })
    .expect("the database to open again");
    let reopened = test.window.held_session(&sibling).expect("the database's session");
    assert_eq!(reopened.safe_mode(), tablepro_core::SafeModeLevel::ReadOnly);
    let request = test.connector.calls().pop().expect("the database's connect").request;
    assert!(request.workspace_settings.read_only);
}

/// A reconnect for Read-Only that fails keeps the connection's other
/// databases with its failure, and Retry opens them beside it again.
#[gtk4::test]
fn a_failed_reconnect_reopens_the_other_databases_on_retry() {
    let test = network_window("OtherDatabaseRetry", vec![answering(), answering(), refused()]);
    connect(&test);
    let sibling = analytics(&test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open");

    pick_level(&test, "read-only");
    test.wait_for_page("connect-failed");
    assert!(test.window.held_session(&sibling).is_none());
    test.window.send(SessionWindowInput::RetryConnect);

    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open again");
}

/// A level picked while one of the connection's other databases is in
/// front is the connection's, and moves every one of its sessions.
#[gtk4::test]
fn a_level_picked_in_another_database_moves_the_connection() {
    let test = network_window("OtherDatabaseLevel", Vec::new());
    connect(&test);
    let sibling = analytics(&test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open");

    test.window.send(SessionWindowInput::SetSafeMode {
        key: sibling.clone(),
        level: tablepro_core::SafeModeLevel::ConfirmWrites,
    });

    for key in [test.key(), sibling] {
        wait_until(WAIT, || {
            test.window
                .held_session(&key)
                .is_some_and(|session| session.safe_mode() == tablepro_core::SafeModeLevel::ConfirmWrites)
        })
        .unwrap_or_else(|_| panic!("{key:?} kept its level"));
    }
    assert_eq!(test.connector.calls().len(), 2, "a level that writes reconnected");
}

fn on_engine(name: &str, dialect: std::sync::Arc<dyn tablepro_core::dialect::SqlDialect>) -> TestWindow {
    network_window_with(
        name,
        Script {
            connection: ConnectionScript {
                dialect,
                ..ConnectionScript::default()
            },
            ..Script::default()
        },
    )
}

/// Each editor tab of the connection, `count` of them, moved to
/// `ANALYTICS` from the editor bar.
fn move_new_tabs(test: &TestWindow, count: usize) -> Vec<crate::ui::editor::SqlEditor> {
    let connection = crate::ui::session_target::to_variant(&test.key());
    for _ in 0..count {
        WidgetExt::activate_action(&test.window, "win.new-query-in", Some(&connection)).expect("win.new-query-in");
    }
    wait_until(WAIT, || editors(&test.window).len() == count).expect("the tabs");
    let tabs = editors(&test.window);
    for editor in &tabs {
        WidgetExt::activate_action(editor, "editor.database", Some(&ANALYTICS.to_variant())).expect("editor.database");
    }
    tabs
}

/// Tabs moved to a database whose engine's catalog holds only the
/// connection's own read that database's session, which opens once for
/// all of them.
#[gtk4::test]
fn tabs_moved_to_another_database_read_its_session() {
    let test = on_engine(
        "FollowDatabase",
        std::sync::Arc::new(tablepro_driver_postgres::PgDialect::new(
            &tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0),
        )),
    );
    connect(&test);
    let sibling = analytics(&test);

    let tabs = move_new_tabs(&test, 2);

    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open");
    wait_until(WAIT, || {
        tabs.iter()
            .all(|editor| editor.followed_catalog().as_deref() == Some(ANALYTICS))
    })
    .expect("every moved tab to read the database's catalog");
    assert_eq!(test.connector.calls().len(), 2, "the database opened once per tab");
}

/// An engine whose connection lists every database already opens no
/// session for a moved tab.
#[gtk4::test]
fn a_tab_moved_where_the_catalog_lists_every_database_opens_nothing() {
    let test = on_engine(
        "FollowDatabaseListed",
        std::sync::Arc::new(tablepro_driver_mysql::MySqlDialect::new(
            tablepro_driver_mysql::MySqlFlavour::MySql,
            &tablepro_core::ServerInfo::new("MySQL", "8.4.0", 8, 4, 0),
        )),
    );
    connect(&test);

    let tabs = move_new_tabs(&test, 1);
    drain_main_context();

    assert!(
        test.window.held_session(&analytics(&test)).is_none(),
        "the database opened"
    );
    assert_eq!(test.connector.calls().len(), 1, "a session opened for the database");
    assert_eq!(tabs[0].followed_catalog(), None);
}

fn postgres() -> std::sync::Arc<dyn tablepro_core::dialect::SqlDialect> {
    std::sync::Arc::new(tablepro_driver_postgres::PgDialect::new(
        &tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0),
    ))
}

/// A PostgreSQL connection that writes what it is sent and answers what
/// a workspace asks as it opens.
fn writing_postgres() -> ConnectionScript {
    let mut connection = answering_script();
    connection.dialect = postgres();
    connection
        .write_batch
        .always(FakeReply::ok(WriteReport::new(vec![None])));
    connection
}

/// A PostgreSQL connection whose own session writes what it is sent,
/// and whose `ANALYTICS` takes `close` to close. `later` answers the
/// connects after those two.
fn dropping_window(name: &str, close: CloseBehaviour, later: Vec<FakeEstablish>) -> TestWindow {
    let mut database = answering_script();
    database.dialect = postgres();
    database.close = close;
    let mut establish = vec![
        FakeEstablish::Connect(writing_postgres()),
        FakeEstablish::Connect(database),
    ];
    establish.extend(later);
    network_window_with(
        name,
        Script {
            establish,
            connection: ConnectionScript {
                dialect: postgres(),
                ..ConnectionScript::default()
            },
            ..Script::default()
        },
    )
}

/// Open `ANALYTICS` beside the connection, with an unsaved edit in it
/// when `edited`, then confirm Drop Database on its row.
fn confirm_dropping_analytics(test: &TestWindow, edited: bool) -> SessionKey {
    connect(test);
    let sibling = analytics(test);
    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    wait_until(WAIT, || test.window.held_session(&sibling).is_some()).expect("the database to open");
    if edited {
        let held = test
            .window
            .workspaces()
            .into_iter()
            .find(|workspace| workspace.key().as_ref() == Some(&sibling))
            .expect("the database's workspace");
        super::sessions::edit_a_table(&held, "events");
    }

    test.window.send(SessionWindowInput::DropDatabaseIn(sibling.clone()));
    wait_for_alert(test, "Drop Database “analytics”?");
    assert!(answer(&test.window, "drop"));
    sibling
}

fn wait_for_alert(test: &TestWindow, heading: &str) {
    wait_until(WAIT, || {
        visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some(heading))
    })
    .unwrap_or_else(|_| panic!("no alert {heading:?}"));
}

fn sent_drop(connection: &tablepro_test_support::FakeConnection) -> bool {
    connection
        .observed_sql("write_batch")
        .iter()
        .flatten()
        .any(|sql| sql.contains("DROP DATABASE \"analytics\""))
}

/// The server refuses to drop a database a session is on, so the
/// window's own session there closes, down to its last connection,
/// before the DROP leaves (0034).
#[gtk4::test]
fn dropping_another_database_closes_it_through_its_prompts_first() {
    let test = dropping_window(
        "DropOtherDatabase",
        CloseBehaviour::Delay(Duration::from_millis(300)),
        Vec::new(),
    );
    let sibling = confirm_dropping_analytics(&test, true);
    wait_for_alert(&test, "Save Changes?");
    let connections = test.connector.connections();
    let (connection, database) = (connections[0].clone(), connections[1].clone());

    assert!(answer(&test.window, "discard"));

    wait_until(WAIT, || sent_drop(&connection)).expect("the drop");
    assert!(
        database.close_finished(),
        "the drop left before the database's session closed"
    );
    assert!(test.window.held_session(&sibling).is_none());
    assert_eq!(test.services.sessions.window_for(&sibling), None);
}

#[gtk4::test]
fn a_cancelled_prompt_drops_nothing() {
    let test = dropping_window("DropOtherDatabaseCancelled", CloseBehaviour::Immediate, Vec::new());
    let sibling = confirm_dropping_analytics(&test, true);
    wait_for_alert(&test, "Save Changes?");

    assert!(answer(&test.window, "cancel"));
    wait_until(WAIT, || visible_alert(&test.window).is_none()).expect("the prompt to close");
    drain_main_context();

    let connection = test.connector.connections()[0].clone();
    assert_eq!(CallCounters::get(&connection.counters().write_batch), 0);
    assert!(
        test.window.held_session(&sibling).is_some(),
        "a cancelled prompt closed the database"
    );
}

/// The connection disconnected and connected again while the database
/// was closing: the new session, perhaps to another server by now, was
/// never asked to drop anything.
#[gtk4::test]
fn a_drop_never_runs_on_a_session_opened_again_under_the_same_key() {
    let test = dropping_window(
        "DropAfterReconnect",
        CloseBehaviour::Delay(Duration::from_secs(3)),
        vec![FakeEstablish::Connect(writing_postgres())],
    );
    confirm_dropping_analytics(&test, false);
    let database = test.connector.connections()[1].clone();
    wait_until(WAIT, || database.is_closed()).expect("the database to start closing");

    test.window.send(SessionWindowInput::DisconnectSession(test.key()));
    test.wait_for_page("picker");
    connect(&test);
    assert!(
        !database.close_finished(),
        "the database closed before the connection came back, so nothing was tested"
    );

    wait_until(WAIT, || database.close_finished()).expect("the database to close");
    let dropped = wait_until(Duration::from_millis(500), || {
        test.connector
            .connections()
            .iter()
            .any(|connection| sent_drop(connection))
    });
    assert!(dropped.is_err(), "a drop confirmed on the old session ran");
}

/// Neither Open Database… nor a tab moving there opens a database on its
/// way to a drop; once the drop has run, it opens again.
#[gtk4::test]
fn a_database_on_its_way_to_a_drop_does_not_open_again() {
    let mut reopened = answering_script();
    reopened.dialect = postgres();
    let test = dropping_window(
        "DropReservesTheDatabase",
        CloseBehaviour::Delay(Duration::from_secs(2)),
        vec![FakeEstablish::Connect(reopened)],
    );
    let sibling = confirm_dropping_analytics(&test, false);
    wait_until(WAIT, || test.window.held_session(&sibling).is_none()).expect("the database to close");
    let connection = test.connector.connections()[0].clone();
    let connects = test.connector.calls().len();

    test.window.open_database(test.saved.id, ANALYTICS.to_owned());
    drain_main_context();

    assert_eq!(
        test.connector.calls().len(),
        connects,
        "the database opened while it was being dropped"
    );
    assert_eq!(test.services.sessions.window_for(&sibling), None);
    wait_until(WAIT, || sent_drop(&connection)).expect("the drop");
    wait_until(WAIT, || {
        test.window.open_database(test.saved.id, ANALYTICS.to_owned());
        test.window.held_session(&sibling).is_some()
    })
    .expect("the database to open once the drop ran");
}

#[test]
fn a_drop_offers_neither_the_connections_database_nor_the_servers_own() {
    let databases = [
        tablepro_core::meta::SchemaInfo {
            name: "postgres".to_owned(),
            is_default: true,
            is_system: false,
        },
        tablepro_core::meta::SchemaInfo {
            name: "template1".to_owned(),
            is_default: false,
            is_system: false,
        },
        tablepro_core::meta::SchemaInfo {
            name: "rdsadmin".to_owned(),
            is_default: false,
            is_system: true,
        },
        tablepro_core::meta::SchemaInfo {
            name: "shop".to_owned(),
            is_default: false,
            is_system: false,
        },
        tablepro_core::meta::SchemaInfo {
            name: "analytics".to_owned(),
            is_default: false,
            is_system: false,
        },
    ];

    let offered =
        super::super::other_databases::droppable(&databases, Some("analytics"), |name| name.starts_with("template"));

    assert_eq!(offered, ["shop"]);
}
