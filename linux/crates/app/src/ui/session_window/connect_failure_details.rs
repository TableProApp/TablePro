//! A connect that failed beside the window's sessions stays in this
//! window: a toast says so, and its Details say why and offer the one
//! way on. HIG Dialogs: "Never pop up a dialog window unexpectedly", so
//! the reason waits for the user to ask for it.

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::credentials::SecretKind;
use tablepro_session::{ConnectSource, SessionKey};

use super::session_window_command::ConnectFailure;
use super::{SessionWindow, SessionWindowInput};
use crate::runtime::DeliverInput;

const CLOSE: &str = "close";
const REMEDY: &str = "remedy";

/// The way on that fixes a failed connect, as its Details offer it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Remedy {
    /// Type the secret the server refused.
    Reenter(SecretKind),
    /// Find the database file the saved connection lost.
    Locate,
    /// Open the connect dialog on what failed.
    Edit,
    Retry,
}

impl Remedy {
    pub(crate) fn of(source: &ConnectSource, failure: &ConnectFailure) -> Self {
        match source {
            ConnectSource::Saved(_) => match failure.reenter {
                Some(kind) => Self::Reenter(kind),
                None if failure.missing_file.is_some() => Self::Locate,
                None if failure.remedy.is_some() => Self::Edit,
                None => Self::Retry,
            },
            ConnectSource::Intent(intent) if intent.pending_save.is_some() => Self::Edit,
            ConnectSource::Intent(_) | ConnectSource::File(_) => Self::Retry,
        }
    }

    fn label(self, failure: &ConnectFailure) -> String {
        match self {
            Self::Reenter(kind) => super::secret_retry::reenter_label(kind),
            Self::Locate => crate::i18n::gettext("Locate File…"),
            Self::Edit => super::edit_label(failure),
            Self::Retry => crate::i18n::gettext("Try Again"),
        }
    }
}

impl SessionWindow {
    /// Say that the connect for `key` failed, on the page on screen. The
    /// reason is the dialog's: a toast shows one line.
    pub(super) fn toast_failure(&self, key: &SessionKey, name: &str) {
        let toast = crate::ui::plain_toast(&crate::i18n::gettext_f(
            "Could not connect to “{name}”",
            &[("name", name)],
        ));
        toast.set_button_label(Some(&crate::i18n::gettext("Details")));
        // The target goes first: an action that takes one, named without
        // it, warns that it cannot be activated.
        toast.set_action_target_value(Some(&crate::ui::session_target::to_variant(key)));
        toast.set_action_name(Some("win.show-connect-failure"));
        self.add_toast(toast);
    }

    /// The Details of the last failure for `key`. One the key has since
    /// left, by connecting again, shows nothing.
    pub(super) fn on_show_connect_failure(&self, key: SessionKey) {
        let Some((name, failure, remedy)) = self.with_failure(&key, |source, failure| {
            (super::source_name(source), failure.clone(), Remedy::of(source, failure))
        }) else {
            return;
        };
        let heading = failure
            .heading
            .clone()
            .unwrap_or_else(|| crate::i18n::gettext_f("Could Not Connect to “{name}”", &[("name", &name)]));
        let dialog = adw::AlertDialog::new(Some(&heading), Some(&failure.message));
        dialog.add_responses(&[
            (CLOSE, &crate::i18n::gettext("_Close")),
            (REMEDY, &remedy.label(&failure)),
        ]);
        dialog.set_response_appearance(REMEDY, adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some(REMEDY));
        dialog.set_close_response(CLOSE);
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(window) = window.upgrade() else {
                return;
            };
            let answer = crate::workspace::respond(&dialog, window.upcast_ref()).await;
            if answer == REMEDY
                && let Some(input) = window.input()
            {
                input.deliver(SessionWindowInput::Remedy { key, remedy });
            }
        });
    }

    pub(super) fn on_remedy(&self, key: SessionKey, remedy: Remedy) {
        match remedy {
            Remedy::Reenter(kind) => self.on_retry_with_new_secret(&key, kind),
            Remedy::Locate => self.locate_for(&key),
            Remedy::Edit => self.on_edit_connection(&key),
            Remedy::Retry => self.on_retry_connect(&key),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_session::registry::FileIdentity;
    use tablepro_session::{ConnectIntent, PendingSave};
    use uuid::Uuid;

    use super::*;
    use crate::ui::error_text::TlsRemedy;

    fn saved() -> ConnectSource {
        let saved = crate::ui::session_window::tests::saved_connection(std::path::Path::new("/srv/app.db"));
        ConnectSource::Saved(Box::new(saved))
    }

    fn typed(pending_save: bool) -> ConnectSource {
        let request = tablepro_session::fakes::FakeConnector::request().expect("a request");
        let connection = crate::ui::session_window::tests::saved_connection(std::path::Path::new("/srv/new.db"));
        ConnectSource::Intent(Box::new(ConnectIntent {
            key: SessionKey::Saved(Uuid::new_v4()),
            request,
            pending_save: pending_save.then(|| PendingSave {
                connection,
                secrets: Vec::new(),
                forget: Vec::new(),
                is_new: true,
            }),
        }))
    }

    #[test]
    fn the_details_offer_what_fixes_the_failure() {
        let plain = ConnectFailure::new("refused".to_owned());
        let refused = ConnectFailure {
            reenter: Some(SecretKind::DatabasePassword),
            ..plain.clone()
        };
        let missing = ConnectFailure {
            missing_file: Some(PathBuf::from("/srv/app.db")),
            ..plain.clone()
        };
        let tls = ConnectFailure {
            remedy: Some(TlsRemedy::ChooseCaCertificate),
            ..plain.clone()
        };
        let file = ConnectSource::File(FileIdentity::new(None, "file:///srv/app.db".to_owned()));

        assert_eq!(
            Remedy::of(&saved(), &refused),
            Remedy::Reenter(SecretKind::DatabasePassword)
        );
        assert_eq!(Remedy::of(&saved(), &missing), Remedy::Locate);
        assert_eq!(Remedy::of(&saved(), &tls), Remedy::Edit);
        assert_eq!(Remedy::of(&saved(), &plain), Remedy::Retry);
        assert_eq!(Remedy::of(&typed(true), &plain), Remedy::Edit);
        assert_eq!(Remedy::of(&typed(false), &plain), Remedy::Retry);
        assert_eq!(
            Remedy::of(&file, &missing),
            Remedy::Retry,
            "a file nobody saved has no entry to locate"
        );
    }
}
