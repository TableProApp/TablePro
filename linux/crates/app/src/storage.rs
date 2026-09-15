use std::rc::Rc;

use tablepro_core::credentials::SecretVault;
use tablepro_storage::{ConnectionStore, StoragePaths};

/// Everything the app persists, resolved once at startup and handed to
/// the root component. Nothing reaches for a global, so a test can point
/// a whole app at a temporary root.
#[derive(Clone)]
pub struct AppStorage {
    paths: StoragePaths,
    connections: ConnectionStore,
    secrets: std::sync::Arc<dyn SecretVault>,
}

impl AppStorage {
    /// The vault is injected so a test can substitute one that never
    /// touches the user's keyring.
    pub fn new(paths: StoragePaths, secrets: std::sync::Arc<dyn SecretVault>) -> Self {
        let connections = ConnectionStore::new(&paths);
        Self {
            paths,
            connections,
            secrets,
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
}

pub type SharedStorage = Rc<AppStorage>;
