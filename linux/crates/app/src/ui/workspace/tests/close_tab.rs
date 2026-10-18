use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita::prelude::*;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::meta::{RowCountEstimate, RowIdentity, TableEstimate};
use tablepro_core::{ColumnInfo, QueryResult, Value};
use tablepro_test_support::{ConnectionScript, FakeReply};
use uuid::Uuid;

use super::super::{OpenMode, WorkspaceInput};
use crate::runtime::DeliverInput;
use crate::test_support::{after_next_frame, descendants, drain_main_context, wait_until};
use crate::ui::browse_tab::BrowseTab;
use crate::ui::grid::GridCell;
use crate::ui::session_window::tests::{TestWindow, WAIT};
use crate::workspace::{answer, visible_alert};

fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

/// Every table has the same two keyed rows.
fn serving_tables(script: &mut ConnectionScript) {
    let columns = [column("id", true), column("name", false)];
    script.fetch_columns.always(FakeReply::ok(columns.to_vec()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(2));
    script.table_estimate.always(FakeReply::ok(TableEstimate {
        rows: RowCountEstimate::Approximate(2),
        heap_blocks: None,
    }));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![
            vec![Value::Int(1), Value::Text("Ada".to_owned())],
            vec![Value::Int(2), Value::Text("Grace".to_owned())],
        ],
    )));
}

/// Open `name` in a tab of its own, which comes to the front.
fn open_table(test: &TestWindow, name: &str) -> (Uuid, BrowseTab) {
    let workspace = test.workspace();
    let before = workspace.selected_tab();
    workspace
        .input()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::SelectTable {
            schema: None,
            name: name.to_owned(),
            open_mode: OpenMode::NewTab,
        });
    let mut id = None;
    wait_until(WAIT, || {
        id = workspace.selected_tab().filter(|tab| Some(*tab) != before);
        id.is_some()
    })
    .expect("the table's tab");
    let tab = workspace
        .imp()
        .tab_view
        .selected_page()
        .and_then(|page| page.child().downcast::<BrowseTab>().ok())
        .expect("a table tab in front");
    (id.expect("the tab's id"), tab)
}

/// Give the keyboard focus to the name of the first row.
fn focus_name(test: &TestWindow, tab: &BrowseTab) -> GridCell {
    let mut grid = None;
    wait_until(WAIT, || {
        grid = descendants(tab)
            .into_iter()
            .find_map(|widget| widget.downcast::<gtk::ColumnView>().ok())
            .filter(|view| view.model().is_some_and(|model| model.n_items() == 2));
        grid.is_some()
    })
    .expect("the rows");
    let view = grid.expect("the grid");
    let name = crate::ui::grid::data_columns(&view)
        .into_iter()
        .nth(1)
        .expect("the name column");
    view.scroll_to(0, Some(&name), gtk::ListScrollFlags::FOCUS, None);
    view.grab_focus();
    let focused = || gtk::prelude::GtkWindowExt::focus(&test.window).and_then(|focus| GridCell::from_focus(&focus));
    wait_until(WAIT, || {
        focused().is_some_and(|cell| cell.position() == Some(0) && cell.column() == 1)
    })
    .expect("the cell takes the focus");
    focused().expect("the focused cell")
}

/// What was typed is an unsaved change like any other, so the close asks
/// about it. GTK 4.22 loops forever, logging a critical, when the field
/// leaves its cell while the focus change is under way.
#[gtk4::test]
fn closing_a_tab_while_a_cell_is_edited_asks_about_the_edit() {
    let test = TestWindow::connected_with("CloseWhileEditing", serving_tables);
    let (id, tab) = open_table(&test, "users");
    let cell = focus_name(&test, &tab);
    crate::ui::grid::begin_edit(&cell);
    cell.inline_text().expect("a one-line field").set_text("Ada Lovelace");

    let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
    WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");
    drain_main_context();
    glib::log_set_always_fatal(previous);

    wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the close asks about the edit");
    let tracker = test.workspace().row_tracker(id).expect("the tab's changes");
    assert_eq!(tracker.pending_count(), 1, "what was typed is not an unsaved change");
    assert!(!cell.is_editing());

    let closed = tab.downgrade();
    drop((tab, cell));
    assert!(answer(&test.window, "discard"));
    wait_until(WAIT, || test.workspace().row_tracker(id).is_none()).expect("the tab closes");
    after_next_frame(&test.window);
    wait_until(WAIT, || closed.upgrade().is_none()).expect("the closed tab is freed");
}

