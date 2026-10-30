use std::sync::Arc;
use std::time::Duration;

use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::{DriverError, EditorSession, ResultEvent, TransactionState, Truncation, Value};
use tablepro_session::Session;
use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
use tablepro_session::operation::DefaultDeadlines;
use tablepro_test_support::{ConnectionScript, FakeEditorSession, FakeReply, FakeRun, Replies};

use super::*;
use crate::services::history_preferences::HistoryPreferences;
use crate::test_support::{MemorySettings, SignalLog, wait_until};
use crate::ui::data_grid::DataGrid;

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    editor: SqlEditor,
    fake: Arc<FakeEditorSession>,
    history: Option<HistoryService>,
    active: ActiveSession,
    settings: MemorySettings,
    runtime: crate::runtime::AppRuntime,
}

fn session_with(fake: Arc<FakeEditorSession>, tasks: Tasks) -> Arc<Session> {
    session_on(fake, tasks, ConnectionScript::default())
}

fn session_on(fake: Arc<FakeEditorSession>, tasks: Tasks, mut script: ConnectionScript) -> Arc<Session> {
    let editor: Arc<dyn EditorSession> = fake;
    script.open_editor_session.always(FakeReply::ok(editor));
    let request = FakeConnector::request().expect("a request");
    let (pending, _) = FakeConnector::pending_session(request, script);
    Session::start(
        pending,
        tablepro_session::SessionDeps {
            connector: Arc::new(FakeConnector::new([])),
            credentials: Arc::new(FakeCredentialSource::new()),
            deadlines: Arc::new(DefaultDeadlines::new(tablepro_core::LivenessPolicy::DESKTOP)),
            tasks,
            prompter: None,
        },
    )
}

fn editor_with(runs: Replies<FakeRun>, text: &str) -> Harness {
    build_editor(runs, text, |_| None)
}

fn build_editor(runs: Replies<FakeRun>, text: &str, history: impl FnOnce(&Tasks) -> Option<HistoryService>) -> Harness {
    build_editor_on(MemorySettings::new(), runs, text, history)
}

fn build_editor_on(
    settings: MemorySettings,
    runs: Replies<FakeRun>,
    text: &str,
    history: impl FnOnce(&Tasks) -> Option<HistoryService>,
) -> Harness {
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let fake = Arc::new(FakeEditorSession::new(runs));
    let active = ActiveSession::new();
    active.replace(session_with(fake.clone(), runtime.tasks()));
    let history = history(&runtime.tasks());
    let editor = SqlEditor::new(SqlEditorInit {
        initial_query: Some(text.to_owned()),
        settings: settings.get().clone(),
        history: history.clone(),
        tasks: runtime.tasks(),
        session: active.clone(),
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
        close_timeout: Duration::from_secs(5),
        snippets: crate::test_support::builtin_snippets_only(),
    });
    Harness {
        editor,
        fake,
        history,
        active,
        settings,
        runtime,
    }
}

/// An editor whose runs go into a real history under `root`.
fn editor_with_history(root: &tempfile::TempDir, text: &str) -> Harness {
    editor_with_history_runs(root, answering(), text)
}

fn editor_with_history_runs(root: &tempfile::TempDir, runs: Replies<FakeRun>, text: &str) -> Harness {
    let paths = tablepro_storage::StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
    build_editor(runs, text, |tasks| {
        let preferences = HistoryPreferences {
            retention_days: tokio::sync::watch::channel(30).1,
            save: tokio::sync::watch::channel(true).1,
        };
        Some(HistoryService::start(paths, preferences, tasks))
    })
}

fn answering() -> Replies<FakeRun> {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    runs
}

fn sent(fake: &FakeEditorSession) -> Vec<String> {
    fake.texts().iter().map(|sql| sql.as_str().to_owned()).collect()
}

fn run_and_wait(harness: &Harness) {
    harness.editor.run();
    assert!(harness.editor.is_running(), "the run did not start");
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");
}

#[gtk4::test]
fn selected_text_is_the_only_sql_sent() {
    let harness = editor_with(answering(), "SELECT 1;\nSELECT 2;\nSELECT 3;");
    let buffer = harness.editor.buffer();
    let start = buffer.iter_at_offset(10);
    let end = buffer.iter_at_offset(18);
    buffer.select_range(&start, &end);
    assert_eq!(
        harness.editor.imp().run_button.label().as_deref(),
        Some("Run Selection")
    );

    run_and_wait(&harness);

    assert_eq!(sent(&harness.fake), ["SELECT 2"]);
}

#[gtk4::test]
fn only_a_run_that_sent_ddl_says_the_catalog_changed() {
    let harness = editor_with(answering(), "SELECT 1;");
    run_and_wait(&harness);
    assert!(
        !harness.editor.last_run_changes_catalog(),
        "a SELECT changed the catalog"
    );

    harness
        .editor
        .buffer()
        .set_text("SELECT 1;\nCREATE TABLE orders (id int);");
    run_and_wait(&harness);
    assert!(harness.editor.last_run_changes_catalog());

    harness
        .editor
        .buffer()
        .set_text("UPDATE orders SET id = 2 WHERE id = 1;");
    run_and_wait(&harness);
    assert!(
        !harness.editor.last_run_changes_catalog(),
        "the last run's answer outlived it"
    );
}

/// The editor in a window, which the Safe Mode question is shown over.
fn shown(harness: &Harness) -> crate::test_support::OwnedWindow<adw::Window> {
    crate::test_support::OwnedWindow::presented(adw::Window::builder().content(&harness.editor).build())
}

#[gtk4::test]
fn confirm_writes_holds_an_update_for_an_answer_and_runs_a_select_at_once() {
    let harness = editor_with(answering(), "SELECT 1;");
    let session = harness.active.get().expect("the session");
    assert!(session.set_safe_mode(tablepro_core::SafeModeLevel::ConfirmWrites));
    let window = shown(&harness);

    run_and_wait(&harness);
    assert_eq!(sent(&harness.fake), ["SELECT 1"]);

    harness
        .editor
        .buffer()
        .set_text("UPDATE orders SET total = 0 WHERE id = 1;");
    harness.editor.run();
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
    assert!(!harness.editor.is_running(), "the run started before the answer");
    harness.editor.run();
    assert_eq!(sent(&harness.fake), ["SELECT 1"]);

    assert!(crate::workspace::answer(&window, "proceed"));
    wait_until(WAIT, || sent(&harness.fake).len() == 2).expect("the update to go");
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");
    assert_eq!(
        sent(&harness.fake),
        ["SELECT 1", "UPDATE orders SET total = 0 WHERE id = 1"]
    );
}

#[gtk4::test]
fn cancelling_the_question_sends_nothing() {
    let harness = editor_with(answering(), "DELETE FROM orders;");
    let window = shown(&harness);

    harness.editor.run();
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
    assert!(crate::workspace::answer(&window, "cancel"));
    wait_until(WAIT, || !harness.editor.imp().confirming.get()).expect("the answer");
    crate::test_support::drain_main_context();

    assert!(sent(&harness.fake).is_empty(), "a cancelled DELETE was sent");
    assert!(!harness.editor.is_running());
}

#[gtk4::test]
fn read_only_refuses_a_write_without_sending_it() {
    let harness = editor_with(
        answering(),
        "SELECT 1;\nUPDATE orders SET total = 0 WHERE id = 1;\nSELECT 2;",
    );
    harness.active.replace(session_on(
        harness.fake.clone(),
        harness.runtime.tasks(),
        ConnectionScript {
            read_only: true,
            ..ConnectionScript::default()
        },
    ));

    run_and_wait(&harness);

    assert_eq!(sent(&harness.fake), ["SELECT 1"]);
    let log = harness.editor.imp().log.borrow();
    assert_eq!(
        log.as_ref().and_then(|log| log.first_failure()),
        Some("Safe Mode is Read-Only on this connection. Choose another level in the main menu to make changes.")
    );
}

#[gtk4::test]
fn run_at_cursor_selects_executed_statement() {
    let harness = editor_with(answering(), "SELECT 'tên';\nSELECT 2 FROM t;\nSELECT 3;");
    let buffer = harness.editor.buffer();
    buffer.place_cursor(&buffer.iter_at_offset(20));

    harness.editor.run_at_cursor();
    assert!(harness.editor.is_running(), "the run did not start");
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");

    assert_eq!(sent(&harness.fake), ["SELECT 2 FROM t"]);
    let (start, end) = buffer.selection_bounds().expect("the statement is selected");
    assert_eq!((start.offset(), end.offset()), (14, 29));
}

#[gtk4::test]
fn run_at_cursor_during_a_run_leaves_the_buffer_alone() {
    let mut runs = Replies::default();
    runs.always(FakeRun::until_stopped());
    let harness = editor_with(runs, "SELECT pg_sleep(60);\nSELECT 2;");
    let buffer = harness.editor.buffer();
    harness.editor.run();
    wait_until(WAIT, || !harness.fake.texts().is_empty()).expect("the first statement to start");
    let sent_before = sent(&harness.fake);
    buffer.place_cursor(&buffer.iter_at_offset(23));

    harness.editor.run_at_cursor();

    assert!(
        buffer.selection_bounds().is_none(),
        "a statement that did not run was selected"
    );
    assert_eq!(sent(&harness.fake), sent_before);
    harness.editor.stop();
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");
}

#[gtk4::test]
fn a_script_fills_the_results_list_one_line_per_statement() {
    let mut runs = Replies::default();
    runs.when_sql_contains(
        "boom",
        FakeRun::failed(DriverError::server("relation \"boom\" does not exist")),
    );
    runs.always(FakeRun::completed(Vec::new()));
    let harness = editor_with(runs, "SELECT 1; SELECT * FROM boom; SELECT 3");
    let states = SignalLog::connect(&harness.editor, "run-state-changed", |values| {
        values[1].get::<bool>().expect("a flag")
    });

    run_and_wait(&harness);

    let results = &harness.editor.imp().results;
    assert_eq!(results.n_entries(), 3);
    assert_eq!(results.selected(), Some(1), "the failure is not what shows");
    assert_eq!(sent(&harness.fake), ["SELECT 1", "SELECT * FROM boom"]);
    assert_eq!(states.take(), [true, false]);
    assert!(harness.editor.imp().run_button.is_sensitive());
}

/// Ctrl+Return leaves the focus in the editor, so the summary is said.
#[gtk4::test]
fn a_finished_run_says_how_it_went() {
    let mut runs = Replies::default();
    runs.when_sql_contains(
        "boom",
        FakeRun::failed(DriverError::server("relation \"boom\" does not exist")),
    );
    runs.always(FakeRun::completed(Vec::new()));
    let harness = editor_with(runs, "SELECT 1");

    run_and_wait(&harness);
    harness.editor.buffer().set_text("SELECT * FROM boom");
    run_and_wait(&harness);

    let said: Vec<(bool, gtk4::AccessibleAnnouncementPriority)> = crate::ui::a11y::announced_in(&harness.editor)
        .into_iter()
        .map(|(message, priority)| (message.contains("failed"), priority))
        .collect();
    assert_eq!(
        said,
        [
            (false, gtk4::AccessibleAnnouncementPriority::Medium),
            (true, gtk4::AccessibleAnnouncementPriority::High),
        ]
    );
}

#[gtk4::test]
fn a_long_script_that_fails_early_builds_one_result_page() {
    let mut runs = Replies::default();
    runs.when_sql_contains(
        "boom",
        FakeRun::failed(DriverError::server("relation \"boom\" does not exist")),
    );
    runs.always(FakeRun::completed(Vec::new()));
    let script: Vec<String> = std::iter::once("SELECT * FROM boom;".to_owned())
        .chain((1..2_000).map(|n| format!("SELECT {n};")))
        .collect();
    let harness = editor_with(runs, &script.join("\n"));

    run_and_wait(&harness);

    let results = &harness.editor.imp().results;
    assert_eq!(results.n_entries(), 2_000);
    assert_eq!(
        results.imp().stack.pages().n_items(),
        2,
        "pages were built for lines nobody opened"
    );
}

#[gtk4::test]
fn an_open_transaction_marks_the_tab() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
    let harness = editor_with(runs, "BEGIN; UPDATE t SET a = 1 WHERE id = 1");
    let changes = SignalLog::connect(&harness.editor, "transaction-changed", |values| {
        values[1].get::<bool>().expect("a flag")
    });

    run_and_wait(&harness);

    assert!(harness.editor.has_open_transaction());
    assert_eq!(changes.take(), [true]);
}

