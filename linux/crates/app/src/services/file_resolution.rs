//! A database file handed to TablePro, resolved to the session it
//! opens. Resolving reads the disk, so it runs on the blocking pool.

use std::path::{Path, PathBuf};

use tablepro_core::DriverRegistry;
use tablepro_session::SessionKey;
use tablepro_session::registry::FileIdentity;
use tablepro_storage::{ConnectionStore, SavedConnection};
use thiserror::Error;

/// Why a file could not be opened before any connect was tried.
#[derive(Debug, Error)]
pub enum FileResolveError {
    /// A file with no local path, such as one on a remote share GIO
    /// reaches without mounting it.
    #[error("the file has no local path")]
    NotLocal,
    #[error("the file could not be found: {0}")]
    NotFound(#[source] std::io::Error),
    /// The background work that resolves it did not finish.
    #[error("the file could not be resolved: {0}")]
    Interrupted(#[source] tablepro_session::runtime::TaskFailure),
}

/// What a file turned out to open.
#[derive(Debug)]
pub enum FileTarget {
    /// The user saved this file as a connection, so that connection
    /// opens, with its name, colour and saved tabs.
    Saved(Box<SavedConnection>),
    File(FileIdentity),
}

/// A file the user opened and what it resolved to.
#[derive(Debug)]
pub struct ResolvedFile {
    /// The URI it arrived as, for a Retry to resolve again.
    pub uri: String,
    pub target: Result<FileTarget, FileResolveError>,
}

/// The file's canonical path, so a symlink and its target, or two
/// spellings of one path, open one session. The URI is the canonical
/// path's, which is what the session's key and saved tabs go by.
pub fn resolve_file_identity_blocking(path: Option<&Path>, uri: &str) -> Result<FileIdentity, FileResolveError> {
    let path = path.ok_or(FileResolveError::NotLocal)?;
    let canonical = std::fs::canonicalize(path).map_err(FileResolveError::NotFound)?;
    let uri = glib::filename_to_uri(&canonical, None).map_or_else(|_| uri.to_owned(), |uri| uri.to_string());
    Ok(FileIdentity::new(Some(canonical), uri))
}

/// Resolve the file, then find whether a saved connection opens the
/// same one.
pub fn resolve_file_blocking(
    path: Option<PathBuf>,
    uri: String,
    connections: &ConnectionStore,
    drivers: &DriverRegistry,
) -> ResolvedFile {
    let target = resolve_file_identity_blocking(path.as_deref(), &uri).map(|identity| {
        let saved = match connections.load_blocking() {
            Ok(saved) => saved.to_vec(),
            Err(error) => {
                tracing::warn!(%error, "the saved connections could not be read to match a file against");
                Vec::new()
            }
        };
        let is_file_driver = |id: &str| {
            drivers
                .get(id)
                .is_some_and(|driver| driver.capabilities().is_file_based())
        };
        match SessionKey::for_file(&identity, &saved, is_file_driver) {
            SessionKey::Saved(id) => match saved.into_iter().find(|connection| connection.id == id) {
                Some(connection) => FileTarget::Saved(Box::new(connection)),
                None => FileTarget::File(identity),
            },
            SessionKey::File(_) => FileTarget::File(identity),
        }
    });
    ResolvedFile { uri, target }
}

#[cfg(test)]
mod tests {
    use tablepro_test_support::{ConnectionScript, FakeDriver};

    use super::*;

    #[test]
    fn a_missing_file_is_not_found() {
        let root = tempfile::tempdir().expect("tempdir");
        let missing = root.path().join("gone.db");

        let resolved = resolve_file_identity_blocking(Some(&missing), "file:///gone.db");

        assert!(matches!(resolved, Err(FileResolveError::NotFound(_))), "{resolved:?}");
        assert!(matches!(
            resolve_file_identity_blocking(None, "sftp://host/app.db"),
            Err(FileResolveError::NotLocal)
        ));
    }

    fn drivers(capabilities: &'static tablepro_core::DriverCapabilities) -> DriverRegistry {
        let mut drivers = DriverRegistry::new();
        drivers.register(std::sync::Arc::new(FakeDriver::connecting(
            capabilities,
            ConnectionScript::default(),
        )));
        drivers
    }

    /// `database` saved as a connection of the fake driver, and what
    /// opening the file then resolves to.
    fn resolve_saved(
        database: &str,
        capabilities: &'static tablepro_core::DriverCapabilities,
    ) -> (uuid::Uuid, ResolvedFile) {
        let root = tempfile::tempdir().expect("tempdir");
        let path = std::fs::canonicalize(root.path()).expect("canonical").join(database);
        std::fs::write(&path, b"").expect("seed");
        let store = ConnectionStore::new(&tablepro_storage::StoragePaths::under(
            root.path(),
            "tablepro-test",
            "app.tablepro.Test",
        ));
        let saved = SavedConnection {
            id: uuid::Uuid::new_v4(),
            name: "local".to_owned(),
            driver_id: "fake".to_owned(),
            host: String::new(),
            port: 0,
            database: path.display().to_string(),
            username: String::new(),
            tls: tablepro_core::TlsConfig::disabled(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
        };
        store.upsert_blocking(saved.clone()).expect("saved");
        let uri = format!("file://{}", path.display());

        (
            saved.id,
            resolve_file_blocking(Some(path), uri, &store, &drivers(capabilities)),
        )
    }

    #[test]
    fn a_saved_file_opens_its_saved_connection() {
        let (id, resolved) = resolve_saved("app.db", &FakeDriver::FILE_CAPABILITIES);

        match resolved.target {
            Ok(FileTarget::Saved(connection)) => assert_eq!(connection.id, id),
            other => panic!("the saved connection was not found: {other:?}"),
        }
    }

    #[test]
    fn a_server_whose_database_names_the_file_is_not_opened() {
        let (_, resolved) = resolve_saved("shop", &FakeDriver::NETWORK_CAPABILITIES);

        assert!(
            matches!(resolved.target, Ok(FileTarget::File(_))),
            "{:?}",
            resolved.target
        );
    }
}
