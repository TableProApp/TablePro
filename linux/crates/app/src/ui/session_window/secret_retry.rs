//! A failed connect whose secret the server refused offers to take it
//! again, and the retry asks for it rather than reading the keyring's
//! copy, which is the one that was just refused.

use gtk4::subclass::prelude::*;
use tablepro_core::credentials::SecretKind;
use tablepro_core::{AuthMode, DriverError, SshFailure, TransportError};
use tablepro_session::{ConnectError, ConnectSource};
use tablepro_storage::{CredentialDemand, SavedConnection, SavedSshAuth};

use super::SessionWindow;
use super::session_page::SessionPage;

impl SessionWindow {
    /// The failed page's Enter Password: connect again, asking for
    /// `kind` whatever the keyring holds. A stale activation, from a
    /// page that has moved on, does nothing.
    pub(super) fn on_retry_with_new_secret(&self, kind: SecretKind) {
        let imp = self.imp();
        let offered = self.page_is(|page| {
            matches!(
                page,
                SessionPage::ConnectFailed {
                    source: ConnectSource::Saved(_),
                    failure,
                    ..
                } if failure.reenter == Some(kind)
            )
        });
        if !offered {
            return;
        }
        let SessionPage::ConnectFailed {
            claim,
            source: ConnectSource::Saved(saved),
            ..
        } = imp.page.replace(SessionPage::Picker)
        else {
            return;
        };
        self.reconnect_saved(claim, *saved, CredentialDemand::reenter(kind));
    }
}

/// The secret of `saved` that `error` says the server refused, when the
/// user can type it in TablePro.
///
/// A key's passphrase counts only when the keyring holds it: without
/// one, ssh asks for it at each connect anyway. A keyring that could
/// not be read refused nothing, so it is not offered: the retry's
/// prompt would say the server turned the secret down.
pub(super) fn refused_secret(error: &ConnectError, saved: &SavedConnection) -> Option<SecretKind> {
    match error {
        ConnectError::Driver(DriverError::Auth { .. }) => {
            (saved.auth_mode == AuthMode::Password).then_some(SecretKind::DatabasePassword)
        }
        ConnectError::Driver(DriverError::Transport(TransportError::Ssh(SshFailure::AuthenticationRejected {
            ..
        }))) => match saved.ssh.as_ref().map(|ssh| &ssh.auth)? {
            SavedSshAuth::Password => Some(SecretKind::SshPassword),
            SavedSshAuth::PrivateKey {
                has_passphrase: true, ..
            } => Some(SecretKind::SshPassphrase),
            SavedSshAuth::PrivateKey { .. } | SavedSshAuth::Agent | SavedSshAuth::KeyboardInteractive => None,
        },
        _ => None,
    }
}

/// The label of the failed page's button for typing `kind` again.
pub(super) fn reenter_label(kind: SecretKind) -> String {
    match kind {
        SecretKind::DatabasePassword => crate::i18n::gettext("Enter Password…"),
        SecretKind::SshPassword => crate::i18n::gettext("Enter SSH Password…"),
        SecretKind::SshPassphrase => crate::i18n::gettext("Enter Passphrase…"),
    }
}

