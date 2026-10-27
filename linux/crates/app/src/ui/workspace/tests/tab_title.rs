use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::ddl::{DraftColumn, DraftType, TableChanges, TableDraft};
use tablepro_core::meta::TableRef;
use tablepro_core::{EditorSession, TransactionState};
use tablepro_storage::DraftId;
use tablepro_test_support::{FakeEditorSession, FakeReply, FakeRun, Replies};
use uuid::Uuid;

use super::super::structure_target::StructureTarget;
use super::super::tab_spec::TabSpec;
use super::super::{Workspace, WorkspaceInput, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::services::pending_structure::PendingStructure;
use crate::test_support::{finish_on_main, wait_until};
use crate::ui::SessionWindowInput;
use crate::ui::session_window::tests::{TestWindow, WAIT, editors};
use crate::ui::structure_tab::StructureMode;
use crate::workspace::{TabRecord, WorkspaceRecord};

fn modified(page: &adw::TabPage) -> bool {
    page.icon().and_downcast::<gio::ThemedIcon>().is_some_and(|icon| {
        icon.names()
            .iter()
            .any(|name| name == crate::ui::icons::DOCUMENT_MODIFIED)
    })
}

/// A new table draft's tab, unselected behind the tab in front, and its
/// id.
fn new_table_tab(workspace: &Workspace) -> (adw::TabPage, Uuid) {
    workspace
        .with_model(|model| {
            let page = model.factory.create(TabSpec::Structure {
                target: StructureTarget::NewDraft { schema: None },
            })?;
            let id = model.index.id_of(&page)?;
            Some((page, id))
        })
        .flatten()
        .expect("a structure tab")
}

fn a_column_added() -> Option<PendingStructure> {
    let mut draft = TableDraft::new(TableRef::unqualified("t"));
    draft
        .columns
        .push(DraftColumn::new("a", DraftType::Typed("int".to_owned())));
    Some(PendingStructure {
        original: None,
        draft,
        changes: TableChanges::default(),
        unparsed_defaults: Vec::new(),
    })
}

/// What a structure tab's dirty-changed signal does.
fn edit_structure(workspace: &Workspace, id: Uuid, pending: Option<PendingStructure>) {
    let input = workspace
        .with_model(|model| {
            if let Some(tracker) = model.structure_trackers.get(id) {
                tracker.set_pending(pending);
            }
            model.input.clone()
        })
        .expect("the workspace's input");
    input.deliver(WorkspaceInput::TabDirtyChanged);
}

#[gtk4::test]
fn unsaved_icon_follows_structure_tracker() {
    let test = TestWindow::connected("UnsavedIcon");
    let workspace = test.workspace();
    let (page, id) = new_table_tab(&workspace);
    assert!(!modified(&page));

    edit_structure(&workspace, id, a_column_added());
    wait_until(WAIT, || modified(&page)).expect("the unsaved icon");
    assert_eq!(page.title(), "New Table", "the title changed with the edit");
    // A screen reader reads the tab's tooltip, never its icon.
    let tooltip = || page.tooltip().map(|tooltip| tooltip.to_string()).unwrap_or_default();
    assert!(tooltip().ends_with("Unsaved changes"), "{}", tooltip());

    edit_structure(&workspace, id, None);
    wait_until(WAIT, || page.icon().is_none()).expect("the icon to go");
    assert!(!tooltip().contains("Unsaved changes"), "{}", tooltip());
}

#[gtk4::test]
fn unsaved_marker_never_sets_needs_attention() {
    let test = TestWindow::connected("UnsavedAttention");
    let workspace = test.workspace();
    let (page, id) = new_table_tab(&workspace);
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || editors(&test.window).len() == 1).expect("an editor tab in front");
    assert_ne!(workspace.chrome().imp().tab_view.selected_page().as_ref(), Some(&page));

    edit_structure(&workspace, id, a_column_added());
    wait_until(WAIT, || modified(&page)).expect("the unsaved icon");

    assert!(
        !page.needs_attention(),
        "a background tab with changes asks for attention"
    );
    assert!(page.indicator_icon().is_none());
}

#[gtk4::test]
fn open_transaction_marks_editor_tab() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
    let editor_session: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));
    let test = TestWindow::connected_with("OpenTransactionIcon", |script| {
        script.open_editor_session.always(FakeReply::ok(editor_session));
    });

    test.run_in_new_editor_tab();

    let page = test
        .workspace()
        .chrome()
        .imp()
        .tab_view
        .selected_page()
        .expect("the editor's page");
    wait_until(WAIT, || modified(&page)).expect("the open transaction to mark the tab");
}

#[gtk4::test]
fn another_tabs_open_transaction_is_bannered_until_its_tab_is_shown() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
    let editor_session: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));
    let test = TestWindow::connected_with("TransactionBanner", |script| {
        script.open_editor_session.always(FakeReply::ok(editor_session));
    });
    let workspace = test.workspace();
    let (view, banner) = (
        workspace.chrome().imp().tab_view.get(),
        workspace.imp().transaction_banner.get(),
    );

    test.run_in_new_editor_tab();
    let owner = view.selected_page().expect("the editor's page");
    wait_until(WAIT, || modified(&owner)).expect("the open transaction to reach the workspace");
    assert!(
        !banner.is_revealed(),
        "the owning tab shows the banner over its own line"
    );

    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || banner.is_revealed()).expect("the banner on the other tab");
    assert_ne!(view.selected_page().as_ref(), Some(&owner));
    assert_eq!(
        banner.title().as_str(),
        format!("“{}” has an open transaction", owner.title())
    );

    banner.emit_by_name::<()>("button-clicked", &[]);
    wait_until(WAIT, || view.selected_page().as_ref() == Some(&owner)).expect("Show to bring the tab forward");
    wait_until(WAIT, || !banner.is_revealed()).expect("the banner to hide on the owning tab");
}

