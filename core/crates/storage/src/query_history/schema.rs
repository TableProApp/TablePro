use sqlx::SqlitePool;
use sqlx::migrate::{MigrateError, Migrator};

use crate::error::StorageError;

// An applied migration is never edited. Each schema change is a new timestamped file with its own fixture test.
pub(super) static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

pub(super) async fn migrate(pool: &SqlitePool) -> Result<(), StorageError> {
    MIGRATOR.run(pool).await.map_err(refused)
}

// Every migration up to and including `version`.
pub(super) async fn migrate_to(version: i64, pool: &SqlitePool) -> Result<(), StorageError> {
    MIGRATOR.run_to(version, pool).await.map_err(refused)
}

// A version this build has no migration for is what a newer build leaves behind.
fn refused(error: MigrateError) -> StorageError {
    match error {
        MigrateError::VersionMissing(version) => StorageError::HistoryNewerThanApp { version },
        other => StorageError::HistoryMigration(other),
    }
}