// With a WHERE clause, so Safe Mode runs it without asking.
const OPENS_A_TRANSACTION: &str = "BEGIN; UPDATE t SET a = 1 WHERE id = 1";

/// The script opens a transaction, and COMMIT or ROLLBACK ends it.
fn transaction_runs() -> Replies<FakeRun> {
    let mut runs = Replies::default();
    runs.when_sql_contains("COMMIT", FakeRun::completed(Vec::new()))
        .when_sql_contains("ROLLBACK", FakeRun::completed(Vec::new()))
        .always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
    runs
}

fn button_labelled(harness: &Harness, label: &str) -> gtk4::Button {
    crate::test_support::descendants(&harness.editor)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
        .find(|button| button.label().as_deref() == Some(label))
        .expect("the button")
}

/// It and every container up to the editor are visible.
fn widget_shown(harness: &Harness, widget: &impl IsA<gtk4::Widget>) -> bool {
    hidden_ancestor(harness, widget).is_none()
}

/// The first of it and its containers up to the editor that is hidden, by type, for a failure message.
/// Each widget's own flag: `is_visible` also asks the window, which these tests never show.
fn hidden_ancestor(harness: &Harness, widget: &impl IsA<gtk4::Widget>) -> Option<String> {
    let editor = harness.editor.upcast_ref::<gtk4::Widget>();
    std::iter::successors(Some(widget.as_ref().clone()), |widget| widget.parent())
        .take_while(|widget| widget != editor)
        .find(|widget| !widget.get_visible())
        .map(|widget| format!("{} {:?}", widget.type_().name(), widget.widget_name()))
}

#[gtk4::test]
fn commit_runs_on_the_tabs_session_and_keeps_the_script() {
    let harness = editor_with(transaction_runs(), OPENS_A_TRANSACTION);
    let _window = InWindow::new(&harness.editor);
    run_and_wait(&harness);
    let before = sent(&harness.fake);
    let commit = button_labelled(&harness, "Commit");
    assert_eq!(hidden_ancestor(&harness, &commit), None);
    assert!(commit.is_sensitive(), "Commit is off with a transaction open");
    assert_eq!(hidden_ancestor(&harness, &button_labelled(&harness, "Roll Back")), None);

    commit.emit_clicked();
    assert!(harness.editor.is_running(), "Commit did not start a run");
    assert!(!commit.is_sensitive(), "Commit stayed on during the run");
    wait_until(WAIT, || !harness.editor.is_running()).expect("the commit to end");

    assert_eq!(sent(&harness.fake), [before, vec!["COMMIT".to_owned()]].concat());
    assert_eq!(buffer_text(&harness.editor.buffer()), OPENS_A_TRANSACTION);
    assert!(!harness.editor.has_open_transaction());
    assert_eq!(harness.editor.open_transaction(), None);
    assert!(!widget_shown(&harness, &commit), "the line outlived the transaction");
    assert_eq!(
        harness.editor.imp().results.n_entries(),
        1,
        "the results are not the COMMIT's"
    );
}

#[gtk4::test]
fn a_failed_transaction_offers_only_roll_back() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::Failed));
    let harness = editor_with(runs, OPENS_A_TRANSACTION);
    let _window = InWindow::new(&harness.editor);

    run_and_wait(&harness);

    assert_eq!(harness.editor.open_transaction(), Some(OpenTransaction::Failed));
    assert_eq!(hidden_ancestor(&harness, &button_labelled(&harness, "Roll Back")), None);
    assert!(!widget_shown(&harness, &button_labelled(&harness, "Commit")));
}

fn roll_back_prompt(harness: &Harness, window: &crate::test_support::OwnedWindow<adw::Window>) -> adw::AlertDialog {
    button_labelled(harness, "Roll Back").emit_clicked();
    let mut alert = None;
    wait_until(WAIT, || {
        alert = crate::workspace::visible_alert(window);
        alert.is_some()
    })
    .expect("the rollback prompt");
    alert.expect("the rollback prompt")
}

#[gtk4::test]
fn roll_back_asks_first_and_cancel_keeps_the_transaction() {
    adw::init().expect("libadwaita initialises under the test backend");
    let harness = editor_with(transaction_runs(), OPENS_A_TRANSACTION);
    let window = crate::test_support::OwnedWindow::presented(adw::Window::builder().content(&harness.editor).build());
    run_and_wait(&harness);
    let before = sent(&harness.fake);

    let alert = roll_back_prompt(&harness, &window);

    assert_eq!(alert.heading().as_deref(), Some("Roll Back the Transaction?"));
    assert_eq!(alert.body().as_str(), "Its uncommitted changes are discarded.");
    assert_eq!(alert.default_response().as_deref(), Some("cancel"));
    assert_eq!(
        alert.response_appearance("roll-back"),
        adw::ResponseAppearance::Destructive
    );
    assert!(crate::workspace::answer(&window, "cancel"));
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_none()).expect("the prompt to close");
    crate::test_support::drain_main_context();
    assert_eq!(sent(&harness.fake), before, "Cancel sent a statement");
    assert!(harness.editor.has_open_transaction());
}

#[gtk4::test]
fn roll_back_once_confirmed_runs_on_the_tabs_session() {
    adw::init().expect("libadwaita initialises under the test backend");
    let harness = editor_with(transaction_runs(), OPENS_A_TRANSACTION);
    let window = crate::test_support::OwnedWindow::presented(adw::Window::builder().content(&harness.editor).build());
    run_and_wait(&harness);

    roll_back_prompt(&harness, &window);
    assert!(crate::workspace::answer(&window, "roll-back"));
    wait_until(WAIT, || {
        sent(&harness.fake).last().map(String::as_str) == Some("ROLLBACK")
    })
    .expect("the rollback to be sent");
    wait_until(WAIT, || !harness.editor.is_running()).expect("the rollback to end");

    assert_eq!(buffer_text(&harness.editor.buffer()), OPENS_A_TRANSACTION);
    assert!(!harness.editor.has_open_transaction());
    assert!(!widget_shown(&harness, &button_labelled(&harness, "Roll Back")));
}

#[gtk4::test]
fn stop_cancels_the_running_statement() {
    let mut runs = Replies::default();
    runs.always(FakeRun::until_stopped());
    let harness = editor_with(runs, "SELECT pg_sleep(60); SELECT 2");

    harness.editor.run();
    wait_until(WAIT, || !harness.fake.texts().is_empty()).expect("the first statement to start");
    harness.editor.stop();
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");

    assert_eq!(harness.fake.stopped_runs(), 1);
    assert_eq!(
        harness.editor.imp().results.n_entries(),
        2,
        "the second statement has no line"
    );
}

#[gtk4::test]
fn replace_query_can_be_undone() {
    let harness = editor_with(answering(), "SELECT 1");
    let toasts = SignalLog::connect(&harness.editor, "undoable-toast", |values| {
        values[1].get::<String>().expect("a title")
    });

    harness.editor.replace_query("SELECT 2");
    assert_eq!(buffer_text(&harness.editor.buffer()), "SELECT 2");
    assert_eq!(toasts.take(), ["Query replaced"]);

    harness.editor.undo();
    assert_eq!(buffer_text(&harness.editor.buffer()), "SELECT 1");

    harness.editor.replace_query("SELECT 1");
    assert_eq!(toasts.count(), 0, "replacing a query with itself said something");
}

#[gtk4::test]
fn format_keeps_the_old_text_one_undo_away() {
    let harness = editor_with(answering(), "select a,b from t where x=1");

    harness.editor.format();
    let formatted = buffer_text(&harness.editor.buffer());
    assert_ne!(formatted, "select a,b from t where x=1");

    harness.editor.undo();
    assert_eq!(buffer_text(&harness.editor.buffer()), "select a,b from t where x=1");
}

#[gtk4::test]
fn typing_emits_content_changed_without_text() {
    let harness = editor_with(answering(), "SELECT 1");
    let changes = SignalLog::connect(&harness.editor, "content-changed", |values| values.len());
    let buffer = harness.editor.buffer();

    buffer.insert(&mut buffer.end_iter(), " ");
    buffer.insert(&mut buffer.end_iter(), "2");

    // One emission per change, carrying the editor and nothing else.
    assert_eq!(changes.take(), [1, 1]);
}

#[gtk4::test]
fn dropped_non_utf8_file_is_rejected() {
    let harness = editor_with(answering(), "SELECT 1");
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("dump.sql");
    std::fs::write(&path, [0xff, 0xfe]).expect("write");
    let toasts = SignalLog::connect(&harness.editor, "toast", |values| {
        values[1].get::<String>().expect("a message")
    });

    let editor = harness.editor.clone();
    glib::spawn_future_local(async move { editor.insert_file(gio::File::for_path(path), false).await });
    wait_until(WAIT, || toasts.count() == 1).expect("the refusal");

    assert_eq!(buffer_text(&harness.editor.buffer()), "SELECT 1");
    assert!(toasts.take()[0].contains("UTF-8"));
}

#[gtk4::test]
fn a_dropped_file_goes_in_at_the_cursor_as_one_undo_step() {
    let harness = editor_with(answering(), "SELECT 1;\n");
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("more.sql");
    std::fs::write(&path, "SELECT 2;").expect("write");
    let buffer = harness.editor.buffer();
    buffer.place_cursor(&buffer.end_iter());

    let editor = harness.editor.clone();
    glib::spawn_future_local(async move { editor.insert_file(gio::File::for_path(path), false).await });
    wait_until(WAIT, || buffer_text(&buffer).contains("SELECT 2")).expect("the file");

    assert_eq!(buffer_text(&buffer), "SELECT 1;\nSELECT 2;");
    harness.editor.undo();
    assert_eq!(buffer_text(&buffer), "SELECT 1;\n");
}

#[gtk4::test]
fn closing_the_tab_closes_its_connection() {
    let harness = editor_with(answering(), "SELECT 1");
    run_and_wait(&harness);

    harness.editor.shutdown();

    wait_until(WAIT, || harness.fake.is_closed()).expect("the editor session to close");
}

#[gtk4::test]
fn the_icon_buttons_have_accessible_names() {
    let harness = editor_with(answering(), "SELECT 1");

    assert!(gtk4::test_accessible_has_property(
        &harness.editor.imp().menu_button.get(),
        gtk4::AccessibleProperty::Label
    ));
    assert!(gtk4::test_accessible_has_property(
        harness.editor.imp().source_view.upcast_ref::<gtk4::Widget>(),
        gtk4::AccessibleProperty::Label
    ));
    assert_eq!(
        crate::test_support::unlabelled_icon_buttons(&harness.editor),
        Vec::<String>::new()
    );
    assert_eq!(
        crate::test_support::tooltips_with_keys(&harness.editor),
        Vec::<String>::new()
    );
}

/// Tab indents and Ctrl+Tab switches tabs, so the editor names F6, the
/// key its pane binds to move on to the results.
#[gtk4::test]
fn the_editor_names_its_way_out() {
    use crate::test_support::shortcut_keys::{class_binding_keys, keystroke};
    let harness = editor_with(answering(), "SELECT 1");
    let view = harness.editor.imp().source_view.get();
    let paned = view.ancestor(gtk4::Paned::static_type()).expect("the editor's pane");

    assert!(class_binding_keys(&paned).contains(&keystroke("F6")));
    assert!(gtk4::test_accessible_has_property(
        view.upcast_ref::<gtk4::Widget>(),
        gtk4::AccessibleProperty::KeyShortcuts
    ));
}

#[gtk4::test]
fn a_run_is_recorded_unless_it_carries_a_credential() {
    let root = tempfile::tempdir().expect("tempdir");
    let harness = editor_with_history(&root, "CREATE USER u PASSWORD 'p';");
    run_and_wait(&harness);

    harness.editor.buffer().set_text("SELECT 2;");
    run_and_wait(&harness);

    wait_until(WAIT, || {
        recorded(&harness).iter().any(|query| query.contains("SELECT 2"))
    })
    .expect("the plain run was never recorded");
    let recorded = recorded(&harness);
    assert!(
        recorded.iter().all(|query| !query.contains("CREATE USER")),
        "a statement with a password was recorded: {recorded:?}"
    );
}

