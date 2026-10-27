//! Reopening a session that was open when the application last quit,
//! and keeping the record of open sessions in step with the window.

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_session::SessionKey;
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::session_page::SessionPage;
use super::{SessionWindow, SessionWindowInput};
use crate::application::WindowLaunch;
use crate::runtime::DeliverInput;

impl SessionWindow {
    /// A file opens as the file manager would open it. A saved
    /// connection is looked up first, since it may have been deleted
    /// since the quit.
    pub(super) fn on_restore(&self, key: SessionKey) {
        let id = match key {
            SessionKey::File(uri) => {
                self.on_open_file(gio::File::for_uri(&uri));
                return;
            }
            SessionKey::Saved(id) => id,
        };
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let store = state.services.storage.connections().clone();
        let reading = state.services.tasks.spawn_blocking_task(move || store.load_blocking());
        glib::spawn_future_local(async move {
            match reading.await {
                Ok(Ok(connections)) => {
                    let saved = connections.iter().find(|saved| saved.id == id).cloned().map(Box::new);
                    input.deliver(SessionWindowInput::RestoreSaved { id, saved });
                }
                // The key stays recorded: the list may read again once
                // the user resets it, which the picker's banner offers.
                Ok(Err(error)) => {
                    tracing::warn!(%error, "a session was not restored: the saved connections could not be read")
                }
                Err(failure) => {
                    tracing::warn!(%failure, "a session was not restored: the connections read task failed")
                }
            }
        });
    }

    pub(super) fn on_restore_saved(&self, id: Uuid, saved: Option<SavedConnection>) {
        self.end_restore(&SessionKey::Saved(id));
        match saved {
            Some(saved) => self.on_open_saved(saved),
            None => {
                self.forget_session(&SessionKey::Saved(id));
                self.show_toast(&crate::i18n::gettext("The connection was deleted."));
                self.continue_restore();
            }
        }
    }

    /// Record the session the window adopted when a later launch can
    /// open it again: a file, or a connection the saved list holds. One
    /// that was never saved has nothing to reopen it from.
    pub(super) fn remember_session(&self, key: &SessionKey, saved: Option<&SavedConnection>) {
        let restorable = match key {
            SessionKey::File(_) => true,
            SessionKey::Saved(_) => saved.is_some(),
        };
        if restorable && let Some(state) = self.state() {
            state.services.open_sessions().add(key.clone(), self.id());
        }
    }

    pub(super) fn forget_session(&self, key: &SessionKey) {
        if let Some(state) = self.state() {
            state.services.open_sessions().remove(key);
        }
    }

    /// The restore has its answer, and the page the window shows next
    /// speaks for the key.
    pub(super) fn end_restore(&self, key: &SessionKey) {
        self.imp().restoring.borrow_mut().retain(|restoring| restoring != key);
    }

    /// Start the keys still waiting to be restored once the window can
    /// take them: all of them beside the workspace the first one opened,
    /// or the next one on the picker when the one before did not open.
    /// A failed page keeps the window, so the rest go to a window of
    /// their own.
    pub(super) fn continue_restore(&self) {
        let imp = self.imp();
        if imp.restore_waiting.borrow().is_empty() {
            return;
        }
        let Some(input) = self.input() else {
            return;
        };
        let started: Vec<SessionKey> = match &*imp.page.borrow() {
            SessionPage::Workspace { .. } => imp.restore_waiting.take(),
            SessionPage::Picker => {
                let mut waiting = imp.restore_waiting.borrow_mut();
                vec![waiting.remove(0)]
            }
            SessionPage::ConnectFailed { .. } => {
                let rest = imp.restore_waiting.take();
                imp.restoring.borrow_mut().retain(|key| !rest.contains(key));
                if let Some(state) = self.state() {
                    state.host.open_window(WindowLaunch::Restore(rest));
                }
                Vec::new()
            }
            SessionPage::Connecting { .. } => Vec::new(),
        };
        for key in started {
            input.deliver(SessionWindowInput::Restore(key));
        }
    }

