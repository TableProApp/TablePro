use std::rc::Rc;

use tablepro_core::credentials::SecretVault;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionStore, StoragePaths};

use crate::persistence::{ColumnWidthStore, FilterSettingsStore};

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
}

impl AppStorage {
    /// The vault is injected so a test can substitute one that never
    /// touches the user's keyring.
    pub fn new(paths: StoragePaths, secrets: std::sync::Arc<dyn SecretVault>, tasks: &Tasks) -> Self {
        let connections = ConnectionStore::new(&paths);
        let column_widths = ColumnWidthStore::load(paths.column_widths_file(), tasks);
        let filter_settings = FilterSettingsStore::load(paths.filter_settings_file(), tasks);
        Self {
            paths,
            connections,
            secrets,
            column_widths,
            filter_settings,
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
}

pub type SharedStorage = Rc<AppStorage>;