#[gtk4::test]
fn a_run_is_judged_by_the_engine_it_ran_on() {
    let root = tempfile::tempdir().expect("tempdir");
    let harness = editor_with_history(&root, "CREATE USER u PASSWORD 'p';");
    let ran_on = harness.active.get().expect("the window's session");
    drop(ran_on.begin_shutdown());
    assert!(ran_on.current_dialect().is_none(), "the run's engine is still known");

    harness.editor.run();
    assert!(harness.editor.is_running(), "the run did not start");
    // SQLite has no logins, so its rules let CREATE USER into the history.
    let sqlite = ConnectionScript {
        dialect: Arc::new(tablepro_driver_sqlite::SqliteDialect::new(
            tablepro_driver_sqlite::SQLITE_MIN_VERSION,
        )),
        ..ConnectionScript::default()
    };
    let moved_to = Arc::new(FakeEditorSession::new(answering()));
    harness
        .active
        .replace(session_on(moved_to, harness.runtime.tasks(), sqlite));
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");

    harness.editor.buffer().set_text("SELECT 2;");
    run_and_wait(&harness);

    wait_until(WAIT, || {
        recorded(&harness).iter().any(|query| query.contains("SELECT 2"))
    })
    .expect("the run on the new engine was never recorded");
    let recorded = recorded(&harness);
    assert!(
        recorded.iter().all(|query| !query.contains("CREATE USER")),
        "a statement with a password was recorded: {recorded:?}"
    );
}

/// What the harness's history holds, newest first.
fn recorded(harness: &Harness) -> Vec<String> {
    recorded_entries(harness).into_iter().map(|entry| entry.query).collect()
}

fn recorded_entries(harness: &Harness) -> Vec<tablepro_storage::query_history::Entry> {
    let Some(history) = harness.history.as_ref().and_then(HistoryService::store) else {
        return Vec::new();
    };
    let everything = tablepro_storage::query_history::HistoryQuery::default();
    let search = history.search_page(
        &everything,
        tablepro_storage::query_history::HistoryPageRequest::first(100),
    );
    block_on(&harness.runtime, search).expect("search").entries
}

/// A result set of `rows` one-column rows, ended the way `truncation`
/// says.
fn result_set(rows: u64, total_rows: Option<u64>, truncation: Truncation) -> FakeRun {
    let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("n", ColumnType::untyped_text("text"))].into();
    let mut events = vec![
        ResultEvent::ResultSetStarted { columns },
        ResultEvent::Rows((0..rows).map(|row| vec![Value::Int(row as i64)]).collect()),
    ];
    if truncation != Truncation::Complete {
        events.push(ResultEvent::RowLimitReached { retained: rows });
    }
    events.push(ResultEvent::ResultSetFinished {
        retained: rows,
        total_rows,
        truncation,
    });
    FakeRun::completed(events)
}

/// The banner over the result page on show.
fn shown_banner(harness: &Harness) -> adw::Banner {
    let page = harness
        .editor
        .imp()
        .results
        .imp()
        .stack
        .visible_child()
        .expect("a result page");
    crate::test_support::first_descendant_of_type::<adw::Banner>(&page).expect("the page's banner")
}

/// The grid on the result page on show.
fn shown_grid(harness: &Harness) -> DataGrid {
    let page = harness
        .editor
        .imp()
        .results
        .imp()
        .stack
        .visible_child()
        .expect("a result page");
    crate::test_support::first_descendant_of_type::<DataGrid>(&page).expect("the page's grid")
}

/// Run what `accel` does in `grid`, as a key press reaching the grid's
/// own controller would. `true` when the grid took the key.
fn press_in_grid(grid: &DataGrid, accel: &str) -> bool {
    use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
    let controller = owner_controller(grid, crate::application::ShortcutOwner::Grid).expect("the grid's keys");
    shortcuts(&controller)
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&keystroke(accel)))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("the grid binds the key")
        .activate(gtk4::ShortcutActionFlags::empty(), grid, None)
}

fn details_shown(grid: &DataGrid) -> bool {
    grid.actions()
        .action_state("show-details")
        .and_then(|state| state.get::<bool>())
        .unwrap_or(false)
}

/// D2: a result grid copies on Ctrl+C, and the editor says how it went.
#[gtk4::test]
fn ctrl_c_copies_from_a_result_grid() {
    let mut runs = Replies::default();
    runs.always(result_set(2, Some(2), Truncation::Complete));
    let harness = editor_with(runs, "SELECT n FROM t");
    let _window = shown(&harness);
    run_and_wait(&harness);
    let toasts = SignalLog::connect(&harness.editor, "toast", |values| {
        values[1].get::<String>().expect("a message")
    });
    let grid = shown_grid(&harness);
    let clipboard = grid.clipboard();
    clipboard.set_text("before");

    grid.selection().select_all();
    assert!(press_in_grid(&grid, "<Primary>c"), "Ctrl+C went by");
    wait_until(WAIT, || toasts.count() > 0).expect("the copy to land");

    assert_eq!(toasts.take(), ["Copied 2 rows".to_owned()]);
    assert!(clipboard.formats().contain_mime_type("text/tab-separated-values"));
    let text: Option<String> = clipboard
        .content()
        .and_then(|content| content.value(String::static_type()).ok())
        .and_then(|value| value.get().ok());
    assert_eq!(text.as_deref(), Some("0\n1\n"));
}

/// The pane's Row Details toggle acts on the grid of the result on
/// screen, and shows that grid's state.
#[gtk4::test]
fn row_details_reaches_the_shown_result_s_grid() {
    let mut runs = Replies::default();
    runs.always(result_set(2, Some(2), Truncation::Complete));
    let harness = editor_with(runs, "SELECT n FROM a; SELECT n FROM b");
    let _window = shown(&harness);
    run_and_wait(&harness);
    let results = &harness.editor.imp().results;
    let toggle = results.imp().details_toggle.get();
    results.select(0);
    let first = shown_grid(&harness);
    results.select(1);
    let second = shown_grid(&harness);

    assert!(toggle.is_visible());
    wait_until(WAIT, || toggle.is_sensitive()).expect("the toggle reaches the grid");
    toggle.emit_clicked();

    assert!(details_shown(&second), "the shown grid kept its details closed");
    assert!(!details_shown(&first), "a grid off screen opened its details");
    assert!(toggle.is_active());
    results.select(0);
    assert!(!toggle.is_active(), "the toggle kept the other grid's state");
}

#[gtk4::test]
fn truncated_result_reveals_banner_and_complete_result_hides_it() {
    let mut runs = Replies::default();
    runs.when_sql_contains("capped", result_set(3, None, Truncation::ServerStopped));
    runs.always(result_set(2, Some(2), Truncation::Complete));
    let harness = editor_with(runs, "SELECT n FROM capped; SELECT n FROM small");

    run_and_wait(&harness);
    let results = &harness.editor.imp().results;
    results.select(0);
    let capped = shown_banner(&harness);
    results.select(1);
    let complete = shown_banner(&harness);

    assert!(capped.is_revealed(), "the capped result has no banner");
    assert_eq!(
        capped.title(),
        "Stopped after the first 3 rows: the statement did not run past them"
    );
    assert_eq!(capped.button_label().as_deref(), Some("Export All…"));
    assert!(!complete.is_revealed(), "a complete result shows a banner");
}

#[gtk4::test]
fn export_all_uses_originating_statement_of_second_result() {
    let mut runs = Replies::default();
    runs.always(result_set(3, Some(40), Truncation::ReadPastLimit));
    let harness = editor_with(runs, "SELECT n FROM first;\nSELECT n FROM second WHERE n > 2;");
    let offers = SignalLog::connect(&harness.editor, "export-results", |values| {
        values[1]
            .get::<glib::BoxedAnyObject>()
            .expect("an offer")
            .borrow::<ExportOffer>()
            .clone()
    });
    run_and_wait(&harness);

    harness.editor.imp().results.select(1);
    shown_banner(&harness).emit_by_name::<()>("button-clicked", &[]);

    let offers = offers.take();
    let [offer] = offers.as_slice() else {
        panic!("one offer, not {}", offers.len());
    };
    let ExportOrigin::Editor {
        shown,
        query: ExportQuery::Editor { sql },
        shown_rows,
        truncated,
    } = &offer.origin
    else {
        panic!("not an editor result: {:?}", offer.origin);
    };
    assert_eq!(sql.as_str(), "SELECT n FROM second WHERE n > 2");
    assert!(*truncated);
    assert_eq!(*shown_rows, 3);
    assert_eq!(shown.row_count(), Some(3));
    assert!(offer.session.is_some(), "Export All has no session to read through");
    assert_eq!(offer.origin.preselected(), crate::ui::export::ScopeSource::Query);
}

#[gtk4::test]
fn history_records_none_for_capped_result() {
    let root = tempfile::tempdir().expect("tempdir");
    let mut runs = Replies::default();
    runs.when_sql_contains("capped", result_set(3, None, Truncation::ServerStopped));
    runs.always(result_set(2, Some(9), Truncation::ReadPastLimit));
    let harness = editor_with_history_runs(&root, runs, "SELECT n FROM capped;");
    run_and_wait(&harness);
    harness.editor.buffer().set_text("SELECT n FROM counted;");
    run_and_wait(&harness);

    wait_until(WAIT, || recorded_entries(&harness).len() == 2).expect("both runs recorded");
    let entries = recorded_entries(&harness);
    let rows = |query: &str| {
        entries
            .iter()
            .find(|entry| entry.query.contains(query))
            .map(|entry| entry.rows_affected)
            .expect("the run's entry")
    };
    assert_eq!(rows("capped"), None, "a capped result recorded the rows it kept");
    assert_eq!(rows("counted"), Some(9));
}

/// The test drives the runtime from outside it, which is the one place
/// blocking on it cannot deadlock.
#[expect(
    clippy::disallowed_methods,
    reason = "a GTK test has no runtime of its own, so it drives the app's from outside"
)]
fn block_on<F: std::future::Future>(runtime: &crate::runtime::AppRuntime, future: F) -> F::Output {
    runtime.tasks().handle().block_on(future)
}

fn unconnected_editor(settings: &MemorySettings, tasks: Tasks) -> SqlEditor {
    crate::register_test_resources();
    SqlEditor::new(SqlEditorInit {
        initial_query: None,
        settings: settings.get().clone(),
        history: None,
        tasks,
        session: ActiveSession::new(),
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
        close_timeout: Duration::from_secs(5),
        snippets: crate::test_support::builtin_snippets_only(),
    })
}

fn scheme_id(view: &sourceview5::View) -> Option<String> {
    let buffer = view.buffer().downcast::<sourceview5::Buffer>().ok()?;
    buffer.style_scheme().map(|scheme| scheme.id().to_string())
}

#[gtk4::test]
fn closed_editor_frees_source_view() {
    let runtime = crate::test_support::test_runtime();
    let settings = MemorySettings::new();
    let editor = unconnected_editor(&settings, runtime.tasks());
    let view = editor.imp().source_view.get().downgrade();

    drop(editor);
    crate::test_support::drain_main_context();

    assert!(
        view.upgrade().is_none(),
        "the closed editor's source view is still alive"
    );
}

#[gtk4::test]
fn closed_editor_drops_its_theme_and_font_handlers() {
    let _ = adw::init();
    let runtime = crate::test_support::test_runtime();
    let settings = MemorySettings::new();
    let counts = |settings: &MemorySettings| (Rc::strong_count(settings.get()), Rc::weak_count(settings.get()));
    let before = counts(&settings);
    let style = adw::StyleManager::default();
    style.set_color_scheme(adw::ColorScheme::ForceLight);
    let editor = unconnected_editor(&settings, runtime.tasks());
    // Held past the editor, so a handler left behind has a view to repaint.
    let view = editor.imp().source_view.get();

    drop(editor);
    crate::test_support::drain_main_context();
    let scheme = scheme_id(view.upcast_ref());
    settings.get().set_style_scheme("cobalt").expect("a style scheme");
    style.set_color_scheme(adw::ColorScheme::ForceDark);
    let after = scheme_id(view.upcast_ref());
    style.set_color_scheme(adw::ColorScheme::Default);

    assert_eq!(after, scheme, "a closed editor still follows the theme");
    assert_eq!(
        counts(&settings),
        before,
        "the settings still carry a closed editor's handlers"
    );
}

