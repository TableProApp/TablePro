// Entries a host keeps in a store of its own and copies here under their ids: the Mac records each run in its
// history and here, until its history reads from the core (core ADR 0010, slice 3).

use std::collections::HashSet;

use sqlx::{AssertSqlSafe, Connection};
use uuid::Uuid;

use super::{
    Bind, CopyDelete, IDS_PER_STATEMENT, INSERT_COLUMNS, INSERT_VALUES, MAX_QUERY_BYTES, NewEntry, QueryHistory,
    bind_entry, trim_history_copies,
};
use crate::error::StorageError;

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
        let sql = format!(
            "INSERT INTO history ({INSERT_COLUMNS}) SELECT {INSERT_VALUES} \
             WHERE NOT EXISTS (SELECT 1 FROM history_tombstones WHERE record_id = ?) \
             ON CONFLICT (record_id) DO NOTHING"
        );
        for entry in entries.iter().filter(|entry| seen.insert(entry.record_id)) {
            let added = bind_entry!(sqlx::query(AssertSqlSafe(sql.clone())), entry)
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

    // By record id, from the upgrade copies too, with no tombstone: for a host whose own store let them go, as a prune
    // does, and for deletions a pull brings. The person's own go through `delete_records`. Returns how many were there.
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
        trim_history_copies(&self.files, &copies).await?;
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
