//! Files the application hands to its windows, from Open With or the
//! command line.

use std::time::Duration;

use gtk4::prelude::*;
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript};

use super::super::*;
use super::{Script, TestWindow, WAIT, editors};
use crate::test_support::{drain_main_context, wait_until};

/// An empty file, which SQLite reads as an empty database.
fn database(dir: &tempfile::TempDir, name: &str) -> gio::File {
    let file = gio::File::for_path(dir.path().join(name));
    file.replace_contents(b"", None, false, gio::FileCreateFlags::NONE, gio::Cancellable::NONE)
        .expect("seed the database file");
    file
}

/// A file carrying the second file engine's signature, under a name the
/// first engine claims.
fn signed_database(dir: &tempfile::TempDir, name: &str) -> gio::File {
    let mut header = vec![0u8; 64];
    let signature = tablepro_test_support::FakeDriver::SIGNED_FILE_SIGNATURE;
    header[signature.offset..signature.header_len()].copy_from_slice(signature.bytes);
    let file = gio::File::for_path(dir.path().join(name));
    file.replace_contents(&header, None, false, gio::FileCreateFlags::NONE, gio::Cancellable::NONE)
        .expect("seed the database file");
    file
}

fn other_windows(test: &TestWindow) -> Vec<SessionWindow> {
    test.app
        .windows()
        .into_iter()
        .filter_map(|window| window.downcast::<SessionWindow>().ok())
        .filter(|window| window != &test.window)
        .collect()
}

#[gtk4::test]
fn an_opened_file_goes_to_the_idle_window_then_its_owner_then_a_new_window() {
    let test = TestWindow::picker("OpenFiles");
    let dir = tempfile::tempdir().expect("tempdir");
    let first = database(&dir, "first.sqlite3");
    let second = database(&dir, "second.sqlite3");

    test.app.open(std::slice::from_ref(&first), "");
    test.wait_for_page("workspace");
    assert_eq!(test.app.windows().len(), 1, "the idle picker did not take the file");

    test.window.set_visible(false);
    test.app.open(&[first], "");
    wait_until(WAIT, || test.window.is_visible()).expect("the file's window to come forward");
    assert_eq!(test.app.windows().len(), 1, "a second window opened on the same file");
    assert_eq!(test.connector.calls().len(), 1, "the open file was connected to again");

    test.app.open(&[second], "");
    wait_until(WAIT, || {
        other_windows(&test)
            .iter()
            .any(|window| window.page_name() == "workspace")
    })
    .expect("a new window on the second file");
    assert_eq!(test.app.windows().len(), 2);
}

/// Files hands over a file by its path alone, and the file's own header
/// says which engine opens it, whatever its name.
#[gtk4::test]
fn an_opened_file_goes_to_the_engine_whose_file_it_is() {
    let test = TestWindow::picker("OpenFileEngine");
    let dir = tempfile::tempdir().expect("tempdir");
    let file = signed_database(&dir, "sales.db");

    test.app.open(std::slice::from_ref(&file), "");
    test.wait_for_page("workspace");

    let calls = test.connector.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].request.metadata.driver_id, "duckdb");
}

#[gtk4::test]
fn a_window_opened_for_a_file_another_window_has_closes_again() {
    let test = TestWindow::picker("OpenFileTwice");
    let dir = tempfile::tempdir().expect("tempdir");
    let file = database(&dir, "app.sqlite3");
    test.window.send(SessionWindowInput::OpenFile(file.clone()));
    test.wait_for_page("workspace");
    test.window.set_visible(false);

    assert!(test.app.open_window(WindowLaunch::OpenFile(file)).is_some());
    wait_until(WAIT, || test.app.windows().len() == 1).expect("the extra window to close");

    assert!(test.window.is_visible(), "the file's window stayed hidden");
    assert_eq!(test.connector.calls().len(), 1);
}

#[gtk4::test]
fn a_window_resolving_a_file_takes_no_other() {
    let test = TestWindow::picker("OpenFileBusy");
    assert!(test.window.is_idle());

    test.window.imp().opening_file.set(true);
    assert!(!test.window.is_idle());
    test.window.imp().opening_file.set(false);
    test.window.send(SessionWindowInput::OpenConnectDialog);
    wait_until(WAIT, || !test.window.is_idle()).expect("the connect dialog to count as busy");
}

fn script(test: &TestWindow, name: &str, text: &str) -> gio::File {
    let path = test.dir().join(name);
    crate::test_support::write_text_file(&path, text);
    gio::File::for_path(path)
}

// The test's own session would be restored from the record in a second
// window, which an open before any activate reads.
fn open(test: &TestWindow, files: &[gio::File]) {
    test.services
        .settings
        .set_restore_session(false)
        .expect("turn restoring off");
    // A window still reading its saved tabs sends the script to a picker instead.
    if test.window.page_name() == "workspace" {
        wait_until(WAIT, || !test.window.settling()).expect("the saved tabs read");
    }
    test.app.open(files, "");
}

