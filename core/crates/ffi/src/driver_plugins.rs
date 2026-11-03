use std::path::PathBuf;
use std::sync::Arc;

use tablepro_driver_host::registry::{HostTarget, parse_manifest};
use tablepro_driver_host::{DriverState, DriverStore, InstalledDriver, PluginError};
use tablepro_session::runtime::Tasks;

use crate::error::{CoreError, ErrorInfo};
use crate::runtime::on_runtime;

/// A driver the user installed, loaded from the app's data folder
/// (`core/docs/decisions/0004-driver-plugin-abi.md`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct InstalledDriverInfo {
    pub id: String,
    pub display_name: String,
    pub version: String,
    pub path: String,
    /// The ABI version both sides speak, as `major.minor`, when it loaded.
    pub abi: Option<String>,
    /// Why it did not load.
    pub error: Option<ErrorInfo>,
}

/// A catalog entry with a release for this computer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AvailableDriver {
    pub id: String,
    pub name: String,
    pub version: String,
    /// Where the app downloads the library from.
    pub url: String,
    pub sha256: String,
}

#[derive(uniffi::Object)]
pub struct DriverPlugins {
    store: Arc<DriverStore>,
    tasks: Tasks,
}

impl DriverPlugins {
    pub(crate) fn new(store: Arc<DriverStore>, tasks: Tasks) -> Self {
        Self { store, tasks }
    }

    async fn blocking<T, F>(&self, work: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: FnOnce(&DriverStore) -> Result<T, PluginError> + Send + 'static,
    {
        let store = self.store.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            tasks
                .spawn_blocking_task(move || work(&store).map_err(|error| plugin_failure(&error)))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
        })
        .await
    }
}

#[uniffi::export]
impl DriverPlugins {
    /// Every installed driver, loading those not loaded yet: each one's
    /// signature is checked before its library is mapped.
    pub async fn installed(&self) -> Result<Vec<InstalledDriverInfo>, CoreError> {
        self.blocking(|store| Ok(store.installed()?.iter().map(info).collect()))
            .await
    }

    /// Copies a driver library into the data folder, checks its
    /// signature, loads it and asks it to describe itself. A driver with
    /// the same id is replaced; the one it replaces stays loaded until the
    /// app quits.
    pub async fn install_file(&self, path: String) -> Result<InstalledDriverInfo, CoreError> {
        self.blocking(move |store| {
            store
                .install_file(&PathBuf::from(path), None)
                .map(|driver| info(&driver))
        })
        .await
    }

    /// Installs the release `available_drivers` listed for `id`, from the
    /// file the app downloaded from its URL. The checksum, the driver's id
    /// and its version must be the catalog's.
    pub async fn install_release(
        &self,
        manifest_json: String,
        id: String,
        path: String,
    ) -> Result<InstalledDriverInfo, CoreError> {
        self.blocking(move |store| {
            let manifest = parse_manifest(&manifest_json)?;
            let entry = manifest.entry(&id)?;
            store
                .install_release(entry, &PathBuf::from(path))
                .map(|driver| info(&driver))
        })
        .await
    }

    /// Stops the driver and forgets it. Its file goes now, or at the next
    /// start where the system still has it mapped.
    pub async fn remove(&self, id: String) -> Result<(), CoreError> {
        self.blocking(move |store| store.remove(&id)).await
    }
}

/// The drivers in a catalog that have a release for this platform,
/// processor and ABI.
#[uniffi::export]
pub fn available_drivers(manifest_json: String) -> Result<Vec<AvailableDriver>, CoreError> {
    let manifest = parse_manifest(&manifest_json).map_err(|error| plugin_failure(&error))?;
    let target = HostTarget::current();
    let mut available: Vec<AvailableDriver> = manifest
        .plugins
        .iter()
        .filter_map(|entry| {
            entry.release_for(target).map(|release| AvailableDriver {
                id: entry.id.clone(),
                name: entry.name.clone(),
                version: release.version.clone(),
                url: release.url.clone(),
                sha256: release.sha256.clone(),
            })
        })
        .collect();
    available.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(available)
}