#[test]
fn export_name_slugs_the_statement() {
    assert_eq!(export_name_for_query("SELECT * FROM users"), "select-from-users");
    assert_eq!(export_name_for_query("  select id\nfrom t"), "select-id");
}

#[test]
fn export_name_falls_back_when_there_is_no_statement() {
    assert_eq!(export_name_for_query("   \n  "), crate::i18n::gettext("query-results"));
}

/// The editor in a window. A widget finds its ancestors' action groups
/// once it is rooted, which a key press always is.
struct InWindow(gtk4::Window);

impl InWindow {
    fn new(editor: &SqlEditor) -> Self {
        let window = gtk4::Window::new();
        window.set_child(Some(editor));
        Self(window)
    }

    /// Shown, and holding the keyboard focus.
    fn presented(editor: &SqlEditor) -> Self {
        let shown = Self::new(editor);
        shown.0.set_default_size(480, 320);
        crate::test_support::KeyInjector::focus_only(&shown.0);
        wait_until(Duration::from_secs(2), || shown.0.is_active()).expect("the window to take the focus");
        shown
    }
}

impl Drop for InWindow {
    fn drop(&mut self) {
        crate::test_support::drop_focus(&self.0);
        self.0.set_child(None::<&gtk4::Widget>);
        self.0.destroy();
    }
}

#[gtk4::test]
fn a_closed_editor_lets_go_of_its_script_and_completion() {
    let harness = editor_with(answering(), "SELECT 1");
    let view = harness.editor.imp().source_view.get();
    let script = harness.editor.buffer().downgrade();
    let providers: Vec<glib::WeakRef<sourceview5::CompletionProvider>> = harness
        .editor
        .imp()
        .completion_providers
        .borrow()
        .iter()
        .map(ObjectExt::downgrade)
        .collect();
    assert_eq!(providers.len(), 2, "the catalog and the document words");
    {
        let shown = InWindow::new(&harness.editor);
        shown.0.present();
        wait_until(WAIT, || view.is_mapped()).expect("the editor on screen");
        crate::test_support::after_next_frame(&view);
    }

    drop(view);
    drop(harness);
    crate::test_support::drain_main_context();

    assert!(script.upgrade().is_none(), "the script outlived its editor");
    assert!(
        providers.iter().all(|provider| provider.upgrade().is_none()),
        "the completion, which holds the session, outlived its editor"
    );
}

#[gtk4::test]
fn a_closed_editor_in_vim_lets_go_of_its_script_and_vim() {
    let harness = editor_with(answering(), "SELECT 1");
    let vim = vim(&harness).downgrade();
    let view = harness.editor.imp().source_view.get();
    let script = harness.editor.buffer().downgrade();
    {
        let shown = InWindow::new(&harness.editor);
        shown.0.present();
        wait_until(WAIT, || view.is_mapped()).expect("the editor on screen");
        crate::test_support::after_next_frame(&view);
    }

    drop(view);
    drop(harness);
    crate::test_support::drain_main_context();

    assert!(script.upgrade().is_none(), "the script outlived its editor");
    assert!(vim.upgrade().is_none(), "Vim outlived its editor");
}

fn owner_keys(harness: &Harness, owner: crate::application::ShortcutOwner) -> gtk4::ShortcutController {
    crate::test_support::shortcut_keys::owner_controller(&harness.editor.imp().source_view.get(), owner)
        .expect("the editor's shortcuts")
}

/// What `accel` does on the source view, as a key reaching the editor's
/// controller would. `false` when the key goes on.
fn press(harness: &Harness, accel: &str) -> bool {
    press_in(harness, crate::application::ShortcutOwner::SqlEditor, accel)
}

fn press_in(harness: &Harness, owner: crate::application::ShortcutOwner, accel: &str) -> bool {
    use crate::test_support::shortcut_keys::{keystroke, shortcuts, trigger_keys};
    let key = keystroke(accel);
    let action = shortcuts(&owner_keys(harness, owner))
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&key))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("the editor binds the key");
    action.activate(
        gtk4::ShortcutActionFlags::empty(),
        &harness.editor.imp().source_view.get(),
        None,
    )
}

/// GtkTextView binds Ctrl+/ to select-all, and a bubble controller on
/// the view runs before that binding only while it was added last, so
/// every editor key that a class binds too runs in the capture phase.
#[gtk4::test]
fn editor_keys_that_the_view_binds_run_in_capture() {
    use crate::application::{ACCELERATORS, AcceleratorScope, ShortcutOwner};
    use crate::test_support::shortcut_keys::{class_binding_keys, keystroke};
    let harness = editor_with(answering(), "SELECT 1");
    let view = harness.editor.imp().source_view.get();
    let class_keys = class_binding_keys(&view);

    assert!(
        class_keys.contains(&keystroke("<Primary>slash")),
        "the view's own bindings were not found, so the check reads nothing"
    );
    assert!(
        class_keys.contains(&keystroke("<Shift><Alt>Down")),
        "GtkSourceView's own bindings were not found"
    );
    for owner in [ShortcutOwner::SqlEditor, ShortcutOwner::SqlEditorCursors] {
        assert_eq!(
            owner_keys(&harness, owner).propagation_phase(),
            gtk4::PropagationPhase::Capture
        );
    }
    for entry in ACCELERATORS {
        let AcceleratorScope::Local {
            owner: ShortcutOwner::SqlEditor | ShortcutOwner::SqlEditorCursors,
            phase,
        } = entry.scope
        else {
            continue;
        };
        if entry
            .triggers
            .iter()
            .any(|accel| class_keys.contains(&keystroke(accel)))
        {
            assert_eq!(phase, gtk4::PropagationPhase::Capture, "{}", entry.action);
        }
    }
}

#[gtk4::test]
fn ctrl_slash_toggles_the_comment() {
    let harness = editor_with(answering(), "select 1");
    let _window = InWindow::new(&harness.editor);

    assert!(press(&harness, "<Primary>slash"));

    assert_eq!(buffer_text(&harness.editor.buffer()), "-- select 1");
    assert!(!harness.editor.buffer().has_selection());
}

#[gtk4::test]
fn escape_cancels_only_while_a_query_runs() {
    let mut runs = Replies::default();
    runs.always(FakeRun::until_stopped());
    let harness = editor_with(runs, "SELECT pg_sleep(60)");
    let _window = InWindow::new(&harness.editor);

    assert!(!press(&harness, "Escape"), "Escape was taken with nothing running");

    assert!(press(&harness, "<Primary>Return"));
    assert!(harness.editor.is_running(), "Ctrl+Return did not run");
    wait_until(WAIT, || !harness.fake.texts().is_empty()).expect("the statement to start");
    assert!(press(&harness, "Escape"), "Escape did not cancel the run");
    wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");
    assert_eq!(harness.fake.stopped_runs(), 1);
    assert!(!press(&harness, "Escape"), "Escape stayed taken after the run");
}

/// GtkPopoverMenu shows only application accelerators by itself.
#[gtk4::test]
fn the_editor_menu_shows_the_tables_local_keys() {
    use crate::application::{ACCELERATORS, AcceleratorScope};
    let harness = editor_with(answering(), "SELECT 1");
    let menu = harness
        .editor
        .imp()
        .menu_button
        .menu_model()
        .expect("the editor's menu");
    let mut checked = 0;
    for section in 0..menu.n_items() {
        let Some(items) = menu.item_link(section, "section") else {
            continue;
        };
        for item in 0..items.n_items() {
            let Some(action) = items
                .item_attribute_value(item, "action", None)
                .and_then(|value| value.get::<String>())
            else {
                continue;
            };
            let accel = items
                .item_attribute_value(item, "accel", None)
                .and_then(|value| value.get::<String>());
            let entry = ACCELERATORS.iter().find(|entry| entry.action == action);
            let expected = entry
                .filter(|entry| matches!(entry.scope, AcceleratorScope::Local { .. }))
                .and_then(|entry| entry.triggers.first())
                .map(|accel| (*accel).to_owned());
            assert_eq!(accel, expected, "{action}");
            checked += usize::from(expected.is_some());
        }
    }
    assert!(checked > 0, "no menu item has a local key, so the check reads nothing");
}

/// Load `path` into the whole buffer, as Open SQL File does.
fn open_path(harness: &Harness, path: &std::path::Path) {
    let (editor, file) = (harness.editor.clone(), gio::File::for_path(path));
    crate::test_support::finish_on_main(WAIT, async move { editor.insert_file(file, true).await })
        .expect("the file to load");
}

#[gtk4::test]
fn ctrl_s_writes_the_opened_file_and_marks_the_text_saved() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    let changes = SignalLog::connect(&harness.editor, "file-changed", |_| ());
    open_path(&harness, &path);
    assert_eq!(harness.editor.file().and_then(|file| file.path()), Some(path.clone()));
    assert!(
        !harness.editor.has_unsaved_file_changes(),
        "the text just read counts as changed"
    );

    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
    assert!(harness.editor.has_unsaved_file_changes());

    assert!(press_on_tab(&harness, "<Primary>s"), "Ctrl+S did nothing");
    wait_until(WAIT, || !harness.editor.has_unsaved_file_changes()).expect("the save to land");

    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        "SELECT 1;\nSELECT 2;"
    );
    assert!(changes.count() >= 3, "the workspace was not told: {}", changes.count());
}

#[gtk4::test]
fn undo_back_to_the_saved_text_is_saved_again() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let buffer = harness.editor.buffer();

    buffer.begin_user_action();
    buffer.insert(&mut buffer.end_iter(), " -- note");
    buffer.end_user_action();
    assert!(harness.editor.has_unsaved_file_changes());
    buffer.undo();

    assert!(!harness.editor.has_unsaved_file_changes());
}

#[gtk4::test]
fn a_file_that_cannot_be_written_keeps_the_text_changed_and_says_why() {
    let root = tempfile::tempdir().expect("tempdir");
    let harness = editor_with(answering(), "SELECT 1;");
    harness
        .editor
        .restore_file(gio::File::for_path(root.path().join("gone").join("daily.sql")), true);

    let saving = harness.editor.save_to_file();
    let failed = crate::test_support::finish_on_main(WAIT, saving).expect("the save to end");

    let message = failed.expect_err("a folder that is not there cannot be written to");
    assert!(message.starts_with("“daily.sql” could not be saved: "), "{message}");
    assert!(harness.editor.has_unsaved_file_changes());
}

#[gtk4::test]
fn a_tab_with_no_file_has_nothing_unsaved_to_ask_about() {
    let harness = editor_with(answering(), "SELECT 1;");
    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");

    assert!(harness.editor.file().is_none());
    assert!(!harness.editor.has_unsaved_file_changes());
}

/// Turn the preference on and hand over Vim's input method.
fn vim(harness: &Harness) -> sourceview5::VimIMContext {
    harness.settings.get().set_vim_keybindings(true).expect("turn Vim on");
    harness.editor.vim_context().expect("Vim on the view")
}

/// A command line as GtkSourceView sends it once Return is pressed.
fn vim_command(context: &sourceview5::VimIMContext, command: &str) -> bool {
    context.emit_by_name::<bool>("execute-command", &[&command])
}

#[gtk4::test]
fn vim_follows_the_preference_and_leaves_the_view_as_it_was() {
    let harness = editor_with(answering(), "select 1");
    let imp = harness.editor.imp();
    let view = imp.source_view.get();
    assert!(!harness.editor.has_vim(), "Vim is on by default");
    assert!(!imp.text_pane.reveals_bottom_bars());

    vim(&harness);

    assert!(imp.text_pane.reveals_bottom_bars(), "the mode line is hidden");
    assert!(view.overwrites(), "normal mode draws no block cursor");

    harness.settings.get().set_vim_keybindings(false).expect("turn Vim off");

    assert!(!harness.editor.has_vim());
    assert!(!imp.text_pane.reveals_bottom_bars());
    assert!(!view.overwrites(), "the block cursor stayed");
    assert!(view.is_cursor_visible());
    assert_eq!(imp.vim_command_bar.label(), "");
}

#[gtk4::test]
fn an_editor_opened_with_the_preference_on_starts_in_vim() {
    let settings = MemorySettings::new();
    settings.get().set_vim_keybindings(true).expect("turn Vim on");

    let harness = build_editor_on(settings, answering(), "select 1", |_| None);

    assert!(harness.editor.has_vim());
    assert!(harness.editor.imp().text_pane.reveals_bottom_bars());
}

