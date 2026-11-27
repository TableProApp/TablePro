// Saved queries, their folders, favourites and table folders leave `history.db` for `saved_queries.db` (core ADR 0060
// as amended) once, without losing a row, whichever store opens first and wherever a crash cuts the move short. The
// write lock on `history.db` orders every attempt, and until the migration that drops the old tables commits,
// `history.db` is where those rows live. The new store is built beside it as `.saved_queries.db.partial`, synced, and
// renamed into place only after that commit, so `saved_queries.db` never exists half made: a sync that read a half-made
// store would push its missing rows as deletions. A `saved_queries.db` already there while `history.db` still holds
// the rows is what putting back an older `history.db` leaves. That restores the history alone: the saved queries' store
// stays as it is, and the copy the upgrade keeps of the file put back holds its tables. In the same move `history.db`
// leaves the state folder for `history/`, with its upgrade copies, so a platform that protects files by folder covers
// every file SQLite and the copies make beside it. What stays in the state folder is an empty `history.db` that older
// builds refuse to open.

use std::path::{Path, PathBuf};

use sqlx::migrate::Migrate;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqliteLockingMode, SqlitePoolOptions};
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

// Where builds before the move kept the history, beside the other stores.
pub(crate) fn history_before_move(paths: &StoragePaths) -> PathBuf {
    paths.state.join("history.db")
}

// Whether the saved queries' store has to look at `history.db` before it opens: it is not there yet, or a move cut
// short left its build beside it.
fn pending(paths: &StoragePaths) -> bool {
    let saved = paths.saved_query_database();
    (!saved.is_file() || partial_of(&saved).exists()) && paths.history_database().is_file()
}

// For the saved queries' store opening first. The copy of `history.db` an upgrade keeps comes first, as when the
// history opens. With nothing to move it reads no more of the history than whether its files are there.
pub(crate) async fn before_saved_queries_open(paths: &StoragePaths) -> Result<(), StorageError> {
    let _moving = MOVING.lock().await;
    relocate(paths).await?;
    if !pending(paths) {
        return Ok(());
    }
    let path = paths.history_database();
    let pool = super::connect(&path).await?;
    let moved = copy_and_move(&pool, &path, paths).await;
    pool.close().await;
    moved
}

// The version no build has a migration for. An older build reads it as a file a newer build wrote and refuses to open
// it, so none writes where the history no longer lives.
pub(crate) const MOVED_AWAY: i64 = i64::MAX;

// Into `history/` once, before anything opens it there. A database already in the folder is this build's, so a file an
// older build made where the history used to be is left as it is. The old file is copied out under a lock no other
// connection shares, and, under that same lock, emptied and marked before the copy takes its place, so a write lands
// either before the copy or nowhere: another process already holding the file refuses the move, and an older build
// opening it after refuses the file.
pub(crate) async fn relocate(paths: &StoragePaths) -> Result<(), StorageError> {
    let old = history_before_move(paths);
    if paths.history_database().exists() {
        return Ok(());
    }
    let folder = paths.history_folder();
    if !old.exists() {
        // Copies without their file: no process holds it, so there is no lock to take.
        if crate::upgrade_copies::copies_blocking(&old)?.is_empty() {
            return Ok(());
        }
        crate::fs::ensure_private_dir(&folder)?;
        move_copies(&old, &folder)?;
        return sync_directories(paths);
    }
    let mut held = hold(&old).await?;
    let moved = move_held(&mut held, paths).await;
    let released = held.close().await;
    moved?;
    released?;
    Ok(())
}

// Exclusive locking keeps every lock the connection takes until it closes. Switching a WAL file to a rollback journal
// needs the only connection to it and writes the WAL back into it first, and the write transaction takes the lock
// when the file already had a rollback journal.
async fn hold(path: &Path) -> Result<SqliteConnection, StorageError> {
    let connected = SqliteConnectOptions::new()
        .filename(path)
        .locking_mode(SqliteLockingMode::Exclusive)
        .journal_mode(SqliteJournalMode::Delete)
        .pragma("secure_delete", "ON")
        .disable_statement_logging()
        .connect()
        .await;
    let mut database = match connected {
        Ok(database) => database,
        Err(error) if busy(&error) => return Err(held_elsewhere(path)),
        Err(error) => return Err(error.into()),
    };
    match take_lock(&mut database, path).await {
        Ok(()) => Ok(database),
        Err(error) => {
            let _ = database.close().await;
            Err(error)
        }
    }
}

