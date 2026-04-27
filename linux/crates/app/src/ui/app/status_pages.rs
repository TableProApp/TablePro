use relm4::adw::prelude::*;
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, HistoryDialogOutput};

use super::{App, AppMsg, UndoBatch, build_shortcuts_window};

impl App {
    pub(super) fn show_welcome_page(&self, _sender: ComponentSender<Self>) {
        // Welcome lives outside the ViewStack — it's the disconnected mode.
        // The ViewSwitcherBar is hidden via on_disconnect so the welcome
        // view occupies the full toolbar surface.
        self.content_holder.set_content(Some(self.welcome_view.widget()));
    }

    /// Used during connect to convey "Connecting…". Persistent toast
    /// (timeout 0) — held in `connect_progress_toast` until the connect
    /// resolves, at which point `dismiss_loading_page` clears it. Replaces
    /// the prior fire-and-forget toast which auto-dismissed at 2 s, well
    /// before remote / SSH-tunnelled connections resolve.
    pub(super) fn set_loading_page(&mut self, title: &str, description: &str) {
        if let Some(prev) = self.connect_progress_toast.take() {
            prev.dismiss();
        }
        let body = if description.is_empty() {
            title.to_string()
        } else {
            format!("{title} {description}")
        };
        let toast = adw::Toast::builder().title(&body).timeout(0).build();
        self.toast_overlay.add_toast(toast.clone());
        self.connect_progress_toast = Some(toast);
    }

    pub(super) fn dismiss_loading_page(&mut self) {
        if let Some(toast) = self.connect_progress_toast.take() {
            toast.dismiss();
        }
    }

    /// Convenience for `set_status_page(Error, ...)` and similar; in the
    /// connected state, browse-tab errors flow through BrowseTabInput::ShowError.
    /// Used here only for app-level (non-tab-scoped) failures — surfaces
    /// as an alert dialog so the user actually notices.
    pub(super) fn set_status_page(&self, _kind: super::StatusKind, title: &str, description: &str) {
        self.show_error_alert(title, description);
    }

    pub(super) fn show_toast(&self, msg: &str) {
        self.toast_overlay.add_toast(adw::Toast::new(msg));
    }

    pub(super) fn show_undoable_toast(&self, msg: &str, batch: UndoBatch, sender: ComponentSender<Self>) {
        let toast = adw::Toast::builder()
            .title(msg)
            .timeout(10)
            .button_label(crate::tr!("Undo"))
            .build();
        let s = sender;
        let batch_clone = batch;
        toast.connect_button_clicked(move |t| {
            s.input(AppMsg::ExecuteUndo(batch_clone.clone()));
            t.dismiss();
        });
        self.toast_overlay.add_toast(toast);
    }

    pub(super) fn show_error_alert(&self, title: &str, message: &str) {
        let dialog = adw::AlertDialog::new(Some(title), Some(message));
        dialog.add_response("ok", "OK");
        dialog.set_default_response(Some("ok"));
        dialog.set_close_response("ok");
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_show_history(&mut self, sender: ComponentSender<Self>) {
        let dialog =
            HistoryDialog::builder()
                .launch(HistoryDialogInit)
                .forward(sender.input_sender(), |out| match out {
                    HistoryDialogOutput::OpenInNewTab(text) => AppMsg::OpenHistoryQuery(text),
                    HistoryDialogOutput::ReplaceCurrentTabQuery(text) => AppMsg::ReplaceActiveTabQuery(text),
                });
        dialog.model().dialog().present(Some(&self.window));
        self.history_dialog = Some(dialog);
    }

    pub(super) fn on_show_shortcuts(&self) {
        build_shortcuts_window(&self.window).present();
    }

    pub(super) fn on_show_about(&self) {
        let dialog = adw::AboutDialog::builder()
            .application_name(crate::tr!("TablePro"))
            .application_icon("com.tablepro.linux")
            .developer_name(crate::tr!("TablePro Authors"))
            .version(env!("CARGO_PKG_VERSION"))
            .website("https://github.com/TableProApp/TablePro")
            .issue_url("https://github.com/TableProApp/TablePro/issues")
            .support_url("https://github.com/TableProApp/TablePro/discussions")
            .copyright(crate::tr!("© 2025–2026 TablePro Authors"))
            .license_type(gtk::License::Agpl30)
            .comments(crate::tr!(
                "A native Linux database client built with GTK4 + libadwaita."
            ))
            .build();
        dialog.set_developers(&["TablePro Authors https://github.com/TableProApp/TablePro"]);
        dialog.set_translator_credits(&crate::tr!("translator-credits"));
        dialog.present(Some(&self.window));
    }
}
