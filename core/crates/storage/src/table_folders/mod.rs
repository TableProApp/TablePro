use std::time::{SystemTime, UNIX_EPOCH};

use sqlx::{AssertSqlSafe, Connection, Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;
use crate::journal::{JournalEntry, RecordKind, RecordRef, Signals};
use crate::query_history::{Bind, CopyDelete, trim_upgrade_copies};

#[cfg(test)]
mod tests;

/// A table as a connection's catalog names it. An engine without databases or schemas leaves that
/// part empty.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TableRef {
    pub connection_id: Uuid,
    pub database: String,
    pub schema: String,
    pub name: String,
}

/// Where a folder sits: a connection's database and schema.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TableScope {
    pub connection_id: Uuid,
    pub database: String,
    pub schema: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableFolder {
    pub id: Uuid,
    pub scope: TableScope,
    pub name: String,
    /// Whole milliseconds since the Unix epoch, the precision a CloudKit date keeps.
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableFolderItem {
    pub table: TableRef,
    pub folder_id: Uuid,
}

/// The folders a person files a connection's tables in, in the history database. A table sits in at
/// most one folder; an item whose folder is missing reads as unfiled, since a pull can bring the
/// item first.
#[derive(Debug, Clone)]
pub struct TableFolders {
    pool: SqlitePool,
    path: std::path::PathBuf,
    signals: Signals,
}

impl TableFolders {
    pub(crate) fn new(pool: SqlitePool, path: std::path::PathBuf, signals: Signals) -> Self {
        Self { pool, path, signals }
    }

    pub fn changes(&self) -> tokio::sync::watch::Receiver<u64> {
        self.signals.subscribe()
    }

    pub async fn folders(&self, connection: Uuid) -> Result<Vec<TableFolder>, StorageError> {
        let rows = sqlx::query(
            "SELECT id, connection_id, database, schema, name, created_at, updated_at FROM table_folders \
             WHERE connection_id = ? ORDER BY database, schema, name COLLATE NOCASE, id",
        )
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(folder_from_row).collect()
    }

    pub async fn items(&self, connection: Uuid) -> Result<Vec<TableFolderItem>, StorageError> {
        let rows = sqlx::query(
            "SELECT connection_id, database, schema, name, folder_id FROM table_folder_items \
             WHERE connection_id = ? ORDER BY database, schema, name",
        )
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                Ok(TableFolderItem {
                    table: TableRef {
                        connection_id: uuid_column(&row, "connection_id")?,
                        database: row.try_get("database")?,
                        schema: row.try_get("schema")?,
                        name: row.try_get("name")?,
                    },
                    folder_id: uuid_column(&row, "folder_id")?,
                })
            })
            .collect()
    }

    /// A new folder, holding no table yet.
    pub async fn create(&self, scope: TableScope, name: &str) -> Result<TableFolder, StorageError> {
        let now = now_ms();
        let folder = TableFolder {
            id: Uuid::new_v4(),
            scope,
            name: checked_name(name)?.to_owned(),
            created_at_ms: now,
            updated_at_ms: now,
        };
        self.put(&folder).await?;
        Ok(folder)
    }

    /// Adds the folder as it is, or replaces the one with its id, as a pull or a move into the core
    /// brings it with its own id and times.
    pub async fn put(&self, folder: &TableFolder) -> Result<(), StorageError> {
        checked_name(&folder.name)?;
        sqlx::query(
            "INSERT INTO table_folders (id, connection_id, database, schema, name, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET connection_id = excluded.connection_id, \
             database = excluded.database, schema = excluded.schema, name = excluded.name, \
             created_at = excluded.created_at, updated_at = excluded.updated_at",
        )
        .bind(folder.id.to_string())
        .bind(folder.scope.connection_id.to_string())
        .bind(&folder.scope.database)
        .bind(&folder.scope.schema)
        .bind(&folder.name)
        .bind(folder.created_at_ms)
        .bind(folder.updated_at_ms)
        .execute(&self.pool)
        .await?;
        self.tell(JournalEntry::new(RecordKind::TableFolder).wrote([RecordRef::Id(folder.id)]), None);
        Ok(())
    }

    pub async fn rename(&self, id: Uuid, name: &str) -> Result<(), StorageError> {
        let name = checked_name(name)?;
        let changed = sqlx::query("UPDATE table_folders SET name = ?, updated_at = ? WHERE id = ? AND name IS NOT ?")
            .bind(name)
            .bind(now_ms())
            .bind(id.to_string())
            .bind(name)
            .execute(&self.pool)
            .await?
            .rows_affected();
        if changed > 0 {
            self.tell(JournalEntry::new(RecordKind::TableFolder).wrote([RecordRef::Id(id)]), None);
            return Ok(());
        }
        let exists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM table_folders WHERE id = ?")
            .bind(id.to_string())
            .fetch_one(&self.pool)
            .await?;
        if exists == 0 {
            Err(StorageError::NotFound)
        } else {
            Ok(())
        }
    }

    /// Deletes the folder, and its tables go back to the schema's list. The upgrade copies lose it
    /// first, so restoring one never brings it back.
    pub async fn delete(&self, id: Uuid) -> Result<bool, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let folder = || vec![Bind::Text(id.to_string())];
        trim_upgrade_copies(
            &self.path,
            &[
                CopyDelete {
                    table: "table_folder_items",
                    sql: "DELETE FROM main.table_folder_items WHERE folder_id = ?".to_owned(),
                    binds: folder(),
                },
                CopyDelete {
                    table: "table_folders",
                    sql: "DELETE FROM main.table_folders WHERE id = ?".to_owned(),
                    binds: folder(),
                },
            ],
        )
        .await?;
        let items: Vec<(String, String, String, String)> = sqlx::query_as(
            "DELETE FROM table_folder_items WHERE folder_id = ? RETURNING connection_id, database, schema, name",
        )
        .bind(id.to_string())
        .fetch_all(&mut *transaction)
        .await?;
        let folders = sqlx::query("DELETE FROM table_folders WHERE id = ?")
            .bind(id.to_string())
            .execute(&mut *transaction)
            .await?
            .rows_affected();
        transaction.commit().await?;
        let folder = JournalEntry::new(RecordKind::TableFolder).deleted((folders > 0).then_some(RecordRef::Id(id)));
        self.tell(
            folder,
            Some(JournalEntry::new(RecordKind::TableFolderItem).deleted(items.into_iter().filter_map(item_record))),
        );
        Ok(folders > 0)
    }

    /// Files each table in the folder, out of any other.
    pub async fn file(&self, tables: &[TableRef], folder: Uuid) -> Result<(), StorageError> {
        if tables.is_empty() {
            return Ok(());
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let mut filed = Vec::new();
        for table in tables {
            let changed = sqlx::query(
                "INSERT INTO table_folder_items (connection_id, database, schema, name, folder_id) \
                 VALUES (?, ?, ?, ?, ?) ON CONFLICT (connection_id, database, schema, name) \
                 DO UPDATE SET folder_id = excluded.folder_id WHERE folder_id IS NOT excluded.folder_id",
            )
            .bind(table.connection_id.to_string())
            .bind(&table.database)
            .bind(&table.schema)
            .bind(&table.name)
            .bind(folder.to_string())
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            if changed > 0 {
                filed.push(RecordRef::Table(table.clone()));
            }
        }
        transaction.commit().await?;
        self.tell(JournalEntry::new(RecordKind::TableFolderItem).wrote(filed), None);
        Ok(())
    }

    /// Takes each table out of its folder.
    pub async fn unfile(&self, tables: &[TableRef]) -> Result<(), StorageError> {
        if tables.is_empty() {
            return Ok(());
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let copies: Vec<CopyDelete> = tables
            .iter()
            .map(|table| CopyDelete {
                table: "table_folder_items",
                sql: "DELETE FROM main.table_folder_items WHERE connection_id = ? AND database = ? AND schema = ? \
                      AND name = ?"
                    .to_owned(),
                binds: vec![
                    Bind::Text(table.connection_id.to_string()),
                    Bind::Text(table.database.clone()),
                    Bind::Text(table.schema.clone()),
                    Bind::Text(table.name.clone()),
                ],
            })
            .collect();
        trim_upgrade_copies(&self.path, &copies).await?;
        let mut unfiled = Vec::new();
        for table in tables {
            let changed = sqlx::query(
                "DELETE FROM table_folder_items WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?",
            )
            .bind(table.connection_id.to_string())
            .bind(&table.database)
            .bind(&table.schema)
            .bind(&table.name)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            if changed > 0 {
                unfiled.push(RecordRef::Table(table.clone()));
            }
        }
        transaction.commit().await?;
        self.tell(JournalEntry::new(RecordKind::TableFolderItem).deleted(unfiled), None);
        Ok(())
    }

    fn tell(&self, first: JournalEntry, second: Option<JournalEntry>) {
        let entries: Vec<JournalEntry> = std::iter::once(first)
            .chain(second)
            .filter(|entry| !entry.is_empty())
            .collect();
        if !entries.is_empty() {
            self.signals.changed(&entries);
        }
    }
}

fn item_record((connection_id, database, schema, name): (String, String, String, String)) -> Option<RecordRef> {
    Some(RecordRef::Table(TableRef {
        connection_id: Uuid::parse_str(&connection_id).ok()?,
        database,
        schema,
        name,
    }))
}

fn checked_name(name: &str) -> Result<&str, StorageError> {
    if name.trim().is_empty() {
        return Err(StorageError::EmptyName);
    }
    Ok(name)
}

fn folder_from_row(row: sqlx::sqlite::SqliteRow) -> Result<TableFolder, StorageError> {
    Ok(TableFolder {
        id: uuid_column(&row, "id")?,
        scope: TableScope {
            connection_id: uuid_column(&row, "connection_id")?,
            database: row.try_get("database")?,
            schema: row.try_get("schema")?,
        },
        name: row.try_get("name")?,
        created_at_ms: row.try_get("created_at")?,
        updated_at_ms: row.try_get("updated_at")?,
    })
}

fn uuid_column(row: &sqlx::sqlite::SqliteRow, column: &str) -> Result<Uuid, StorageError> {
    let text: String = row.try_get(column)?;
    Uuid::parse_str(&text).map_err(|_| StorageError::Schema(format!("{column} is not a UUID")))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| i64::try_from(since.as_millis()).unwrap_or(i64::MAX))
}
