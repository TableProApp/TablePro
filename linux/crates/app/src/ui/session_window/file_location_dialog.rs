//! The question asked before a database file on a network or FUSE
//! filesystem opens read-write.

use std::path::PathBuf;

use futures::FutureExt;
use futures::future::BoxFuture;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::FileOpenMode;
use tablepro_session::runtime::Tasks;
use tablepro_session::{ConnectSource, RequestTarget};
use tokio_util::sync::CancellationToken;

use super::session_page::PendingConnect;
use super::session_window_command::{AttemptError, Connected};
use super::{SessionWindow, SessionWindowInput};
use crate::services::file_location::{self, FileLocationKind, LocationClassifier};

const CANCEL: &str = "cancel";
const READ_ONLY: &str = "read-only";
const READ_WRITE: &str = "read-write";

/// How the user chose to open a file the location check flagged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LocationChoice {
    Cancel,
    ReadOnly,
    ReadWrite,
}

/// What a connect knows about where its database file is.
#[derive(Debug)]
pub(crate) enum FileCheck {
    /// Read the filesystem `path` is on before connecting, and stop to
    /// ask when the engines' file locks cannot be trusted there.
    Pending {
        path: PathBuf,
        classify: LocationClassifier,
    },
    /// Nothing to check, or the user answered.
    Settled { read_only: bool },
}

impl FileCheck {
    pub(crate) fn read_only(&self) -> bool {
        matches!(self, Self::Settled { read_only: true })
    }

    /// Run `connecting` once the file is known to be on a filesystem
    /// whose locks the engines can trust. The check reads the disk on the
    /// spawner, and only a file that needs the question comes back to
    /// the GTK thread before connecting.
    pub(crate) fn guard(
        self,
        tasks: &Tasks,
        cancel: CancellationToken,
        connecting: BoxFuture<'static, Result<Connected, AttemptError>>,
    ) -> BoxFuture<'static, Result<Connected, AttemptError>> {
        let Self::Pending { path, classify } = self else {
            return connecting;
        };
        let checking = tasks.spawn_blocking_task(move || classify(&path));
        async move {
            let kind = cancel
                .run_until_cancelled(checking)
                .await
                .ok_or(AttemptError::Cancelled)?
                .unwrap_or_else(|failure| {
                    tracing::warn!(%failure, "could not read the database file's filesystem");
                    FileLocationKind::Unknown { fs_type: String::new() }
                });
            if kind.requires_read_only_prompt() {
                return Err(AttemptError::AskLocation(kind));
            }
            connecting.await
        }
        .boxed()
    }
}

/// The question for a file at `kind`, or `None` when it opens without
/// one.
pub(crate) fn for_location(kind: &FileLocationKind) -> Option<adw::AlertDialog> {
    kind.requires_read_only_prompt().then(location_dialog)
}

fn location_dialog() -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("Database on a Network Filesystem")),
        Some(&crate::i18n::gettext(
            "A database on a network or FUSE filesystem can be corrupted when more than one program writes to it.",
        )),
    );
    dialog.add_responses(&[
        (CANCEL, &crate::i18n::gettext("_Cancel")),
        (READ_ONLY, &crate::i18n::gettext("Open _Read-Only")),
        (READ_WRITE, &crate::i18n::gettext("Open Read-_Write")),
    ]);
    dialog.set_response_appearance(READ_ONLY, adw::ResponseAppearance::Suggested);
    dialog.set_response_appearance(READ_WRITE, adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some(READ_ONLY));
    dialog.set_close_response(CANCEL);
    dialog
}

impl SessionWindow {
    /// The file a connect would open read-write. A file opened
    /// read-only needs no question, nor does a new one, which no other
    /// program writes to yet.
    pub(super) fn file_to_check(&self, source: &ConnectSource) -> Option<PathBuf> {
        match source {
            ConnectSource::File(identity) => identity.canonical_path.clone(),
            ConnectSource::Saved(saved) => {
                let file_based = self
                    .state()?
                    .context
                    .drivers
                    .get(&saved.driver_id)
                    .is_some_and(|driver| driver.capabilities().is_file_based());
                (file_based && !saved.safe_mode.blocks_writes()).then(|| PathBuf::from(&saved.database))
            }
            ConnectSource::Intent(intent) => match &intent.request.target {
                RequestTarget::File(endpoint)
                    if endpoint.mode() == FileOpenMode::OpenExisting
                        && !intent.request.workspace_settings.read_only =>
                {
                    Some(endpoint.path().to_path_buf())
                }
                _ => None,
            },
        }
    }

