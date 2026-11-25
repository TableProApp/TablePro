use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection, SqlitePool};
use uuid::Uuid;

use crate::journal::{JournalEntry, RecordKind, RecordRef};
use crate::{StorageError, TableRef};
use crate::query_history::{Bind, CopyDelete, trim_upgrade_copies};
use crate::unix_time::to_unix;

use super::folders::folders;
use super::{ordering, queries};

// Its subfolders go and its queries move to the top, which writes them too.
pub(super) async fn delete_folder(pool: &SqlitePool, path: &Path, id: i64) -> Result<Vec<JournalEntry>, StorageError> {
    let mut connection = pool.acquire().await?;
    let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
    let row = sqlx::query("SELECT connection_id, parent_id FROM saved_query_folders WHERE id = ?")
        .bind(id)
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or(StorageError::NotFound)?;
    let owner: String = row.try_get("connection_id")?;
    let parent: Option<i64> = row.try_get("parent_id")?;
    let ids: Vec<i64> = sqlx::query_scalar(
        "WITH RECURSIVE subtree(id) AS (SELECT id FROM saved_query_folders WHERE id = ? \
         UNION SELECT f.id FROM saved_query_folders f JOIN subtree s ON f.parent_id = s.id) \
         SELECT id FROM subtree",
    )
    .bind(id)
    .fetch_all(&mut *transaction)
    .await?;
    let doomed: HashSet<i64> = ids.iter().copied().collect();
    trim_upgrade_copies(path, &folder_deletes(&ids)).await?;
    let rows = sqlx::query(
        "SELECT id, folder_id FROM saved_queries WHERE connection_id = ? AND folder_id IS NOT NULL \
         ORDER BY folder_id, sort_order, name COLLATE NOCASE, id",
    )
    .bind(&owner)
    .fetch_all(&mut *transaction)
    .await?;
    let mut position: i64 = sqlx::query_scalar(
        "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_queries WHERE connection_id = ? AND folder_id IS NULL",
    )
    .bind(&owner)
    .fetch_one(&mut *transaction)
    .await?;
    let mut freed = Vec::new();
    for row in rows {
        if !doomed.contains(&row.try_get::<i64, _>("folder_id")?) {
            continue;
        }
        let query: i64 = row.try_get("id")?;
        sqlx::query("UPDATE saved_queries SET folder_id = NULL, sort_order = ?, updated_at = ? WHERE id = ?")
            .bind(position)
            .bind(to_unix(SystemTime::now()))
            .bind(query)
            .execute(&mut *transaction)
            .await?;
        freed.push(query);
        position += 1;
    }
    delete_folder_rows(&mut transaction, &doomed).await?;
    let moved = ordering::compact_folders(&mut transaction, &owner, parent).await?;
    transaction.commit().await?;
    Ok([queries(freed, []), folders(moved, ids)]
        .into_iter()
        .filter(|entry| !entry.is_empty())
        .collect())
}

