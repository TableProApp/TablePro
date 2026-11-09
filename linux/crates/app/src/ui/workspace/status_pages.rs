use libadwaita as adw;
use libadwaita::prelude::*;

use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, QueryDestination};
use crate::ui::saved_queries_dialog::{SavedQueriesDialog, SavedQueriesDialogInit};

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::DeliverInput;
use crate::ui::plain_toast;

#[derive(Debug)]
pub(crate) enum SearchInput {
    History,
    SavedQueries,
    QuickOpen,
    CloseQuickOpen,
    QuickOpenChosen(crate::ui::quick_open::Pick),
}

impl WorkspaceModel {
    pub(super) fn on_search(&mut self, input: SearchInput) {
        match input {
            SearchInput::History => self.on_show_history(),
            SearchInput::SavedQueries => self.on_show_saved_queries(),
            SearchInput::QuickOpen => self.on_show_quick_open(),
            SearchInput::CloseQuickOpen => self.close_quick_open(),
            SearchInput::QuickOpenChosen(pick) => self.on_quick_open_chosen(pick),
        }
    }

    pub(super) fn show_toast(&self, msg: &str) {
        self.add_toast(plain_toast(msg));
    }

    /// In the window's toasts, which every session of the window shares.
    pub(super) fn add_toast(&self, toast: adw::Toast) {
        if let Some(shell) = self.shell.upgrade() {
            shell.toast_overlay().add_toast(toast);
        }
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
        let dialog = SavedQueriesDialog::new(SavedQueriesDialogInit {
            store: self.history.store().map(|history| history.saved_queries()),
            active_connection: self.context.active.metadata().map(|metadata| metadata.id),
            tasks: self.tasks.clone(),
            hold: self.context.hold.clone(),
        });
        let input = self.input.clone();
        dialog.connect_query_chosen(move |_, destination, text| {
            input.deliver(match destination {
                QueryDestination::NewTab => WorkspaceInput::OpenHistoryQuery(text),
                QueryDestination::CurrentTab => WorkspaceInput::ReplaceActiveTabQuery(text),
            });
        });
        dialog.present(self.dialog_parent().as_ref());
        self.saved_queries_dialog = Some(dialog);
    }

    pub(super) fn close_quick_open(&mut self) {
        if let Some(dialog) = self.quick_open_dialog.take() {
            dialog.dismiss();
        }
    }

