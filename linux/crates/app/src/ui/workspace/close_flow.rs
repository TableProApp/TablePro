use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::EditorSession;
use uuid::Uuid;

use super::workspace_persistence::WorkspaceTabs;
use super::{WorkspaceInput, WorkspaceModel, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::workspace::CloseDecision;

/// Every editor tab's connection, taken from its tab. Each tab's run is
/// stopped first, so nothing is still writing to the session it gives
/// up.
fn take_editor_sessions(tabs: &WorkspaceTabs) -> Vec<Arc<dyn EditorSession>> {
    tabs.borrow()
        .values()
        .filter_map(|tab| match tab {
            WorkspaceTab::Editor(slot) => slot.editor.take_editor_session(),
            WorkspaceTab::Structure(_) | WorkspaceTab::Table(_) => None,
        })
        .collect()
}

impl WorkspaceModel {
    /// Write what the workspace shows as it is now: the last column drag
    /// and filter change, the editor text and the tab list. The process
    /// is held until every write lands, so quitting right after a
    /// disconnect does not lose them.
    pub(super) fn flush(&self) {
        let hold = self.context.hold.acquire();
        let column_widths = self.storage.column_widths().flush();
        let filter_settings = self.storage.filter_settings().flush();
        let editor_drafts = self.drafts.flush_all();
        let writer = self.drafts.clone();
        let tabs = self.workspace.detach();
        glib::spawn_future_local(async move {
            column_widths.await;
            filter_settings.await;
            for failure in editor_drafts.await {
                tracing::warn!(failure, "an editor draft was not saved");
            }
            writer.release_closed();
            if let Some(tabs) = tabs
                && let Err(error) = tabs.await
            {
                tracing::debug!(%error, "the open tabs were not saved");
            }
            drop(hold);
        });
    }

    pub(super) fn take_editor_sessions(&self) -> Vec<Arc<dyn EditorSession>> {
        take_editor_sessions(&self.workspace_tabs)
    }

    /// A tab asked to close. One with nothing to lose closes now; any
    /// other waits for the prompts.
    pub(super) fn close_workspace_tab_by_id(&mut self, id: Uuid) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        if self.close_guards.may_close_tab(&self.workspace_handle, id) {
            self.finish_close_workspace_tab(id, &tab_view);
            return;
        }
        let Some(parent) = self.dialog_parent() else {
            return;
        };
        let input = self.input.clone();
        self.close_guards
            .ask_close_tab(&parent, &self.workspace_handle, id, move |decision| {
                input.deliver(WorkspaceInput::TabCloseDecided {
                    id,
                    approved: decision == CloseDecision::Approved,
                });
            });
    }

    pub(super) fn on_tab_close_decided(&mut self, id: Uuid, approved: bool) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        if approved {
            self.finish_close_workspace_tab(id, &tab_view);
            return;
        }
        let page = self.workspace_tabs.borrow().get(&id).map(|tab| tab.page().clone());
        if let Some(page) = page {
            tab_view.close_page_finish(&page, false);
        }
    }

    /// Tell the window whether a logout would lose something here, so it
    /// holds the session back while one would.
    pub(super) fn refresh_inhibitor(&self) {
        let dirty = !self.workspace_handle.dirty_tabs().is_empty();
        if self.reported_dirty.replace(Some(dirty)) == Some(dirty) {
            return;
        }
        if let Some(workspace) = self.this.upgrade() {
            workspace.emit_by_name::<()>("dirty-changed", &[&dirty]);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::rc::Rc;
    use std::time::Duration;

    use libadwaita as adw;
    use tablepro_core::TransactionState;
    use tablepro_session::runtime::CountingHold;
    use tablepro_storage::DraftId;
    use tablepro_test_support::{ConnectionScript, FakeEditorSession, FakeReply, FakeRun, Replies};

    use super::*;
    use crate::services::active_session::ActiveSession;
    use crate::test_support::{FakeSession, MemorySettings, wait_until};
    use crate::ui::editor::{SqlEditor, SqlEditorInit};
    use crate::ui::workspace::window_tabs::WindowTabs;
    use crate::ui::workspace::{EditorTabSlot, write_workspace_tab_id};
    use crate::workspace::{TabDirectory, TabEntry};

    const WAIT: Duration = Duration::from_secs(10);

    #[gtk4::test]
    fn an_open_transaction_is_named_and_its_session_handed_over_once() {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let settings = MemorySettings::new();
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
        let editor_session = Arc::new(FakeEditorSession::new(runs));
        let mut script = ConnectionScript::default();
        let opened: Arc<dyn EditorSession> = editor_session.clone();
        script.open_editor_session.always(FakeReply::ok(opened));
        script.probe.always(FakeReply::ok(()));
        let fake = FakeSession::start(script, [], runtime.tasks());
        let active = ActiveSession::new();
        active.replace(fake.session.clone());
        let hold = Rc::new(CountingHold::new());
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: Some("BEGIN; UPDATE t SET a = 1".to_owned()),
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: active.clone(),
            hold: hold.clone(),
            close_timeout: Duration::from_secs(5),
        });
        editor.run();
        wait_until(WAIT, || !editor.is_running()).expect("the run to end");
        let view = adw::TabView::new();
        let page = view.append(&editor);
        page.set_title("• Query 1");
        let id = Uuid::new_v4();
        write_workspace_tab_id(&page, id);
        let tabs: WorkspaceTabs = Rc::new(RefCell::new(HashMap::from([(
            id,
            WorkspaceTab::Editor(EditorTabSlot {
                editor: editor.clone(),
                page,
                draft: DraftId::new(),
            }),
        )])));
        let directory = WindowTabs::new(tabs.clone());
        directory.set_view(Some(&view));

        assert_eq!(
            directory.tabs(),
            [TabEntry {
                id,
                title: "Query 1".to_owned(),
                open_transaction: true,
            }]
        );

        let taken = take_editor_sessions(&tabs);
        editor.shutdown();
        crate::test_support::drain_main_context();

        assert_eq!(taken.len(), 1, "the tab's session was not handed over");
        assert!(take_editor_sessions(&tabs).is_empty(), "handed over twice");
        assert_eq!(
            editor_session.close_count(),
            0,
            "the tab closed the session it handed over"
        );
        assert_eq!(hold.live(), 0);
        drop((taken, tabs));
        crate::test_support::drain_main_context();
        runtime.shutdown();
    }
}
