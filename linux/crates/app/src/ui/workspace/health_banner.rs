//! The banner over the tabs while the session needs attention.

use gtk4::prelude::*;
use tablepro_core::{DriverError, SshFailure, TransportError};
use tablepro_session::{FailureCause, MonitorSignal, ReviewedHostKey, SessionHealth};
use tablepro_ssh::ForgetHostKeyError;

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::{DeliverInput, spawn_and_deliver};
use crate::ui::host_key_failure::{HostKeyFailure, HostKeyFailureKind};
use crate::ui::host_key_review::{HostKeyReviewOutcome, review_host_key};

pub(super) const REVIEW_HOST_KEY: &str = "review-host-key";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BannerButton {
    Retry,
    ReviewKey,
}

impl WorkspaceModel {
    /// GNOME apps keep banners for states the user can act on, so the
    /// banner shows only while the session is not online. A host key ssh
    /// refused offers a review instead of a retry, which would only be
    /// refused again.
    pub(super) fn refresh_health_banner(&self, health: &SessionHealth) {
        let review = self.host_key_to_review(health);
        if let Some(window) = self.window() {
            super::workspace_actions::set_enabled(&window, REVIEW_HOST_KEY, review.is_some());
        }
        let title = self
            .rejection_text(health, review.as_ref())
            .or_else(|| health_banner_text(health, review.as_ref()));
        let Some(title) = title else {
            self.reconnect_banner.set_revealed(false);
            return;
        };
        let (label, action) = match banner_button(review.as_ref()) {
            BannerButton::Retry => (crate::i18n::gettext("Retry"), "win.reconnect".to_owned()),
            BannerButton::ReviewKey => (crate::i18n::gettext("Review Key…"), format!("win.{REVIEW_HOST_KEY}")),
        };
        let news = !self.reconnect_banner.is_revealed() || self.reconnect_banner.title() != title;
        self.reconnect_banner.set_title(&title);
        self.reconnect_banner.set_button_label(Some(&label));
        self.reconnect_banner.set_action_name(Some(&action));
        self.reconnect_banner.set_revealed(true);
        // The focus stays in the grid or the editor, under a banner no
        // screen reader reads by itself.
        if news {
            crate::ui::a11y::announce(
                &self.reconnect_banner,
                &title,
                gtk4::AccessibleAnnouncementPriority::High,
            );
        }
    }

    /// What the server or the settings said when the session parked,
    /// which says more than the cause's own sentence. A host key keeps
    /// its own banner and review.
    fn rejection_text(&self, health: &SessionHealth, review: Option<&HostKeyFailure>) -> Option<String> {
        let SessionHealth::Failed { cause } = health else {
            return None;
        };
        if review.is_some() || is_host_key(*cause) {
            return None;
        }
        let rejection = self.context.active.get()?.last_rejection()?;
        Some(crate::ui::error_text::connect_error_message(&rejection))
    }

    /// The host key the session is parked on, read from the error that
    /// parked it.
    fn host_key_to_review(&self, health: &SessionHealth) -> Option<HostKeyFailure> {
        let SessionHealth::Failed { cause } = health else {
            return None;
        };
        if !is_host_key(*cause) {
            return None;
        }
        let rejection = self.context.active.get()?.last_rejection()?;
        HostKeyFailure::from_connect_error(&rejection)
    }

    pub(super) fn on_review_host_key(&mut self) {
        if self.reviewing_host_key {
            return;
        }
        let Some(session) = self.context.active.get() else {
            return;
        };
        let health = session.health().borrow().clone();
        let Some(failure) = self.host_key_to_review(&health) else {
            return;
        };
        let Some(parent) = self.dialog_parent() else {
            return;
        };
        self.reviewing_host_key = true;
        let input = self.input.clone();
        gtk4::glib::spawn_future_local(async move {
            let outcome = review_host_key(&parent, &failure).await;
            input.deliver(WorkspaceInput::HostKeyReviewed { failure, outcome });
        });
    }