fn text_of(editor: &crate::ui::editor::SqlEditor) -> String {
    let buffer = editor.buffer();
    buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
}

fn bound_to(editor: &crate::ui::editor::SqlEditor, file: &gio::File) -> bool {
    editor.file().is_some_and(|bound| bound.equal(file))
}

fn script_editor(window: &SessionWindow, file: &gio::File) -> crate::ui::editor::SqlEditor {
    let mut found = None;
    wait_until(WAIT, || {
        found = editors(window).into_iter().find(|editor| bound_to(editor, file));
        found.is_some()
    })
    .expect("an editor tab bound to the file");
    found.expect("the editor")
}

fn script_banner(test: &TestWindow) -> adw::Banner {
    test.window.script_banner().expect("the picker's script banner")
}

#[gtk4::test]
fn a_sql_file_opens_in_the_session_in_front_without_running() {
    let test = TestWindow::connected("OpenScript");
    let counters = test.connection().counters();
    let file = script(&test, "report.sql", "DELETE FROM orders;\n");

    open(&test, std::slice::from_ref(&file));
    let editor = script_editor(&test.window, &file);
    drain_main_context();

    assert_eq!(text_of(&editor), "DELETE FROM orders;\n");
    assert!(!editor.has_unsaved_file_changes(), "the tab differs from its file");
    let page = test
        .window
        .shell()
        .and_then(|shell| shell.tab_view().selected_page())
        .expect("a tab in front");
    assert_eq!(page.title(), "report.sql");
    assert!(!editor.is_running(), "the script ran");
    assert_eq!(CallCounters::get(&counters.open_editor_session), 0, "the script ran");
    assert_eq!(test.connector.calls().len(), 1, "the script was opened as a database");
    assert_eq!(test.app.windows().len(), 1, "the script opened another window");
}

#[gtk4::test]
fn a_sql_file_on_the_picker_waits_for_a_connection() {
    let test = TestWindow::picker("ScriptWaits");
    let banner = script_banner(&test);
    let file = script(&test, "report.sql", "SELECT 1;");

    open(&test, std::slice::from_ref(&file));
    wait_until(WAIT, || banner.is_revealed()).expect("the banner asking for a connection");
    assert_eq!(banner.title(), "Choose a connection to open “report.sql”");
    assert!(test.connector.calls().is_empty(), "the script was opened as a database");
    assert_eq!(test.window.page_name(), "picker");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let editor = script_editor(&test.window, &file);

    assert_eq!(text_of(&editor), "SELECT 1;");
    assert!(!banner.is_revealed(), "the banner stayed once the script opened");
    assert_eq!(test.app.windows().len(), 1);
}

#[gtk4::test]
fn the_banner_cancel_drops_the_waiting_scripts() {
    let test = TestWindow::picker("ScriptCancel");
    let banner = script_banner(&test);
    let files = [
        script(&test, "first.sql", "SELECT 1;"),
        script(&test, "second.sql", "SELECT 2;"),
    ];

    open(&test, &files);
    wait_until(WAIT, || banner.title() == "Choose a connection to open 2 SQL files").expect("both scripts waiting");
    assert!(banner.is_revealed());
    banner.emit_by_name::<()>("button-clicked", &[]);
    wait_until(WAIT, || !banner.is_revealed()).expect("the banner to go");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let _ = wait_until(Duration::from_millis(300), || false);
    drain_main_context();

    assert!(
        editors(&test.window)
            .iter()
            .all(|editor| files.iter().all(|file| !bound_to(editor, file))),
        "a dropped script opened"
    );
}

