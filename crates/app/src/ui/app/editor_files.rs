use relm4::ComponentSender;
use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tablepro_core::text_file::{TextFile, TextFileError};
use uuid::Uuid;

use crate::ui::editor::open_file::{choose_save_path, file_error_message, read_sql_file, save_sql_file};

use super::types::{EditorFile, WorkspaceTab};
use super::{App, AppMsg, dec_close_after_save};

const UNTITLED_FILE_NAME: &str = "query.sql";

impl App {
    pub(super) fn selected_editor_tab_id(&self) -> Option<Uuid> {
        let id = self.selected_workspace_tab_id()?;
        matches!(self.workspace_tabs.borrow().get(&id), Some(WorkspaceTab::Editor(_))).then_some(id)
    }

    pub(super) fn on_sql_file_opened(&mut self, file: TextFile, sender: ComponentSender<Self>) {
        self.append_editor_tab(Some(file.text.clone()), sender);
        let Some(id) = self.selected_editor_tab_id() else {
            return;
        };
        self.bind_editor_file(id, EditorFile::from_disk(file));
    }

    pub(super) fn restore_editor_file(&self, tab: Uuid, path: std::path::PathBuf, sender: ComponentSender<Self>) {
        std::thread::spawn(move || sender.input(AppMsg::EditorFileRestored(tab, read_sql_file(&path))));
    }

    pub(super) fn on_editor_file_restored(&self, tab: Uuid, outcome: Result<TextFile, String>) {
        match outcome {
            Ok(file) => self.bind_editor_file(tab, EditorFile::from_disk(file)),
            Err(message) => self.show_toast(
                &crate::tr!("A reopened tab is no longer linked to its file: {reason}").replace("{reason}", &message),
            ),
        }
    }

    pub(super) fn save_editor_file(&self, tab: Uuid, overwrite: bool, sender: ComponentSender<Self>) {
        let request = match self.workspace_tabs.borrow().get(&tab) {
            Some(WorkspaceTab::Editor(slot)) => slot
                .file
                .as_ref()
                .map(|file| (file.path.clone(), file.version.clone(), slot.query.clone())),
            _ => return,
        };
        let Some((path, version, text)) = request else {
            self.save_editor_file_as(tab, sender);
            return;
        };
        std::thread::spawn(move || {
            let expected = (!overwrite).then_some(&version);
            sender.input(save_outcome(tab, save_sql_file(&path, &text, expected)));
        });
    }

    pub(super) fn save_editor_file_as(&self, tab: Uuid, sender: ComponentSender<Self>) {
        let (suggested, text) = match self.workspace_tabs.borrow().get(&tab) {
            Some(WorkspaceTab::Editor(slot)) => (suggested_file_name(slot.file.as_ref()), slot.query.clone()),
            _ => return,
        };
        let parent = self.window.clone().upcast::<gtk::Window>();
        choose_save_path(Some(parent), &suggested, move |chosen| match chosen {
            Some(Ok(path)) => {
                std::thread::spawn(move || sender.input(save_outcome(tab, save_sql_file(&path, &text, None))));
            }
            Some(Err(message)) => sender.input(AppMsg::EditorFileSaveFailed(tab, message)),
            None => sender.input(AppMsg::EditorFileSaveCancelled(tab)),
        });
    }

    pub(super) fn on_editor_file_saved(&mut self, tab: Uuid, file: TextFile, sender: ComponentSender<Self>) {
        self.bind_editor_file(tab, EditorFile::from_disk(file));
        self.show_toast(&crate::tr!("Saved"));
        if matches!(
            self.workspace_tabs.borrow().get(&tab),
            Some(WorkspaceTab::Editor(slot)) if slot.has_unsaved_file_changes()
        ) {
            self.close_after_save.borrow_mut().remove(&tab);
            return;
        }
        if dec_close_after_save(&mut self.close_after_save.borrow_mut(), &tab) {
            sender.input(AppMsg::WorkspaceTabClosed(tab));
        }
    }

    pub(super) fn on_editor_file_save_failed(&self, tab: Uuid, message: &str) {
        self.close_after_save.borrow_mut().remove(&tab);
        self.show_toast(message);
    }

    pub(super) fn on_editor_file_save_cancelled(&self, tab: Uuid) {
        self.close_after_save.borrow_mut().remove(&tab);
    }

    pub(super) fn on_editor_file_changed_on_disk(&self, tab: Uuid, sender: ComponentSender<Self>) {
        let dialog = adw::AlertDialog::new(
            Some(&crate::tr!("The file changed on disk")),
            Some(&crate::tr!(
                "Another program changed or removed this file after it was opened. Overwriting replaces its changes with yours."
            )),
        );
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("save-as", &crate::tr!("Save As…"));
        dialog.add_response("overwrite", &crate::tr!("Overwrite"));
        dialog.set_response_appearance("overwrite", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.connect_response(None, move |_, response| match response {
            "overwrite" => sender.input(AppMsg::SaveEditorFile { tab, overwrite: true }),
            "save-as" => sender.input(AppMsg::SaveEditorFileAs(tab)),
            _ => sender.input(AppMsg::EditorFileSaveCancelled(tab)),
        });
        dialog.present(Some(&self.window));
    }

    pub(super) fn refresh_editor_file_title(slot: &super::types::EditorTabSlot) {
        let Some(file) = slot.file.as_ref() else {
            return;
        };
        slot.page.set_title(&file.title(&slot.query));
        slot.page.set_tooltip(&file.path.display().to_string());
    }

    fn bind_editor_file(&self, tab: Uuid, file: EditorFile) {
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow_mut().get_mut(&tab) {
            slot.file = Some(file);
            Self::refresh_editor_file_title(slot);
        }
    }
}

fn save_outcome(tab: Uuid, outcome: Result<TextFile, TextFileError>) -> AppMsg {
    match outcome {
        Ok(file) => AppMsg::EditorFileSaved(tab, file),
        Err(TextFileError::Changed) => AppMsg::EditorFileChangedOnDisk(tab),
        Err(error) => AppMsg::EditorFileSaveFailed(tab, file_error_message(&error)),
    }
}

fn suggested_file_name(file: Option<&EditorFile>) -> String {
    file.and_then(|file| file.path.file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| UNTITLED_FILE_NAME.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opened(text: &str) -> (tempfile::TempDir, EditorFile) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("report.sql");
        std::fs::write(&path, text).unwrap();
        let file = tablepro_core::text_file::read_text_file(&path, 1024).unwrap();
        (directory, EditorFile::from_disk(file))
    }

    #[test]
    fn a_file_tab_is_titled_by_its_file_name_and_marked_while_it_differs_from_disk() {
        let (_directory, file) = opened("SELECT 1;");

        assert_eq!(file.title("SELECT 1;"), "report.sql");
        assert_eq!(file.title("SELECT 2;"), "• report.sql");
    }

    #[test]
    fn save_as_suggests_the_current_file_name_or_a_default() {
        let (_directory, file) = opened("SELECT 1;");

        assert_eq!(suggested_file_name(Some(&file)), "report.sql");
        assert_eq!(suggested_file_name(None), UNTITLED_FILE_NAME);
    }

    #[test]
    fn a_changed_file_asks_the_user_instead_of_reporting_a_failure() {
        let tab = Uuid::new_v4();

        assert!(matches!(
            save_outcome(tab, Err(TextFileError::Changed)),
            AppMsg::EditorFileChangedOnDisk(id) if id == tab
        ));
        assert!(matches!(
            save_outcome(tab, Err(TextFileError::NotText)),
            AppMsg::EditorFileSaveFailed(id, _) if id == tab
        ));
    }
}
