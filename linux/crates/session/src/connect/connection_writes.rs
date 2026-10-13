use futures::future::BoxFuture;
use tablepro_storage::{ConnectionStore, SavedConnection, StorageError};
use uuid::Uuid;

use crate::runtime::Tasks;

/// Where a saved connection entry is written.
pub trait ConnectionWrites: Send + Sync {
    fn upsert(&self, connection: SavedConnection) -> BoxFuture<'_, Result<(), StorageError>>;
    fn remove(&self, id: Uuid) -> BoxFuture<'_, Result<(), StorageError>>;
}

/// The connection list on disk, written on the blocking pool because a
/// durable write waits for the disk.
#[derive(Debug, Clone)]
pub struct StoreConnectionWrites {
    store: ConnectionStore,
    tasks: Tasks,
}

impl StoreConnectionWrites {
    pub fn new(store: ConnectionStore, tasks: Tasks) -> Self {
        Self { store, tasks }
    }
}

impl ConnectionWrites for StoreConnectionWrites {
    fn upsert(&self, connection: SavedConnection) -> BoxFuture<'_, Result<(), StorageError>> {
        let store = self.store.clone();
        let written = self
            .tasks
            .spawn_blocking_task(move || store.upsert_blocking(connection));
        Box::pin(async move {
            written
                .await
                .map_err(|failure| StorageError::Schema(format!("the connections write task failed: {failure}")))?
        })
    }

    fn remove(&self, id: Uuid) -> BoxFuture<'_, Result<(), StorageError>> {
        let store = self.store.clone();
        let removed = self.tasks.spawn_blocking_task(move || store.remove_blocking(id));
        Box::pin(async move {
            removed
                .await
                .map_err(|failure| StorageError::Schema(format!("the connections write task failed: {failure}")))?
                .map(|_| ())
        })
    }
}
