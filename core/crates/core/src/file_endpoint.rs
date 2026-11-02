use std::path::{Path, PathBuf};

use crate::{ConfigError, FileOpenMode};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FileEndpoint {
    path: PathBuf,
    mode: FileOpenMode,
}

impl FileEndpoint {
    pub fn open_existing(path: PathBuf) -> Result<Self, ConfigError> {
        Self::with_mode(path, FileOpenMode::OpenExisting)
    }

    pub fn create_new(path: PathBuf) -> Result<Self, ConfigError> {
        Self::with_mode(path, FileOpenMode::CreateNew)
    }

    fn with_mode(path: PathBuf, mode: FileOpenMode) -> Result<Self, ConfigError> {
        if !path.is_absolute() {
            return Err(ConfigError::RelativePath);
        }
        Ok(Self { path, mode })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn mode(&self) -> FileOpenMode {
        self.mode
    }

    pub fn for_reopen(&self) -> FileEndpoint {
        Self {
            path: self.path.clone(),
            mode: FileOpenMode::OpenExisting,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_absolute_non_empty_path() {
        assert_eq!(
            FileEndpoint::open_existing(PathBuf::new()),
            Err(ConfigError::RelativePath)
        );
        assert_eq!(
            FileEndpoint::create_new(PathBuf::from("data/app.sqlite")),
            Err(ConfigError::RelativePath)
        );

        let existing = FileEndpoint::open_existing(PathBuf::from("/srv/app.sqlite")).unwrap();
        assert_eq!(existing.path(), Path::new("/srv/app.sqlite"));
        assert_eq!(existing.mode(), FileOpenMode::OpenExisting);

        let created = FileEndpoint::create_new(PathBuf::from("/srv/new.sqlite")).unwrap();
        assert_eq!(created.mode(), FileOpenMode::CreateNew);
    }

    #[test]
    fn for_reopen_is_open_existing_for_the_same_path() {
        let created = FileEndpoint::create_new(PathBuf::from("/srv/new.sqlite")).unwrap();
        let reopened = created.for_reopen();
        assert_eq!(reopened.path(), created.path());
        assert_eq!(reopened.mode(), FileOpenMode::OpenExisting);
    }
}
