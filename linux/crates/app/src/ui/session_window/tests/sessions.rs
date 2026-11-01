//! Several sessions in one window: every connect runs beside the others
//! and its session joins the shell, a disconnect closes only its own, a
//! failure beside them stays in this window, and the window's close asks
//! about all of them at once.

use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::meta::TableRef;
use tablepro_core::{DriverError, FileEndpoint, LossPhase, Value};
use tablepro_session::fakes::FakeEstablish;
use tablepro_session::{ConnectError, SessionKey};
use tablepro_storage::SavedConnection;
use tablepro_test_support::ConnectionScript;

use super::{Script, TestWindow, WAIT, dialog_submission, pick_level, refused, stored_level};
use crate::application::WindowLaunch;
use crate::runtime::DeliverInput;
use crate::services::change_tracker::RowKey;
use crate::services::save_batch::SaveTarget;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::SessionWindowInput;
use crate::ui::session_window::SessionWindow;
use crate::ui::workspace::{OpenMode, Workspace, WorkspaceInput};
use crate::workspace::test_workspace::integer;
use crate::workspace::{DirtyKind, answer, visible_alert};

/// A second saved connection beside the test's, once the list has it.
fn second_connection(test: &TestWindow) -> SavedConnection {
    saved_beside(test, "Other")
}

fn saved_beside(test: &TestWindow, name: &str) -> SavedConnection {
    let other = SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: name.to_owned(),
        database: test.dir().join(format!("{name}.db")).display().to_string(),
        ..test.saved.clone()
    };
    test.services
        .storage
        .connections()
        .upsert_blocking(other.clone())
        .expect("save the connection");
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

