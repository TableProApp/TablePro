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
use super::shell_of;
use crate::runtime::DeliverInput;
use crate::test_support::{after_next_frame, drain_main_context, wait_until};
use crate::ui::browse_tab::BrowseTab;
use crate::ui::data_grid::GridCell;
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
        partition_scoped: false,
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
        .sender()
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
    let tab = shell_of(&workspace)
        .imp()
        .tab_view
        .selected_page()
        .and_then(|page| page.child().downcast::<BrowseTab>().ok())
        .expect("a table tab in front");
    (id.expect("the tab's id"), tab)
}

/// Give the keyboard focus to the name of the first row.
fn focus_name(tab: &BrowseTab) -> GridCell {
    let grid = tab.grid();
    wait_until(WAIT, || grid.row_count() == 2).expect("the rows");
    let mut focused = None;
    wait_until(WAIT, || {
        focused = grid.focus_cell(0, 1);
        focused.is_some()
    })
    .expect("the cell takes the focus");
    focused.expect("the focused cell")
}

/// Open the name's one-line editor and type over it, leaving it open.
fn type_a_name(tab: &BrowseTab) -> GridCell {
    let cell = focus_name(tab);
    let grid = tab.grid();
    assert!(grid.edit().edit_cell(&cell), "the name took no edit");
    grid.edit()
        .open_text()
        .expect("a one-line field")
        .set_text("Ada Lovelace");
    cell
}

/// What was typed is an unsaved change like any other, so the close asks
/// about it. GTK 4.22 loops forever, logging a critical, when the field
/// leaves its cell while the focus change is under way.
#[gtk4::test]
fn closing_a_tab_while_a_cell_is_edited_asks_about_the_edit() {
    let test = TestWindow::connected_with("CloseWhileEditing", serving_tables);
    let (id, tab) = open_table(&test, "users");
    let cell = type_a_name(&tab);

    let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
    WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");
    drain_main_context();
    glib::log_set_always_fatal(previous);

    wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the close asks about the edit");
    let changes = super::row_tracker(&test.workspace(), id).expect("the tab's changes");
    assert_eq!(changes.pending_count(), 1, "what was typed is not an unsaved change");
    assert!(!cell.is_editing());

    let closed = tab.downgrade();
    drop((tab, cell));
    assert!(answer(&test.window, "discard"));
    wait_until(WAIT, || super::row_tracker(&test.workspace(), id).is_none()).expect("the tab closes");
    after_next_frame(&test.window);
    wait_until(WAIT, || closed.upgrade().is_none()).expect("the closed tab is freed");
}

#[gtk4::test]
fn closing_the_window_while_a_cell_is_edited_asks_about_the_edit() {
    let test = TestWindow::connected_with("CloseWindowWhileEditing", serving_tables);
    let (id, tab) = open_table(&test, "users");
    let cell = type_a_name(&tab);
    assert_eq!(
        super::row_tracker(&test.workspace(), id).map(|tracker| tracker.pending_count()),
        Some(0),
        "the edit counted before the close committed it"
    );

    test.window.close();

    wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the close asks about the edit");
    let changes = super::row_tracker(&test.workspace(), id).expect("the tab's changes");
    assert_eq!(changes.pending_count(), 1, "what was typed is not an unsaved change");
    assert!(answer(&test.window, "cancel"));
    drain_main_context();
    assert_eq!(test.app.windows().len(), 1, "Cancel closed the window");
    assert!(!cell.is_editing());
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
    drop(focus_name(&tab));
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
            database: None,
        })
    });
    let id = workspace.selected_tab().expect("the editor in front");
    let editor = shell_of(&workspace)
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

/// Vim's `:q` closes its own tab through the prompts Ctrl+W meets.
#[gtk4::test]
fn an_editor_asking_to_close_goes_through_the_close_prompts() {
    let test = TestWindow::connected("VimQuitUnsavedFile");
    let path = test.dir().join("daily.sql");
    crate::test_support::write_text_file(&path, "SELECT 1;");
    let (id, editor) = editor_on_file(&test, &path);

    editor.emit_by_name::<()>("close-requested", &[]);

    wait_until(WAIT, || {
        visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some("Save Changes?"))
    })
    .expect("the close asks about the file");
    assert!(answer(&test.window, "discard"));
    wait_until(WAIT, || !tab_is_open(&test, id)).expect("the tab closes");
    assert_eq!(crate::test_support::read_text_file(&path), "SELECT 1;");
}

