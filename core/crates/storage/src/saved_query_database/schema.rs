use sqlx::SqlitePool;
use sqlx::migrate::Migrator;

use crate::error::StorageError;

// An applied migration is never edited. Each schema change is a new timestamped file with its own fixture test.
pub(crate) static MIGRATOR: Migrator = sqlx::migrate!("./saved_query_migrations");

// A version this build has no migration for is what a newer build leaves behind, and is refused.
pub(crate) async fn migrate(pool: &SqlitePool) -> Result<(), StorageError> {
    MIGRATOR.run(pool).await.map_err(|error| match error {
        sqlx::migrate::MigrateError::VersionMissing(version) => StorageError::SavedQueriesNewerThanApp { version },
        other => StorageError::SavedQueriesMigration(other),
    })
}
