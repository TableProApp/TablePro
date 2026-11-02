use sqlx::SqlitePool;

use crate::error::StorageError;

use super::search_fold::fold;

/// An applied migration is never edited. Each schema change is a new
/// timestamped file with its own fixture test.
pub(super) static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Rows folded per transaction, so a large history neither holds one
/// long write nor commits once per row.
const FOLD_BATCH: i64 = 500;

/// Bring the database to this build's schema, refusing one a newer
/// build wrote.
pub(super) async fn migrate(pool: &SqlitePool) -> Result<(), StorageError> {
    MIGRATOR.run(pool).await.map_err(|error| match error {
        // The database carries a version this build does not know,
        // which means a newer binary created it.
        sqlx::migrate::MigrateError::VersionMissing(version) => StorageError::HistoryNewerThanApp { version },
        other => StorageError::HistoryMigration(other),
    })?;
    fold_unfolded_rows(pool).await
}

/// Rows recorded before the search used the folded text have none. SQLite
/// cannot fold beyond ASCII, so the migration leaves them for this.
async fn fold_unfolded_rows(pool: &SqlitePool) -> Result<(), StorageError> {
    loop {
        let rows: Vec<(i64, String)> =
            sqlx::query_as("SELECT id, query FROM history WHERE query_folded IS NULL LIMIT ?")
                .bind(FOLD_BATCH)
                .fetch_all(pool)
                .await?;
        if rows.is_empty() {
            return Ok(());
        }
        let mut transaction = pool.begin().await?;
        for (id, query) in &rows {
            sqlx::query("UPDATE history SET query_folded = ? WHERE id = ?")
                .bind(fold(query))
                .bind(id)
                .execute(&mut *transaction)
                .await?;
        }
        transaction.commit().await?;
    }
}
