use std::rc::Rc;

use tablepro_core::credentials::SecretVault;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionStore, StoragePaths};

use crate::persistence::{ColumnWidthStore, FilterSettingsStore};
use crate::workspace::{WorkspaceStore, remove_legacy_tab_file};

/// Everything the app persists, resolved once at startup and handed to
/// the root component. Nothing reaches for a global, so a test can point
/// a whole app at a temporary root.
#[derive(Clone)]
pub struct AppStorage {
    paths: StoragePaths,
    connections: ConnectionStore,
    secrets: std::sync::Arc<dyn SecretVault>,
    column_widths: ColumnWidthStore,
    filter_settings: FilterSettingsStore,
    workspaces: WorkspaceStore,
}

impl AppStorage {
    /// The vault is injected so a test can substitute one that never
    /// touches the user's keyring.
    pub fn new(paths: StoragePaths, secrets: std::sync::Arc<dyn SecretVault>, tasks: &Tasks) -> Self {
        let connections = ConnectionStore::new(&paths);
        let column_widths = ColumnWidthStore::load(paths.column_widths_file(), tasks);
        let filter_settings = FilterSettingsStore::load(paths.filter_settings_file(), tasks);
        let workspaces = WorkspaceStore::start(
            paths.workspaces_dir(),
            tablepro_storage::DraftStore::new(paths.drafts_dir()),
            tasks,
        );
        let state = paths.state.clone();
        drop(tasks.spawn_blocking_task(move || match remove_legacy_tab_file(&state) {
            Ok(true) => tracing::info!("removed the tab file an older build left"),
            Ok(false) => {}
            Err(error) => tracing::warn!(%error, "could not remove the tab file an older build left"),
        }));
        Self {
            paths,
            connections,
            secrets,
            column_widths,
            filter_settings,
            workspaces,
        }
    }

    pub fn paths(&self) -> &StoragePaths {
        &self.paths
    }

    pub fn connections(&self) -> &ConnectionStore {
        &self.connections
    }

    pub fn secrets(&self) -> &std::sync::Arc<dyn SecretVault> {
        &self.secrets
    }

    pub fn column_widths(&self) -> &ColumnWidthStore {
        &self.column_widths
    }

    pub fn filter_settings(&self) -> &FilterSettingsStore {
        &self.filter_settings
    }

    pub fn workspaces(&self) -> &WorkspaceStore {
        &self.workspaces
    }
}

pub type SharedStorage = Rc<AppStorage>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{test_runtime, wait_until};

    #[gtk4::test]
    fn opening_the_storage_removes_the_tab_file_an_older_build_left() {
        let root = tempfile::tempdir().expect("a root");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        std::fs::create_dir_all(&paths.state).expect("the state directory");
        let legacy = paths.state.join("workspace_state.json");
        std::fs::write(&legacy, b"{}").expect("the legacy file");
        let runtime = test_runtime();

        let _storage = AppStorage::new(
            paths,
            std::sync::Arc::new(tablepro_storage::SecretStore::new(crate::config::secret_schema())),
            &runtime.tasks(),
        );

        wait_until(std::time::Duration::from_secs(10), || !legacy.exists()).expect("the legacy file is removed");
        runtime.shutdown();
    }
}
