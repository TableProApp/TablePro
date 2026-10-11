use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;

const MAX_QUERY_BYTES: usize = 1024 * 1024;

#[derive(Clone)]
pub struct HistoryStore {
    pool: SqlitePool,
    path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Source {
    #[default]
    Editor,
    Structure,
    Browse,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Editor => "editor",
            Source::Structure => "structure",
            Source::Browse => "browse",
        }
    }

    pub fn from_stored(raw: &str) -> Source {
        match raw {
            "structure" => Source::Structure,
            "browse" => Source::Browse,
            _ => Source::Editor,
        }
    }
}

#[derive(Debug, Clone)]
pub enum Outcome {
    Success,
    Error(String),
    Cancelled,
}

#[derive(Debug, Clone)]
pub struct NewEntry {
    pub query: String,
    pub driver_id: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub executed_at: SystemTime,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: Outcome,
    pub source: Source,
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub id: i64,
    pub query: String,
    pub driver_id: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub executed_at: SystemTime,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub success: bool,
    pub cancelled: bool,
    pub pinned: bool,
    pub error: Option<String>,
    pub source: Source,
}

#[derive(Debug, Clone, Default)]
pub struct SearchFilter {
    pub needle: Option<String>,
    pub connection_id: Option<Uuid>,
    pub success_only: Option<bool>,
    pub exclude_cancelled: Option<bool>,
    pub min_executed_at: Option<SystemTime>,
    pub source: Option<Source>,
    pub limit: usize,
}

pub fn default_db_path() -> Option<PathBuf> {
    crate::config_path("history.db").ok()
}

impl HistoryStore {
    pub async fn open_default() -> Result<Self, StorageError> {
        let Some(path) = default_db_path() else {
            return Err(StorageError::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "no XDG_CONFIG_HOME or HOME",
            )));
        };
        Self::open(path).await
    }

    pub async fn open(path: PathBuf) -> Result<Self, StorageError> {
        let _migration_lock = crate::file_access::lock_path(&path).await?;
        let existed = path.exists();
        create_private_file_if_missing(&path)?;
        let opts = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
        let pool = SqlitePoolOptions::new().max_connections(1).connect_with(opts).await?;
        if existed && user_version(&pool).await? < MIGRATIONS.len() as i64 {
            backup_before_migration(&pool, &path).await?;
        }
        apply_schema(&pool).await?;
        restrict_permissions(&path)?;
        Ok(Self { pool, path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Creates the database file with 0600 up front so sqlx never has a chance
/// to create it at its own default mode; a fresh file is the common case.
fn create_private_file_if_missing(path: &PathBuf) -> Result<(), StorageError> {
    use std::os::unix::fs::OpenOptionsExt;
    if path.exists() {
        return Ok(());
    }
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map(|_| ())
        .or_else(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                Ok(())
            } else {
                Err(StorageError::Io(error))
            }
        })
}

/// Restricts the main database file and its WAL/SHM siblings, covering both
/// a database already created with wider permissions by an older build and
/// the WAL/SHM files sqlx creates on its own once WAL mode is active.
fn restrict_permissions(path: &Path) -> Result<(), StorageError> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let Some(file_name) = path.file_name().and_then(std::ffi::OsStr::to_str) else {
        return Ok(());
    };
    for suffix in ["-wal", "-shm"] {
        let sibling = path.with_file_name(format!("{file_name}{suffix}"));
        if sibling.exists() {
            std::fs::set_permissions(&sibling, std::fs::Permissions::from_mode(0o600))?;
        }
    }
    Ok(())
}

struct Migration {
    statements: &'static [&'static str],
}

