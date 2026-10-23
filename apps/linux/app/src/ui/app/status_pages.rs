use relm4::adw::prelude::*;
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, HistoryDialogOutput};

use super::{App, AppMsg, shortcuts};

const ABOUT_DEVELOPERS: &[&str] = &[
    "BookiE contributors https://github.com/cozyGarage/BookiE",
    "TablePro Authors (upstream project) https://github.com/TableProApp/TablePro",
];

impl App {
    pub(super) fn show_welcome_page(&self, _sender: ComponentSender<Self>) {
        // Welcome lives outside the ViewStack — it's the disconnected mode.
        // The ViewSwitcherBar is hidden via on_disconnect so the welcome
        // view occupies the full toolbar surface.
        self.show_in_content_holder(self.welcome_view.widget());
    }

    pub(super) fn show_in_content_holder(&self, widget: &impl IsA<gtk::Widget>) {
        if self.content_holder.content().as_ref() != Some(self.history_paned.upcast_ref()) {
            self.content_holder.set_content(Some(&self.history_paned));
        }
        if self.history_paned.start_child().as_ref() != Some(widget.upcast_ref()) {
            self.history_paned.set_start_child(Some(widget));
        }
    }

    /// Used during connect to convey "Connecting…". Persistent toast
    /// (timeout 0) — held in `connect_progress_toast` until the connect
    /// resolves, at which point `dismiss_loading_page` clears it. Replaces
    /// the prior fire-and-forget toast which auto-dismissed at 2 s, well
    /// before remote / SSH-tunnelled connections resolve.
    pub(super) fn set_loading_page(&mut self, title: &str, description: &str, sender: &ComponentSender<Self>) {
        if let Some(prev) = self.connect_progress_toast.take() {
            prev.dismiss();
        }
        // GNOME inline-metadata separator (` · `) keeps the two
        // strings reading as one phrase rather than two sentences
        // colliding ("Connecting… Opening MyDB" → "Connecting… ·
        // Opening MyDB"). Same convention used in the browse
        // paginator label and the editor status line.
        let body = if description.is_empty() {
            title.to_string()
        } else {
            format!("{title} · {description}")
        };
        let toast = adw::Toast::builder()
            .title(&body)
            .timeout(0)
            .button_label(crate::tr!("Cancel"))
            .build();
        let cancel_sender = sender.clone();
        toast.connect_button_clicked(move |_| cancel_sender.input(AppMsg::CancelConnect));
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

    pub(super) fn show_error_alert(&self, title: &str, message: &str) {
        let dialog = adw::AlertDialog::new(Some(title), Some(message));
        // GNOME HIG dismiss-only alert: "Close" reads cleaner than "OK"
        // (which implies acknowledgement of an action the user took)
        // and matches GNOME Settings' info-alert convention.
        dialog.add_response("close", &crate::tr!("Close"));
        dialog.set_default_response(Some("close"));
        dialog.set_close_response("close");
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_show_history(&mut self, sender: ComponentSender<Self>) {
        if self.history_paned.end_child().is_some() {
            self.hide_history_panel();
            return;
        }
        let Some(history) = self.history.clone() else {
            self.show_toast(&crate::tr!("Query history is unavailable"));
            return;
        };
        let panel = HistoryDialog::builder()
            .launch(HistoryDialogInit {
                history,
                database: self.database.clone(),
            })
            .forward(sender.input_sender(), |out| match out {
                HistoryDialogOutput::OpenInNewTab(text) => AppMsg::OpenHistoryQuery(text),
                HistoryDialogOutput::ReplaceCurrentTabQuery(text) => AppMsg::ReplaceActiveTabQuery(text),
                HistoryDialogOutput::Close => AppMsg::CloseHistory,
            });
        self.history_paned.set_end_child(Some(panel.widget()));
        self.history_paned.set_position(self.window.default_height() / 2);
        self.history_dialog = Some(panel);
    }

    pub(super) fn hide_history_panel(&mut self) {
        self.history_paned.set_end_child(None::<&gtk::Widget>);
        self.history_dialog = None;
    }

    pub(super) fn on_show_shortcuts(&self) {
        let shortcuts = shortcuts::build_shortcuts_dialog();
        shortcuts.present(Some(&self.window));
    }

    pub(super) fn on_show_about(&self) {
        let dialog = adw::AboutDialog::builder()
            .application_name(crate::tr!("BookiE"))
            .application_icon(crate::config::APP_ID)
            .developer_name(crate::tr!("BookiE contributors"))
            .version(env!("CARGO_PKG_VERSION"))
            .website("https://github.com/cozyGarage/BookiE")
            .issue_url("https://github.com/cozyGarage/BookiE/issues")
            .support_url("https://github.com/cozyGarage/BookiE/discussions")
            .copyright(crate::tr!("© 2025–2026 TablePro Authors"))
            .license_type(gtk::License::Agpl30)
            .comments(crate::tr!(
                "A native Linux database client built with GTK4 + libadwaita. Based on the open-source TablePro project."
            ))
            .build();
        dialog.set_developers(ABOUT_DEVELOPERS);
        dialog.set_translator_credits(&crate::tr!("translator-credits"));
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_explain_active_query(&self) {
        let Some(id) = self.selected_workspace_tab_id() else {
            self.show_toast(&crate::tr!("Open an SQL editor tab to explain a query."));
            return;
        };
        let tabs = self.workspace_tabs.borrow();
        let Some(super::WorkspaceTab::Editor(slot)) = tabs.get(&id) else {
            self.show_toast(&crate::tr!("Open an SQL editor tab to explain a query."));
            return;
        };
        let sql = slot.query.clone();
        drop(tabs);
        crate::ui::explain_dialog::present(
            &self.window,
            self.connection_id,
            &sql,
            &self.database,
            &self.preferences,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::ABOUT_DEVELOPERS;

    #[test]
    fn about_credits_distinguish_bookie_contributors_from_the_upstream_authors() {
        assert!(ABOUT_DEVELOPERS[0].starts_with("BookiE contributors "));
        assert!(ABOUT_DEVELOPERS[0].contains("github.com/cozyGarage/BookiE"));
        assert!(ABOUT_DEVELOPERS[1].starts_with("TablePro Authors (upstream project) "));
        assert!(ABOUT_DEVELOPERS[1].contains("github.com/TableProApp/TablePro"));
    }
}