/// A window connected to the test's connection, whose connects after
/// the first one go as `beside` says.
fn connected_then(name: &str, beside: Vec<FakeEstablish>) -> TestWindow {
    let mut establish = vec![FakeEstablish::Connect(ConnectionScript::default())];
    establish.extend(beside);
    let test = TestWindow::with_script(
        name,
        Script {
            establish,
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    test
}

fn toast_titled(window: &SessionWindow, title: &str) -> Option<adw::Toast> {
    window
        .imp()
        .toasts
        .borrow()
        .iter()
        .find(|toast| toast.title().as_deref() == Some(title))
        .cloned()
}

fn holds_page(view: &adw::TabView, page: &adw::TabPage) -> bool {
    (0..view.n_pages()).any(|position| &view.nth_page(position) == page)
}

/// Give `workspace` a table tab with a cell edited and not saved.
fn edit_a_table(workspace: &Workspace, name: &str) {
    let before = workspace.open_tabs().unwrap_or_default();
    workspace
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::SelectTable {
            schema: None,
            name: name.to_owned(),
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
    let tracker =
        crate::ui::workspace::tests::row_tracker(workspace, opened.expect("the tab")).expect("the table's tracker");
    let _ = tracker.set_target(SaveTarget {
        table: TableRef::unqualified(name),
        columns: vec![integer("id", true), integer("n", false)],
    });
    let _ = tracker.apply(TrackerEdit::Cell {
        row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
        col: 1,
        original: Value::Int(1),
        value: tablepro_core::edit::CellInput::Value(Value::Int(2)),
    });
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
    assert_eq!(test.app.windows().len(), 1);
    assert!(test.window.imp().connects.borrow().is_empty());
}

#[gtk4::test]
fn both_sessions_tabs_share_the_one_tab_view() {
    let (test, _) = open_both("SharedTabs");
    let shell = test.window.shell().expect("the shell");

    for workspace in test.window.workspaces() {
        crate::ui::workspace::tests::new_editor_page(&workspace).expect("an editor tab");
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
    assert!(test.window.shell().is_none(), "the shell outlived the last session");
}

#[gtk4::test]
fn disconnecting_a_session_closes_its_tabs() {
    let (test, other) = open_both("DisconnectTabs");
    let shell = test.window.shell().expect("the shell");
    for workspace in test.window.workspaces() {
        crate::ui::workspace::tests::new_editor_page(&workspace).expect("an editor tab");
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
fn two_connects_beside_the_sessions_both_join() {
    let test = connected_then(
        "TwoBeside",
        vec![FakeEstablish::Late {
            after: Duration::from_millis(300),
            script: ConnectionScript::default(),
        }],
    );
    let second = second_connection(&test);
    let third = saved_beside(&test, "Third");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(second.clone())));
    test.window.send(SessionWindowInput::OpenSaved(Box::new(third.clone())));
    wait_until(WAIT, || test.window.workspaces().len() == 3).expect("both connects to join");

    let window = Some(test.window.id());
    assert_eq!(test.services.sessions.window_for(&SessionKey::Saved(second.id)), window);
    assert_eq!(test.services.sessions.window_for(&SessionKey::Saved(third.id)), window);
}

/// It used to start again on the connecting page, which built a second
/// connection and asked again for a password already typed.
#[gtk4::test]
fn f002_a_connect_beside_the_last_session_adopts_from_the_connecting_page_without_connecting_again() {
    let test = connected_then(
        "BesideTheLast",
        vec![FakeEstablish::Late {
            after: Duration::from_millis(300),
            script: ConnectionScript::default(),
        }],
    );
    let other = second_connection(&test);
    let other_key = SessionKey::Saved(other.id);
    test.window.send(SessionWindowInput::OpenSaved(Box::new(other.clone())));
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("the connect beside to reach the driver");

    test.window.send(SessionWindowInput::Disconnect);
    test.wait_for_page("connecting");
    let page = test
        .window
        .content()
        .and_downcast::<crate::ui::session_window::ConnectingPage>()
        .expect("the connecting page");
    assert_eq!(page.status_page().title(), "Connecting to Other");
    wait_until(WAIT, || {
        test.window.workspaces().first().and_then(Workspace::key).as_ref() == Some(&other_key)
    })
    .expect("the connect to join the window");
    drain_main_context();

    assert_eq!(test.connector.calls().len(), 2, "the connect was started again");
    let connections = test.connector.connections();
    assert_eq!(connections.len(), 2);
    assert!(connections[0].is_closed(), "the disconnected session stayed open");
    assert!(!connections[1].is_closed(), "the adopted connection was closed");
    assert_eq!(test.services.sessions.window_for(&other_key), Some(test.window.id()));
    assert_eq!(test.services.sessions.window_for(&test.key()), None);
    assert_eq!(test.services.sessions.live_count(), 1);
}

#[gtk4::test]
fn the_windows_actions_go_to_the_session_in_front() {
    let (test, other) = open_both("ActionsFront");
    let shell = test.window.shell().expect("the shell");
    let other_key = SessionKey::Saved(other.id);
    let joined = test
        .window
        .session_workspace(&other_key)
        .expect("the session that joined");
    let page = crate::ui::workspace::tests::new_editor_page(&joined).expect("a tab of its own");
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

/// The level goes to the session in front when the user picked it,
/// not the one in front once the window handles the choice.
#[gtk4::test]
fn a_safe_mode_level_goes_to_the_session_it_was_picked_for() {
    let (test, other) = open_both("SafeModeTarget");
    let shell = test.window.shell().expect("the shell");
    let (first_key, other_key) = (test.key(), SessionKey::Saved(other.id));
    let tab_of = |key: &SessionKey| {
        crate::ui::workspace::tests::new_editor_page(&test.window.session_workspace(key).expect("the session"))
            .expect("a tab")
    };
    let (first_tab, other_tab) = (tab_of(&first_key), tab_of(&other_key));
    shell.tab_view().set_selected_page(&first_tab);
    let level = |key: &SessionKey| {
        test.window
            .imp()
            .sessions
            .borrow()
            .iter()
            .find(|open| open.claim.key() == key)
            .map(|open| open.session.safe_mode())
    };

    pick_level(&test, "confirm-writes");
    shell.tab_view().set_selected_page(&other_tab);

    wait_until(WAIT, || {
        level(&first_key) == Some(tablepro_core::SafeModeLevel::ConfirmWrites)
    })
    .expect("the level on the session it was picked for");
    assert_eq!(
        level(&other_key),
        Some(tablepro_core::SafeModeLevel::Off),
        "the level moved another connection"
    );
}

#[gtk4::test]
fn new_query_in_opens_an_editor_in_the_session_it_names() {
    let (test, _) = open_both("NewQueryIn");
    let shell = test.window.shell().expect("the shell");

    WidgetExt::activate_action(
        &test.window,
        "win.new-query-in",
        Some(&crate::ui::session_target::to_variant(&test.key())),
    )
    .expect("win.new-query-in");
    wait_until(WAIT, || shell.tab_view().n_pages() == 1).expect("a new tab");

    let added = shell.tab_view().nth_page(0);
    assert_eq!(
        shell.owner_of(&added).and_then(|(workspace, _)| workspace.key()),
        Some(test.key())
    );
}

#[gtk4::test]
fn a_window_close_asks_once_about_every_session_and_cancel_keeps_them_all() {
    let (test, _) = open_both("CloseBothDirty");
    for (workspace, table) in test.window.workspaces().iter().zip(["orders", "stock"]) {
        edit_a_table(workspace, table);
    }

    test.window.close();
    let mut asked = None;
    wait_until(WAIT, || {
        asked = visible_alert(&test.window).filter(|alert| alert.heading().as_deref() == Some("Save Changes?"));
        asked.is_some()
    })
    .expect("the close prompt");
    assert_eq!(
        asked.expect("the prompt").response_label("discard").as_str(),
        "_Discard All",
        "the prompt did not list both sessions' tabs"
    );
    assert!(answer(&test.window, "cancel"));
    wait_until(WAIT, || visible_alert(&test.window).is_none()).expect("the prompt to close");
    drain_main_context();

    assert!(
        visible_alert(&test.window).is_none(),
        "a second session was asked on its own"
    );
    assert_eq!(test.app.windows().len(), 1, "the window closed");
    let workspaces = test.window.workspaces();
    assert_eq!(workspaces.len(), 2, "a session went with the cancelled close");
    assert_eq!(test.services.sessions.live_count(), 2);
    let unsaved = workspaces
        .iter()
        .filter_map(Workspace::handle)
        .flat_map(|handle| handle.dirty_tabs())
        .filter(|tab| tab.kind == DirtyKind::Unsaved)
        .count();
    assert_eq!(unsaved, 2, "a cancelled close discarded a session's edits");
}

/// Connect a second connection that fails as `failure` says, beside the
/// test's, and the toast that says so.
fn failed_beside(name: &str, failure: FakeEstablish) -> (TestWindow, SessionKey, adw::Toast) {
    let test = connected_then(name, vec![failure]);
    let other = second_connection(&test);
    let key = SessionKey::Saved(other.id);

    test.window.send(SessionWindowInput::OpenSaved(Box::new(other)));
    let mut shown = None;
    wait_until(WAIT, || {
        shown = toast_titled(&test.window, "Could not connect to “Other”");
        shown.is_some()
    })
    .expect("the failure's toast");
    (test, key, shown.expect("the toast"))
}

/// The first of two connects fails before either opens: its toast goes
/// to the page that shows the other connect from then on.
#[gtk4::test]
fn a_failure_while_another_connect_runs_toasts_on_the_page_left_on_screen() {
    let test = TestWindow::with_script(
        "FailedWhileConnecting",
        Script {
            establish: vec![refused(), FakeEstablish::UntilCancelled],
            ..Script::default()
        },
    );
    let other = second_connection(&test);
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.window.send(SessionWindowInput::OpenSaved(Box::new(other)));

    let title = format!("Could not connect to “{}”", test.saved.name);
    let on_screen = || {
        test.window.content().is_some_and(|page| {
            crate::test_support::descendants(&page)
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
                .any(|label| label.label() == title)
        })
    };
    wait_until(WAIT, on_screen).expect("the failure's toast on the page on screen");
    assert_eq!(
        test.window.page_name(),
        "connecting",
        "the other connect left the screen"
    );
}

#[gtk4::test]
fn a_failed_connect_beside_the_sessions_opens_no_window_and_toasts() {
    let (test, key, toast) = failed_beside("FailedBeside", refused());
    drain_main_context();

    assert_eq!(test.app.windows().len(), 1, "the failure opened a window of its own");
    assert_eq!(test.window.page_name(), "workspace");
    assert_eq!(test.window.workspaces().len(), 1);
    assert_eq!(
        test.services.sessions.window_for(&key),
        None,
        "the failed connect kept its claim"
    );
    assert!(!toast.uses_markup());
    assert_eq!(toast.button_label().as_deref(), Some("Details"));
    assert_eq!(toast.action_name().as_deref(), Some("win.show-connect-failure"));
    assert_eq!(
        toast.action_target_value(),
        Some(crate::ui::session_target::to_variant(&key))
    );
}

#[gtk4::test]
fn the_details_of_a_failure_beside_offer_its_remedy() {
    let (test, key, _) = failed_beside("FailureDetails", refused());

    WidgetExt::activate_action(
        &test.window,
        "win.show-connect-failure",
        Some(&crate::ui::session_target::to_variant(&key)),
    )
    .expect("win.show-connect-failure");
    let mut shown = None;
    wait_until(WAIT, || {
        shown = visible_alert(&test.window);
        shown.is_some()
    })
    .expect("the Details");
    let details = shown.expect("the dialog");

    assert_eq!(details.heading().as_deref(), Some("Could Not Connect to “Other”"));
    assert!(!details.body().is_empty(), "the Details gave no reason");
    assert!(!details.is_body_use_markup());
    assert_eq!(details.response_label("remedy").as_str(), "Enter Password…");
    assert_eq!(
        details.response_appearance("remedy"),
        adw::ResponseAppearance::Suggested
    );
    assert_eq!(details.close_response(), "close");
    assert!(answer(&test.window, "close"));
    drain_main_context();
    assert_eq!(test.connector.calls().len(), 2, "closing the Details connected again");
}

#[gtk4::test]
fn try_again_in_the_details_connects_beside_the_sessions() {
    let lost = FakeEstablish::Fail(ConnectError::Driver(DriverError::ConnectionLost {
        during: LossPhase::Connect,
    }));
    let (test, key, _) = failed_beside("FailureTryAgain", lost);

    WidgetExt::activate_action(
        &test.window,
        "win.show-connect-failure",
        Some(&crate::ui::session_target::to_variant(&key)),
    )
    .expect("win.show-connect-failure");
    wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the Details");
    assert_eq!(
        visible_alert(&test.window)
            .map(|details| details.response_label("remedy").to_string())
            .as_deref(),
        Some("Try Again")
    );
    assert!(answer(&test.window, "remedy"));

    wait_until(WAIT, || test.window.workspaces().len() == 2).expect("the retry to join the window");
    assert_eq!(test.services.sessions.window_for(&key), Some(test.window.id()));
    assert_eq!(test.app.windows().len(), 1);
}

/// A connect the dialog started beside the sessions shows in the tree
/// and stops from there; its connection, made after the stop, is closed.
#[gtk4::test]
fn f002_stop_connecting_a_dialog_connect_beside_the_sessions_closes_its_late_connection() {
    let test = connected_then(
        "StopDialogConnect",
        vec![FakeEstablish::Late {
            after: Duration::from_millis(300),
            script: ConnectionScript::default(),
        }],
    );
    let submission = dialog_submission(FileEndpoint::create_new(test.dir().join("new.db")).expect("an endpoint"));
    let key = SessionKey::Saved(submission.pending_save.connection.id);

    test.window
        .send(SessionWindowInput::ConnectFromDialog(Box::new(submission)));
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("the connect to reach the driver");
    assert!(
        test.window.keeps_session(&key),
        "the dialog's connect is not the window's"
    );
    WidgetExt::activate_action(
        &test.window,
        "win.stop-connecting",
        Some(&crate::ui::session_target::to_variant(&key)),
    )
    .expect("win.stop-connecting");
    wait_until(WAIT, || !test.window.keeps_session(&key)).expect("the connect to stop");

    assert_eq!(
        test.services.sessions.window_for(&key),
        None,
        "the claim outlived the stop"
    );
    assert_eq!(test.window.page_name(), "workspace");
    wait_until(WAIT, || {
        let connections = test.connector.connections();
        connections.len() == 2 && connections[1].is_closed()
    })
    .expect("the late connection to close");
    drain_main_context();

    assert_eq!(test.window.workspaces().len(), 1, "the stopped connect was adopted");
    assert_eq!(test.app.windows().len(), 1);
    assert_eq!(test.services.sessions.live_count(), 1);
    assert!(toast_titled(&test.window, "Could not connect to “Fake”").is_none());
}

/// It used to stop the dialog's connect and look it up as a saved
/// connection, which it was not yet: "The connection was deleted."
#[gtk4::test]
fn a_safe_mode_reopen_keeps_a_dialog_connect_running() {
    let test = connected_then("ReopenBesideDialog", vec![FakeEstablish::UntilCancelled]);
    let submission = dialog_submission(FileEndpoint::create_new(test.dir().join("new.db")).expect("an endpoint"));
    let key = SessionKey::Saved(submission.pending_save.connection.id);
    test.window
        .send(SessionWindowInput::ConnectFromDialog(Box::new(submission)));
    wait_until(WAIT, || test.connector.calls().len() == 2).expect("the dialog's connect to start");

    pick_level(&test, "read-only");
    wait_until(WAIT, || test.connector.calls().len() == 3).expect("the session to connect again");
    wait_until(WAIT, || test.window.workspaces().len() == 1).expect("the session to join again");
    drain_main_context();

    assert_eq!(stored_level(&test), Some(tablepro_core::SafeModeLevel::ReadOnly));
    assert!(test.connector.calls()[2].request.workspace_settings.read_only);
    assert!(test.window.keeps_session(&key), "the dialog's connect stopped");
    assert_eq!(test.services.sessions.window_for(&key), Some(test.window.id()));
    assert!(toast_titled(&test.window, "The connection was deleted.").is_none());
}

#[gtk4::test]
fn a_tab_dropped_on_another_window_goes_back_to_its_own() {
    let test = TestWindow::connected("ForeignTab");
    let other = second_connection(&test);
    let second = test
        .app
        .open_window(WindowLaunch::Connect(Box::new(other)))
        .and_then(|window| window.downcast::<SessionWindow>().ok())
        .expect("a second window");
    wait_until(WAIT, || second.page_name() == "workspace").expect("the second window's session");
    let page = crate::ui::workspace::tests::new_editor_page(&test.workspace()).expect("a tab");
    let home = test.window.shell().expect("the shell").tab_view();
    let away = second.shell().expect("the second shell").tab_view();

    home.transfer_page(&page, &away, away.n_pages());
    second.send(SessionWindowInput::ReturnForeignTab(page.downgrade().into()));

    wait_until(WAIT, || holds_page(&home, &page) && !holds_page(&away, &page))
        .expect("the tab to go back to its session's window");
}
