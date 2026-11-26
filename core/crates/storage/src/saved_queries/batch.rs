// Writes a host makes whole: every record it holds, or the records one of its edits wrote and removed, each under
// its own id. The Mac's store writes through these while it moves into the core (core ADR 0010, slice 3).

use std::collections::HashSet;
use std::time::SystemTime;

use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection};
use uuid::Uuid;

use crate::StorageError;
use crate::journal::JournalEntry;
use crate::query_history::{LiveFiles, trim_saved_copies};
use crate::unix_time::to_unix_millis;

use super::deletion::{delete_folder_rows, rowid_deletes};
use super::folders::{SavedQueryFolder, folders, row_to_folder};
use super::put::{put_folders, put_queries};
use super::{SavedQueries, SavedQuery, queries, row_to_saved_query};

const IDS_PER_STATEMENT: usize = 500;

// Every query and folder, with a digest a later write can name to say what it was based on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQueryContents {
    pub queries: Vec<SavedQuery>,
    pub folders: Vec<SavedQueryFolder>,
    pub digest: String,
}

// Records written over any this store holds under their ids, and records removed by id. A removal changes no
// other row: the folders and queries a removed folder held stay as the write gives them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SavedQueryWrite {
    pub queries: Vec<SavedQuery>,
    pub folders: Vec<SavedQueryFolder>,
    pub removed_queries: Vec<Uuid>,
    pub removed_folders: Vec<Uuid>,
}

// The ids whose name or keyword the store changed to settle a collision (core ADR 0052), and the digest after.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SavedQuerySettlement {
    pub queries: Vec<Uuid>,
    pub folders: Vec<Uuid>,
    pub digest: String,
}

impl SavedQueries {
    pub async fn contents(&self) -> Result<SavedQueryContents, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin().await?;
        let contents = read_contents(&mut transaction).await?;
        transaction.commit().await?;
        Ok(contents)
    }

    pub async fn write(&self, write: &SavedQueryWrite) -> Result<SavedQuerySettlement, StorageError> {
        self.commit(None, write).await
    }

    // The store comes to hold exactly these records. Refused with `ImportOutdated`, writing nothing, when
    // `expected` is not the digest of what the store holds, so a change the caller never read survives.
    pub async fn replace(
        &self,
        expected: Option<&str>,
        queries: &[SavedQuery],
        folders: &[SavedQueryFolder],
    ) -> Result<SavedQuerySettlement, StorageError> {
        let kept_queries: HashSet<Uuid> = queries.iter().map(|query| query.id).collect();
        let kept_folders: HashSet<Uuid> = folders.iter().map(|folder| folder.id).collect();
        let replace = Replace {
            expected,
            kept_queries,
            kept_folders,
        };
        let write = SavedQueryWrite {
            queries: queries.to_vec(),
            folders: folders.to_vec(),
            removed_queries: Vec::new(),
            removed_folders: Vec::new(),
        };
        self.commit(Some(replace), &write).await
    }

    async fn commit(
        &self,
        replace: Option<Replace<'_>>,
        write: &SavedQueryWrite,
    ) -> Result<SavedQuerySettlement, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (removed_queries, removed_folders) = match &replace {
            Some(replace) => {
                let held = read_contents(&mut transaction).await?;
                if replace.expected.is_some_and(|expected| expected != held.digest) {
                    return Err(StorageError::ImportOutdated);
                }
                let gone_queries = held
                    .queries
                    .iter()
                    .map(|query| query.id)
                    .filter(|id| !replace.kept_queries.contains(id))
                    .collect();
                let gone_folders = held
                    .folders
                    .iter()
                    .map(|folder| folder.id)
                    .filter(|id| !replace.kept_folders.contains(id))
                    .collect();
                (gone_queries, gone_folders)
            }
            None => (write.removed_queries.clone(), write.removed_folders.clone()),
        };
        let removed_queries = remove_rows(&mut transaction, &self.files, "saved_queries", &removed_queries).await?;
        let removed_folders =
            remove_rows(&mut transaction, &self.files, "saved_query_folders", &removed_folders).await?;
        let now = SystemTime::now();
        let settled_folders = match write.folders.is_empty() {
            true => Vec::new(),
            false => put_folders(&mut transaction, &write.folders, now).await?,
        };
        let settled_queries = match write.queries.is_empty() {
            true => Vec::new(),
            false => put_queries(&mut transaction, &write.queries, now).await?,
        };
        let digest = read_contents(&mut transaction).await?.digest;
        transaction.commit().await?;
        let entries: Vec<JournalEntry> = [
            queries(
                write
                    .queries
                    .iter()
                    .map(|query| query.id)
                    .chain(settled_queries.iter().copied()),
                removed_queries,
            ),
            folders(
                write
                    .folders
                    .iter()
                    .map(|folder| folder.id)
                    .chain(settled_folders.iter().copied()),
                removed_folders,
            ),
        ]
        .into_iter()
        .filter(|entry| !entry.is_empty())
        .collect();
        if !entries.is_empty() {
            self.signals.changed(&entries);
        }
        Ok(SavedQuerySettlement {
            queries: settled_queries,
            folders: settled_folders,
            digest,
        })
    }
}

