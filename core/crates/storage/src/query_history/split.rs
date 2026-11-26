// Saved queries, their folders, favourites and table folders leave `history.db` for `saved_queries.db` (core ADR 0060
// as amended) once, without losing a row, whichever store opens first and wherever a crash cuts the move short. The
// write lock on `history.db` orders every attempt, and until the migration that drops the old tables commits,
// `history.db` is where those rows live. The new store is built beside it as `.saved_queries.db.partial`, synced, and
// renamed into place only after that commit, so `saved_queries.db` never exists half made: a sync that read a half-made
// store would push its missing rows as deletions. A `saved_queries.db` already there while `history.db` still holds
// the rows is what putting back an older `history.db` leaves. That restores the history alone: the saved queries' store
// stays as it is, and the copy the upgrade keeps of the file put back holds its tables.

use std::path::{Path, PathBuf};

use sqlx::migrate::Migrate;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{AssertSqlSafe, ConnectOptions, Connection, SqliteConnection, SqlitePool};
use uuid::Uuid;

use super::schema;
use crate::error::StorageError;
use crate::paths::StoragePaths;

// The history migration that drops the tables the move copied out.
pub(crate) const MOVE_OUT: i64 = 20_261_128_000_000;

// Each moved table with its columns, the rowid among them where the store's copies and full-text joins match on it.
pub(super) const MOVED: [(&str, &str); 6] = [
    (
        "saved_query_folders",
        "id, record_id, connection_id, name, parent_record_id, sort_order, created_at, updated_at",
    ),
    (
        "saved_queries",
        "id, record_id, name, query, connection_id, connection_name, keyword, folder_record_id, sort_order, created_at, \
         updated_at",
    ),
    ("favourite_tables", "connection_id, database, schema, name, created_at"),
    (
        "favourite_databases",
        "connection_id, database, environment, created_at",
    ),
    (
        "table_folders",
        "id, connection_id, database, schema, name, created_at, updated_at",
    ),
    ("table_folder_items", "connection_id, database, schema, name, folder_id"),
];

// One move at a time in this process: two stores opening at once would each copy `history.db` before migrating it, and
// each copy's cleanup removes what the other is still writing. Other processes wait on the write lock instead.
pub(crate) static MOVING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub(crate) fn partial_of(saved: &Path) -> PathBuf {
    let name = saved.file_name().map(|name| name.to_string_lossy()).unwrap_or_default();
    match saved.parent() {
        Some(parent) => parent.join(format!(".{name}.partial")),
        None => PathBuf::from(format!(".{name}.partial")),
    }
}

// Whether the saved queries' store has to look at `history.db` before it opens: it is not there yet, or a move cut
// short left its build beside it.
pub(crate) fn pending(paths: &StoragePaths) -> bool {
    let saved = paths.saved_query_database();
    (!saved.is_file() || partial_of(&saved).exists()) && paths.history_database().is_file()
}

// For the saved queries' store opening first. The copy of `history.db` an upgrade keeps comes first, as when the
// history opens.
pub(crate) async fn move_out_of(paths: &StoragePaths) -> Result<(), StorageError> {
    let _moving = MOVING.lock().await;
    let path = paths.history_database();
    let pool = super::connect(&path).await?;
    let moved = copy_and_move(&pool, &path, paths).await;
    pool.close().await;
    moved
}

async fn copy_and_move(pool: &SqlitePool, path: &Path, paths: &StoragePaths) -> Result<(), StorageError> {
    if let Some(version) = crate::upgrade_copies::pending_upgrade(pool, &schema::MIGRATOR).await? {
        crate::upgrade_copies::keep_database(pool, path, version).await?;
    }
    move_out(pool, paths).await
}

// Before the history's migrations run. A new database gets its schema from them, and one a newer build wrote is left
// for them to refuse.
pub(crate) async fn move_out(pool: &SqlitePool, paths: &StoragePaths) -> Result<(), StorageError> {
    let Some(applied) = applied(pool).await? else {
        return Ok(());
    };
    if applied.contains(&MOVE_OUT) {
        return finish(paths);
    }
    let known: Vec<i64> = schema::MIGRATOR.iter().map(|migration| migration.version).collect();
    if applied.iter().any(|version| !known.contains(version)) {
        return Ok(());
    }
    // The old tables in the form this build copies from.
    schema::migrate_to(MOVE_OUT - 1, pool).await?;

    let mut connection = pool.acquire().await?;
    let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
    if is_applied(&mut transaction, MOVE_OUT).await? {
        transaction.commit().await?;
        return finish(paths);
    }
    let history = paths.history_database();
    let saved = paths.saved_query_database();
    // Left by an attempt cut short before the drop committed, so it holds no row `history.db` does not.
    remove_with_journal(&partial_of(&saved))?;
    if !saved.is_file() {
        build(&partial_of(&saved), &history).await?;
    }
    let migration = schema::MIGRATOR
        .iter()
        .find(|migration| migration.version == MOVE_OUT)
        .ok_or_else(|| StorageError::Schema("the history has no migration that moves the saved queries".to_owned()))?;
    // Inside this transaction, as a savepoint, so the rows were copied under the same lock the drop commits in.
    Migrate::apply(&mut *transaction, &schema::MIGRATOR.table_name, migration)
        .await
        .map_err(StorageError::HistoryMigration)?;
    transaction.commit().await?;
    finish(paths)
}