/// The kind an action target names, as `SecretKind::attribute` spells
/// it.
pub(super) fn secret_kind_named(name: &str) -> Option<SecretKind> {
    SecretKind::ALL.into_iter().find(|kind| kind.attribute() == name)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::TlsConfig;
    use tablepro_storage::{KeyringError, SavedSshConfig};
    use uuid::Uuid;

    use super::*;

    fn saved(auth_mode: AuthMode, ssh: Option<SavedSshAuth>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Prod".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.example.com".to_owned(),
            port: 5432,
            database: "shop".to_owned(),
            username: "app".to_owned(),
            tls: TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode,
            ssh: ssh.map(|auth| SavedSshConfig {
                host: "bastion.example.com".to_owned(),
                port: None,
                username: Some("deploy".to_owned()),
                jump_hosts: Vec::new(),
                auth,
            }),
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn ssh_rejected() -> ConnectError {
        ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
            SshFailure::AuthenticationRejected {
                user: "deploy".to_owned(),
                host: "bastion.example.com".to_owned(),
                methods: vec!["password".to_owned()],
            },
        )))
    }

    #[test]
    fn a_refused_database_login_offers_the_database_password() {
        let refused = ConnectError::Driver(DriverError::auth(None));

        assert_eq!(
            refused_secret(&refused, &saved(AuthMode::Password, None)),
            Some(SecretKind::DatabasePassword)
        );
        assert_eq!(
            refused_secret(&refused, &saved(AuthMode::Kerberos, None)),
            None,
            "a Kerberos login has no password to type"
        );
    }

    #[test]
    fn a_refused_ssh_login_offers_the_secret_the_keyring_holds_for_it() {
        let password = saved(AuthMode::Password, Some(SavedSshAuth::Password));
        let stored_passphrase = saved(
            AuthMode::Password,
            Some(SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: true,
            }),
        );
        let asked_by_ssh = saved(
            AuthMode::Password,
            Some(SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: false,
            }),
        );
        let agent = saved(AuthMode::Password, Some(SavedSshAuth::Agent));

        assert_eq!(
            refused_secret(&ssh_rejected(), &password),
            Some(SecretKind::SshPassword)
        );
        assert_eq!(
            refused_secret(&ssh_rejected(), &stored_passphrase),
            Some(SecretKind::SshPassphrase)
        );
        assert_eq!(refused_secret(&ssh_rejected(), &asked_by_ssh), None);
        assert_eq!(refused_secret(&ssh_rejected(), &agent), None);
    }

    #[test]
    fn too_many_failed_attempts_offers_no_secret() {
        let too_many = ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
            SshFailure::TooManyAuthenticationFailures {
                host: "bastion.example.com".to_owned(),
            },
        )));
        let auths = [
            SavedSshAuth::Password,
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: true,
            },
            SavedSshAuth::Agent,
        ];

        for auth in auths {
            let saved = saved(AuthMode::Password, Some(auth));
            assert_eq!(refused_secret(&too_many, &saved), None, "{:?}", saved.ssh);
        }
    }

    #[test]
    fn an_unreadable_keyring_offers_nothing_to_type_again() {
        let unreadable = ConnectError::Keyring(KeyringError::Secret {
            kind: SecretKind::SshPassword,
            error: tablepro_core::credentials::SecretError::Backend {
                detail: "broken".to_owned(),
                service_message: None,
            },
        });

        assert_eq!(
            refused_secret(&unreadable, &saved(AuthMode::Password, Some(SavedSshAuth::Password))),
            None,
            "a keyring read error was offered as a refused password"
        );
    }

    #[test]
    fn failures_a_secret_cannot_fix_offer_nothing() {
        let lost = ConnectError::Driver(DriverError::ConnectionLost {
            during: tablepro_core::LossPhase::Connect,
        });

        assert_eq!(refused_secret(&lost, &saved(AuthMode::Password, None)), None);
        let pg_hba = ConnectError::Driver(DriverError::LoginRefused(Box::new(
            tablepro_core::ServerDiagnostics::new(None, "no pg_hba.conf entry for host"),
        )));
        assert_eq!(
            refused_secret(&pg_hba, &saved(AuthMode::Password, None)),
            None,
            "a login the server's rules refused offered a new password"
        );
        assert_eq!(
            refused_secret(&ConnectError::Cancelled, &saved(AuthMode::Password, None)),
            None
        );
    }

    #[test]
    fn every_kind_round_trips_through_its_action_target() {
        for kind in SecretKind::ALL {
            assert_eq!(secret_kind_named(kind.attribute()), Some(kind));
        }
        assert_eq!(secret_kind_named("password"), None);
    }
}

