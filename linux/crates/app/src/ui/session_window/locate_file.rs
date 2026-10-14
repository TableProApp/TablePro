//! A saved SQLite connection whose file is gone: find the file again,
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
use tablepro_session::ConnectSource;
use tablepro_session::connect::{ConnectionWrites, StoreConnectionWrites};
use tablepro_storage::SavedConnection;

use super::session_page::SessionPage;
use super::{SessionWindow, SessionWindowInput};
use crate::runtime::DeliverInput;

const CANCEL: &str = "cancel";
const LOCATE: &str = "locate";

/// Where the user says a lost database file is now.
pub(crate) trait LocateChooser {
    fn choose(&self, parent: &gtk::Window, missing: &Path) -> LocalBoxFuture<'static, Option<PathBuf>>;
}

/// The file chooser, opened where the file used to be.
struct FileDialogChooser;

impl LocateChooser for FileDialogChooser {
    fn choose(&self, parent: &gtk::Window, missing: &Path) -> LocalBoxFuture<'static, Option<PathBuf>> {
        let dialog = crate::ui::connect_dialog::sqlite_file_dialog(&crate::i18n::gettext("Locate Database File"));
        dialog.set_initial_file(Some(&gio::File::for_path(missing)));
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
    pub(super) fn offer_locate(&self, missing: PathBuf) {
        let dialog = not_found_dialog(&missing);
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(window) = window.upgrade() else {
                return;
            };
            if crate::workspace::respond(&dialog, window.upcast_ref()).await != LOCATE {
                return;
            }
            let chooser = window
                .imp()
                .locate_chooser
                .borrow()
                .clone()
                .unwrap_or_else(|| Rc::new(FileDialogChooser));
            let chosen = chooser.choose(window.upcast_ref(), &missing).await;
            if let Some(path) = chosen {
                window.send(SessionWindowInput::FileLocated(path));
            }
        });
    }

    /// Save the file's new path on the connection the failed page is
    /// about, then connect to it once the write lands, so the entry and
    /// the open session name the same file.
    pub(super) fn on_file_located(&self, path: PathBuf) {
        let saved = match &*self.imp().page.borrow() {
            SessionPage::ConnectFailed {
                source: ConnectSource::Saved(saved),
                ..
            } => (**saved).clone(),
            _ => return,
        };
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let mut located = self.saved_as_stored(&saved).unwrap_or(saved);
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
                input.deliver(SessionWindowInput::ReloadConnections);
                input.deliver(SessionWindowInput::LocatedSaved(Box::new(located)));
            },
        );
    }

    /// Connect to the located file, unless the user left the failed
    /// page while its path was saved.
    pub(super) fn on_located_saved(&self, located: SavedConnection) {
        let current = match &*self.imp().page.borrow() {
            SessionPage::ConnectFailed {
                source: ConnectSource::Saved(saved),
                ..
            } => saved.id == located.id,
            _ => false,
        };
        if !current {
            return;
        }
        let SessionPage::ConnectFailed { claim, .. } = self.imp().page.replace(SessionPage::Picker) else {
            return;
        };
        self.begin_connect(claim, ConnectSource::Saved(Box::new(located)));
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::DriverError;
    use tablepro_session::fakes::FakeEstablish;
    use tablepro_session::{ConnectError, RequestTarget};

    use super::super::tests::{Script, TestWindow, WAIT};
    use super::*;
    use crate::test_support::wait_until;
    use crate::workspace::{answer, visible_alert};

    /// Answers with a file the test made, as a user picking it would.
    struct ChosenFile(PathBuf);

    impl LocateChooser for ChosenFile {
        fn choose(&self, _parent: &gtk::Window, _missing: &Path) -> LocalBoxFuture<'static, Option<PathBuf>> {
            let path = self.0.clone();
            async move { Some(path) }.boxed_local()
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
        let test = TestWindow::with_script(
            "Locate",
            Script {
                establish: vec![FakeEstablish::Fail(ConnectError::Driver(DriverError::FileNotFound {
                    path: PathBuf::from("/srv/gone.db"),
                }))],
                ..Script::default()
            },
        );
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
        let test = TestWindow::with_script(
            "LocateCancel",
            Script {
                establish: vec![FakeEstablish::Fail(ConnectError::Driver(DriverError::FileNotFound {
                    path: PathBuf::from("/srv/gone.db"),
                }))],
                ..Script::default()
            },
        );

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
}