async fn take_lock(database: &mut SqliteConnection, path: &Path) -> Result<(), StorageError> {
    let mut transaction = match database.begin_with(AssertSqlSafe("BEGIN EXCLUSIVE")).await {
        Ok(transaction) => transaction,
        Err(error) if busy(&error) => return Err(held_elsewhere(path)),
        Err(error) => return Err(error.into()),
    };
    let mode: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(&mut *transaction)
        .await?;
    transaction.commit().await?;
    let wal = sidecar(path, "-wal");
    let left = std::fs::metadata(&wal).map(|found| found.len() > 0).unwrap_or(false);
    if !mode.eq_ignore_ascii_case("delete") || left {
        return Err(held_elsewhere(path));
    }
    Ok(())
}

fn busy(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .and_then(|code| code.parse::<i32>().ok())
        // SQLITE_BUSY and SQLITE_LOCKED, with any extended code.
        .is_some_and(|code| matches!(code & 0xff, 5 | 6))
}

fn held_elsewhere(path: &Path) -> StorageError {
    StorageError::Io {
        path: path.to_owned(),
        source: std::io::Error::new(std::io::ErrorKind::WouldBlock, "another process holds the history open"),
    }
}

// A crash leaves the old file whole and unmarked, so the next open copies it again, or marked with its synced copy in
// the folder, which the next open renames into place. The upgrade copies move only under the lock, so a move another
// process refuses leaves them where an older build's cleanup finds them.
async fn move_held(database: &mut SqliteConnection, paths: &StoragePaths) -> Result<(), StorageError> {
    let old = history_before_move(paths);
    let new = paths.history_database();
    let folder = paths.history_folder();
    let partial = partial_of(&new);
    crate::fs::ensure_private_dir(&folder)?;
    if !is_marked(database).await? {
        remove_with_journal(&partial)?;
        copy_out(database, &partial).await?;
        #[cfg(test)]
        pause_here(&old).await;
        mark(database).await?;
    }
    if let Err(error) = sqlx::query("VACUUM").execute(&mut *database).await {
        tracing::warn!(%error, "the file the history left keeps its size");
    }
    // A rollback journal leaves the WAL index unused.
    if let Err(error) = std::fs::remove_file(sidecar(&old, "-shm"))
        && error.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!(%error, "the WAL index of the file the history left stays");
    }
    crate::upgrade_copies::remove_leftovers_blocking(&old)?;
    move_copies(&old, &folder)?;
    if partial.exists() {
        rename(&partial, &new)?;
    }
    sync_directories(paths)
}

async fn is_marked(database: &mut SqliteConnection) -> Result<bool, StorageError> {
    let tracked: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'")
            .fetch_one(&mut *database)
            .await?;
    if tracked == 0 {
        return Ok(false);
    }
    is_applied(database, MOVED_AWAY).await
}

async fn copy_out(database: &mut SqliteConnection, partial: &Path) -> Result<(), StorageError> {
    let error = |source| StorageError::Write {
        path: partial.to_owned(),
        source,
    };
    crate::upgrade_copies::vacuum_into_new_file(&mut *database, partial)
        .await
        .map_err(error)?;
    // Windows flushes only a handle opened for writing.
    std::fs::OpenOptions::new()
        .write(true)
        .open(partial)
        .and_then(|file| file.sync_all())
        .map_err(error)?;
    let folder = partial.parent().unwrap_or_else(|| Path::new("."));
    tablepro_core::sync_directory(folder).map_err(error)
}

// Every table goes, its pages zeroed as they are freed, and the version no build knows comes in, in one transaction.
async fn mark(database: &mut SqliteConnection) -> Result<(), StorageError> {
    let mut transaction = database.begin().await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS _sqlx_migrations (version BIGINT PRIMARY KEY, description TEXT NOT NULL, \
         installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, success BOOLEAN NOT NULL, checksum BLOB NOT NULL, \
         execution_time BIGINT NOT NULL)",
    )
    .execute(&mut *transaction)
    .await?;
    // Virtual tables first, since each takes its shadow tables with it.
    for filter in ["type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%'", "type = 'table'"] {
        let names: Vec<String> = sqlx::query_scalar(AssertSqlSafe(format!(
            "SELECT name FROM sqlite_master WHERE {filter} AND name <> '_sqlx_migrations' AND name NOT LIKE 'sqlite\\_%' \
             ESCAPE '\\'"
        )))
        .fetch_all(&mut *transaction)
        .await?;
        for name in names {
            sqlx::query(AssertSqlSafe(format!(
                "DROP TABLE IF EXISTS \"{}\"",
                name.replace('"', "\"\"")
            )))
            .execute(&mut *transaction)
            .await?;
        }
    }
    let views: Vec<String> = sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'view'")
        .fetch_all(&mut *transaction)
        .await?;
    for name in views {
        sqlx::query(AssertSqlSafe(format!(
            "DROP VIEW IF EXISTS \"{}\"",
            name.replace('"', "\"\"")
        )))
        .execute(&mut *transaction)
        .await?;
    }
    sqlx::query(
        "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) \
         VALUES (?, 'the history moved into its folder', 1, x'', 0)",
    )
    .bind(MOVED_AWAY)
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    Ok(())
}

