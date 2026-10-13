use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{DriverError, EditorSession, TransactionState};
use tablepro_session::Session;
use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
use tablepro_session::operation::DefaultDeadlines;
use tablepro_test_support::{ConnectionScript, FakeEditorSession, FakeReply, FakeRun, Replies};

use super::*;
use crate::test_support::{MemorySettings, SignalLog, wait_until};

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    editor: SqlEditor,
    fake: Arc<FakeEditorSession>,
    _settings: MemorySettings,
    _runtime: crate::runtime::AppRuntime,
}

fn session_with(fake: Arc<FakeEditorSession>, tasks: Tasks) -> Arc<Session> {
    let mut script = ConnectionScript::default();
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
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let settings = MemorySettings::new();
    let fake = Arc::new(FakeEditorSession::new(runs));
    let active = ActiveSession::new();
    active.replace(session_with(fake.clone(), runtime.tasks()));
    let editor = SqlEditor::new(SqlEditorInit {
        schema_buffer: build_schema_buffer(),
        initial_query: Some(text.to_owned()),
        settings: settings.get().clone(),
        history: None,
        tasks: runtime.tasks(),
        session: active,
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
        close_timeout: Duration::from_secs(5),
    });
    Harness {
        editor,
        fake,
        _settings: settings,
        _runtime: runtime,
    }
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
    let harness = editor_with(runs, "BEGIN; UPDATE t SET a = 1");
    let changes = SignalLog::connect(&harness.editor, "transaction-changed", |values| {
        values[1].get::<bool>().expect("a flag")
    });

    run_and_wait(&harness);

    assert!(harness.editor.has_open_transaction());
    assert_eq!(changes.take(), [true]);
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
