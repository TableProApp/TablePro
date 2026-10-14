//! Files the application hands to its windows, from Open With or the
//! command line.

use gtk4::prelude::*;

use super::tests::{TestWindow, WAIT};
use super::*;
use crate::test_support::wait_until;

/// An empty file, which SQLite reads as an empty database.
fn database(dir: &tempfile::TempDir, name: &str) -> gio::File {
    let file = gio::File::for_path(dir.path().join(name));
    file.replace_contents(b"", None, false, gio::FileCreateFlags::NONE, gio::Cancellable::NONE)
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
