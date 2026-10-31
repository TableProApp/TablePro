use std::path::{Path, PathBuf};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;

use super::SessionWindow;
use crate::i18n::{gettext, gettext_f};
use crate::ui::file_reveal::reveal_failure_toast;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LaunchNotice {
    Crash(PathBuf),
    Update(String),
}

impl LaunchNotice {
    fn same_kind(&self, other: &Self) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}

type ShownToast = (adw::Toast, glib::SignalHandlerId);

pub(super) struct Said {
    notice: LaunchNotice,
    toast: Option<ShownToast>,
}

impl SessionWindow {
    // A later notice replaces the earlier one of its kind and leaves the other kind's toast alone.
    pub(crate) fn announce(&self, notice: LaunchNotice) {
        let replaced = {
            let mut notices = self.imp().launch_notices.borrow_mut();
            let at = notices.iter().position(|said| said.notice.same_kind(&notice));
            at.and_then(|at| notices.remove(at).toast)
        };
        if let Some(toast) = replaced {
            withdraw(toast);
        }
        let toast = self.say(&notice);
        self.imp().launch_notices.borrow_mut().push(Said {
            notice,
            toast: Some(toast),
        });
    }

    // A toast lives in the overlay of the page it was added to, and a restored session goes from
    // the picker through connecting to its workspace, so each page shown says what is unread.
    pub(super) fn show_launch_notices(&self) {
        let (shown, notices): (Vec<_>, Vec<_>) = self
            .imp()
            .launch_notices
            .borrow_mut()
            .iter_mut()
            .map(|said| (said.toast.take(), said.notice.clone()))
            .unzip();
        shown.into_iter().flatten().for_each(withdraw);
        for notice in notices {
            let toast = self.say(&notice);
            if let Some(said) = self
                .imp()
                .launch_notices
                .borrow_mut()
                .iter_mut()
                .find(|said| said.notice == notice)
            {
                said.toast = Some(toast);
            }
        }
    }

    fn say(&self, notice: &LaunchNotice) -> ShownToast {
        let toast = match notice {
            LaunchNotice::Crash(report) => {
                let toast = adw::Toast::builder()
                    .title(gettext("TablePro quit unexpectedly last time"))
                    .button_label(gettext("Show Report"))
                    .use_markup(false)
                    .build();
                let window = self.downgrade();
                let report = report.clone();
                toast.connect_button_clicked(move |_| {
                    if let Some(window) = window.upgrade() {
                        window.reveal_crash_report(&report);
                    }
                });
                toast
            }
            LaunchNotice::Update(version) => adw::Toast::builder()
                // Translators: {version} is the TablePro version this launch updated to, such as 0.2.0.
                .title(gettext_f("TablePro was updated to {version}", &[("version", version)]))
                .button_label(gettext("What’s New"))
                .action_name("app.about")
                .use_markup(false)
                .build(),
        };
        let window = self.downgrade();
        let notice = notice.clone();
        let dismissed = toast.connect_dismissed(move |_| {
            if let Some(window) = window.upgrade() {
                window
                    .imp()
                    .launch_notices
                    .borrow_mut()
                    .retain(|said| said.notice != notice);
            }
        });
        self.add_toast(toast.clone());
        (toast, dismissed)
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

// An overlay that goes away dismisses its toasts, which must not count as the user dismissing one.
fn withdraw((toast, dismissed): ShownToast) {
    toast.disconnect(dismissed);
    toast.dismiss();
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use libadwaita::prelude::*;

    use super::super::SessionWindowInput;
    use super::super::tests::{Script, TestWindow, WAIT};
    use super::*;
    use crate::test_support::{descendants, drain_main_context, wait_until};
    use crate::ui::file_reveal::RecordingRevealer;

    const CRASHED: &str = "TablePro quit unexpectedly last time";
    const UPDATED: &str = "TablePro was updated to 2.0";

    fn said(window: &SessionWindow, title: &str) -> usize {
        window
            .imp()
            .toasts
            .borrow()
            .iter()
            .filter(|toast| toast.title().as_deref() == Some(title))
            .count()
    }

    fn mapped_button(window: &SessionWindow, label: &str) -> Option<gtk4::Button> {
        descendants(window)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
            .find(|button| button.label().as_deref() == Some(label) && button.is_mapped())
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

        test.window.announce(LaunchNotice::Crash(report.clone()));
        assert_eq!(said(&test.window, CRASHED), 1);

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        assert!(said(&test.window, CRASHED) > 1, "the toast stayed on the picker");
        wait_until(WAIT, || mapped_button(&test.window, "Show Report").is_some()).expect("the toast on the workspace");

        mapped_button(&test.window, "Show Report")
            .expect("the button")
            .emit_clicked();
        drain_main_context();

        assert_eq!(revealer.revealed(), [report]);
        assert!(test.window.imp().launch_notices.borrow().is_empty());
        let before = said(&test.window, CRASHED);
        test.window.show_launch_notices();
        assert_eq!(said(&test.window, CRASHED), before, "a dismissed notice came back");
    }

    #[gtk4::test]
    fn an_update_and_a_crash_are_each_said_on_each_page() {
        let test = TestWindow::picker("UpdateBesideCrash");
        let report = test.dir().join("crash-20261017T000000Z-1.txt");

        test.window.announce(LaunchNotice::Update("2.0".to_owned()));
        test.window.announce(LaunchNotice::Crash(report));
        assert_eq!(said(&test.window, UPDATED), 1);
        assert_eq!(said(&test.window, CRASHED), 1);

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");

        assert!(said(&test.window, UPDATED) > 1, "the update toast stayed on the picker");
        assert!(said(&test.window, CRASHED) > 1, "the crash toast stayed on the picker");
        assert_eq!(test.window.imp().launch_notices.borrow().len(), 2);
    }

    #[gtk4::test]
    fn a_second_notice_of_a_kind_replaces_only_its_own_toast() {
        let test = TestWindow::picker("UpdateReplaced");
        let report = test.dir().join("crash-20261017T000000Z-1.txt");
        test.window.announce(LaunchNotice::Crash(report.clone()));
        test.window.announce(LaunchNotice::Update("1.0".to_owned()));

        test.window.announce(LaunchNotice::Update("2.0".to_owned()));

        let notices: Vec<LaunchNotice> = test
            .window
            .imp()
            .launch_notices
            .borrow()
            .iter()
            .map(|said| said.notice.clone())
            .collect();
        assert_eq!(
            notices,
            [LaunchNotice::Crash(report), LaunchNotice::Update("2.0".to_owned())]
        );
        assert_eq!(said(&test.window, CRASHED), 1, "the crash toast was said again");
    }

    #[gtk4::test]
    fn whats_new_opens_the_about_dialog_and_the_notice_stays_read() {
        let test = TestWindow::picker("UpdateWhatsNew");
        test.window.announce(LaunchNotice::Update("2.0".to_owned()));
        wait_until(WAIT, || mapped_button(&test.window, "What’s New").is_some()).expect("the toast's button");

        mapped_button(&test.window, "What’s New")
            .expect("the button")
            .emit_clicked();
        drain_main_context();

        let dialog = test.window.visible_dialog().expect("a dialog over the window");
        assert!(dialog.is::<adw::AboutDialog>(), "{}", dialog.type_().name());
        assert!(test.window.imp().launch_notices.borrow().is_empty());
        dialog.force_close();
        let before = said(&test.window, UPDATED);
        test.window.show_launch_notices();
        assert_eq!(said(&test.window, UPDATED), before, "a read notice came back");
    }
}
