mod entry;
mod export;
mod history_connection;
mod history_cursor;
mod history_page;
mod history_query;
mod new_entry;
mod outcome;
mod prune_report;
pub mod retention;
mod schema;
mod search_fold;
mod status_filter;

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{AssertSqlSafe, ConnectOptions, Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;
use crate::paths::StoragePaths;
use crate::unix_time::{from_unix, to_unix};

pub use entry::Entry;
pub use history_connection::HistoryConnection;
pub use history_cursor::HistoryCursor;
pub use history_page::{HistoryPage, HistoryPageRequest, MAX_PAGE_SIZE};
pub use history_query::HistoryQuery;
pub use new_entry::NewEntry;
pub use outcome::Outcome;
pub use prune_report::PruneReport;
pub use status_filter::StatusFilter;

use export::{history_csv, outcome_summary};
use history_query::TermMatch;
use search_fold::fold;

const MAX_QUERY_BYTES: usize = 1024 * 1024;

/// Unpinned entries kept regardless of the retention window. History is
/// a convenience, not an archive, and an unbounded table makes every
/// search slower for everyone.
const MAX_UNPINNED_ENTRIES: i64 = 100_000;

/// Ids per statement when a list of them is bound, well under SQLite's
/// limit on parameters.
const IDS_PER_STATEMENT: usize = 500;

const ENTRY_COLUMNS: &str = "h.id, h.query, h.driver_id, h.connection_id, h.connection_name, h.executed_at, \
     h.duration_ms, h.rows_affected, h.success, h.cancelled, h.pinned, h.error";

/// A value for a placeholder of a statement built from parts.
enum Bind {
    Text(String),
    Integer(i64),
}

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
        schema::migrate(&pool).await?;
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
                query, query_folded, driver_id, connection_id, connection_name,
                executed_at, duration_ms, rows_affected,
                success, cancelled, error
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(&entry.query)
        .bind(fold(&entry.query))
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

    /// One page of the entries `query` matches, pinned first, then
    /// newest. Paging is by keyset, so rows recorded while the user
    /// scrolls shift nothing and no row is shown twice.
    pub async fn search_page(
        &self,
        query: &HistoryQuery,
        request: HistoryPageRequest,
    ) -> Result<HistoryPage, StorageError> {
        let limit = request.limit.clamp(1, MAX_PAGE_SIZE);
        let mut clauses: Vec<&'static str> = Vec::new();
        let mut binds: Vec<Bind> = Vec::new();
        for term in query.term_matches() {
            match term {
                TermMatch::Trigram(phrase) => {
                    clauses.push("h.id IN (SELECT rowid FROM history_search WHERE history_search MATCH ?)");
                    binds.push(Bind::Text(phrase));
                }
                TermMatch::Substring(text) => {
                    clauses.push("instr(h.query_folded, ?) > 0");
                    binds.push(Bind::Text(text));
                }
            }
        }
        if let Some(connection) = query.connection {
            clauses.push("h.connection_id = ?");
            binds.push(Bind::Text(connection.to_string()));
        }
        if let Some(predicate) = query.status.predicate() {
            clauses.push(predicate);
        }
        if let Some(after) = query.executed_after {
            clauses.push("h.executed_at >= ?");
            binds.push(Bind::Integer(to_unix(after)));
        }
        if let Some(cursor) = request.after {
            clauses.push("(h.pinned, h.executed_at, h.id) < (?, ?, ?)");
            binds.push(Bind::Integer(i64::from(cursor.pinned)));
            binds.push(Bind::Integer(cursor.executed_at));
            binds.push(Bind::Integer(cursor.id));
        }

        let mut sql = format!("SELECT {ENTRY_COLUMNS} FROM history h");
        if !clauses.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&clauses.join(" AND "));
        }
        // One row past the page says whether there is another.
        sql.push_str(" ORDER BY h.pinned DESC, h.executed_at DESC, h.id DESC LIMIT ?");
        binds.push(Bind::Integer(limit as i64 + 1));

        let mut statement = sqlx::query(AssertSqlSafe(sql));
        for bind in binds {
            statement = match bind {
                Bind::Text(text) => statement.bind(text),
                Bind::Integer(value) => statement.bind(value),
            };
        }
        let rows = statement.fetch_all(&self.pool).await?;
        let mut entries = rows
            .into_iter()
            .map(Self::row_to_entry)
            .collect::<Result<Vec<_>, _>>()?;
        let next = if entries.len() > limit {
            entries.truncate(limit);
            entries.last().map(HistoryCursor::after)
        } else {
            None
        };
        Ok(HistoryPage { entries, next })
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

    /// Delete the entries and hand back what they held, so the delete
    /// can be undone with `restore`.
    pub async fn delete_returning(&self, ids: &[i64]) -> Result<Vec<Entry>, StorageError> {
        let mut transaction = self.pool.begin().await?;
        let mut deleted = Vec::with_capacity(ids.len());
        for chunk in ids.chunks(IDS_PER_STATEMENT) {
            let placeholders = vec!["?"; chunk.len()].join(",");
            let sql = format!(
                "DELETE FROM history WHERE id IN ({placeholders}) RETURNING id, query, driver_id, connection_id, \
                 connection_name, executed_at, duration_ms, rows_affected, success, cancelled, pinned, error"
            );
            let mut statement = sqlx::query(AssertSqlSafe(sql));
            for id in chunk {
                statement = statement.bind(id);
            }
            for row in statement.fetch_all(&mut *transaction).await? {
                deleted.push(Self::row_to_entry(row)?);
            }
        }
        transaction.commit().await?;
        deleted.sort_by_key(|entry| entry.id);
        Ok(deleted)
    }

    /// Put deleted entries back under their own ids, pinned or not as
    /// they were. The insert triggers index them again.
    pub async fn restore(&self, entries: &[Entry]) -> Result<(), StorageError> {
        let mut transaction = self.pool.begin().await?;
        for entry in entries {
            sqlx::query(
                "INSERT INTO history (
                     id, query, query_folded, driver_id, connection_id, connection_name,
                     executed_at, duration_ms, rows_affected, success, cancelled, pinned, error
                 )
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(entry.id)
            .bind(&entry.query)
            .bind(fold(&entry.query))
            .bind(&entry.driver_id)
            .bind(entry.connection_id.to_string())
            .bind(&entry.connection_name)
            .bind(to_unix(entry.executed_at))
            .bind(entry.duration_ms)
            .bind(entry.rows_affected)
            .bind(i64::from(entry.success))
            .bind(i64::from(entry.cancelled))
            .bind(i64::from(entry.pinned))
            .bind(&entry.error)
            .execute(&mut *transaction)
            .await?;
        }
        transaction.commit().await?;
        Ok(())
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
            sqlx::query("INSERT INTO history_search(history_search) VALUES('optimize')")
                .execute(&self.pool)
                .await?;
        }
        Ok(report)
    }

    /// How many queries ran on a connection, pinned ones included.
    pub async fn count_for_connection(&self, connection: Uuid) -> Result<u64, StorageError> {
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM history WHERE connection_id = ?")
            .bind(connection.to_string())
            .fetch_one(&self.pool)
            .await?;
        Ok(u64::try_from(count).unwrap_or(0))
    }

    /// Drop every query run on a connection, pinned ones included, for a
    /// connection the user deleted along with its history.
    pub async fn delete_for_connection(&self, connection: Uuid) -> Result<u64, StorageError> {
        let removed = sqlx::query("DELETE FROM history WHERE connection_id = ?")
            .bind(connection.to_string())
            .execute(&self.pool)
            .await?
            .rows_affected();
        // As after a prune: the delete triggers leave tombstones in the
        // index until it is optimized.
        if removed > 0 {
            sqlx::query("INSERT INTO history_search(history_search) VALUES('optimize')")
                .execute(&self.pool)
                .await?;
        }
        Ok(removed)
    }

    /// Every connection the history holds entries for, under the name
    /// of its latest run, so a renamed connection is listed once.
    pub async fn connections_with_history(&self) -> Result<Vec<HistoryConnection>, StorageError> {
        let rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT connection_id, connection_name FROM (
                 SELECT connection_id, connection_name,
                        ROW_NUMBER() OVER (
                            PARTITION BY connection_id ORDER BY executed_at DESC, id DESC
                        ) AS recency
                 FROM history
             )
             WHERE recency = 1
             ORDER BY connection_name COLLATE NOCASE, connection_id",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .filter_map(|(id, name)| Uuid::parse_str(&id).ok().map(|id| HistoryConnection { id, name }))
            .collect())
    }

    /// The entries with these ids, in the order the history lists them.
    pub async fn fetch_by_ids(&self, ids: &[i64]) -> Result<Vec<Entry>, StorageError> {
        let mut entries = Vec::with_capacity(ids.len());
        for chunk in ids.chunks(IDS_PER_STATEMENT) {
            let placeholders = vec!["?"; chunk.len()].join(",");
            let sql = format!("SELECT {ENTRY_COLUMNS} FROM history h WHERE h.id IN ({placeholders})");
            let mut statement = sqlx::query(AssertSqlSafe(sql));
            for id in chunk {
                statement = statement.bind(id);
            }
            for row in statement.fetch_all(&self.pool).await? {
                entries.push(Self::row_to_entry(row)?);
            }
        }
        entries.sort_by_key(|entry| std::cmp::Reverse(HistoryCursor::after(entry)));
        Ok(entries)
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
    use std::time::Duration;

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

    async fn find(history: &QueryHistory, query: &HistoryQuery) -> Vec<Entry> {
        history
            .search_page(query, HistoryPageRequest::first(MAX_PAGE_SIZE))
            .await
            .expect("search")
            .entries
    }

    async fn all(history: &QueryHistory) -> Vec<Entry> {
        find(history, &HistoryQuery::default()).await
    }

    async fn matching(history: &QueryHistory, input: &str) -> Vec<String> {
        find(history, &HistoryQuery::from_input(input))
            .await
            .into_iter()
            .map(|entry| entry.query)
            .collect()
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
        let found = find(&history, &HistoryQuery::from_input("widgets")).await;

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

        assert_ne!(installed.path(), devel.path());
        assert_eq!(all(&installed).await.len(), 1);
        assert!(all(&devel).await.is_empty());
    }

    #[tokio::test]
    async fn fresh_database_applies_every_migration() {
        let root = tempfile::tempdir().expect("tempdir");

        let history = QueryHistory::open(&paths(&root)).await.expect("open");

        let applied: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations")
            .fetch_one(&history.pool)
            .await
            .expect("count migrations");
        assert_eq!(applied, 3);
    }

    /// The fixture for the substring-search migration: a database the
    /// two migrations before it built, with rows in it.
    #[tokio::test]
    async fn opens_database_created_with_previous_schema() {
        const BEFORE_SUBSTRING_SEARCH: i64 = 20260918000000;
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);
        crate::fs::create_private_file_if_missing(&paths.history_database()).expect("the database file");
        let options = SqliteConnectOptions::new()
            .filename(paths.history_database())
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .expect("connect");
        schema::MIGRATOR
            .run_to(BEFORE_SUBSTRING_SEARCH, &pool)
            .await
            .expect("the earlier schema");
        for (query, executed_at) in [("SELECT * FROM ÉLÈVES", 100_i64), ("SELECT id FROM orders", 200)] {
            sqlx::query(
                "INSERT INTO history (query, driver_id, connection_id, connection_name, executed_at, success) \
                 VALUES (?, 'sqlite', ?, 'old', ?, 1)",
            )
            .bind(query)
            .bind(Uuid::nil().to_string())
            .bind(executed_at)
            .execute(&pool)
            .await
            .expect("an old row");
        }
        pool.close().await;

        let history = QueryHistory::open(&paths).await.expect("open");
        history
            .record(entry("SELECT élèves FROM classes", Uuid::nil()))
            .await
            .expect("record");

        assert_eq!(matching(&history, "élèves").await.len(), 2, "an old row was not folded");
        assert_eq!(
            matching(&history, "ORD").await,
            vec!["SELECT id FROM orders".to_owned()]
        );
        let unfolded: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM history WHERE query_folded IS NULL")
            .fetch_one(&history.pool)
            .await
            .expect("count");
        assert_eq!(unfolded, 0);
        let word_index: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'history_fts'")
            .fetch_one(&history.pool)
            .await
            .expect("look up the old index");
        assert_eq!(word_index, 0, "the word index outlived its migration");
        let integrity = sqlx::query("INSERT INTO history_search(history_search) VALUES('integrity-check')")
            .execute(&history.pool)
            .await;
        assert!(integrity.is_ok(), "{integrity:?}");
    }

    #[tokio::test]
    async fn open_twice_is_idempotent() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = paths(&root);

        let first = QueryHistory::open(&paths).await.expect("first open");
        first.record(entry("SELECT 1", Uuid::nil())).await.expect("record");
        drop(first);
        let second = QueryHistory::open(&paths).await.expect("second open");

        assert_eq!(all(&second).await.len(), 1);
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
            "history_connection_idx",
            "history_executed_at_idx",
            "history_page_idx",
            "history_search",
            "history_search_ad",
            "history_search_ai",
            "history_search_au",
            "history_unfolded_idx",
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
        let left = all(&history).await;

        assert_eq!(report.expired, 0);
        assert_eq!(report.over_cap, 3);
        assert_eq!(left.len(), 3, "the pinned row plus the cap");
        assert!(left.iter().any(|entry| entry.pinned), "the pinned row was dropped");
    }

    #[tokio::test]
    async fn delete_for_connection_removes_only_that_connections_queries() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let (going, staying) = (Uuid::new_v4(), Uuid::new_v4());
        for index in 0..3 {
            let id = history
                .record(entry(&format!("SELECT widgets {index}"), going))
                .await
                .expect("record");
            if index == 0 {
                history.set_pinned(id, true).await.expect("pin");
            }
        }
        history
            .record(entry("SELECT widgets kept", staying))
            .await
            .expect("record");
        assert_eq!(history.count_for_connection(going).await.expect("count"), 3);

        let removed = history.delete_for_connection(going).await.expect("delete");

        assert_eq!(removed, 3, "a pinned query outlived its connection");
        assert_eq!(history.count_for_connection(going).await.expect("count"), 0);
        assert_eq!(history.count_for_connection(staying).await.expect("count"), 1);
        let found = find(&history, &HistoryQuery::from_input("widgets")).await;
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].connection_id, staying);
        assert_eq!(history.delete_for_connection(going).await.expect("delete"), 0);
    }

    #[tokio::test]
    async fn search_still_matches_after_optimize() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        for index in 0..4 {
            history
                .record(entry(&format!("SELECT widgets {index}"), Uuid::nil()))
                .await
                .expect("record");
        }

        let report = history.prune_with_cap(0, 2).await.expect("prune");

        assert!(report.removed_anything());
        assert_eq!(matching(&history, "widgets").await.len(), 2);
    }

    /// Bump this with each new migration file. An applied migration is
    /// never edited, so a count that did not move when the schema did
    /// means a change went into a file that has already run somewhere.
    #[test]
    fn migrator_embeds_every_migration() {
        assert_eq!(schema::MIGRATOR.iter().count(), 3);
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
    async fn trigram_index_available_on_system_sqlite() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        history
            .record(entry("SELECT name FROM widgets", Uuid::nil()))
            .await
            .expect("record");

        let matches: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM history_search WHERE history_search MATCH ?")
            .bind("\"idge\"")
            .fetch_one(&history.pool)
            .await
            .expect("trigram match");

        assert_eq!(matches, 1);
    }

    #[tokio::test]
    async fn partial_token_matches() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        history
            .record(entry("SELECT * FROM customer_orders", Uuid::nil()))
            .await
            .expect("record");
        history
            .record(entry("SELECT * FROM products", Uuid::nil()))
            .await
            .expect("record");

        assert_eq!(
            matching(&history, "tomer_ord").await,
            vec!["SELECT * FROM customer_orders"]
        );
        assert_eq!(matching(&history, "ROM").await.len(), 2);
    }

    #[tokio::test]
    async fn two_char_term_matches_via_instr() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        history
            .record(entry("SELECT a.id FROM t1 a", Uuid::nil()))
            .await
            .expect("record");
        history.record(entry("VACUUM", Uuid::nil())).await.expect("record");

        assert_eq!(matching(&history, "T1").await, vec!["SELECT a.id FROM t1 a"]);
        assert_eq!(matching(&history, ".").await, vec!["SELECT a.id FROM t1 a"]);
        assert!(matching(&history, "zz").await.is_empty());
    }

    #[tokio::test]
    async fn unicode_case_fold() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        history
            .record(entry("SELECT * FROM ÉLÈVES WHERE nom = 'Ærø'", Uuid::nil()))
            .await
            .expect("record");

        assert_eq!(matching(&history, "élèves").await.len(), 1);
        assert_eq!(matching(&history, "ÉlÈv").await.len(), 1);
        assert_eq!(matching(&history, "æR").await.len(), 1, "a short term was not folded");
    }

    #[tokio::test]
    async fn quote_and_fts_operators_are_literal() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let tricky = "SELECT \"a b\" FROM t WHERE x = 'OR' AND y NEAR(z) -- *";
        history.record(entry(tricky, Uuid::nil())).await.expect("record");
        history.record(entry("SELECT 1", Uuid::nil())).await.expect("record");

        for input in [
            "\"a", "b\"", "NEAR(z)", "'OR'", "OR", "AND", "*", "-- *", "\"", "y NEAR",
        ] {
            assert_eq!(matching(&history, input).await, vec![tricky.to_owned()], "{input}");
        }
        assert!(matching(&history, "NEAR(zz)").await.is_empty());
    }

    #[tokio::test]
    async fn a_quote_in_a_long_term_matches_literally() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let quoted = "SELECT \"total\" FROM sales";
        history.record(entry(quoted, Uuid::nil())).await.expect("record");
        history
            .record(entry("SELECT total FROM sales", Uuid::nil()))
            .await
            .expect("record");

        for input in ["\"total\"", "total\"", "\"tot"] {
            assert_eq!(matching(&history, input).await, vec![quoted.to_owned()], "{input}");
        }
        for input in ["\"totals\"", "t\"\"", "\"FROM"] {
            assert!(matching(&history, input).await.is_empty(), "{input}");
        }
        assert_eq!(matching(&history, "total").await.len(), 2);
    }

    #[tokio::test]
    async fn fetch_by_ids_reads_past_one_statement_in_list_order() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let mut ids = Vec::new();
        for index in 0..IDS_PER_STATEMENT + 10 {
            ids.push(
                history
                    .record(entry(&format!("SELECT {index}"), Uuid::nil()))
                    .await
                    .expect("record"),
            );
        }
        // In the last statement's ids, but first in the list.
        let pinned = ids[ids.len() - 1];
        history.set_pinned(pinned, true).await.expect("pin");

        let fetched = history.fetch_by_ids(&ids).await.expect("fetch");

        assert_eq!(fetched.len(), ids.len());
        assert_eq!(fetched.first().map(|entry| entry.id), Some(pinned));
        assert_eq!(fetched, all(&history).await);
    }

    #[tokio::test]
    async fn terms_are_anded() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        for query in ["SELECT id FROM users", "SELECT id FROM orders", "DELETE FROM users"] {
            history.record(entry(query, Uuid::nil())).await.expect("record");
        }

        assert_eq!(matching(&history, "users select").await, vec!["SELECT id FROM users"]);
        assert_eq!(matching(&history, "id  rs").await.len(), 2);
        assert!(matching(&history, "users orders").await.is_empty());
    }

    #[tokio::test]
    async fn keyset_pages_cover_all_rows_once() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        // Groups of runs in the same second, so only the id orders them.
        let base = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        for index in 0..450_u64 {
            let mut run = entry(&format!("SELECT {index}"), Uuid::nil());
            run.executed_at = base + Duration::from_secs(index / 7);
            let id = history.record(run).await.expect("record");
            if index % 50 == 0 {
                history.set_pinned(id, true).await.expect("pin");
            }
        }

        let mut seen = Vec::new();
        let mut request = HistoryPageRequest::first(100);
        let mut pages = 0;
        loop {
            let page = history
                .search_page(&HistoryQuery::default(), request)
                .await
                .expect("a page");
            pages += 1;
            for entry in &page.entries {
                let cursor = HistoryCursor::after(entry);
                assert!(
                    request.after.is_none_or(|after| cursor < after),
                    "an entry on a later page does not sort below the cursor"
                );
                assert!(
                    page.next.is_none_or(|next| cursor >= next),
                    "an entry on this page sorts below its own cursor"
                );
            }
            seen.extend(
                page.entries
                    .iter()
                    .map(|entry| (entry.pinned, entry.executed_at, entry.id)),
            );
            match page.next {
                Some(next) => request.after = Some(next),
                None => break,
            }
        }

        assert_eq!(pages, 5);
        assert_eq!(seen.len(), 450);
        let mut sorted = seen.clone();
        sorted.sort_by(|a, b| b.cmp(a));
        assert_eq!(seen, sorted, "pages are not in pinned, newest, id order");
        sorted.dedup();
        assert_eq!(sorted.len(), 450, "a row was shown twice");
        assert_eq!(seen.iter().take_while(|(pinned, _, _)| *pinned).count(), 9);
    }

    #[tokio::test]
    async fn status_and_connection_filters() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let (mine, theirs) = (Uuid::new_v4(), Uuid::new_v4());
        let old = SystemTime::now() - Duration::from_secs(10 * 86_400);
        for (query, connection, outcome, executed_at) in [
            ("SELECT ok", mine, Outcome::Success, SystemTime::now()),
            ("SELECT bad", mine, Outcome::Error("boom".to_owned()), SystemTime::now()),
            ("SELECT stopped", mine, Outcome::Cancelled, SystemTime::now()),
            ("SELECT theirs", theirs, Outcome::Success, SystemTime::now()),
            ("SELECT old", mine, Outcome::Success, old),
        ] {
            let mut run = entry(query, connection);
            run.outcome = outcome;
            run.executed_at = executed_at;
            history.record(run).await.expect("record");
        }
        let queries = |entries: Vec<Entry>| -> Vec<String> {
            let mut queries: Vec<String> = entries.into_iter().map(|entry| entry.query).collect();
            queries.sort();
            queries
        };
        let filtered = |status: StatusFilter, connection: Option<Uuid>, executed_after: Option<SystemTime>| {
            let mut query = HistoryQuery::default();
            query.connection = connection;
            query.status = status;
            query.executed_after = executed_after;
            query
        };

        assert_eq!(
            queries(find(&history, &filtered(StatusFilter::Succeeded, Some(mine), None)).await),
            ["SELECT ok", "SELECT old"]
        );
        assert_eq!(
            queries(find(&history, &filtered(StatusFilter::Failed, None, None)).await),
            ["SELECT bad"]
        );
        assert_eq!(
            queries(find(&history, &filtered(StatusFilter::Cancelled, None, None)).await),
            ["SELECT stopped"]
        );
        assert_eq!(
            queries(find(&history, &filtered(StatusFilter::Any, Some(theirs), None)).await),
            ["SELECT theirs"]
        );
        let last_week = SystemTime::now() - Duration::from_secs(7 * 86_400);
        assert_eq!(
            queries(
                find(
                    &history,
                    &filtered(StatusFilter::Succeeded, Some(mine), Some(last_week))
                )
                .await
            ),
            ["SELECT ok"]
        );
    }

    #[tokio::test]
    async fn connections_with_history_uses_latest_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let (renamed, other) = (Uuid::new_v4(), Uuid::new_v4());
        let now = SystemTime::now();
        for (connection, name, ago) in [
            (renamed, "Old name", 300),
            (renamed, "New name", 10),
            // Recorded last but ran first, as a restore leaves it.
            (renamed, "Oldest name", 900),
            (other, "beta", 60),
        ] {
            let mut run = entry("SELECT 1", connection);
            run.connection_name = name.to_owned();
            run.executed_at = now - Duration::from_secs(ago);
            history.record(run).await.expect("record");
        }

        let connections = history.connections_with_history().await.expect("list");

        assert_eq!(
            connections,
            vec![
                HistoryConnection {
                    id: other,
                    name: "beta".to_owned()
                },
                HistoryConnection {
                    id: renamed,
                    name: "New name".to_owned()
                },
            ]
        );
    }

    #[tokio::test]
    async fn delete_returning_then_restore_roundtrips_entries_and_search() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&paths(&root)).await.expect("open");
        let mut ids = Vec::new();
        for query in ["SELECT widgets 1", "SELECT widgets 2", "SELECT gadgets"] {
            let mut run = entry(query, Uuid::new_v4());
            run.outcome = Outcome::Error("no such table".to_owned());
            ids.push(history.record(run).await.expect("record"));
        }
        history.set_pinned(ids[0], true).await.expect("pin");
        let before = all(&history).await;

        let deleted = history
            .delete_returning(&[ids[0], ids[2], 9_999])
            .await
            .expect("delete");

        assert_eq!(
            deleted.iter().map(|entry| entry.id).collect::<Vec<_>>(),
            vec![ids[0], ids[2]]
        );
        assert_eq!(matching(&history, "widgets").await, vec!["SELECT widgets 2"]);
        assert!(matching(&history, "gadg").await.is_empty());

        history.restore(&deleted).await.expect("restore");

        assert_eq!(all(&history).await, before);
        assert_eq!(matching(&history, "widgets").await.len(), 2);
        assert_eq!(matching(&history, "gadg").await, vec!["SELECT gadgets"]);
        let integrity = sqlx::query("INSERT INTO history_search(history_search) VALUES('integrity-check')")
            .execute(&history.pool)
            .await;
        assert!(integrity.is_ok(), "{integrity:?}");
    }
}