    pub(super) fn on_show_quick_open(&mut self) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        self.close_quick_open();
        let input = self.input.clone();
        let dialog = crate::ui::quick_open::QuickOpen::new(session, self.tasks.clone(), move |pick| {
            input.deliver(WorkspaceInput::Search(SearchInput::QuickOpenChosen(pick)));
        });
        dialog.present(self.dialog_parent().as_ref());
        self.quick_open_dialog = Some(dialog);
    }

    pub(super) fn on_quick_open_chosen(&mut self, pick: crate::ui::quick_open::Pick) {
        if !self.is_front() {
            return;
        }
        let crate::ui::quick_open::Target::Table(table) = pick.target;
        let tablepro_core::meta::TableRef { schema, name } = table;
        self.update(match pick.structure {
            true => WorkspaceInput::EditStructureTab { schema, table: name },
            false => WorkspaceInput::SelectTable {
                schema,
                name,
                open_mode: super::OpenMode::SwitchOrAppend,
            },
        });
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
            name,
            query,
            connection_id: metadata.id,
            connection_name: metadata.name,
        };
        self.save_named_query(new_query, false);
    }

    pub(super) fn confirm_replace_saved_query(&self, query: tablepro_storage::saved_queries::NewSavedQuery) {
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext_f(
                "Replace “{name}”?",
                &[("name", query.name.trim())],
            )),
            Some(&crate::i18n::gettext(
                "A saved query already uses this name. Replacing it will overwrite its SQL.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("replace", &crate::i18n::gettext("Replace"));
        dialog.set_response_appearance("replace", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let input = self.input.clone();
        dialog.connect_response(None, move |_, response| {
            if response == "replace" {
                input.deliver(WorkspaceInput::ReplaceSavedQuery(query.clone()));
            }
        });
        dialog.present(self.dialog_parent().as_ref());
    }

    pub(super) fn save_named_query(&self, new_query: tablepro_storage::saved_queries::NewSavedQuery, replace: bool) {
        let name = new_query.name.clone();
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
            let saved = if replace {
                store.save(new_query).await.map(|outcome| outcome.replaced)
            } else {
                match store.save_if_new(new_query.clone()).await {
                    Ok(Some(_)) => Ok(false),
                    Ok(None) => {
                        input.deliver(WorkspaceInput::ConfirmReplaceSavedQuery(new_query));
                        return;
                    }
                    Err(error) => Err(error),
                }
            };
            let message = match saved {
                Ok(true) => crate::i18n::gettext_f("Replaced “{name}”.", &[("name", &name)]),
                Ok(false) => crate::i18n::gettext_f("Saved “{name}”.", &[("name", &name)]),
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
    fn open_quickly_closes_on_disconnect() {
        use gtk4::prelude::*;
        let test = TestWindow::connected("QuickOpenDisconnect");
        let dialog = test
            .workspace()
            .with_model(|model| {
                model.on_show_quick_open();
                model.quick_open_dialog.clone().expect("quick open")
            })
            .expect("workspace");
        wait_until(WAIT, || dialog.parent().is_some()).expect("shown");
        test.window.send(crate::ui::SessionWindowInput::Disconnect);
        wait_until(WAIT, || dialog.parent().is_none()).expect("dialog closed");
        wait_until(WAIT, || test.window.page_name() == "picker").expect("disconnected");
    }

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
    fn replacing_a_saved_query_needs_confirmation_and_keeps_its_id() {
        use crate::workspace::{answer, visible_alert};
        let test = TestWindow::connected("ConfirmSavedQuery");
        let availability = test.services.history().availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("history ready");
        let save = |sql: &str| {
            test.workspace()
                .with_model(|model| model.on_save_query_named("Orders".to_owned(), sql.to_owned()));
            wait_until(WAIT, || test.hold.live() == 0).expect("save complete");
        };
        let read = || {
            let store = test.services.history().store().expect("history").saved_queries();
            let reading = test.services.tasks.spawn_task(async move { store.list(None).await });
            finish_on_main(WAIT, reading)
                .expect("read complete")
                .expect("task")
                .expect("list")
                .remove(0)
        };
        save("SELECT 1");
        let original = read();
        save("SELECT 2");
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("replace prompt");
        answer(&test.window, "cancel");
        assert_eq!(read().query, "SELECT 1");
        save("SELECT 3");
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("replace prompt");
        answer(&test.window, "replace");
        wait_until(WAIT, || read().query == "SELECT 3").expect("replacement");
        assert_eq!(read().id, original.id);
    }

    #[gtk4::test]
    fn the_favorites_scope_lists_the_saved_queries_of_the_front_connection() {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        let test = TestWindow::connected("FavoritesScope");
        let history = test.services.history();
        let availability = history.availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("history ready");
        let shell = test.window.shell().expect("shell");
        let favorites = shell.imp().favorites.get().expect("favorites");
        shell.imp().scope_toggle.set_active_name(Some("favorites"));
        test.workspace()
            .with_model(|model| model.on_save_query_named("Orders".to_owned(), "SELECT 1".to_owned()));
        wait_until(WAIT, || favorites.names() == ["Orders"]).expect("saved query listed");
        let store = history.store().expect("history").saved_queries();
        let work = test.services.tasks.spawn_task(async move {
            let saved = store.list(None).await.expect("list");
            store.rename(saved[0].id, "Renamed").await.expect("rename");
        });
        finish_on_main(WAIT, work).expect("rename finished").expect("task");
        wait_until(WAIT, || favorites.names() == ["Renamed"]).expect("external rename listed");
        let store = history.store().expect("history").saved_queries();
        let work = test.services.tasks.spawn_task(async move {
            let saved = store.list(None).await.expect("list");
            store.delete(saved[0].id).await.expect("delete");
        });
        finish_on_main(WAIT, work).expect("delete finished").expect("task");
        wait_until(WAIT, || favorites.names().is_empty()).expect("external deletion listed");
    }

    #[gtk4::test]
    fn favorites_for_an_unsaved_file_survive_reopening_it() {
        use gtk4::{gio, subclass::prelude::ObjectSubclassIsExt};
        let test = TestWindow::picker("FileFavorites");
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("favorites.db");
        std::fs::write(&path, "").expect("database");
        let file = gio::File::for_path(path);
        test.window.send(crate::ui::SessionWindowInput::OpenFile(file.clone()));
        test.wait_for_page("workspace");
        let availability = test.services.history().availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("history ready");
        let connection = test.workspace().connection_id();
        test.workspace()
            .with_model(|model| model.on_save_query_named("File query".to_owned(), "SELECT 2".to_owned()));
        wait_until(WAIT, || test.hold.live() == 0).expect("save finished");
        test.window.send(crate::ui::SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        test.window.send(crate::ui::SessionWindowInput::OpenFile(file));
        test.wait_for_page("workspace");
        assert_eq!(test.workspace().connection_id(), connection);
        let shell = test.window.shell().expect("shell");
        shell.imp().scope_toggle.set_active_name(Some("favorites"));
        let favorites = shell.imp().favorites.get().expect("favorites");
        wait_until(WAIT, || favorites.names() == ["File query"]).expect("file query listed after reopen");
    }

    #[gtk4::test]
    fn a_favorite_is_renamed_and_deleted_from_the_list() {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;

        let test = TestWindow::connected("FavoritesChange");
        let availability = test.services.history().availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("the query database to open");
        let shell = test.window.shell().expect("the shell");
        let favorites = shell.imp().favorites.get().cloned().expect("the favorites pane");
        shell.imp().scope_toggle.set_active_name(Some("favorites"));
        test.workspace()
            .with_model(|model| model.on_save_query_named("Orders".to_owned(), "SELECT 1".to_owned()));
        wait_until(WAIT, || favorites.names() == ["Orders"]).expect("the saved query to be listed");
        let id = favorites.ids()[0];
        wait_until(WAIT, || test.hold.live() == 0).expect("save complete");

        shell.rename_favorite(id, "Weekly orders".to_owned());
        assert_eq!(test.hold.live(), 1);
        wait_until(WAIT, || favorites.names() == ["Weekly orders"]).expect("the new name to be listed");

        wait_until(WAIT, || test.hold.live() == 0).expect("rename complete");
        shell.delete_favorite(id);
        assert_eq!(test.hold.live(), 1);
        wait_until(WAIT, || favorites.names().is_empty()).expect("the favorite to go");
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
