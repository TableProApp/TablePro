// The sample database the setup guide offers, compiled in so every package carries it (core ADR 0057).

use std::path::{Path, PathBuf};

use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
use tablepro_storage::{ConnectionStore, DeviceOnly, SavedConnection, StorageError};
use uuid::Uuid;

const CHINOOK: &[u8] = include_bytes!("../../../../../core/resources/Chinook.sqlite");
const ENGINE: &str = "sqlite";

#[derive(Debug, thiserror::Error)]
pub(crate) enum SampleError {
    #[error(transparent)]
    Storage(#[from] StorageError),
}

pub(crate) fn sample_path(data: &Path) -> PathBuf {
    data.join("samples").join("Chinook.sqlite")
}

// Copied once: a sample the user changed is theirs, and its saved connection opens again rather than a second one.
pub(crate) fn ensure_blocking(
    data: &Path,
    store: &ConnectionStore,
    name: &str,
) -> Result<SavedConnection, SampleError> {
    let path = sample_path(data);
    if !path.exists() {
        tablepro_storage::fs::write_private_blocking(&path, CHINOOK)?;
    }
    let database = path.display().to_string();
    let list = store.list_blocking()?;
    if let Some(saved) = list
        .connections
        .iter()
        .find(|saved| saved.driver_id == ENGINE && saved.database == database)
    {
        return Ok(saved.clone());
    }
    let saved = SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: ENGINE.to_owned(),
        host: String::new(),
        port: 0,
        database,
        username: String::new(),
        tls: TlsConfig::disabled(),
        safe_mode: SafeModeLevel::Off,
        external_access: ExternalAccess::default(),
        ai_policy: AiPolicy::default(),
        query_timeout_secs: None,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
        details: Default::default(),
        // A sample stays on this device: no sync or export carries it.
        device: DeviceOnly {
            is_sample: true,
            ..DeviceOnly::default()
        },
        unknown: Default::default(),
    };
    store.upsert_blocking(saved.clone())?;
    Ok(saved)
}

#[cfg(test)]
mod tests {
    use tablepro_storage::StoragePaths;

    use super::*;

    #[test]
    fn the_sample_is_copied_and_saved_once() {
        let root = tempfile::tempdir().expect("a temporary folder");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let store = ConnectionStore::new(&paths);

        let first = ensure_blocking(&paths.data, &store, "Chinook (Sample)").expect("the sample");
        let copied = std::fs::read(sample_path(&paths.data)).expect("the copied file");
        assert!(
            copied.starts_with(b"SQLite format 3\0"),
            "the copy is not a SQLite file"
        );
        assert_eq!(copied.len(), CHINOOK.len());
        assert_eq!(first.driver_id, "sqlite");
        assert!(first.device.is_sample);
        assert_eq!(first.database, sample_path(&paths.data).display().to_string());

        let again = ensure_blocking(&paths.data, &store, "Chinook (Sample)").expect("the sample again");
        assert_eq!(again.id, first.id);
        assert_eq!(store.list_blocking().expect("the list").connections.len(), 1);
    }

    #[test]
    fn a_sample_the_user_changed_is_kept() {
        let root = tempfile::tempdir().expect("a temporary folder");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let store = ConnectionStore::new(&paths);
        let path = sample_path(&paths.data);
        tablepro_storage::fs::write_private_blocking(&path, b"changed").expect("a changed sample");

        ensure_blocking(&paths.data, &store, "Chinook (Sample)").expect("the sample");

        assert_eq!(std::fs::read(&path).expect("the file"), b"changed");
    }
}