const BASE_SCHEMA: &[&str] = &[
    r#"
        CREATE TABLE IF NOT EXISTS history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            query           TEXT NOT NULL,
            driver_id       TEXT NOT NULL,
            connection_id   TEXT NOT NULL,
            connection_name TEXT NOT NULL,
            executed_at     INTEGER NOT NULL,
            duration_ms     INTEGER,
            rows_affected   INTEGER,
            success         INTEGER NOT NULL,
            cancelled       INTEGER NOT NULL DEFAULT 0,
            pinned          INTEGER NOT NULL DEFAULT 0,
            error           TEXT
        )
        "#,
    r#"
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
            query,
            content='history',
            content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        )
        "#,
    r#"
        CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
            INSERT INTO history_fts(rowid, query) VALUES (new.id, new.query);
        END
        "#,
    r#"
        CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
            INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.id, old.query);
        END
        "#,
    r#"
        CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE OF query ON history BEGIN
            INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.id, old.query);
            INSERT INTO history_fts(rowid, query) VALUES (new.id, new.query);
        END
        "#,
    "CREATE INDEX IF NOT EXISTS history_executed_at_idx ON history (executed_at DESC)",
    "CREATE INDEX IF NOT EXISTS history_pinned_idx ON history (pinned DESC, executed_at DESC)",
    "CREATE INDEX IF NOT EXISTS history_connection_idx ON history (connection_id, executed_at DESC)",
];

/// SQLite fills existing rows from the constant DEFAULT and rewrites only the
/// table header, so the external-content FTS5 index over `history` keeps its
/// rowid mapping and needs no rebuild.
const ADD_SOURCE: &[&str] = &["ALTER TABLE history ADD COLUMN source TEXT NOT NULL DEFAULT 'editor'"];

const MIGRATIONS: &[Migration] = &[
    Migration {
        statements: BASE_SCHEMA,
    },
    Migration { statements: ADD_SOURCE },
];

async fn user_version(pool: &SqlitePool) -> Result<i64, StorageError> {
    let row = sqlx::query("PRAGMA user_version").fetch_one(pool).await?;
    Ok(row.try_get::<i64, _>(0)?)
}

fn pending_migrations(applied: i64) -> &'static [Migration] {
    let applied = applied.clamp(0, MIGRATIONS.len() as i64) as usize;
    &MIGRATIONS[applied..]
}

async fn apply_schema(pool: &SqlitePool) -> Result<(), StorageError> {
    let applied = user_version(pool).await?;
    let mut version = applied.clamp(0, MIGRATIONS.len() as i64);
    for migration in pending_migrations(applied) {
        let mut tx = pool.begin().await?;
        for statement in migration.statements {
            sqlx::query(*statement).execute(&mut *tx).await?;
        }
        version += 1;
        sqlx::query(sqlx::AssertSqlSafe(format!("PRAGMA user_version = {version}")))
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
    }
    Ok(())
}

