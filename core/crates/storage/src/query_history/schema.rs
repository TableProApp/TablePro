use sqlx::SqlitePool;

use crate::error::StorageError;

/// An applied migration is never edited. Each schema change is a new
/// timestamped file with its own fixture test.
pub(super) static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Bring the database to this build's schema, refusing one a newer
/// build wrote.
pub(super) async fn migrate(pool: &SqlitePool) -> Result<(), StorageError> {
    MIGRATOR.run(pool).await.map_err(|error| match error {
        // The database carries a version this build does not know,
        // which means a newer binary created it.
        sqlx::migrate::MigrateError::VersionMissing(version) => StorageError::HistoryNewerThanApp { version },
        other => StorageError::HistoryMigration(other),
    })
}
