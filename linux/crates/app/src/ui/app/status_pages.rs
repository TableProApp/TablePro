use relm4::adw::prelude::*;
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, HistoryDialogOutput};
use crate::ui::saved_queries_dialog::{SavedQueriesDialog, SavedQueriesDialogInit, SavedQueriesDialogOutput};

use super::{App, AppMsg};

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

    pub(super) fn show_error_alert(&self, title: &str, message: &str) {
        let dialog = adw::AlertDialog::new(Some(title), Some(message));
        // GNOME HIG dismiss-only alert: "Close" reads cleaner than "OK"
        // (which implies acknowledgement of an action the user took)
        // and matches GNOME Settings' info-alert convention.
        dialog.add_response("close", &crate::i18n::gettext("Close"));
        dialog.set_default_response(Some("close"));
        dialog.set_close_response("close");
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_show_history(&mut self, sender: ComponentSender<Self>) {
        let dialog = HistoryDialog::builder()
            .launch(HistoryDialogInit {
                history: self.history.clone(),
                tasks: self.tasks.clone(),
            })
            .forward(sender.input_sender(), |out| match out {
                HistoryDialogOutput::OpenInNewTab(text) => AppMsg::OpenHistoryQuery(text),
                HistoryDialogOutput::ReplaceCurrentTabQuery(text) => AppMsg::ReplaceActiveTabQuery(text),
            });
        dialog.model().dialog().present(Some(&self.window));
        self.history_dialog = Some(dialog);
    }

    pub(super) fn on_show_saved_queries(&mut self, sender: ComponentSender<Self>) {
        let dialog = SavedQueriesDialog::builder()
            .launch(SavedQueriesDialogInit {
                store: self.history.store().map(|history| history.saved_queries()),
                active_connection: crate::services::database_service::instance()
                    .active_metadata()
                    .map(|metadata| metadata.id),
            })
            .forward(sender.input_sender(), |out| match out {
                SavedQueriesDialogOutput::OpenInNewTab(text) => AppMsg::OpenHistoryQuery(text),
                SavedQueriesDialogOutput::ReplaceCurrentTabQuery(text) => AppMsg::ReplaceActiveTabQuery(text),
                SavedQueriesDialogOutput::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
                SavedQueriesDialogOutput::ShowToast(text) => AppMsg::ShowToast(text),
            });
        dialog.model().dialog().present(Some(&self.window));
        self.saved_queries_dialog = Some(dialog);
    }

    /// Ask what to call the SQL in front of the user, then keep it.
    ///
    /// The text is read now rather than when the dialog closes, so what
    /// is saved is what the user was looking at when they asked.
    pub(super) fn on_save_active_query(&self, sender: ComponentSender<Self>) {
        let Some(query) = self.active_editor_query() else {
            self.show_toast(&crate::i18n::gettext("Open a SQL editor tab to save a query."));
            return;
        };
        if query.trim().is_empty() {
            self.show_toast(&crate::i18n::gettext("There is nothing in the editor to save."));
            return;
        }
        if crate::services::database_service::instance()
            .active_metadata()
            .is_none()
        {
            self.show_toast(&crate::i18n::gettext(
                "Connect to a database first: a saved query is kept under its connection.",
            ));
            return;
        }

        let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Save Query")), None);
        let entry = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
        entry.set_text(&suggested_query_name(&query));
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("save", &crate::i18n::gettext("Save"));
        dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("save"));
        dialog.set_close_response("cancel");

        let sender = sender.input_sender().clone();
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "save" {
                return;
            }
            let name = entry.text().to_string();
            if name.trim().is_empty() {
                return;
            }
            let _ = sender.send(AppMsg::SaveQueryNamed {
                name,
                query: query.clone(),
            });
        });
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_save_query_named(&self, name: String, query: String, sender: ComponentSender<Self>) {
        let Some(store) = self.history.store().map(|history| history.saved_queries()) else {
            self.show_toast(&crate::i18n::gettext("The query database is not open yet."));
            return;
        };
        let Some(metadata) = crate::services::database_service::instance().active_metadata() else {
            self.show_toast(&crate::i18n::gettext(
                "Connect to a database first: a saved query is kept under its connection.",
            ));
            return;
        };
        let new_query = tablepro_storage::saved_queries::NewSavedQuery {
            name: name.clone(),
            query,
            connection_id: metadata.id,
            connection_name: metadata.name,
        };
        let sender_for_result = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let message = match store.save(new_query).await {
                        Ok(outcome) if outcome.replaced => {
                            crate::i18n::gettext_f("Replaced “{name}”.", &[("name", &name)])
                        }
                        Ok(_) => crate::i18n::gettext_f("Saved “{name}”.", &[("name", &name)]),
                        Err(error) => {
                            tracing::warn!(%error, "could not save the query");
                            crate::i18n::gettext("Could not save that query.")
                        }
                    };
                    sender_for_result.input(AppMsg::ShowToast(message));
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_show_about(&self) {
        let dialog = adw::AboutDialog::builder()
            .application_name(crate::i18n::gettext("TablePro"))
            .application_icon(crate::config::APP_ID)
            .developer_name(crate::i18n::gettext("TablePro Authors"))
            .version(crate::config::VERSION)
            .website("https://github.com/TableProApp/TablePro")
            .issue_url("https://github.com/TableProApp/TablePro/issues")
            .support_url("https://github.com/TableProApp/TablePro/discussions")
            .copyright(crate::i18n::gettext("© 2025–2026 TablePro Authors"))
            .license_type(gtk::License::Agpl30)
            .comments(crate::i18n::gettext(
                "A native Linux database client built with GTK4 + libadwaita.",
            ))
            .build();
        dialog.set_developers(&["TablePro Authors https://github.com/TableProApp/TablePro"]);
        dialog.set_translator_credits(&crate::i18n::gettext("translator-credits"));
        dialog.present(Some(&self.window));
    }
}

/// A name for a query the user has not named, taken from the first
/// line that is neither blank nor a comment. It is a starting point in
/// an entry the user can edit, not a final name.
fn suggested_query_name(query: &str) -> String {
    const MAX_CHARS: usize = 40;
    for line in query.lines() {
        let trimmed = line.trim().trim_end_matches(';').trim();
        if trimmed.is_empty() || trimmed.starts_with("--") {
            continue;
        }
        return trimmed
            .chars()
            .take(MAX_CHARS)
            .collect::<String>()
            .trim_end()
            .to_owned();
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::suggested_query_name;

    #[test]
    fn the_suggested_name_is_the_first_real_line() {
        assert_eq!(
            suggested_query_name("\n-- yesterday's orders\nSELECT * FROM orders;\n"),
            "SELECT * FROM orders"
        );
    }

    #[test]
    fn a_long_first_line_is_cut_rather_than_run_on() {
        let name = suggested_query_name("SELECT a, b, c, d, e, f, g, h FROM a_table_with_a_long_name");

        assert_eq!(name.chars().count(), 40);
        assert!(!name.ends_with(' '));
    }

    #[test]
    fn a_query_that_is_only_comments_suggests_nothing() {
        assert_eq!(suggested_query_name("-- nothing here\n\n"), "");
    }
}
