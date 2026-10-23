use std::collections::HashSet;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::EditorSession;
use uuid::Uuid;

use super::unsaved_icon::apply_unsaved_icon;
use super::workspace_persistence::WorkspaceTabs;
use super::{WorkspaceInput, WorkspaceModel, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::ui::browse_tab::BrowseTab;
use crate::workspace::CloseDecision;

/// Every editor tab's connection, taken from its tab. Each tab's run is
/// stopped first, so nothing is still writing to the session it gives
/// up.
fn take_editor_sessions(tabs: &WorkspaceTabs) -> Vec<Arc<dyn EditorSession>> {
    tabs.borrow()
        .values()
        .filter_map(|tab| match tab {
            WorkspaceTab::Editor(slot) => slot.editor.take_editor_session(),
            WorkspaceTab::Structure(_) | WorkspaceTab::Table(_) | WorkspaceTab::Key(_) => None,
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
        // The key is free once the window lets go of it, which is before
        // these land; a delete of the connection waits for them.
        let drafts_landing = self.storage.workspaces().writes_in_flight(&self.key);
        let editor_drafts = self.drafts.flush_all();
        let writer = self.drafts.clone();
        let tabs = self.workspace.detach();
        glib::spawn_future_local(async move {
            column_widths.await;
            filter_settings.await;
            for failure in editor_drafts.await {
                tracing::warn!(failure, "an editor draft was not saved");
            }
            drop(drafts_landing);
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

    /// The table tabs, or only `id` when it is one.
    pub(super) fn browse_tabs(&self, id: Option<Uuid>) -> Vec<BrowseTab> {
        self.workspace_tabs
            .borrow()
            .iter()
            .filter(|(tab, _)| id.is_none_or(|id| id == **tab))
            .filter_map(|(_, tab)| match tab {
                WorkspaceTab::Table(slot) => Some(slot.browse.clone()),
                WorkspaceTab::Editor(_) | WorkspaceTab::Structure(_) | WorkspaceTab::Key(_) => None,
            })
            .collect()
    }

    /// A tab asked to close. One with nothing to lose closes now; any
    /// other waits for the prompts. A value typed into a cell is an
    /// unsaved change by then, as it is once the focus leaves the cell.
    pub(super) fn close_workspace_tab_by_id(&mut self, id: Uuid) {
        for browse in self.browse_tabs(Some(id)) {
            browse.commit_cell_edit();
        }
        let tab_view = self.tab_view.clone();
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

    /// Take the keyboard focus out of `page` before it closes. The page
    /// the view selects next is selected first, so the view hands it the
    /// focus while `page` is still whole. GTK 4.22 leaks a focus that is
    /// hidden and then unparented in one go, which the close does when
    /// that page takes no focus.
    pub(super) fn move_focus_off(&self, page: &adw::TabPage) {
        let Some(window) = self.window() else {
            return;
        };
        let child = page.child();
        let holds_focus = || {
            gtk::prelude::GtkWindowExt::focus(&window).is_some_and(|focus| focus == child || focus.is_ancestor(&child))
        };
        if !holds_focus() {
            return;
        }
        // The documented choice for a page with no parent, and this
        // workspace never gives one. The last page leaves the focus to
        // the empty page the stack shows next.
        if page.is_selected() && !self.tab_view.select_next_page() && !self.tab_view.select_previous_page() {
            return;
        }
        // Where GTK moves a focus left in a removed widget, from the
        // window's first control.
        if holds_focus() {
            gtk::prelude::GtkWindowExt::set_focus(&window, None::<&gtk::Widget>);
            window.child_focus(gtk::DirectionType::TabForward);
        }
    }

    pub(super) fn on_tab_close_decided(&mut self, id: Uuid, approved: bool) {
        let tab_view = self.tab_view.clone();
        if approved {
            self.finish_close_workspace_tab(id, &tab_view);
            return;
        }
        let page = self.workspace_tabs.borrow().get(&id).map(|tab| tab.page().clone());
        if let Some(page) = page {
            tab_view.close_page_finish(&page, false);
        }
    }

    /// Mark each tab that closing would lose something in, and tell the
    /// window whether a logout would, so it holds the session back.
    pub(super) fn refresh_unsaved(&self) {
        let dirty_tabs = self.workspace_handle.dirty_tabs();
        let unsaved: HashSet<Uuid> = dirty_tabs.iter().map(|tab| tab.id).collect();
        let marked: Vec<Uuid> = self
            .workspace_tabs
            .borrow()
            .iter()
            .filter(|(id, tab)| tab.page().icon().is_some() != unsaved.contains(id))
            .map(|(id, _)| *id)
            .collect();
        for (id, tab) in self.workspace_tabs.borrow().iter() {
            apply_unsaved_icon(tab.page(), unsaved.contains(id));
        }
        // The tooltip carries the mark to a screen reader.
        for id in marked {
            self.retitle_tab(id);
        }
        let dirty = dirty_tabs.iter().any(|tab| tab.kind.lost_with_the_window());
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
    use crate::ui::workspace::EditorTabSlot;
    use crate::ui::workspace::tab_index::TabIndex;
    use crate::ui::workspace::window_tabs::WindowTabs;
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
            initial_query: Some("BEGIN; UPDATE t SET a = 1 WHERE id = 1".to_owned()),
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
        page.set_title("Query 1");
        let id = Uuid::new_v4();
        let index = Rc::new(TabIndex::default());
        index.insert(&page, id);
        let tabs: WorkspaceTabs = Rc::new(RefCell::new(HashMap::from([(
            id,
            WorkspaceTab::Editor(EditorTabSlot {
                editor: editor.clone(),
                page,
                draft: DraftId::new(),
                ordinal: 1,
                label: crate::ui::workspace::editor_label::EditorLabel::Untitled(1),
            }),
        )])));
        let directory = WindowTabs::new(tabs.clone(), index, &view);

        assert_eq!(
            directory.tabs(),
            [TabEntry {
                id,
                title: "Query 1".to_owned(),
                open_transaction: true,
                unsaved_file: false,
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
