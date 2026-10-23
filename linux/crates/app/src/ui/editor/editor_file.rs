//! The `.sql` file an editor tab is opened from or saved to.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;

use super::{SqlEditor, buffer_text, export_name_for_query};

impl SqlEditor {
    /// The file the tab's text is saved to, once it was opened from or
    /// saved to one.
    pub(crate) fn file(&self) -> Option<gio::File> {
        self.imp().file.borrow().clone()
    }

    /// Whether the text differs from what the tab's file last held.
    pub(crate) fn has_unsaved_file_changes(&self) -> bool {
        self.imp().file.borrow().is_some() && self.buffer().is_modified()
    }

    /// Point a restored tab at its file again, with its text changed
    /// since the last save or not.
    pub(crate) fn restore_file(&self, file: gio::File, modified: bool) {
        self.imp().file.replace(Some(file));
        self.buffer().set_modified(modified);
        self.emit_by_name::<()>("file-changed", &[]);
    }

    /// A file or its changed state changed.
    pub(crate) fn connect_file_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "file-changed",
            false,
            glib::closure_local!(move |editor: &Self| f(editor)),
        )
    }

    /// The buffer's own modified flag says whether the text changed
    /// since the file was read or written; Undo back to that point
    /// clears it again.
    pub(super) fn follow_file_state(&self, buffer: &sourceview5::Buffer) {
        let weak = self.downgrade();
        buffer.connect_modified_changed(move |_| {
            if let Some(editor) = weak.upgrade()
                && editor.imp().file.borrow().is_some()
            {
                editor.emit_by_name::<()>("file-changed", &[]);
            }
        });
        let weak = self.downgrade();
        buffer.connect_changed(move |_| {
            if let Some(editor) = weak.upgrade() {
                let edits = &editor.imp().edits;
                edits.set(edits.get().wrapping_add(1));
            }
        });
    }

    /// The text now came whole from `file`.
    pub(super) fn opened_file(&self, file: gio::File) {
        self.imp().file.replace(Some(file));
        self.buffer().set_modified(false);
        self.emit_by_name::<()>("file-changed", &[]);
    }

    /// Ctrl+S: write to the tab's file, or ask for one.
    pub(super) fn save(&self) {
        self.save_then(|_| {});
    }

    /// A cancelled choice or a failed write skips `then`.
    pub(super) fn save_then(&self, then: impl FnOnce(&SqlEditor) + 'static) {
        let weak = self.downgrade();
        let file = self.file();
        let chosen = file.is_none().then(|| self.choose_save_file());
        glib::spawn_future_local(async move {
            let file = match (file, chosen) {
                (Some(file), _) => Some(file),
                (None, Some(chosen)) => chosen.await,
                (None, None) => None,
            };
            let (Some(file), Some(editor)) = (file, weak.upgrade()) else {
                return;
            };
            if editor.write_reporting(&file).await {
                then(&editor);
            }
        });
    }

    /// Ctrl+Shift+S: ask where to write, starting from the tab's file.
    pub(super) fn save_as(&self) {
        let weak = self.downgrade();
        let chosen = self.choose_save_file();
        glib::spawn_future_local(async move {
            if let (Some(file), Some(editor)) = (chosen.await, weak.upgrade()) {
                editor.write_reporting(&file).await;
            }
        });
    }

    /// Holds only the dialog's window while it is open.
    fn choose_save_file(&self) -> impl Future<Output = Option<gio::File>> + use<> {
        let filter = sql_filter();
        let filters = gio::ListStore::new::<gtk4::FileFilter>();
        filters.append(&filter);
        let dialog = gtk4::FileDialog::builder()
            .title(crate::i18n::gettext("Save SQL File"))
            .modal(true)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        match self.file() {
            Some(file) => dialog.set_initial_file(Some(&file)),
            None => dialog.set_initial_name(Some(&suggested_file_name(&buffer_text(&self.buffer())))),
        }
        let parent = self.root().and_downcast::<gtk4::Window>();
        async move { dialog.save_future(parent.as_ref()).await.ok() }
    }

    /// Write the text to the tab's file, for a close that chose Save.
    /// The error is the sentence to show.
    pub(crate) fn save_to_file(&self) -> impl Future<Output = Result<(), String>> + use<> {
        let editor = self.clone();
        async move {
            match editor.file() {
                Some(file) => editor.write_to(&file).await,
                None => Ok(()),
            }
        }
    }

    /// Whether the text landed in `file`; an alert says why it did not.
    pub(super) async fn write_reporting(&self, file: &gio::File) -> bool {
        match self.write_to(file).await {
            Ok(()) => true,
            Err(message) => {
                self.alert_save_failed(&message);
                false
            }
        }
    }

    /// Text typed while the write runs is not in the file, so the tab
    /// stays changed.
    async fn write_to(&self, file: &gio::File) -> Result<(), String> {
        let imp = self.imp();
        if imp.saving.replace(true) {
            return Err(crate::i18n::gettext("This tab is already being saved."));
        }
        let buffer = self.buffer();
        let edits = imp.edits.get();
        let written = crate::ui::file_write::replace_file(file, buffer_text(&buffer).into_bytes()).await;
        imp.saving.set(false);
        if let Err(error) = written {
            tracing::warn!(%error, "could not save an editor tab to its file");
            return Err(crate::i18n::gettext_f(
                "“{name}” could not be saved: {error}",
                &[("name", &file_name(file)), ("error", error.message())],
            ));
        }
        imp.file.replace(Some(file.clone()));
        if imp.edits.get() == edits {
            buffer.set_modified(false);
        }
        self.emit_by_name::<()>("file-changed", &[]);
        Ok(())
    }

    fn alert_save_failed(&self, message: &str) {
        let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Could Not Save File")), Some(message));
        dialog.add_response("close", &crate::i18n::gettext("_Close"));
        dialog.set_default_response(Some("close"));
        dialog.set_close_response("close");
        dialog.present(Some(self));
    }
}

pub(super) fn sql_filter() -> gtk4::FileFilter {
    let filter = gtk4::FileFilter::new();
    filter.set_name(Some(&crate::i18n::gettext("SQL files")));
    filter.add_suffix("sql");
    filter.add_mime_type("application/sql");
    filter
}

/// What a tab bound to `file` is called.
pub(crate) fn file_name(file: &gio::File) -> String {
    file.basename()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.parse_name().to_string())
}

/// A file name for a tab that has none, from its first statement.
fn suggested_file_name(text: &str) -> String {
    let stem = match text.trim().is_empty() {
        true => crate::i18n::gettext("query"),
        false => export_name_for_query(text),
    };
    format!("{stem}.sql")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_file_is_named_after_its_first_statement() {
        assert_eq!(suggested_file_name("SELECT * FROM users;"), "select-from-users.sql");
        assert_eq!(suggested_file_name("  \n"), "query.sql");
    }

    #[gtk4::test]
    fn a_file_is_named_by_its_last_part() {
        assert_eq!(file_name(&gio::File::for_path("/tmp/reports/daily.sql")), "daily.sql");
    }
}
