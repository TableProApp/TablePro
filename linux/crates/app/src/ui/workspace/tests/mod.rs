mod assistant;
mod close_tab;
mod diagram;
mod keys;
mod large_catalog;
mod references;
mod sessions;
mod shell;
mod tab_title;

use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_session::SessionKey;
use tablepro_storage::SavedConnection;

use super::{Workspace, WorkspaceInput, WorkspaceShell};
use crate::runtime::DeliverInput;
use crate::test_support::wait_until;
use crate::ui::SessionWindowInput;
use crate::ui::session_window::tests::{TestWindow, WAIT};

/// The shell that holds `workspace`, as the window shows it.
pub(crate) fn shell_of(workspace: &Workspace) -> WorkspaceShell {
    workspace
        .imp()
        .shell
        .upgrade()
        .expect("a workspace the window holds is in its shell")
}

/// A new editor tab in `workspace`, which the tab view selects.
pub(crate) fn new_editor_page(workspace: &Workspace) -> Option<adw::TabPage> {
    Some(workspace.tab_factory()?.create_editor())
}

/// The change tracker of `workspace`'s tab `tab`, while the tab is open.
pub(crate) fn row_tracker(
    workspace: &Workspace,
    tab: uuid::Uuid,
) -> Option<crate::services::tab_tracker_handle::TabTrackerHandle> {
    workspace.read(|model| model.change_trackers.get(tab)).flatten()
}

/// A server with one keyed table, whose every page is the same
/// thousand rows.
pub(super) fn served_table() -> tablepro_test_support::ConnectionScript {
    use tablepro_core::column::{ColumnDefault, ColumnType};
    use tablepro_core::meta::{RowCountEstimate, RowIdentity, TableEstimate};
    use tablepro_core::{ColumnInfo, QueryResult, Value};
    use tablepro_test_support::FakeReply;
    let column = |name: &str, primary_key: bool| ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    };
    let columns = vec![column("id", true), column("name", false)];
    let page = QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        (0..1_000)
            .map(|id| vec![Value::Int(id), Value::Text(format!("customer {id}"))])
            .collect(),
    );
    let mut script = tablepro_test_support::ConnectionScript::default();
    script.fetch_columns.always(FakeReply::ok(columns));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    // Too many rows to count unasked, so Count Rows stays on the bar.
    script.table_estimate.always(FakeReply::ok(TableEstimate {
        rows: RowCountEstimate::Approximate(48_213_000),
        heap_blocks: None,
    }));
    script.query_bound.always(FakeReply::ok(page));
    script
}

/// A window with the test's connection open and a second one, named
/// `other`, opened beside it.
pub(super) struct TwoSessions {
    pub test: TestWindow,
    pub first: Workspace,
    pub second: Workspace,
    pub shell: WorkspaceShell,
}

pub(super) fn two_sessions(name: &str, other: &str) -> TwoSessions {
    let test = TestWindow::connected(name);
    let first = test.workspace();
    let shell = shell_of(&first);
    let saved = SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: other.to_owned(),
        database: test.dir().join("other.db").display().to_string(),
        ..test.saved.clone()
    };
    test.services
        .storage
        .connections()
        .upsert_blocking(saved.clone())
        .expect("save the second connection");
    wait_until(WAIT, || test.services.saved_connections.get(saved.id).is_some()).expect("the list to have it");
    test.window.send(SessionWindowInput::OpenSaved(Box::new(saved.clone())));
    let key = SessionKey::Saved(saved.id);
    let joined = || {
        shell
            .sessions()
            .into_iter()
            .find(|workspace| workspace.key().as_ref() == Some(&key))
    };
    wait_until(WAIT, || joined().is_some()).expect("the second session to join");
    let second = joined().expect("the second session");
    TwoSessions {
        test,
        first,
        second,
        shell,
    }
}

/// Open an editor tab in `workspace`, which comes to the front, and
/// return its page.
pub(super) fn open_editor(workspace: &Workspace) -> adw::TabPage {
    let shell = shell_of(workspace);
    let count = || workspace.imp().index.get().map_or(0, |index| index.pages().len());
    let before = count();
    workspace
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::NewEditorTab);
    wait_until(WAIT, || {
        count() == before + 1
            && shell
                .tab_view()
                .selected_page()
                .is_some_and(|page| workspace.tab_id(&page).is_some())
    })
    .expect("the editor tab in front");
    shell.tab_view().selected_page().expect("the editor's page")
}