async fn backup_before_migration(pool: &SqlitePool, path: &Path) -> Result<(), StorageError> {
    let backup = path.with_extension("before-migrations.db");
    match std::fs::symlink_metadata(&backup) {
        Ok(meta) if meta.file_type().is_file() => return Ok(()),
        Ok(_) => return Err(StorageError::Schema("history backup is not a regular file".into())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    let parent = path
        .parent()
        .ok_or_else(|| StorageError::Schema("history path has no parent".into()))?;
    let temp = parent.join(format!(".history-backup-{}.tmp", Uuid::new_v4()));
    let result = async {
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        let temp_name = temp
            .to_str()
            .ok_or_else(|| StorageError::Schema("history backup path is not UTF-8".into()))?;
        sqlx::query("VACUUM INTO ?").bind(temp_name).execute(pool).await?;
        File::open(&temp)?.sync_all()?;
        std::fs::rename(&temp, &backup)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    }
    .await;
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

fn to_unix(t: SystemTime) -> i64 {
    // System clocks before 1970 (clock skew, VM snapshots) should not collapse
    // every record to epoch — preserve the negative offset so timestamps round-trip.
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(e) => -(e.duration().as_secs() as i64),
    }
}

fn from_unix(s: i64) -> SystemTime {
    if s >= 0 {
        UNIX_EPOCH + std::time::Duration::from_secs(s as u64)
    } else {
        UNIX_EPOCH - std::time::Duration::from_secs((-s) as u64)
    }
}

impl HistoryStore {
    pub async fn record(&self, entry: NewEntry) -> Result<i64, StorageError> {
        if entry.query.len() > MAX_QUERY_BYTES {
            return Err(StorageError::TooLarge {
                got: entry.query.len(),
                limit: MAX_QUERY_BYTES,
            });
        }
        let pool = &self.pool;
        let executed_at = to_unix(entry.executed_at);
        let (success, cancelled, error_text) = match &entry.outcome {
            Outcome::Success => (1_i64, 0_i64, None),
            Outcome::Error(msg) => (0, 0, Some(msg.clone())),
            Outcome::Cancelled => (0, 1, None),
        };
        let id = sqlx::query(
            r#"
        INSERT INTO history (
            query, driver_id, connection_id, connection_name,
            executed_at, duration_ms, rows_affected,
            success, cancelled, error, source
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        "#,
        )
        .bind(&entry.query)
        .bind(&entry.driver_id)
        .bind(entry.connection_id.to_string())
        .bind(&entry.connection_name)
        .bind(executed_at)
        .bind(entry.duration_ms)
        .bind(entry.rows_affected)
        .bind(success)
        .bind(cancelled)
        .bind(error_text)
        .bind(entry.source.as_str())
        .execute(pool)
        .await?
        .last_insert_rowid();
        Ok(id)
    }

    pub async fn search(&self, filter: SearchFilter) -> Result<Vec<Entry>, StorageError> {
        let pool = &self.pool;
        let limit_usize = if filter.limit == 0 { 200 } else { filter.limit };
        // Cap to a value that fits losslessly in i64 (no negative-LIMIT surprise
        // in SQLite, which would silently disable the limit).
        let limit = limit_usize.min(i64::MAX as usize) as i64;

        let mut sql = String::from(
            "SELECT h.id, h.query, h.driver_id, h.connection_id, h.connection_name, \
         h.executed_at, h.duration_ms, h.rows_affected, h.success, h.cancelled, h.pinned, h.error, h.source \
         FROM history h ",
        );
        let mut wheres: Vec<&str> = Vec::new();
        // FTS5 requires the MATCH operator to be applied directly to the
        // virtual-table reference; combining it with other WHERE predicates
        // via AND raises "unable to use function MATCH in the requested
        // context" on some SQLite builds. Pinning the predicate to the JOIN
        // condition keeps it isolated from the user-filter predicates below.
        if filter.needle.is_some() {
            sql.push_str("JOIN history_fts fts ON fts.rowid = h.id AND history_fts MATCH ? ");
        }
        if filter.connection_id.is_some() {
            wheres.push("h.connection_id = ?");
        }
        if let Some(success_only) = filter.success_only {
            if success_only {
                wheres.push("h.success = 1 AND h.cancelled = 0");
            } else {
                wheres.push("h.success = 0");
            }
        }
        if filter.exclude_cancelled == Some(true) {
            wheres.push("h.cancelled = 0");
        } else if filter.exclude_cancelled == Some(false) {
            wheres.push("h.cancelled = 1");
        }
        if filter.min_executed_at.is_some() {
            wheres.push("h.executed_at >= ?");
        }
        if filter.source.is_some() {
            wheres.push("h.source = ?");
        }
        if !wheres.is_empty() {
            sql.push_str("WHERE ");
            sql.push_str(&wheres.join(" AND "));
            sql.push(' ');
        }
        sql.push_str("ORDER BY h.pinned DESC, h.executed_at DESC LIMIT ?");

        let mut q = sqlx::query(sqlx::AssertSqlSafe(sql.as_str()));
        if let Some(needle) = &filter.needle {
            q = q.bind(needle);
        }
        if let Some(conn_id) = filter.connection_id {
            q = q.bind(conn_id.to_string());
        }
        if let Some(min_ts) = filter.min_executed_at {
            q = q.bind(to_unix(min_ts));
        }
        if let Some(source) = filter.source {
            q = q.bind(source.as_str());
        }
        q = q.bind(limit);

        let rows = q.fetch_all(pool).await?;
        rows.into_iter().map(Self::row_to_entry).collect()
    }

    fn row_to_entry(row: sqlx::sqlite::SqliteRow) -> Result<Entry, StorageError> {
        let conn_id_str: String = row.try_get("connection_id")?;
        let connection_id = Uuid::parse_str(&conn_id_str).unwrap_or_default();
        let executed_at: i64 = row.try_get("executed_at")?;
        let success_i: i64 = row.try_get("success")?;
        let cancelled_i: i64 = row.try_get("cancelled")?;
        let pinned_i: i64 = row.try_get("pinned")?;
        let source: String = row.try_get("source")?;
        Ok(Entry {
            id: row.try_get("id")?,
            query: row.try_get("query")?,
            driver_id: row.try_get("driver_id")?,
            connection_id,
            connection_name: row.try_get("connection_name")?,
            executed_at: from_unix(executed_at),
            duration_ms: row.try_get::<Option<i64>, _>("duration_ms")?,
            rows_affected: row.try_get::<Option<i64>, _>("rows_affected")?,
            success: success_i != 0,
            cancelled: cancelled_i != 0,
            pinned: pinned_i != 0,
            error: row.try_get::<Option<String>, _>("error")?,
            source: Source::from_stored(&source),
        })
    }

    pub async fn set_pinned(&self, id: i64, pinned: bool) -> Result<(), StorageError> {
        let pool = &self.pool;
        sqlx::query("UPDATE history SET pinned = ? WHERE id = ?")
            .bind(if pinned { 1_i64 } else { 0 })
            .bind(id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn delete(&self, id: i64) -> Result<(), StorageError> {
        let pool = &self.pool;
        sqlx::query("DELETE FROM history WHERE id = ?")
            .bind(id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn delete_many(&self, ids: &[i64]) -> Result<usize, StorageError> {
        if ids.is_empty() {
            return Ok(0);
        }
        let pool = &self.pool;
        let placeholders = vec!["?"; ids.len()].join(",");
        let sql = format!("DELETE FROM history WHERE id IN ({placeholders})");
        let mut q = sqlx::query(sqlx::AssertSqlSafe(sql.as_str()));
        for id in ids {
            q = q.bind(id);
        }
        let affected = q.execute(pool).await?.rows_affected();
        Ok(affected as usize)
    }

    pub async fn clear_all(&self) -> Result<usize, StorageError> {
        let pool = &self.pool;
        let affected = sqlx::query("DELETE FROM history").execute(pool).await?.rows_affected();
        Ok(affected as usize)
    }

    pub async fn prune_older_than(&self, retention_days: u32) -> Result<usize, StorageError> {
        if retention_days == 0 {
            return Ok(0);
        }
        let pool = &self.pool;
        let cutoff = SystemTime::now() - std::time::Duration::from_secs(retention_days as u64 * 86_400);
        let cutoff_unix = to_unix(cutoff);
        let affected = sqlx::query("DELETE FROM history WHERE pinned = 0 AND executed_at < ?")
            .bind(cutoff_unix)
            .execute(pool)
            .await?
            .rows_affected();
        Ok(affected as usize)
    }

    pub async fn fetch_by_ids(&self, ids: &[i64]) -> Result<Vec<Entry>, StorageError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let pool = &self.pool;
        let placeholders = vec!["?"; ids.len()].join(",");
        let sql = format!(
            "SELECT id, query, driver_id, connection_id, connection_name, executed_at, \
         duration_ms, rows_affected, success, cancelled, pinned, error, source \
         FROM history WHERE id IN ({placeholders}) ORDER BY pinned DESC, executed_at DESC"
        );
        let mut q = sqlx::query(sqlx::AssertSqlSafe(sql.as_str()));
        for id in ids {
            q = q.bind(id);
        }
        let rows = q.fetch_all(pool).await?;
        rows.into_iter().map(Self::row_to_entry).collect()
    }

    pub async fn export_sql(&self, ids: &[i64]) -> Result<String, StorageError> {
        let entries = self.fetch_by_ids(ids).await?;
        let mut out = String::new();
        out.push_str("-- TablePro query history export\n");
        out.push_str(&format!("-- Generated at {}\n", chrono::Utc::now().to_rfc3339()));
        out.push_str(&format!("-- Entries: {}\n\n", entries.len()));
        for entry in &entries {
            let when = chrono::DateTime::<chrono::Utc>::from(entry.executed_at).to_rfc3339();
            out.push_str(&format!(
                "-- [{}] {} · {} · {}\n",
                when,
                entry.connection_name,
                entry.driver_id,
                outcome_summary(entry),
            ));
            if let Some(err) = &entry.error {
                for line in err.lines() {
                    out.push_str("-- error: ");
                    out.push_str(line);
                    out.push('\n');
                }
            }
            out.push_str(entry.query.trim_end());
            if !entry.query.trim_end().ends_with(';') {
                out.push(';');
            }
            out.push_str("\n\n");
        }
        Ok(out)
    }

    pub async fn export_csv(&self, ids: &[i64]) -> Result<String, StorageError> {
        let entries = self.fetch_by_ids(ids).await?;
        let mut out = String::new();
        out.push_str("executed_at,connection,driver,duration_ms,rows_affected,success,cancelled,pinned,query,error\n");
        for entry in &entries {
            let when = chrono::DateTime::<chrono::Utc>::from(entry.executed_at).to_rfc3339();
            out.push_str(&csv_field(&when));
            out.push(',');
            out.push_str(&csv_field(&entry.connection_name));
            out.push(',');
            out.push_str(&csv_field(&entry.driver_id));
            out.push(',');
            out.push_str(&entry.duration_ms.map(|n| n.to_string()).unwrap_or_default());
            out.push(',');
            out.push_str(&entry.rows_affected.map(|n| n.to_string()).unwrap_or_default());
            out.push(',');
            out.push_str(if entry.success { "1" } else { "0" });
            out.push(',');
            out.push_str(if entry.cancelled { "1" } else { "0" });
            out.push(',');
            out.push_str(if entry.pinned { "1" } else { "0" });
            out.push(',');
            out.push_str(&csv_field(&entry.query));
            out.push(',');
            out.push_str(&csv_field(entry.error.as_deref().unwrap_or("")));
            out.push('\n');
        }
        Ok(out)
    }
}

fn csv_field(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r') {
        let escaped = s.replace('"', "\"\"");
        format!("\"{escaped}\"")
    } else {
        s.to_string()
    }
}

fn outcome_summary(entry: &Entry) -> String {
    if entry.cancelled {
        "cancelled".into()
    } else if entry.success {
        match (entry.rows_affected, entry.duration_ms) {
            (Some(rows), Some(ms)) => format!("ok · {rows} row(s) · {ms} ms"),
            (Some(rows), None) => format!("ok · {rows} row(s)"),
            (None, Some(ms)) => format!("ok · {ms} ms"),
            (None, None) => "ok".into(),
        }
    } else {
        "error".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn legacy_pool() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory pool");
        for statement in BASE_SCHEMA {
            sqlx::query(*statement).execute(&pool).await.expect("legacy schema");
        }
        sqlx::query(
            "INSERT INTO history (query, driver_id, connection_id, connection_name, executed_at, success, cancelled) \
             VALUES ('SELECT 1', 'sqlite', '00000000-0000-0000-0000-000000000000', 'legacy', 1, 1, 0)",
        )
        .execute(&pool)
        .await
        .expect("legacy row");
        pool
    }

    fn store_over(pool: SqlitePool) -> HistoryStore {
        HistoryStore {
            pool,
            path: PathBuf::from(":memory:"),
        }
    }

    #[tokio::test]
    async fn a_database_written_before_versioning_is_stamped_with_the_current_version() {
        let pool = legacy_pool().await;
        assert_eq!(user_version(&pool).await.unwrap(), 0);

        apply_schema(&pool).await.expect("upgrade");

        assert_eq!(user_version(&pool).await.unwrap(), MIGRATIONS.len() as i64);
    }

    #[tokio::test]
    async fn upgrading_an_older_database_keeps_the_entries_it_already_holds() {
        let pool = legacy_pool().await;
        apply_schema(&pool).await.expect("upgrade");

        let entries = store_over(pool).search(SearchFilter::default()).await.unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].query, "SELECT 1");
    }

    #[tokio::test]
    async fn upgrading_a_history_file_keeps_a_private_pre_migration_snapshot() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("history.db");
        let options = SqliteConnectOptions::new().filename(&path).create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .unwrap();
        for statement in BASE_SCHEMA {
            sqlx::query(*statement).execute(&pool).await.unwrap();
        }
        sqlx::query("PRAGMA user_version = 1").execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO history (query, driver_id, connection_id, connection_name, executed_at, success) VALUES ('SELECT 1', 'sqlite', '', '', 0, 1)")
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;

        let store = HistoryStore::open(path.clone()).await.unwrap();
        let backup = path.with_extension("before-migrations.db");
        assert_eq!(std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777, 0o600);
        let backup_options = SqliteConnectOptions::new().filename(&backup);
        let old = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(backup_options)
            .await
            .unwrap();
        assert_eq!(user_version(&old).await.unwrap(), 1);
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM history")
                .fetch_one(&old)
                .await
                .unwrap(),
            1
        );
        assert_eq!(user_version(&store.pool).await.unwrap(), MIGRATIONS.len() as i64);
        let before = std::fs::read(&backup).unwrap();
        old.close().await;
        store.pool.close().await;
        let reopened = HistoryStore::open(path.clone()).await.unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), before);
        reopened.pool.close().await;
        for suffix in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", path.display(), suffix));
        }
        std::fs::copy(&backup, &path).unwrap();
        let restored = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(SqliteConnectOptions::new().filename(&path))
            .await
            .unwrap();
        assert_eq!(user_version(&restored).await.unwrap(), 1);
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM history")
                .fetch_one(&restored)
                .await
                .unwrap(),
            1
        );
        restored.close().await;
    }

    #[tokio::test]
    async fn reopening_an_up_to_date_database_applies_nothing_further() {
        let pool = legacy_pool().await;
        apply_schema(&pool).await.expect("upgrade");
        apply_schema(&pool).await.expect("second open");

        assert_eq!(user_version(&pool).await.unwrap(), MIGRATIONS.len() as i64);
        assert!(pending_migrations(user_version(&pool).await.unwrap()).is_empty());
    }

    #[tokio::test]
    async fn a_failed_history_migration_rolls_back_its_schema_and_version_change() {
        let pool = legacy_pool().await;
        sqlx::query("ALTER TABLE history ADD COLUMN source TEXT NOT NULL DEFAULT 'editor'")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("PRAGMA user_version = 1").execute(&pool).await.unwrap();

        assert!(apply_schema(&pool).await.is_err());

        assert_eq!(user_version(&pool).await.unwrap(), 1);
        let columns = sqlx::query("PRAGMA table_info(history)")
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(
            columns
                .iter()
                .filter(|row| row.get::<String, _>("name") == "source")
                .count(),
            1
        );
        let query: String = sqlx::query_scalar("SELECT query FROM history WHERE id = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(query, "SELECT 1");
    }

    #[tokio::test]
    async fn an_older_database_gains_the_source_column_and_reads_as_editor() {
        let pool = legacy_pool().await;

        apply_schema(&pool).await.expect("upgrade");

        let entries = store_over(pool).search(SearchFilter::default()).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].source, Source::Editor);
    }

    #[tokio::test]
    async fn opening_a_legacy_history_file_migrates_it_and_reopening_keeps_its_data() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.db");
        let options = SqliteConnectOptions::new().filename(&path).create_if_missing(true);
        let legacy = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .expect("legacy file");
        for statement in BASE_SCHEMA {
            sqlx::query(*statement).execute(&legacy).await.expect("legacy schema");
        }
        sqlx::query(
            "INSERT INTO history (query, driver_id, connection_id, connection_name, executed_at, success, cancelled) \
             VALUES ('SELECT 1', 'sqlite', '00000000-0000-0000-0000-000000000000', 'legacy', 1, 1, 0)",
        )
        .execute(&legacy)
        .await
        .expect("legacy row");
        legacy.close().await;

        let store = HistoryStore::open(path.clone())
            .await
            .expect("migrate legacy history file");
        let entries = store.search(SearchFilter::default()).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].query, "SELECT 1");
        assert_eq!(entries[0].source, Source::Editor);
        assert_eq!(user_version(&store.pool).await.unwrap(), MIGRATIONS.len() as i64);

        // A previous package can keep using its explicit legacy column list
        // and omit `source`; SQLite supplies the migration's editor default.
        sqlx::query(
            "INSERT INTO history (query, driver_id, connection_id, connection_name, executed_at, success, cancelled) \
             VALUES ('SELECT 2', 'sqlite', '00000000-0000-0000-0000-000000000000', 'legacy', 2, 1, 0)",
        )
        .execute(&store.pool)
        .await
        .expect("legacy package write after migration");
        let legacy_read: (i64, String) =
            sqlx::query_as("SELECT id, query FROM history ORDER BY executed_at DESC LIMIT 1")
                .fetch_one(&store.pool)
                .await
                .expect("legacy package explicit-column read");
        assert_eq!(legacy_read.1, "SELECT 2");
        drop(store);

        let reopened = HistoryStore::open(path).await.expect("reopen migrated history file");
        let entries = reopened.search(SearchFilter::default()).await.unwrap();
        assert_eq!(entries.len(), 2);
        assert!(
            entries
                .iter()
                .any(|entry| entry.query == "SELECT 1" && entry.source == Source::Editor)
        );
        assert!(
            entries
                .iter()
                .any(|entry| entry.query == "SELECT 2" && entry.source == Source::Editor)
        );
        assert_eq!(user_version(&reopened.pool).await.unwrap(), MIGRATIONS.len() as i64);
    }

    #[tokio::test]
    async fn full_text_search_still_finds_an_entry_written_before_the_upgrade() {
        let pool = legacy_pool().await;
        apply_schema(&pool).await.expect("upgrade");

        let found = store_over(pool)
            .search(SearchFilter {
                needle: Some("SELECT".into()),
                ..SearchFilter::default()
            })
            .await
            .unwrap();

        assert_eq!(found.len(), 1);
    }

    #[tokio::test]
    async fn a_source_filter_keeps_only_the_entries_that_came_from_it() {
        let store = fresh_store().await;
        for source in [Source::Editor, Source::Structure, Source::Browse] {
            store
                .record(NewEntry {
                    source,
                    ..sample_new_entry()
                })
                .await
                .unwrap();
        }

        let structure = store
            .search(SearchFilter {
                source: Some(Source::Structure),
                ..SearchFilter::default()
            })
            .await
            .unwrap();

        assert_eq!(structure.len(), 1);
        assert_eq!(structure[0].source, Source::Structure);
        assert_eq!(store.search(SearchFilter::default()).await.unwrap().len(), 3);
    }

    #[tokio::test]
    async fn an_unknown_stored_source_reads_as_editor_rather_than_failing() {
        let store = fresh_store().await;
        store.record(sample_new_entry()).await.unwrap();
        sqlx::query("UPDATE history SET source = 'from-the-future'")
            .execute(&store.pool)
            .await
            .unwrap();

        let entries = store.search(SearchFilter::default()).await.unwrap();

        assert_eq!(entries[0].source, Source::Editor);
    }

    #[tokio::test]
    async fn a_version_from_a_newer_build_is_left_alone() {
        let pool = legacy_pool().await;
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "PRAGMA user_version = {}",
            MIGRATIONS.len() + 5
        )))
        .execute(&pool)
        .await
        .unwrap();

        apply_schema(&pool).await.expect("no downgrade");

        assert_eq!(user_version(&pool).await.unwrap(), MIGRATIONS.len() as i64 + 5);
    }

    async fn fresh_store() -> HistoryStore {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory pool");
        apply_schema(&pool).await.expect("apply schema");
        HistoryStore {
            pool,
            path: PathBuf::from(":memory:"),
        }
    }

    #[tokio::test]
    async fn rejects_query_over_limit() {
        let store = fresh_store().await;
        let big = "x".repeat(MAX_QUERY_BYTES + 1);
        let entry = NewEntry {
            query: big,
            driver_id: "sqlite".into(),
            connection_id: Uuid::nil(),
            connection_name: "test".into(),
            executed_at: SystemTime::now(),
            duration_ms: Some(1),
            rows_affected: Some(0),
            outcome: Outcome::Success,
            source: Source::Editor,
        };
        let err = store.record(entry).await.unwrap_err();
        assert!(matches!(err, StorageError::TooLarge { .. }));
    }

    #[tokio::test]
    async fn stores_keep_independent_pools() {
        let first = fresh_store().await;
        let second = fresh_store().await;
        first
            .record(NewEntry {
                query: "SELECT 1".into(),
                driver_id: "sqlite".into(),
                connection_id: Uuid::nil(),
                connection_name: "first".into(),
                executed_at: SystemTime::now(),
                duration_ms: None,
                rows_affected: None,
                outcome: Outcome::Success,
                source: Source::Editor,
            })
            .await
            .unwrap();

        assert_eq!(first.search(SearchFilter::default()).await.unwrap().len(), 1);
        assert!(second.search(SearchFilter::default()).await.unwrap().is_empty());
    }

    #[test]
    fn csv_escaping() {
        assert_eq!(csv_field("plain"), "plain");
        assert_eq!(csv_field("a,b"), "\"a,b\"");
        assert_eq!(csv_field("a\"b"), "\"a\"\"b\"");
        assert_eq!(csv_field("line\n"), "\"line\n\"");
    }

    fn sample_new_entry() -> NewEntry {
        NewEntry {
            query: "SELECT 1".into(),
            driver_id: "sqlite".into(),
            connection_id: Uuid::nil(),
            connection_name: "test".into(),
            executed_at: SystemTime::now(),
            duration_ms: None,
            rows_affected: None,
            outcome: Outcome::Success,
            source: Source::Editor,
        }
    }

    fn sample_entry() -> Entry {
        Entry {
            id: 1,
            query: "SELECT 1".into(),
            driver_id: "sqlite".into(),
            connection_id: Uuid::nil(),
            connection_name: "test".into(),
            executed_at: SystemTime::now(),
            duration_ms: None,
            rows_affected: None,
            success: true,
            cancelled: false,
            pinned: false,
            error: None,
            source: Source::Editor,
        }
    }

    #[test]
    fn outcome_summary_reports_cancelled_before_checking_success() {
        let mut entry = sample_entry();
        entry.cancelled = true;
        entry.success = false;
        assert_eq!(outcome_summary(&entry), "cancelled");
    }

    #[test]
    fn outcome_summary_reports_an_error_outcome() {
        let mut entry = sample_entry();
        entry.success = false;
        assert_eq!(outcome_summary(&entry), "error");
    }

    #[test]
    fn outcome_summary_reports_rows_and_duration_when_both_are_known() {
        let mut entry = sample_entry();
        entry.rows_affected = Some(3);
        entry.duration_ms = Some(12);
        assert_eq!(outcome_summary(&entry), "ok · 3 row(s) · 12 ms");
    }

    #[test]
    fn outcome_summary_reports_rows_only_when_duration_is_unknown() {
        let mut entry = sample_entry();
        entry.rows_affected = Some(3);
        assert_eq!(outcome_summary(&entry), "ok · 3 row(s)");
    }

    #[test]
    fn outcome_summary_reports_duration_only_when_rows_are_unknown() {
        let mut entry = sample_entry();
        entry.duration_ms = Some(12);
        assert_eq!(outcome_summary(&entry), "ok · 12 ms");
    }

    #[test]
    fn outcome_summary_reports_plain_ok_when_neither_is_known() {
        let entry = sample_entry();
        assert_eq!(outcome_summary(&entry), "ok");
    }

    #[test]
    fn a_fresh_history_db_is_created_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.db");
        create_private_file_if_missing(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn restrict_permissions_tightens_the_database_and_its_wal_and_shm_siblings() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.db");
        let wal = dir.path().join("history.db-wal");
        let shm = dir.path().join("history.db-shm");
        for p in [&path, &wal, &shm] {
            std::fs::write(p, b"").unwrap();
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        restrict_permissions(&path).unwrap();

        for p in [&path, &wal, &shm] {
            let mode = std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "{p:?} must be private");
        }
    }
}
