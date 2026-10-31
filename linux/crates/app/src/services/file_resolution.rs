//! A database file handed to TablePro, resolved to the session it
//! opens. Resolving reads the disk, so it runs on the blocking pool.

use std::io::Read;
use std::path::{Path, PathBuf};

use tablepro_core::{BusyReason, DriverError, DriverRegistry};
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

/// The first `len` bytes of the file, or as many as it has, which say
/// which engine opens it.
///
/// SQLite and DuckDB lock a file with POSIX record locks, which belong to
/// the process: closing any descriptor this process has on the file
/// drops them all. A file this process already holds open, through
/// another name such as a hard link, is refused rather than read, and no
/// engine opens a file until the read is done (`opening_file_blocking`).
pub fn read_header_blocking(path: &Path, len: usize) -> Result<Vec<u8>, DriverError> {
    let _opening = tablepro_core::opening_file_blocking();
    let failed = |error: std::io::Error| {
        let path = path.to_path_buf();
        match error.kind() {
            std::io::ErrorKind::NotFound => DriverError::FileNotFound { path },
            std::io::ErrorKind::PermissionDenied => DriverError::FileAccessDenied { path },
            std::io::ErrorKind::IsADirectory => DriverError::NotADatabase { path },
            kind => DriverError::FileIo { path, kind },
        }
    };
    let metadata = std::fs::metadata(path).map_err(failed)?;
    // A FIFO would hold the read, and every engine's open behind it,
    // until something wrote to it.
    if !metadata.is_file() {
        return Err(DriverError::NotADatabase {
            path: path.to_path_buf(),
        });
    }
    if tablepro_core::held_by_this_process(path) {
        return Err(DriverError::Busy(BusyReason::FileLocked));
    }
    let mut header = Vec::with_capacity(len);
    std::fs::File::open(path)
        .and_then(|file| file.take(len as u64).read_to_end(&mut header))
        .map_err(failed)?;
    Ok(header)
}

#[cfg(test)]
mod tests {
    use tablepro_test_support::{ConnectionScript, FakeDriver};

    use super::*;

    #[test]
    fn a_header_is_at_most_what_the_file_holds() {
        let directory = tempfile::tempdir().expect("tempdir");
        let short = directory.path().join("short.db");
        std::fs::write(&short, b"abc").expect("seed");
        let missing = directory.path().join("missing.db");

        assert_eq!(read_header_blocking(&short, 16).expect("the header"), b"abc");
        assert_eq!(
            read_header_blocking(&missing, 16),
            Err(DriverError::FileNotFound { path: missing })
        );
    }

    /// Reading a FIFO would wait for a writer, with every engine's open
    /// waiting behind it.
    #[test]
    fn a_fifo_is_not_read() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("pipe.db");
        let made = std::process::Command::new("mkfifo")
            .arg(&path)
            .status()
            .expect("mkfifo");
        assert!(made.success());

        assert_eq!(read_header_blocking(&path, 16), Err(DriverError::NotADatabase { path }));
    }

    /// An engine opening a file holds no descriptor on it yet, so the
    /// read waits until it does.
    #[test]
    fn a_header_read_waits_for_an_engine_opening_a_file() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("opening.db");
        std::fs::write(&path, b"SQLite format 3\0").expect("seed");
        let opening = tablepro_core::opening_file_blocking();

        let reading = std::thread::spawn(move || read_header_blocking(&path, 16));
        std::thread::sleep(std::time::Duration::from_millis(100));
        let waited = !reading.is_finished();
        drop(opening);

        assert!(waited, "the header was read while an engine was opening a file");
        assert_eq!(
            reading.join().expect("the read").expect("the header"),
            b"SQLite format 3\0"
        );
    }

    /// Reading a file through a second name would close a descriptor on
    /// it, which drops every lock this process holds on it.
    #[test]
    fn a_file_this_process_holds_is_not_read() {
        let directory = tempfile::tempdir().expect("tempdir");
        let held = directory.path().join("held.db");
        std::fs::write(&held, b"SQLite format 3\0").expect("seed");
        let linked = directory.path().join("linked.db");
        std::fs::hard_link(&held, &linked).expect("link");
        let open = std::fs::File::open(&held).expect("open");

        assert_eq!(
            read_header_blocking(&linked, 16),
            Err(DriverError::Busy(BusyReason::FileLocked))
        );
        drop(open);
        assert_eq!(
            read_header_blocking(&linked, 16).expect("the header"),
            b"SQLite format 3\0"
        );
    }

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
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
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
