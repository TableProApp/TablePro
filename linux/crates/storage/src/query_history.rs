use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;

const MAX_QUERY_BYTES: usize = 1024 * 1024;

static POOL: OnceLock<SqlitePool> = OnceLock::new();

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
}

#[derive(Debug, Clone, Default)]
pub struct SearchFilter {
    pub needle: Option<String>,
    pub connection_id: Option<Uuid>,
    pub success_only: Option<bool>,
    pub exclude_cancelled: Option<bool>,
    pub min_executed_at: Option<SystemTime>,
    pub limit: usize,
}

pub fn db_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("tablepro").join("history.db"))
}

pub async fn init() -> Result<(), StorageError> {
    if POOL.get().is_some() {
        return Ok(());
    }
    let Some(path) = db_path() else {
        return Err(StorageError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "no XDG_CONFIG_HOME or HOME",
        )));
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let opts = SqliteConnectOptions::new()
        .filename(&path)
        .create_if_missing(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new().max_connections(1).connect_with(opts).await?;
    apply_schema(&pool).await?;
    POOL.set(pool)
        .map_err(|_| StorageError::Schema("history pool already initialised".into()))?;
    Ok(())
}

async fn apply_schema(pool: &SqlitePool) -> Result<(), StorageError> {
    sqlx::query(
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
    )
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
            query,
            content='history',
            content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        )
        "#,
    )
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
            INSERT INTO history_fts(rowid, query) VALUES (new.id, new.query);
        END
        "#,
    )
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
            INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.id, old.query);
        END
        "#,
    )
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE OF query ON history BEGIN
            INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.id, old.query);
            INSERT INTO history_fts(rowid, query) VALUES (new.id, new.query);
        END
        "#,
    )
    .execute(pool)
    .await?;

    sqlx::query("CREATE INDEX IF NOT EXISTS history_executed_at_idx ON history (executed_at DESC)")
        .execute(pool)
        .await?;
    sqlx::query("CREATE INDEX IF NOT EXISTS history_pinned_idx ON history (pinned DESC, executed_at DESC)")
        .execute(pool)
        .await?;
    sqlx::query("CREATE INDEX IF NOT EXISTS history_connection_idx ON history (connection_id, executed_at DESC)")
        .execute(pool)
        .await?;

    Ok(())
}

fn pool() -> Result<&'static SqlitePool, StorageError> {
    POOL.get().ok_or(StorageError::NotInitialised)
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

pub async fn record(entry: NewEntry) -> Result<i64, StorageError> {
    if entry.query.len() > MAX_QUERY_BYTES {
        return Err(StorageError::TooLarge {
            got: entry.query.len(),
            limit: MAX_QUERY_BYTES,
        });
    }
    let pool = pool()?;
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
    .execute(pool)
    .await?
    .last_insert_rowid();
    Ok(id)
}