    pub(super) fn on_host_key_reviewed(&mut self, failure: HostKeyFailure, outcome: HostKeyReviewOutcome) {
        self.reviewing_host_key = false;
        match outcome {
            HostKeyReviewOutcome::Dismissed => {}
            HostKeyReviewOutcome::Retry => self.retry(),
            HostKeyReviewOutcome::Trust => self.retry_trusting(&failure),
            HostKeyReviewOutcome::Replace => self.reviewing_host_key = self.forget_old_host_key(failure),
        }
    }

    pub(super) fn on_old_host_key_forgotten(&mut self, failure: HostKeyFailure, forgotten: Result<(), String>) {
        self.reviewing_host_key = false;
        match forgotten {
            Ok(()) => self.retry_trusting(&failure),
            Err(detail) => {
                tracing::warn!(host = %failure.host, %detail, "the old SSH host key was not removed");
                let file = match &failure.kind {
                    HostKeyFailureKind::Changed { known_hosts, .. } => known_hosts.display().to_string(),
                    _ => String::new(),
                };
                self.show_toast(&crate::i18n::gettext_f(
                    "The old key for {host} could not be removed from {file}: {detail}",
                    &[("host", &failure.host), ("file", &file), ("detail", &detail)],
                ));
            }
        }
    }

    /// ssh is asked again with the user's answer given: the reviewed key
    /// is accepted, any other is shown to them as on a first connect.
    /// Without a fingerprint there is nothing to answer for them, so ssh
    /// asks.
    fn retry_trusting(&self, failure: &HostKeyFailure) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        match failure.fingerprint.is_empty() {
            true => session.signal(MonitorSignal::RetryNow),
            false => session.retry_trusting_host_key(ReviewedHostKey {
                host: failure.host.clone(),
                fingerprint: failure.fingerprint.clone(),
            }),
        }
    }

    fn retry(&self) {
        if let Some(session) = self.context.active.get() {
            session.signal(MonitorSignal::RetryNow);
        }
    }

    /// ssh never accepts a changed key, so the old one leaves known_hosts
    /// first, with the ssh-keygen command ssh itself suggests, once the
    /// session's own tunnel confirms the host and the file. Returns
    /// whether that was started.
    fn forget_old_host_key(&self, failure: HostKeyFailure) -> bool {
        let HostKeyFailureKind::Changed { known_hosts, .. } = &failure.kind else {
            return false;
        };
        let Some(ssh) = self.ssh.clone() else {
            tracing::warn!("no SSH services to remove the old host key with");
            return false;
        };
        let Some(config) = self
            .context
            .active
            .get()
            .and_then(|session| session.ssh_config().cloned())
        else {
            tracing::warn!("the session has no SSH tunnel to check the changed host key against");
            return false;
        };
        let (host, known_hosts) = (failure.host.clone(), known_hosts.clone());
        let input = self.input.clone();
        drop(spawn_and_deliver(
            &self.tasks,
            async move { tablepro_ssh::forget_changed_host_key(&ssh, &config, &host, &known_hosts).await },
            move |forgotten| {
                let forgotten = match forgotten {
                    Ok(Ok(())) => Ok(()),
                    Ok(Err(error)) => Err(forget_failure_detail(&error)),
                    Err(failure) => Err(crate::ui::error_text::task_failure_message(&failure)),
                };
                input.deliver(WorkspaceInput::OldHostKeyForgotten { failure, forgotten });
            },
        ));
        true
    }
}

fn forget_failure_detail(error: &ForgetHostKeyError) -> String {
    match error {
        ForgetHostKeyError::NotThisConnection { .. } => crate::i18n::gettext("it is not a key this connection uses"),
        ForgetHostKeyError::Ssh(SshFailure::ConfigRejected { detail }) => detail.clone(),
        ForgetHostKeyError::Ssh(other) => {
            crate::ui::error_text::driver_message(&DriverError::Transport(TransportError::Ssh(other.clone())))
        }
    }
}

fn is_host_key(cause: FailureCause) -> bool {
    matches!(
        cause,
        FailureCause::HostKeyUnknown | FailureCause::HostKeyChanged | FailureCause::HostKeyRevoked
    )
}