// A session still connecting may bring the file back in a saved tab, so a picker of its own asks.
#[gtk4::test]
fn a_sql_file_while_a_window_connects_asks_in_a_picker_of_its_own() {
    let test = TestWindow::with_script(
        "ScriptConnecting",
        Script {
            establish: vec![FakeEstablish::Late {
                after: Duration::from_secs(2),
                script: ConnectionScript::default(),
            }],
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connecting");
    let file = script(&test, "report.sql", "SELECT 1;");

    open(&test, std::slice::from_ref(&file));
    let asking = || {
        test.app
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<SessionWindow>().ok())
            .find(|window| window.script_banner().is_some_and(|banner| banner.is_revealed()))
    };
    wait_until(WAIT, || asking().is_some()).expect("a picker asking for a connection");
    test.wait_for_page("workspace");
    drain_main_context();

    assert!(
        asking().is_some_and(|window| window != test.window),
        "the connecting window took the script"
    );
    assert!(
        editors(&test.window).iter().all(|editor| !bound_to(editor, &file)),
        "the script opened in the session that was connecting"
    );
}

#[gtk4::test]
fn an_unreadable_sql_file_says_why_and_opens_nothing() {
    let test = TestWindow::connected("ScriptNotUtf8");
    let path = test.dir().join("latin1.sql");
    std::fs::write(&path, b"SELECT 'caf\xe9';").expect("seed the script");
    let file = gio::File::for_path(&path);

    open(&test, std::slice::from_ref(&file));
    wait_until(WAIT, || {
        test.window
            .imp()
            .toasts
            .borrow()
            .iter()
            .any(|toast| toast.title().is_some_and(|title| title.contains("not UTF-8 text")))
    })
    .expect("a toast saying why");
    drain_main_context();

    assert!(
        editors(&test.window).iter().all(|editor| !bound_to(editor, &file)),
        "a tab opened on the file"
    );
    assert!(!script_banner(&test).is_revealed(), "the window asked for a connection");
}

#[gtk4::test]
fn a_sql_file_already_open_brings_its_tab_forward() {
    let test = TestWindow::connected("ScriptTwice");
    let file = script(&test, "report.sql", "SELECT 1;");
    open(&test, std::slice::from_ref(&file));
    let editor = script_editor(&test.window, &file);
    let shell = test.window.shell().expect("the shell");
    let in_front = || {
        shell
            .tab_view()
            .selected_page()
            .is_some_and(|page| page.child() == editor.clone().upcast::<gtk::Widget>())
    };
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || !in_front()).expect("another tab in front");

    test.app.open(std::slice::from_ref(&file), "");
    wait_until(WAIT, in_front).expect("the script's tab in front");

    let bound = editors(&test.window)
        .iter()
        .filter(|editor| bound_to(editor, &file))
        .count();
    assert_eq!(bound, 1, "a second tab opened on the file");
    assert_eq!(test.app.windows().len(), 1);
}

fn shared(window: &SessionWindow, title: &str, sql: &str) {
    window.send(SessionWindowInput::Script(ScriptInput::Shared {
        title: title.to_owned(),
        sql: sql.to_owned(),
    }));
}

fn editor_with_text(window: &SessionWindow, text: &str) -> crate::ui::editor::SqlEditor {
    let mut found = None;
    wait_until(WAIT, || {
        found = editors(window).into_iter().find(|editor| text_of(editor) == text);
        found.is_some()
    })
    .expect("an editor tab with the shared SQL");
    found.expect("the editor")
}

#[gtk4::test]
fn a_shared_query_opens_in_a_new_tab_of_the_session_in_front_without_running() {
    let test = TestWindow::connected("SharedQuery");
    wait_until(WAIT, || !test.window.settling()).expect("the saved tabs read");
    let counters = test.connection().counters();
    let before = editors(&test.window).len();

    shared(&test.window, "Orders", "DELETE FROM orders;");
    let editor = editor_with_text(&test.window, "DELETE FROM orders;");
    drain_main_context();

    assert_eq!(editors(&test.window).len(), before + 1, "the SQL took over a tab");
    assert!(editor.file().is_none(), "a shared query is bound to a file");
    assert!(!editor.is_running(), "the shared query ran");
    assert_eq!(
        CallCounters::get(&counters.open_editor_session),
        0,
        "the shared query ran"
    );
    assert_eq!(test.app.windows().len(), 1);
}

#[gtk4::test]
fn a_shared_query_on_the_picker_waits_for_a_connection() {
    let test = TestWindow::picker("SharedQueryWaits");
    let banner = script_banner(&test);

    shared(&test.window, "Orders", "SELECT 1;");
    wait_until(WAIT, || banner.is_revealed()).expect("the banner asking for a connection");
    assert_eq!(banner.title(), "Choose a connection to open “Orders”");
    shared(&test.window, "", "SELECT 2;");
    wait_until(WAIT, || banner.title() == "Choose a connection to open 2 queries").expect("both waiting");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    editor_with_text(&test.window, "SELECT 1;");
    editor_with_text(&test.window, "SELECT 2;");

    assert!(!banner.is_revealed(), "the banner stayed once the queries opened");
}

#[gtk4::test]
fn a_share_link_that_cannot_open_says_so_in_the_window_in_front() {
    let test = TestWindow::connected("ShareLinkToast");
    crate::services::connection_link::register_link_schemes().expect("register the links");

    open(&test, &[gio::File::for_uri("tablepro://share?token=short")]);

    wait_until(WAIT, || {
        test.window
            .toast_titles()
            .contains(&"This shared link is no longer available.".to_owned())
    })
    .expect("the toast in the window in front");
    assert_eq!(test.app.windows().len(), 1, "a picker opened only to say it");
}