// The number of queries deleted, and what changed of each kind.
pub(super) async fn delete_connection(
    pool: &SqlitePool,
    path: &Path,
    connection: Uuid,
) -> Result<(usize, Vec<JournalEntry>), StorageError> {
    let mut database = pool.acquire().await?;
    let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
    let owner = connection.to_string();
    let copies = [
        "saved_queries",
        "saved_query_folders",
        "favourite_tables",
        "favourite_databases",
        "table_folders",
        "table_folder_items",
    ]
    .map(|table| CopyDelete {
        table,
        sql: format!("DELETE FROM main.{table} WHERE connection_id = ?"),
        binds: vec![Bind::Text(owner.clone())],
    });
    trim_upgrade_copies(path, &copies).await?;
    let removed: Vec<i64> = sqlx::query_scalar("DELETE FROM saved_queries WHERE connection_id = ? RETURNING id")
        .bind(&owner)
        .fetch_all(&mut *transaction)
        .await?;
    let folder_ids: Vec<i64> = sqlx::query_scalar("SELECT id FROM saved_query_folders WHERE connection_id = ?")
        .bind(&owner)
        .fetch_all(&mut *transaction)
        .await?;
    delete_folder_rows(&mut transaction, &folder_ids.iter().copied().collect()).await?;
    let tables: Vec<(String, String, String)> = sqlx::query_as(
        "DELETE FROM favourite_tables WHERE connection_id = ? RETURNING database, schema, name",
    )
    .bind(&owner)
    .fetch_all(&mut *transaction)
    .await?;
    let databases: Vec<String> =
        sqlx::query_scalar("DELETE FROM favourite_databases WHERE connection_id = ? RETURNING database")
            .bind(&owner)
            .fetch_all(&mut *transaction)
            .await?;
    let table_folders: Vec<String> =
        sqlx::query_scalar("DELETE FROM table_folders WHERE connection_id = ? RETURNING id")
            .bind(&owner)
            .fetch_all(&mut *transaction)
            .await?;
    let items: Vec<(String, String, String)> = sqlx::query_as(
        "DELETE FROM table_folder_items WHERE connection_id = ? RETURNING database, schema, name",
    )
    .bind(&owner)
    .fetch_all(&mut *transaction)
    .await?;
    transaction.commit().await?;
    let table = |(database, schema, name): (String, String, String)| {
        RecordRef::Table(TableRef {
            connection_id: connection,
            database,
            schema,
            name,
        })
    };
    let changed = [
        queries([], removed.iter().copied()),
        folders([], folder_ids),
        JournalEntry::new(RecordKind::FavouriteTable).deleted(tables.into_iter().map(table)),
        JournalEntry::new(RecordKind::FavouriteDatabase).deleted(databases.into_iter().map(|database| {
            RecordRef::Database {
                connection_id: connection,
                database,
            }
        })),
        JournalEntry::new(RecordKind::TableFolder).deleted(
            table_folders
                .iter()
                .filter_map(|id| Uuid::parse_str(id).ok())
                .map(RecordRef::Id),
        ),
        JournalEntry::new(RecordKind::TableFolderItem).deleted(items.into_iter().map(table)),
    ]
    .into_iter()
    .filter(|entry| !entry.is_empty())
    .collect();
    Ok((removed.len(), changed))
}

fn folder_deletes(ids: &[i64]) -> Vec<CopyDelete> {
    ids.chunks(500)
        .map(|chunk| CopyDelete {
            table: "saved_query_folders",
            sql: format!(
                "DELETE FROM main.saved_query_folders WHERE id IN ({})",
                vec!["?"; chunk.len()].join(",")
            ),
            binds: chunk.iter().map(|id| Bind::Integer(*id)).collect(),
        })
        .collect()
}

async fn delete_folder_rows(database: &mut SqliteConnection, ids: &HashSet<i64>) -> Result<(), StorageError> {
    // Deleting leaves first avoids SQLite's cascade depth limit without moving names into occupied sibling lists.
    let rows: Vec<(i64, Option<i64>)> = sqlx::query_as("SELECT id, parent_id FROM saved_query_folders")
        .fetch_all(&mut *database)
        .await?;
    let parents: HashMap<i64, Option<i64>> = rows.into_iter().filter(|(id, _)| ids.contains(id)).collect();
    let mut children: HashMap<i64, usize> = parents.keys().map(|id| (*id, 0)).collect();
    for parent in parents.values().flatten() {
        if let Some(count) = children.get_mut(parent) {
            *count += 1;
        }
    }
    let mut leaves: Vec<i64> = children
        .iter()
        .filter_map(|(id, count)| (*count == 0).then_some(*id))
        .collect();
    let mut removed = 0;
    while let Some(id) = leaves.pop() {
        sqlx::query("DELETE FROM saved_query_folders WHERE id = ?")
            .bind(id)
            .execute(&mut *database)
            .await?;
        removed += 1;
        if let Some(Some(parent)) = parents.get(&id)
            && let Some(count) = children.get_mut(parent)
        {
            *count -= 1;
            if *count == 0 {
                leaves.push(*parent);
            }
        }
    }
    if removed != parents.len() {
        return Err(StorageError::Schema("saved query folder cycle".to_owned()));
    }
    Ok(())
}
