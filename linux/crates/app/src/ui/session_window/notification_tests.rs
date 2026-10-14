use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::export::CsvOptions;
use tablepro_core::{DriverError, EditorSession, TransactionState, WriteKind};
use tablepro_test_support::{FakeEditorSession, FakeReply, FakeRun, Replies};
use uuid::Uuid;

use super::SessionWindowInput;
use super::notification_request::NotificationRequest;
use super::tests::{TestWindow, WAIT, editors};
use super::work_notifier::tests::{Notice, RecordingNotificationSink};
use crate::runtime::DeliverInput;
use crate::services::change_origins::ChangeOrigins;
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::editor::SqlEditor;
use crate::ui::export::{ExportFormat, ExportJob, ExportSource, RowFormat};
use crate::ui::workspace::{OpenMode, WorkspaceInput};
use crate::workspace::{
    CompletedWork, RollbackCause, SaveOutcome, SaveSettled, WorkKind, WorkOutcome, WorkspaceEvent, visible_alert,
};

/// A connected window counted as the active one, whose notifications
/// go to a record.
struct Notified {
    test: TestWindow,
    sink: Rc<RecordingNotificationSink>,
}

/// A connected window counted as the active one, whose every editor run
/// ends as `run` does.
fn active_window(name: &str, run: FakeRun) -> TestWindow {
    let mut runs = Replies::default();
    runs.always(run);
    let session: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));
    let test = TestWindow::connected_with(name, |script| {
        script.open_editor_session.always(FakeReply::ok(session));
    });
    test.window.set_active_for_test(true);
    test
}

/// Open an editor tab, which comes to the front.
fn open_editor_tab(test: &TestWindow) -> (Uuid, SqlEditor) {
    let before = editors(&test.window);
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || editors(&test.window).len() == before.len() + 1).expect("a new editor tab");
    let editor = editors(&test.window)
        .into_iter()
        .find(|editor| !before.contains(editor))
        .expect("the new editor");
    let tab = test.workspace().selected_tab().expect("the new tab in front");
    (tab, editor)
}

/// Run the editor's script and let the window hear how it ended.
fn run(editor: &SqlEditor) {
    editor.run();
    wait_until(WAIT, || !editor.is_running()).expect("the run to end");
    drain_main_context();
}

impl Notified {
    fn new(name: &str, run: FakeRun) -> Self {
        let test = active_window(name, run);
        let sink = Rc::new(RecordingNotificationSink::default());
        test.window.set_notification_sink(sink.clone());
        Self { test, sink }
    }

    fn completing(name: &str) -> Self {
        Self::new(name, FakeRun::completed(Vec::new()))
    }

    fn open_editor_tab(&self) -> (Uuid, SqlEditor) {
        open_editor_tab(&self.test)
    }

    fn run(&self, editor: &SqlEditor) {
        run(editor);
    }

    fn id(&self, tab: Uuid) -> String {
        format!("work-finished-{}-{tab}", self.test.window.id())
    }

    fn wait_for_sent(&self, count: usize) {
        wait_until(WAIT, || self.sink.sent().len() >= count).expect("the notifications");
        drain_main_context();
    }
}

#[gtk4::test]
fn inactive_tab_completion_sends_once() {
    let notified = Notified::completing("NotifyInactiveTab");
    let (first, editor) = notified.open_editor_tab();
    notified.open_editor_tab();

    notified.run(&editor);
    notified.wait_for_sent(1);

    let window_id = notified.test.window.id();
    assert_eq!(
        notified.sink.notices(),
        [Notice::Sent(NotificationRequest {
            id: notified.id(first),
            title: "Query Finished".to_owned(),
            body: "Query 1 · Fake".to_owned(),
            window_id,
            tab: first,
        })],
        "the tab is named by its script, or the run was told twice"
    );
}

