use libadwaita as adw;
use libadwaita::prelude::*;
use relm4::{Component, ComponentController};

use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, QueryDestination};
use crate::ui::saved_queries_dialog::{SavedQueriesDialog, SavedQueriesDialogInit, SavedQueriesDialogOutput};

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::DeliverInput;
use crate::ui::plain_toast;

impl WorkspaceModel {
    pub(super) fn show_toast(&self, msg: &str) {
        self.toast_overlay.add_toast(plain_toast(msg));
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

    /// Say in an alert why the query database cannot be used. False
    /// when it can.
    fn alert_history_unavailable(&self, title: &str) -> bool {
        let reason = self.history.availability().borrow().failure().map(str::to_owned);
        let Some(reason) = reason else {
            return false;
        };
        self.show_error_alert(title, &reason);
        true
    }

    pub(super) fn on_show_history(&mut self) {
        if self.alert_history_unavailable(&crate::i18n::gettext("Query History Unavailable")) {
            return;
        }
        let dialog = HistoryDialog::new(HistoryDialogInit {
            history: self.history.clone(),
            connections: self.storage.connections().clone(),
            preferred_connection: self.context.active.metadata().map(|metadata| metadata.id),
            revealer: self.file_revealer.clone(),
            tasks: self.tasks.clone(),
        });
        let input = self.input.clone();
        dialog.connect_query_chosen(move |_, destination, text| {
            input.deliver(match destination {
                QueryDestination::NewTab => WorkspaceInput::OpenHistoryQuery(text),
                QueryDestination::CurrentTab => WorkspaceInput::ReplaceActiveTabQuery(text),
            });
        });
        dialog.present(self.dialog_parent().as_ref());
        self.history_dialog = Some(dialog);
    }

    pub(super) fn on_show_saved_queries(&mut self) {
        if self.alert_history_unavailable(&crate::i18n::gettext("Saved Queries Unavailable")) {
            return;
        }
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
        if self.alert_history_unavailable(&crate::i18n::gettext("Could Not Save Query")) {
            return;
        }
        let Some(query) = self.active_editor_query() else {
            self.show_toast(&crate::i18n::gettext("Open a SQL editor tab to save a query."));
            return;
        };
        if query.trim().is_empty() {
            self.show_toast(&crate::i18n::gettext("There is nothing in the editor to save."));
            return;
        }

        let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Save Query")), None);
        let entry = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Name"))
            .activates_default(true)
            .build();
        entry.set_text(&suggested_query_name(&query));
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("save", &crate::i18n::gettext("Save"));
        dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("save"));
        dialog.set_close_response("cancel");
        crate::ui::name_entry::require_name(&dialog, "save", &entry);

        let input = self.input.clone();
        dialog.connect_response(None, move |_, response| {
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
        // its toast is dropped. A database still opening is waited for.
        let input = self.input.clone();
        let (ready, availability) = (self.history.ready_store(), self.history.availability());
        crate::runtime::spawn_held(&self.tasks, &*self.context.hold, async move {
            let Some(store) = ready.await.map(|history| history.saved_queries()) else {
                let reason = availability.borrow().failure().map(str::to_owned).unwrap_or_default();
                input.deliver(WorkspaceInput::ShowAlert {
                    title: crate::i18n::gettext("Could Not Save Query"),
                    body: reason,
                });
                return;
            };
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

    #[gtk4::test]
    fn a_history_dialog_closed_by_hand_is_not_closed_again_on_disconnect() {
        use gtk4::glib;
        use gtk4::prelude::*;

        let test = TestWindow::connected("HistoryClosedOnce");
        let dialog = test
            .workspace()
            .with_model(|model| {
                model.on_show_history();
                model
                    .history_dialog
                    .as_ref()
                    .map(|dialog| dialog.clone().upcast::<libadwaita::Dialog>())
            })
            .flatten()
            .expect("the history dialog");
        wait_until(WAIT, || dialog.parent().is_some()).expect("the dialog to show");
        libadwaita::prelude::AdwDialogExt::close(&dialog);
        wait_until(WAIT, || dialog.parent().is_none()).expect("the dialog to close");

        // Closing a dialog that is no longer presented logs a critical,
        // which this makes abort the test.
        let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
        test.window.send(crate::ui::SessionWindowInput::Disconnect);
        let disconnected = wait_until(WAIT, || test.window.page_name() == "picker");
        glib::log_set_always_fatal(previous);

        disconnected.expect("the window back on the picker");
    }

    /// A history whose database cannot be read: a folder stands where
    /// the file goes.
    fn unreadable_history(
        test: &TestWindow,
        root: &tempfile::TempDir,
    ) -> crate::services::history_service::HistoryService {
        let paths = tablepro_storage::StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        std::fs::create_dir_all(paths.history_database()).expect("a folder where the database goes");
        let preferences = crate::services::history_preferences::HistoryPreferences {
            retention_days: tokio::sync::watch::channel(30).1,
            save: tokio::sync::watch::channel(true).1,
        };
        let history = crate::services::history_service::HistoryService::start(paths, preferences, &test.services.tasks);
        let availability = history.availability();
        wait_until(WAIT, || availability.borrow().is_settled()).expect("the open to end");
        history
    }

    #[gtk4::test]
    fn an_unreadable_history_says_why_where_it_is_opened() {
        use gtk4::prelude::*;
        use libadwaita::prelude::*;

        use crate::workspace::{answer, visible_alert};

        let test = TestWindow::connected("HistoryUnreadable");
        let root = tempfile::tempdir().expect("tempdir");
        let history = unreadable_history(&test, &root);
        test.workspace().with_model(|model| model.history = history);

        for (action, heading) in [
            ("win.show-history", "Query History Unavailable"),
            ("win.show-saved-queries", "Saved Queries Unavailable"),
        ] {
            // The action follows the window's own history, which may still
            // be opening.
            let name = action.trim_start_matches("win.");
            wait_until(WAIT, || {
                test.window
                    .lookup_action(name)
                    .is_some_and(|action| action.is_enabled())
            })
            .unwrap_or_else(|_| panic!("{action} stayed off"));
            WidgetExt::activate_action(&test.window, action, None).expect(action);
            wait_until(WAIT, || {
                visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some(heading))
            })
            .unwrap_or_else(|_| panic!("{action} said nothing"));
            let body = visible_alert(&test.window).map(|alert| alert.body().to_string());
            assert_eq!(
                body.as_deref(),
                Some("The query history file could not be read. It may be damaged.")
            );
            assert!(answer(&test.window, "close"));
            wait_until(WAIT, || visible_alert(&test.window).is_none()).expect("the alert to close");
        }
    }

    #[gtk4::test]
    fn saving_a_query_into_an_unreadable_history_says_why() {
        use libadwaita::prelude::*;

        use crate::workspace::visible_alert;

        let test = TestWindow::connected("SaveQueryUnreadable");
        let root = tempfile::tempdir().expect("tempdir");
        let history = unreadable_history(&test, &root);
        test.workspace().with_model(|model| {
            model.history = history;
            model.on_save_query_named("Orders".to_owned(), "SELECT 1".to_owned());
        });

        wait_until(WAIT, || {
            visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some("Could Not Save Query"))
        })
        .expect("the save said why it failed");
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
