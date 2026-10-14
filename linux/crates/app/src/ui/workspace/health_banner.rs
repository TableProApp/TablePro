//! The banner over the tabs while the session needs attention.

use tablepro_session::{FailureCause, SessionHealth};

use super::WorkspaceModel;

impl WorkspaceModel {
    /// GNOME apps keep banners for states the user can act on, so the
    /// banner shows only while the session is not online. Its Retry is
    /// `win.reconnect`.
    pub(super) fn refresh_health_banner(&self, health: &SessionHealth) {
        match health_banner_text(health) {
            Some(title) => {
                self.reconnect_banner.set_title(&title);
                self.reconnect_banner.set_revealed(true);
            }
            None => self.reconnect_banner.set_revealed(false),
        }
    }
}

/// The banner's sentence for a session that needs attention, `None`
/// while it is online.
fn health_banner_text(health: &SessionHealth) -> Option<String> {
    match health {
        SessionHealth::Online => None,
        SessionHealth::Reconnecting { attempt } => Some(crate::i18n::gettext_f(
            "Connection lost. Reconnecting (attempt {n}).",
            &[("n", &attempt.to_string())],
        )),
        SessionHealth::Offline => Some(crate::i18n::gettext(
            "The server cannot be reached. TablePro will keep checking.",
        )),
        SessionHealth::Failed { cause } => Some(failed_banner_text(*cause)),
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
    use super::*;

    #[test]
    fn the_banner_shows_only_when_the_session_needs_attention() {
        assert_eq!(health_banner_text(&SessionHealth::Online), None);
        let reconnecting = health_banner_text(&SessionHealth::Reconnecting { attempt: 3 }).expect("a banner");
        assert!(reconnecting.contains('3'), "{reconnecting}");
        assert!(health_banner_text(&SessionHealth::Offline).is_some());
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
            .map(|cause| health_banner_text(&SessionHealth::Failed { cause }).expect("a banner"))
            .collect();

        assert_eq!(texts.len(), causes.len());
    }
}
