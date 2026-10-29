use std::path::{Path, PathBuf};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;

use super::SessionWindow;
use crate::i18n::{gettext, gettext_f};
use crate::ui::file_reveal::reveal_failure_toast;

/// Something the last run or an update left to say at launch, said until
/// the user or the toast's timeout dismisses it.
pub(crate) struct LaunchNotice {
    kind: NoticeKind,
    title: String,
    button: String,
    act: Rc<dyn Fn(&SessionWindow)>,
    shown: Option<(adw::Toast, glib::SignalHandlerId)>,
}

/// Which notice it is, so a second one of a kind replaces the first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NoticeKind {
    Crash,
    Update,
}

impl SessionWindow {
    pub(crate) fn announce_crash(&self, report: PathBuf) {
        self.announce(
            NoticeKind::Crash,
            gettext("TablePro quit unexpectedly last time"),
            gettext("Show Report"),
            Rc::new(move |window: &SessionWindow| window.reveal_crash_report(&report)),
        );
    }

    /// The first launch of `version` after another one ran, with the
    /// About dialog's release notes a click away.
    pub(crate) fn announce_update(&self, version: &str) {
        self.announce(
            NoticeKind::Update,
            gettext_f("TablePro was updated to {version}", &[("version", version)]),
            gettext("What’s New"),
            Rc::new(|window: &SessionWindow| {
                let _ = WidgetExt::activate_action(window, "app.about", None);
            }),
        );
    }

    /// Replaces a notice of the same kind, and leaves any other toast
    /// where it is.
    fn announce(&self, kind: NoticeKind, title: String, button: String, act: Rc<dyn Fn(&SessionWindow)>) {
        let replaced = {
            let mut notices = self.imp().launch_notices.borrow_mut();
            let at = notices.iter().position(|notice| notice.kind == kind);
            at.map(|at| notices.remove(at))
        };
        if let Some((toast, dismissed)) = replaced.and_then(|notice| notice.shown) {
            toast.disconnect(dismissed);
            toast.dismiss();
        }
        self.imp().launch_notices.borrow_mut().push(LaunchNotice {
            kind,
            title,
            button,
            act,
            shown: None,
        });
        self.show_launch_notice(kind);
    }

    /// A toast lives in the overlay of the page it was added to, so a
    /// restored session, which goes from the picker through connecting
    /// to its workspace, would take an unread one away. Each page shown
    /// gets it again until it is dismissed.
    pub(super) fn show_launch_notices(&self) {
        self.withdraw_launch_toasts();
        let kinds: Vec<NoticeKind> = self
            .imp()
            .launch_notices
            .borrow()
            .iter()
            .map(|notice| notice.kind)
            .collect();
        for kind in kinds {
            self.show_launch_notice(kind);
        }
    }

    fn show_launch_notice(&self, kind: NoticeKind) {
        let Some((title, button, act)) = self
            .imp()
            .launch_notices
            .borrow()
            .iter()
            .find(|notice| notice.kind == kind)
            .map(|notice| (notice.title.clone(), notice.button.clone(), notice.act.clone()))
        else {
            return;
        };
        let toast = adw::Toast::builder()
            .title(title)
            .button_label(button)
            .use_markup(false)
            .build();
        let window = self.downgrade();
        toast.connect_button_clicked(move |_| {
            if let Some(window) = window.upgrade() {
                act(&window);
            }
        });
        let window = self.downgrade();
        let dismissed = toast.connect_dismissed(move |_| {
            if let Some(window) = window.upgrade() {
                window
                    .imp()
                    .launch_notices
                    .borrow_mut()
                    .retain(|notice| notice.kind != kind);
            }
        });
        if let Some(notice) = self
            .imp()
            .launch_notices
            .borrow_mut()
            .iter_mut()
            .find(|notice| notice.kind == kind)
        {
            notice.shown = Some((toast.clone(), dismissed));
        }
        self.add_toast(toast);
    }

    /// Takes the toasts off the page they are on without counting that as
    /// the user dismissing them. An overlay that goes away dismisses its
    /// toasts, so this runs before the old page can.
    fn withdraw_launch_toasts(&self) {
        let shown: Vec<_> = self
            .imp()
            .launch_notices
            .borrow_mut()
            .iter_mut()
            .filter_map(|notice| notice.shown.take())
            .collect();
        for (toast, dismissed) in shown {
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
    const UPDATED: &str = "TablePro was updated to 2.0";

    fn said_as(window: &SessionWindow, title: &str) -> usize {
        window
            .imp()
            .toasts
            .borrow()
            .iter()
            .filter(|toast| toast.title().as_deref() == Some(title))
            .count()
    }

    fn said(window: &SessionWindow) -> usize {
        said_as(window, TITLE)
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
        assert!(test.window.imp().launch_notices.borrow().is_empty());
        let before = said(&test.window);
        test.window.show_launch_notices();
        assert_eq!(said(&test.window), before, "a dismissed notice came back");
    }

    /// An update and a crash are each said, and the update stays on
    /// every page until it is dismissed, as the crash does.
    #[gtk4::test]
    fn an_update_is_said_beside_a_crash_on_each_page() {
        let test = TestWindow::with_script("UpdateNotice", Script::default());
        let report = test.dir().join("crash-20261017T000000Z-1.txt");

        test.window.announce_update("2.0");
        test.window.announce_crash(report);
        assert_eq!(said_as(&test.window, UPDATED), 1);
        assert_eq!(said(&test.window), 1);

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        assert!(
            said_as(&test.window, UPDATED) > 1,
            "the update toast stayed on the picker"
        );
        assert_eq!(test.window.imp().launch_notices.borrow().len(), 2);
    }
}
