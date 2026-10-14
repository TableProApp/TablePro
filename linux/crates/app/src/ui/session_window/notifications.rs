//! The window's side of the notifications about finished work: it hears
//! the workspace's tabs, decides whether the user saw the work end, and
//! withdraws a tab's notification once the user looks at the tab.

use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use uuid::Uuid;

use super::application_notification_sink::ApplicationNotificationSink;
use super::notification_sink::NotificationSink;
use super::work_notifier::WorkNotifier;
use super::{SessionWindow, SessionWindowInput};
use crate::runtime::{DeliverInput, InputSender};
use crate::ui::workspace::{Workspace, WorkspaceInput};
use crate::workspace::{CompletedWork, WorkKind};

impl SessionWindow {
    /// Called once the window is added to the application, which gives
    /// it the id its notifications name.
    pub(super) fn install_notifier(&self) {
        if let Some(app) = self.application() {
            self.set_notification_sink(Rc::new(ApplicationNotificationSink::new(&app)));
        }
        self.connect_is_active_notify(SessionWindow::on_tabs_changed);
    }

    pub(super) fn set_notification_sink(&self, sink: Rc<dyn NotificationSink>) {
        let replaced = self.imp().notifier.replace(Some(WorkNotifier::new(self.id(), sink)));
        if let Some(replaced) = replaced {
            replaced.withdraw_all();
        }
    }

    /// Count the window as active or not, whatever the display says.
    #[cfg(test)]
    pub(super) fn set_active_for_test(&self, active: bool) {
        self.imp().active_for_test.set(Some(active));
    }

    fn window_is_active(&self) -> bool {
        #[cfg(test)]
        if let Some(active) = self.imp().active_for_test.get() {
            return active;
        }
        self.is_active()
    }

    pub(super) fn follow_workspace_tabs(&self, workspace: &Workspace, input: &InputSender<SessionWindowInput>) {
        let completed = input.clone();
        workspace.connect_work_completed(move |_, work| completed.deliver(SessionWindowInput::WorkCompleted(work)));
        let changed = input.clone();
        workspace.connect_tabs_changed(move |_| changed.deliver(SessionWindowInput::TabsChanged));
    }

    pub(super) fn on_work_completed(&self, work: CompletedWork) {
        let Some(workspace) = self.workspace() else {
            return;
        };
        let Some(label) = workspace.notice_label(work.tab) else {
            return;
        };
        // The close prompt in front of the user saved those tabs, and
        // says itself how that went.
        if work.kind == WorkKind::Save && self.close_guards().is_some_and(|guards| guards.is_asking()) {
            return;
        }
        let active = self.window_is_active() && workspace.selected_tab() == Some(work.tab);
        let connection = workspace.connection_name().unwrap_or_default();
        if let Some(notifier) = self.imp().notifier.borrow().as_ref() {
            notifier.work_completed(&work, active, &label, &connection);
        }
    }

    pub(super) fn on_tabs_changed(&self) {
        let notifier = self.imp().notifier.borrow();
        let Some(notifier) = notifier.as_ref().filter(|notifier| notifier.has_sent()) else {
            return;
        };
        let Some(workspace) = self.workspace() else {
            return;
        };
        if let Some(open) = workspace.open_tabs() {
            notifier.withdraw_closed(|tab| open.contains(&tab));
        }
        if self.window_is_active()
            && let Some(tab) = workspace.selected_tab()
        {
            notifier.tab_became_active(tab);
        }
    }

    pub(super) fn on_focus_tab(&self, tab: Uuid) {
        match self.workspace().and_then(|workspace| workspace.input()) {
            Some(input) => input.deliver(WorkspaceInput::FocusTab(tab)),
            None => tracing::debug!("a notification named a tab of a session the window no longer shows"),
        }
    }

    /// Every notification names a tab of the session going away.
    pub(super) fn withdraw_notifications(&self) {
        if let Some(notifier) = self.imp().notifier.borrow().as_ref() {
            notifier.withdraw_all();
        }
    }
}