#[gtk4::test]
fn active_tab_completion_sends_nothing() {
    let notified = Notified::completing("NotifyActiveTab");
    let (tab, editor) = notified.open_editor_tab();

    notified.run(&editor);
    // The same tab in front, with the user away from the window.
    notified.test.window.set_active_for_test(false);
    notified.run(&editor);
    notified.wait_for_sent(1);

    let sent = notified.sink.sent();
    assert_eq!(sent.len(), 1, "the run the user watched was notified: {sent:?}");
    assert_eq!(sent[0].tab, tab);
}

#[gtk4::test]
fn a_failed_run_says_so_without_its_error() {
    let notified = Notified::new(
        "NotifyFailedRun",
        FakeRun::failed(DriverError::server("password authentication failed for hunter2")),
    );
    let (tab, editor) = notified.open_editor_tab();
    notified.open_editor_tab();

    notified.run(&editor);
    notified.wait_for_sent(1);

    let sent = notified.sink.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!((sent[0].tab, sent[0].title.as_str()), (tab, "Query Failed"));
    assert_eq!(sent[0].body, "Query 1 · Fake");
}

#[gtk4::test]
fn a_stopped_run_sends_nothing() {
    let notified = Notified::new("NotifyStoppedRun", FakeRun::until_stopped());
    let (_, editor) = notified.open_editor_tab();
    notified.open_editor_tab();

    editor.run();
    wait_until(WAIT, || editor.is_running()).expect("the run to start");
    editor.stop();
    wait_until(WAIT, || !editor.is_running()).expect("the run to stop");
    drain_main_context();

    assert!(notified.sink.notices().is_empty(), "{:?}", notified.sink.notices());
}

#[gtk4::test]
fn activating_tab_withdraws() {
    let notified = Notified::completing("NotifyActivateTab");
    let (first, editor) = notified.open_editor_tab();
    notified.open_editor_tab();
    notified.run(&editor);
    notified.wait_for_sent(1);

    let view = notified.test.workspace().imp().tab_view.get();
    view.set_selected_page(&view.nth_page(0));

    wait_until(WAIT, || notified.sink.withdrawn() == [notified.id(first)]).expect("the notification to go");
}

#[gtk4::test]
fn the_window_coming_forward_withdraws_the_tab_in_front() {
    let notified = Notified::completing("NotifyWindowActive");
    notified.test.window.set_active_for_test(false);
    let (tab, editor) = notified.open_editor_tab();
    notified.run(&editor);
    notified.wait_for_sent(1);
    assert!(notified.sink.withdrawn().is_empty());

    notified.test.window.set_active_for_test(true);
    notified.test.window.notify("is-active");

    assert_eq!(notified.sink.withdrawn(), [notified.id(tab)]);
}

#[gtk4::test]
fn closing_a_tab_withdraws_its_notification() {
    let notified = Notified::completing("NotifyCloseTab");
    let (first, editor) = notified.open_editor_tab();
    notified.open_editor_tab();
    notified.run(&editor);
    notified.wait_for_sent(1);

    let view = notified.test.workspace().imp().tab_view.get();
    view.close_page(&view.nth_page(0));

    wait_until(WAIT, || notified.sink.withdrawn() == [notified.id(first)]).expect("the notification to go");
}

#[gtk4::test]
fn teardown_withdraws_all() {
    let notified = Notified::completing("NotifyTeardown");
    notified.test.window.set_active_for_test(false);
    let (first, editor) = notified.open_editor_tab();
    notified.run(&editor);
    let (second, editor) = notified.open_editor_tab();
    notified.run(&editor);
    notified.wait_for_sent(2);

    notified.test.window.send(SessionWindowInput::Disconnect);
    notified.test.wait_for_page("picker");

    let mut withdrawn = notified.sink.withdrawn();
    withdrawn.sort();
    let mut expected = vec![notified.id(first), notified.id(second)];
    expected.sort();
    assert_eq!(withdrawn, expected);
}

