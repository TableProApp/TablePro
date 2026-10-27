//! Several sessions in one window: a connection opened while the window
//! shows its sessions joins them, and a disconnect closes only its own.

use gtk4::prelude::*;
use tablepro_session::SessionKey;
use tablepro_storage::SavedConnection;

use super::{TestWindow, WAIT};
use crate::test_support::wait_until;
use crate::ui::SessionWindowInput;

/// A second saved connection beside the test's, once the list has it.
fn second_connection(test: &TestWindow) -> SavedConnection {
    let other = SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: "Other".to_owned(),
        database: test.dir().join("other.db").display().to_string(),
        ..test.saved.clone()
    };
    test.services
        .storage
        .connections()
        .upsert_blocking(other.clone())
        .expect("save the second connection");
    wait_until(WAIT, || test.services.saved_connections.get(other.id).is_some()).expect("the list to have it");
    other
}

fn open_both(name: &str) -> (TestWindow, SavedConnection) {
    let test = TestWindow::connected(name);
    let other = second_connection(&test);
    test.window.send(SessionWindowInput::OpenSaved(Box::new(other.clone())));
    wait_until(WAIT, || test.window.workspaces().len() == 2).expect("the second session to join");
    (test, other)
}

#[gtk4::test]
fn a_second_connection_joins_the_window_beside_the_first() {
    let (test, other) = open_both("SecondJoins");

    assert_eq!(test.window.page_name(), "workspace");
    let sessions = &test.services.sessions;
    assert_eq!(sessions.window_for(&test.key()), Some(test.window.id()));
    assert_eq!(
        sessions.window_for(&SessionKey::Saved(other.id)),
        Some(test.window.id())
    );
    let shell = test.window.shell().expect("the shell");
    assert_eq!(shell.sessions().len(), 2);
    assert_eq!(
        shell.front().and_then(|front| front.key()),
        Some(SessionKey::Saved(other.id)),
        "the session that joined is not in front"
    );
    wait_until(WAIT, || shell.tree_open_connections() == ["Fake", "Other"])
        .expect("the tree to mark both connections open");
}

#[gtk4::test]
fn both_sessions_tabs_share_the_one_tab_view() {
    let (test, _) = open_both("SharedTabs");
    let shell = test.window.shell().expect("the shell");

    for workspace in test.window.workspaces() {
        workspace.create_editor_page().expect("an editor tab");
    }

    assert_eq!(shell.tab_view().n_pages(), 2);
    let owners: Vec<_> = (0..2)
        .filter_map(|position| shell.owner_of(&shell.tab_view().nth_page(position)))
        .map(|(workspace, _)| workspace.key())
        .collect();
    assert_eq!(owners.len(), 2, "a tab no session owns");
    assert_ne!(owners[0], owners[1], "both tabs went to one session");
}

#[gtk4::test]
fn disconnecting_one_session_keeps_the_other() {
    let (test, other) = open_both("DisconnectOne");
    let other_key = SessionKey::Saved(other.id);

    test.window
        .send(SessionWindowInput::DisconnectSession(other_key.clone()));
    wait_until(WAIT, || test.window.workspaces().len() == 1).expect("one session to go");

    assert_eq!(test.window.page_name(), "workspace");
    assert_eq!(
        test.services.sessions.window_for(&other_key),
        None,
        "the claim outlived the session"
    );
    assert_eq!(test.services.sessions.window_for(&test.key()), Some(test.window.id()));
    let shell = test.window.shell().expect("the shell");
    assert_eq!(shell.front().and_then(|front| front.key()), Some(test.key()));
    wait_until(WAIT, || shell.tree_open_connections() == ["Fake"]).expect("the tree to mark only the first open");
}

#[gtk4::test]
fn disconnecting_the_last_session_returns_to_the_picker() {
    let (test, other) = open_both("DisconnectBoth");

    test.window
        .send(SessionWindowInput::DisconnectSession(SessionKey::Saved(other.id)));
    wait_until(WAIT, || test.window.workspaces().len() == 1).expect("one session to go");
    test.window.send(SessionWindowInput::Disconnect);
    test.wait_for_page("picker");

    assert_eq!(test.services.sessions.window_for(&test.key()), None);
}
