//! What a database file handed to TablePro connects with, once it is
//! resolved off the GTK thread.

use std::path::PathBuf;

use tablepro_core::{DriverError, DriverRegistry, FileEndpoint, SafeModeLevel, WorkspaceSettings};
use tablepro_session::registry::FileIdentity;
use tablepro_session::{ConnectError, ConnectRequest, ConnectionMetadata, RequestTarget};

pub(crate) use crate::services::file_resolution::{
    FileResolveError, FileTarget, ResolvedFile, read_header_blocking, resolve_file_blocking,
};

/// The path a handed-over file opens at.
pub(crate) fn file_path(identity: &FileIdentity) -> PathBuf {
    identity
        .canonical_path
        .clone()
        .unwrap_or_else(|| PathBuf::from(&identity.uri))
}

/// The request that opens a file nobody saved, through the engine whose
/// files carry `header`, the file's first bytes, or go by its name.
pub(crate) fn file_request(
    identity: &FileIdentity,
    drivers: &DriverRegistry,
    header: &[u8],
    read_only: bool,
) -> Result<ConnectRequest, ConnectError> {
    let path = file_path(identity);
    let driver = drivers
        .file_driver_for(header, &path)
        .ok_or_else(|| DriverError::NotADatabase { path: path.clone() })?;
    let name = path
        .file_name()
        .map_or_else(|| identity.uri.clone(), |name| name.to_string_lossy().into_owned());
    let endpoint = FileEndpoint::open_existing(path).map_err(DriverError::from)?;
    let mut request = ConnectRequest {
        metadata: ConnectionMetadata {
            id: uuid::Uuid::new_v4(),
            name,
            driver_id: driver.id().to_owned(),
        },
        driver,
        target: RequestTarget::File(endpoint),
        workspace_settings: WorkspaceSettings::workspace(false),
        safe_mode: SafeModeLevel::Off,
    };
    if read_only {
        request.open_read_only();
    }
    Ok(request)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;
    use crate::services::file_resolution::resolve_file_identity_blocking;

    #[gtk4::test]
    fn symlinked_path_canonicalises() {
        let runtime = crate::test_support::test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let database = root.path().join("app.db");
        std::fs::write(&database, b"").expect("seed");
        let link = root.path().join("link.db");
        std::os::unix::fs::symlink(&database, &link).expect("symlink");
        let uri = format!("file://{}", link.display());

        let resolving = runtime
            .tasks()
            .spawn_blocking_task(move || resolve_file_identity_blocking(Some(&link), &uri));
        let identity = crate::test_support::finish_on_main(Duration::from_secs(10), resolving)
            .expect("the resolve to end")
            .expect("the task to finish")
            .expect("the file resolves");

        let canonical = std::fs::canonicalize(&database).expect("canonical");
        assert_eq!(identity.canonical_path.as_deref(), Some(canonical.as_path()));
        assert!(
            identity.uri.ends_with("/app.db"),
            "the key followed the link, not the file: {}",
            identity.uri
        );
        runtime.shutdown();
    }

    #[test]
    fn an_unsaved_file_opens_through_the_driver_that_opens_files() {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(tablepro_test_support::FakeDriver::connecting(
            &tablepro_test_support::FakeDriver::FILE_CAPABILITIES,
            tablepro_test_support::ConnectionScript::default(),
        )));
        let identity = FileIdentity::new(Some(PathBuf::from("/srv/app.db")), "file:///srv/app.db".to_owned());

        let request = file_request(&identity, &drivers, b"", false).expect("a request");
        let read_only = file_request(&identity, &drivers, b"", true).expect("a read-only request");

        assert_eq!(request.metadata.name, "app.db");
        assert!(matches!(request.target, RequestTarget::File(_)));
        assert!(!request.workspace_settings.read_only);
        assert!(read_only.workspace_settings.read_only);
        assert_eq!(read_only.safe_mode, SafeModeLevel::ReadOnly);
        assert!(file_request(&identity, &DriverRegistry::new(), b"", false).is_err());
    }

    /// The file's own bytes pick its engine, whatever it is named: a
    /// DuckDB file called `.db` is no SQLite file.
    #[test]
    fn the_engine_whose_signature_a_file_carries_opens_it() {
        let mut drivers = DriverRegistry::new();
        for (id, capabilities) in [
            ("sqlite", &tablepro_test_support::FakeDriver::FILE_CAPABILITIES),
            ("duckdb", &tablepro_test_support::FakeDriver::SIGNED_FILE_CAPABILITIES),
        ] {
            drivers.register(Arc::new(
                tablepro_test_support::FakeDriver::connecting(
                    capabilities,
                    tablepro_test_support::ConnectionScript::default(),
                )
                .with_id(id),
            ));
        }
        let identity = FileIdentity::new(Some(PathBuf::from("/srv/sales.db")), "file:///srv/sales.db".to_owned());
        let mut header = vec![0u8; 16];
        header[8..12].copy_from_slice(b"DUCK");

        let duck = file_request(&identity, &drivers, &header, false).expect("a request");
        let plain = file_request(&identity, &drivers, b"", false).expect("a request");
        let unknown = file_request(&identity, &drivers, b"some text file", false);

        assert_eq!(duck.metadata.driver_id, "duckdb");
        assert_eq!(plain.metadata.driver_id, "sqlite", "an empty .db file goes by its name");
        assert!(
            matches!(unknown, Err(ConnectError::Driver(DriverError::NotADatabase { .. }))),
            "{unknown:?}"
        );
    }
}
