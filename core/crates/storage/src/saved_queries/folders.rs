use std::path::PathBuf;
use std::time::SystemTime;

use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;
use crate::unix_time::{from_unix, to_unix};

/// A folder of a connection's saved queries, which can hold others.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQueryFolder {
    pub id: i64,
    pub connection_id: Uuid,
    pub name: String,
    /// The folder it sits in, none at the top of the connection's list.
    pub parent_id: Option<i64>,
    /// Its place among the folders of its parent.
    pub order: i64,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

/// A name long enough to be unreadable in the list is a name nobody
/// meant to type, as for a saved query.
const MAX_NAME_CHARS: usize = 200;

/// The folders saved queries are filed in. Cloning shares the pool with
/// the history it lives beside.
#[derive(Debug, Clone)]
pub struct SavedQueryFolders {
    pool: SqlitePool,
    // The database's file, whose upgrade copies a delete reaches too.
    path: PathBuf,
}

impl SavedQueryFolders {
    pub(crate) fn new(pool: SqlitePool, path: PathBuf) -> Self {
        Self { pool, path }
    }

    /// Make a folder in `parent`, none for the top, last among its
    /// siblings. The parent must be the same connection's.
    pub async fn create(&self, connection: Uuid, name: &str, parent: Option<i64>) -> Result<i64, StorageError> {
        let name = checked_name(name)?;
        if let Some(parent) = parent {
            let owner: Option<String> =
                sqlx::query_scalar("SELECT connection_id FROM saved_query_folders WHERE id = ?")
                    .bind(parent)
                    .fetch_optional(&self.pool)
                    .await?;
            if owner.as_deref() != Some(connection.to_string().as_str()) {
                return Err(StorageError::NotFound);
            }
        }
        let now = to_unix(SystemTime::now());
        let id = sqlx::query(
            "INSERT INTO saved_query_folders (connection_id, name, parent_id, sort_order, created_at, updated_at) \
             VALUES (?1, ?2, ?3, \
                 (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_query_folders \
                  WHERE connection_id = ?1 AND parent_id IS ?3), ?4, ?4) \
             RETURNING id",
        )
        .bind(connection.to_string())
        .bind(name)
        .bind(parent)
        .bind(now)
        .fetch_one(&self.pool)
        .await
        .map_err(name_taken)?
        .try_get("id")?;
        Ok(id)
    }

    pub async fn rename(&self, id: i64, name: &str) -> Result<(), StorageError> {
        let name = checked_name(name)?;
        let affected = sqlx::query("UPDATE saved_query_folders SET name = ?, updated_at = ? WHERE id = ?")
            .bind(name)
            .bind(to_unix(SystemTime::now()))
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(name_taken)?
            .rows_affected();
        match affected {
            0 => Err(StorageError::NotFound),
            _ => Ok(()),
        }
    }

    /// Move a folder into `parent`, none for the top, last among the
    /// folders there. A folder never goes inside itself or inside one it
    /// holds.
    pub async fn move_to(&self, id: i64, parent: Option<i64>) -> Result<(), StorageError> {
        let mut transaction = self.pool.begin().await?;
        let connection: Option<String> =
            sqlx::query_scalar("SELECT connection_id FROM saved_query_folders WHERE id = ?")
                .bind(id)
                .fetch_optional(&mut *transaction)
                .await?;
        let connection = connection.ok_or(StorageError::NotFound)?;
        let mut above = parent;
        while let Some(held) = above {
            if held == id {
                return Err(StorageError::FolderCycle { id });
            }
            let row = sqlx::query("SELECT connection_id, parent_id FROM saved_query_folders WHERE id = ?")
                .bind(held)
                .fetch_optional(&mut *transaction)
                .await?
                .ok_or(StorageError::NotFound)?;
            if row.try_get::<String, _>("connection_id")? != connection {
                return Err(StorageError::NotFound);
            }
            above = row.try_get("parent_id")?;
        }
        sqlx::query(
            "UPDATE saved_query_folders SET parent_id = ?1, updated_at = ?2, \
                 sort_order = (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_query_folders \
                               WHERE connection_id = ?3 AND parent_id IS ?1) \
             WHERE id = ?4",
        )
        .bind(parent)
        .bind(to_unix(SystemTime::now()))
        .bind(connection)
        .bind(id)
        .execute(&mut *transaction)
        .await
        .map_err(name_taken)?;
        transaction.commit().await?;
        Ok(())
    }

    /// Delete a folder and the folders in it. The queries filed in them
    /// stay, at the top of the connection's list.
    pub async fn delete(&self, id: i64) -> Result<(), StorageError> {
        // The folders in it go from the copies with it, by the cascade, and
        // the copies' sweep of folders the database no longer has.
        crate::query_history::trim_upgrade_copies(
            &self.path,
            &[crate::query_history::CopyDelete {
                table: "saved_query_folders",
                sql: "DELETE FROM main.saved_query_folders WHERE id = ?".to_owned(),
                binds: vec![crate::query_history::Bind::Integer(id)],
            }],
        )
        .await?;
        let affected = sqlx::query("DELETE FROM saved_query_folders WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?
            .rows_affected();
        match affected {
            0 => Err(StorageError::NotFound),
            _ => Ok(()),
        }
    }

    /// Every folder of `connection`, the order a list shows them in: by
    /// parent, then place, then name.
    pub async fn list(&self, connection: Uuid) -> Result<Vec<SavedQueryFolder>, StorageError> {
        let rows = sqlx::query(
            "SELECT id, connection_id, name, parent_id, sort_order, created_at, updated_at \
             FROM saved_query_folders WHERE connection_id = ? \
             ORDER BY COALESCE(parent_id, 0), sort_order, name COLLATE NOCASE, id",
        )
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                let owner: String = row.try_get("connection_id")?;
                Ok(SavedQueryFolder {
                    id: row.try_get("id")?,
                    connection_id: Uuid::parse_str(&owner).unwrap_or_default(),
                    name: row.try_get("name")?,
                    parent_id: row.try_get("parent_id")?,
                    order: row.try_get("sort_order")?,
                    created_at: from_unix(row.try_get::<i64, _>("created_at")?),
                    updated_at: from_unix(row.try_get::<i64, _>("updated_at")?),
                })
            })
            .collect()
    }
}

fn checked_name(name: &str) -> Result<&str, StorageError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(StorageError::EmptyName);
    }
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
