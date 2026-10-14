use libadwaita as adw;
use libadwaita::prelude::*;
use relm4::{Component, ComponentController};

use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, HistoryDialogOutput};
use crate::ui::saved_queries_dialog::{SavedQueriesDialog, SavedQueriesDialogInit, SavedQueriesDialogOutput};

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::DeliverInput;

impl WorkspaceModel {
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
        dialog.present(self.dialog_parent().as_ref());
    }

    pub(super) fn on_show_history(&mut self) {
        let dialog = HistoryDialog::builder()
            .launch(HistoryDialogInit {
                history: self.history.clone(),
                tasks: self.tasks.clone(),
            })
            .connect_receiver({
                let input = self.input.clone();
                move |_, out| {
                    input.deliver(match out {
                        HistoryDialogOutput::OpenInNewTab(text) => WorkspaceInput::OpenHistoryQuery(text),
                        HistoryDialogOutput::ReplaceCurrentTabQuery(text) => {
                            WorkspaceInput::ReplaceActiveTabQuery(text)
                        }
                    });
                }
            });
        dialog.model().dialog().present(self.dialog_parent().as_ref());
        self.history_dialog = Some(dialog);
    }

    pub(super) fn on_show_saved_queries(&mut self) {
        let dialog = SavedQueriesDialog::builder()
            .launch(SavedQueriesDialogInit {
                store: self.history.store().map(|history| history.saved_queries()),
                active_connection: self.context.active.metadata().map(|metadata| metadata.id),
            })
            .connect_receiver({
                let input = self.input.clone();
                move |_, out| {
                    input.deliver(match out {
                        SavedQueriesDialogOutput::OpenInNewTab(text) => WorkspaceInput::OpenHistoryQuery(text),
                        SavedQueriesDialogOutput::ReplaceCurrentTabQuery(text) => {
                            WorkspaceInput::ReplaceActiveTabQuery(text)
                        }
                        SavedQueriesDialogOutput::CopyToClipboard(text) => WorkspaceInput::CopyToClipboard(text),
                        SavedQueriesDialogOutput::ShowToast(text) => WorkspaceInput::ShowToast(text),
                    });
                }
            });
        dialog.model().dialog().present(self.dialog_parent().as_ref());
        self.saved_queries_dialog = Some(dialog);
    }

    /// Ask what to call the SQL in front of the user, then keep it.
    ///
    /// The text is read now rather than when the dialog closes, so what
    /// is saved is what the user was looking at when they asked.
    pub(super) fn on_save_active_query(&self) {
        let Some(query) = self.active_editor_query() else {
            self.show_toast(&crate::i18n::gettext("Open a SQL editor tab to save a query."));
            return;
        };
        if query.trim().is_empty() {
            self.show_toast(&crate::i18n::gettext("There is nothing in the editor to save."));
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

        let input = self.input.clone();
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "save" {
                return;
            }
            let name = entry.text().to_string();
            if name.trim().is_empty() {
                return;
            }
            input.deliver(WorkspaceInput::SaveQueryNamed {
                name,
                query: query.clone(),
            });
        });
        dialog.present(self.dialog_parent().as_ref());
    }

    pub(super) fn on_save_query_named(&self, name: String, query: String) {
        let Some(store) = self.history.store().map(|history| history.saved_queries()) else {
            self.show_toast(&crate::i18n::gettext("The query database is not open yet."));
            return;
        };
        let Some(metadata) = self.context.active.metadata() else {
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
        // The save lands even when the workspace is gone by then; only
        // its toast is dropped.
        let input = self.input.clone();
        crate::runtime::spawn_held(&self.tasks, &*self.context.hold, async move {
            let message = match store.save(new_query).await {
                Ok(outcome) if outcome.replaced => crate::i18n::gettext_f("Replaced “{name}”.", &[("name", &name)]),
                Ok(_) => crate::i18n::gettext_f("Saved “{name}”.", &[("name", &name)]),
                Err(error) => {
                    tracing::warn!(%error, "could not save the query");
                    crate::i18n::gettext("Could not save that query.")
                }
            };
            input.deliver(WorkspaceInput::ShowToast(message));
        });
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
    use crate::test_support::{finish_on_main, wait_until};
    use crate::ui::session_window::tests::{TestWindow, WAIT};

    #[gtk4::test]
    fn a_saved_query_is_written_under_a_hold() {
        let test = TestWindow::connected("SaveQueryHeld");
        let history = test.services.history();
        let availability = history.availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("the query database to open");
        wait_until(WAIT, || test.hold.live() == 0).expect("nothing else to hold the process");

        test.workspace()
            .with_model(|model| model.on_save_query_named("Orders".to_owned(), "SELECT 1".to_owned()));
        assert_eq!(test.hold.live(), 1, "the save started without holding the process");
        wait_until(WAIT, || test.hold.live() == 0).expect("the hold to end");

        let store = history.store().expect("the query database").saved_queries();
        let listing = test.services.tasks.spawn_task(async move { store.list(None).await });
        let saved = finish_on_main(WAIT, listing)
            .expect("the list to load")
            .expect("the listing task")
            .expect("the saved queries");
        assert!(
            saved.iter().any(|query| query.name == "Orders"),
            "the hold ended before the save"
        );
    }

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
