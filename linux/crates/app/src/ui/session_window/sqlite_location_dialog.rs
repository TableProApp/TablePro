//! The question asked before a SQLite file on a network or FUSE
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
use tablepro_session::connect::AttemptGeneration;
use tablepro_session::runtime::Tasks;
use tablepro_session::{ConnectSource, RequestTarget};
use tokio_util::sync::CancellationToken;

use super::session_page::SessionPage;
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
    /// ask when SQLite's locking cannot be trusted there.
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
    /// whose locking SQLite can trust. The check reads the disk on the
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
            "SQLite can corrupt a database on a network or FUSE filesystem when more than one program writes to it.",
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
                (file_based && !saved.read_only).then(|| PathBuf::from(&saved.database))
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

    /// The connect stopped before connecting to ask about its file. The
    /// connecting page stays behind the question.
    pub(super) fn ask_about_location(&self, generation: AttemptGeneration, kind: &FileLocationKind) {
        let Some(dialog) = for_location(kind) else {
            self.send(SessionWindowInput::LocationChosen {
                generation,
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
            window.send(SessionWindowInput::LocationChosen { generation, choice });
        });
    }

    pub(super) fn on_location_chosen(&self, generation: AttemptGeneration, choice: LocationChoice) {
        let asking = self.imp().attempts.accepts(generation)
            && self.page_is(|page| matches!(page, SessionPage::Connecting { .. }));
        if !asking {
            return;
        }
        let read_only = match choice {
            LocationChoice::Cancel => {
                self.on_cancel_connect();
                return;
            }
            LocationChoice::ReadOnly => true,
            LocationChoice::ReadWrite => false,
        };
        let SessionPage::Connecting { claim, source } = self.imp().page.replace(SessionPage::Picker) else {
            return;
        };
        self.start_connect(claim, source, Some(read_only));
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::super::tests::{TestWindow, WAIT};
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
        saved.read_only = true;

        test.window.send(SessionWindowInput::OpenSaved(Box::new(saved)));
        test.wait_for_page("workspace");

        assert!(visible_alert(&test.window).is_none());
    }
}
