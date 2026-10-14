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

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    editor: SqlEditor,
    fake: Arc<FakeEditorSession>,
    history: Option<HistoryService>,
    active: ActiveSession,
    _settings: MemorySettings,
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
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let settings = MemorySettings::new();
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
    });
    Harness {
        editor,
        fake,
        history,
        active,
        _settings: settings,
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
fn a_copy_from_a_result_grid_reaches_the_clipboard() {
    use tablepro_core::column::{ColumnType, ResultColumn};

    use tablepro_core::Value;

    use crate::ui::clipboard::{CopyKind, CopyRequest};
    use crate::ui::grid::RowSnapshot;

    let harness = editor_with(answering(), "SELECT 1");
    let toasts = Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = toasts.clone();
    harness
        .editor
        .connect_toast(move |_, text| sink.borrow_mut().push(text));
    let grid = harness.editor.imp().grid_sink.get().expect("the grid's sink").clone();
    let clipboard = harness.editor.clipboard();
    clipboard.set_text("before");
    let columns: std::sync::Arc<[ResultColumn]> = ["a", "b"]
        .iter()
        .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
        .collect();
    let rows = vec![
        RowSnapshot::new(vec![Value::Int(1), Value::Text("x".into())].into(), Vec::new()),
        RowSnapshot::new(vec![Value::Int(2), Value::Text("y".into())].into(), Vec::new()),
    ];

    grid(GridMsg::Copy(CopyRequest::Rows {
        columns,
        rows,
        kind: CopyKind::Rows,
    }));
    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the copy to land");

    assert_eq!(*toasts.borrow(), ["Copied 2 rows".to_owned()]);
    assert!(clipboard.formats().contain_mime_type("text/tab-separated-values"));
    let text: Option<String> = clipboard
        .content()
        .and_then(|content| content.value(String::static_type()).ok())
        .and_then(|value| value.get().ok());
    assert_eq!(text.as_deref(), Some("1\tx\n2\ty\n"));
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
        dialect: Arc::new(drivers_sqlite::SqliteDialect::new(drivers_sqlite::SQLITE_MIN_VERSION)),
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
    assert_eq!(capped.title(), "Showing the first 3 rows");
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
    let scheme = scheme_id(&view);

    drop(editor);
    crate::test_support::drain_main_context();
    settings.get().set_style_scheme("classic").expect("a style scheme");
    style.set_color_scheme(adw::ColorScheme::ForceDark);
    let after = scheme_id(&view);
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
        self.0.set_child(None::<&gtk4::Widget>);
        self.0.destroy();
    }
}

fn editor_keys(harness: &Harness) -> gtk4::ShortcutController {
    crate::test_support::shortcut_keys::owner_controller(
        &harness.editor.imp().source_view.get(),
        crate::application::ShortcutOwner::SqlEditor,
    )
    .expect("the editor's shortcuts")
}

/// What `accel` does on the source view, as a key reaching the editor's
/// controller would. `false` when the key goes on.
fn press(harness: &Harness, accel: &str) -> bool {
    use crate::test_support::shortcut_keys::{keystroke, shortcuts, trigger_keys};
    let key = keystroke(accel);
    let action = shortcuts(&editor_keys(harness))
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
    let controller = editor_keys(&harness);

    assert!(
        class_keys.contains(&keystroke("<Primary>slash")),
        "the view's own bindings were not found, so the check reads nothing"
    );
    assert_eq!(controller.propagation_phase(), gtk4::PropagationPhase::Capture);
    for entry in ACCELERATORS {
        let AcceleratorScope::Local {
            owner: ShortcutOwner::SqlEditor,
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
}
