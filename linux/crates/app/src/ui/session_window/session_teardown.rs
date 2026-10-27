//! The ordered teardown of a window's session, for a disconnect and an
//! approved close.

use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita::prelude::AdwApplicationWindowExt;
use tablepro_core::EditorSession;
use tablepro_session::Session;
use tablepro_session::runtime::{ProcessHold, Tasks};

use tablepro_session::SessionKey;

use super::SessionWindow;
use super::session_page::{OpenSession, SessionPage};
use crate::ui::workspace::WorkspaceShell;

impl SessionWindow {
    /// Take every session's workspace down once the close prompts
    /// approved, and close the sessions under one hold each. False when
    /// the window shows no workspace.
    ///
    /// The order matters. What a workspace shows is written before it
    /// is freed; the workspace goes before the claim, so nothing of it
    /// reads for a key another window can now claim; and the claim goes
    /// before the close finishes, so the same connection can be picked
    /// again at once.
    pub(super) fn tear_down(&self) -> bool {
        let imp = self.imp();
        if self.state().is_none() {
            return false;
        }
        let Ok(mut page) = imp.page.try_borrow_mut() else {
            tracing::warn!("the session was torn down while its page was in use");
            return false;
        };
        if !matches!(*page, SessionPage::Workspace { .. }) {
            return false;
        }
        let SessionPage::Workspace { shell, sessions } = std::mem::take(&mut *page) else {
            return false;
        };
        drop(page);
        for open in &sessions {
            open.workspace.flush();
        }
        self.set_content(gtk::Widget::NONE);
        imp.page_toasts.replace(None);
        self.set_title(Some(&crate::i18n::gettext("TablePro")));
        for open in sessions {
            self.close_open_session(&shell, open, false);
        }
        shell.shutdown();
        self.withdraw_notifications();
        imp.dirty.set(false);
        imp.saving.set(false);
        self.refresh_inhibitor();
        super::window_actions::sync(self.upcast_ref(), &SessionPage::Picker, false);
        true
    }

    /// Take down the one session under `key`, in the same order, while
    /// the window keeps its others. The last one tears the whole page
    /// down, and true then means the window shows no workspace. False
    /// when the window does not hold `key`.
    pub(super) fn tear_down_session(&self, key: &SessionKey) -> bool {
        let imp = self.imp();
        let Ok(mut page) = imp.page.try_borrow_mut() else {
            tracing::warn!("a session was torn down while its page was in use");
            return false;
        };
        let SessionPage::Workspace { shell, sessions } = &mut *page else {
            return false;
        };
        let Some(position) = sessions.iter().position(|open| open.claim.key() == key) else {
            return false;
        };
        if sessions.len() == 1 {
            drop(page);
            return self.tear_down();
        }
        let open = sessions.remove(position);
        let shell = shell.clone();
        drop(page);
        open.workspace.flush();
        self.close_open_session(&shell, open, true);
        self.withdraw_closed_notifications();
        self.refresh_dirty();
        self.sync_front();
        true
    }

    /// Shut `open`'s workspace down, take it off the shell, drop its
    /// claim and record, and close its session. Its pages leave the tab
    /// view first when `close_pages`, so the shell picks the next front
    /// from a page that stays.
    fn close_open_session(&self, shell: &WorkspaceShell, open: OpenSession, close_pages: bool) {
        let Some(state) = self.state() else {
            return;
        };
        let OpenSession {
            claim,
            session,
            workspace,
        } = open;
        let editor_sessions = workspace.take_editor_sessions();
        let key = claim.key().clone();
        workspace.shutdown(close_pages);
        shell.remove_session(&workspace, &key);
        drop(workspace);
        drop(claim);
        // A quit freezes the record first, so only a disconnect or a
        // window closed by hand takes the session off it.
        self.forget_session(&key);
        close_session(
            session,
            editor_sessions,
            &*state.services.hold(),
            &state.services.tasks,
            state.context.close_timeout(),
        );
    }
}