#[gtk4::test]
fn vim_quit_asks_the_workspace_to_close_the_tab() {
    let harness = editor_with(answering(), "select 1");
    let context = vim(&harness);
    let closes = SignalLog::connect(&harness.editor, "close-requested", |_| ());

    assert!(vim_command(&context, ":q"));
    assert!(vim_command(&context, ":quit!"));
    assert!(
        !vim_command(&context, ":nohl"),
        "a command of GtkSourceView's own was taken"
    );

    assert_eq!(closes.count(), 2);
}

#[gtk4::test]
fn vim_write_saves_the_tabs_file_as_ctrl_s_does() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
    let context = vim(&harness);

    assert!(vim_command(&context, ":w"));
    wait_until(WAIT, || !harness.editor.has_unsaved_file_changes()).expect("the save to land");

    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        "SELECT 1;\nSELECT 2;"
    );
}

#[gtk4::test]
fn vim_write_with_a_trailing_space_saves_the_tabs_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
    let context = vim(&harness);

    assert!(vim_command(&context, ":write "));
    wait_until(WAIT, || !harness.editor.has_unsaved_file_changes()).expect("the save to land");

    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        "SELECT 1;\nSELECT 2;"
    );
    assert_eq!(harness.editor.file().and_then(|file| file.path()), Some(path));
}

#[gtk4::test]
fn vim_write_quit_closes_once_the_file_is_written() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
    let context = vim(&harness);
    let closes = SignalLog::connect(&harness.editor, "close-requested", |_| ());

    assert!(vim_command(&context, ":wq"));
    wait_until(WAIT, || closes.count() == 1).expect("the close after the write");

    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        "SELECT 1;\nSELECT 2;"
    );
    assert!(!harness.editor.has_unsaved_file_changes());
}

#[gtk4::test]
fn vim_write_quit_keeps_the_tab_when_the_write_fails() {
    let root = tempfile::tempdir().expect("tempdir");
    let harness = editor_with(answering(), "SELECT 1;");
    harness
        .editor
        .restore_file(gio::File::for_path(root.path().join("gone").join("daily.sql")), true);
    let window = shown(&harness);
    let context = vim(&harness);
    let closes = SignalLog::connect(&harness.editor, "close-requested", |_| ());

    assert!(vim_command(&context, ":wq"));
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the failed write to say so");
    crate::test_support::drain_main_context();

    assert_eq!(closes.count(), 0, "the tab closed without its text in the file");
}

/// The file is not there to write to, so a close means no write was tried.
#[gtk4::test]
fn vim_exit_closes_an_unchanged_file_without_writing() {
    let root = tempfile::tempdir().expect("tempdir");
    let harness = editor_with(answering(), "SELECT 1;");
    harness
        .editor
        .restore_file(gio::File::for_path(root.path().join("gone").join("daily.sql")), false);
    let context = vim(&harness);
    let closes = SignalLog::connect(&harness.editor, "close-requested", |_| ());

    assert!(vim_command(&context, ":x"));

    assert_eq!(closes.count(), 1);
}

#[gtk4::test]
fn vim_write_to_a_name_saves_next_to_the_tabs_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let context = vim(&harness);

    assert!(vim_command(&context, ":w weekly.sql"));
    let copy = root.path().join("weekly.sql");
    // The name is claimed empty first; the tab follows once the text is in.
    wait_until(WAIT, || {
        harness.editor.file().and_then(|file| file.path()).as_ref() == Some(&copy)
    })
    .expect("the tab on the new file");

    assert_eq!(std::fs::read_to_string(&copy).expect("read back"), "SELECT 1;");
}

#[gtk4::test]
fn vim_write_to_a_name_leaves_another_file_alone() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    let other = root.path().join("weekly.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    std::fs::write(&other, "SELECT 7;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let context = vim(&harness);
    let toasts = SignalLog::connect(&harness.editor, "toast", |values| {
        values[1].get::<String>().expect("a message")
    });

    assert!(vim_command(&context, ":w weekly.sql"));
    wait_until(WAIT, || toasts.count() == 1).expect("the refusal");

    assert!(toasts.take()[0].starts_with("“weekly.sql” already exists."));
    assert_eq!(std::fs::read_to_string(&other).expect("read back"), "SELECT 7;");
    assert_eq!(harness.editor.file().and_then(|file| file.path()), Some(path));
}

#[gtk4::test]
fn vim_write_to_a_new_name_during_a_save_writes_nothing() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let window = shown(&harness);
    let context = vim(&harness);
    harness.editor.imp().saving.set(true);

    assert!(vim_command(&context, ":w weekly.sql"));
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the refusal to say so");

    assert!(!root.path().join("weekly.sql").exists(), "a file was made");
    assert_eq!(harness.editor.file().and_then(|file| file.path()), Some(path));
}

#[gtk4::test]
fn vim_force_write_to_a_name_replaces_another_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    let other = root.path().join("weekly.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    std::fs::write(&other, "SELECT 7;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let context = vim(&harness);

    assert!(vim_command(&context, ":w! weekly.sql"));
    wait_until(WAIT, || {
        harness.editor.file().and_then(|file| file.path()).as_ref() == Some(&other)
    })
    .expect("the tab on the other file");

    assert_eq!(std::fs::read_to_string(&other).expect("read back"), "SELECT 1;");
}

#[gtk4::test]
fn vim_force_edit_reads_the_tabs_file_without_asking() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let window = shown(&harness);
    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
    let context = vim(&harness);

    assert!(vim_command(&context, ":e!"));
    wait_until(WAIT, || buffer_text(&buffer) == "SELECT 1;").expect("the file again");

    assert!(crate::workspace::visible_alert(&window).is_none(), "it asked");
    assert!(!harness.editor.has_unsaved_file_changes());
}

#[gtk4::test]
fn vim_edit_asks_before_it_drops_changes_to_the_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let window = shown(&harness);
    let buffer = harness.editor.buffer();
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
    let context = vim(&harness);

    assert!(vim_command(&context, ":e"));
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
    assert_eq!(buffer_text(&buffer), "SELECT 1;\nSELECT 2;");
    assert!(crate::workspace::answer(&window, "replace"));

    wait_until(WAIT, || buffer_text(&buffer) == "SELECT 1;").expect("the file again");
}

#[gtk4::test]
fn vim_edit_a_name_asks_before_it_drops_an_emptied_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    let other = root.path().join("weekly.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    std::fs::write(&other, "SELECT 7;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let window = shown(&harness);
    let buffer = harness.editor.buffer();
    buffer.delete(&mut buffer.start_iter(), &mut buffer.end_iter());
    let context = vim(&harness);

    assert!(vim_command(&context, ":e weekly.sql"));

    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
    assert_eq!(buffer_text(&buffer), "");
    assert_eq!(harness.editor.file().and_then(|file| file.path()), Some(path));
}

#[gtk4::test]
fn vim_edit_asks_before_it_undoes_emptying_the_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    let window = shown(&harness);
    let buffer = harness.editor.buffer();
    buffer.delete(&mut buffer.start_iter(), &mut buffer.end_iter());
    let context = vim(&harness);

    assert!(vim_command(&context, ":e"));

    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
    assert_eq!(buffer_text(&buffer), "");
}

#[gtk4::test]
fn vim_edit_reads_the_tabs_file_again() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 1;").expect("seed");
    let harness = editor_with(answering(), "");
    open_path(&harness, &path);
    std::fs::write(&path, "SELECT 2;").expect("change it on disk");
    let context = vim(&harness);

    assert!(vim_command(&context, ":e"));
    let buffer = harness.editor.buffer();
    wait_until(WAIT, || buffer_text(&buffer) == "SELECT 2;").expect("the file again");

    assert!(!harness.editor.has_unsaved_file_changes());
}

#[gtk4::test]
fn vim_edit_without_a_file_says_so() {
    let harness = editor_with(answering(), "SELECT 1;");
    let context = vim(&harness);
    let toasts = SignalLog::connect(&harness.editor, "toast", |values| {
        values[1].get::<String>().expect("a message")
    });

    assert!(vim_command(&context, ":e"));

    assert_eq!(toasts.take(), ["This tab is not saved to a file."]);
    assert_eq!(buffer_text(&harness.editor.buffer()), "SELECT 1;");
}

#[gtk4::test]
fn vim_edit_a_name_opens_that_file_in_an_empty_tab() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 3;").expect("seed");
    let harness = editor_with(answering(), "");
    let context = vim(&harness);

    assert!(vim_command(&context, &format!(":e {}", path.display())));
    let buffer = harness.editor.buffer();
    wait_until(WAIT, || buffer_text(&buffer) == "SELECT 3;").expect("the file");

    assert_eq!(harness.editor.file().and_then(|file| file.path()), Some(path));
}

#[gtk4::test]
fn vim_edit_a_name_asks_before_it_replaces_the_tabs_text() {
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("daily.sql");
    std::fs::write(&path, "SELECT 3;").expect("seed");
    let harness = editor_with(answering(), "SELECT 1;");
    let window = shown(&harness);
    let context = vim(&harness);
    let buffer = harness.editor.buffer();

    assert!(vim_command(&context, &format!(":e {}", path.display())));
    wait_until(WAIT, || crate::workspace::visible_alert(&window).is_some()).expect("the question");
    assert_eq!(buffer_text(&buffer), "SELECT 1;", "the text went before the answer");
    assert!(crate::workspace::answer(&window, "replace"));

    wait_until(WAIT, || buffer_text(&buffer) == "SELECT 3;").expect("the file");
    harness.editor.undo();
    assert_eq!(buffer_text(&buffer), "SELECT 1;");
}

fn find_bar(harness: &Harness) -> find_bar::FindBar {
    harness.editor.imp().find_bar.get()
}

/// What `accel` does on the editor tab, as a key reaching the tab's own
/// controller would.
fn press_on_tab(harness: &Harness, accel: &str) -> bool {
    use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
    let key = keystroke(accel);
    let controller = owner_controller(&harness.editor, crate::application::ShortcutOwner::SqlEditorTab)
        .expect("the tab's shortcuts");
    let action = shortcuts(&controller)
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&key))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("the tab binds the key");
    action.activate(gtk4::ShortcutActionFlags::empty(), &harness.editor, None)
}

fn select(buffer: &gtk4::TextBuffer, start: i32, end: i32) {
    buffer.select_range(&buffer.iter_at_offset(start), &buffer.iter_at_offset(end));
}

fn selected(buffer: &gtk4::TextBuffer) -> Option<(i32, i32)> {
    buffer
        .selection_bounds()
        .map(|(start, end)| (start.offset(), end.offset()))
}

/// Open the bar and search for `text`, waiting until the bar shows
/// what the search counted. The count can be read a moment before the
/// context says it changed.
fn search(harness: &Harness, text: &str) -> find_bar::FindBar {
    assert!(press_on_tab(harness, "<Primary>f"));
    let bar = find_bar(harness);
    bar.search_entry().set_text(text);
    wait_until(WAIT, || !bar.count_text().is_empty()).expect("the search to count");
    bar
}

#[gtk4::test]
fn ctrl_f_reveals_bar_and_prefills_selection() {
    let harness = editor_with(answering(), "SELECT * FROM orders JOIN orders_lines");
    let _window = InWindow::new(&harness.editor);
    let buffer = harness.editor.buffer();
    select(&buffer, 14, 20);

    assert!(press_on_tab(&harness, "<Primary>f"));

    let bar = find_bar(&harness);
    assert!(bar.is_open());
    assert!(!bar.is_replacing());
    assert_eq!(bar.search_entry().text(), "orders");
    wait_until(WAIT, || bar.count_text() == "1 of 2").expect("the search to count");
    assert_eq!(
        bar.context().map(|context| context.is_highlight()),
        Some(true),
        "matches are not highlighted"
    );
}

#[gtk4::test]
fn a_selection_over_lines_is_not_searched_for() {
    let harness = editor_with(answering(), "SELECT 1;\nSELECT 2;");
    let _window = InWindow::new(&harness.editor);
    select(&harness.editor.buffer(), 0, 15);

    assert!(press_on_tab(&harness, "<Primary>f"));

    assert_eq!(find_bar(&harness).search_entry().text(), "");
}