/// A `:wq` whose write lands after the user moved to another tab still
/// closes the tab it was typed in.
#[gtk4::test]
fn an_editor_asking_to_close_closes_its_own_tab_not_the_one_in_front() {
    let test = TestWindow::connected("VimQuitBackgroundTab");
    let workspace = test.workspace();
    let open_editor = |query: &str| {
        workspace.with_model(|model| {
            model.open_tab(super::super::tab_spec::TabSpec::Editor {
                initial_query: Some(query.to_owned()),
                draft: None,
                file: None,
                database: None,
            })
        });
        let page = shell_of(&workspace)
            .imp()
            .tab_view
            .selected_page()
            .expect("the editor in front");
        let editor = page
            .child()
            .downcast::<crate::ui::editor::SqlEditor>()
            .expect("an editor tab");
        (workspace.selected_tab().expect("its id"), editor)
    };
    let (behind, editor) = open_editor("SELECT 1;");
    let (front, _) = open_editor("SELECT 2;");

    editor.emit_by_name::<()>("close-requested", &[]);

    wait_until(WAIT, || !tab_is_open(&test, behind)).expect("the tab that asked closes");
    assert!(tab_is_open(&test, front));
    assert_eq!(workspace.selected_tab(), Some(front));
}

/// Close All Tabs asks about each tab as its close button would.
#[gtk4::test]
fn close_all_tabs_asks_before_closing_unsaved_work() {
    let test = TestWindow::connected("CloseAllUnsavedFile");
    let path = test.dir().join("daily.sql");
    crate::test_support::write_text_file(&path, "SELECT 1;");
    let (id, _editor) = editor_on_file(&test, &path);
    let workspace = test.workspace();
    super::open_editor(&workspace);
    let view = shell_of(&workspace).tab_view();

    WidgetExt::activate_action(&test.window, "win.close-all-tabs", None).expect("win.close-all-tabs");

    wait_until(WAIT, || {
        visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some("Save Changes?"))
    })
    .expect("the close asks about the file");
    assert!(answer(&test.window, "cancel"));
    wait_until(WAIT, || view.n_pages() == 1).expect("the tabs with nothing to lose to close");
    assert!(tab_is_open(&test, id), "the tab with unsaved changes closed");
    assert_eq!(crate::test_support::read_text_file(&path), "SELECT 1;");
}

#[gtk4::test]
fn header_save_commits_the_first_inline_edit_and_follows_the_running_save() {
    use tablepro_core::WriteReport;
    use tablepro_test_support::CallCounters;
    use tokio_util::sync::CancellationToken;

    let release = CancellationToken::new();
    let test = TestWindow::connected_with("HeaderInlineSave", |script| {
        serving_tables(script);
        script.write_batch.always(FakeReply::UntilReleased {
            release: release.clone(),
            outcome: Ok(WriteReport::new(vec![Some(1)])),
        });
    });
    let (id, tab) = open_table(&test, "users");
    let shell = shell_of(&test.workspace());
    let button = shell.imp().save_changes_button.get();
    crate::test_support::assert_labelled(&button).expect("Save Changes has a name");
    assert_eq!(button.tooltip_text().as_deref(), Some("Save Changes"));
    assert!(gtk::test_accessible_has_property(
        &button,
        gtk::AccessibleProperty::KeyShortcuts
    ));
    assert!(!button.is_sensitive());
    let cell = type_a_name(&tab);
    let changes = super::row_tracker(&test.workspace(), id).expect("the changes");
    assert_eq!(changes.pending_count(), 0);
    wait_until(WAIT, || button.is_sensitive()).expect("Save Changes for the first inline edit");

    button.emit_clicked();

    let connection = test.connection();
    wait_until(WAIT, || CallCounters::get(&connection.counters().write_batch) == 1)
        .expect("the header starts the write");
    assert!(!cell.is_editing());
    assert!(!button.is_sensitive(), "Save stays disabled during its write");
    assert!(
        connection
            .observed_sql("write_batch")
            .iter()
            .flatten()
            .any(|sql| sql.contains("UPDATE"))
    );
    release.cancel();
    wait_until(WAIT, || changes.pending_count() == 0 && !test.workspace().is_saving()).expect("the save settles");
    assert!(!button.is_sensitive(), "the saved tab has nothing to save");
}

