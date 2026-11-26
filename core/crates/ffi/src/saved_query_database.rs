// The saved queries' database, `saved_queries.db`: saved queries and their folders, favourites and table folders, a
// store apart from the query history (core ADR 0060 as amended). Opening it reads `history.db` only to move saved
// queries out of an older one, so an iOS app reads it in the background while the history stays locked.

use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_storage::{SavedQueryDatabase, StoragePaths};

use crate::error::CoreError;
use crate::favourites::FavouriteStore;
use crate::saved_queries::SavedQueryStore;
use crate::table_folders::TableFolderStore;

#[derive(uniffi::Object)]
pub struct SavedQueryDatabaseStore {
    pub(crate) database: SavedQueryDatabase,
    pub(crate) tasks: Tasks,
}

impl SavedQueryDatabaseStore {
    pub(crate) async fn open(paths: StoragePaths, tasks: Tasks) -> Result<Arc<Self>, CoreError> {
        let database = SavedQueryDatabase::open(&paths).await?;
        Ok(Arc::new(Self { database, tasks }))
    }
}

#[uniffi::export]
impl SavedQueryDatabaseStore {
    // Every store from one database sees the others' writes.
    pub fn saved_queries(&self) -> Arc<SavedQueryStore> {
        SavedQueryStore::new(
            self.database.saved_queries(),
            self.database.saved_query_folders(),
            self.tasks.clone(),
        )
    }

    pub fn favourites(&self) -> Arc<FavouriteStore> {
        FavouriteStore::new(self.database.favourites(), self.tasks.clone())
    }

    pub fn table_folders(&self) -> Arc<TableFolderStore> {
        TableFolderStore::new(self.database.table_folders(), self.tasks.clone())
    }
}

// The files the core keeps queries in, so a host can set what the platform keeps of each, such as an iOS protection
// class. SQLite keeps `-wal` and `-shm` beside each, made again when the database opens, and an upgrade keeps copies
// beside each named `<file>.v<version>-<seconds>`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StoreFilesInfo {
    // Holds the history with every file made beside it, and nothing else. The core makes it only when it is missing, so
    // a host that makes it first with a protection class gives that class to each file in it.
    pub history_folder: String,
    pub history_database: String,
    // Saved queries, their folders, favourites and table folders, which sync reads in the background.
    pub saved_query_database: String,
}

impl std::fmt::Debug for SavedQueryDatabaseStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SavedQueryDatabaseStore")
            .field("path", &self.database.path())
            .finish_non_exhaustive()
    }
}