#[gtk4::test]
fn next_selects_second_occurrence() {
    let harness = editor_with(answering(), "orders; orders; orders");
    let _window = InWindow::new(&harness.editor);
    let buffer = harness.editor.buffer();
    select(&buffer, 0, 6);
    let bar = search(&harness, "orders");
    wait_until(WAIT, || selected(&buffer) == Some((0, 6))).expect("the first match selected");

    assert!(press_on_tab(&harness, "<Primary>g"));
    assert_eq!(selected(&buffer), Some((8, 14)));
    assert_eq!(bar.count_text(), "2 of 3");

    assert!(press_on_tab(&harness, "<Primary><Shift>g"));
    assert_eq!(selected(&buffer), Some((0, 6)));
    assert!(press_on_tab(&harness, "<Primary><Shift>g"));
    assert_eq!(selected(&buffer), Some((16, 22)), "the search did not wrap around");
}

/// GtkSearchEntry binds Ctrl+G itself, so in the entry the key reaches
/// the bar as the entry's next-match signal.
#[gtk4::test]
fn the_search_entrys_next_match_moves_to_the_next() {
    let harness = editor_with(answering(), "a; b; a");
    let _window = InWindow::new(&harness.editor);
    let buffer = harness.editor.buffer();
    buffer.place_cursor(&buffer.start_iter());
    let bar = search(&harness, "a");
    wait_until(WAIT, || selected(&buffer) == Some((0, 1))).expect("the first match selected");

    bar.search_entry().emit_by_name::<()>("next-match", &[]);

    assert_eq!(selected(&buffer), Some((6, 7)));
}

#[gtk4::test]
fn replace_all_is_single_undo_step() {
    let harness = editor_with(answering(), "x = 1 AND x = 2");
    let _window = InWindow::new(&harness.editor);
    let toasts = SignalLog::connect(&harness.editor, "toast", |values| {
        values[1].get::<String>().expect("a message")
    });
    assert!(press_on_tab(&harness, "<Primary>h"));
    let bar = find_bar(&harness);
    assert!(bar.is_replacing(), "Ctrl+H did not show the replace row");
    bar.replace_entry().set_text("y");
    bar.search_entry().set_text("x");
    wait_until(WAIT, || bar.count_text().ends_with("of 2")).expect("the search to count");

    WidgetExt::activate_action(&bar, "find.replace-all", None).expect("find.replace-all");

    let buffer = harness.editor.buffer();
    assert_eq!(toasts.take(), ["Replaced 2 occurrences"]);
    assert_eq!(buffer_text(&buffer), "y = 1 AND y = 2");
    buffer.undo();
    assert_eq!(buffer_text(&buffer), "x = 1 AND x = 2");
}

#[gtk4::test]
fn replace_changes_the_selected_match_and_moves_on() {
    let harness = editor_with(answering(), "x; x; x");
    let _window = InWindow::new(&harness.editor);
    let buffer = harness.editor.buffer();
    select(&buffer, 3, 4);
    let bar = search(&harness, "x");
    bar.replace_entry().set_text("yy");

    WidgetExt::activate_action(&bar, "find.replace", None).expect("find.replace");

    assert_eq!(buffer_text(&buffer), "x; yy; x");
    wait_until(WAIT, || selected(&buffer) == Some((7, 8))).expect("the next match selected");
}

#[gtk4::test]
fn nothing_to_replace_leaves_the_buffer_alone() {
    let harness = editor_with(answering(), "SELECT 1");
    let _window = InWindow::new(&harness.editor);
    let bar = search(&harness, "orders");
    assert_eq!(bar.count_text(), "No results");

    let actions = bar.actions().expect("the find actions");
    assert!(
        !actions.is_action_enabled("replace-all"),
        "Replace All is on with nothing to replace"
    );
    assert!(!actions.is_action_enabled("replace"));
    bar.replace_all();

    assert_eq!(buffer_text(&harness.editor.buffer()), "SELECT 1");
}

#[gtk4::test]
fn invalid_regex_marks_entry_error() {
    let harness = editor_with(answering(), "SELECT 1");
    let _window = InWindow::new(&harness.editor);
    assert!(press_on_tab(&harness, "<Primary>f"));
    let bar = find_bar(&harness);
    WidgetExt::activate_action(&bar, "find.regex-enabled", None).expect("find.regex-enabled");
    let entry = bar.search_entry();

    entry.set_text("(");
    wait_until(WAIT, || entry.has_css_class("error")).expect("the entry to show the error");
    assert!(entry.tooltip_text().is_some_and(|text| !text.is_empty()));
    assert_eq!(bar.count_text(), "");

    entry.set_text("SEL+");
    wait_until(WAIT, || !entry.has_css_class("error")).expect("the error to clear");
    assert_eq!(entry.tooltip_text(), None);
}

/// The count and a pattern's error show away from the text the reader
/// is on, so they are said, and the error marks the field.
#[gtk4::test]
fn the_match_count_and_a_bad_pattern_are_said() {
    let harness = editor_with(answering(), "SELECT 1; SELECT 2");
    let _window = InWindow::new(&harness.editor);
    let bar = search(&harness, "SELECT");
    let said = |text: &str| {
        crate::ui::a11y::announced_in(&bar)
            .iter()
            .any(|(message, _)| message == text)
    };
    wait_until(WAIT, || said(&bar.count_text())).expect("the count to be said");

    WidgetExt::activate_action(&bar, "find.regex-enabled", None).expect("find.regex-enabled");
    let entry = bar.search_entry();
    entry.set_text("(");
    let text = entry.delegate().expect("the entry's text field");
    wait_until(WAIT, || {
        gtk4::test_accessible_has_state(&text, gtk4::AccessibleState::Invalid)
            && entry.tooltip_text().is_some_and(|error| said(&error))
    })
    .expect("the pattern's error to be said and marked");

    entry.set_text("SEL+");
    wait_until(WAIT, || {
        !gtk4::test_accessible_has_state(&text, gtk4::AccessibleState::Invalid)
    })
    .expect("the mark to clear");
}

#[gtk4::test]
fn case_sensitive_action_toggles_settings() {
    let harness = editor_with(answering(), "SELECT 1");
    let _window = InWindow::new(&harness.editor);
    let bar = find_bar(&harness);
    assert!(!bar.settings().is_case_sensitive());

    WidgetExt::activate_action(&bar, "find.case-sensitive", None).expect("find.case-sensitive");
    assert!(bar.settings().is_case_sensitive());

    WidgetExt::activate_action(&bar, "find.at-word-boundaries", None).expect("find.at-word-boundaries");
    assert!(bar.settings().is_at_word_boundaries());
}

#[gtk4::test]
fn escape_hides_bar_and_disables_highlight() {
    let harness = editor_with(answering(), "SELECT 1");
    let _window = InWindow::new(&harness.editor);
    let bar = search(&harness, "SEL");
    let context = bar.context().expect("the search context");
    assert!(context.is_highlight());

    bar.search_entry().emit_by_name::<()>("stop-search", &[]);

    assert!(!bar.is_open());
    assert!(!context.is_highlight());
}

/// A bubble key on the tab reaches it only when no class on the way up
/// from the focus binds it first. The search entry binds Ctrl+G, which
/// the bar follows through the entry's own signals.
#[gtk4::test]
fn tab_keys_are_not_class_bindings_inside_the_tab() {
    use crate::application::{ACCELERATORS, AcceleratorScope, ShortcutOwner};
    use crate::test_support::shortcut_keys::{class_keys_on_focus_paths, keystroke};
    let harness = editor_with(answering(), "SELECT 1");
    let _window = InWindow::new(&harness.editor);

    let class_keys = class_keys_on_focus_paths(&harness.editor, |widget| {
        widget.is::<gtk4::Text>() || widget.is::<gtk4::SearchEntry>()
    });

    assert!(
        class_keys.contains(&keystroke("<Primary>slash")),
        "the view's own bindings were not found, so the check reads nothing"
    );
    let mut checked = 0;
    for entry in ACCELERATORS {
        let AcceleratorScope::Local {
            owner: ShortcutOwner::SqlEditorTab,
            phase,
        } = entry.scope
        else {
            continue;
        };
        assert_eq!(phase, gtk4::PropagationPhase::Bubble, "{}", entry.action);
        for accel in entry.triggers {
            assert!(
                !class_keys.contains(&keystroke(accel)),
                "{accel} of {} never reaches the tab",
                entry.action
            );
            checked += 1;
        }
    }
    assert_eq!(checked, 7);
}

fn cursors_on(harness: &Harness, offsets: &[i32]) -> EditorView {
    let view = harness.editor.imp().source_view.get();
    let buffer = harness.editor.buffer();
    let (first, rest) = offsets.split_first().expect("a cursor");
    buffer.place_cursor(&buffer.iter_at_offset(*first));
    for offset in rest {
        view.toggle_caret_at(&buffer.iter_at_offset(*offset));
    }
    assert_eq!(view.caret_count(), offsets.len());
    view
}

#[gtk4::test]
fn ctrl_slash_comments_every_cursors_line_as_one_edit() {
    let harness = editor_with(answering(), "select 1;\nselect 2;\nselect 3;");
    let _window = InWindow::new(&harness.editor);
    let view = cursors_on(&harness, &[0, 22]);
    let buffer = harness.editor.buffer();

    assert!(press(&harness, "<Primary>slash"));

    assert_eq!(buffer_text(&buffer), "-- select 1;\nselect 2;\n-- select 3;");
    assert_eq!(view.caret_count(), 2);
    buffer.undo();
    assert_eq!(buffer_text(&buffer), "select 1;\nselect 2;\nselect 3;");
}

#[gtk4::test]
fn escape_returns_to_one_cursor_only_while_there_are_more() {
    use crate::application::ShortcutOwner::SqlEditorCursors;
    let harness = editor_with(answering(), "select a, a");
    let _window = InWindow::new(&harness.editor);
    let view = harness.editor.imp().source_view.get();
    harness
        .editor
        .buffer()
        .place_cursor(&harness.editor.buffer().iter_at_offset(7));

    assert!(
        !press_in(&harness, SqlEditorCursors, "Escape"),
        "Escape was taken with one cursor"
    );
    assert!(press_in(&harness, SqlEditorCursors, "<Primary>d"));
    assert!(press_in(&harness, SqlEditorCursors, "<Primary>d"));
    assert_eq!(view.caret_count(), 2);
    assert_eq!(
        crate::ui::a11y::announced_in(&harness.editor)
            .last()
            .map(|(said, _)| said.clone()),
        Some("2 cursors".to_owned()),
        "a screen reader hears of the other cursor"
    );
    assert!(press_in(&harness, SqlEditorCursors, "Escape"));
    assert_eq!(view.caret_count(), 1);
    assert!(!press_in(&harness, SqlEditorCursors, "Escape"));
}

#[gtk4::test]
fn the_status_line_counts_the_cursors() {
    let harness = editor_with(answering(), "select a, a");
    let label = harness.editor.imp().cursor_info.get();

    cursors_on(&harness, &[7, 10]);
    assert_eq!(label.label(), "Ln 1, Col 11, 2 cursors");

    harness.editor.imp().source_view.single_caret();
    assert_eq!(label.label(), "Ln 1, Col 11");
}

#[gtk4::test]
fn rewriting_the_whole_text_returns_to_one_cursor() {
    let harness = editor_with(answering(), "select a, a from t");
    let view = cursors_on(&harness, &[7, 10]);

    harness.editor.format();
    assert_eq!(view.caret_count(), 1, "Format kept the other cursor");

    cursors_on(&harness, &[0, 5]);
    harness.editor.replace_query("select 2");
    assert_eq!(view.caret_count(), 1, "a query from history kept the other cursor");
    assert_eq!(buffer_text(&harness.editor.buffer()), "select 2");
}

#[gtk4::test]
fn vim_turns_the_other_cursors_off_and_back_on() {
    let harness = editor_with(answering(), "select a, a");
    let view = cursors_on(&harness, &[7, 10]);
    let group = harness
        .editor
        .imp()
        .actions
        .get()
        .expect("the editor's actions")
        .clone();
    assert!(group.is_action_enabled("single-cursor"));

    vim(&harness);

    assert_eq!(view.caret_count(), 1);
    for action in [
        "add-cursor-next-match",
        "add-cursors-all-matches",
        "add-cursor-above",
        "add-cursor-below",
        "single-cursor",
    ] {
        assert!(!group.is_action_enabled(action), "{action} is on in Vim");
    }
    view.toggle_caret_at(&harness.editor.buffer().start_iter());
    assert_eq!(view.caret_count(), 1, "Ctrl+click added a cursor in Vim");

    harness.settings.get().set_vim_keybindings(false).expect("turn Vim off");
    assert!(group.is_action_enabled("add-cursor-next-match"));
}