    /// What a connect from `source` checks before it starts. `answer`
    /// is how the user chose to open a file they were already asked
    /// about.
    pub(super) fn file_check(&self, source: &ConnectSource, answer: Option<bool>) -> FileCheck {
        if let Some(read_only) = answer {
            return FileCheck::Settled { read_only };
        }
        match self.file_to_check(source) {
            Some(path) => FileCheck::Pending {
                path,
                classify: self
                    .imp()
                    .classify_location
                    .get()
                    .unwrap_or(file_location::classify_blocking),
            },
            None => FileCheck::Settled { read_only: false },
        }
    }

    /// Connect `id` stopped before connecting to ask about its file,
    /// over this window, whatever else it shows. The connect stays among
    /// the window's until the answer.
    pub(super) fn ask_about_location(&self, id: u64, kind: &FileLocationKind) {
        let Some(dialog) = for_location(kind) else {
            self.send(SessionWindowInput::LocationChosen {
                id,
                choice: LocationChoice::ReadWrite,
            });
            return;
        };
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(window) = window.upgrade() else {
                return;
            };
            let choice = match crate::workspace::respond(&dialog, window.upcast_ref()).await.as_str() {
                READ_ONLY => LocationChoice::ReadOnly,
                READ_WRITE => LocationChoice::ReadWrite,
                _ => LocationChoice::Cancel,
            };
            window.send(SessionWindowInput::LocationChosen { id, choice });
        });
    }

    /// The same connect goes on, in its place among the others, under a
    /// new id: a result of the one that asked can no longer be taken
    /// for it. One stopped while the question was open is not started.
    pub(super) fn on_location_chosen(&self, id: u64, choice: LocationChoice) {
        let imp = self.imp();
        let position = imp.connects.borrow().iter().position(|pending| pending.id == id);
        let Some(position) = position else {
            return;
        };
        let asked = imp.connects.borrow_mut().remove(position);
        let read_only = match choice {
            LocationChoice::Cancel => {
                self.drop_connect(asked);
                self.connects_changed();
                return;
            }
            LocationChoice::ReadOnly => true,
            LocationChoice::ReadWrite => false,
        };
        let PendingConnect {
            claim, source, demand, ..
        } = asked;
        if let Some(pending) = self.spawn_connect(claim, source, Some(read_only), demand) {
            imp.connects.borrow_mut().insert(position, pending);
        }
        self.connects_changed();
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tablepro_core::FileEndpoint;

    use super::super::tests::{TestWindow, WAIT, dialog_submission};
    use super::*;
    use crate::test_support::wait_until;
    use crate::workspace::{answer, visible_alert};

    fn on_a_share(_path: &Path) -> FileLocationKind {
        FileLocationKind::Remote {
            fs_type: "nfs4".to_owned(),
        }
    }

    fn open_saved_on_a_share(name: &str) -> TestWindow {
        let test = TestWindow::picker(name);
        test.window.imp().classify_location.set(Some(on_a_share));
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the location question");
        test
    }

    #[gtk4::test]
    fn default_response_is_read_only() {
        adw::init().expect("libadwaita initialises under the test backend");

        let dialog = for_location(&on_a_share(Path::new("/mnt/share/app.db"))).expect("a question");

        assert_eq!(dialog.default_response().as_deref(), Some(READ_ONLY));
        assert_eq!(dialog.close_response(), CANCEL);
        assert_eq!(
            dialog.response_appearance(READ_ONLY),
            adw::ResponseAppearance::Suggested
        );
        assert_eq!(
            dialog.response_appearance(READ_WRITE),
            adw::ResponseAppearance::Destructive
        );
        assert!(for_location(&FileLocationKind::Local).is_none());
    }

    #[gtk4::test]
    fn portal_path_without_host_path_offers_read_only_default() {
        adw::init().expect("libadwaita initialises under the test backend");
        let portal = FileLocationKind::portal(None, |_| true, |_| FileLocationKind::Local);

        let dialog = for_location(&portal).expect("a question for a portal file");

        assert_eq!(dialog.default_response().as_deref(), Some(READ_ONLY));
    }

    #[gtk4::test]
    fn a_file_on_a_share_opens_read_only_when_asked() {
        let test = open_saved_on_a_share("ShareReadOnly");
        assert!(
            test.connector.calls().is_empty(),
            "the connect did not wait for the answer"
        );

        assert!(answer(&test.window, READ_ONLY));
        test.wait_for_page("workspace");

        let calls = test.connector.calls();
        assert_eq!(calls.len(), 1);
        assert!(calls[0].request.workspace_settings.read_only);
    }

    #[gtk4::test]
    fn a_file_on_a_share_opens_read_write_when_asked() {
        let test = open_saved_on_a_share("ShareReadWrite");

        assert!(answer(&test.window, READ_WRITE));
        test.wait_for_page("workspace");

        assert!(!test.connector.calls()[0].request.workspace_settings.read_only);
    }

    #[gtk4::test]
    fn cancel_at_the_question_connects_nothing_and_frees_the_connection() {
        let test = open_saved_on_a_share("ShareCancel");

        assert!(answer(&test.window, CANCEL));
        test.wait_for_page("picker");
        crate::test_support::drain_main_context();

        assert!(test.connector.calls().is_empty());
        assert_eq!(test.services.sessions.window_for(&test.key()), None);
    }

    #[gtk4::test]
    fn a_read_only_connection_is_not_asked_about() {
        let test = TestWindow::picker("ShareSavedReadOnly");
        test.window.imp().classify_location.set(Some(on_a_share));
        let mut saved = test.saved.clone();
        saved.safe_mode = tablepro_core::SafeModeLevel::ReadOnly;
        test.services
            .storage
            .connections()
            .upsert_blocking(saved.clone())
            .expect("save the entry read-only");

        test.window.send(SessionWindowInput::OpenSaved(Box::new(saved)));
        test.wait_for_page("workspace");

        assert!(visible_alert(&test.window).is_none());
    }

    #[gtk4::test]
    fn a_file_handed_over_from_a_share_is_asked_about() {
        let test = TestWindow::picker("ShareFile");
        test.window.imp().classify_location.set(Some(on_a_share));
        let dir = tempfile::tempdir().expect("tempdir");
        let database = dir.path().join("app.db");
        std::fs::write(&database, b"").expect("seed");

        test.window
            .send(SessionWindowInput::OpenFile(gio::File::for_path(&database)));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the location question");
        assert!(test.connector.calls().is_empty());
        assert!(answer(&test.window, READ_ONLY));
        test.wait_for_page("workspace");

        let calls = test.connector.calls();
        assert_eq!(calls.len(), 1);
        assert!(calls[0].request.workspace_settings.read_only);
    }

    /// The question goes over this window, and the connect it held back
    /// joins the sessions there.
    #[gtk4::test]
    fn a_file_opened_beside_the_sessions_is_asked_about_here() {
        let test = TestWindow::connected("ShareBeside");
        test.window.imp().classify_location.set(Some(on_a_share));
        let dir = tempfile::tempdir().expect("tempdir");
        let database = dir.path().join("app.db");
        std::fs::write(&database, b"").expect("seed");

        test.window
            .send(SessionWindowInput::OpenFile(gio::File::for_path(&database)));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the location question");
        assert_eq!(test.connector.calls().len(), 1, "the file connected before the answer");
        assert!(answer(&test.window, READ_ONLY));
        wait_until(WAIT, || test.window.workspaces().len() == 2).expect("the file to join the window");

        assert_eq!(test.app.windows().len(), 1, "the question went to a window of its own");
        assert!(test.connector.calls()[1].request.workspace_settings.read_only);
    }

    #[gtk4::test]
    fn an_existing_file_from_the_connect_dialog_is_asked_about() {
        let test = TestWindow::picker("ShareDialog");
        test.window.imp().classify_location.set(Some(on_a_share));
        let endpoint = FileEndpoint::open_existing(PathBuf::from("/mnt/share/app.db")).expect("an endpoint");

        test.window
            .send(SessionWindowInput::ConnectFromDialog(Box::new(dialog_submission(
                endpoint,
            ))));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the location question");
        assert!(test.connector.calls().is_empty());
        assert!(answer(&test.window, READ_ONLY));
        test.wait_for_page("workspace");

        assert!(test.connector.calls()[0].request.workspace_settings.read_only);
    }

    #[gtk4::test]
    fn a_new_file_from_the_connect_dialog_is_not_asked_about() {
        let test = TestWindow::picker("ShareDialogNew");
        test.window.imp().classify_location.set(Some(on_a_share));
        let endpoint = FileEndpoint::create_new(PathBuf::from("/mnt/share/new.db")).expect("an endpoint");

        test.window
            .send(SessionWindowInput::ConnectFromDialog(Box::new(dialog_submission(
                endpoint,
            ))));
        test.wait_for_page("workspace");

        assert!(visible_alert(&test.window).is_none());
        assert!(!test.connector.calls()[0].request.workspace_settings.read_only);
    }
}
