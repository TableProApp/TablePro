use std::cell::RefCell;

use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::services::secret_save_report::SecretSaveReport;

const CLOSE: &str = "close";

/// The one refusal toast a window or page shows. A toast that stays until dismissed holds back
/// every later one on its overlay, so a newer report or a save that worked takes it down.
#[derive(Debug, Default)]
pub(crate) struct UnsavedSecretToasts(RefCell<Option<adw::Toast>>);

impl UnsavedSecretToasts {
    pub(crate) fn replace(&self, report: SecretSaveReport, parent: &impl IsA<gtk4::Widget>) -> adw::Toast {
        self.dismiss();
        let toast = unsaved_secret_toast(report, parent);
        self.0.replace(Some(toast.clone()));
        toast
    }

    pub(crate) fn dismiss(&self) {
        if let Some(toast) = self.0.take() {
            toast.dismiss();
        }
    }
}

/// The toast for a save the keyring refused, whose Details say how to fix the keyring.
fn unsaved_secret_toast(report: SecretSaveReport, parent: &impl IsA<gtk4::Widget>) -> adw::Toast {
    let toast = crate::ui::plain_toast(&report.title());
    // A 5 s toast runs out while the window is unfocused, and this one is about the next connect.
    toast.set_timeout(0);
    toast.set_priority(adw::ToastPriority::High);
    toast.set_button_label(Some(&crate::i18n::gettext("Details")));
    let parent = parent.as_ref().downgrade();
    toast.connect_button_clicked(move |_| {
        if let Some(parent) = parent.upgrade() {
            details_dialog(&report).present(Some(&parent));
        }
    });
    toast
}

fn details_dialog(report: &SecretSaveReport) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(Some(&report.heading()), Some(&report.body()));
    dialog.add_response(CLOSE, &crate::i18n::gettext("_Close"));
    dialog.set_close_response(CLOSE);
    dialog
}

#[cfg(test)]
mod tests {
    use tablepro_core::credentials::{SecretError, SecretKind};

    use super::*;
    use crate::test_support::drain_main_context;

    #[gtk4::test]
    fn the_toast_stays_until_dismissed_and_its_details_say_how_to_fix_the_keyring() {
        let report =
            SecretSaveReport::of_connection(&[(SecretKind::DatabasePassword, SecretError::Locked)]).expect("a refusal");
        let window = adw::Window::new();
        let overlay = adw::ToastOverlay::new();
        window.set_content(Some(&overlay));
        window.present();

        let toast = unsaved_secret_toast(report.clone(), &window);
        overlay.add_toast(toast.clone());
        drain_main_context();

        assert_eq!(toast.timeout(), 0);
        assert_eq!(toast.priority(), adw::ToastPriority::High);
        assert_eq!(toast.title().as_deref(), Some(report.title().as_str()));
        assert_eq!(toast.button_label().as_deref(), Some("Details"));
        toast.emit_by_name::<()>("button-clicked", &[]);
        drain_main_context();
        let dialog = window
            .visible_dialog()
            .and_downcast::<adw::AlertDialog>()
            .expect("the Details dialog");
        assert_eq!(dialog.heading().as_deref(), Some("Password Not Saved"));
        assert_eq!(dialog.body(), report.body());
        dialog.close();
        window.destroy();
    }

    #[gtk4::test]
    fn a_newer_report_or_a_save_that_worked_takes_the_last_one_down() {
        let window = adw::Window::new();
        let overlay = adw::ToastOverlay::new();
        window.set_content(Some(&overlay));
        window.present();
        let toasts = UnsavedSecretToasts::default();
        let dismissed = std::rc::Rc::new(std::cell::Cell::new(0));

        for _ in 0..2 {
            let toast = toasts.replace(SecretSaveReport::api_key(SecretError::Locked), &window);
            let counted = dismissed.clone();
            toast.connect_dismissed(move |_| counted.set(counted.get() + 1));
            overlay.add_toast(toast);
            drain_main_context();
        }
        assert_eq!(dismissed.get(), 1, "the first report stayed behind the second");

        toasts.dismiss();
        drain_main_context();
        assert_eq!(dismissed.get(), 2);
        window.destroy();
    }
}