/// These press real keys on the X display every test shares; nextest runs
/// them with no other test beside them.
mod real_keys {
    use super::*;

    /// A real key press, so the editor's controller meets GtkTextView's own
    /// Ctrl+/ binding in the order GTK runs them.
    #[gtk4::test]
    fn ctrl_slash_toggles_comment_instead_of_selecting_all() {
        let harness = editor_with(answering(), "select 1");
        let _window = InWindow::presented(&harness.editor);
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.start_iter());
        harness.editor.imp().source_view.grab_focus();

        crate::test_support::KeyInjector::connect()
            .expect("an X11 display")
            .press(gtk4::gdk::Key::slash, gtk4::gdk::ModifierType::CONTROL_MASK)
            .expect("the key press");

        wait_until(Duration::from_secs(2), || buffer_text(&buffer) == "-- select 1")
            .expect("Ctrl+/ to comment the line");
        assert!(!buffer.has_selection(), "Ctrl+/ selected the text");
    }

    /// Real keys, so Ctrl+F meets every handler on its way up from the
    /// view, and Escape the search entry's own.
    #[gtk4::test]
    fn ctrl_f_in_the_view_opens_find_and_escape_returns_to_it() {
        // The bar slides in, and its entry takes no key until the first
        // frame of the slide shows it.
        if let Some(settings) = gtk4::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let harness = editor_with(answering(), "select 1");
        let _window = InWindow::presented(&harness.editor);
        let view = harness.editor.imp().source_view.get();
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");
        let bar = find_bar(&harness);
        let entry = bar.search_entry();

        keys.press(gtk4::gdk::Key::f, gtk4::gdk::ModifierType::CONTROL_MASK)
            .expect("the key press");
        wait_until(Duration::from_secs(2), || {
            bar.is_open() && entry.state_flags().contains(gtk4::StateFlags::FOCUS_WITHIN)
        })
        .expect("Ctrl+F to open the find bar with the focus in its entry");

        keys.press(gtk4::gdk::Key::Escape, gtk4::gdk::ModifierType::empty())
            .expect("the key press");
        wait_until(Duration::from_secs(2), || !bar.is_open() && view.has_focus())
            .expect("Escape to close the bar and return to the view");
    }

    const KEY_WAIT: Duration = Duration::from_secs(2);

    /// An editor in Vim's normal mode with the cursor at the start,
    /// shown and holding the keyboard focus.
    fn in_vim(harness: &Harness) -> (InWindow, crate::test_support::KeyInjector) {
        vim(harness);
        let window = InWindow::presented(&harness.editor);
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.start_iter());
        harness.editor.imp().source_view.grab_focus();
        (
            window,
            crate::test_support::KeyInjector::connect().expect("an X11 display"),
        )
    }

    fn press(keys: &crate::test_support::KeyInjector, key: gtk4::gdk::Key) {
        keys.press(key, gtk4::gdk::ModifierType::empty())
            .expect("the key press");
    }

    /// A key typed with Shift, such as `:` or `G` on a US layout.
    fn shifted(keys: &crate::test_support::KeyInjector, key: gtk4::gdk::Key) {
        keys.press(key, gtk4::gdk::ModifierType::SHIFT_MASK)
            .expect("the key press");
    }

    fn ctrl(keys: &crate::test_support::KeyInjector, key: gtk4::gdk::Key) {
        keys.press(key, gtk4::gdk::ModifierType::CONTROL_MASK)
            .expect("the key press");
    }

    #[gtk4::test]
    fn vim_takes_normal_insert_and_visual_mode_keys() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "select 1");
        let (_window, keys) = in_vim(&harness);
        let buffer = harness.editor.buffer();
        let mode = harness.editor.imp().vim_command_bar.get();

        press(&keys, Key::x);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "elect 1").expect("x to delete a character");

        press(&keys, Key::i);
        wait_until(KEY_WAIT, || !mode.label().is_empty()).expect("i to show insert mode");
        press(&keys, Key::s);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "select 1").expect("insert mode to type");
        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || mode.label().is_empty()).expect("Escape to leave insert mode");

        press(&keys, Key::v);
        press(&keys, Key::e);
        wait_until(KEY_WAIT, || buffer.has_selection() && !mode.label().is_empty())
            .expect("v and e to select a word in visual mode");
        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || mode.label().is_empty()).expect("Escape to leave visual mode");
    }

    #[gtk4::test]
    fn the_run_keys_run_from_vims_normal_and_insert_modes() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "select 1");
        let (_window, keys) = in_vim(&harness);

        ctrl(&keys, Key::Return);
        wait_until(WAIT, || sent(&harness.fake) == ["select 1"]).expect("Ctrl+Return to run in normal mode");
        wait_until(WAIT, || !harness.editor.is_running()).expect("the run to end");

        press(&keys, Key::i);
        keys.press(
            Key::Return,
            gtk4::gdk::ModifierType::CONTROL_MASK | gtk4::gdk::ModifierType::SHIFT_MASK,
        )
        .expect("the key press");
        wait_until(WAIT, || sent(&harness.fake).len() == 2).expect("Ctrl+Shift+Return to run in insert mode");
        assert_eq!(
            buffer_text(&harness.editor.buffer()),
            "select 1",
            "Return went into the text"
        );
    }

    /// Normal mode binds Ctrl+F to a page down, and the command line
    /// takes every key.
    #[gtk4::test]
    fn find_and_comment_keep_their_keys_in_vim() {
        use gtk4::gdk::Key;
        if let Some(settings) = gtk4::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let harness = editor_with(answering(), "select 1");
        let (_window, keys) = in_vim(&harness);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();

        ctrl(&keys, Key::slash);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "-- select 1").expect("Ctrl+/ to comment the line");

        shifted(&keys, Key::colon);
        ctrl(&keys, Key::f);
        let bar = find_bar(&harness);
        wait_until(KEY_WAIT, || bar.is_open()).expect("Ctrl+F to open the find bar from the command line");
        assert!(!view.has_focus(), "the view kept the focus");
    }

    #[gtk4::test]
    fn escape_is_vims_while_a_query_runs() {
        use gtk4::gdk::Key;
        let mut runs = Replies::default();
        runs.always(FakeRun::until_stopped());
        let harness = editor_with(runs, "select 1");
        let (_window, keys) = in_vim(&harness);
        let mode = harness.editor.imp().vim_command_bar.get();
        harness.editor.run();
        assert!(harness.editor.is_running());

        press(&keys, Key::i);
        wait_until(KEY_WAIT, || !mode.label().is_empty()).expect("insert mode");
        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || mode.label().is_empty()).expect("Escape to leave insert mode");

        assert!(harness.editor.is_running(), "Escape stopped the query");
        harness.editor.stop();
        wait_until(WAIT, || !harness.editor.is_running()).expect("the Stop button's stop");
    }

    #[gtk4::test]
    fn typing_colon_w_saves_and_colon_q_asks_to_close() {
        use gtk4::gdk::Key;
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("daily.sql");
        std::fs::write(&path, "SELECT 1;").expect("seed");
        let harness = editor_with(answering(), "");
        open_path(&harness, &path);
        let buffer = harness.editor.buffer();
        buffer.insert(&mut buffer.end_iter(), "\nSELECT 2;");
        let (_window, keys) = in_vim(&harness);
        let closes = SignalLog::connect(&harness.editor, "close-requested", |_| ());

        shifted(&keys, Key::colon);
        press(&keys, Key::w);
        press(&keys, Key::Return);
        wait_until(WAIT, || !harness.editor.has_unsaved_file_changes()).expect(":w to save");
        assert_eq!(
            std::fs::read_to_string(&path).expect("read back"),
            "SELECT 1;\nSELECT 2;"
        );

        shifted(&keys, Key::colon);
        press(&keys, Key::q);
        press(&keys, Key::Return);
        wait_until(KEY_WAIT, || closes.count() == 1).expect(":q to ask for the close");
    }

    fn completion_list_shown(view: &impl IsA<gtk4::Widget>) -> bool {
        let mut child = view.as_ref().first_child();
        while let Some(widget) = child {
            if widget.is::<gtk4::Popover>() && widget.is_visible() {
                return true;
            }
            child = widget.next_sibling();
        }
        false
    }

    /// Each key is waited for, so the list opens in insert mode and not
    /// while Vim is still taking the keys before it.
    #[gtk4::test]
    fn leaving_insert_mode_closes_the_completion_list_for_good() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "SELECT 1;\n");
        let (_window, keys) = in_vim(&harness);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        let mode = harness.editor.imp().vim_command_bar.get();

        shifted(&keys, Key::G);
        press(&keys, Key::o);
        wait_until(KEY_WAIT, || !mode.label().is_empty() && buffer.line_count() == 3).expect("o to open a line");
        shifted(&keys, Key::S);
        shifted(&keys, Key::E);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT 1;\n\nSE").expect("insert mode to type");
        view.completion().show();
        wait_until(KEY_WAIT, || completion_list_shown(&view)).expect("the completion list");

        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || mode.label().is_empty()).expect("Escape to leave insert mode");
        wait_until(KEY_WAIT, || !completion_list_shown(&view)).expect("the list to close");

        press(&keys, Key::x);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT 1;\n\nS").expect("x to delete in normal mode");
        view.completion().show();
        crate::test_support::drain_main_context();
        assert!(!completion_list_shown(&view), "the list opened in normal mode");
    }

    /// Vim's insert mode leaves Tab to GtkSourceView, which moves
    /// between the stops of an accepted snippet.
    #[gtk4::test]
    fn a_snippet_accepted_in_insert_mode_takes_tab_between_its_stops() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "");
        let (_window, keys) = in_vim(&harness);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        let mode = harness.editor.imp().vim_command_bar.get();
        let selected = |buffer: &gtk4::TextBuffer| {
            buffer
                .selection_bounds()
                .map(|(start, end)| buffer.text(&start, &end, false).to_string())
        };

        press(&keys, Key::i);
        wait_until(KEY_WAIT, || !mode.label().is_empty()).expect("i to enter insert mode");
        for key in [Key::i, Key::n, Key::s] {
            press(&keys, key);
        }
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "ins").expect("insert mode to type");
        super::super::completion::accept_builtin_snippet(view.upcast_ref(), "ins");
        wait_until(KEY_WAIT, || {
            buffer_text(&buffer) == "INSERT INTO table_name (columns)\nVALUES (values);"
        })
        .unwrap_or_else(|_| panic!("the INSERT was not written: {:?}", buffer_text(&buffer)));

        press(&keys, Key::Tab);
        wait_until(KEY_WAIT, || selected(&buffer).as_deref() == Some("columns"))
            .unwrap_or_else(|_| panic!("Tab selected {:?}", selected(&buffer)));
    }

    #[gtk4::test]
    fn completion_comes_back_when_vim_is_turned_off() {
        let harness = editor_with(answering(), "SE");
        let (_window, _keys) = in_vim(&harness);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.end_iter());

        harness.settings.get().set_vim_keybindings(false).expect("turn Vim off");
        view.completion().show();

        wait_until(KEY_WAIT, || completion_list_shown(&view)).expect("the list without Vim");
    }

    /// The issue's done line: three cursors type and delete together, and
    /// one undo reverts all three edits. Real keys, so the typed text
    /// takes the input method's way into the buffer.
    #[gtk4::test]
    fn three_cursors_type_and_delete_together_and_one_undo_reverts_all_three() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "SELECT a, a, a");
        let _window = InWindow::presented(&harness.editor);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.iter_at_offset(7));
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        for _ in 0..3 {
            ctrl(&keys, Key::d);
        }
        wait_until(KEY_WAIT, || view.caret_count() == 3).expect("Ctrl+D to add a cursor at each match");
        press(&keys, Key::x);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT x, x, x").expect("x typed at every cursor");
        press(&keys, Key::y);
        press(&keys, Key::BackSpace);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT x, x, x").expect("BackSpace at every cursor");

        ctrl(&keys, Key::z);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT xy, xy, xy")
            .expect("one undo to bring the three deleted y back");
        ctrl(&keys, Key::z);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT x, x, x").expect("one undo to take the three y away");
        ctrl(&keys, Key::z);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "SELECT a, a, a").expect("one undo to bring the three a back");
        assert_eq!(view.caret_count(), 1, "an undo returns to one cursor");
    }

    /// GtkSourceView's completion list closes itself on Escape and lets
    /// the key go on, so the editor's Escape must not act on the same
    /// press.
    #[gtk4::test]
    fn escape_with_the_completion_open_leaves_the_query_running() {
        use gtk4::gdk::Key;
        let mut runs = Replies::default();
        runs.always(FakeRun::until_stopped());
        let harness = editor_with(runs, "SELECT 1;\nSE");
        let _window = InWindow::presented(&harness.editor);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        harness.editor.run();
        wait_until(WAIT, || !harness.fake.texts().is_empty()).expect("the statement to start");
        buffer.place_cursor(&buffer.end_iter());
        view.grab_focus();
        view.completion().show();
        wait_until(KEY_WAIT, || completion_list_shown(&view)).expect("the completion list");
        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || !completion_list_shown(&view)).expect("Escape to close the list");
        crate::test_support::drain_main_context();

        assert!(
            harness.editor.is_running(),
            "the Escape that closed the list stopped the query"
        );
        press(&keys, Key::Escape);
        wait_until(WAIT, || !harness.editor.is_running()).expect("the next Escape to stop the query");
    }

    /// GtkSourceView's own Return indents each new line as the line above
    /// it, at every cursor.
    #[gtk4::test]
    fn return_and_tab_work_out_each_cursors_own_line() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "    a\nb");
        let _window = InWindow::presented(&harness.editor);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.iter_at_offset(5));
        view.toggle_caret_at(&buffer.end_iter());
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        press(&keys, Key::Return);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "    a\n    \nb\n").expect("Return to indent each new line");
        press(&keys, Key::Tab);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "    a\n    \t\nb\n\t").expect("Tab at each cursor");
        ctrl(&keys, Key::z);
        wait_until(KEY_WAIT, || buffer_text(&buffer) == "    a\n    \nb\n").expect("one undo for both tabs");
    }

    /// Shift+Tab unindents the lines a cursor is on, so two cursors on
    /// one line unindent it once.
    #[gtk4::test]
    fn shift_tab_unindents_a_line_once_for_two_cursors_on_it() {
        use gtk4::gdk::{Key, ModifierType};
        let harness = editor_with(answering(), "        a b");
        let _window = InWindow::presented(&harness.editor);
        let view = cursors_on(&harness, &[9, 11]);
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        keys.press(Key::Tab, ModifierType::SHIFT_MASK).expect("the key press");

        wait_until(KEY_WAIT, || buffer_text(&harness.editor.buffer()) == "    a b").expect("one level off the line");
        crate::test_support::drain_main_context();
        assert_eq!(buffer_text(&harness.editor.buffer()), "    a b");
        assert_eq!(view.caret_count(), 2);
    }

    /// A completion replaces the word at one cursor, so its list waits
    /// for one cursor.
    #[gtk4::test]
    fn typing_at_several_cursors_opens_no_completion_list() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "SELECT 1;\nSE\nSE");
        let _window = InWindow::presented(&harness.editor);
        let view = cursors_on(&harness, &[12, 15]);
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        press(&keys, Key::l);
        wait_until(KEY_WAIT, || {
            buffer_text(&harness.editor.buffer()) == "SELECT 1;\nSEl\nSEl"
        })
        .expect("l at both cursors");

        let opened = wait_until(Duration::from_millis(800), || completion_list_shown(&view));
        assert!(opened.is_err(), "the completion list opened with two cursors");
    }

    /// Shift+Alt+Down is GtkSourceView's scroll by a line until the editor
    /// takes it.
    #[gtk4::test]
    fn shift_alt_down_adds_a_cursor_and_ctrl_shift_l_one_at_every_match() {
        use gtk4::gdk::{Key, ModifierType};
        let harness = editor_with(answering(), "id\nid\nid");
        let _window = InWindow::presented(&harness.editor);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.start_iter());
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

        keys.press(Key::Down, ModifierType::SHIFT_MASK | ModifierType::ALT_MASK)
            .expect("the key press");
        wait_until(KEY_WAIT, || view.caret_count() == 2).expect("Shift+Alt+Down to add a cursor below");
        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || view.caret_count() == 1).expect("Escape to return to one cursor");

        keys.press(Key::l, ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK)
            .expect("the key press");
        wait_until(KEY_WAIT, || view.caret_count() == 3).expect("Ctrl+Shift+L to add a cursor at each match");
    }

    /// A snippet's stops follow GTK's cursor alone, so another cursor
    /// ends the snippet and Tab types at every cursor instead.
    #[gtk4::test]
    fn another_cursor_ends_the_snippet_being_filled_in() {
        use gtk4::gdk::Key;
        let harness = editor_with(answering(), "ins");
        let _window = InWindow::presented(&harness.editor);
        let view = harness.editor.imp().source_view.get();
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.end_iter());
        view.grab_focus();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");
        super::super::completion::accept_builtin_snippet(view.upcast_ref(), "ins");
        wait_until(KEY_WAIT, || {
            buffer_text(&buffer) == "INSERT INTO table_name (columns)\nVALUES (values);"
        })
        .unwrap_or_else(|_| panic!("the INSERT was not written: {:?}", buffer_text(&buffer)));

        view.toggle_caret_at(&buffer.end_iter());
        assert!(!view.enables_snippets());
        press(&keys, Key::Tab);
        wait_until(KEY_WAIT, || {
            buffer_text(&buffer) == "INSERT INTO \t (columns)\nVALUES (values);\t"
        })
        .unwrap_or_else(|_| panic!("Tab typed {:?}", buffer_text(&buffer)));

        press(&keys, Key::Escape);
        wait_until(KEY_WAIT, || view.caret_count() == 1).expect("Escape to return to one cursor");
        assert!(view.enables_snippets(), "one cursor takes snippets again");
    }
}

