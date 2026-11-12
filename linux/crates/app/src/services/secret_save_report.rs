use std::sync::Arc;

use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialInteraction, SecretError, SecretKind, SecretSave};
use tablepro_session::{ConnectError, ConnectRequest, CredentialSource, RefreshedRequest};
use tablepro_storage::CredentialDemand;

use crate::i18n::{gettext, gettext_f, ngettext};

/// A save the user asked for that the keyring refused, said once per save.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct SecretSaveReport {
    unsaved: Unsaved,
    error: SecretError,
}

/// What came of the secrets one save asked the keyring to keep.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum SecretSaveOutcome {
    Kept,
    Refused(SecretSaveReport),
}

impl SecretSaveOutcome {
    /// `None` for a save that asked the keyring for nothing.
    pub(crate) fn of_connection(asked: usize, refused: &[(SecretKind, SecretError)]) -> Option<Self> {
        if asked == 0 {
            return None;
        }
        Some(SecretSaveReport::of_connection(refused).map_or(Self::Kept, Self::Refused))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Unsaved {
    Passwords(usize),
    Passphrase,
    ApiKey,
    AccessToken,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reason {
    Locked,
    NoKeyring,
    Refused,
}

impl Reason {
    fn of(error: &SecretError) -> Self {
        match error {
            SecretError::Locked | SecretError::UnlockDismissed => Self::Locked,
            SecretError::ServiceUnavailable { .. } | SecretError::PortalUnavailable { .. } => Self::NoKeyring,
            SecretError::Backend { .. } | SecretError::InvalidEncoding => Self::Refused,
        }
    }
}

impl SecretSaveReport {
    /// `None` when the keyring kept every secret of the connection.
    pub(crate) fn of_connection(refused: &[(SecretKind, SecretError)]) -> Option<Self> {
        let (_, error) = refused.first()?;
        let unsaved = match refused {
            [(SecretKind::SshPassphrase, _)] => Unsaved::Passphrase,
            _ => Unsaved::Passwords(refused.len()),
        };
        Some(Self {
            unsaved,
            error: error.clone(),
        })
    }

    pub(crate) fn api_key(error: SecretError) -> Self {
        Self {
            unsaved: Unsaved::ApiKey,
            error,
        }
    }

    pub(crate) fn access_token(error: SecretError) -> Self {
        Self {
            unsaved: Unsaved::AccessToken,
            error,
        }
    }

    /// The toast's one line: what was not saved, and why.
    pub(crate) fn title(&self) -> String {
        match (Reason::of(&self.error), self.unsaved) {
            (Reason::Locked, Unsaved::Passwords(n)) => ngettext(
                "The keyring is locked, so the password was not saved",
                "The keyring is locked, so the passwords were not saved",
                n,
            ),
            (Reason::Locked, Unsaved::Passphrase) => gettext("The keyring is locked, so the passphrase was not saved"),
            (Reason::Locked, Unsaved::ApiKey) => gettext("The keyring is locked, so the API key was not saved"),
            (Reason::Locked, Unsaved::AccessToken) => {
                gettext("The keyring is locked, so the new access token was not saved")
            }
            (Reason::NoKeyring, Unsaved::Passwords(n)) => ngettext(
                "No keyring is available, so the password was not saved",
                "No keyring is available, so the passwords were not saved",
                n,
            ),
            (Reason::NoKeyring, Unsaved::Passphrase) => {
                gettext("No keyring is available, so the passphrase was not saved")
            }
            (Reason::NoKeyring, Unsaved::ApiKey) => gettext("No keyring is available, so the API key was not saved"),
            (Reason::NoKeyring, Unsaved::AccessToken) => {
                gettext("No keyring is available, so the new access token was not saved")
            }
            (Reason::Refused, Unsaved::Passwords(n)) => ngettext(
                "The keyring did not save the password",
                "The keyring did not save the passwords",
                n,
            ),
            (Reason::Refused, Unsaved::Passphrase) => gettext("The keyring did not save the passphrase"),
            (Reason::Refused, Unsaved::ApiKey) => gettext("The keyring did not save the API key"),
            (Reason::Refused, Unsaved::AccessToken) => gettext("The keyring did not save the new access token"),
        }
    }

    pub(crate) fn heading(&self) -> String {
        match self.unsaved {
            Unsaved::Passwords(n) => ngettext("Password Not Saved", "Passwords Not Saved", n),
            Unsaved::Passphrase => gettext("Passphrase Not Saved"),
            Unsaved::ApiKey => gettext("API Key Not Saved"),
            Unsaved::AccessToken => gettext("Access Token Not Saved"),
        }
    }

    /// Why, what follows from it, and the way out.
    pub(crate) fn body(&self) -> String {
        let said = match self.consequence() {
            Some(consequence) => format!("{} {consequence}", self.reason()),
            None => self.reason(),
        };
        match self.remedy() {
            Some(remedy) => format!("{said}\n\n{remedy}"),
            None => said,
        }
    }

    fn reason(&self) -> String {
        match &self.error {
            SecretError::Locked => gettext("The keyring is locked."),
            SecretError::UnlockDismissed => {
                gettext("The keyring stayed locked because the unlock prompt was dismissed.")
            }
            SecretError::ServiceUnavailable { .. } => gettext("No keyring is running."),
            SecretError::PortalUnavailable { .. } => gettext("The secret portal is unavailable."),
            SecretError::Backend {
                service_message: Some(message),
                ..
            } => gettext_f("The keyring reported: {detail}", &[("detail", message)]),
            SecretError::Backend { .. } | SecretError::InvalidEncoding => {
                gettext("The keyring failed without giving a reason.")
            }
        }
    }

    fn consequence(&self) -> Option<String> {
        let asked_again = |n: usize| {
            ngettext(
                "TablePro asks for it at the next connect.",
                "TablePro asks for them at the next connect.",
                n,
            )
        };
        match self.unsaved {
            Unsaved::Passwords(n) => Some(asked_again(n)),
            Unsaved::Passphrase => Some(asked_again(1)),
            Unsaved::ApiKey => None,
            Unsaved::AccessToken => Some(gettext("Clients keep using the current token.")),
        }
    }

    fn remedy(&self) -> Option<String> {
        match Reason::of(&self.error) {
            Reason::Locked => Some(keyring_locked_recovery()),
            Reason::NoKeyring => Some(match self.error {
                SecretError::PortalUnavailable { .. } => {
                    gettext("Install xdg-desktop-portal and your desktop’s keyring, then log out and in.")
                }
                _ => gettext("Install or start a keyring, such as GNOME Keyring or KWallet, then log out and in."),
            }),
            Reason::Refused => None,
        }
    }
}

/// The way out of a locked keyring, shared by every surface that reads or saves a secret. The
/// Secret portal answers a missing default keyring the same way as a locked one, so the advice
/// covers both (linux/docs/troubleshooting.md, Flatpak connections).
pub(crate) fn keyring_locked_recovery() -> String {
    gettext(
        "Unlock the keyring, accept its prompt and try again. With automatic login, GNOME may have no default keyring yet: create one in Passwords and Keys and make it the default.",
    )
}

/// A session's credentials whose saves are reported. A secret typed at a reconnect prompt is
/// stored by the session's health monitor, which only logs a refusal.
pub(crate) struct ReportingCredentials {
    inner: Arc<dyn CredentialSource>,
    report: Arc<dyn Fn(SecretSaveOutcome) + Send + Sync>,
}

impl ReportingCredentials {
    pub(crate) fn new(
        inner: Arc<dyn CredentialSource>,
        report: impl Fn(SecretSaveOutcome) + Send + Sync + 'static,
    ) -> Self {
        Self {
            inner,
            report: Arc::new(report),
        }
    }
}

impl CredentialSource for ReportingCredentials {
    fn refresh(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        demand: CredentialDemand,
    ) -> BoxFuture<'static, Result<RefreshedRequest, ConnectError>> {
        self.inner.refresh(request, interaction, demand)
    }

    fn remember(&self, saves: Vec<SecretSave>) -> BoxFuture<'static, Vec<(SecretKind, SecretError)>> {
        let asked = saves.len();
        let stored = self.inner.remember(saves);
        let report = self.report.clone();
        Box::pin(async move {
            let refused = stored.await;
            if let Some(outcome) = SecretSaveOutcome::of_connection(asked, &refused) {
                report(outcome);
            }
            refused
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use secrecy::SecretString;
    use tablepro_core::credentials::SecretVault;
    use tablepro_storage::KeyringCredentials;
    use tablepro_test_support::FakeSecretVault;

    use super::*;

    fn connection(refused: &[(SecretKind, SecretError)]) -> SecretSaveReport {
        SecretSaveReport::of_connection(refused).expect("a refusal")
    }

    #[test]
    fn a_locked_keyring_says_so_and_how_to_make_a_default_one() {
        let report = connection(&[(SecretKind::DatabasePassword, SecretError::Locked)]);

        assert_eq!(report.title(), "The keyring is locked, so the password was not saved");
        assert_eq!(report.heading(), "Password Not Saved");
        assert_eq!(
            report.body(),
            "The keyring is locked. TablePro asks for it at the next connect.\n\n\
             Unlock the keyring, accept its prompt and try again. With automatic login, GNOME may have no \
             default keyring yet: create one in Passwords and Keys and make it the default."
        );
    }

    #[test]
    fn one_save_is_one_report_that_names_what_it_lost() {
        let both = connection(&[
            (SecretKind::DatabasePassword, SecretError::UnlockDismissed),
            (SecretKind::SshPassword, SecretError::UnlockDismissed),
        ]);
        let passphrase = connection(&[(SecretKind::SshPassphrase, SecretError::Locked)]);

        assert_eq!(both.title(), "The keyring is locked, so the passwords were not saved");
        assert!(
            both.body().starts_with(
                "The keyring stayed locked because the unlock prompt was dismissed. TablePro asks for them"
            )
        );
        assert_eq!(
            passphrase.title(),
            "The keyring is locked, so the passphrase was not saved"
        );
        assert_eq!(passphrase.heading(), "Passphrase Not Saved");
        assert_eq!(SecretSaveReport::of_connection(&[]), None);
    }

    #[test]
    fn each_cause_has_its_own_words_and_its_own_way_out() {
        let portal = connection(&[(
            SecretKind::DatabasePassword,
            SecretError::PortalUnavailable {
                detail: "no portal".to_owned(),
            },
        )]);
        let service = SecretSaveReport::api_key(SecretError::ServiceUnavailable { detail: String::new() });
        let reply = SecretSaveReport::access_token(SecretError::Backend {
            detail: "DBus error org.freedesktop.Secret.Error.NoSuchObject".to_owned(),
            service_message: Some("No such collection".to_owned()),
        });

        assert_eq!(portal.title(), "No keyring is available, so the password was not saved");
        assert!(
            portal
                .body()
                .ends_with("Install xdg-desktop-portal and your desktop’s keyring, then log out and in.")
        );
        assert_eq!(service.title(), "No keyring is available, so the API key was not saved");
        assert_eq!(
            service.body(),
            "No keyring is running.\n\nInstall or start a keyring, such as GNOME Keyring or KWallet, then log out and in."
        );
        assert_eq!(reply.title(), "The keyring did not save the new access token");
        assert_eq!(
            reply.body(),
            "The keyring reported: No such collection Clients keep using the current token."
        );
        assert!(!reply.body().contains("DBus"), "{}", reply.body());
    }

    #[tokio::test]
    async fn a_reconnect_reports_what_came_of_the_secrets_it_kept() {
        let vault = Arc::new(FakeSecretVault::new());
        vault.fail_store(SecretKind::DatabasePassword, SecretError::Locked);
        let reported = Arc::new(Mutex::new(Vec::new()));
        let sink = reported.clone();
        let saved = crate::test_support::saved_connection("Prod");
        let keyring: Arc<dyn CredentialSource> = Arc::new(KeyringCredentials::for_saved(vault.clone(), &saved));
        let credentials = ReportingCredentials::new(keyring, move |report| sink.lock().unwrap().push(report));
        let typed = |kind| SecretSave {
            kind,
            secret: SecretString::from("typed"),
            label: "label".to_owned(),
        };

        let nothing = credentials.remember(Vec::new()).await;
        let kept = credentials.remember(vec![typed(SecretKind::SshPassword)]).await;
        let refused = credentials.remember(vec![typed(SecretKind::DatabasePassword)]).await;

        assert!(nothing.is_empty() && kept.is_empty());
        assert_eq!(refused, vec![(SecretKind::DatabasePassword, SecretError::Locked)]);
        assert_eq!(
            *reported.lock().unwrap(),
            vec![
                SecretSaveOutcome::Kept,
                SecretSaveOutcome::Refused(connection(&[(SecretKind::DatabasePassword, SecretError::Locked)])),
            ]
        );
        assert!(vault.load(saved.id, SecretKind::SshPassword).await.unwrap().is_stored());
    }
}
