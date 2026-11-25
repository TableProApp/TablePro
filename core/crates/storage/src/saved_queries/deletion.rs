use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection, SqlitePool};
use uuid::Uuid;

use crate::StorageError;
use crate::journal::RecordKind;
use crate::query_history::{Bind, CopyDelete, trim_upgrade_copies};
use crate::unix_time::to_unix_millis;

use super::folders::name_key;
use super::ordering;
use super::put::free_name;

const IDS_PER_STATEMENT: usize = 500;

// A folder and every folder under it, by its parent references, whatever connection each has.
const SUBTREE: &str = "WITH RECURSIVE subtree(record_id) AS ( \
         SELECT record_id FROM saved_query_folders WHERE id = ?1 \
         UNION SELECT folder.record_id FROM saved_query_folders folder \
         JOIN subtree ON folder.parent_record_id = subtree.record_id) ";

// The store's own code does what a cascade did, so the change journal sees every row it changes (core ADR 0052).
pub(super) async fn delete_folder(pool: &SqlitePool, path: &Path, id: Uuid) -> Result<(), StorageError> {
    let mut connection = pool.acquire().await?;
    let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
    let row = sqlx::query("SELECT id, connection_id, parent_record_id FROM saved_query_folders WHERE record_id = ?")
        .bind(id.to_string())
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or(StorageError::NotFound)?;
    let rowid: i64 = row.try_get("id")?;
    let owner: Option<String> = row.try_get("connection_id")?;
    let parent: Option<String> = row.try_get("parent_record_id")?;
    let doomed: Vec<i64> = sqlx::query_scalar(AssertSqlSafe(format!(
        "{SUBTREE} SELECT folder.id FROM saved_query_folders folder JOIN subtree USING (record_id)"
    )))
    .bind(rowid)
    .fetch_all(&mut *transaction)
    .await?;
    trim_upgrade_copies(path, &rowid_deletes("saved_query_folders", &doomed)).await?;
    let filed: Vec<(i64, Option<String>)> = sqlx::query_as(AssertSqlSafe(format!(
        "{SUBTREE} SELECT query.id, query.connection_id FROM saved_queries query \
         JOIN saved_query_folders folder ON folder.record_id = query.folder_record_id \
         JOIN subtree ON subtree.record_id = folder.record_id \
         ORDER BY folder.id, query.sort_order, query.name COLLATE NOCASE, query.id"
    )))
    .bind(rowid)
    .fetch_all(&mut *transaction)
    .await?;
    unfile_queries(&mut transaction, &filed).await?;
    delete_folder_rows(&mut transaction, &doomed).await?;
    ordering::compact_folders(&mut transaction, owner.as_deref(), parent.as_deref()).await?;
    transaction.commit().await?;
    Ok(())
}

