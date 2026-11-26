// What sync reads of the history (core ADR 0054, Dirty state is a diff): every entry, and a tombstone for each entry
// the person deleted, kept until sync has pushed its deletion. A prune by the retention, a host's removal and a
// deletion a pull brings write none, so only the person's own deletions leave this device.

use sqlx::{AssertSqlSafe, SqliteConnection};
use uuid::Uuid;

use super::{ENTRY_COLUMNS, Entry, IDS_PER_STATEMENT, QueryHistory};
use crate::error::StorageError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryTombstone {
    pub record_id: Uuid,
    // The connection the deleted run was of.
    pub connection_id: Uuid,
}

impl QueryHistory {
    // Oldest row first.
    pub async fn entries(&self) -> Result<Vec<Entry>, StorageError> {
        let sql = format!("SELECT {ENTRY_COLUMNS} FROM history h ORDER BY h.id");
        sqlx::query(AssertSqlSafe(sql))
            .fetch_all(&self.pool)
            .await?
            .into_iter()
            .map(Self::row_to_entry)
            .collect()
    }

    // Oldest first.
    pub async fn tombstones(&self) -> Result<Vec<HistoryTombstone>, StorageError> {
        let rows: Vec<(String, String)> =
            sqlx::query_as("SELECT record_id, connection_id FROM history_tombstones ORDER BY id")
                .fetch_all(&self.pool)
                .await?;
        let uuid = |text: &str| {
            Uuid::parse_str(text)
                .map_err(|_| StorageError::Schema("a history tombstone holds a non-UUID id".to_owned()))
        };
        rows.iter()
            .map(|(record_id, connection_id)| {
                Ok(HistoryTombstone {
                    record_id: uuid(record_id)?,
                    connection_id: uuid(connection_id)?,
                })
            })
            .collect()
    }

    // The deletions sync has pushed, or found the provider already holds.
    pub async fn drop_tombstones(&self, record_ids: &[Uuid]) -> Result<(), StorageError> {
        let mut connection = self.pool.acquire().await?;
        untombstone(&mut connection, record_ids).await
    }
}

// The entries `filter` names, in the person's deletion, before the rows go. None is dropped before sync takes it, so a
// device that syncs again after a long time offline still sends every deletion; each is one entry the person had.
pub(super) async fn tombstone(
    database: &mut SqliteConnection,
    filter: &str,
    binds: &[super::Bind],
) -> Result<(), StorageError> {
    let sql = format!(
        "INSERT OR IGNORE INTO history_tombstones (record_id, connection_id) \
         SELECT record_id, connection_id FROM history {filter}"
    );
    let mut statement = sqlx::query(AssertSqlSafe(sql));
    for bind in binds {
        statement = match bind {
            super::Bind::Text(text) => statement.bind(text.clone()),
            super::Bind::Integer(value) => statement.bind(*value),
        };
    }
    statement.execute(&mut *database).await?;
    Ok(())
}

// Entries put back under their ids are no longer deleted.
pub(super) async fn untombstone(database: &mut SqliteConnection, record_ids: &[Uuid]) -> Result<(), StorageError> {
    for chunk in record_ids.chunks(IDS_PER_STATEMENT) {
        let sql = format!(
            "DELETE FROM history_tombstones WHERE record_id IN ({})",
            vec!["?"; chunk.len()].join(",")
        );
        let mut statement = sqlx::query(AssertSqlSafe(sql));
        for id in chunk {
            statement = statement.bind(id.to_string());
        }
        statement.execute(&mut *database).await?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "synced_tests.rs"]
mod tests;
