//! What a database file handed to TablePro connects with, once it is
//! resolved off the GTK thread.

use std::path::PathBuf;
use std::sync::Arc;

use tablepro_core::{DatabaseDriver, DriverError, DriverRegistry, FileEndpoint, WorkspaceSettings};
use tablepro_session::registry::FileIdentity;
use tablepro_session::{ConnectError, ConnectRequest, ConnectionMetadata, RequestTarget};

pub(crate) use crate::services::file_resolution::{FileResolveError, FileTarget, ResolvedFile, resolve_file_blocking};

/// The request that opens a file nobody saved, through the driver that
/// opens files.
pub(crate) fn file_request(
    identity: &FileIdentity,
    drivers: &DriverRegistry,
    read_only: bool,
) -> Result<ConnectRequest, ConnectError> {
    let driver = file_driver(drivers).ok_or_else(|| ConnectError::UnknownDriver("sqlite".to_owned()))?;
    let path = identity
        .canonical_path
        .clone()
        .unwrap_or_else(|| PathBuf::from(&identity.uri));
    let name = path
        .file_name()
        .map_or_else(|| identity.uri.clone(), |name| name.to_string_lossy().into_owned());
    let endpoint = FileEndpoint::open_existing(path).map_err(DriverError::from)?;
    Ok(ConnectRequest {
        metadata: ConnectionMetadata {
            id: uuid::Uuid::new_v4(),
            name,
            driver_id: driver.id().to_owned(),
        },
        driver,
        target: RequestTarget::File(endpoint),
        workspace_settings: WorkspaceSettings::workspace(read_only),
    })
}

fn file_driver(drivers: &DriverRegistry) -> Option<Arc<dyn DatabaseDriver>> {
    drivers
        .get("sqlite")
        .filter(|driver| driver.capabilities().is_file_based())
        .or_else(|| {
            drivers
                .iter()
                .find(|driver| driver.capabilities().is_file_based())
                .cloned()
        })
}

#[cfg(test)]
mod tests {
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

        let request = file_request(&identity, &drivers, false).expect("a request");
        let read_only = file_request(&identity, &drivers, true).expect("a read-only request");

        assert_eq!(request.metadata.name, "app.db");
        assert!(matches!(request.target, RequestTarget::File(_)));
        assert!(!request.workspace_settings.read_only);
        assert!(read_only.workspace_settings.read_only);
        assert!(file_request(&identity, &DriverRegistry::new(), false).is_err());
    }
}
