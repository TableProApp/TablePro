use gtk4::glib;
use gtk4::prelude::*;

const READ_CHUNK_BYTES: usize = 256 * 1024;

/// Why a file the user chose was not read. The caller words it, since
/// what is too large depends on what the file was for.
#[derive(Debug)]
pub(crate) enum FileReadError {
    /// A pipe, a device or a socket. Opening a pipe waits for a writer
    /// that may never come, and a device has no end to read to.
    NotRegular,
    TooLarge,
    Io(glib::Error),
}

/// Read a file whole off the main thread, giving up once it passes
/// `limit` bytes.
pub(crate) async fn read_capped_file(file: &gio::File, limit: usize) -> Result<Vec<u8>, FileReadError> {
    let info = file
        .query_info_future(
            "standard::type,standard::size",
            gio::FileQueryInfoFlags::NONE,
            glib::Priority::DEFAULT,
        )
        .await;
    if let Ok(info) = info {
        if info.has_attribute(gio::FILE_ATTRIBUTE_STANDARD_TYPE) && info.file_type() == gio::FileType::Special {
            return Err(FileReadError::NotRegular);
        }
        if info.has_attribute(gio::FILE_ATTRIBUTE_STANDARD_SIZE)
            && u64::try_from(info.size()).is_ok_and(|size| size > limit as u64)
        {
            return Err(FileReadError::TooLarge);
        }
    }
    let stream = file
        .read_future(glib::Priority::DEFAULT)
        .await
        .map_err(FileReadError::Io)?;
    let read = read_capped(stream.upcast_ref(), limit).await;
    if let Err(error) = stream.close_future(glib::Priority::DEFAULT).await {
        tracing::debug!(%error, "closing a file that was read whole failed");
    }
    read
}

/// Read to the end of the stream, giving up once it passes `limit`.
///
/// The size a file reports is not enough: a remote file may report
/// none, and a file can grow between being measured and being read.
async fn read_capped(stream: &gio::InputStream, limit: usize) -> Result<Vec<u8>, FileReadError> {
    let mut contents = Vec::new();
    loop {
        let chunk = stream
            .read_bytes_future(READ_CHUNK_BYTES, glib::Priority::DEFAULT)
            .await
            .map_err(FileReadError::Io)?;
        if chunk.is_empty() {
            return Ok(contents);
        }
        if contents.len() + chunk.len() > limit {
            return Err(FileReadError::TooLarge);
        }
        contents.extend_from_slice(&chunk);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::test_support::finish_on_main;

    const WAIT: Duration = Duration::from_secs(10);

    fn capped(bytes: Vec<u8>, limit: usize) -> Result<Vec<u8>, FileReadError> {
        let stream = gio::MemoryInputStream::from_bytes(&glib::Bytes::from_owned(bytes));
        finish_on_main(WAIT, async move { read_capped(stream.upcast_ref(), limit).await }).expect("the read to end")
    }

    fn read(path: &std::path::Path, limit: usize) -> Result<Vec<u8>, FileReadError> {
        let file = gio::File::for_path(path);
        finish_on_main(WAIT, async move { read_capped_file(&file, limit).await }).expect("the read to end")
    }

    #[gtk4::test]
    fn a_stream_past_the_limit_is_refused_without_a_reported_size() {
        let read = capped(vec![b'x'; READ_CHUNK_BYTES * 3], READ_CHUNK_BYTES * 2);

        assert!(matches!(read, Err(FileReadError::TooLarge)), "{read:?}");
    }

    #[gtk4::test]
    fn a_stream_at_the_limit_is_read_whole() {
        let read = capped(vec![b'x'; READ_CHUNK_BYTES * 2], READ_CHUNK_BYTES * 2).expect("the contents");

        assert_eq!(read.len(), READ_CHUNK_BYTES * 2);
    }

    #[gtk4::test]
    fn a_device_is_refused_before_it_is_read() {
        let refused = read(std::path::Path::new("/dev/zero"), 1024);

        assert!(matches!(refused, Err(FileReadError::NotRegular)), "{refused:?}");
    }

    #[gtk4::test]
    fn a_file_reporting_more_than_the_limit_is_refused() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("big");
        std::fs::write(&path, vec![b' '; 1025]).expect("write");

        let refused = read(&path, 1024);

        assert!(matches!(refused, Err(FileReadError::TooLarge)), "{refused:?}");
    }

    #[gtk4::test]
    fn a_missing_file_is_an_io_error() {
        let root = tempfile::tempdir().expect("tempdir");

        let missing = read(&root.path().join("gone"), 1024);

        assert!(matches!(missing, Err(FileReadError::Io(_))), "{missing:?}");
    }
}
