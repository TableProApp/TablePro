use std::rc::Rc;

use tablepro_core::credentials::SecretVault;
use tablepro_storage::{ConnectionStore, QueryHistory, SecretStore, StoragePaths};

/// Everything the app persists, resolved once at startup and handed to
/// the root component. Nothing reaches for a global, so a test can point
/// a whole app at a temporary root.
#[derive(Clone)]
pub struct AppStorage {
    paths: StoragePaths,
    connections: ConnectionStore,
    secrets: std::sync::Arc<dyn SecretVault>,
    /// `None` when the history database could not be opened. The app
    /// still runs; the history dialog reports that it is unavailable.
    history: Option<QueryHistory>,
}

impl AppStorage {
    pub async fn open(paths: StoragePaths, secret_schema: String) -> Self {
        Self::with_vault(paths, std::sync::Arc::new(SecretStore::new(secret_schema))).await
    }

    /// A caller-supplied vault, for tests that must not touch the
    /// user's keyring.
    pub async fn with_vault(paths: StoragePaths, secrets: std::sync::Arc<dyn SecretVault>) -> Self {
        let connections = ConnectionStore::new(&paths);
        let history = match QueryHistory::open(&paths).await {
            Ok(history) => Some(history),
            Err(error) => {
                tracing::warn!(%error, "query history unavailable");
                None
            }
        };
        Self {
            paths,
            connections,
            secrets,
            history,
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

    pub fn history(&self) -> Option<&QueryHistory> {
        self.history.as_ref()
    }
}

pub type SharedStorage = Rc<AppStorage>;
