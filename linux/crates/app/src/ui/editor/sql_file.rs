use gtk4::glib;
use gtk4::prelude::*;

/// The most a file may be before the editor refuses it.
///
/// A dump can be gigabytes, and a text buffer holding one stops being
/// an editor. Refusing is better than a window that will not paint.
const MAX_SQL_FILE_BYTES: usize = 8 * 1024 * 1024;

const READ_CHUNK_BYTES: usize = 256 * 1024;

#[derive(Debug)]
enum ReadError {
    TooLarge,
    Io(glib::Error),
}

/// Read a file as text off the main thread, or say why it cannot be.
pub async fn load_text(file: &gio::File) -> Result<String, String> {
    let info = file
        .query_info_future(
            "standard::type,standard::size",
            gio::FileQueryInfoFlags::NONE,
            glib::Priority::DEFAULT,
        )
        .await;
    if let Ok(info) = info {
        // Opening a pipe waits for a writer that may never come, and a
        // device has no end to read to.
        if info.has_attribute(gio::FILE_ATTRIBUTE_STANDARD_TYPE) && info.file_type() == gio::FileType::Special {
            return Err(crate::i18n::gettext("Only regular files can be opened in the editor."));
        }
        if info.has_attribute(gio::FILE_ATTRIBUTE_STANDARD_SIZE)
            && u64::try_from(info.size()).is_ok_and(|size| size > MAX_SQL_FILE_BYTES as u64)
        {
            return Err(too_large());
        }
    }
    let stream = file.read_future(glib::Priority::DEFAULT).await.map_err(unreadable)?;
    let read = read_capped(stream.upcast_ref(), MAX_SQL_FILE_BYTES).await;
    if let Err(error) = stream.close_future(glib::Priority::DEFAULT).await {
        tracing::debug!(%error, "closing a file the editor read failed");
    }
    let bytes = match read {
        Ok(bytes) => bytes,
        Err(ReadError::TooLarge) => return Err(too_large()),
        Err(ReadError::Io(error)) => return Err(unreadable(error)),
    };
    String::from_utf8(bytes).map_err(|_| crate::i18n::gettext("That file is not UTF-8 text."))
}

/// Read to the end of the stream, giving up once it passes `limit`.
///
/// The size a file reports is not enough: a remote file may report
/// none, and a file can grow between being measured and being read.
async fn read_capped(stream: &gio::InputStream, limit: usize) -> Result<Vec<u8>, ReadError> {
    let mut contents = Vec::new();
    loop {
        let chunk = stream
            .read_bytes_future(READ_CHUNK_BYTES, glib::Priority::DEFAULT)
            .await
            .map_err(ReadError::Io)?;
        if chunk.is_empty() {
            return Ok(contents);
        }
        if contents.len() + chunk.len() > limit {
            return Err(ReadError::TooLarge);
        }
        contents.extend_from_slice(&chunk);
    }
}

fn too_large() -> String {
    crate::i18n::gettext("That file is too large to open in the editor.")
}

fn unreadable(error: glib::Error) -> String {
    tracing::warn!(%error, "could not read a file for the editor");
    crate::i18n::gettext("That file could not be read.")
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(10);

    fn load(file: gio::File) -> Result<String, String> {
        let outcome = std::rc::Rc::new(std::cell::RefCell::new(None));
        let slot = outcome.clone();
        glib::spawn_future_local(async move {
            let loaded = load_text(&file).await;
            slot.replace(Some(loaded));
        });
        wait_until(WAIT, || outcome.borrow().is_some()).expect("the load to end");
        outcome.take().expect("an outcome")
    }

    fn capped(bytes: Vec<u8>, limit: usize) -> Result<Vec<u8>, ReadError> {
        let stream = gio::MemoryInputStream::from_bytes(&glib::Bytes::from_owned(bytes));
        let outcome = std::rc::Rc::new(std::cell::RefCell::new(None));
        let slot = outcome.clone();
        glib::spawn_future_local(async move {
            let read = read_capped(stream.upcast_ref(), limit).await;
            slot.replace(Some(read));
        });
        wait_until(WAIT, || outcome.borrow().is_some()).expect("the read to end");
        outcome.take().expect("an outcome")
    }

    #[gtk4::test]
    fn a_stream_past_the_limit_is_refused_without_a_reported_size() {
        let read = capped(vec![b'x'; READ_CHUNK_BYTES * 3], READ_CHUNK_BYTES * 2);

        assert!(matches!(read, Err(ReadError::TooLarge)), "{read:?}");
    }

    #[gtk4::test]
    fn a_stream_at_the_limit_is_read_whole() {
        let read = capped(vec![b'x'; READ_CHUNK_BYTES * 2], READ_CHUNK_BYTES * 2).expect("the contents");

        assert_eq!(read.len(), READ_CHUNK_BYTES * 2);
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