/// Close the session and every editor tab's connection together, under
/// the close deadline. One hold keeps the process alive until all of
/// them end, so quitting right after a disconnect closes them rather
/// than cutting them off.
fn close_session(
    session: Arc<Session>,
    editor_sessions: Vec<Arc<dyn EditorSession>>,
    hold: &dyn ProcessHold,
    tasks: &Tasks,
    close_timeout: Duration,
) {
    let hold = hold.acquire();
    let editors_closing = tablepro_session::close_editor_sessions(editor_sessions, close_timeout, tasks);
    let closing = session.begin_shutdown();
    drop(session);
    glib::spawn_future_local(async move {
        let (closed, editors) = futures::future::join(closing, editors_closing).await;
        match closed {
            Ok(report) => tracing::debug!(?report, "the session closed"),
            Err(failure) => tracing::warn!(%failure, "the session close task failed"),
        }
        match editors {
            Ok(reports) => tracing::debug!(?reports, "the editor tabs' sessions closed"),
            Err(failure) => tracing::warn!(%failure, "closing the editor tabs' sessions failed"),
        }
        drop(hold);
    });
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::EditorSession;
    use tablepro_test_support::{CallCounters, CloseBehaviour, FakeEditorSession, FakeReply, FakeRun, Replies};

    use std::cell::RefCell;
    use std::rc::Rc;

    use tablepro_session::RegistryEvent;

    use super::*;
    use crate::test_support::wait_until;
    use crate::ui::session_window::SessionWindowInput;
    use crate::ui::session_window::tests::{TestWindow, WAIT};

    #[gtk4::test]
    fn disconnect_runs_ordered_teardown() {
        let test = TestWindow::connected("OrderedTeardown");
        let workspace = test.workspace().downgrade();
        let key = test.key();
        wait_until(WAIT, || test.hold.live() == 0).expect("the workspace's opening writes to land");
        // Each step records what had happened before it. Only the flush
        // holds the process before the claim goes, and the close's hold
        // comes after it.
        let steps = Rc::new(RefCell::new(Vec::new()));
        let (detached, hold) = (steps.clone(), test.hold.clone());
        test.workspace()
            .connect_notify_local(Some("parent"), move |workspace, _| {
                if workspace.parent().is_none() {
                    detached.borrow_mut().push(("detached", hold.live() > 0));
                }
            });
        let (released, gone) = (steps.clone(), workspace.clone());
        let _subscription = test.services.sessions.subscribe(move |event| {
            if matches!(event, RegistryEvent::Released { .. }) {
                let shut_down = gone.upgrade().is_none_or(|workspace| workspace.handle().is_none());
                released.borrow_mut().push(("released", shut_down));
            }
        });

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");

        assert_eq!(
            *steps.borrow(),
            [("detached", true), ("released", true)],
            "a step ran before the one it depends on"
        );

        let child = test.window.content();
        assert!(
            child.is_some_and(|child| child.type_().name() == "TableProPickerPage"),
            "the picker did not replace the workspace"
        );
        let counters = test.connection().counters();
        wait_until(WAIT, || CallCounters::get(&counters.close) == 1).expect("the connection to close");
        crate::test_support::drain_main_context();
        assert_eq!(
            CallCounters::get(&counters.close),
            1,
            "the connection closed more than once"
        );
        // GTK holds a widget that had the focus until the window paints
        // again, and a delivery still in flight holds the workspace until
        // its aborted task's result reaches the main context.
        crate::test_support::after_next_frame(&test.window);
        wait_until(WAIT, || workspace.upgrade().is_none()).expect("the workspace outlived its teardown");
        let claim = test
            .services
            .sessions
            .claim(key, test.window.id() + 100)
            .expect("the key is free again at once");
        drop(claim);
    }

    #[gtk4::test]
    fn disconnect_closes_editor_sessions_once() {
        let delayed = || {
            let mut runs = Replies::default();
            runs.always(FakeRun::completed(Vec::new()));
            std::sync::Arc::new(FakeEditorSession::with_close(
                runs,
                CloseBehaviour::Delay(Duration::from_millis(100)),
            ))
        };
        let (first, second) = (delayed(), delayed());
        let test = TestWindow::connected_with("EditorSessions", |script| {
            let (a, b): (Arc<dyn EditorSession>, Arc<dyn EditorSession>) = (first.clone(), second.clone());
            script.open_editor_session.once(FakeReply::ok(a));
            script.open_editor_session.once(FakeReply::ok(b));
        });
        test.run_in_new_editor_tab();
        test.run_in_new_editor_tab();
        wait_until(WAIT, || !first.texts().is_empty() && !second.texts().is_empty())
            .expect("both tabs to open their sessions");

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        assert!(test.hold.live() > 0, "nothing held the process for the closes");
        wait_until(WAIT, || test.hold.live() == 0).expect("the holds to end");

        assert!(
            first.is_closed() && second.is_closed(),
            "the hold ended before both delayed closes did"
        );
        assert_eq!((first.close_count(), second.close_count()), (1, 1));
    }
}
