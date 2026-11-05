use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::TableProApplication;
use crate::i18n::gettext;
use crate::ui::LaunchNotice;

const SHARE: &str = "share";
const DONT_SHARE: &str = "dont-share";
// Escape and closing the window choose nothing, so the next launch asks again.
const UNDECIDED: &str = "close";

impl TableProApplication {
    // From startup: until the user chooses, each launch offers the choice once, in a toast.
    pub(super) fn ask_about_usage_data(&self) {
        let Some(services) = self.imp().services.get() else {
            return;
        };
        // A build without a PostHog key sends nothing, so it has nothing to ask.
        if services.telemetry().has_project_key() && !services.settings.usage_data_asked() {
            self.announce(LaunchNotice::UsageData);
        }
    }

    // The toast's Choose…, so the dialog opens only because the user asked for it.
    pub(super) fn present_usage_data_choice(&self) {
        let Some(services) = self.imp().services.get() else {
            return;
        };
        let Some(window) = self.active_window() else {
            return;
        };
        let alert = usage_data_dialog();
        let settings = services.settings.clone();
        glib::spawn_future_local(async move {
            let share = match crate::workspace::respond(&alert, window.upcast_ref()).await.as_str() {
                SHARE => true,
                DONT_SHARE => false,
                _ => return,
            };
            // The setting's change starts or stops the usage data (AppServices::start_telemetry).
            if let Err(error) = settings.choose_usage_data(share) {
                tracing::warn!(%error, "the usage data choice was not stored");
            }
        });
    }
}

// Neither answer is the default: the choice is the user's, and Escape makes none.
pub(super) fn usage_data_dialog() -> adw::AlertDialog {
    let body = format!(
        "{}\n\n{}\n\n{}",
        gettext(
            "TablePro would send PostHog, the analytics service TablePro uses, events such as a launch, a first connection or query and a sign-in, with the TablePro and system versions, the processor type, the interface language and the kinds of database you open. Once you sign in, they carry your account’s ID."
        ),
        gettext("Never a host name, a password, a query or a row."),
        gettext("You can change this in Preferences."),
    );
    let alert = adw::AlertDialog::new(Some(&gettext("Share Usage Data?")), Some(&body));
    alert.add_response(DONT_SHARE, &gettext("_Don’t Share"));
    alert.add_response(SHARE, &gettext("_Share"));
    alert.set_close_response(UNDECIDED);
    alert
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn the_choice_has_no_default_and_escape_makes_none() {
        let alert = usage_data_dialog();

        assert!(alert.has_response(SHARE));
        assert!(alert.has_response(DONT_SHARE));
        assert_eq!(alert.default_response(), None);
        assert_eq!(alert.close_response(), UNDECIDED);
        assert!(!alert.has_response(UNDECIDED));
        assert_eq!(alert.response_appearance(SHARE), adw::ResponseAppearance::Default);
    }
}