fn banner_button(review: Option<&HostKeyFailure>) -> BannerButton {
    match review {
        Some(_) => BannerButton::ReviewKey,
        None => BannerButton::Retry,
    }
}

/// The banner's sentence for a session that needs attention, `None`
/// while it is online.
fn health_banner_text(health: &SessionHealth, review: Option<&HostKeyFailure>) -> Option<String> {
    match health {
        SessionHealth::Online => None,
        SessionHealth::Reconnecting { attempt } => Some(crate::i18n::gettext_f(
            "Connection lost. Reconnecting (attempt {n}).",
            &[("n", &attempt.to_string())],
        )),
        SessionHealth::Offline => Some(crate::i18n::gettext("Offline. Waiting for the network.")),
        SessionHealth::Failed { cause } => Some(match review {
            Some(failure) => host_key_banner_text(failure),
            None => failed_banner_text(*cause),
        }),
    }
}

fn host_key_banner_text(failure: &HostKeyFailure) -> String {
    let host = [("host", failure.host.as_str())];
    match failure.kind {
        HostKeyFailureKind::Unknown { .. } => crate::i18n::gettext_f("The SSH host {host} is not trusted yet.", &host),
        HostKeyFailureKind::Changed { .. } => {
            crate::i18n::gettext_f("The SSH host key for {host} does not match.", &host)
        }
        HostKeyFailureKind::Revoked { .. } => crate::i18n::gettext_f("The SSH host key for {host} is revoked.", &host),
    }
}

