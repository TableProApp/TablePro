//! A saved file connection whose file is gone: find the file again,
//! save its new path and connect to it.

use std::path::{Path, PathBuf};
use std::rc::Rc;

use futures::FutureExt;
use futures::future::LocalBoxFuture;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::connect::{ConnectionWrites, StoreConnectionWrites};
use tablepro_session::{ConnectSource, SessionKey};
use tablepro_storage::{CredentialDemand, SavedConnection};
use uuid::Uuid;

use super::{SessionWindow, SessionWindowInput};
use crate::runtime::DeliverInput;
use crate::ui::connect_dialog::DatabaseFiles;

const CANCEL: &str = "cancel";
const LOCATE: &str = "locate";

/// Where the user says a lost database file is now.
pub(crate) trait LocateChooser {
    fn choose(
        &self,
        parent: &gtk::Window,
        missing: &Path,
        files: Option<&DatabaseFiles>,
    ) -> LocalBoxFuture<'static, Option<PathBuf>>;
}

/// The file chooser, opened where the file used to be and offering the
/// connection's engine's files first.
struct FileDialogChooser;

impl LocateChooser for FileDialogChooser {
    fn choose(
        &self,
        parent: &gtk::Window,
        missing: &Path,
        files: Option<&DatabaseFiles>,
    ) -> LocalBoxFuture<'static, Option<PathBuf>> {
        let dialog =
            crate::ui::connect_dialog::database_file_dialog(&crate::i18n::gettext("Locate Database File"), files);
        // An initial file is read synchronously, which hangs on a dead
        // mount; a folder is only stored.
        if let Some(folder) = missing.parent() {
            dialog.set_initial_folder(Some(&gio::File::for_path(folder)));
        }
        let parent = parent.clone();
        async move {
            dialog
                .open_future(Some(&parent))
                .await
                .ok()
                .and_then(|file| file.path())
        }
        .boxed_local()
    }
}

fn not_found_dialog(missing: &Path) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("Database File Not Found")),
        Some(&crate::i18n::gettext_f(
            "{file} could not be found. If it was moved or renamed, locate it to update the connection.",
            &[("file", &missing.display().to_string())],
        )),
    );
    dialog.add_responses(&[
        (CANCEL, &crate::i18n::gettext("_Cancel")),
        (LOCATE, &crate::i18n::gettext("_Locate…")),
    ]);
    dialog.set_response_appearance(LOCATE, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(LOCATE));
    dialog.set_close_response(CANCEL);
    dialog
}

