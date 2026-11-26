// Entries a host keeps in a store of its own and copies here under their ids: the Mac records each run in its
// history and here, until its history reads from the core (core ADR 0010, slice 3).

use std::collections::HashSet;

use sqlx::{AssertSqlSafe, Connection};
use uuid::Uuid;

use super::search_fold::fold;
use super::{
    Bind, CopyDelete, IDS_PER_STATEMENT, MAX_QUERY_BYTES, NewEntry, Outcome, QueryHistory, trim_upgrade_copies,
};
use crate::error::StorageError;
use crate::unix_time::to_unix;

impl QueryHistory {
    // In one transaction. An entry this store already holds keeps its row, as `record` keeps it, and one the person
    // deleted stays deleted until sync has pushed that. Returns how many were new.
    pub async fn put(&self, entries: &[NewEntry]) -> Result<u64, StorageError> {
        if let Some(entry) = entries.iter().find(|entry| entry.query.len() > MAX_QUERY_BYTES) {
            return Err(StorageError::TooLarge {
                got: entry.query.len(),
                limit: MAX_QUERY_BYTES,
            });
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let mut inserted = Vec::new();
        let mut seen = HashSet::new();
        for entry in entries.iter().filter(|entry| seen.insert(entry.record_id)) {
            let (success, cancelled, error) = match &entry.outcome {
                Outcome::Success => (1_i64, 0_i64, None),
                Outcome::Error(message) => (0, 0, Some(message.as_str())),
                Outcome::Cancelled => (0, 1, None),
            };
            let added = sqlx::query(
                "INSERT INTO history (record_id, query, query_folded, driver_id, connection_id, connection_name, \
                 executed_at, duration_ms, rows_affected, success, cancelled, error) \
                 SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? \
                 WHERE NOT EXISTS (SELECT 1 FROM history_tombstones WHERE record_id = ?) \
                 ON CONFLICT (record_id) DO NOTHING",
            )
            .bind(entry.record_id.to_string())
            .bind(&entry.query)
            .bind(fold(&entry.query))
            .bind(&entry.driver_id)
            .bind(entry.connection_id.to_string())
            .bind(&entry.connection_name)
            .bind(to_unix(entry.executed_at))
            .bind(entry.duration_ms)
            .bind(entry.rows_affected)
            .bind(success)
            .bind(cancelled)
            .bind(error)
            .bind(entry.record_id.to_string())
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            if added > 0 {
                inserted.push(entry.record_id);
            }
        }
        transaction.commit().await?;
        let count = inserted.len() as u64;
        self.history_changed(inserted, []);
        Ok(count)
    }

    // Every entry's record id, so a host can tell which of its own the store lacks or holds past.
    pub async fn record_ids(&self) -> Result<Vec<Uuid>, StorageError> {
        let texts: Vec<String> = sqlx::query_scalar("SELECT record_id FROM history ORDER BY id")
            .fetch_all(&self.pool)
            .await?;
        texts
            .iter()
            .map(|text| {
                Uuid::parse_str(text).map_err(|_| StorageError::Schema("a history record_id is not a UUID".to_owned()))
            })
            .collect()
    }

    // By record id, from the upgrade copies too. Returns how many were there.
    pub async fn remove(&self, record_ids: &[Uuid]) -> Result<u64, StorageError> {
        if record_ids.is_empty() {
            return Ok(0);
        }
        let copies: Vec<CopyDelete> = record_ids
            .chunks(IDS_PER_STATEMENT)
            .map(|chunk| CopyDelete {
                table: "history",
                sql: format!(
                    "DELETE FROM main.history WHERE record_id IN ({})",
                    vec!["?"; chunk.len()].join(",")
                ),
                binds: chunk.iter().map(|id| Bind::Text(id.to_string())).collect(),
            })
            .collect();
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        trim_upgrade_copies(&self.path, &copies).await?;
        let mut removed = Vec::new();
        for chunk in record_ids.chunks(IDS_PER_STATEMENT) {
            let sql = format!(
                "DELETE FROM history WHERE record_id IN ({}) RETURNING record_id",
                vec!["?"; chunk.len()].join(",")
            );
            let mut statement = sqlx::query_scalar::<_, String>(AssertSqlSafe(sql));
            for id in chunk {
                statement = statement.bind(id.to_string());
            }
            removed.extend(statement.fetch_all(&mut *transaction).await?);
        }
        if !removed.is_empty() {
            sqlx::query("INSERT INTO history_search(history_search) VALUES('optimize')")
                .execute(&mut *transaction)
                .await?;
        }
        transaction.commit().await?;
        let count = removed.len() as u64;
        self.history_changed([], super::record_ids(removed));
        Ok(count)
    }
}

#[cfg(test)]
#[path = "host_entries_tests.rs"]
mod tests;
