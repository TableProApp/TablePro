use std::rc::Rc;

use tablepro_storage::{ConnectionStore, QueryHistory, SecretStore, StoragePaths};

/// Everything the app persists, resolved once at startup and handed to
/// the root component. Nothing reaches for a global, so a test can point
/// a whole app at a temporary root.
#[derive(Clone)]
pub struct AppStorage {
    paths: StoragePaths,
    connections: ConnectionStore,
    secrets: SecretStore,
    /// `None` when the history database could not be opened. The app
    /// still runs; the history dialog reports that it is unavailable.
    history: Option<QueryHistory>,
}

impl AppStorage {
    pub async fn open(paths: StoragePaths, secret_schema: String) -> Self {
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
            secrets: SecretStore::new(secret_schema),
            history,
        }
    }

    pub fn paths(&self) -> &StoragePaths {
        &self.paths
    }

    pub fn connections(&self) -> &ConnectionStore {
        &self.connections
    }

    pub fn secrets(&self) -> &SecretStore {
        &self.secrets
    }

    pub fn history(&self) -> Option<&QueryHistory> {
        self.history.as_ref()
    }
}

pub type SharedStorage = Rc<AppStorage>;