/// An editor on a Redis session, opened empty as a new tab is.
fn command_editor() -> (SqlEditor, crate::runtime::AppRuntime, MemorySettings) {
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let settings = MemorySettings::new();
    let fake = Arc::new(FakeEditorSession::new(Replies::default()));
    let script = ConnectionScript {
        dialect: Arc::new(tablepro_driver_redis::RedisDialect),
        ..ConnectionScript::default()
    };
    let active = ActiveSession::new();
    active.replace(session_on(fake, runtime.tasks(), script));
    let editor = SqlEditor::new(SqlEditorInit {
        initial_query: None,
        settings: settings.get().clone(),
        history: None,
        tasks: runtime.tasks(),
        session: active,
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
        close_timeout: Duration::from_secs(5),
        snippets: crate::test_support::builtin_snippets_only(),
    });
    (editor, runtime, settings)
}

#[gtk4::test]
fn a_command_editor_has_none_of_the_sql_tools() {
    let (editor, _runtime, _settings) = command_editor();

    let buffer = editor
        .buffer()
        .downcast::<sourceview5::Buffer>()
        .expect("a source buffer");
    assert!(buffer.language().is_none(), "commands coloured as SQL");
    assert_eq!(buffer_text(&editor.buffer()), "PING");
    let group = editor.imp().actions.get().expect("the editor's actions");
    for action in ["format", "toggle-comment"] {
        assert!(!group.is_action_enabled(action), "{action} is on");
    }
    assert!(group.is_action_enabled("run"));
    let providers = editor.imp().completion_providers.borrow().len();
    assert_eq!(
        providers, 2,
        "the document's words and the engine's own snippets complete"
    );
}

/// The bar names the tab's database and its default schema, as the
/// macOS editor bar does.
#[gtk4::test]
fn the_bar_names_the_tabs_database_and_schema() {
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let fake = Arc::new(FakeEditorSession::new(answering()));
    let mut request = FakeConnector::network_request("db.example", 5432).expect("a request");
    if let tablepro_session::connect::RequestTarget::Network { database, .. } = &mut request.target {
        *database = Some("shop".to_owned());
    }
    let mut script = ConnectionScript::default();
    let editor_session: Arc<dyn EditorSession> = fake;
    script.open_editor_session.always(FakeReply::ok(editor_session));
    let (pending, _) = FakeConnector::pending_session(request, script);
    let session = Session::start(
        pending,
        tablepro_session::SessionDeps {
            connector: Arc::new(FakeConnector::new([])),
            credentials: Arc::new(FakeCredentialSource::new()),
            deadlines: Arc::new(DefaultDeadlines::new(tablepro_core::LivenessPolicy::DESKTOP)),
            tasks: runtime.tasks(),
            prompter: None,
        },
    );
    let schema = |name: &str, is_default: bool| tablepro_core::meta::SchemaInfo {
        name: name.to_owned(),
        is_default,
        is_system: false,
    };
    session
        .catalog()
        .commit(vec![schema("public", true), schema("audit", false)], Vec::new());
    let active = ActiveSession::new();
    active.replace(session);
    let settings = MemorySettings::new();
    let editor = SqlEditor::new(SqlEditorInit {
        initial_query: None,
        settings: settings.get().clone(),
        history: None,
        tasks: runtime.tasks(),
        session: active,
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
        close_timeout: Duration::from_secs(5),
        snippets: crate::test_support::builtin_snippets_only(),
    });

    let label = editor.imp().scope_label.get();
    crate::test_support::wait_until(Duration::from_secs(5), || label.label() == "shop.public")
        .unwrap_or_else(|_| panic!("the bar says {:?}", label.label()));
    assert!(editor.imp().scope_box.is_visible());
}

/// The bar is a menu of the server's databases; picking one moves the
/// tab there, so the next run sends the engine's `USE` before the query.
#[gtk4::test]
fn picking_a_database_moves_the_tab_and_its_next_run() {
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let fake = Arc::new(FakeEditorSession::new(answering()));
    let mut request = FakeConnector::network_request("db.example", 3306).expect("a request");
    if let tablepro_session::connect::RequestTarget::Network { database, .. } = &mut request.target {
        *database = Some("shop".to_owned());
    }
    let database = |name: &str, is_default: bool, is_system: bool| tablepro_core::meta::SchemaInfo {
        name: name.to_owned(),
        is_default,
        is_system,
    };
    let mut script = ConnectionScript::default();
    script.list_databases.always(FakeReply::ok(vec![
        database("analytics", false, false),
        database("shop", true, false),
        database("mysql", false, true),
    ]));
    let editor_session: Arc<dyn EditorSession> = fake.clone();
    script.open_editor_session.always(FakeReply::ok(editor_session));
    let (pending, _) = FakeConnector::pending_session(request, script);
    let session = Session::start(
        pending,
        tablepro_session::SessionDeps {
            connector: Arc::new(FakeConnector::new([])),
            credentials: Arc::new(FakeCredentialSource::new()),
            deadlines: Arc::new(DefaultDeadlines::new(tablepro_core::LivenessPolicy::DESKTOP)),
            tasks: runtime.tasks(),
            prompter: None,
        },
    );
    let active = ActiveSession::new();
    active.replace(session);
    let settings = MemorySettings::new();
    let editor = SqlEditor::new(SqlEditorInit {
        initial_query: Some("SELECT 1".to_owned()),
        settings: settings.get().clone(),
        history: None,
        tasks: runtime.tasks(),
        session: active.clone(),
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
        close_timeout: Duration::from_secs(5),
        snippets: crate::test_support::builtin_snippets_only(),
    });
    let button = editor.imp().scope_button.get();
    crate::test_support::wait_until(Duration::from_secs(5), || button.is_visible()).expect("the database menu");

    WidgetExt::activate_action(&editor, "tab.database", Some(&"analytics".to_variant())).expect("tab.database");
    assert_eq!(editor.imp().scope_button_label.label(), "analytics");

    let harness = Harness {
        editor,
        fake: fake.clone(),
        history: None,
        active,
        settings,
        runtime,
    };
    run_and_wait(&harness);
    let sent = sent(&fake);
    assert!(
        sent.first()
            .is_some_and(|first| first.starts_with("USE ") && first.contains("analytics")),
        "{sent:?}"
    );
    assert_eq!(sent.last().map(String::as_str), Some("SELECT 1"));
}