// The number of queries deleted, and the kinds of record that changed.
pub(super) async fn delete_connection(
    pool: &SqlitePool,
    path: &Path,
    connection: Uuid,
) -> Result<(usize, Vec<RecordKind>), StorageError> {
    let mut database = pool.acquire().await?;
    let mut transaction = database.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
    let owner = connection.to_string();
    let mut copies: Vec<CopyDelete> = [
        "favourite_tables",
        "favourite_databases",
        "table_folders",
        "table_folder_items",
    ]
    .map(|table| CopyDelete {
        table,
        sql: format!("DELETE FROM main.{table} WHERE connection_id = ?"),
        binds: vec![Bind::Text(owner.clone())],
    })
    .into();
    // A pull can move a query or a folder between connections after a copy was made, so the copy may name it
    // under another; its rowid is the same in both. What the live database no longer holds leaves in the sweep.
    for table in ["saved_queries", "saved_query_folders"] {
        let rows: Vec<i64> = sqlx::query_scalar(AssertSqlSafe(format!("SELECT id FROM {table} WHERE connection_id = ?")))
            .bind(&owner)
            .fetch_all(&mut *transaction)
            .await?;
        copies.extend(rowid_deletes(table, &rows));
    }
    trim_upgrade_copies(path, &copies).await?;
    let queries = sqlx::query("DELETE FROM saved_queries WHERE connection_id = ?")
        .bind(&owner)
        .execute(&mut *transaction)
        .await?
        .rows_affected();
    let folders: Vec<i64> = sqlx::query_scalar("SELECT id FROM saved_query_folders WHERE connection_id = ?")
        .bind(&owner)
        .fetch_all(&mut *transaction)
        .await?;
    let mut changed = Vec::new();
    if queries > 0 {
        changed.push(RecordKind::SavedQuery);
    }
    if !folders.is_empty() {
        changed.push(RecordKind::SavedQueryFolder);
    }
    // What another connection, or none, keeps in a folder going here moves to its own top level.
    let filed: Vec<(i64, Option<String>)> = sqlx::query_as(
        "SELECT query.id, query.connection_id FROM saved_queries query \
         JOIN saved_query_folders folder ON folder.record_id = query.folder_record_id \
         WHERE folder.connection_id = ? ORDER BY folder.id, query.sort_order, query.name COLLATE NOCASE, query.id",
    )
    .bind(&owner)
    .fetch_all(&mut *transaction)
    .await?;
    unfile_queries(&mut transaction, &filed).await?;
    if !filed.is_empty() && queries == 0 {
        changed.push(RecordKind::SavedQuery);
    }
    let nested: Vec<(i64, Option<String>, String)> = sqlx::query_as(
        "SELECT child.id, child.connection_id, child.name FROM saved_query_folders child \
         JOIN saved_query_folders parent ON parent.record_id = child.parent_record_id \
         WHERE parent.connection_id = ? AND child.connection_id IS NOT ? \
         ORDER BY parent.id, child.sort_order, child.name COLLATE NOCASE, child.id",
    )
    .bind(&owner)
    .bind(&owner)
    .fetch_all(&mut *transaction)
    .await?;
    // Each takes the first free name at the top of its own connection, or of none.
    let mut taken: HashMap<Option<String>, HashSet<String>> = HashMap::new();
    for (id, scope, name) in &nested {
        let held = match taken.entry(scope.clone()) {
            Entry::Occupied(held) => held.into_mut(),
            Entry::Vacant(vacant) => {
                let names: Vec<String> = sqlx::query_scalar(
                    "SELECT name FROM saved_query_folders WHERE connection_id IS ? AND parent_record_id IS NULL",
                )
                .bind(scope)
                .fetch_all(&mut *transaction)
                .await?;
                vacant.insert(names.iter().map(|name| name_key(name)).collect())
            }
        };
        let name = match held.contains(&name_key(name)) {
            true => free_name(name, |candidate| held.contains(&name_key(candidate))),
            false => name.clone(),
        };
        held.insert(name_key(&name));
        let order = ordering::next_folder_order(&mut transaction, scope.as_deref(), None).await?;
        sqlx::query(
            "UPDATE saved_query_folders SET parent_record_id = NULL, name = ?, sort_order = ?, updated_at = ? \
             WHERE id = ?",
        )
        .bind(name)
        .bind(order)
        .bind(to_unix_millis(SystemTime::now()))
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    }
    delete_folder_rows(&mut transaction, &folders).await?;
    for (statement, kind) in [
        (
            "DELETE FROM favourite_tables WHERE connection_id = ?",
            RecordKind::FavouriteTable,
        ),
        (
            "DELETE FROM favourite_databases WHERE connection_id = ?",
            RecordKind::FavouriteDatabase,
        ),
        (
            "DELETE FROM table_folders WHERE connection_id = ?",
            RecordKind::TableFolder,
        ),
        (
            "DELETE FROM table_folder_items WHERE connection_id = ?",
            RecordKind::TableFolderItem,
        ),
    ] {
        let removed = sqlx::query(statement)
            .bind(&owner)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
        if removed > 0 {
            changed.push(kind);
        }
    }
    transaction.commit().await?;
    Ok((queries as usize, changed))
}

// Each to the end of the top level of the list it shows in, in the order given.
async fn unfile_queries(database: &mut SqliteConnection, queries: &[(i64, Option<String>)]) -> Result<(), StorageError> {
    let now = to_unix_millis(SystemTime::now());
    for (id, scope) in queries {
        let order = ordering::next_query_order(database, scope.as_deref(), None).await?;
        sqlx::query("UPDATE saved_queries SET folder_record_id = NULL, sort_order = ?, updated_at = ? WHERE id = ?")
            .bind(order)
            .bind(now)
            .bind(id)
            .execute(&mut *database)
            .await?;
    }
    Ok(())
}

fn rowid_deletes(table: &'static str, ids: &[i64]) -> Vec<CopyDelete> {
    ids.chunks(IDS_PER_STATEMENT)
        .map(|chunk| CopyDelete {
            table,
            sql: format!(
                "DELETE FROM main.{table} WHERE id IN ({})",
                vec!["?"; chunk.len()].join(",")
            ),
            binds: chunk.iter().map(|id| Bind::Integer(*id)).collect(),
        })
        .collect()
}

async fn delete_folder_rows(database: &mut SqliteConnection, ids: &[i64]) -> Result<(), StorageError> {
    for chunk in ids.chunks(IDS_PER_STATEMENT) {
        let sql = format!(
            "DELETE FROM saved_query_folders WHERE id IN ({})",
            vec!["?"; chunk.len()].join(",")
        );
        let mut statement = sqlx::query(AssertSqlSafe(sql));
        for id in chunk {
            statement = statement.bind(id);
        }
        statement.execute(&mut *database).await?;
    }
    Ok(())
}