// Journals with their copies, as `upgrade_copies::move_with_sidecars_blocking` orders them.
fn move_copies(old: &Path, folder: &Path) -> Result<(), StorageError> {
    for copy in crate::upgrade_copies::copies_blocking(old)? {
        let name = copy.path.file_name().map(ToOwned::to_owned).unwrap_or_default();
        crate::upgrade_copies::move_with_sidecars_blocking(&copy.path, &folder.join(name))?;
    }
    Ok(())
}

fn sync_directories(paths: &StoragePaths) -> Result<(), StorageError> {
    for directory in [&paths.state, &paths.history_folder()] {
        tablepro_core::sync_directory(directory).map_err(|source| StorageError::Write {
            path: directory.clone(),
            source,
        })?;
    }
    Ok(())
}

#[cfg(test)]
pub(super) struct Pause {
    pub(super) path: PathBuf,
    pub(super) held: tokio::sync::oneshot::Sender<()>,
    pub(super) resume: tokio::sync::oneshot::Receiver<()>,
}

// For a test to act while the move holds the old file, its copy made and the file not yet marked.
#[cfg(test)]
pub(super) static PAUSES: std::sync::Mutex<Vec<Pause>> = std::sync::Mutex::new(Vec::new());

#[cfg(test)]
async fn pause_here(path: &Path) {
    let found = {
        let mut pauses = PAUSES.lock().expect("pauses");
        pauses
            .iter()
            .position(|pause| pause.path == path)
            .map(|at| pauses.remove(at))
    };
    if let Some(pause) = found {
        let _ = pause.held.send(());
        let _ = pause.resume.await;
    }
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

fn rename(from: &Path, to: &Path) -> Result<(), StorageError> {
    std::fs::rename(from, to).map_err(|source| StorageError::Write {
        path: to.to_owned(),
        source,
    })
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
    take_out(pool, paths).await?;
    compact_if_owed(pool).await
}

pub(super) async fn take_out(pool: &SqlitePool, paths: &StoragePaths) -> Result<(), StorageError> {
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
    sqlx::query(AssertSqlSafe(format!(
        "CREATE TABLE IF NOT EXISTS {COMPACTION_OWED} (id INTEGER PRIMARY KEY CHECK (id = 1))"
    )))
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    finish(paths)
}

// Written with the drop, so an open after a crash still compacts the file.
pub(super) const COMPACTION_OWED: &str = "compaction_owed";

// The text of the saved queries stays in the pages the drop freed until a VACUUM rewrites the file, and in the file and
// its WAL until a checkpoint folds the rewrite in and empties the WAL. A checkpoint another connection blocks leaves it
// owed for the next open, and so does a VACUUM that fails, which costs only space.
async fn compact_if_owed(pool: &SqlitePool) -> Result<(), StorageError> {
    let owed: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?")
        .bind(COMPACTION_OWED)
        .fetch_one(pool)
        .await?;
    if owed == 0 {
        return Ok(());
    }
    let mut connection = pool.acquire().await?;
    if let Err(error) = sqlx::query("VACUUM").execute(&mut *connection).await {
        tracing::warn!(%error, "the history keeps the pages the saved queries left until it can be compacted");
        return Ok(());
    }
    let (blocked, frames, folded): (i64, i64, i64) = sqlx::query_as("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_one(&mut *connection)
        .await?;
    if blocked != 0 || frames != folded {
        return Ok(());
    }
    sqlx::query(AssertSqlSafe(format!("DROP TABLE {COMPACTION_OWED}")))
        .execute(&mut *connection)
        .await?;
    Ok(())
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
