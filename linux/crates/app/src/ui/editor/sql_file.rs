use gtk4::glib;

use crate::ui::file_read::{FileReadError, read_capped_file};

/// The most a file may be before the editor refuses it.
///
/// A dump can be gigabytes, and a text buffer holding one stops being
/// an editor. Refusing is better than a window that will not paint.
const MAX_SQL_FILE_BYTES: usize = 8 * 1024 * 1024;

/// Read a file as text off the main thread, or say why it cannot be.
pub async fn load_text(file: &gio::File) -> Result<String, String> {
    let bytes = match read_capped_file(file, MAX_SQL_FILE_BYTES).await {
        Ok(bytes) => bytes,
        Err(FileReadError::NotRegular) => {
            return Err(crate::i18n::gettext("Only regular files can be opened in the editor."));
        }
        Err(FileReadError::TooLarge) => {
            return Err(crate::i18n::gettext("That file is too large to open in the editor."));
        }
        Err(FileReadError::Io(error)) => return Err(unreadable(error)),
    };
    String::from_utf8(bytes).map_err(|_| crate::i18n::gettext("That file is not UTF-8 text."))
}

fn unreadable(error: glib::Error) -> String {
    tracing::warn!(%error, "could not read a file for the editor");
    crate::i18n::gettext("That file could not be read.")
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::test_support::finish_on_main;

    const WAIT: Duration = Duration::from_secs(10);

    fn load(file: gio::File) -> Result<String, String> {
        finish_on_main(WAIT, async move { load_text(&file).await }).expect("the load to end")
    }

    #[gtk4::test]
    fn a_device_is_refused_before_it_is_read() {
        let refused = load(gio::File::for_path("/dev/zero")).expect_err("a refusal");

        assert!(refused.contains("regular files"), "{refused}");
    }

    #[gtk4::test]
    fn a_pipe_is_refused_without_waiting_for_a_writer() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("script.sql");
        let made = std::process::Command::new("mkfifo")
            .arg(&path)
            .status()
            .expect("mkfifo");
        assert!(made.success());

        let refused = load(gio::File::for_path(&path)).expect_err("a refusal");

        assert!(refused.contains("regular files"), "{refused}");
    }

    #[gtk4::test]
    fn a_file_over_the_limit_is_refused() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("dump.sql");
        std::fs::write(&path, vec![b' '; MAX_SQL_FILE_BYTES + 1]).expect("write");

        let refused = load(gio::File::for_path(&path)).expect_err("a refusal");

        assert!(refused.contains("too large"), "{refused}");
    }

    #[gtk4::test]
    fn a_small_file_is_read_as_text() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("query.sql");
        std::fs::write(&path, "SELECT 'tên';").expect("write");

        assert_eq!(load(gio::File::for_path(&path)).as_deref(), Ok("SELECT 'tên';"));
    }
}