#[gtk4::test]
fn a_failed_save_in_a_background_tab_names_only_the_table() {
    let notified = Notified::completing("NotifySave");
    let workspace = notified.test.workspace();
    let input = workspace.input().expect("the workspace's input");
    input.deliver(WorkspaceInput::SelectTable {
        schema: None,
        name: "orders".to_owned(),
        open_mode: OpenMode::NewTab,
    });
    let mut table = None;
    wait_until(WAIT, || {
        table = workspace.selected_tab();
        table.is_some()
    })
    .expect("the table's tab");
    let table = table.expect("the table's tab");
    notified.open_editor_tab();

    input.deliver(WorkspaceInput::Workspace(WorkspaceEvent::SaveSettled(Box::new(
        SaveSettled {
            tab: table,
            kind: WriteKind::RowChanges,
            outcome: SaveOutcome::RolledBack(RollbackCause::Driver(DriverError::server(
                "duplicate key value (id)=(42)",
            ))),
            failing: None,
            saved_table_name: None,
            origins: ChangeOrigins::default(),
        },
    ))));
    notified.wait_for_sent(1);

    let sent = notified.sink.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(
        (sent[0].tab, sent[0].title.as_str(), sent[0].body.as_str()),
        (table, "Changes Not Saved", "orders · Fake")
    );
}

#[gtk4::test]
fn an_export_from_a_background_tab_notifies() {
    let notified = Notified::completing("NotifyExport");
    let (first, _) = notified.open_editor_tab();
    notified.open_editor_tab();
    let exports = notified.test.workspace().exports().expect("the workspace's exports");
    let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("n", ColumnType::untyped_text("text"))].into();

    let _running = exports
        .begin(ExportJob {
            destination: gio::File::for_path(notified.test.dir().join("rows.csv")),
            format: ExportFormat::Rows(RowFormat::Csv(CsvOptions::default())),
            source: ExportSource::Rows {
                columns,
                rows: Vec::new(),
            },
            expected_rows: None,
            tab: Some(first),
        })
        .expect("started");
    notified.wait_for_sent(1);

    let sent = notified.sink.sent();
    assert_eq!(
        (sent[0].tab, sent[0].title.as_str(), sent[0].body.as_str()),
        (first, "Export Finished", "Query 1 · Fake")
    );
}

#[gtk4::test]
fn a_close_prompts_own_saves_are_not_notified() {
    let notified = Notified::new(
        "NotifyPromptSaves",
        FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction),
    );
    let (first, editor) = notified.open_editor_tab();
    notified.run(&editor);
    notified.open_editor_tab();
    assert!(notified.sink.sent().is_empty(), "the run in front was notified");

    notified.test.window.close();
    wait_until(WAIT, || visible_alert(&notified.test.window).is_some()).expect("the close prompt");
    for kind in [WorkKind::Save, WorkKind::Export] {
        notified
            .test
            .window
            .send(SessionWindowInput::WorkCompleted(CompletedWork {
                tab: first,
                kind,
                outcome: WorkOutcome::Succeeded,
            }));
    }
    notified.wait_for_sent(1);

    let titles: Vec<String> = notified.sink.sent().into_iter().map(|sent| sent.title).collect();
    assert_eq!(titles, ["Export Finished"]);
}

#[gtk4::test]
fn focus_tab_action_selects_tab_and_presents_window() {
    let notified = Notified::completing("NotifyFocusTab");
    let (first, _) = notified.open_editor_tab();
    let (second, _) = notified.open_editor_tab();
    let workspace = notified.test.workspace();
    assert_eq!(workspace.selected_tab(), Some(second));
    notified.test.window.set_visible(false);

    notified.test.app.activate_action(
        "focus-tab",
        Some(&(notified.test.window.id(), first.to_string()).to_variant()),
    );

    wait_until(WAIT, || workspace.selected_tab() == Some(first)).expect("the tab to come to the front");
    assert!(notified.test.window.is_visible(), "the window was not presented");
}

