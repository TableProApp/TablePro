//! The desktop entry offers TablePro for SQLite files and hands them
//! over the way the application expects.

use std::path::Path;

const MAIN: &str = "Desktop Entry";
const NEW_WINDOW: &str = "Desktop Action new-window";

fn entry() -> Result<glib::KeyFile, glib::Error> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data/app.tablepro.TablePro.desktop.in.in");
    let entry = glib::KeyFile::new();
    entry.load_from_file(&path, glib::KeyFileFlags::NONE)?;
    Ok(entry)
}

fn list(entry: &glib::KeyFile, group: &str, key: &str) -> Result<Vec<String>, glib::Error> {
    Ok(entry
        .string_list(group, key)?
        .iter()
        .map(|item| item.to_string())
        .collect())
}

#[test]
fn sqlite_files_are_offered_to_tablepro() {
    let entry = entry().expect("the desktop entry parses");

    let types = list(&entry, MAIN, "MimeType").expect("a MimeType list");

    assert!(
        types.contains(&"application/vnd.sqlite3".to_owned()),
        "the entry does not take SQLite files: {types:?}"
    );
}

#[test]
fn files_reach_the_running_application() {
    let entry = entry().expect("the desktop entry parses");

    let exec = entry.string(MAIN, "Exec").expect("an Exec line");

    assert!(exec.ends_with(" %U"), "Exec passes no files: {exec}");
    assert!(
        entry.boolean(MAIN, "DBusActivatable").expect("DBusActivatable"),
        "files would start a second process instead of reaching the running one"
    );
}

#[test]
fn new_window_is_a_desktop_action() {
    let entry = entry().expect("the desktop entry parses");

    let actions = list(&entry, MAIN, "Actions").expect("an Actions list");
    let name = entry.string(NEW_WINDOW, "Name").expect("the action's name");

    assert!(actions.contains(&"new-window".to_owned()), "{actions:?}");
    assert!(!name.is_empty());
}

/// GNOME Settings lists an application under Notifications only when
/// its entry says it sends them.
#[test]
fn notifications_can_be_turned_off_in_settings() {
    let entry = entry().expect("the desktop entry parses");

    assert!(
        entry
            .boolean(MAIN, "X-GNOME-UsesNotifications")
            .expect("X-GNOME-UsesNotifications"),
        "TablePro is missing from the Notifications settings"
    );
}
