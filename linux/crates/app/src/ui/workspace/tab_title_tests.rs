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

use super::structure_target::StructureTarget;
use super::tab_spec::TabSpec;
use super::{Workspace, WorkspaceInput, WorkspaceTab};
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

    edit_structure(&workspace, id, None);
    wait_until(WAIT, || page.icon().is_none()).expect("the icon to go");
}

#[gtk4::test]
fn unsaved_marker_never_sets_needs_attention() {
    let test = TestWindow::connected("UnsavedAttention");
    let workspace = test.workspace();
    let (page, id) = new_table_tab(&workspace);
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || editors(&test.window).len() == 1).expect("an editor tab in front");
    assert_ne!(workspace.imp().tab_view.selected_page().as_ref(), Some(&page));

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
        .imp()
        .tab_view
        .selected_page()
        .expect("the editor's page");
    wait_until(WAIT, || modified(&page)).expect("the open transaction to mark the tab");
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
                tabs: vec![TabRecord::Editor { draft: DraftId::new() }, orders],
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
    wait_until(WAIT, || workspace.imp().tab_view.n_pages() == 2).expect("both tabs restored");

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
fn window_title_follows_the_tab_in_front() {
    let test = TestWindow::connected("WindowTitle");
    wait_until(WAIT, || test.window.title().as_deref() == Some("Fake - TablePro")).expect("the connection's title");

    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");

    wait_until(WAIT, || {
        test.window.title().as_deref() == Some("Query 1 (Fake) - TablePro")
    })
    .expect("the tab's title");
    let heading = test.workspace().imp().window_title.get();
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
                page: super::tab_spec::TablePage::first(100),
            })
        })
        .flatten()
        .expect("a table tab");
    assert_eq!(page.title(), "orders");
    assert_eq!(page.tooltip().as_deref(), Some("public.orders"));

    let input = workspace.input().expect("the workspace's input");
    input.deliver(WorkspaceInput::TableNamingRead(
        super::table_naming::TableNaming::SchemaQualified,
    ));

    wait_until(WAIT, || page.title() == "public.orders").expect("the tab to name its schema");
    assert!(
        page.tooltip().unwrap_or_default().is_empty(),
        "the tooltip repeats the title"
    );
}