#[gtk4::test]
fn focus_tab_action_for_a_gone_window_or_tab_brings_tablepro_forward() {
    let notified = Notified::completing("NotifyFocusGone");
    let (tab, _) = notified.open_editor_tab();
    let workspace = notified.test.workspace();
    let window_id = notified.test.window.id();

    for (target_window, target_tab) in [
        (window_id + 100, Uuid::new_v4().to_string()),
        (window_id, "not a tab".to_owned()),
        (window_id, Uuid::new_v4().to_string()),
    ] {
        notified.test.window.set_visible(false);
        notified
            .test
            .app
            .activate_action("focus-tab", Some(&(target_window, target_tab).to_variant()));
        wait_until(WAIT, || notified.test.window.is_visible()).expect("TablePro to come forward");
        drain_main_context();
        assert_eq!(workspace.selected_tab(), Some(tab));
    }
}

/// A notification server on the session bus, as GNOME Shell or a
/// notification daemon is, on a connection of its own. Every test on
/// the bus can reach it, so a test reads only its own application's
/// calls.
struct NotificationServer {
    connection: gio::DBusConnection,
    calls: Rc<RefCell<Vec<ServerCall>>>,
    registration: Option<gio::RegistrationId>,
}

#[derive(Debug, Clone)]
enum ServerCall {
    Notify {
        /// The application id, from the `desktop-entry` hint.
        app: String,
        id: u32,
        summary: String,
        body: String,
        actions: Vec<String>,
    },
    Close(u32),
}

const NOTIFICATIONS: &str = "org.freedesktop.Notifications";
const NOTIFICATIONS_PATH: &str = "/org/freedesktop/Notifications";
const NOTIFICATIONS_XML: &str = r#"<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" name="app_name" direction="in"/>
      <arg type="u" name="replaces_id" direction="in"/>
      <arg type="s" name="app_icon" direction="in"/>
      <arg type="s" name="summary" direction="in"/>
      <arg type="s" name="body" direction="in"/>
      <arg type="as" name="actions" direction="in"/>
      <arg type="a{sv}" name="hints" direction="in"/>
      <arg type="i" name="expire_timeout" direction="in"/>
      <arg type="u" name="id" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="GetCapabilities">
      <arg type="as" name="capabilities" direction="out"/>
    </method>
    <method name="GetServerInformation">
      <arg type="s" name="name" direction="out"/>
      <arg type="s" name="vendor" direction="out"/>
      <arg type="s" name="version" direction="out"/>
      <arg type="s" name="spec_version" direction="out"/>
    </method>
    <signal name="ActionInvoked">
      <arg type="u" name="id"/>
      <arg type="s" name="action_key"/>
    </signal>
    <signal name="NotificationClosed">
      <arg type="u" name="id"/>
      <arg type="u" name="reason"/>
    </signal>
  </interface>
</node>"#;

