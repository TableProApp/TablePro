//! What the window hears about the tabs for its notifications: work
//! that ended in one, and a change to which tabs are open or in front.

use std::collections::HashSet;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use uuid::Uuid;

use super::{Workspace, WorkspaceModel, WorkspaceTab, tab_title};
use crate::workspace::{CompletedWork, WorkKind, WorkOutcome};

impl Workspace {
    /// A run, save or export ended in a tab that is still open.
    pub(crate) fn connect_work_completed<F: Fn(&Self, CompletedWork) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "work-completed",
            false,
            glib::closure_local!(move |workspace: &Self, work: glib::BoxedAnyObject| {
                f(workspace, *work.borrow::<CompletedWork>());
            }),
        )
    }

    /// Another tab came to the front, or one opened or closed.
    pub(crate) fn connect_tabs_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "tabs-changed",
            false,
            glib::closure_local!(move |workspace: &Self| f(workspace)),
        )
    }

    /// The tab in front. `None` with no tab, or while the workspace is
    /// handling input.
    pub(crate) fn selected_tab(&self) -> Option<Uuid> {
        self.read(WorkspaceModel::selected_workspace_tab_id).flatten()
    }

    /// Every open tab. `None` while the workspace is handling input.
    pub(crate) fn open_tabs(&self) -> Option<HashSet<Uuid>> {
        self.read(|model| model.workspace_tabs.borrow().keys().copied().collect())
    }

    /// What a notification calls tab `id`, while it is open.
    pub(crate) fn notice_label(&self, id: Uuid) -> Option<String> {
        self.read(|model| model.notice_label(id)).flatten()
    }

    /// The connection's name, as the window's title gives it.
    pub(crate) fn connection_name(&self) -> Option<String> {
        self.read(|model| model.context.active.metadata().map(|metadata| metadata.name))
            .flatten()
    }
}

impl WorkspaceModel {
    /// Tell the window that work ended in tab `tab`. A tab closed since
    /// has nothing left to show or bring forward, so it is not told.
    pub(super) fn report_work(&self, tab: Uuid, kind: WorkKind, outcome: WorkOutcome) {
        if !self.workspace_tabs.borrow().contains_key(&tab) {
            return;
        }
        if let Some(workspace) = self.this.upgrade() {
            let work = CompletedWork { tab, kind, outcome };
            workspace.emit_by_name::<()>("work-completed", &[&glib::BoxedAnyObject::new(work)]);
        }
    }

    pub(super) fn report_tabs_changed(&self) {
        if let Some(workspace) = self.this.upgrade() {
            workspace.emit_by_name::<()>("tabs-changed", &[]);
        }
    }

    /// Bring tab `id` to the front, out of the tab overview, as clicking
    /// a notification about it asks.
    pub(super) fn focus_tab(&self, id: Uuid) {
        let page = self.workspace_tabs.borrow().get(&id).map(|tab| tab.page().clone());
        let Some(page) = page else {
            tracing::debug!(%id, "a notification named a tab that has closed");
            return;
        };
        self.tab_view.set_selected_page(&page);
        if let Some(shell) = self.shell.upgrade() {
            shell.imp().tab_overview.set_open(false);
        }
    }

    /// The tab's name for a notification, which can show on the lock
    /// screen. An editor tab's title is the start of its script, so it
    /// goes by its number instead.
    fn notice_label(&self, id: Uuid) -> Option<String> {
        let tabs = self.workspace_tabs.borrow();
        Some(match tabs.get(&id)? {
            WorkspaceTab::Editor(slot) => tab_title::numbered_query(slot.ordinal),
            tab => tab_title::resolve_tab_title(&tab.identity(), self.naming.get()).label,
        })
    }
}
