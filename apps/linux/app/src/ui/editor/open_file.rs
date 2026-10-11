use relm4::gtk;
use relm4::gtk::prelude::*;
use tablepro_core::text_file::{FileVersion, TextFile, TextFileError, read_text_file, save_text_file};

use super::MAX_SQL_FILE_BYTES;

pub(crate) fn read_sql_file(path: &std::path::Path) -> Result<TextFile, String> {
    read_text_file(path, MAX_SQL_FILE_BYTES).map_err(|error| file_error_message(&error))
}

pub(crate) fn save_sql_file(
    path: &std::path::Path,
    text: &str,
    expected: Option<&FileVersion>,
) -> Result<TextFile, TextFileError> {
    if text.len() as u64 > MAX_SQL_FILE_BYTES {
        return Err(TextFileError::TooLarge(MAX_SQL_FILE_BYTES));
    }
    save_text_file(path, text, expected)
}

pub(crate) fn file_error_message(error: &TextFileError) -> String {
    match error {
        TextFileError::Changed => crate::tr!("The file changed on disk"),
        TextFileError::TooLarge(_) => crate::tr!("The SQL file is too large"),
        TextFileError::NotText => crate::tr!("The SQL file is not valid UTF-8"),
        TextFileError::Io(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            crate::tr!("You don't have permission to use that file")
        }
        TextFileError::Io(_) => crate::tr!("Couldn't read or write the SQL file"),
    }
}

fn sql_filters() -> gtk::gio::ListStore {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::tr!("SQL files")));
    filter.add_pattern("*.sql");
    filter.add_mime_type("application/sql");
    filter.add_mime_type("text/x-sql");
    let filters = gtk::gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    filters
}

fn sql_file_dialog(title: &str) -> gtk::FileDialog {
    let dialog = gtk::FileDialog::builder().title(title).modal(true).build();
    let filters = sql_filters();
    let default = filters.item(0).and_downcast::<gtk::FileFilter>();
    dialog.set_filters(Some(&filters));
    dialog.set_default_filter(default.as_ref());
    dialog
}

pub(crate) fn choose_sql_file<F>(parent: Option<gtk::Window>, done: F)
where
    F: FnOnce(Result<TextFile, String>) + 'static,
{
    let dialog = sql_file_dialog(&crate::tr!("Open SQL file"));
    dialog.open(parent.as_ref(), gtk::gio::Cancellable::NONE, move |result| {
        let Ok(file) = result else {
            return;
        };
        let Some(path) = file.path() else {
            done(Err(crate::tr!("That file is not on this computer")));
            return;
        };
        let (tx, rx) = async_channel::bounded(1);
        std::thread::spawn(move || {
            let _ = tx.send_blocking(read_sql_file(&path));
        });
        relm4::spawn_local(async move {
            if let Ok(outcome) = rx.recv().await {
                done(outcome);
            }
        });
    });
}

pub(crate) fn choose_save_path<F>(parent: Option<gtk::Window>, suggested_name: &str, done: F)
where
    F: FnOnce(Option<Result<std::path::PathBuf, String>>) + 'static,
{
    let dialog = sql_file_dialog(&crate::tr!("Save SQL file"));
    dialog.set_initial_name(Some(suggested_name));
    dialog.save(parent.as_ref(), gtk::gio::Cancellable::NONE, move |result| {
        let Ok(file) = result else {
            done(None);
            return;
        };
        match file.path() {
            Some(path) => done(Some(Ok(path))),
            None => done(Some(Err(crate::tr!("That file is not on this computer")))),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn written(bytes: &[u8]) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("script.sql");
        let mut file = std::fs::File::create(&path).expect("create");
        file.write_all(bytes).expect("write");
        (dir, path)
    }

    #[test]
    fn a_chosen_sql_file_is_read_as_text() {
        let (_dir, path) = written(b"SELECT 1;\n");

        assert_eq!(read_sql_file(&path).unwrap().text, "SELECT 1;\n");
    }

    #[test]
    fn a_file_over_the_size_limit_is_refused_rather_than_truncated() {
        let oversized = vec![b'-'; (MAX_SQL_FILE_BYTES + 1) as usize];
        let (_dir, path) = written(&oversized);

        let error = read_sql_file(&path).unwrap_err();

        assert!(error.contains("too large"), "{error}");
    }

    #[test]
    fn a_file_that_is_not_text_is_refused() {
        let (_dir, path) = written(&[0xff, 0xfe, 0x00]);

        assert!(read_sql_file(&path).is_err());
    }

    #[test]
    fn a_draft_over_the_size_limit_is_not_saved() {
        let (_dir, path) = written(b"SELECT 1;\n");
        let oversized = "-".repeat((MAX_SQL_FILE_BYTES + 1) as usize);

        let error = save_sql_file(&path, &oversized, None).unwrap_err();

        assert!(matches!(error, TextFileError::TooLarge(_)));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "SELECT 1;\n");
    }
}