impl NotificationServer {
    fn start() -> Self {
        let address =
            gio::dbus_address_get_for_bus_sync(gio::BusType::Session, gio::Cancellable::NONE).expect("the session bus");
        let connection = gio::DBusConnection::for_address_sync(
            &address,
            gio::DBusConnectionFlags::AUTHENTICATION_CLIENT | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
            None,
            gio::Cancellable::NONE,
        )
        .expect("a connection of the server's own");
        let node = gio::DBusNodeInfo::for_xml(NOTIFICATIONS_XML).expect("the interface description");
        let interface = node.lookup_interface(NOTIFICATIONS).expect("the interface");
        let calls = Rc::new(RefCell::new(Vec::new()));
        let log = calls.clone();
        let next_id = std::cell::Cell::new(0u32);
        let registration = connection
            .register_object(NOTIFICATIONS_PATH, &interface)
            .method_call(move |_, _, _, _, method, parameters, invocation| match method {
                "Notify" => {
                    let text = |index| parameters.child_value(index).get::<String>().unwrap_or_default();
                    // A replaced notification keeps its id.
                    let replaces = parameters.child_value(1).get::<u32>().unwrap_or_default();
                    let id = match replaces {
                        0 => {
                            next_id.set(next_id.get() + 1);
                            next_id.get()
                        }
                        id => id,
                    };
                    let app = glib::VariantDict::new(Some(&parameters.child_value(6)))
                        .lookup_value("desktop-entry", Some(glib::VariantTy::STRING))
                        .and_then(|entry| entry.get::<String>())
                        .unwrap_or_default();
                    log.borrow_mut().push(ServerCall::Notify {
                        app,
                        id,
                        summary: text(3),
                        body: text(4),
                        actions: parameters.child_value(5).get::<Vec<String>>().unwrap_or_default(),
                    });
                    invocation.return_value(Some(&(id,).to_variant()));
                }
                "CloseNotification" => {
                    let id = parameters.child_value(0).get::<u32>().unwrap_or_default();
                    log.borrow_mut().push(ServerCall::Close(id));
                    invocation.return_value(None);
                }
                "GetCapabilities" => {
                    invocation.return_value(Some(&(vec!["actions".to_owned(), "body".to_owned()],).to_variant()));
                }
                _ => invocation.return_value(Some(&("Fake", "TablePro", "1", "1.2").to_variant())),
            })
            .build()
            .expect("the server's object");
        let owner = connection
            .call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "RequestName",
                Some(&(NOTIFICATIONS, 4u32).to_variant()),
                Some(glib::VariantTy::new("(u)").expect("a reply type")),
                gio::DBusCallFlags::NONE,
                -1,
                gio::Cancellable::NONE,
            )
            .expect("the server's name");
        assert_eq!(
            owner.child_value(0).get::<u32>(),
            Some(1),
            "another server owns the name"
        );
        Self {
            connection,
            calls,
            registration: Some(registration),
        }
    }

    /// The calls about `app_id`'s notifications.
    fn calls_from(&self, app_id: &str) -> Vec<ServerCall> {
        let calls = self.calls.borrow();
        let ours: Vec<u32> = calls
            .iter()
            .filter_map(|call| match call {
                ServerCall::Notify { app, id, .. } if app == app_id => Some(*id),
                _ => None,
            })
            .collect();
        calls
            .iter()
            .filter(|call| match call {
                ServerCall::Notify { app, .. } => app == app_id,
                ServerCall::Close(id) => ours.contains(id),
            })
            .cloned()
            .collect()
    }

    /// What clicking notification `id` sends.
    fn click(&self, id: u32) {
        self.connection
            .emit_signal(
                None,
                NOTIFICATIONS_PATH,
                NOTIFICATIONS,
                "ActionInvoked",
                Some(&(id, "default").to_variant()),
            )
            .expect("the click");
    }
}

impl Drop for NotificationServer {
    fn drop(&mut self) {
        if let Some(registration) = self.registration.take() {
            let _ = self.connection.unregister_object(registration);
        }
        let _ = self.connection.close_sync(gio::Cancellable::NONE);
    }
}

#[gtk4::test]
fn a_notification_reaches_the_desktop_and_a_click_brings_its_tab_forward() {
    let server = NotificationServer::start();
    let test = active_window("NotifyDesktop", FakeRun::completed(Vec::new()));
    let app_id = test
        .app
        .application_id()
        .expect("the test's application id")
        .to_string();
    let (first, editor) = open_editor_tab(&test);
    open_editor_tab(&test);

    run(&editor);
    wait_until(WAIT, || !server.calls_from(&app_id).is_empty()).expect("the notification on the bus");
    let ServerCall::Notify {
        id,
        summary,
        body,
        actions,
        ..
    } = server.calls_from(&app_id).remove(0)
    else {
        panic!("{:?}", server.calls_from(&app_id));
    };
    assert_eq!((summary.as_str(), body.as_str()), ("Query Finished", "Query 1 · Fake"));
    assert!(actions.iter().any(|action| action == "default"), "{actions:?}");

    server.click(id);

    wait_until(WAIT, || test.workspace().selected_tab() == Some(first)).expect("the click to bring the tab forward");
}
