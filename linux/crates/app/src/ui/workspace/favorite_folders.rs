use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::{AdwDialogExt, AlertDialogExt, PreferencesGroupExt};
use tablepro_storage::StorageError;
use tablepro_storage::saved_queries::{SavedQuery, SavedQueryFolder};
use uuid::Uuid;

use super::WorkspaceShell;
use crate::i18n::{gettext, gettext_f};

impl WorkspaceShell {
    pub(crate) fn move_favorite(&self, id: i64, folder: Option<i64>) {
        self.change_favorites_with(
            async move |history| history.saved_queries().set_folder(id, folder).await,
            gettext("Could not move that saved query."),
            move_failure_text,
        );
    }

    #[cfg(test)]
    pub(crate) fn create_folder(&self, name: String, parent: Option<i64>) {
        if let Some(connection) = self.front().and_then(|front| front.connection_id()) {
            self.create_folder_for(connection, name, parent);
        }
    }

    fn create_folder_for(&self, connection: Uuid, name: String, parent: Option<i64>) {
        self.change_favorites_with(
            async move |history| {
                history
                    .saved_query_folders()
                    .create(connection, &name, parent)
                    .await
                    .map(drop)
            },
            gettext("Could not create that folder."),
            folder_failure_text,
        );
    }

    fn rename_folder(&self, id: i64, name: String) {
        self.change_favorites_with(
            async move |history| history.saved_query_folders().rename(id, &name).await,
            gettext("Could not rename that folder."),
            folder_failure_text,
        );
    }

    pub(crate) fn delete_folder(&self, id: i64) {
        self.change_favorites_with(
            async move |history| history.saved_query_folders().delete(id).await,
            gettext("Could not delete that folder."),
            folder_failure_text,
        );
    }