// None for a database no migration has run on.
async fn applied(pool: &SqlitePool) -> Result<Option<Vec<i64>>, StorageError> {
    let tracked: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'")
            .fetch_one(pool)
            .await?;
    if tracked == 0 {
        return Ok(None);
    }
    Ok(Some(
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations")
            .fetch_all(pool)
            .await?,
    ))
}

async fn is_applied(database: &mut SqliteConnection, version: i64) -> Result<bool, StorageError> {
    let found: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE version = ?")
        .bind(version)
        .fetch_one(&mut *database)
        .await?;
    Ok(found > 0)
}

// The rows went out and `history.db` committed the drop; a crash before the rename leaves the synced build.
fn finish(paths: &StoragePaths) -> Result<(), StorageError> {
    let saved = paths.saved_query_database();
    let partial = partial_of(&saved);
    if !partial.exists() {
        return Ok(());
    }
    if saved.exists() {
        // Only a hand-made state gets here. Neither file is the other's to replace.
        tracing::warn!("a build of the saved queries' store waits beside one that is in use");
        return Ok(());
    }
    let error = |source| StorageError::Write {
        path: saved.clone(),
        source,
    };
    std::fs::rename(&partial, &saved).map_err(error)?;
    if let Some(directory) = saved.parent() {
        tablepro_core::sync_directory(directory).map_err(error)?;
    }
    Ok(())
}

async fn build(partial: &Path, history: &Path) -> Result<(), StorageError> {
    let built = fill(partial, history).await;
    if built.is_err() {
        let _ = remove_with_journal(partial);
    }
    built
}

// With a rollback journal, so the one file it leaves once closed is the build.
async fn fill(partial: &Path, history: &Path) -> Result<(), StorageError> {
    crate::fs::create_private_file_if_missing(partial)?;
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(partial)
                .journal_mode(sqlx::sqlite::SqliteJournalMode::Delete)
                .disable_statement_logging(),
        )
        .await?;
    let copied = copy_into(&pool, history).await;
    pool.close().await;
    copied?;
    // Windows flushes only a handle opened for writing.
    std::fs::OpenOptions::new()
        .write(true)
        .open(partial)
        .and_then(|file| file.sync_all())
        .map_err(|source| StorageError::Write {
            path: partial.to_owned(),
            source,
        })
}

async fn copy_into(pool: &SqlitePool, history: &Path) -> Result<(), StorageError> {
    crate::saved_query_database::schema::migrate(pool).await?;
    let mut database = pool.acquire().await?;
    copy_rows(&mut database, history).await
}

// In one transaction: every moved row, the AUTOINCREMENT counters so no deleted rowid comes back, and a generation.
async fn copy_rows(database: &mut SqliteConnection, history: &Path) -> Result<(), StorageError> {
    let source = history.to_str().ok_or_else(|| StorageError::Io {
        path: history.to_owned(),
        source: std::io::Error::new(std::io::ErrorKind::InvalidInput, "the path is not UTF-8"),
    })?;
    sqlx::query("ATTACH DATABASE ? AS moving")
        .bind(source.to_owned())
        .execute(&mut *database)
        .await?;
    let copied = copy_attached(&mut *database).await;
    let detached = sqlx::query("DETACH DATABASE moving").execute(&mut *database).await;
    copied?;
    detached?;
    Ok(())
}

// Deferred, since IMMEDIATE would also lock `history.db`, whose write lock the move already holds; the copy reads it.
async fn copy_attached(database: &mut SqliteConnection) -> Result<(), StorageError> {
    {
        let mut transaction = database.begin().await?;
        for (table, columns) in MOVED {
            sqlx::query(AssertSqlSafe(format!(
                "INSERT INTO main.{table} ({columns}) SELECT {columns} FROM moving.{table}"
            )))
            .execute(&mut *transaction)
            .await?;
        }
        sqlx::query(
            "UPDATE main.sqlite_sequence \
             SET seq = (SELECT kept.seq FROM moving.sqlite_sequence kept WHERE kept.name = main.sqlite_sequence.name) \
             WHERE seq < (SELECT kept.seq FROM moving.sqlite_sequence kept WHERE kept.name = main.sqlite_sequence.name)",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO main.sqlite_sequence (name, seq) \
             SELECT kept.name, kept.seq FROM moving.sqlite_sequence kept \
             WHERE kept.name IN ('saved_queries', 'saved_query_folders') \
             AND NOT EXISTS (SELECT 1 FROM main.sqlite_sequence held WHERE held.name = kept.name)",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query("INSERT INTO main.store_identity (id, generation, sequence) VALUES (1, ?, 0)")
            .bind(Uuid::new_v4().to_string())
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
    }
    Ok(())
}

// The build runs with a rollback journal, so that is the one file beside it.
fn remove_with_journal(path: &Path) -> Result<(), StorageError> {
    let mut journal = path.as_os_str().to_owned();
    journal.push("-journal");
    for file in [PathBuf::from(journal), path.to_owned()] {
        match std::fs::remove_file(&file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(StorageError::Io {
                    path: file,
                    source: error,
                });
            }
            _ => {}
        }
    }
    Ok(())
}
