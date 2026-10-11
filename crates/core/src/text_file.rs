use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::export::write_atomically_checked;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileVersion {
    len: u64,
    modified: SystemTime,
}

impl FileVersion {
    fn of(metadata: &std::fs::Metadata) -> io::Result<Self> {
        Ok(Self {
            len: metadata.len(),
            modified: metadata.modified()?,
        })
    }
}

#[derive(Debug, Clone)]
pub struct TextFile {
    pub path: PathBuf,
    pub text: String,
    pub version: FileVersion,
}

#[derive(Debug, thiserror::Error)]
pub enum TextFileError {
    #[error("the file changed on disk after it was opened or last saved")]
    Changed,
    #[error("the file is larger than {0} bytes")]
    TooLarge(u64),
    #[error("the file is not valid UTF-8 text")]
    NotText,
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub fn read_text_file(path: &Path, max_bytes: u64) -> Result<TextFile, TextFileError> {
    let path = std::fs::canonicalize(path)?;
    let file = File::open(&path)?;
    let version = FileVersion::of(&file.metadata()?)?;
    let mut bytes = Vec::new();
    file.take(max_bytes.saturating_add(1)).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        return Err(TextFileError::TooLarge(max_bytes));
    }
    let text = String::from_utf8(bytes).map_err(|_| TextFileError::NotText)?;
    Ok(TextFile { path, text, version })
}

pub fn save_text_file(path: &Path, text: &str, expected: Option<&FileVersion>) -> Result<TextFile, TextFileError> {
    let target = resolve_link_target(path)?;
    let permissions = existing_metadata(&target)?.map(|metadata| metadata.permissions());
    write_atomically_checked(
        &target,
        |output| output.write_all(text.as_bytes()).map_err(TextFileError::from),
        || ensure_unchanged(&target, expected),
    )?;
    if let Some(permissions) = permissions {
        std::fs::set_permissions(&target, permissions)?;
    }
    let version = FileVersion::of(&std::fs::metadata(&target)?)?;
    Ok(TextFile {
        path: target,
        text: text.to_string(),
        version,
    })
}

fn ensure_unchanged(path: &Path, expected: Option<&FileVersion>) -> Result<(), TextFileError> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let current = existing_metadata(path)?
        .map(|metadata| FileVersion::of(&metadata))
        .transpose()?;
    match current {
        Some(current) if &current == expected => Ok(()),
        _ => Err(TextFileError::Changed),
    }
}

fn resolve_link_target(path: &Path) -> io::Result<PathBuf> {
    match std::fs::canonicalize(path) {
        Ok(target) => Ok(target),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(path.to_path_buf()),
        Err(error) => Err(error),
    }
}

fn existing_metadata(path: &Path) -> io::Result<Option<std::fs::Metadata>> {
    match std::fs::metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_with(text: &str) -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("script.sql");
        std::fs::write(&path, text).unwrap();
        (directory, path)
    }

    fn change_on_disk(path: &Path, text: &str) {
        let before = std::fs::metadata(path).unwrap().modified().unwrap();
        std::fs::write(path, text).unwrap();
        let file = File::options().write(true).open(path).unwrap();
        file.set_modified(before + std::time::Duration::from_secs(5)).unwrap();
    }

    #[test]
    fn a_saved_file_reads_back_with_the_version_the_save_returned() {
        let (_directory, path) = file_with("SELECT 1;");
        let opened = read_text_file(&path, 1024).unwrap();

        let saved = save_text_file(&path, "SELECT 2;", Some(&opened.version)).unwrap();
        let reread = read_text_file(&path, 1024).unwrap();

        assert_eq!(reread.text, "SELECT 2;");
        assert_eq!(reread.version, saved.version);
    }

    #[test]
    fn saving_over_a_file_changed_on_disk_is_refused_and_keeps_the_other_writer_contents() {
        let (_directory, path) = file_with("SELECT 1;");
        let opened = read_text_file(&path, 1024).unwrap();
        change_on_disk(&path, "SELECT 'theirs';");

        let error = save_text_file(&path, "SELECT 'mine';", Some(&opened.version)).unwrap_err();

        assert!(matches!(error, TextFileError::Changed));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "SELECT 'theirs';");
    }

    #[test]
    fn a_file_deleted_after_opening_counts_as_changed() {
        let (_directory, path) = file_with("SELECT 1;");
        let opened = read_text_file(&path, 1024).unwrap();
        std::fs::remove_file(&path).unwrap();

        let error = save_text_file(&path, "SELECT 2;", Some(&opened.version)).unwrap_err();

        assert!(matches!(error, TextFileError::Changed));
        assert!(!path.exists());
    }

    #[test]
    fn saving_without_an_expected_version_overwrites() {
        let (_directory, path) = file_with("SELECT 1;");
        change_on_disk(&path, "SELECT 'theirs';");

        save_text_file(&path, "SELECT 'mine';", None).unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "SELECT 'mine';");
    }

    #[cfg(unix)]
    #[test]
    fn saving_keeps_the_file_permissions_and_writes_through_a_symlink() {
        use std::os::unix::fs::PermissionsExt;
        let (directory, path) = file_with("SELECT 1;");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        let link = directory.path().join("link.sql");
        std::os::unix::fs::symlink(&path, &link).unwrap();

        let saved = save_text_file(&link, "SELECT 2;", None).unwrap();

        assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(saved.path, std::fs::canonicalize(&path).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "SELECT 2;");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o640);
    }

    #[test]
    fn a_new_file_is_created() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("new.sql");

        let saved = save_text_file(&path, "SELECT 1;", None).unwrap();

        assert_eq!(read_text_file(&path, 1024).unwrap().version, saved.version);
    }

    #[test]
    fn reading_refuses_oversized_and_non_text_files() {
        let (_directory, path) = file_with("SELECT 1;");
        assert!(matches!(read_text_file(&path, 8), Err(TextFileError::TooLarge(8))));
        assert_eq!(read_text_file(&path, 9).unwrap().text, "SELECT 1;");

        std::fs::write(&path, [0xff, 0xfe, 0x00]).unwrap();
        assert!(matches!(read_text_file(&path, 1024), Err(TextFileError::NotText)));
    }
}