fn info(driver: &InstalledDriver) -> InstalledDriverInfo {
    let (abi, error) = match &driver.state {
        DriverState::Loaded { abi_major, abi_minor } => (Some(format!("{abi_major}.{abi_minor}")), None),
        DriverState::Failed(error) => (None, Some(plugin_info(error))),
    };
    InstalledDriverInfo {
        id: driver.id.clone(),
        display_name: driver.display_name.clone(),
        version: driver.version.clone(),
        path: driver.path.display().to_string(),
        abi,
        error,
    }
}

fn plugin_failure(error: &PluginError) -> CoreError {
    CoreError::Failed {
        info: plugin_info(error),
    }
}

fn plugin_info(error: &PluginError) -> ErrorInfo {
    let mut codes = vec![error.code().to_owned()];
    if let PluginError::Call { codes: inner, .. } = error {
        codes.extend(inner.iter().cloned());
    }
    ErrorInfo {
        code: codes.last().cloned().unwrap_or_default(),
        codes,
        message: error.to_string(),
        server: None,
        path: None,
        secret: None,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_driver_host::{PlatformTrust, Signer};

    use super::*;

    fn plugins(folder: &std::path::Path) -> DriverPlugins {
        // The fixture issuer is impossible, so this policy cannot admit executable code.
        let trust = Arc::new(unsafe {
            PlatformTrust::new(vec![Signer {
                subject: "CN=TablePro".to_owned(),
                issuer_sha256: "00".repeat(32),
            }])
        });
        let store = Arc::new(DriverStore::new(folder.join("drivers"), trust));
        DriverPlugins::new(store, crate::runtime::tasks().unwrap())
    }

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(future)
    }

    #[test]
    fn a_new_data_folder_has_no_drivers() {
        let folder = tempfile::tempdir().unwrap();

        assert!(block_on(plugins(folder.path()).installed()).unwrap().is_empty());
    }

    #[test]
    fn a_file_with_no_signature_never_loads() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("driver.dll");
        std::fs::write(&file, b"MZ").unwrap();
        let plugins = plugins(folder.path());

        let error = block_on(plugins.install_file(file.display().to_string())).unwrap_err();

        let expected = if cfg!(windows) {
            "plugin.unsigned"
        } else {
            "plugin.trust_unavailable"
        };
        assert_eq!(error.code(), expected);
        assert!(block_on(plugins.installed()).unwrap().is_empty());
    }

    #[test]
    fn removing_what_is_not_installed_says_so() {
        let folder = tempfile::tempdir().unwrap();

        let error = block_on(plugins(folder.path()).remove("sqlite".to_owned())).unwrap_err();

        assert_eq!(error.code(), "plugin.not_installed");
    }

    #[test]
    fn a_catalog_lists_only_what_runs_here() {
        let target = HostTarget::current();
        let manifest = format!(
            r#"{{"schemaVersion": 1, "plugins": [
              {{"id": "sqlite", "name": "SQLite", "releases": [{{"version": "0.1.0", "build": 1, "channel": "stable",
                "abi": 1, "os": "{os}", "arch": "{arch}", "url": "https://example.com/a", "sha256": "ab"}}]}},
              {{"id": "oracle", "name": "Oracle", "releases": [{{"version": "0.1.0", "build": 1, "channel": "stable",
                "abi": 1, "os": "plan9", "arch": "{arch}", "url": "https://example.com/b", "sha256": "cd"}}]}}
            ]}}"#,
            os = target.os,
            arch = target.arch
        );

        let available = available_drivers(manifest).unwrap();

        assert_eq!(available.len(), 1);
        assert_eq!(available[0].id, "sqlite");
        assert_eq!(available[0].url, "https://example.com/a");
    }

    #[test]
    fn a_catalog_that_is_not_json_says_so() {
        let error = available_drivers("<html>".to_owned()).unwrap_err();

        assert_eq!(error.code(), "plugin.manifest_invalid");
    }
}