#[gtk4::test]
fn restored_workspace_selects_saved_active_tab() {
    let test = TestWindow::picker("RestoreActive");
    let store = test.services.storage.workspaces().clone();
    let orders = TabRecord::Structure {
        schema: None,
        table: "orders".to_owned(),
    };
    store
        .schedule(
            &test.key(),
            WorkspaceRecord {
                active_tab: Some(1),
                tabs: vec![
                    TabRecord::Editor {
                        draft: DraftId::new(),
                        file: None,
                    },
                    orders,
                ],
            },
        )
        .expect("the record to queue");
    finish_on_main(WAIT, store.flush(&test.key()))
        .expect("the flush to end")
        .expect("the record written");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.chrome().imp().tab_view.n_pages() == 2).expect("both tabs restored");

    let selected = workspace
        .read(|model| {
            let id = model.selected_workspace_tab_id()?;
            match model.workspace_tabs.borrow().get(&id)? {
                WorkspaceTab::Structure(slot) => Some((slot.mode, slot.table.clone())),
                _ => None,
            }
        })
        .flatten();
    assert_eq!(selected, Some((StructureMode::Edit, "orders".to_owned())));
}

#[gtk4::test]
fn a_restored_editor_tab_keeps_its_file_and_its_unsaved_changes() {
    let test = TestWindow::picker("RestoreEditorFile");
    let path = test.dir().join("daily.sql");
    crate::test_support::write_text_file(&path, "SELECT 1;");
    let store = test.services.storage.workspaces().clone();
    store
        .schedule(
            &test.key(),
            WorkspaceRecord {
                active_tab: Some(0),
                tabs: vec![TabRecord::Editor {
                    draft: DraftId::new(),
                    file: Some(crate::workspace::EditorFileRecord {
                        uri: gio::File::for_path(&path).uri().to_string(),
                        modified: true,
                    }),
                }],
            },
        )
        .expect("the record to queue");
    finish_on_main(WAIT, store.flush(&test.key()))
        .expect("the flush to end")
        .expect("the record written");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.chrome().imp().tab_view.n_pages() == 1).expect("the editor tab restored");

    let page = workspace.chrome().imp().tab_view.nth_page(0);
    let editor = editors(&test.window).pop().expect("the editor");
    assert_eq!(editor.file().and_then(|file| file.path()), Some(path.clone()));
    assert!(
        editor.has_unsaved_file_changes(),
        "the restore forgot the text was not saved"
    );
    assert_eq!(page.title(), "daily.sql");
    wait_until(WAIT, || modified(&page)).expect("the unsaved icon");
    assert_eq!(
        page.tooltip().as_deref(),
        Some(format!("{}\nUnsaved changes", path.to_string_lossy()).as_str())
    );
}

#[gtk4::test]
fn window_title_follows_the_tab_in_front() {
    let test = TestWindow::connected("WindowTitle");
    wait_until(WAIT, || test.window.title().as_deref() == Some("Fake - TablePro")).expect("the connection's title");

    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");

    wait_until(WAIT, || {
        test.window.title().as_deref() == Some("Query 1 (Fake) - TablePro")
    })
    .expect("the tab's title");
    let heading = test.workspace().chrome().imp().window_title.get();
    assert_eq!(heading.title(), "Query 1");
    assert_eq!(heading.subtitle(), "Fake");
}

#[gtk4::test]
fn tabs_name_the_schema_once_the_session_has_two() {
    let test = TestWindow::connected("NamingFollowsSchemas");
    let workspace = test.workspace();
    let page = workspace
        .with_model(|model| {
            model.open_tab(TabSpec::Table {
                table: TableRef::new(Some("public".to_owned()), "orders"),
                page: super::super::tab_spec::TablePage::first(100),
                filter: crate::ui::browse_tab::TableFilter::Remembered,
            })
        })
        .flatten()
        .expect("a table tab");
    assert_eq!(page.title(), "orders");
    assert_eq!(page.tooltip().as_deref(), Some("public.orders"));

    let schema = |name: &str| tablepro_core::meta::SchemaInfo {
        name: name.to_owned(),
        is_default: name == "public",
        is_system: false,
    };
    let session = workspace
        .read(|model| model.context.active.get())
        .flatten()
        .expect("the session");
    // What a reconnect to a database with a second schema commits.
    session
        .catalog()
        .commit(vec![schema("public"), schema("sales")], Vec::new());

    wait_until(WAIT, || page.title() == "public.orders").expect("the tab to name its schema");
    assert!(
        page.tooltip().unwrap_or_default().is_empty(),
        "the tooltip repeats the title"
    );
}

#[gtk4::test]
fn a_new_editor_tab_takes_the_lowest_number_no_open_tab_has() {
    let test = TestWindow::connected("LowestFreeQueryNumber");
    let view = test.workspace().chrome().imp().tab_view.get();
    let open = || {
        let before = editors(&test.window).len();
        WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
        wait_until(WAIT, || editors(&test.window).len() == before + 1).expect("a new editor tab");
    };
    open();
    open();
    open();

    view.close_page(&view.nth_page(0));
    wait_until(WAIT, || view.n_pages() == 2).expect("Query 1 to close");
    open();

    let mut titles: Vec<String> = (0..view.n_pages())
        .map(|index| view.nth_page(index).title().to_string())
        .collect();
    titles.sort();
    assert_eq!(titles, ["Query 1", "Query 2", "Query 3"]);
}