pub async fn search(filter: SearchFilter) -> Result<Vec<Entry>, StorageError> {
    let pool = pool()?;
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

    let mut q = sqlx::query(&sql);
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

    let rows = q.fetch_all(pool).await?;
    rows.into_iter().map(row_to_entry).collect()
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

pub async fn set_pinned(id: i64, pinned: bool) -> Result<(), StorageError> {
    let pool = pool()?;
    sqlx::query("UPDATE history SET pinned = ? WHERE id = ?")
        .bind(if pinned { 1_i64 } else { 0 })
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete(id: i64) -> Result<(), StorageError> {
    let pool = pool()?;
    sqlx::query("DELETE FROM history WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_many(ids: &[i64]) -> Result<usize, StorageError> {
    if ids.is_empty() {
        return Ok(0);
    }
    let pool = pool()?;
    let placeholders = vec!["?"; ids.len()].join(",");
    let sql = format!("DELETE FROM history WHERE id IN ({placeholders})");
    let mut q = sqlx::query(&sql);
    for id in ids {
        q = q.bind(id);
    }
    let affected = q.execute(pool).await?.rows_affected();
    Ok(affected as usize)
}

pub async fn clear_all() -> Result<usize, StorageError> {
    let pool = pool()?;
    let affected = sqlx::query("DELETE FROM history").execute(pool).await?.rows_affected();
    Ok(affected as usize)
}

pub async fn prune_older_than(retention_days: u32) -> Result<usize, StorageError> {
    if retention_days == 0 {
        return Ok(0);
    }
    let pool = pool()?;
    let cutoff = SystemTime::now() - std::time::Duration::from_secs(retention_days as u64 * 86_400);
    let cutoff_unix = to_unix(cutoff);
    let affected = sqlx::query("DELETE FROM history WHERE pinned = 0 AND executed_at < ?")
        .bind(cutoff_unix)
        .execute(pool)
        .await?
        .rows_affected();
    Ok(affected as usize)
}

pub async fn known_connections() -> Result<Vec<(Uuid, String)>, StorageError> {
    let pool = pool()?;
    let rows = sqlx::query(
        "SELECT DISTINCT connection_id, connection_name FROM history ORDER BY connection_name COLLATE NOCASE",
    )
    .fetch_all(pool)
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

pub async fn fetch_by_ids(ids: &[i64]) -> Result<Vec<Entry>, StorageError> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let pool = pool()?;
    let placeholders = vec!["?"; ids.len()].join(",");
    let sql = format!(
        "SELECT id, query, driver_id, connection_id, connection_name, executed_at, \
         duration_ms, rows_affected, success, cancelled, pinned, error \
         FROM history WHERE id IN ({placeholders}) ORDER BY pinned DESC, executed_at DESC"
    );
    let mut q = sqlx::query(&sql);
    for id in ids {
        q = q.bind(id);
    }
    let rows = q.fetch_all(pool).await?;
    rows.into_iter().map(row_to_entry).collect()
}

pub async fn export_sql(ids: &[i64]) -> Result<String, StorageError> {
    let entries = fetch_by_ids(ids).await?;
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

pub async fn export_csv(ids: &[i64]) -> Result<String, StorageError> {
    let entries = fetch_by_ids(ids).await?;
    history_csv(&entries)
}

const HISTORY_CSV_HEADER: [&str; 10] = [
    "executed_at",
    "connection",
    "driver",
    "duration_ms",
    "rows_affected",
    "success",
    "cancelled",
    "pinned",
    "query",
    "error",
];

fn history_csv(entries: &[Entry]) -> Result<String, StorageError> {
    let records: Vec<Vec<String>> = entries.iter().map(history_record).collect();
    let options = tablepro_core::export::CsvOptions::default();
    Ok(tablepro_core::export::render_text_csv(
        &HISTORY_CSV_HEADER,
        &records,
        &options,
    )?)
}

fn history_record(entry: &Entry) -> Vec<String> {
    vec![
        chrono::DateTime::<chrono::Utc>::from(entry.executed_at).to_rfc3339(),
        entry.connection_name.clone(),
        entry.driver_id.clone(),
        entry.duration_ms.map(|n| n.to_string()).unwrap_or_default(),
        entry.rows_affected.map(|n| n.to_string()).unwrap_or_default(),
        flag(entry.success),
        flag(entry.cancelled),
        flag(entry.pinned),
        entry.query.clone(),
        entry.error.clone().unwrap_or_default(),
    ]
}

fn flag(value: bool) -> String {
    if value { "1" } else { "0" }.to_string()
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

    async fn fresh_pool() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory pool");
        apply_schema(&pool).await.expect("apply schema");
        pool
    }

    fn install(pool: SqlitePool) {
        let _ = POOL.set(pool);
    }

    #[tokio::test]
    async fn rejects_query_over_limit() {
        let pool = fresh_pool().await;
        install(pool);
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
        };
        let err = record(entry).await.unwrap_err();
        assert!(matches!(err, StorageError::TooLarge { .. }));
    }

    #[test]
    fn history_csv_quotes_every_field_and_neutralises_formulas() {
        let entry = Entry {
            id: 1,
            query: "=HYPERLINK(\"x\")".into(),
            driver_id: "postgres".into(),
            connection_id: Uuid::nil(),
            connection_name: "a,b".into(),
            executed_at: UNIX_EPOCH,
            duration_ms: Some(12),
            rows_affected: None,
            success: true,
            cancelled: false,
            pinned: false,
            error: Some("line\nbreak".into()),
        };
        let csv = history_csv(&[entry]).unwrap();
        assert_eq!(
            csv,
            "\"executed_at\",\"connection\",\"driver\",\"duration_ms\",\"rows_affected\",\
             \"success\",\"cancelled\",\"pinned\",\"query\",\"error\"\n\
             \"1970-01-01T00:00:00+00:00\",\"a,b\",\"postgres\",\"12\",\"\",\"1\",\"0\",\"0\",\
             \"'=HYPERLINK(\"\"x\"\")\",\"line\nbreak\"\n"
        );
    }
}
