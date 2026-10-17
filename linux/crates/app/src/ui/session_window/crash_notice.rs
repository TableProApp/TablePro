use std::path::{Path, PathBuf};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;

use super::SessionWindow;
use crate::i18n::gettext;
use crate::ui::file_reveal::reveal_failure_toast;

/// The report the last run left when it crashed, said until the user or
/// the toast's timeout dismisses it.
pub(crate) struct CrashNotice {
    report: PathBuf,
    shown: Option<(adw::Toast, glib::SignalHandlerId)>,
}

impl SessionWindow {
    pub(crate) fn announce_crash(&self, report: PathBuf) {
        self.withdraw_crash_toast();
        self.imp()
            .crash_notice
            .replace(Some(CrashNotice { report, shown: None }));
        self.show_crash_notice();
    }

    /// A toast lives in the overlay of the page it was added to, so a
    /// restored session, which goes from the picker through connecting
    /// to its workspace, would take an unread one away. Each page shown
    /// gets it again until it is dismissed.
    pub(super) fn show_crash_notice(&self) {
        self.withdraw_crash_toast();
        let Some(report) = self
            .imp()
            .crash_notice
            .borrow()
            .as_ref()
            .map(|notice| notice.report.clone())
        else {
            return;
        };
        let toast = adw::Toast::builder()
            .title(gettext("TablePro quit unexpectedly last time"))
            .button_label(gettext("Show Report"))
            .use_markup(false)
            .build();
        let window = self.downgrade();
        toast.connect_button_clicked(move |_| {
            if let Some(window) = window.upgrade() {
                window.reveal_crash_report(&report);
            }
        });
        let window = self.downgrade();
        let dismissed = toast.connect_dismissed(move |_| {
            if let Some(window) = window.upgrade() {
                window.imp().crash_notice.take();
            }
        });
        if let Some(notice) = self.imp().crash_notice.borrow_mut().as_mut() {
            notice.shown = Some((toast.clone(), dismissed));
        }
        self.add_toast(toast);
    }

    /// Takes the toast off the page it is on without counting that as
    /// the user dismissing it. An overlay that goes away dismisses its
    /// toasts, so this runs before the old page can.
    fn withdraw_crash_toast(&self) {
        let shown = self
            .imp()
            .crash_notice
            .borrow_mut()
            .as_mut()
            .and_then(|notice| notice.shown.take());
        if let Some((toast, dismissed)) = shown {
            toast.disconnect(dismissed);
            toast.dismiss();
        }
    }

    fn reveal_crash_report(&self, report: &Path) {
        let Some(state) = self.imp().state.get() else {
            return;
        };
        let revealing = state
            .services
            .file_revealer
            .reveal(gio::File::for_path(report), Some(self.clone().upcast()));
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let revealed = revealing.await;
            if let (Some(toast), Some(window)) = (reveal_failure_toast(&revealed), window.upgrade()) {
                window.add_toast(toast);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use super::super::SessionWindowInput;
    use super::super::tests::{Script, TestWindow, WAIT};
    use super::*;
    use crate::test_support::{descendants, drain_main_context, wait_until};
    use crate::ui::file_reveal::RecordingRevealer;

    const TITLE: &str = "TablePro quit unexpectedly last time";

    fn said(window: &SessionWindow) -> usize {
        window
            .imp()
            .toasts
            .borrow()
            .iter()
            .filter(|toast| toast.title().as_deref() == Some(TITLE))
            .count()
    }

    fn show_report(window: &SessionWindow) -> Option<gtk4::Button> {
        descendants(window)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Show Report") && button.is_mapped())
    }

    #[gtk4::test]
    fn a_crash_report_is_said_on_each_page_until_the_user_opens_it() {
        let revealer = Rc::new(RecordingRevealer::succeeding());
        let test = TestWindow::with_script(
            "CrashNotice",
            Script {
                revealer: Some(revealer.clone()),
                ..Script::default()
            },
        );
        let report = test.dir().join("crash-20261017T000000Z-1.txt");

        test.window.announce_crash(report.clone());
        assert_eq!(said(&test.window), 1);

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        assert!(said(&test.window) > 1, "the toast stayed on the picker");
        wait_until(WAIT, || show_report(&test.window).is_some()).expect("the toast on the workspace");

        show_report(&test.window).expect("the button").emit_clicked();
        drain_main_context();

        assert_eq!(revealer.revealed(), [report]);
        assert!(test.window.imp().crash_notice.borrow().is_none());
        let before = said(&test.window);
        test.window.show_crash_notice();
        assert_eq!(said(&test.window), before, "a dismissed notice came back");
    }
}
