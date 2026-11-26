use std::collections::HashSet;
use std::path::PathBuf;
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection, SqlitePool};
use tokio::sync::watch;
use uuid::Uuid;

use crate::error::StorageError;
use crate::journal::{JournalEntry, RecordKind, RecordRef, Signals};
use crate::name_rules::{self, NameFault};
use crate::stored_id::{optional_uuid_column, uuid_column};
use crate::unix_time::{from_unix_millis, to_unix_millis};

use super::ordering;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQueryFolder {
    pub id: Uuid,
    // None puts the folder in every connection.
    pub connection_id: Option<Uuid>,
    pub name: String,
    // A folder this store may not hold yet, which reads as the top level.
    pub parent_id: Option<Uuid>,
    pub order: i64,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

const MAX_NAME_CHARS: usize = 200;

#[derive(Debug, Clone)]
pub struct SavedQueryFolders {
    pool: SqlitePool,
    path: PathBuf,
    signals: Signals,
}

impl SavedQueryFolders {
    pub(crate) fn new(pool: SqlitePool, path: PathBuf, signals: Signals) -> Self {
        Self { pool, path, signals }
    }

    pub fn changes(&self) -> watch::Receiver<u64> {
        self.signals.subscribe()
    }

    fn wrote(&self, written: impl IntoIterator<Item = Uuid>) {
        self.signals.changed(&[folders(written, [])]);
    }

    pub async fn create(
        &self,
        connection: Option<Uuid>,
        name: &str,
        parent: Option<Uuid>,
    ) -> Result<Uuid, StorageError> {
        let name = checked_name(name)?;
        let owner = connection.map(|id| id.to_string());
        let parent = parent.map(|id| id.to_string());
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        check_parent(&mut transaction, owner.as_deref(), parent.as_deref(), None).await?;
        check_name(&mut transaction, owner.as_deref(), parent.as_deref(), &name, None).await?;
        let now = to_unix_millis(SystemTime::now());
        let id = Uuid::new_v4();
        let (order, mut moved) =
            ordering::next_folder_order(&mut transaction, owner.as_deref(), parent.as_deref()).await?;
        sqlx::query(
            "INSERT INTO saved_query_folders \
             (record_id, connection_id, name, parent_record_id, sort_order, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id.to_string())
        .bind(&owner)
        .bind(name)
        .bind(&parent)
        .bind(order)
        .bind(now)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(name_taken)?;
        transaction.commit().await?;
        moved.push(id);
        self.wrote(moved);
        Ok(id)
    }

    pub async fn rename(&self, id: Uuid, name: &str) -> Result<(), StorageError> {
        let name = checked_name(name)?;
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (rowid, owner, parent, previous): (i64, Option<String>, Option<String>, String) = sqlx::query_as(
            "SELECT id, connection_id, parent_record_id, name FROM saved_query_folders WHERE record_id = ?",
        )
        .bind(id.to_string())
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or(StorageError::NotFound)?;
        if previous == name {
            transaction.commit().await?;
            return Ok(());
        }
        check_name(
            &mut transaction,
            owner.as_deref(),
            parent.as_deref(),
            &name,
            Some(rowid),
        )
        .await?;
        sqlx::query("UPDATE saved_query_folders SET name = ?, updated_at = ? WHERE id = ?")
            .bind(name)
            .bind(to_unix_millis(SystemTime::now()))
            .bind(rowid)
            .execute(&mut *transaction)
            .await
            .map_err(name_taken)?;
        transaction.commit().await?;
        self.wrote([id]);
        Ok(())
    }

    pub async fn move_to(&self, id: Uuid, parent: Option<Uuid>) -> Result<(), StorageError> {
        let parent = parent.map(|id| id.to_string());
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (rowid, owner, previous, name): (i64, Option<String>, Option<String>, String) = sqlx::query_as(
            "SELECT id, connection_id, parent_record_id, name FROM saved_query_folders WHERE record_id = ?",
        )
        .bind(id.to_string())
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or(StorageError::NotFound)?;
        check_parent(&mut transaction, owner.as_deref(), parent.as_deref(), Some(id)).await?;
        if previous == parent {
            transaction.commit().await?;
            return Ok(());
        }
        check_name(
            &mut transaction,
            owner.as_deref(),
            parent.as_deref(),
            &name,
            Some(rowid),
        )
        .await?;
        let (order, mut moved) =
            ordering::next_folder_order(&mut transaction, owner.as_deref(), parent.as_deref()).await?;
        sqlx::query("UPDATE saved_query_folders SET parent_record_id = ?, updated_at = ?, sort_order = ? WHERE id = ?")
            .bind(&parent)
            .bind(to_unix_millis(SystemTime::now()))
            .bind(order)
            .bind(rowid)
            .execute(&mut *transaction)
            .await
            .map_err(name_taken)?;
        moved.push(id);
        moved.extend(ordering::compact_folders(&mut transaction, owner.as_deref(), previous.as_deref()).await?);
        transaction.commit().await?;
        self.wrote(moved);
        Ok(())
    }

    pub async fn delete(&self, id: Uuid) -> Result<(), StorageError> {
        let changed = super::deletion::delete_folder(&self.pool, &self.path, id).await?;
        self.signals.changed(&changed);
        Ok(())
    }

    // What one connection shows: its own folders and those with no connection.
    pub async fn list(&self, connection: Uuid) -> Result<Vec<SavedQueryFolder>, StorageError> {
        let rows = sqlx::query(concat!(
            "SELECT ",
            folder_columns!(),
            " FROM saved_query_folders WHERE connection_id = ? OR connection_id IS NULL \
             ORDER BY COALESCE(parent_record_id, ''), sort_order, name COLLATE NOCASE, id"
        ))
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_folder).collect()
    }

    // Folders a pull or another store brings, each under its own id. Returns the ids the store renamed
    // to settle a collision (core ADR 0052, Collisions).
    pub async fn put(&self, folders: &[SavedQueryFolder]) -> Result<Vec<Uuid>, StorageError> {
        if folders.is_empty() {
            return Ok(Vec::new());
        }
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let settled = super::put::put_folders(&mut transaction, folders, SystemTime::now()).await?;
        transaction.commit().await?;
        self.wrote(folders.iter().map(|folder| folder.id).chain(settled.iter().copied()));
        Ok(settled)
    }
}

// The parent has to show wherever the folder does, and the folder may not end up inside itself. A
// parent this store does not hold ends the walk, as it reads as the top level.
async fn check_parent(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    parent: Option<&str>,
    moving: Option<Uuid>,
) -> Result<(), StorageError> {
    let Some(parent) = parent else {
        return Ok(());
    };
    let target: Option<String> =
        sqlx::query_scalar::<_, Option<String>>("SELECT connection_id FROM saved_query_folders WHERE record_id = ?")
            .bind(parent)
            .fetch_optional(&mut *database)
            .await?
            .ok_or(StorageError::NotFound)?;
    if target.is_some() && target.as_deref() != owner {
        return Err(StorageError::NotFound);
    }
    let moving = moving.map(|id| id.to_string());
    let mut above = Some(parent.to_owned());
    let mut visited = HashSet::new();
    while let Some(id) = above {
        if moving.as_deref() == Some(id.as_str()) || !visited.insert(id.clone()) {
            let cycle = moving.as_deref().unwrap_or(id.as_str());
            return Err(StorageError::FolderCycle {
                id: Uuid::parse_str(cycle).unwrap_or_default(),
            });
        }
        above = sqlx::query_scalar::<_, Option<String>>(
            "SELECT parent_record_id FROM saved_query_folders WHERE record_id = ?",
        )
        .bind(&id)
        .fetch_optional(&mut *database)
        .await?
        .flatten();
    }
    Ok(())
}

async fn check_name(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    parent: Option<&str>,
    name: &str,
    own_id: Option<i64>,
) -> Result<(), StorageError> {
    let siblings: Vec<(i64, String)> =
        sqlx::query_as("SELECT id, name FROM saved_query_folders WHERE connection_id IS ? AND parent_record_id IS ?")
            .bind(owner)
            .bind(parent)
            .fetch_all(database)
            .await?;
    let key = name_key(name);
    if siblings
        .into_iter()
        .any(|(id, sibling)| Some(id) != own_id && name_key(&sibling) == key)
    {
        return Err(StorageError::FolderNameTaken);
    }
    Ok(())
}

// Two folder names are one when they read the same in any case.
pub(super) fn name_key(name: &str) -> String {
    name_rules::shown(name).to_lowercase()
}

pub(super) fn row_to_folder(row: &sqlx::sqlite::SqliteRow) -> Result<SavedQueryFolder, StorageError> {
    Ok(SavedQueryFolder {
        id: uuid_column(row, "record_id")?,
        connection_id: optional_uuid_column(row, "connection_id")?,
        name: row.try_get("name")?,
        parent_id: optional_uuid_column(row, "parent_record_id")?,
        order: row.try_get("sort_order")?,
        created_at: from_unix_millis(row.try_get::<i64, _>("created_at")?),
        updated_at: from_unix_millis(row.try_get::<i64, _>("updated_at")?),
    })
}

pub(super) fn folders(
    written: impl IntoIterator<Item = Uuid>,
    deleted: impl IntoIterator<Item = Uuid>,
) -> JournalEntry {
    JournalEntry::new(RecordKind::SavedQueryFolder)
        .wrote(written.into_iter().map(RecordRef::Id))
        .deleted(deleted.into_iter().map(RecordRef::Id))
}

fn checked_name(name: &str) -> Result<String, StorageError> {
    let name = name_rules::checked(name).map_err(|error| match error {
        NameFault::Empty => StorageError::EmptyName,
        NameFault::ControlCharacter => StorageError::FolderNameInvalid,
    })?;
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(StorageError::TooLarge {
            got: name.chars().count(),
            limit: MAX_NAME_CHARS,
        });
    }
    Ok(name)
}

fn name_taken(error: sqlx::Error) -> StorageError {
    match &error {
        sqlx::Error::Database(database) if database.is_unique_violation() => StorageError::FolderNameTaken,
        _ => StorageError::Database(error),
    }
}

#[cfg(test)]
#[path = "folders_tests.rs"]
mod tests;