impl SessionWindow {
    /// Offer to find the file a saved connection lost. The failed page
    /// stays behind the question, so Cancel leaves Retry and Edit
    /// Connection.
    pub(super) fn offer_locate(&self, id: Uuid, missing: PathBuf) {
        let dialog = not_found_dialog(&missing);
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(window) = window.upgrade() else {
                return;
            };
            if crate::workspace::respond(&dialog, window.upcast_ref()).await == LOCATE {
                window.choose_location(id, missing);
            }
        });
    }

    /// A failure's Details already said the file is gone, so its Locate
    /// File goes straight to the file chooser.
    pub(super) fn locate_for(&self, key: &SessionKey) {
        let lost = self
            .with_failure(key, |source, failure| match source {
                ConnectSource::Saved(saved) => failure.missing_file.clone().map(|missing| (saved.id, missing)),
                _ => None,
            })
            .flatten();
        if let Some((id, missing)) = lost {
            self.choose_location(id, missing);
        }
    }

    fn choose_location(&self, id: Uuid, missing: PathBuf) {
        let files = self.located_files(id);
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(window) = window.upgrade() else {
                return;
            };
            let chooser = window
                .imp()
                .locate_chooser
                .borrow()
                .clone()
                .unwrap_or_else(|| Rc::new(FileDialogChooser));
            let chosen = chooser.choose(window.upcast_ref(), &missing, files.as_ref()).await;
            if let Some(path) = chosen {
                window.send(SessionWindowInput::FileLocated { id, path });
            }
        });
    }

    /// The saved connection whose connect failed under `id`, while its
    /// failure is the window's.
    fn failed_saved(&self, id: Uuid) -> Option<SavedConnection> {
        self.with_failure(&SessionKey::Saved(id), |source, _| match source {
            ConnectSource::Saved(saved) => Some((**saved).clone()),
            _ => None,
        })
        .flatten()
    }

    /// The files the failed connection's engine opens.
    fn located_files(&self, id: Uuid) -> Option<DatabaseFiles> {
        let driver_id = self.failed_saved(id)?.driver_id;
        let driver = self.state()?.context.drivers.get(&driver_id)?;
        DatabaseFiles::of(driver.as_ref())
    }

    /// Save the file's new path on the connection that failed, then
    /// connect to it once the write lands, so the entry and the open
    /// session name the same file.
    pub(super) fn on_file_located(&self, id: Uuid, path: PathBuf) {
        let Some(saved) = self.failed_saved(id) else {
            return;
        };
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        // Deleted in another window while the question was open: writing
        // the failure's copy back would bring it back without its secrets.
        let Some(mut located) = self.saved_as_stored(&saved) else {
            drop(self.take_failure(&SessionKey::Saved(id)));
            self.render();
            self.show_toast(&crate::i18n::gettext("The connection was deleted."));
            return;
        };
        located.database = path.display().to_string();
        let writes = StoreConnectionWrites::new(
            state.services.storage.connections().clone(),
            state.services.tasks.clone(),
        );
        let update = located.clone();
        let held = state.services.hold().acquire();
        crate::runtime::spawn_and_deliver(
            &state.services.tasks,
            async move { writes.upsert(update).await },
            move |written| {
                drop(held);
                let error = match written {
                    Ok(Ok(())) => None,
                    Ok(Err(error)) => Some(error.to_string()),
                    Err(failure) => Some(failure.to_string()),
                };
                if let Some(error) = error {
                    tracing::warn!(%error, "could not save the database file's new location");
                    input.deliver(SessionWindowInput::ShowToast(crate::i18n::gettext(
                        "The new location could not be saved.",
                    )));
                }
                input.deliver(SessionWindowInput::LocatedSaved(Box::new(located)));
            },
        );
    }

    /// Connect to the located file, unless its failure went while its
    /// path was saved: the user left it, or it connected again.
    pub(super) fn on_located_saved(&self, located: SavedConnection) {
        if self.failed_saved(located.id).is_none() {
            return;
        }
        if let Some((claim, _, _)) = self.take_failure(&SessionKey::Saved(located.id)) {
            self.connect_with(
                claim,
                ConnectSource::Saved(Box::new(located)),
                CredentialDemand::default(),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{DriverError, FileEndpoint};
    use tablepro_session::fakes::FakeEstablish;
    use tablepro_session::{ConnectError, RequestTarget};

    use super::super::tests::{Script, TestWindow, WAIT, dialog_submission};
    use super::*;
    use crate::test_support::wait_until;
    use crate::workspace::{answer, visible_alert};

    /// Answers with a file the test made, as a user picking it would.
    struct ChosenFile(PathBuf);

    impl LocateChooser for ChosenFile {
        fn choose(
            &self,
            _parent: &gtk::Window,
            _missing: &Path,
            _files: Option<&DatabaseFiles>,
        ) -> LocalBoxFuture<'static, Option<PathBuf>> {
            let path = self.0.clone();
            async move { Some(path) }.boxed_local()
        }
    }

    fn not_found() -> Script {
        Script {
            establish: vec![FakeEstablish::Fail(ConnectError::Driver(DriverError::FileNotFound {
                path: PathBuf::from("/srv/gone.db"),
            }))],
            ..Script::default()
        }
    }

    fn opened_path(call: &tablepro_session::fakes::EstablishCall) -> PathBuf {
        match &call.request.target {
            RequestTarget::File(endpoint) => {
                assert_eq!(endpoint.mode(), tablepro_core::FileOpenMode::OpenExisting);
                endpoint.path().to_path_buf()
            }
            RequestTarget::Network { .. } => panic!("a file connection opened a network target"),
        }
    }

    #[gtk4::test]
    fn file_not_found_offers_locate_and_retries_with_new_path() {
        let test = TestWindow::with_script("Locate", not_found());
        let moved = tempfile::tempdir().expect("tempdir");
        let found = moved.path().join("moved.db");
        std::fs::write(&found, b"").expect("seed");
        test.window
            .imp()
            .locate_chooser
            .replace(Some(Rc::new(ChosenFile(found.clone()))));

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the not found question");
        let alert = visible_alert(&test.window).expect("the alert");
        assert_eq!(alert.heading().as_deref(), Some("Database File Not Found"));
        assert_eq!(alert.default_response().as_deref(), Some(LOCATE));

        assert!(answer(&test.window, LOCATE));
        test.wait_for_page("workspace");

        let calls = test.connector.calls();
        assert_eq!(calls.len(), 2);
        assert_eq!(opened_path(&calls[1]), found);
        let stored = test
            .services
            .storage
            .connections()
            .load_blocking()
            .expect("the connection list");
        let entry = stored
            .iter()
            .find(|entry| entry.id == test.saved.id)
            .expect("the entry");
        assert_eq!(entry.database, found.display().to_string());
        assert_eq!(entry.name, test.saved.name);
    }

    #[gtk4::test]
    fn cancel_leaves_the_failed_page_and_saves_nothing() {
        let test = TestWindow::with_script("LocateCancel", not_found());

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the not found question");
        let body = visible_alert(&test.window)
            .map(|alert| alert.body().to_string())
            .unwrap_or_default();
        assert!(body.contains("/srv/gone.db"), "{body}");
        assert!(answer(&test.window, CANCEL));
        wait_until(WAIT, || visible_alert(&test.window).is_none()).expect("the question to close");
        crate::test_support::drain_main_context();

        assert_eq!(test.window.page_name(), "connect-failed");
        assert_eq!(test.connector.calls().len(), 1);
        let stored = test
            .services
            .storage
            .connections()
            .load_blocking()
            .expect("the connection list");
        assert_eq!(
            stored
                .iter()
                .find(|entry| entry.id == test.saved.id)
                .map(|entry| &entry.database),
            Some(&test.saved.database)
        );
    }

    #[gtk4::test]
    fn another_failure_offers_no_locate() {
        let test = TestWindow::with_script(
            "LocateOther",
            Script {
                establish: vec![FakeEstablish::Fail(ConnectError::Driver(DriverError::Auth {
                    diagnostics: None,
                }))],
                ..Script::default()
            },
        );

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        crate::test_support::drain_main_context();

        assert!(visible_alert(&test.window).is_none());
    }

    #[gtk4::test]
    fn locate_after_the_entry_was_deleted_returns_to_the_picker_and_saves_nothing() {
        let test = TestWindow::with_script("LocateDeleted", not_found());
        let moved = tempfile::tempdir().expect("tempdir");
        test.window
            .imp()
            .locate_chooser
            .replace(Some(Rc::new(ChosenFile(moved.path().join("moved.db")))));
        let store = test.services.storage.connections().clone();

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the not found question");
        store.remove_blocking(test.saved.id).expect("delete the entry");
        assert!(answer(&test.window, LOCATE));
        test.wait_for_page("picker");
        crate::test_support::drain_main_context();

        assert_eq!(test.connector.calls().len(), 1);
        assert_eq!(test.services.sessions.window_for(&test.key()), None);
        let stored = store.load_blocking().expect("the connection list");
        assert!(
            stored.iter().all(|entry| entry.id != test.saved.id),
            "the deleted entry came back"
        );
    }

    #[gtk4::test]
    fn a_file_located_for_another_connection_is_ignored() {
        let test = TestWindow::with_script("LocateOtherId", not_found());
        let moved = tempfile::tempdir().expect("tempdir");
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the not found question");
        assert!(answer(&test.window, CANCEL));

        test.window.send(SessionWindowInput::FileLocated {
            id: Uuid::new_v4(),
            path: moved.path().join("moved.db"),
        });

        assert!(
            wait_until(std::time::Duration::from_millis(500), || test.connector.calls().len()
                > 1)
            .is_err(),
            "connected to a file located for another connection"
        );
        assert_eq!(test.window.page_name(), "connect-failed");
        let stored = test
            .services
            .storage
            .connections()
            .load_blocking()
            .expect("the connection list");
        assert_eq!(
            stored
                .iter()
                .find(|entry| entry.id == test.saved.id)
                .map(|entry| &entry.database),
            Some(&test.saved.database)
        );
    }

    #[gtk4::test]
    fn a_file_handed_over_that_is_not_found_offers_no_locate() {
        let test = TestWindow::with_script("LocateFileSource", not_found());
        let dir = tempfile::tempdir().expect("tempdir");
        let database = dir.path().join("app.db");
        std::fs::write(&database, b"").expect("seed");

        test.window
            .send(SessionWindowInput::OpenFile(gio::File::for_path(&database)));
        test.wait_for_page("connect-failed");
        crate::test_support::drain_main_context();

        assert!(visible_alert(&test.window).is_none());
    }

    #[gtk4::test]
    fn a_dialog_connect_that_is_not_found_offers_no_locate() {
        let test = TestWindow::with_script("LocateIntent", not_found());
        let dir = tempfile::tempdir().expect("tempdir");
        let endpoint = FileEndpoint::open_existing(dir.path().join("app.db")).expect("an endpoint");

        test.window
            .send(SessionWindowInput::ConnectFromDialog(Box::new(dialog_submission(
                endpoint,
            ))));
        test.wait_for_page("connect-failed");
        crate::test_support::drain_main_context();

        assert!(visible_alert(&test.window).is_none());
    }
}
