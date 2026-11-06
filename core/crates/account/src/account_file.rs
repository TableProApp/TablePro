use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::account_error::AccountError;

const VERSION: u32 = 1;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AccountFile {
    pub device_id: Option<String>,
    // The last entitlement's sub, kept once it expires or a refresh is refused, so an offline file
    // of another account is refused then too.
    #[serde(default)]
    pub account_id: Option<String>,
    pub entitlement: Option<String>,
    // An offline file imported with no sign-in: the keyring holds nothing to open.
    #[serde(default)]
    pub offline_only: bool,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    version: u32,
    #[serde(flatten)]
    file: AccountFile,
}

// None when missing. Read as empty when of another version: the device registers again.
pub(crate) async fn read(path: &Path) -> Result<Option<AccountFile>, AccountError> {
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(storage_error(path, &error)),
    };
    let file = match serde_json::from_slice::<Stored>(&bytes) {
        Ok(stored) if stored.version == VERSION => stored.file,
        Ok(stored) => {
            tracing::warn!(version = stored.version, "the account file is of another version");
            AccountFile::default()
        }
        Err(error) => {
            tracing::warn!(%error, "the account file does not read");
            AccountFile::default()
        }
    };
    Ok(Some(file))
}

pub(crate) async fn write(path: &Path, file: &AccountFile) -> Result<(), AccountError> {
    let stored = Stored {
        version: VERSION,
        file: file.clone(),
    };
    let bytes = serde_json::to_vec_pretty(&stored).map_err(|error| storage_error(path, &error))?;
    let target = path.to_owned();
    tokio::task::spawn_blocking(move || tablepro_storage::fs::write_private_blocking(&target, &bytes))
        .await
        .map_err(|error| storage_error(path, &error))?
        .map_err(|error| storage_error(path, &error))
}

pub(crate) async fn remove(path: &Path) -> Result<(), AccountError> {
    match tokio::fs::remove_file(path).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(storage_error(path, &error)),
    }
}

fn storage_error(path: &Path, error: &dyn std::fmt::Display) -> AccountError {
    AccountError::Storage {
        path: PathBuf::from(path).display().to_string(),
        detail: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_written_file_reads_back_and_is_private() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("state").join("account.json");
        let file = AccountFile {
            device_id: Some("dev_01k8d6wpggfd68tbhz818p4ww4".to_owned()),
            account_id: Some("acct_01k8d6wk00f8xsr79e7x052rkk".to_owned()),
            entitlement: Some("header.payload.signature".to_owned()),
            offline_only: false,
        };

        write(&path, &file).await.expect("written");
        let read_back = read(&path).await.expect("read");

        assert_eq!(read_back, Some(file));
        #[cfg(unix)]
        {
            let metadata = std::fs::metadata(&path).expect("metadata");
            let mode = std::os::unix::fs::PermissionsExt::mode(&metadata.permissions());
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[tokio::test]
    async fn a_file_from_before_offline_files_reads_as_signed_in() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("account.json");
        std::fs::write(&path, r#"{"version":1,"device_id":"dev_x","entitlement":null}"#).expect("written");

        let file = read(&path).await.expect("read").expect("a file");

        assert_eq!(file.device_id.as_deref(), Some("dev_x"));
        assert_eq!(file.account_id, None);
        assert!(!file.offline_only);
    }

    #[tokio::test]
    async fn a_missing_file_reads_as_none() {
        let dir = tempfile::tempdir().expect("a temporary directory");

        let missing = read(&dir.path().join("account.json")).await.expect("read");

        assert_eq!(missing, None);
    }

    #[tokio::test]
    async fn an_unreadable_or_newer_file_reads_as_empty() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("account.json");

        std::fs::write(&path, "not json").expect("written");
        let garbage = read(&path).await.expect("read");
        std::fs::write(&path, r#"{"version":2,"device_id":"dev_x"}"#).expect("written");
        let newer = read(&path).await.expect("read");

        for file in [garbage, newer] {
            assert_eq!(file, Some(AccountFile::default()));
        }
    }

    #[tokio::test]
    async fn remove_takes_the_file_and_tolerates_none() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("account.json");
        write(&path, &AccountFile::default()).await.expect("written");

        remove(&path).await.expect("removed");
        let again = remove(&path).await;

        assert!(!path.exists());
        assert!(again.is_ok());
    }
}