fn failed_banner_text(cause: FailureCause) -> String {
    match cause {
        FailureCause::Authentication => {
            crate::i18n::gettext("The server refused the login. Retry to enter the password again.")
        }
        FailureCause::Tls => crate::i18n::gettext("The secure connection failed. Check the connection's TLS settings."),
        FailureCause::Configuration => {
            crate::i18n::gettext("The connection settings no longer work. Check them and retry.")
        }
        FailureCause::HostKeyUnknown => crate::i18n::gettext("The SSH server's host key is not trusted yet."),
        FailureCause::HostKeyChanged => crate::i18n::gettext(
            "The SSH server's host key changed. Check with its administrator before connecting again.",
        ),
        FailureCause::HostKeyRevoked => crate::i18n::gettext("The SSH server's host key was revoked."),
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::Duration;

    use gtk4 as gtk;
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    use libadwaita as adw;
    use libadwaita::prelude::*;
    use tablepro_session::ConnectError;
    use tablepro_session::fakes::FakeEstablish;
    use tablepro_ssh::{SshRuntimeCell, SshServices};
    use tablepro_storage::{SavedSshAuth, SavedSshConfig};
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::{descendants, drain_main_context, wait_until};
    use crate::ui::SessionWindowInput;
    use crate::ui::session_window::tests::{Script, TestWindow, WAIT};

    const FINGERPRINT: &str = "SHA256:reviewed";
    const KEY: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g";

    #[test]
    fn the_banner_shows_only_when_the_session_needs_attention() {
        assert_eq!(health_banner_text(&SessionHealth::Online, None), None);
        let reconnecting = health_banner_text(&SessionHealth::Reconnecting { attempt: 3 }, None).expect("a banner");
        assert!(reconnecting.contains('3'), "{reconnecting}");
        assert_eq!(
            health_banner_text(&SessionHealth::Offline, None).as_deref(),
            Some("Offline. Waiting for the network.")
        );
    }

    #[test]
    fn each_parked_cause_has_its_own_banner() {
        let causes = [
            FailureCause::Authentication,
            FailureCause::Tls,
            FailureCause::Configuration,
            FailureCause::HostKeyUnknown,
            FailureCause::HostKeyChanged,
            FailureCause::HostKeyRevoked,
        ];

        let texts: std::collections::HashSet<String> = causes
            .into_iter()
            .map(|cause| health_banner_text(&SessionHealth::Failed { cause }, None).expect("a banner"))
            .collect();

        assert_eq!(texts.len(), causes.len());
    }

    #[test]
    fn a_host_key_banner_names_the_host() {
        let kinds = [
            HostKeyFailureKind::Unknown { trust_allowed: true },
            HostKeyFailureKind::Changed {
                known_hosts: PathBuf::from("/home/u/.ssh/known_hosts"),
                line: 1,
                trust_allowed: true,
            },
            HostKeyFailureKind::Revoked {
                detail: "revoked".to_owned(),
            },
        ];
        for kind in kinds {
            let failure = HostKeyFailure {
                host: "bastion".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: FINGERPRINT.to_owned(),
                kind,
            };
            let parked = SessionHealth::Failed {
                cause: FailureCause::HostKeyUnknown,
            };

            let text = health_banner_text(&parked, Some(&failure)).expect("a banner");

            assert!(text.contains("bastion"), "{text}");
            assert_eq!(banner_button(Some(&failure)), BannerButton::ReviewKey);
        }
        assert_eq!(banner_button(None), BannerButton::Retry);
    }

    fn healthy() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::ok(()));
        script.list_schemas.always(FakeReply::ok(Vec::new()));
        script.list_objects.always(FakeReply::ok(Vec::new()));
        script
    }

    /// ssh asking about `fingerprint`: an unattended reconnect declines
    /// it, an attended one connects on a yes.
    fn asks(host: &str, fingerprint: &str) -> FakeEstablish {
        FakeEstablish::AskHostKey {
            host: host.to_owned(),
            fingerprint: fingerprint.to_owned(),
            script: healthy(),
        }
    }

    /// A window whose connection dropped and whose first reconnect
    /// parked it; `reconnects` answer that one and the ones after.
    fn parked(name: &str, reconnects: Vec<FakeEstablish>, ssh: Option<SshServices>) -> TestWindow {
        parked_with(name, reconnects, ssh, None)
    }

    fn parked_with(
        name: &str,
        reconnects: Vec<FakeEstablish>,
        ssh: Option<SshServices>,
        tunnel: Option<SavedSshConfig>,
    ) -> TestWindow {
        let mut establish = vec![FakeEstablish::Connect(healthy())];
        establish.extend(reconnects);
        let test = TestWindow::with_script(
            name,
            Script {
                establish,
                ssh,
                tunnel,
                ..Script::default()
            },
        );
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        test.connection().mark_lost();
        wait_until(WAIT, || matches!(health(&test), SessionHealth::Failed { .. })).expect("the session to park");
        test
    }

    fn health(test: &TestWindow) -> SessionHealth {
        test.services
            .sessions
            .session(&test.key())
            .map_or(SessionHealth::Online, |session| session.health().borrow().clone())
    }

    fn banner(test: &TestWindow) -> adw::Banner {
        test.workspace().imp().reconnect_banner.get()
    }

    fn wait_for_button(test: &TestWindow, label: &str) -> adw::Banner {
        let banner = banner(test);
        wait_until(WAIT, || {
            banner.is_revealed() && banner.button_label().as_deref() == Some(label)
        })
        .unwrap_or_else(|_| panic!("the banner never offered {label}"));
        banner
    }

    fn review_enabled(test: &TestWindow) -> bool {
        test.window
            .lookup_action(REVIEW_HOST_KEY)
            .is_some_and(|action| action.is_enabled())
    }

    fn alert(test: &TestWindow) -> Option<adw::AlertDialog> {
        test.window.visible_dialog().and_downcast::<adw::AlertDialog>()
    }

    /// Open the review from the banner and click `response`, the way a
    /// user does.
    fn review_and_answer(test: &TestWindow, response: &str) {
        answer(test, &open_review(test), response);
    }

    fn open_review(test: &TestWindow) -> adw::AlertDialog {
        gtk::prelude::WidgetExt::activate_action(&test.window, &format!("win.{REVIEW_HOST_KEY}"), None)
            .expect("the review action");
        wait_until(WAIT, || alert(test).is_some()).expect("the review dialog");
        alert(test).expect("the review dialog")
    }

    fn answer(test: &TestWindow, dialog: &adw::AlertDialog, response: &str) {
        let label = dialog.response_label(response);
        descendants(dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some(label.as_str()))
            .unwrap_or_else(|| panic!("no {response} button"))
            .emit_clicked();
        wait_until(WAIT, || alert(test).is_none()).expect("the review dialog to close");
    }

    #[gtk4::test]
    fn banner_offers_review_for_host_key_failure() {
        let test = parked("ReviewOffered", vec![asks("bastion", FINGERPRINT)], None);

        let banner = wait_for_button(&test, "Review Key…");

        assert!(banner.title().contains("bastion"), "{}", banner.title());
        assert_eq!(
            banner.action_name().as_deref(),
            Some(format!("win.{REVIEW_HOST_KEY}").as_str())
        );
        assert!(review_enabled(&test));
    }

    #[gtk4::test]
    fn the_banner_is_said_when_it_shows() {
        let test = parked("BannerSaid", vec![asks("bastion", FINGERPRINT)], None);

        let banner = wait_for_button(&test, "Review Key…");

        assert_eq!(
            crate::ui::a11y::announced_in(&banner).last(),
            Some(&(banner.title().to_string(), gtk::AccessibleAnnouncementPriority::High))
        );
    }

    #[gtk4::test]
    fn review_trust_retries_trusting_that_key() {
        let test = parked(
            "ReviewTrust",
            vec![asks("bastion", FINGERPRINT), asks("bastion", FINGERPRINT)],
            None,
        );
        wait_for_button(&test, "Review Key…");

        review_and_answer(&test, "trust");

        wait_until(WAIT, || health(&test) == SessionHealth::Online).expect("the session back online");
        wait_until(WAIT, || !banner(&test).is_revealed()).expect("the banner to go");
        let calls = test.connector.calls();
        assert_eq!(calls.len(), 3);
        assert!(calls[2].attended, "the retry could not ask anything");
        drain_main_context();
        assert!(
            alert(&test).is_none(),
            "ssh's question about the trusted key reached the user"
        );
        assert!(!review_enabled(&test));
    }

    #[gtk4::test]
    fn dismiss_keeps_session_parked() {
        let test = parked("ReviewDismiss", vec![asks("bastion", FINGERPRINT)], None);
        wait_for_button(&test, "Review Key…");

        review_and_answer(&test, "cancel");
        std::thread::sleep(Duration::from_millis(200));
        drain_main_context();

        assert_eq!(
            health(&test),
            SessionHealth::Failed {
                cause: FailureCause::HostKeyUnknown
            }
        );
        assert_eq!(test.connector.calls().len(), 2, "a dismissed review retried");
        assert!(banner(&test).is_revealed());
        assert!(review_enabled(&test));
    }

    #[gtk4::test]
    fn review_retry_reconnects_a_key_fixed_outside_tablepro() {
        let strict = FakeEstablish::Fail(ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
            SshFailure::HostKeyUnknown {
                host: "bastion".to_owned(),
                algorithm: String::new(),
                sha256_fingerprint: String::new(),
                trust_allowed: false,
                declined: false,
            },
        ))));
        let test = parked("ReviewRetry", vec![strict, FakeEstablish::Connect(healthy())], None);
        wait_for_button(&test, "Review Key…");

        review_and_answer(&test, "retry");

        wait_until(WAIT, || health(&test) == SessionHealth::Online).expect("the session back online");
        assert_eq!(test.connector.calls().len(), 3);
    }

    #[gtk4::test]
    fn a_parked_session_says_what_the_server_said() {
        let refused = FakeEstablish::Fail(ConnectError::Driver(DriverError::LoginRefused(Box::new(
            tablepro_core::ServerDiagnostics::new(None, "no pg_hba.conf entry for host"),
        ))));
        let test = parked("RejectionText", vec![refused], None);

        // The banner follows the session's health after it changes, and offers
        // Retry while reconnecting too, so the button alone can come too early.
        let banner = banner(&test);
        wait_until(WAIT, || banner.title().contains("no pg_hba.conf entry"))
            .unwrap_or_else(|_| panic!("the banner said {}", banner.title()));
        assert_eq!(banner.button_label().as_deref(), Some("Retry"));
    }

    #[gtk4::test]
    fn review_action_disabled_for_other_failures() {
        let refused = FakeEstablish::Fail(ConnectError::Driver(DriverError::auth(None)));
        let test = parked("ReviewAuth", vec![refused], None);

        let banner = wait_for_button(&test, "Retry");

        assert_eq!(banner.action_name().as_deref(), Some("win.reconnect"));
        assert!(!review_enabled(&test));
    }

    fn ssh_services(dir: &Path) -> SshServices {
        SshServices {
            runtime: Arc::new(SshRuntimeCell::new(dir.join("runtime"))),
            ssh_program: "ssh".into(),
            ssh_keygen_program: "ssh-keygen".into(),
            askpass_program: dir.join("tablepro-askpass"),
            config_file: None,
        }
    }

    fn changed_key(known_hosts: &Path) -> FakeEstablish {
        changed_key_of("[bastion]:2222", known_hosts, true)
    }

    fn changed_key_of(host: &str, known_hosts: &Path, trust_allowed: bool) -> FakeEstablish {
        FakeEstablish::Fail(ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
            SshFailure::HostKeyChanged {
                host: host.to_owned(),
                algorithm: "ED25519".to_owned(),
                sha256_fingerprint: FINGERPRINT.to_owned(),
                known_hosts: known_hosts.to_owned(),
                line: 1,
                trust_allowed,
            },
        ))))
    }

    /// The tunnel the parked sessions go through. The server is on this
    /// machine, so no reachability check runs.
    fn tunnel() -> SavedSshConfig {
        SavedSshConfig {
            host: "127.0.0.1".to_owned(),
            port: Some(2222),
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        }
    }

    /// SSH services whose `ssh -G` resolves the tunnel's host to
    /// `[bastion]:2222`, looked up in `known_hosts`, the way an
    /// ssh_config with `HostName bastion` would.
    fn resolving_ssh(dir: &Path, known_hosts: &Path) -> SshServices {
        let program = dir.join("ssh");
        let resolved = format!(
            "hostname bastion\\nport 2222\\nhostkeyalias none\\nuserknownhostsfile {} {}\\n",
            known_hosts.display(),
            dir.join("known_hosts2").display()
        );
        tablepro_test_support::write_executable(
            &program,
            format!("#!/bin/sh\nprintf '{resolved}'\n").as_bytes(),
            0o755,
        )
        .unwrap();
        SshServices {
            ssh_program: program,
            ..ssh_services(dir)
        }
    }

    fn has_toast(test: &TestWindow, text: &str) -> bool {
        descendants(&test.workspace())
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .any(|label| label.label().contains(text))
    }

    #[gtk4::test]
    fn replace_removes_the_old_key_and_retries_trusting_the_new_one() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(&known_hosts, format!("[bastion]:2222 {KEY}\nother {KEY}\n")).unwrap();
        let test = parked_with(
            "ReviewReplace",
            vec![changed_key(&known_hosts), asks("[bastion]:2222", FINGERPRINT)],
            Some(resolving_ssh(dir.path(), &known_hosts)),
            Some(tunnel()),
        );
        let banner = wait_for_button(&test, "Review Key…");
        assert!(banner.title().contains("does not match"), "{}", banner.title());

        review_and_answer(&test, "replace");

        wait_until(WAIT, || health(&test) == SessionHealth::Online).expect("the session back online");
        let left = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(!left.contains("[bastion]:2222"), "{left}");
        assert!(left.contains("other "), "{left}");
        assert!(
            alert(&test).is_none(),
            "ssh's question about the reviewed key reached the user"
        );
    }

    #[gtk4::test]
    fn no_second_review_while_the_old_key_is_removed() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(&known_hosts, format!("[bastion]:2222 {KEY}\n")).unwrap();
        let slow_keygen = dir.path().join("slow-ssh-keygen");
        tablepro_test_support::write_executable(&slow_keygen, b"#!/bin/sh\nsleep 1\nexec ssh-keygen \"$@\"\n", 0o755)
            .unwrap();
        let ssh = SshServices {
            ssh_keygen_program: slow_keygen,
            ..resolving_ssh(dir.path(), &known_hosts)
        };
        let test = parked_with(
            "ReviewReplaceBusy",
            vec![changed_key(&known_hosts), asks("[bastion]:2222", FINGERPRINT)],
            Some(ssh),
            Some(tunnel()),
        );
        wait_for_button(&test, "Review Key…");
        review_and_answer(&test, "replace");
        drain_main_context();

        gtk::prelude::WidgetExt::activate_action(&test.window, &format!("win.{REVIEW_HOST_KEY}"), None)
            .expect("the review action");
        std::thread::sleep(Duration::from_millis(200));
        drain_main_context();

        assert!(
            alert(&test).is_none(),
            "a second review opened while ssh-keygen was still running"
        );
        wait_until(WAIT, || health(&test) == SessionHealth::Online).expect("the session back online");
    }

    /// ssh's stderr carries the server's login banner too, so a changed
    /// key it reports for a host or a file this connection does not use
    /// stays where it is.
    #[gtk4::test]
    fn replace_leaves_a_key_this_connection_does_not_use() {
        for (name, host, file) in [
            ("ReviewForgedHost", "other", "known_hosts"),
            ("ReviewForgedFile", "[bastion]:2222", "elsewhere"),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let known_hosts = dir.path().join("known_hosts");
            let reported = dir.path().join(file);
            let keys = format!("[bastion]:2222 {KEY}\nother {KEY}\n");
            for path in [&known_hosts, &dir.path().join("elsewhere")] {
                std::fs::write(path, &keys).unwrap();
            }
            let test = parked_with(
                name,
                vec![changed_key_of(host, &reported, true)],
                Some(resolving_ssh(dir.path(), &known_hosts)),
                Some(tunnel()),
            );
            wait_for_button(&test, "Review Key…");

            review_and_answer(&test, "replace");

            wait_until(WAIT, || has_toast(&test, "it is not a key this connection uses"))
                .unwrap_or_else(|_| panic!("{name}: the forged report was not refused"));
            assert_eq!(std::fs::read_to_string(&reported).unwrap(), keys, "{name}");
            assert_eq!(test.connector.calls().len(), 2, "{name}: a refused replace retried");
        }
    }

    /// Under StrictHostKeyChecking yes ssh would refuse the new key once
    /// the old one is gone, so the review offers no replace and the old
    /// key stays.
    #[gtk4::test]
    fn review_offers_no_replace_when_the_configuration_takes_only_known_keys() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        let keys = format!("[bastion]:2222 {KEY}\n");
        std::fs::write(&known_hosts, &keys).unwrap();
        let test = parked_with(
            "ReviewStrictChanged",
            vec![
                changed_key_of("[bastion]:2222", &known_hosts, false),
                FakeEstablish::Connect(healthy()),
            ],
            Some(resolving_ssh(dir.path(), &known_hosts)),
            Some(tunnel()),
        );
        wait_for_button(&test, "Review Key…");

        let dialog = open_review(&test);

        assert!(!dialog.has_response("replace"), "a replace was offered");
        assert!(dialog.has_response("retry"));
        assert!(
            dialog.body().contains(&known_hosts.display().to_string()),
            "{}",
            dialog.body()
        );
        answer(&test, &dialog, "retry");
        wait_until(WAIT, || health(&test) == SessionHealth::Online).expect("the session back online");
        assert_eq!(std::fs::read_to_string(&known_hosts).unwrap(), keys);
    }

    #[gtk4::test]
    fn trust_answers_only_for_the_host_it_was_reviewed_for() {
        let test = parked(
            "ReviewTrustHost",
            vec![asks("bastion", FINGERPRINT), asks("jump", FINGERPRINT)],
            None,
        );
        wait_for_button(&test, "Review Key…");

        review_and_answer(&test, "trust");

        wait_until(WAIT, || alert(&test).is_some()).expect("ssh's question about another host to reach the user");
        if let Some(question) = alert(&test) {
            question.force_close();
        }
    }
}
