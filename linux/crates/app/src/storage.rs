use std::rc::Rc;

use tablepro_core::credentials::SecretVault;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionStore, StoragePaths};

use crate::persistence::{ColumnLayoutStore, FilterSettingsStore};
use crate::workspace::WorkspaceStore;

/// Everything the app persists, resolved once at startup and handed to
/// the application. Nothing reaches for a global, so a test can point a
/// whole app at a temporary root.
#[derive(Clone)]
pub struct AppStorage {
    paths: StoragePaths,
    connections: ConnectionStore,
    secrets: std::sync::Arc<dyn SecretVault>,
    column_layouts: ColumnLayoutStore,
    filter_settings: FilterSettingsStore,
    workspaces: WorkspaceStore,
}

impl AppStorage {
    /// The vault is injected so a test can substitute one that never
    /// touches the user's keyring.
    pub fn new(paths: StoragePaths, secrets: std::sync::Arc<dyn SecretVault>, tasks: &Tasks) -> Self {
        let connections = ConnectionStore::new(&paths);
        let column_layouts = ColumnLayoutStore::load(paths.column_layouts_file(), tasks);
        let filter_settings = FilterSettingsStore::load(paths.filter_settings_file(), tasks);
        let workspaces = WorkspaceStore::start(
            paths.workspaces_dir(),
            tablepro_storage::DraftStore::new(paths.drafts_dir()),
            tasks,
        );
        Self {
            paths,
            connections,
            secrets,
            column_layouts,
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

    pub fn column_layouts(&self) -> &ColumnLayoutStore {
        &self.column_layouts
    }

    pub fn filter_settings(&self) -> &FilterSettingsStore {
        &self.filter_settings
    }

    pub fn workspaces(&self) -> &WorkspaceStore {
        &self.workspaces
    }
}

pub type SharedStorage = Rc<AppStorage>;