    pub(super) fn ask_folder_name(&self, parent: Option<SavedQueryFolder>, rename: Option<SavedQueryFolder>) {
        let Some(connection) = rename
            .as_ref()
            .or(parent.as_ref())
            .map(|folder| folder.connection_id)
            .or_else(|| self.front().and_then(|front| front.connection_id()))
        else {
            return;
        };
        let title = match (&rename, &parent) {
            (Some(_), _) => gettext("Rename Folder"),
            (None, Some(_)) => gettext("New Subfolder"),
            (None, None) => gettext("New Folder"),
        };
        let verb = if rename.is_some() {
            gettext("Rename")
        } else {
            gettext("Create")
        };
        let dialog = adw::AlertDialog::new(Some(&title), None);
        let entry = adw::EntryRow::builder()
            .title(gettext("Name"))
            .activates_default(true)
            .build();
        if let Some(folder) = &rename {
            entry.set_text(&folder.name);
        }
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", &gettext("Cancel"));
        dialog.add_response("ok", &verb);
        dialog.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("ok"));
        dialog.set_close_response("cancel");
        crate::ui::name_entry::require_name(&dialog, "ok", &entry);
        dialog.set_focus(Some(&entry));
        let shell = self.downgrade();
        dialog.connect_response(None, move |_, response| {
            let name = entry.text().trim().to_owned();
            let Some(shell) = shell.upgrade().filter(|_| response == "ok" && !name.is_empty()) else {
                return;
            };
            match &rename {
                Some(folder) if name != folder.name => shell.rename_folder(folder.id, name),
                Some(_) => {}
                None => shell.create_folder_for(connection, name, parent.as_ref().map(|folder| folder.id)),
            }
        });
        dialog.present(self.imp().window.upgrade().as_ref());
    }

    pub(super) fn ask_folder_deletion(&self, folder: SavedQueryFolder) {
        let dialog = adw::AlertDialog::new(
            Some(&gettext_f("Delete “{name}”?", &[("name", &folder.name)])),
            Some(&gettext(
                "This folder and its subfolders will be deleted. Their saved queries will move to the top level.",
            )),
        );
        dialog.add_response("cancel", &gettext("Cancel"));
        dialog.add_response("delete", &gettext("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let shell = self.downgrade();
        dialog.connect_response(None, move |_, response| {
            if let (true, Some(shell)) = (response == "delete", shell.upgrade()) {
                shell.delete_folder(folder.id);
            }
        });
        dialog.present(self.imp().window.upgrade().as_ref());
    }

    pub(super) fn ask_folder_for(&self, favorite: SavedQuery) {
        let Some(pane) = self.imp().favorites.get() else {
            return;
        };
        let folders = pane.folder_destinations();
        let top = gettext("No Folder");
        let names: Vec<&str> = std::iter::once(top.as_str())
            .chain(folders.iter().map(|(_, path)| path.as_str()))
            .collect();
        let choice = gtk::DropDown::from_strings(&names);
        choice.set_enable_search(true);
        choice.update_property(&[gtk::accessible::Property::Label(&gettext("Folder"))]);
        let at = match favorite.folder_id {
            None => 0,
            Some(id) => folders
                .iter()
                .position(|(held, _)| *held == id)
                .and_then(|position| u32::try_from(position + 1).ok())
                .unwrap_or(gtk::INVALID_LIST_POSITION),
        };
        choice.set_selected(at);
        choice.set_tooltip_text(names.get(at as usize).copied());
        let dialog = adw::AlertDialog::new(Some(&gettext_f("Move “{name}”", &[("name", &favorite.name)])), None);
        dialog.set_extra_child(Some(&choice));
        dialog.add_response("cancel", &gettext("Cancel"));
        dialog.add_response("move", &gettext("Move"));
        dialog.set_response_appearance("move", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("move"));
        dialog.set_close_response("cancel");
        dialog.set_response_enabled("move", false);
        choice.connect_selected_notify(gtk::glib::clone!(
            #[weak]
            dialog,
            move |choice| {
                dialog.set_response_enabled(
                    "move",
                    choice.selected() != gtk::INVALID_LIST_POSITION && choice.selected() != at,
                );
                let label = choice
                    .selected_item()
                    .and_downcast::<gtk::StringObject>()
                    .map(|item| item.string());
                choice.set_tooltip_text(label.as_deref());
            }
        ));
        dialog.set_focus(Some(&choice));
        let shell = self.downgrade();
        dialog.connect_response(None, move |_, response| {
            let Some(shell) = shell.upgrade().filter(|_| response == "move") else {
                return;
            };
            let Some(folder) = destination(&folders, choice.selected()) else {
                return;
            };
            if folder != favorite.folder_id {
                shell.move_favorite(favorite.id, folder);
            }
        });
        dialog.present(self.imp().window.upgrade().as_ref());
    }
}

fn destination(folders: &[(i64, String)], selected: u32) -> Option<Option<i64>> {
    if selected == 0 {
        Some(None)
    } else {
        folders.get(selected as usize - 1).map(|(id, _)| Some(*id))
    }
}

fn folder_failure_text(error: &StorageError, fallback: &str) -> String {
    match error {
        StorageError::FolderNameTaken => gettext("That name is already used by another folder in the same place."),
        StorageError::FolderNameInvalid => gettext("Folder names cannot contain control characters."),
        StorageError::TooLarge { .. } => gettext("That folder name is too long."),
        StorageError::EmptyName => gettext("Enter a name for the folder."),
        StorageError::FolderCycle { .. } => gettext("A folder cannot be moved inside itself or one of its subfolders."),
        StorageError::NotFound => gettext("That folder was deleted elsewhere."),
        StorageError::NotInitialised => gettext("Favorites are unavailable. Restart TablePro to try again."),
        _ => fallback.to_owned(),
    }
}

fn move_failure_text(error: &StorageError, fallback: &str) -> String {
    match error {
        StorageError::NotFound => gettext("The saved query or destination folder was deleted elsewhere."),
        StorageError::NotInitialised => gettext("Favorites are unavailable. Restart TablePro to try again."),
        _ => fallback.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{descendants, finish_on_main, wait_until};
    use crate::ui::session_window::tests::{TestWindow, WAIT};
    use crate::workspace::{answer, visible_alert};

    fn ready(test: &TestWindow) -> tablepro_storage::QueryHistory {
        let availability = test.services.history().availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("history ready");
        wait_until(WAIT, || test.hold.live() == 0).expect("initial work finished");
        test.services.history().store().expect("history")
    }

    fn folders(test: &TestWindow, owner: Uuid) -> Vec<SavedQueryFolder> {
        let history = test.services.history().store().expect("history");
        let task = test
            .services
            .tasks
            .spawn_task(async move { history.saved_query_folders().list(owner).await });
        finish_on_main(WAIT, task)
            .expect("read finished")
            .expect("task")
            .expect("folders")
    }

    #[gtk4::test]
    fn a_folder_write_keeps_its_hold_after_the_window_closes() {
        let test = TestWindow::connected("FolderWriteClosed");
        ready(&test);
        let owner = test.workspace().connection_id().expect("owner");
        let shell = test.window.shell().expect("shell");
        let (release, released) = tokio::sync::oneshot::channel();
        shell.change_favorites_with(
            move |history| async move {
                released.await.expect("release write");
                history
                    .saved_query_folders()
                    .create(owner, "Reports", None)
                    .await
                    .map(drop)
            },
            "Create failed".to_owned(),
            folder_failure_text,
        );
        assert_eq!(test.hold.live(), 1);
        let held = test.hold_tokens.borrow().last().expect("folder hold").clone();
        test.window.close();
        wait_until(WAIT, || !test.window.is_visible()).expect("window closed");
        assert!(held.upgrade().is_some());
        release.send(()).expect("write still waiting");
        wait_until(WAIT, || held.upgrade().is_none()).expect("folder write finished");
        assert_eq!(folders(&test, owner)[0].name, "Reports");
    }

    #[gtk4::test]
    fn a_new_folder_dialog_keeps_the_connection_it_opened_for() {
        let test = TestWindow::connected("FolderCapturedOwner");
        ready(&test);
        let owner = test.workspace().connection_id().expect("owner");
        let shell = test.window.shell().expect("shell");
        shell.ask_folder_name(None, None);
        let dialog = visible_alert(&test.window).expect("new folder prompt");
        let entry = descendants(&dialog)
            .into_iter()
            .find_map(|widget| widget.downcast::<adw::EntryRow>().ok())
            .expect("entry");
        assert!(!dialog.is_response_enabled("ok"));
        entry.set_text("Reports");
        assert!(dialog.is_response_enabled("ok"));
        shell.imp().front.replace(None);
        shell.reload_favorites();
        answer(&test.window, "ok");
        assert_eq!(test.hold.live(), 1);
        wait_until(WAIT, || test.hold.live() == 0).expect("create finished");
        let saved = folders(&test, owner);
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].name, "Reports");
        assert_eq!(saved[0].connection_id, owner);
    }

    #[gtk4::test]
    fn choosing_the_current_destination_does_not_reorder_the_query() {
        let test = TestWindow::connected("FolderMoveUnchanged");
        let history = ready(&test);
        let owner = test.workspace().connection_id().expect("owner");
        let task = test.services.tasks.spawn_task(async move {
            let store = history.saved_queries();
            for name in ["First", "Second"] {
                store
                    .save(tablepro_storage::saved_queries::NewSavedQuery {
                        name: name.to_owned(),
                        query: "SELECT 1".to_owned(),
                        connection_id: owner,
                        connection_name: "local".to_owned(),
                    })
                    .await
                    .expect("save");
            }
            store.snapshot(owner).await.expect("snapshot")
        });
        let before = finish_on_main(WAIT, task).expect("read finished").expect("task");
        let favorite = before.queries[0].clone();
        let shell = test.window.shell().expect("shell");
        shell.imp().favorites.get().expect("pane").show(before.clone());
        let history = test.services.history().store().expect("history");
        let changes = history.saved_queries().changes();
        shell.ask_folder_for(favorite.clone());
        let dialog = visible_alert(&test.window).expect("move prompt");
        assert!(!dialog.is_response_enabled("move"));
        answer(&test.window, "move");
        assert_eq!(test.hold.live(), 0);
        assert!(!changes.has_changed().expect("no change"));
        shell.move_favorite(favorite.id, None);
        wait_until(WAIT, || test.hold.live() == 0).expect("no-op finished");
        let task = test
            .services
            .tasks
            .spawn_task(async move { history.saved_queries().snapshot(owner).await });
        let after = finish_on_main(WAIT, task)
            .expect("read finished")
            .expect("task")
            .expect("snapshot");
        assert_eq!(after, before);
        assert!(!changes.has_changed().expect("no revision"));
    }

    #[gtk4::test]
    fn folder_deletion_requires_confirmation_and_preserves_queries() {
        let test = TestWindow::connected("FolderDeleteConfirmed");
        let history = ready(&test);
        let owner = test.workspace().connection_id().expect("owner");
        let task = test.services.tasks.spawn_task(async move {
            let folders = history.saved_query_folders();
            let parent = folders.create(owner, "Reports", None).await.expect("parent");
            let child = folders.create(owner, "Monthly", Some(parent)).await.expect("child");
            let saved = history
                .saved_queries()
                .save(tablepro_storage::saved_queries::NewSavedQuery {
                    name: "Report".to_owned(),
                    query: "SELECT 1".to_owned(),
                    connection_id: owner,
                    connection_name: "local".to_owned(),
                })
                .await
                .expect("save");
            history
                .saved_queries()
                .move_to_folder(saved.id, Some(child), None)
                .await
                .expect("file");
            folders
                .list(owner)
                .await
                .expect("folders")
                .into_iter()
                .find(|folder| folder.id == parent)
                .expect("parent")
        });
        let parent = finish_on_main(WAIT, task).expect("read finished").expect("task");
        let shell = test.window.shell().expect("shell");
        shell.ask_folder_deletion(parent.clone());
        let dialog = visible_alert(&test.window).expect("delete prompt");
        assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
        assert_eq!(
            dialog.response_appearance("delete"),
            adw::ResponseAppearance::Destructive
        );
        answer(&test.window, "cancel");
        wait_until(WAIT, || visible_alert(&test.window).is_none()).expect("cancelled");
        assert_eq!(folders(&test, owner).len(), 2);
        shell.ask_folder_deletion(parent);
        answer(&test.window, "delete");
        assert_eq!(test.hold.live(), 1);
        wait_until(WAIT, || test.hold.live() == 0).expect("deleted");
        assert!(folders(&test, owner).is_empty());
        let history = test.services.history().store().expect("history");
        let task = test
            .services
            .tasks
            .spawn_task(async move { history.saved_queries().list(Some(owner)).await });
        let saved = finish_on_main(WAIT, task)
            .expect("read finished")
            .expect("task")
            .expect("queries");
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].query, "SELECT 1");
        assert_eq!(saved[0].folder_id, None);
    }

    #[test]
    fn a_destination_never_converts_an_invalid_selection_into_the_root() {
        let choices = vec![(42, "/No Folder".to_owned()), (7, "/Reports/Monthly".to_owned())];
        assert_eq!(destination(&choices, 0), Some(None));
        assert_eq!(destination(&choices, 1), Some(Some(42)));
        assert_eq!(destination(&choices, 2), Some(Some(7)));
        assert_eq!(destination(&choices, 3), None);
        assert_eq!(destination(&choices, gtk::INVALID_LIST_POSITION), None);
    }

    #[test]
    fn folder_and_move_failures_name_the_missing_record() {
        assert_eq!(
            folder_failure_text(&StorageError::NotFound, "fallback"),
            "That folder was deleted elsewhere."
        );
        assert_eq!(
            move_failure_text(&StorageError::NotFound, "fallback"),
            "The saved query or destination folder was deleted elsewhere."
        );
        assert_eq!(
            folder_failure_text(&StorageError::FolderNameTaken, "fallback"),
            "That name is already used by another folder in the same place."
        );
    }
}