#[gtk4::test]
fn closing_the_window_while_a_cell_is_edited_asks_about_the_edit() {
    let test = TestWindow::connected_with("CloseWindowWhileEditing", serving_tables);
    let (id, tab) = open_table(&test, "users");
    let cell = focus_name(&test, &tab);
    crate::ui::grid::begin_edit(&cell);
    cell.inline_text().expect("a one-line field").set_text("Ada Lovelace");

    test.window.close();

    wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the close asks about the edit");
    let tracker = test.workspace().row_tracker(id).expect("the tab's changes");
    assert_eq!(tracker.pending_count(), 1, "what was typed is not an unsaved change");
    assert!(answer(&test.window, "cancel"));
    drain_main_context();
    assert_eq!(test.app.windows().len(), 1, "Cancel closed the window");
}

/// The focus leaves the tab before it goes. GTK 4.22 leaks a focus that
/// is hidden and then unparented in one go, with the tab around it, which
/// the close does when the tab shown next takes no focus.
#[gtk4::test]
fn a_tab_closed_with_the_focus_in_it_is_freed_when_the_next_takes_none() {
    let test = TestWindow::connected_with("CloseFocusedTab", serving_tables);
    let (_, next) = open_table(&test, "orders");
    next.set_can_focus(false);
    let (_, tab) = open_table(&test, "users");
    drop(focus_name(&test, &tab));
    let closed = tab.downgrade();
    drop(tab);

    WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");
    drain_main_context();
    after_next_frame(&test.window);

    wait_until(WAIT, || closed.upgrade().is_none()).expect("the closed tab is freed");
    assert!(
        gtk::prelude::GtkWindowExt::focus(&test.window).is_some_and(|focus| focus.root().is_some()),
        "the focus was left nowhere"
    );
}

/// An editor tab saved to `path`, whose text has changed since.
fn editor_on_file(test: &TestWindow, path: &std::path::Path) -> (Uuid, crate::ui::editor::SqlEditor) {
    let workspace = test.workspace();
    workspace.with_model(|model| {
        model.open_tab(super::super::tab_spec::TabSpec::Editor {
            initial_query: Some("SELECT 2;".to_owned()),
            draft: None,
            file: Some(crate::workspace::EditorFileRecord {
                uri: gtk::gio::File::for_path(path).uri().to_string(),
                modified: true,
            }),
        })
    });
    let id = workspace.selected_tab().expect("the editor in front");
    let editor = workspace
        .imp()
        .tab_view
        .selected_page()
        .and_then(|page| page.child().downcast::<crate::ui::editor::SqlEditor>().ok())
        .expect("an editor tab in front");
    (id, editor)
}

fn tab_is_open(test: &TestWindow, id: Uuid) -> bool {
    test.workspace()
        .read(|model| model.workspace_tabs.borrow().contains_key(&id))
        .unwrap_or(false)
}

#[gtk4::test]
fn closing_a_tab_with_unsaved_file_changes_saves_them_when_asked() {
    let test = TestWindow::connected("CloseUnsavedFileSave");
    let path = test.dir().join("daily.sql");
    crate::test_support::write_text_file(&path, "SELECT 1;");
    let (id, _editor) = editor_on_file(&test, &path);

    WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");

    wait_until(WAIT, || {
        visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some("Save Changes?"))
    })
    .expect("the close asks about the file");
    assert!(answer(&test.window, "save"));
    wait_until(WAIT, || !tab_is_open(&test, id)).expect("the tab closes once saved");
    assert_eq!(crate::test_support::read_text_file(&path), "SELECT 2;");
}

#[gtk4::test]
fn discarding_unsaved_file_changes_closes_the_tab_and_leaves_the_file() {
    let test = TestWindow::connected("CloseUnsavedFileDiscard");
    let path = test.dir().join("daily.sql");
    crate::test_support::write_text_file(&path, "SELECT 1;");
    let (id, _editor) = editor_on_file(&test, &path);

    WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");

    wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the close asks about the file");
    assert!(answer(&test.window, "discard"));
    wait_until(WAIT, || !tab_is_open(&test, id)).expect("the tab closes");
    assert!(visible_alert(&test.window).is_none(), "the close asked again");
    assert_eq!(crate::test_support::read_text_file(&path), "SELECT 1;");
}

/// The window keeps the text with the tab's draft and restores both.
#[gtk4::test]
fn closing_the_window_keeps_unsaved_file_changes_without_asking() {
    let test = TestWindow::connected("CloseWindowUnsavedFile");
    let path = test.dir().join("daily.sql");
    crate::test_support::write_text_file(&path, "SELECT 1;");
    let (_id, editor) = editor_on_file(&test, &path);
    assert!(editor.has_unsaved_file_changes());
    drop(editor);

    test.window.close();

    wait_until(WAIT, || test.app.windows().is_empty()).expect("the window closes");
}
