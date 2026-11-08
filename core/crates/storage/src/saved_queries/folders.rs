use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection, SqlitePool};
use tokio::sync::watch;
use uuid::Uuid;

use crate::error::StorageError;
use crate::name_rules::{self, NameFault};
use crate::unix_time::{from_unix, to_unix};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQueryFolder {
    pub id: i64,
    pub connection_id: Uuid,
    pub name: String,
    pub parent_id: Option<i64>,
    pub order: i64,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

const MAX_NAME_CHARS: usize = 200;

#[derive(Debug, Clone)]
pub struct SavedQueryFolders {
    pool: SqlitePool,
    path: PathBuf,
    changes: Arc<watch::Sender<u64>>,
}

impl SavedQueryFolders {
    pub(crate) fn new(pool: SqlitePool, path: PathBuf, changes: Arc<watch::Sender<u64>>) -> Self {
        Self { pool, path, changes }
    }

    pub fn changes(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    fn changed(&self) {
        self.changes
            .send_modify(|revision| *revision = revision.wrapping_add(1));
    }

    pub async fn create(&self, connection: Uuid, name: &str, parent: Option<i64>) -> Result<i64, StorageError> {
        let name = checked_name(name)?;
        let owner = connection.to_string();
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        check_parent(&mut transaction, &owner, parent, None).await?;
        check_name(&mut transaction, &owner, parent, &name, None).await?;
        let now = to_unix(SystemTime::now());
        let id = sqlx::query(
            "INSERT INTO saved_query_folders (connection_id, name, parent_id, sort_order, created_at, updated_at) \
             VALUES (?1, ?2, ?3, \
                 (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_query_folders \
                  WHERE connection_id = ?1 AND parent_id IS ?3), ?4, ?4) \
             RETURNING id",
        )
        .bind(owner)
        .bind(name)
        .bind(parent)
        .bind(now)
        .fetch_one(&mut *transaction)
        .await
        .map_err(name_taken)?
        .try_get("id")?;
        transaction.commit().await?;
        self.changed();
        Ok(id)
    }

    pub async fn rename(&self, id: i64, name: &str) -> Result<(), StorageError> {
        let name = checked_name(name)?;
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (owner, parent, previous): (String, Option<i64>, String) =
            sqlx::query_as("SELECT connection_id, parent_id, name FROM saved_query_folders WHERE id = ?")
                .bind(id)
                .fetch_optional(&mut *transaction)
                .await?
                .ok_or(StorageError::NotFound)?;
        if previous == name {
            transaction.commit().await?;
            return Ok(());
        }
        check_name(&mut transaction, &owner, parent, &name, Some(id)).await?;
        sqlx::query("UPDATE saved_query_folders SET name = ?, updated_at = ? WHERE id = ?")
            .bind(name)
            .bind(to_unix(SystemTime::now()))
            .bind(id)
            .execute(&mut *transaction)
            .await
            .map_err(name_taken)?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn move_to(&self, id: i64, parent: Option<i64>) -> Result<(), StorageError> {
        let mut database = self.pool.acquire().await?;
        let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (owner, previous, name): (String, Option<i64>, String) =
            sqlx::query_as("SELECT connection_id, parent_id, name FROM saved_query_folders WHERE id = ?")
                .bind(id)
                .fetch_optional(&mut *transaction)
                .await?
                .ok_or(StorageError::NotFound)?;
        check_parent(&mut transaction, &owner, parent, Some(id)).await?;
        if previous == parent {
            transaction.commit().await?;
            return Ok(());
        }
        check_name(&mut transaction, &owner, parent, &name, Some(id)).await?;
        sqlx::query(
            "UPDATE saved_query_folders SET parent_id = ?1, updated_at = ?2, \
                 sort_order = (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_query_folders \
                               WHERE connection_id = ?3 AND parent_id IS ?1) \
             WHERE id = ?4",
        )
        .bind(parent)
        .bind(to_unix(SystemTime::now()))
        .bind(&owner)
        .bind(id)
        .execute(&mut *transaction)
        .await
        .map_err(name_taken)?;
        super::ordering::compact_folders(&mut transaction, &owner, previous).await?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn delete(&self, id: i64) -> Result<(), StorageError> {
        super::deletion::delete_folder(&self.pool, &self.path, id).await?;
        self.changed();
        Ok(())
    }

    pub async fn list(&self, connection: Uuid) -> Result<Vec<SavedQueryFolder>, StorageError> {
        let rows = sqlx::query(
            "SELECT id, connection_id, name, parent_id, sort_order, created_at, updated_at \
             FROM saved_query_folders WHERE connection_id = ? \
             ORDER BY COALESCE(parent_id, 0), sort_order, name COLLATE NOCASE, id",
        )
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(row_to_folder).collect()
    }
}

async fn check_parent(
    database: &mut SqliteConnection,
    connection: &str,
    parent: Option<i64>,
    moving: Option<i64>,
) -> Result<(), StorageError> {
    let mut above = parent;
    let mut visited = HashSet::new();
    while let Some(id) = above {
        if Some(id) == moving || !visited.insert(id) {
            return Err(StorageError::FolderCycle {
                id: moving.unwrap_or(id),
            });
        }
        let (owner, next): (String, Option<i64>) =
            sqlx::query_as("SELECT connection_id, parent_id FROM saved_query_folders WHERE id = ?")
                .bind(id)
                .fetch_optional(&mut *database)
                .await?
                .ok_or(StorageError::NotFound)?;
        if owner != connection {
            return Err(StorageError::NotFound);
        }
        above = next;
    }
    Ok(())
}

async fn check_name(
    database: &mut SqliteConnection,
    connection: &str,
    parent: Option<i64>,
    name: &str,
    own_id: Option<i64>,
) -> Result<(), StorageError> {
    let siblings: Vec<(i64, String)> =
        sqlx::query_as("SELECT id, name FROM saved_query_folders WHERE connection_id = ? AND parent_id IS ?")
            .bind(connection)
            .bind(parent)
            .fetch_all(database)
            .await?;
    let key = name_rules::shown(name).to_lowercase();
    if siblings
        .into_iter()
        .any(|(id, sibling)| Some(id) != own_id && name_rules::shown(&sibling).to_lowercase() == key)
    {
        return Err(StorageError::FolderNameTaken);
    }
    Ok(())
}

pub(super) fn row_to_folder(row: sqlx::sqlite::SqliteRow) -> Result<SavedQueryFolder, StorageError> {
    let owner: String = row.try_get("connection_id")?;
    let connection_id = Uuid::parse_str(&owner).map_err(|error| StorageError::Schema(error.to_string()))?;
    Ok(SavedQueryFolder {
        id: row.try_get("id")?,
        connection_id,
        name: row.try_get("name")?,
        parent_id: row.try_get("parent_id")?,
        order: row.try_get("sort_order")?,
        created_at: from_unix(row.try_get::<i64, _>("created_at")?),
        updated_at: from_unix(row.try_get::<i64, _>("updated_at")?),
    })
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