#[gtk4::test]
fn header_save_follows_sidebar_selection_and_drops_the_previous_tabs_state() {
    let test = TestWindow::connected_with("HeaderSidebarSave", serving_tables);
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let button = shell.imp().save_changes_button.get();
    let (first, tab) = open_table(&test, "users");
    type_a_name(&tab);
    tab.grid().commit_edit();
    wait_until(WAIT, || button.is_sensitive()).expect("the first tab has edits");
    let (_, other) = open_table(&test, "teams");
    assert!(!button.is_sensitive());

    workspace.sender().expect("input").deliver(WorkspaceInput::SelectTable {
        schema: None,
        name: "users".to_owned(),
        open_mode: OpenMode::SwitchOrAppend,
    });
    wait_until(WAIT, || workspace.selected_tab() == Some(first)).expect("sidebar selects the edited tab");
    assert!(
        button.is_sensitive(),
        "selection under the workspace borrow lost the action state"
    );

    other.send(crate::ui::browse_tab::SaveInput::SaveStarted);
    assert!(
        button.is_sensitive(),
        "a background tab changed the selected tab's action"
    );
    tab.send(crate::ui::browse_tab::SaveInput::SaveStarted);
    assert!(!button.is_sensitive());
    tab.send(crate::ui::browse_tab::SaveInput::SaveCommitted(Default::default()));
    super::open_editor(&workspace);
    assert!(
        !button.is_sensitive(),
        "a SQL editor without result edits cannot save data"
    );
    shell.shutdown();
    assert!(test.window.lookup_action("save-changes").is_none());
}

#[gtk4::test]
fn header_save_uses_the_structure_tabs_save_action() {
    use crate::ui::structure_tab::{ColumnsInput, SaveInput, StructureTab};

    let test = TestWindow::connected("HeaderStructureSave");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    workspace
        .sender()
        .expect("input")
        .deliver(WorkspaceInput::NewTableTab { schema: None });
    let mut tab = None;
    wait_until(WAIT, || {
        tab = shell
            .tab_view()
            .selected_page()
            .and_then(|page| page.child().downcast::<StructureTab>().ok());
        tab.is_some()
    })
    .expect("a new structure tab");
    let tab = tab.expect("the structure");
    let button = shell.imp().save_changes_button.get();
    let source = tab.save_action().expect("the structure save action");
    assert_eq!(button.is_sensitive(), source.is_enabled());
    tab.send(ColumnsInput::AddColumn);
    assert!(source.is_enabled());
    assert!(button.is_sensitive());
    tab.send(SaveInput::SaveStarted);
    assert!(!button.is_sensitive());
    tab.send(SaveInput::SaveFailed("The connection closed.".to_owned()));
    assert!(button.is_sensitive());
}

#[gtk4::test]
fn header_save_switches_between_sessions_and_disables_without_a_tab() {
    let sessions = super::two_sessions_with("HeaderSessionSave", "Other", serving_tables);
    let shell = &sessions.shell;
    let button = shell.imp().save_changes_button.get();
    assert!(!button.is_sensitive());
    super::open_editor(&sessions.first);
    let (_, tab) = open_table(&sessions.test, "users");
    type_a_name(&tab);
    tab.grid().commit_edit();
    assert!(button.is_sensitive());
    let edited = shell.tab_view().selected_page().expect("the edited page");

    let clean = super::open_editor(&sessions.second);
    assert!(!button.is_sensitive());
    shell.tab_view().set_selected_page(&edited);
    assert!(button.is_sensitive());
    shell.tab_view().set_selected_page(&clean);
    tab.send(crate::ui::browse_tab::SaveInput::SaveStarted);
    assert!(
        !button.is_sensitive(),
        "a background session cannot enable Save Changes"
    );
}
