// Entries a host keeps in a store of its own and copies here under their ids: the Mac records each run in its
// history and here, until its history reads from the core (core ADR 0010, slice 3).

use std::collections::HashSet;

use sqlx::{AssertSqlSafe, Connection};
use uuid::Uuid;

use super::{
    Bind, CopyDelete, ENTRY_COLUMNS, Entry, IDS_PER_STATEMENT, INSERT_COLUMNS, INSERT_VALUES, MAX_QUERY_BYTES,
    NewEntry, QueryHistory, RunDetails, bind_details, bind_entry, trim_history_copies,
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

    // Details for runs this store already holds, as a host learns them after it mirrored the runs, in one commit. A
    // field the row has none of takes the value given; one it has, a value a newer build wrote included, stays. A run
    // the store does not hold, one the person deleted among them, is passed over. Returns how many rows changed.
    pub async fn fill_details(&self, details: &[(Uuid, RunDetails)]) -> Result<u64, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let mut changed = 0_u64;
        let mut synced = Vec::new();
        for (record_id, given) in details {
            let empty: Option<(bool, bool, bool, bool, bool, bool, bool)> = sqlx::query_as(
                "SELECT database IS NULL, schema IS NULL, source IS NULL, statement_type IS NULL, \
                 first_row_us IS NULL, server_us IS NULL, fingerprint IS NULL FROM history h WHERE h.record_id = ? \
                 AND NOT EXISTS (SELECT 1 FROM history_tombstones t WHERE t.record_id = h.record_id)",
            )
            .bind(record_id.to_string())
            .fetch_optional(&mut *transaction)
            .await?;
            let Some((database, schema, source, statement_type, first_row, server, fingerprint)) = empty else {
                continue;
            };
            let fills_synced = (database && given.database.is_some())
                || (schema && given.schema.is_some())
                || (source && given.source.is_some())
                || (statement_type && given.statement_type.is_some())
                || (first_row && given.first_row_us.is_some())
                || (server && given.server_us.is_some());
            if !fills_synced && !(fingerprint && given.fingerprint.is_some()) {
                continue;
            }
            let statement = sqlx::query(
                "UPDATE history SET database = COALESCE(database, ?), schema = COALESCE(schema, ?), \
                 source = COALESCE(source, ?), statement_type = COALESCE(statement_type, ?), \
                 first_row_us = COALESCE(first_row_us, ?), server_us = COALESCE(server_us, ?), \
                 fingerprint = COALESCE(fingerprint, ?) WHERE record_id = ?",
            );
            bind_details!(statement, given)
                .bind(record_id.to_string())
                .execute(&mut *transaction)
                .await?;
            changed += 1;
            // A fingerprint never leaves the device, so filling only that tells sync nothing.
            if fills_synced {
                synced.push(*record_id);
            }
        }
        transaction.commit().await?;
        self.history_changed(synced, []);
        Ok(changed)
    }

    // Runs by record id, in rowid order and each once. An id the store does not hold, one the person deleted among
    // them, is left out.
    pub async fn entries_by_record_id(&self, record_ids: &[Uuid]) -> Result<Vec<Entry>, StorageError> {
        let wanted: Vec<String> = record_ids
            .iter()
            .collect::<HashSet<_>>()
            .into_iter()
            .map(Uuid::to_string)
            .collect();
        // One read transaction, so every chunk reads the same state.
        let mut transaction = self.pool.begin().await?;
        let mut found = Vec::with_capacity(wanted.len());
        for chunk in wanted.chunks(IDS_PER_STATEMENT) {
            let sql = format!(
                "SELECT {ENTRY_COLUMNS} FROM history h WHERE h.record_id IN ({}) \
                 AND NOT EXISTS (SELECT 1 FROM history_tombstones t WHERE t.record_id = h.record_id)",
                vec!["?"; chunk.len()].join(",")
            );
            let mut statement = sqlx::query(AssertSqlSafe(sql));
            for id in chunk {
                statement = statement.bind(id.clone());
            }
            for row in statement.fetch_all(&mut *transaction).await? {
                found.push(Self::row_to_entry(row)?);
            }
        }
        transaction.commit().await?;
        found.sort_by_key(|entry| entry.id);
        Ok(found)
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