#[cfg(test)]
mod window_tests {
    use gtk4::glib;
    use gtk4::prelude::*;
    use libadwaita as adw;
    use libadwaita::prelude::*;
    use secrecy::{ExposeSecret, SecretString};
    use tablepro_core::Credentials;
    use tablepro_core::credentials::{SecretError, SecretVault};
    use tablepro_session::RequestTarget;
    use tablepro_session::fakes::{EstablishCall, FakeCredentialSource};
    use tablepro_test_support::Call;

    use super::*;
    use crate::test_support::{descendants, finish_on_main, wait_until};
    use crate::ui::session_window::SessionWindowInput;
    use crate::ui::session_window::connect_failed_page::ConnectFailedPage;
    use crate::ui::session_window::tests::{Script, TestWindow, WAIT, refused};

    fn open_prompt(window: &SessionWindow) -> Option<adw::AlertDialog> {
        window
            .dialogs()
            .iter::<glib::Object>()
            .filter_map(|item| item.ok()?.downcast::<adw::AlertDialog>().ok())
            .next()
    }

    /// Type `secret` into the credential prompt the window shows and
    /// press its Connect, as the user would. Returns what the prompt
    /// said.
    fn answer_prompt(window: &SessionWindow, secret: &str, remember: bool) -> String {
        let mut shown = None;
        wait_until(WAIT, || {
            shown = open_prompt(window);
            shown.is_some()
        })
        .expect("a credential prompt");
        let alert = shown.expect("the prompt");
        let body = alert.body().to_string();
        let rows = alert.extra_child().expect("the prompt's rows");
        for row in descendants(&rows) {
            if let Some(entry) = row.downcast_ref::<adw::PasswordEntryRow>() {
                entry.set_text(secret);
            } else if let Some(switch) = row.downcast_ref::<adw::SwitchRow>() {
                switch.set_active(remember);
            }
        }
        assert!(
            crate::workspace::answer(window, "accept"),
            "the prompt has no Connect button"
        );
        body
    }

    fn password_of(call: &EstablishCall) -> Option<String> {
        match &call.request.target {
            RequestTarget::Network {
                credentials: Credentials::Password { password, .. },
                ..
            } => Some(password.expose_secret().to_owned()),
            _ => None,
        }
    }

    fn failed_page(window: &SessionWindow) -> ConnectFailedPage {
        window
            .content()
            .and_then(|child| child.downcast::<ConnectFailedPage>().ok())
            .expect("the failed page")
    }

    fn toasts(window: &SessionWindow) -> Vec<String> {
        window
            .imp()
            .toasts
            .borrow()
            .iter()
            .filter_map(|toast| toast.title().map(|title| title.to_string()))
            .collect()
    }

    fn password_loads(test: &TestWindow) -> usize {
        test.vault
            .calls()
            .iter()
            .filter(|call| **call == Call::Load(test.saved.id, SecretKind::DatabasePassword))
            .count()
    }

    #[gtk4::test]
    fn a_connect_the_user_starts_may_ask_for_what_is_missing() {
        let credentials = FakeCredentialSource::new();
        let test = TestWindow::with_script(
            "Attended",
            Script {
                credentials: Some(credentials.clone()),
                ..Script::default()
            },
        );

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");

        assert_eq!(credentials.refreshes(), [true]);
        assert!(test.connector.calls().iter().all(|call| call.attended));
    }

    #[gtk4::test]
    fn enter_password_asks_again_and_skips_the_refused_secret() {
        let test = TestWindow::with_script(
            "EnterPassword",
            Script {
                establish: vec![refused()],
                network: true,
                ..Script::default()
            },
        );
        let (vault, id) = (test.vault.clone(), test.saved.id);
        finish_on_main(WAIT, async move {
            vault
                .store(id, SecretKind::DatabasePassword, &SecretString::from("old"), "label")
                .await
        })
        .expect("the store to end")
        .expect("the old password stored");
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        let button = failed_page(&test.window)
            .reenter_button()
            .expect("an Enter Password button");
        assert_eq!(button.label().as_deref(), Some("Enter Password…"));
        assert!(
            test.window
                .lookup_action("retry-with-new-secret")
                .is_some_and(|action| action.is_enabled())
        );
        let loads = password_loads(&test);

        button.emit_clicked();
        let asked = answer_prompt(&test.window, "new", true);
        test.wait_for_page("workspace");

        assert!(asked.contains("refused"), "{asked}");
        assert_eq!(password_loads(&test), loads, "the refused password was read again");
        let calls = test.connector.calls();
        assert_eq!(password_of(&calls[0]).as_deref(), Some("old"));
        assert_eq!(password_of(&calls[1]).as_deref(), Some("new"));
        assert_eq!(
            test.vault.stored_secret(id, SecretKind::DatabasePassword).as_deref(),
            Some("new"),
            "the password that worked was not remembered"
        );
    }

