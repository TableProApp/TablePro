//! A connection's other databases open beside it and live and go with
//! its session (0030).

use gtk4::prelude::*;
use tablepro_session::SessionKey;
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::{Script, TestWindow, WAIT, pick_level};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::SessionWindowInput;

const ANALYTICS: &str = "analytics";

/// A server connection whose password is stored, which another of its
/// databases opens with, unasked. `establish` is what each connect gets
/// before the test's connection from then on.
fn network_window(name: &str, establish: Vec<FakeEstablish>) -> TestWindow {
    let test = TestWindow::with_script(
        name,
        Script {
            network: true,
            establish,
            ..Script::default()
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

/// The connection connects; another of its databases never answers
/// until its open is stopped.
fn opening_never_ends() -> Vec<FakeEstablish> {
    let mut connection = ConnectionScript::default();
    connection.probe.always(FakeReply::ok(()));
    connection.list_schemas.always(FakeReply::ok(Vec::new()));
    connection.list_objects.always(FakeReply::ok(Vec::new()));
    vec![FakeEstablish::Connect(connection), FakeEstablish::UntilCancelled]
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
