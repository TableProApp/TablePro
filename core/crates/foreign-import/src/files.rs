use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

// Far above any app's settings file, and small enough to hold in memory.
pub(crate) const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;

// A path from another app's files can be crafted, such as a project's `.idea` folder linked to
// `/dev/zero` or a pipe, so a read takes only a regular file, and only up to the cap.
pub(crate) fn read_capped(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    let path = path.as_ref();
    let metadata = fs::metadata(path)?;
    if !metadata.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a regular file"));
    }
    if metadata.len() > MAX_FILE_BYTES {
        return Err(too_large());
    }
    let mut data = Vec::new();
    File::open(path)?.take(MAX_FILE_BYTES + 1).read_to_end(&mut data)?;
    if u64::try_from(data.len()).unwrap_or(u64::MAX) > MAX_FILE_BYTES {
        return Err(too_large());
    }
    Ok(data)
}

pub(crate) fn read_capped_string(path: impl AsRef<Path>) -> io::Result<String> {
    String::from_utf8(read_capped(path)?).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn too_large() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "larger than an app's settings file")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_regular_file_is_read() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let path = dir.path().join("settings.json");
        fs::write(&path, b"{}").expect("a file");
        assert_eq!(read_capped(&path).expect("the file"), b"{}");
        assert_eq!(read_capped_string(&path).expect("the file"), "{}");
    }

    #[test]
    fn a_folder_or_a_file_past_the_cap_is_refused() {
        let dir = tempfile::tempdir().expect("a temp dir");
        assert!(read_capped(dir.path()).is_err());
        let path = dir.path().join("huge.json");
        File::create(&path)
            .and_then(|file| file.set_len(MAX_FILE_BYTES + 1))
            .expect("a sparse file");
        assert!(read_capped(&path).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_device_is_refused_without_reading_it() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let link = dir.path().join("dataSources.xml");
        std::os::unix::fs::symlink("/dev/zero", &link).expect("a link");
        assert_eq!(
            read_capped(&link).map_err(|error| error.kind()).err(),
            Some(io::ErrorKind::InvalidInput)
        );
    }
}