    #[gtk4::test]
    fn a_reconnect_uses_the_password_typed_without_remember() {
        let test = TestWindow::with_script(
            "ReenterReconnect",
            Script {
                establish: vec![refused()],
                network: true,
                ..Script::default()
            },
        );
        let (vault, id) = (test.vault.clone(), test.saved.id);
        finish_on_main(WAIT, async move {
            vault
                .store(id, SecretKind::DatabasePassword, &SecretString::from("old"), "label")
                .await
        })
        .expect("the store to end")
        .expect("the old password stored");
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");
        failed_page(&test.window)
            .reenter_button()
            .expect("an Enter Password button")
            .emit_clicked();
        answer_prompt(&test.window, "new", false);
        test.wait_for_page("workspace");

        WidgetExt::activate_action(&test.window, "win.reconnect", None).expect("win.reconnect");
        wait_until(WAIT, || test.connector.calls().len() == 3).expect("the reconnect");

        let calls = test.connector.calls();
        assert_eq!(
            password_of(&calls[2]).as_deref(),
            Some("new"),
            "the reconnect logged in with the refused password"
        );
        assert!(open_prompt(&test.window).is_none(), "the reconnect asked again");
        assert_eq!(
            test.vault.stored_secret(id, SecretKind::DatabasePassword).as_deref(),
            Some("old"),
            "a password typed without Remember was kept"
        );
    }

    #[gtk4::test]
    fn a_failure_no_password_fixes_offers_no_enter_password() {
        let lost = tablepro_session::fakes::FakeEstablish::Fail(ConnectError::Driver(DriverError::ConnectionLost {
            during: tablepro_core::LossPhase::Connect,
        }));
        let test = TestWindow::with_script(
            "NoEnterPassword",
            Script {
                establish: vec![lost],
                network: true,
                ..Script::default()
            },
        );
        let (vault, id) = (test.vault.clone(), test.saved.id);
        finish_on_main(WAIT, async move {
            vault
                .store(id, SecretKind::DatabasePassword, &SecretString::from("old"), "label")
                .await
        })
        .expect("the store to end")
        .expect("the password stored");

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("connect-failed");

        assert!(failed_page(&test.window).reenter_button().is_none());
        assert!(
            test.window
                .lookup_action("retry-with-new-secret")
                .is_some_and(|action| !action.is_enabled())
        );
    }

    #[gtk4::test]
    fn adoption_stores_remembered_secret_and_toasts_failure() {
        let test = TestWindow::with_script(
            "RememberRefused",
            Script {
                network: true,
                ..Script::default()
            },
        );
        test.vault.fail_store(SecretKind::DatabasePassword, SecretError::Locked);

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        let asked = answer_prompt(&test.window, "typed", true);
        test.wait_for_page("workspace");

        assert!(asked.contains("No password is saved"), "{asked}");
        assert_eq!(password_of(&test.connector.calls()[0]).as_deref(), Some("typed"));
        assert!(
            test.vault
                .calls()
                .contains(&Call::Store(test.saved.id, SecretKind::DatabasePassword)),
            "the typed password was not offered to the keyring"
        );
        wait_until(WAIT, || {
            toasts(&test.window)
                .iter()
                .any(|toast| toast.starts_with("The keyring stayed locked, so the password was not saved"))
        })
        .expect("the refused save to be reported");
    }
}
