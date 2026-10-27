//! Several sessions in one window: a connection opened while the window
//! shows its sessions joins them, and a disconnect closes only its own.

use std::time::Duration;

use gtk4::prelude::*;
use tablepro_session::SessionKey;
use tablepro_session::fakes::FakeEstablish;
use tablepro_storage::SavedConnection;
use tablepro_test_support::ConnectionScript;

use super::{Script, TestWindow, WAIT};
use crate::test_support::{drain_main_context, wait_until};
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
        Some(test.key()),
        "the session that joined took the front with no tab on screen"
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

#[gtk4::test]
fn disconnecting_a_session_closes_its_tabs() {
    let (test, other) = open_both("DisconnectTabs");
    let shell = test.window.shell().expect("the shell");
    for workspace in test.window.workspaces() {
        workspace.create_editor_page().expect("an editor tab");
    }

    test.window
        .send(SessionWindowInput::DisconnectSession(SessionKey::Saved(other.id)));
    wait_until(WAIT, || test.window.workspaces().len() == 1).expect("one session to go");

    assert_eq!(shell.tab_view().n_pages(), 1, "the session's tab stayed in the bar");
    let left = shell.tab_view().nth_page(0);
    assert_eq!(
        shell.owner_of(&left).and_then(|(workspace, _)| workspace.key()),
        Some(test.key()),
        "the tab left is not the first session's"
    );
}

#[gtk4::test]
fn tabs_name_their_connection_while_another_shares_the_window() {
    let (test, other) = open_both("TabTitles");
    let first = test.window.workspaces().into_iter().next().expect("the first session");
    let page = first.create_editor_page().expect("an editor tab");
    wait_until(WAIT, || page.title().ends_with(" · Fake")).expect("the tab to name its connection");
    assert_eq!(page.keyword().as_deref(), Some("Fake"));

    test.window
        .send(SessionWindowInput::DisconnectSession(SessionKey::Saved(other.id)));
    wait_until(WAIT, || !page.title().contains(" · Fake")).expect("the tab to drop the name with one session left");
}

#[gtk4::test]
fn two_connects_beside_the_sessions_both_join() {
    let test = TestWindow::with_script(
        "TwoBeside",
        Script {
            establish: vec![
                FakeEstablish::Connect(ConnectionScript::default()),
                FakeEstablish::Late {
                    after: Duration::from_millis(300),
                    script: ConnectionScript::default(),
                },
            ],
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let second = second_connection(&test);
    let third = SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: "Third".to_owned(),
        database: test.dir().join("third.db").display().to_string(),
        ..test.saved.clone()
    };
    test.services
        .storage
        .connections()
        .upsert_blocking(third.clone())
        .expect("save the third connection");
    wait_until(WAIT, || test.services.saved_connections.get(third.id).is_some()).expect("the list to have it");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(second.clone())));
    test.window.send(SessionWindowInput::OpenSaved(Box::new(third.clone())));
    wait_until(WAIT, || test.window.workspaces().len() == 3).expect("both connects to join");

    let window = Some(test.window.id());
    assert_eq!(test.services.sessions.window_for(&SessionKey::Saved(second.id)), window);
    assert_eq!(test.services.sessions.window_for(&SessionKey::Saved(third.id)), window);
}

#[gtk4::test]
fn f002_a_connect_beside_the_last_session_carries_on_and_its_stopped_result_closes() {
    let test = TestWindow::with_script(
        "BesideTheLast",
        Script {
            establish: vec![
                FakeEstablish::Connect(ConnectionScript::default()),
                FakeEstablish::Late {
                    after: Duration::from_millis(300),
                    script: ConnectionScript::default(),
                },
            ],
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let other = second_connection(&test);
    let other_key = SessionKey::Saved(other.id);
    test.window.send(SessionWindowInput::OpenSaved(Box::new(other.clone())));
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("the connect beside to reach the driver");

    test.window.send(SessionWindowInput::Disconnect);
    wait_until(WAIT, || {
        test.window
            .workspaces()
            .first()
            .and_then(crate::ui::workspace::Workspace::key)
            == Some(other_key.clone())
    })
    .expect("the connect to carry on as the window's own");
    // The first session's, closed by the disconnect, and the stopped
    // connect's, which landed after the one that carried on.
    wait_until(WAIT, || {
        let connections = test.connector.connections();
        connections.len() == 3 && connections.iter().filter(|connection| connection.is_closed()).count() == 2
    })
    .expect("the stopped connect's late connection to close");
    drain_main_context();

    assert_eq!(test.window.workspaces().len(), 1);
    assert_eq!(test.services.sessions.window_for(&other_key), Some(test.window.id()));
    assert_eq!(test.services.sessions.window_for(&test.key()), None);
    assert_eq!(test.services.sessions.live_count(), 1);
}

#[gtk4::test]
fn the_windows_actions_go_to_the_session_in_front() {
    let (test, other) = open_both("ActionsFront");
    let shell = test.window.shell().expect("the shell");
    let other_key = SessionKey::Saved(other.id);
    let joined = shell.session(&other_key).expect("the session that joined");
    let page = joined.create_editor_page().expect("a tab of its own");
    shell.tab_view().set_selected_page(&page);
    wait_until(WAIT, || {
        shell.front().and_then(|front| front.key()) == Some(other_key.clone())
    })
    .expect("the session to come to the front with its tab");
    let before = shell.tab_view().n_pages();

    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("the window's action");
    wait_until(WAIT, || shell.tab_view().n_pages() == before + 1).expect("a new tab");

    let added = shell.tab_view().selected_page().expect("the new tab in front");
    assert_eq!(
        shell.owner_of(&added).and_then(|(workspace, _)| workspace.key()),
        Some(other_key),
        "the action went to a session behind"
    );
}
