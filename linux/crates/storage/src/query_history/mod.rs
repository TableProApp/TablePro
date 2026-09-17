mod entry;
mod export;
mod new_entry;
mod outcome;
mod prune_report;
pub mod retention;
mod search_filter;

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{AssertSqlSafe, ConnectOptions, Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;
use crate::paths::StoragePaths;
use crate::unix_time::{from_unix, to_unix};

pub use entry::Entry;
pub use new_entry::NewEntry;
pub use outcome::Outcome;
pub use prune_report::PruneReport;
pub use search_filter::SearchFilter;

use export::{history_csv, outcome_summary};

const MAX_QUERY_BYTES: usize = 1024 * 1024;

/// Unpinned entries kept regardless of the retention window. History is
/// a convenience, not an archive, and an unbounded table makes every
/// search slower for everyone.
const MAX_UNPINNED_ENTRIES: i64 = 100_000;

/// An applied migration is never edited. Each schema change is a new
/// timestamped file with its own fixture test.
static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// The query-history database. Cloning shares the pool, so a clone per
/// consumer is cheap and they all see the same rows.
#[derive(Debug, Clone)]
pub struct QueryHistory {
    pool: SqlitePool,
    path: PathBuf,
}

impl QueryHistory {
    /// SQLite creates the database, its WAL and its SHM with the umask
    /// mode. Pre-creating the database at 0600 makes the siblings copy
    /// that instead, so query text is never world-readable.
    pub async fn open(paths: &StoragePaths) -> Result<Self, StorageError> {
        let path = paths.history_database();
        crate::fs::create_private_file_if_missing(&path)?;
        let options = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            // Query text is the user's own SQL, which may carry values
            // they would not want in a log.
            .disable_statement_logging();
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        MIGRATOR.run(&pool).await.map_err(|error| match error {
            // The database carries a version this build does not know,
            // which means a newer binary created it.
            sqlx::migrate::MigrateError::VersionMissing(version) => StorageError::HistoryNewerThanApp { version },
            other => StorageError::HistoryMigration(other),
        })?;
        Ok(Self { pool, path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The saved queries, which share this database. One file, one
    /// migration chain, one open: what the user keeps and what they
    /// ran are the same kind of thing in the same place.
    pub fn saved_queries(&self) -> crate::saved_queries::SavedQueries {
        crate::saved_queries::SavedQueries::new(self.pool.clone())
    }

    pub async fn record(&self, entry: NewEntry) -> Result<i64, StorageError> {
        if entry.query.len() > MAX_QUERY_BYTES {
            return Err(StorageError::TooLarge {
                got: entry.query.len(),
                limit: MAX_QUERY_BYTES,
            });
        }
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
                success, cancelled, error
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        .execute(&self.pool)
        .await?
        .last_insert_rowid();
        Ok(id)
    }

    pub async fn search(&self, filter: SearchFilter) -> Result<Vec<Entry>, StorageError> {
        let limit_usize = if filter.limit == 0 { 200 } else { filter.limit };
        // Cap to a value that fits losslessly in i64 (no negative-LIMIT surprise
        // in SQLite, which would silently disable the limit).
        let limit = limit_usize.min(i64::MAX as usize) as i64;

        let mut sql = String::from(
            "SELECT h.id, h.query, h.driver_id, h.connection_id, h.connection_name, \
             h.executed_at, h.duration_ms, h.rows_affected, h.success, h.cancelled, h.pinned, h.error \
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
        if !wheres.is_empty() {
            sql.push_str("WHERE ");
            sql.push_str(&wheres.join(" AND "));
            sql.push(' ');
        }
        sql.push_str("ORDER BY h.pinned DESC, h.executed_at DESC LIMIT ?");

        let mut q = sqlx::query(AssertSqlSafe(sql.as_str()));
        if let Some(needle) = &filter.needle {
            q = q.bind(needle);
        }
        if let Some(conn_id) = filter.connection_id {
            q = q.bind(conn_id.to_string());
        }
        if let Some(min_ts) = filter.min_executed_at {
            q = q.bind(to_unix(min_ts));
        }
        q = q.bind(limit);

        let rows = q.fetch_all(&self.pool).await?;
        rows.into_iter().map(Self::row_to_entry).collect()
    }

    fn row_to_entry(row: sqlx::sqlite::SqliteRow) -> Result<Entry, StorageError> {
        let conn_id_str: String = row.try_get("connection_id")?;
        let connection_id = Uuid::parse_str(&conn_id_str).unwrap_or_default();
        let executed_at: i64 = row.try_get("executed_at")?;
        let success_i: i64 = row.try_get("success")?;
        let cancelled_i: i64 = row.try_get("cancelled")?;
        let pinned_i: i64 = row.try_get("pinned")?;
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
        })
    }

    pub async fn set_pinned(&self, id: i64, pinned: bool) -> Result<(), StorageError> {
        sqlx::query("UPDATE history SET pinned = ? WHERE id = ?")
            .bind(if pinned { 1_i64 } else { 0 })
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn delete(&self, id: i64) -> Result<(), StorageError> {
        sqlx::query("DELETE FROM history WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn delete_many(&self, ids: &[i64]) -> Result<usize, StorageError> {
        if ids.is_empty() {
            return Ok(0);
        }
        let placeholders = vec!["?"; ids.len()].join(",");
        let sql = format!("DELETE FROM history WHERE id IN ({placeholders})");
        let mut q = sqlx::query(AssertSqlSafe(sql.as_str()));
        for id in ids {
            q = q.bind(id);
        }
        let affected = q.execute(&self.pool).await?.rows_affected();
        Ok(affected as usize)
    }

    pub async fn clear_all(&self) -> Result<usize, StorageError> {
        let affected = sqlx::query("DELETE FROM history")
            .execute(&self.pool)
            .await?
            .rows_affected();
        Ok(affected as usize)
    }

    /// Drop what the user no longer needs: first anything past the
    /// retention window, then anything past the entry cap. Pinned rows
    /// survive both.
    pub async fn prune(&self, retention_days: u32) -> Result<PruneReport, StorageError> {
        self.prune_with_cap(retention_days, MAX_UNPINNED_ENTRIES).await
    }

    pub(crate) async fn prune_with_cap(&self, retention_days: u32, cap: i64) -> Result<PruneReport, StorageError> {
        let mut report = PruneReport::default();

        if let Some(cutoff) = retention::cutoff(retention_days, SystemTime::now()) {
            report.expired = sqlx::query("DELETE FROM history WHERE pinned = 0 AND executed_at < ?")
                .bind(to_unix(cutoff))
                .execute(&self.pool)
                .await?
                .rows_affected();
        }

        report.over_cap = sqlx::query(
            "DELETE FROM history WHERE pinned = 0 AND id NOT IN (
                 SELECT id FROM history WHERE pinned = 0 ORDER BY executed_at DESC, id DESC LIMIT ?
             )",
        )
        .bind(cap)
        .execute(&self.pool)
        .await?
        .rows_affected();

        // The delete triggers queue tombstones in the FTS index; without
        // this the index keeps growing even as the table shrinks.
        if report.removed_anything() {
            sqlx::query("INSERT INTO history_fts(history_fts) VALUES('optimize')")
                .execute(&self.pool)
                .await?;
        }
        Ok(report)
    }

    pub async fn known_connections(&self) -> Result<Vec<(Uuid, String)>, StorageError> {
        let rows = sqlx::query(
            "SELECT DISTINCT connection_id, connection_name FROM history ORDER BY connection_name COLLATE NOCASE",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let id_str: String = row.try_get("connection_id")?;
            let name: String = row.try_get("connection_name")?;
            if let Ok(id) = Uuid::parse_str(&id_str) {
                out.push((id, name));
            }
        }
        Ok(out)
    }

    pub async fn fetch_by_ids(&self, ids: &[i64]) -> Result<Vec<Entry>, StorageError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = vec!["?"; ids.len()].join(",");
        let sql = format!(
            "SELECT id, query, driver_id, connection_id, connection_name, executed_at, \
             duration_ms, rows_affected, success, cancelled, pinned, error \
             FROM history WHERE id IN ({placeholders}) ORDER BY pinned DESC, executed_at DESC"
        );
        let mut q = sqlx::query(AssertSqlSafe(sql.as_str()));
        for id in ids {
            q = q.bind(id);
        }
        let rows = q.fetch_all(&self.pool).await?;
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
        history_csv(&entries)
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn paths(root: &tempfile::TempDir) -> StoragePaths {
        StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
    }

    fn entry(query: &str, connection: Uuid) -> NewEntry {
        NewEntry {
            query: query.to_owned(),
            driver_id: "sqlite".to_owned(),
            connection_id: connection,
            connection_name: "test".to_owned(),
            executed_at: SystemTime::now(),
            duration_ms: Some(3),
            rows_affected: Some(1),
            outcome: Outcome::Success,
        }
    }

    #[tokio::test]
    async fn history_open_creates_0600_db_and_wal() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);

        let history = QueryHistory::open(&paths).await.expect("open");
        history.record(entry("SELECT 1", Uuid::nil())).await.expect("record");

        let mode = |path: &Path| std::fs::metadata(path).expect("metadata").permissions().mode() & 0o777;
        assert_eq!(mode(&paths.history_database()), 0o600);
        let wal = paths.history_database().with_extension("db-wal");
        assert!(wal.exists(), "WAL was not created");
        assert_eq!(mode(&wal), 0o600);
    }

    #[tokio::test]
    async fn history_record_search_round_trip() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let connection = Uuid::new_v4();

        let id = history
            .record(entry("SELECT name FROM widgets", connection))
            .await
            .expect("record");
        let found = history
            .search(SearchFilter {
                needle: Some("widgets".to_owned()),
                limit: 10,
                ..SearchFilter::default()
            })
            .await
            .expect("search");

        assert!(id > 0);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].query, "SELECT name FROM widgets");
        assert_eq!(found[0].connection_id, connection);
    }

    #[tokio::test]
    async fn two_histories_in_one_process_are_independent() {
        let root = tempfile::tempdir().expect("tempdir");
        let installed = QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
            .await
            .expect("installed");
        let devel = QueryHistory::open(&StoragePaths::under(
            root.path(),
            "tablepro-devel",
            "app.tablepro.TablePro.Devel",
        ))
        .await
        .expect("devel");

        installed
            .record(entry("SELECT 'installed'", Uuid::nil()))
            .await
            .expect("record");

        let from_installed = installed.search(SearchFilter::default()).await.expect("search");
        let from_devel = devel.search(SearchFilter::default()).await.expect("search");

        assert_ne!(installed.path(), devel.path());
        assert_eq!(from_installed.len(), 1);
        assert!(from_devel.is_empty());
    }

    #[tokio::test]
    async fn fresh_database_migrates() {
        let root = tempfile::tempdir().expect("tempdir");

        let history = QueryHistory::open(&paths(&root)).await.expect("open");

        let applied: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations")
            .fetch_one(&history.pool)
            .await
            .expect("count migrations");
        assert_eq!(applied, 2);
    }

    #[tokio::test]
    async fn open_twice_is_idempotent() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);

        let first = QueryHistory::open(&paths).await.expect("first open");
        first.record(entry("SELECT 1", Uuid::nil())).await.expect("record");
        drop(first);
        let second = QueryHistory::open(&paths).await.expect("second open");

        let found = second.search(SearchFilter::default()).await.expect("search");
        assert_eq!(found.len(), 1);
    }

    #[tokio::test]
    async fn newer_database_is_refused_without_changes() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);
        let history = QueryHistory::open(&paths).await.expect("open");
        // A version this build has no migration for is what a newer
        // binary leaves behind.
        sqlx::query("INSERT INTO _sqlx_migrations (version, description, installed_on, success, checksum, execution_time) VALUES (99999999999999, 'from the future', CURRENT_TIMESTAMP, 1, X'00', 0)")
            .execute(&history.pool)
            .await
            .expect("insert a future migration");
        drop(history);

        let refused = QueryHistory::open(&paths).await;

        assert!(
            matches!(refused, Err(StorageError::HistoryNewerThanApp { .. })),
            "{:?}",
            refused.err()
        );
    }

    #[tokio::test]
    async fn schema_matches_the_expected_objects() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");

        let names: Vec<String> = sqlx::query_scalar(
            "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE '_sqlx%' ORDER BY name",
        )
        .fetch_all(&history.pool)
        .await
        .expect("list objects");

        for expected in [
            "history",
            "history_ad",
            "history_ai",
            "history_au",
            "history_connection_idx",
            "history_executed_at_idx",
            "history_fts",
            "history_pinned_idx",
        ] {
            assert!(
                names.iter().any(|name| name == expected),
                "{expected} missing: {names:?}"
            );
        }
    }

    #[tokio::test]
    async fn prune_caps_unpinned_entries_and_keeps_pinned() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        for index in 0..6 {
            let id = history
                .record(entry(&format!("SELECT {index}"), Uuid::nil()))
                .await
                .expect("record");
            if index == 0 {
                history.set_pinned(id, true).await.expect("pin");
            }
        }

        let report = history.prune_with_cap(0, 2).await.expect("prune");
        let left = history.search(SearchFilter::default()).await.expect("search");

        assert_eq!(report.expired, 0);
        assert_eq!(report.over_cap, 3);
        assert_eq!(left.len(), 3, "the pinned row plus the cap");
        assert!(left.iter().any(|entry| entry.pinned), "the pinned row was dropped");
    }

    #[tokio::test]
    async fn fts_search_still_matches_after_optimize() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        for index in 0..4 {
            history
                .record(entry(&format!("SELECT widgets {index}"), Uuid::nil()))
                .await
                .expect("record");
        }

        let report = history.prune_with_cap(0, 2).await.expect("prune");
        let found = history
            .search(SearchFilter {
                needle: Some("widgets".to_owned()),
                limit: 10,
                ..SearchFilter::default()
            })
            .await
            .expect("search");

        assert!(report.removed_anything());
        assert_eq!(found.len(), 2);
    }

    /// Bump this with each new migration file. An applied migration is
    /// never edited, so a count that did not move when the schema did
    /// means a change went into a file that has already run somewhere.
    #[test]
    fn migrator_embeds_every_migration() {
        assert_eq!(MIGRATOR.iter().count(), 2);
    }

    #[tokio::test]
    async fn rejects_query_over_limit() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let big = "x".repeat(MAX_QUERY_BYTES + 1);

        let error = history.record(entry(&big, Uuid::nil())).await.unwrap_err();

        assert!(matches!(error, StorageError::TooLarge { .. }));
    }

    #[tokio::test]
    async fn history_fts5_available_on_system_sqlite() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        history
            .record(entry("SELECT name FROM widgets", Uuid::nil()))
            .await
            .expect("record");

        let matches: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH ?")
            .bind("widgets")
            .fetch_one(&history.pool)
            .await
            .expect("fts5 match");

        assert_eq!(matches, 1);
    }
}
