//! The window's side of the notifications about finished work: it hears
//! the workspace's tabs, decides whether the user saw the work end, and
//! withdraws a tab's notification once the user looks at the tab.

use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use uuid::Uuid;

use super::notification_sink::NotificationSink;
use super::work_notifier::WorkNotifier;
use super::{SessionWindow, SessionWindowInput};
use crate::runtime::{DeliverInput, InputSender};
use crate::ui::workspace::{Workspace, WorkspaceInput};
use crate::workspace::CompletedWork;

impl SessionWindow {
    /// Called once the window is added to the application, which gives
    /// it the id its notifications name.
    pub(super) fn install_notifier(&self, input: &InputSender<SessionWindowInput>) {
        if let Some(app) = self.application() {
            self.set_notification_sink(default_sink(&app));
        }
        let changed = input.clone();
        self.connect_is_active_notify(move |_| changed.deliver(SessionWindowInput::TabsChanged));
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
        let Some(workspace) = self.workspace_with_tab(work.tab) else {
            return;
        };
        let Some(label) = workspace.notice_label(work.tab) else {
            return;
        };
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
        let workspaces = self.workspaces();
        if workspaces.is_empty() {
            return;
        }
        // A session busy with its input cannot say which tabs it holds,
        // and its notifications stay until it can.
        if let Some(open) = workspaces.iter().map(Workspace::open_tabs).collect::<Option<Vec<_>>>() {
            notifier.withdraw_closed(|tab| open.iter().any(|tabs| tabs.contains(&tab)));
        }
        if self.window_is_active()
            && let Some(tab) = workspaces.iter().find_map(Workspace::selected_tab)
        {
            notifier.tab_became_active(tab);
        }
    }

    /// The notifications of tabs no session holds any more, after one of
    /// the window's sessions closed.
    pub(super) fn withdraw_closed_notifications(&self) {
        let Some(open) = self
            .workspaces()
            .iter()
            .map(Workspace::open_tabs)
            .collect::<Option<Vec<_>>>()
        else {
            return;
        };
        if let Some(notifier) = self.imp().notifier.borrow().as_ref() {
            notifier.withdraw_closed(|tab| open.iter().any(|tabs| tabs.contains(&tab)));
        }
    }

    pub(super) fn on_focus_tab(&self, tab: Uuid) {
        match self.workspace_with_tab(tab).and_then(|workspace| workspace.input()) {
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

#[cfg(not(test))]
fn default_sink(app: &gtk4::Application) -> Rc<dyn NotificationSink> {
    Rc::new(super::application_notification_sink::ApplicationNotificationSink::new(
        app,
    ))
}

/// The tests share a session bus with no notification server on it,
/// where GLib warns about the first notification it cannot send.
#[cfg(test)]
fn default_sink(_: &gtk4::Application) -> Rc<dyn NotificationSink> {
    Rc::new(super::work_notifier::tests::RecordingNotificationSink::default())
}