    /// A window closed before its restore had an answer holds no claim
    /// whose release would forget the keys.
    pub(super) fn abandon_restore(&self) {
        self.imp().restore_waiting.take();
        for key in self.imp().restoring.take() {
            self.forget_unclaimed(&key);
        }
    }

    /// Forget a key this window has no claim on, unless another window
    /// shows that session.
    pub(super) fn forget_unclaimed(&self, key: &SessionKey) {
        if let Some(state) = self.state()
            && state.context.sessions.window_for(key).is_none()
        {
            state.services.open_sessions().remove(key);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_session::fakes::{FakeConnector, FakeEstablish};
    use tablepro_session::{PendingSave, SessionKey};
    use tablepro_test_support::ConnectionScript;

    use super::*;
    use crate::application::WindowLaunch;
    use crate::test_support::wait_until;
    use crate::ui::connect_dialog::ConnectSubmission;
    use crate::ui::session_window::tests::{Script, TestWindow, WAIT};
    use crate::workspace::OpenSessionsRecord;

    impl TestWindow {
        fn recorded(&self) -> Vec<SessionKey> {
            self.services.open_sessions().keys()
        }

        /// Open a window on `key` the way a launch restoring it does.
        fn restored_window(&self, key: &SessionKey) -> SessionWindow {
            self.services
                .open_sessions()
                .restore(OpenSessionsRecord::from_windows([[key]]));
            self.app
                .open_window(WindowLaunch::Restore(vec![key.clone()]))
                .and_then(|window| window.downcast::<SessionWindow>().ok())
                .expect("a restored window")
        }

        /// The URI a file under the test's directory is keyed by.
        fn file_key(&self, name: &str) -> SessionKey {
            let dir = std::fs::canonicalize(self.dir()).expect("the canonical directory");
            let uri = glib::filename_to_uri(dir.join(name), None).expect("a file URI");
            SessionKey::File(uri.to_string())
        }
    }

    fn wait_for(window: &SessionWindow, page: &str) {
        wait_until(WAIT, || window.page_name() == page)
            .unwrap_or_else(|_| panic!("the window stayed on {}, not {page}", window.page_name()));
    }

    fn submission(test: &TestWindow) -> ConnectSubmission {
        let mut connection = test.saved.clone();
        connection.id = Uuid::new_v4();
        connection.name = "Submitted".to_owned();
        ConnectSubmission {
            request: FakeConnector::request().expect("a request"),
            pending_save: PendingSave {
                connection,
                secrets: Vec::new(),
                forget: Vec::new(),
                is_new: true,
            },
        }
    }

    #[gtk4::test]
    fn adoption_adds_persisted_key_only() {
        let test = TestWindow::picker("AdoptPersisted");
        let list = test.services.storage.paths().connections_file();
        // A directory where the list goes makes its write fail.
        std::fs::remove_file(&list).expect("remove the list");
        std::fs::create_dir(&list).expect("block the list");
        let refused = submission(&test);
        let refused_key = SessionKey::Saved(refused.pending_save.connection.id);

        test.window
            .send(SessionWindowInput::ConnectFromDialog(Box::new(refused)));
        test.wait_for_page("connect-failed");
        assert!(
            !test.recorded().contains(&refused_key),
            "a connection whose entry was not saved was recorded"
        );

        std::fs::remove_dir(&list).expect("unblock the list");
        test.window.send(SessionWindowInput::CancelConnect);
        test.wait_for_page("picker");
        let saved = submission(&test);
        let saved_key = SessionKey::Saved(saved.pending_save.connection.id);
        test.window.send(SessionWindowInput::ConnectFromDialog(Box::new(saved)));
        test.wait_for_page("workspace");

        assert_eq!(test.recorded(), [saved_key]);
    }

    #[gtk4::test]
    fn an_opened_file_is_recorded_and_a_disconnect_forgets_it() {
        let test = TestWindow::picker("RecordFile");
        std::fs::write(test.dir().join("local.db"), b"").expect("seed");
        let key = test.file_key("local.db");

        test.window.send(SessionWindowInput::OpenFile(gio::File::for_path(
            test.dir().join("local.db"),
        )));
        test.wait_for_page("workspace");
        assert_eq!(test.recorded(), std::slice::from_ref(&key));

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        assert!(test.recorded().is_empty(), "a disconnected session stayed recorded");
    }

    #[gtk4::test]
    fn a_closed_window_forgets_its_session() {
        let test = TestWindow::connected("CloseForgets");
        assert_eq!(test.recorded(), [test.key()]);

        test.window.close();

        wait_until(WAIT, || test.recorded().is_empty()).expect("the closed window's session to be forgotten");
    }

    #[gtk4::test]
    fn a_restored_saved_connection_connects_and_stays_recorded() {
        let test = TestWindow::picker("RestoreSaved");

        let window = test.restored_window(&test.key());
        wait_for(&window, "workspace");

        assert_eq!(test.services.sessions.window_for(&test.key()), Some(window.id()));
        assert_eq!(test.recorded(), [test.key()]);
    }

    #[gtk4::test]
    fn cancel_connect_removes_key() {
        let test = TestWindow::with_script(
            "RestoreCancel",
            Script {
                establish: vec![FakeEstablish::Late {
                    after: Duration::from_millis(300),
                    script: ConnectionScript::default(),
                }],
                ..Script::default()
            },
        );
        let window = test.restored_window(&test.key());
        wait_for(&window, "connecting");
        assert_eq!(test.recorded(), [test.key()]);

        window.send(SessionWindowInput::CancelConnect);
        wait_for(&window, "picker");

        assert!(test.recorded().is_empty(), "a cancelled restore stayed recorded");
    }

    #[gtk4::test]
    fn a_deleted_saved_connection_is_forgotten_and_shows_the_picker() {
        let test = TestWindow::picker("RestoreDeleted");
        let gone = SessionKey::Saved(Uuid::new_v4());

        let window = test.restored_window(&gone);
        wait_until(WAIT, || test.recorded().is_empty()).expect("the deleted connection to be forgotten");

        assert_eq!(window.page_name(), "picker");
        assert!(
            test.connector.calls().is_empty(),
            "a deleted connection was connected to"
        );
    }

    #[gtk4::test]
    fn a_restored_window_closed_before_its_lookup_forgets_the_session() {
        let test = TestWindow::picker("RestoreClosedEarly");

        let window = test.restored_window(&test.key());
        window.close();

        assert!(
            test.recorded().is_empty(),
            "the closed window's session stayed recorded"
        );
        let _ = wait_until(Duration::from_millis(300), || {
            test.services.sessions.window_for(&test.key()).is_some()
        });
        assert_eq!(
            test.services.sessions.window_for(&test.key()),
            None,
            "the closed window connected"
        );
    }

    #[gtk4::test]
    fn a_failed_open_of_a_file_another_window_shows_keeps_it_recorded() {
        let test = TestWindow::picker("OpenGoneFile");
        let path = test.dir().join("local.db");
        std::fs::write(&path, b"").expect("seed");
        let key = test.file_key("local.db");
        test.window
            .send(SessionWindowInput::OpenFile(gio::File::for_path(&path)));
        test.wait_for_page("workspace");
        std::fs::remove_file(&path).expect("delete the file");
        let SessionKey::File(uri) = &key else {
            panic!("{key:?} is not a file key");
        };
        test.window.set_visible(false);

        test.app.open_window(WindowLaunch::OpenFile(gio::File::for_uri(uri)));
        wait_until(WAIT, || test.window.is_visible()).expect("the window showing the file to come forward");

        assert_eq!(test.recorded(), [key]);
    }

    #[gtk4::test]
    fn a_missing_file_is_forgotten_and_a_retry_records_it_again() {
        let test = TestWindow::picker("RestoreMissing");
        let key = test.file_key("later.db");

        let window = test.restored_window(&key);
        wait_for(&window, "connect-failed");
        assert!(test.recorded().is_empty(), "a file that is gone stayed recorded");

        std::fs::write(test.dir().join("later.db"), b"").expect("create the file");
        window.send(SessionWindowInput::RetryConnect);
        wait_for(&window, "workspace");

        assert_eq!(test.recorded(), [key]);
    }
}
