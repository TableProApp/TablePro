// The saved queries' database, `saved_queries.db`: saved queries and their folders, favourite tables and databases,
// and table folders (core ADR 0017, 0052), one store with one generation and one journal (0060 as amended). It holds
// no history, so sync reads it while the history stays behind a stronger protection class.

pub(crate) mod schema;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use sqlx::SqlitePool;
use tokio::sync::watch;
use uuid::Uuid;

use crate::error::StorageError;
use crate::journal::{ChangeJournal, JournalSlot, Signals};
use crate::paths::StoragePaths;
use crate::query_history::LiveFiles;
use crate::store_identity::StoreIdentity;

// Cloning shares the pool, and every handle it gives out shares one revision feed and one journal.
#[derive(Debug, Clone)]
pub struct SavedQueryDatabase {
    pool: SqlitePool,
    path: PathBuf,
    files: LiveFiles,
    signals: Signals,
    journal: JournalSlot,
}

impl SavedQueryDatabase {
    // Reads `history.db` only when this store is not there yet or a move out of it was cut short.
    pub async fn open(paths: &StoragePaths) -> Result<Self, StorageError> {
        if crate::query_history::split::pending(paths) {
            crate::query_history::split::move_out_of(paths).await?;
        }
        let path = paths.saved_query_database();
        let pool = prepared_pool(&path).await?;
        let journal = JournalSlot::default();
        Ok(Self {
            pool,
            path,
            files: LiveFiles::of(paths),
            signals: Signals::new(Arc::new(watch::channel(0).0), journal.clone()),
            journal,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    #[cfg(test)]
    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    // The journal every later write through this database's handles tells, or none.
    pub fn set_journal(&self, journal: Option<Arc<dyn ChangeJournal>>) {
        self.journal.set(journal);
    }

    pub async fn identity(&self) -> Result<StoreIdentity, StorageError> {
        let (generation, sequence): (String, i64) =
            sqlx::query_as("SELECT generation, sequence FROM store_identity WHERE id = 1")
                .fetch_one(&self.pool)
                .await?;
        Ok(StoreIdentity {
            generation: Uuid::parse_str(&generation)
                .map_err(|_| StorageError::Schema("the saved queries' generation is not a UUID".to_owned()))?,
            sequence: u64::try_from(sequence).unwrap_or(0),
        })
    }

    // For a host that restored the file from a backup of its own: a new generation tells sync the store is not the
    // one it last saw.
    pub async fn start_new_generation(&self) -> Result<StoreIdentity, StorageError> {
        sqlx::query("UPDATE store_identity SET generation = ?, sequence = sequence + 1 WHERE id = 1")
            .bind(Uuid::new_v4().to_string())
            .execute(&self.pool)
            .await?;
        self.identity().await
    }

    pub fn saved_queries(&self) -> crate::saved_queries::SavedQueries {
        crate::saved_queries::SavedQueries::new(self.pool.clone(), self.files.clone(), self.signals.clone())
    }

    pub fn saved_query_folders(&self) -> crate::saved_queries::SavedQueryFolders {
        crate::saved_queries::SavedQueryFolders::new(self.pool.clone(), self.files.clone(), self.signals.clone())
    }

    pub fn favourites(&self) -> crate::favourites::Favourites {
        crate::favourites::Favourites::new(self.pool.clone(), self.files.clone(), self.signals.clone())
    }

    pub fn table_folders(&self) -> crate::table_folders::TableFolders {
        crate::table_folders::TableFolders::new(self.pool.clone(), self.files.clone(), self.signals.clone())
    }
}

// The file at this build's schema: copied first when an older build wrote it (core ADR 0012), and stamped with a
// generation when it has none.
pub(crate) async fn prepared_pool(path: &Path) -> Result<SqlitePool, StorageError> {
    let pool = crate::query_history::connect(path).await?;
    if let Err(error) = prepare(&pool, path).await {
        pool.close().await;
        return Err(error);
    }
    Ok(pool)
}

async fn prepare(pool: &SqlitePool, path: &Path) -> Result<(), StorageError> {
    if let Some(version) = crate::upgrade_copies::pending_upgrade(pool, &schema::MIGRATOR).await? {
        crate::upgrade_copies::keep_database(pool, path, version).await?;
    }
    schema::migrate(pool).await?;
    sqlx::query("INSERT INTO store_identity (id, generation, sequence) VALUES (1, ?, 0) ON CONFLICT (id) DO NOTHING")
        .bind(Uuid::new_v4().to_string())
        .execute(pool)
        .await?;
    Ok(())
}
