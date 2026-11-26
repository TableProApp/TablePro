use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

use super::schema;
use crate::paths::StoragePaths;

// The first migrations: 1 is what Linux 0.1.0 beta.1 to beta.3 shipped, 3 what beta.4 and beta.5 shipped.
pub(super) const BETA_3: usize = 1;
pub(super) const BETA_5: usize = 3;

pub(super) async fn old_database(root: &tempfile::TempDir, migrations: usize) -> (StoragePaths, SqlitePool) {
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    crate::fs::create_private_file_if_missing(&paths.history_database()).expect("file");
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(paths.history_database())
                .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal),
        )
        .await
        .expect("pool");
    sqlx::migrate::Migrator::with_migrations(schema::MIGRATOR.iter().take(migrations).cloned().collect())
        .run(&pool)
        .await
        .expect("old migrations");
    (paths, pool)
}