struct Replace<'a> {
    expected: Option<&'a str>,
    kept_queries: HashSet<Uuid>,
    kept_folders: HashSet<Uuid>,
}

async fn read_contents(database: &mut SqliteConnection) -> Result<SavedQueryContents, StorageError> {
    let queries = sqlx::query(concat!("SELECT ", columns!(), " FROM saved_queries ORDER BY record_id"))
        .fetch_all(&mut *database)
        .await?
        .iter()
        .map(row_to_saved_query)
        .collect::<Result<Vec<_>, _>>()?;
    let folders = sqlx::query(concat!(
        "SELECT ",
        folder_columns!(),
        " FROM saved_query_folders ORDER BY record_id"
    ))
    .fetch_all(&mut *database)
    .await?
    .iter()
    .map(row_to_folder)
    .collect::<Result<Vec<_>, _>>()?;
    let digest = digest(&queries, &folders)?;
    Ok(SavedQueryContents {
        queries,
        folders,
        digest,
    })
}

// Over every stored value in record id order, so two reads of the same rows give the same digest.
fn digest(queries: &[SavedQuery], folders: &[SavedQueryFolder]) -> Result<String, StorageError> {
    let queries: Vec<_> = queries
        .iter()
        .map(|query| {
            (
                query.id,
                &query.name,
                &query.query,
                query.connection_id,
                &query.connection_name,
                &query.keyword,
                query.folder_id,
                query.order,
                to_unix_millis(query.created_at),
                to_unix_millis(query.updated_at),
            )
        })
        .collect();
    let folders: Vec<_> = folders
        .iter()
        .map(|folder| {
            (
                folder.id,
                &folder.name,
                folder.connection_id,
                folder.parent_id,
                folder.order,
                to_unix_millis(folder.created_at),
                to_unix_millis(folder.updated_at),
            )
        })
        .collect();
    let bytes = serde_json::to_vec(&(queries, folders))?;
    Ok(hex::encode(Sha256::digest(&bytes)))
}

// Removes the rows these ids name, from the upgrade copies too, and returns the ids that were there.
async fn remove_rows(
    database: &mut SqliteConnection,
    files: &LiveFiles,
    table: &'static str,
    ids: &[Uuid],
) -> Result<Vec<Uuid>, StorageError> {
    let mut rowids = Vec::new();
    let mut removed = Vec::new();
    for chunk in ids.chunks(IDS_PER_STATEMENT) {
        let sql = format!(
            "SELECT id, record_id FROM {table} WHERE record_id IN ({})",
            vec!["?"; chunk.len()].join(",")
        );
        let mut statement = sqlx::query(AssertSqlSafe(sql));
        for id in chunk {
            statement = statement.bind(id.to_string());
        }
        for row in statement.fetch_all(&mut *database).await? {
            rowids.push(row.try_get::<i64, _>("id")?);
            removed.push(super::ordering::record_id(&row.try_get::<String, _>("record_id")?)?);
        }
    }
    if rowids.is_empty() {
        return Ok(removed);
    }
    trim_saved_copies(files, &rowid_deletes(table, &rowids)).await?;
    match table {
        "saved_query_folders" => delete_folder_rows(database, &rowids).await?,
        _ => delete_query_rows(database, &rowids).await?,
    }
    Ok(removed)
}

async fn delete_query_rows(database: &mut SqliteConnection, ids: &[i64]) -> Result<(), StorageError> {
    for chunk in ids.chunks(IDS_PER_STATEMENT) {
        let sql = format!(
            "DELETE FROM saved_queries WHERE id IN ({})",
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

#[cfg(test)]
#[path = "batch_tests.rs"]
mod tests;
