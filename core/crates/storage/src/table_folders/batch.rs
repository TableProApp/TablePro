// Writes a host makes whole: every folder and item it holds, or the ones one of its edits wrote and removed. The
// Mac's store writes through these while it moves into the core (core ADR 0010, slice 9).

use std::collections::HashSet;

use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection};
use uuid::Uuid;

use crate::StorageError;
use crate::journal::{JournalEntry, RecordKind, RecordRef};
use crate::query_history::{Bind, CopyDelete, trim_upgrade_copies};

use super::{TableFolder, TableFolderItem, TableFolders, TableRef, checked_name, folder_from_row, uuid_column};

// Every folder and item of every connection, with a digest a later write can name to say what it was based on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableFolderContents {
    pub folders: Vec<TableFolder>,
    pub items: Vec<TableFolderItem>,
    pub digest: String,
}

// Folders and items written over any this store holds under their keys, and ones removed. Removing a folder
// changes no item: the write names the items it takes out.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TableFolderWrite {
    pub folders: Vec<TableFolder>,
    pub items: Vec<TableFolderItem>,
    pub removed_folders: Vec<Uuid>,
    pub removed_items: Vec<TableRef>,
}

impl TableFolders {
    pub async fn contents(&self) -> Result<TableFolderContents, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin().await?;
        let contents = read_contents(&mut transaction).await?;
        transaction.commit().await?;
        Ok(contents)
    }

    // Returns the digest after the write.
    pub async fn write(&self, write: &TableFolderWrite) -> Result<String, StorageError> {
        self.commit(None, write).await
    }

    // The store comes to hold exactly these. Refused with `ImportOutdated`, writing nothing, when `expected` is not
    // the digest of what the store holds.
    pub async fn replace(
        &self,
        expected: Option<&str>,
        folders: &[TableFolder],
        items: &[TableFolderItem],
    ) -> Result<String, StorageError> {
        let write = TableFolderWrite {
            folders: folders.to_vec(),
            items: items.to_vec(),
            removed_folders: Vec::new(),
            removed_items: Vec::new(),
        };
        self.commit(Some(expected), &write).await
    }

    async fn commit(&self, replace: Option<Option<&str>>, write: &TableFolderWrite) -> Result<String, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (removed_folders, removed_items) = match replace {
            Some(expected) => {
                let held = read_contents(&mut transaction).await?;
                if expected.is_some_and(|expected| expected != held.digest) {
                    return Err(StorageError::ImportOutdated);
                }
                let kept_folders: HashSet<Uuid> = write.folders.iter().map(|folder| folder.id).collect();
                let kept_items: HashSet<&TableRef> = write.items.iter().map(|item| &item.table).collect();
                let folders: Vec<Uuid> = held
                    .folders
                    .iter()
                    .map(|folder| folder.id)
                    .filter(|id| !kept_folders.contains(id))
                    .collect();
                let items: Vec<TableRef> = held
                    .items
                    .into_iter()
                    .map(|item| item.table)
                    .filter(|table| !kept_items.contains(table))
                    .collect();
                (folders, items)
            }
            None => (write.removed_folders.clone(), write.removed_items.clone()),
        };
        // After the digest check, so a store that moved is refused as outdated whatever the write holds.
        for folder in &write.folders {
            checked_name(&folder.name)?;
        }
        trim_upgrade_copies(&self.path, &copy_deletes(&removed_folders, &removed_items)).await?;
        let (gone_folders, gone_items) = remove(&mut transaction, &removed_folders, &removed_items).await?;
        let (wrote_folders, wrote_items) = put(&mut transaction, write).await?;
        let digest = read_contents(&mut transaction).await?.digest;
        transaction.commit().await?;
        self.tell(
            JournalEntry::new(RecordKind::TableFolder)
                .wrote(wrote_folders)
                .deleted(gone_folders),
            Some(
                JournalEntry::new(RecordKind::TableFolderItem)
                    .wrote(wrote_items)
                    .deleted(gone_items),
            ),
        );
        Ok(digest)
    }
}

type Changed = (Vec<RecordRef>, Vec<RecordRef>);

async fn remove(
    database: &mut SqliteConnection,
    folders: &[Uuid],
    items: &[TableRef],
) -> Result<Changed, StorageError> {
    let mut gone_folders = Vec::new();
    for id in folders {
        let removed = sqlx::query("DELETE FROM table_folders WHERE id = ?")
            .bind(id.to_string())
            .execute(&mut *database)
            .await?
            .rows_affected();
        if removed > 0 {
            gone_folders.push(RecordRef::Id(*id));
        }
    }
    let mut gone_items = Vec::new();
    for table in items {
        let removed = sqlx::query(
            "DELETE FROM table_folder_items WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?",
        )
        .bind(table.connection_id.to_string())
        .bind(&table.database)
        .bind(&table.schema)
        .bind(&table.name)
        .execute(&mut *database)
        .await?
        .rows_affected();
        if removed > 0 {
            gone_items.push(RecordRef::Table(table.clone()));
        }
    }
    Ok((gone_folders, gone_items))
}

async fn put(database: &mut SqliteConnection, write: &TableFolderWrite) -> Result<Changed, StorageError> {
    let mut wrote_folders = Vec::new();
    for folder in &write.folders {
        let changed = sqlx::query(
            "INSERT INTO table_folders (id, connection_id, database, schema, name, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET connection_id = excluded.connection_id, \
             database = excluded.database, schema = excluded.schema, name = excluded.name, \
             created_at = excluded.created_at, updated_at = excluded.updated_at \
             WHERE (connection_id, database, schema, name, created_at, updated_at) IS NOT \
             (excluded.connection_id, excluded.database, excluded.schema, excluded.name, excluded.created_at, \
             excluded.updated_at)",
        )
        .bind(folder.id.to_string())
        .bind(folder.scope.connection_id.to_string())
        .bind(&folder.scope.database)
        .bind(&folder.scope.schema)
        .bind(&folder.name)
        .bind(folder.created_at_ms)
        .bind(folder.updated_at_ms)
        .execute(&mut *database)
        .await?
        .rows_affected();
        if changed > 0 {
            wrote_folders.push(RecordRef::Id(folder.id));
        }
    }
    let mut wrote_items = Vec::new();
    for item in &write.items {
        let changed = sqlx::query(
            "INSERT INTO table_folder_items (connection_id, database, schema, name, folder_id) \
             VALUES (?, ?, ?, ?, ?) ON CONFLICT (connection_id, database, schema, name) \
             DO UPDATE SET folder_id = excluded.folder_id WHERE folder_id IS NOT excluded.folder_id",
        )
        .bind(item.table.connection_id.to_string())
        .bind(&item.table.database)
        .bind(&item.table.schema)
        .bind(&item.table.name)
        .bind(item.folder_id.to_string())
        .execute(&mut *database)
        .await?
        .rows_affected();
        if changed > 0 {
            wrote_items.push(RecordRef::Table(item.table.clone()));
        }
    }
    Ok((wrote_folders, wrote_items))
}

fn copy_deletes(folders: &[Uuid], items: &[TableRef]) -> Vec<CopyDelete> {
    let folders = folders.iter().map(|id| CopyDelete {
        table: "table_folders",
        sql: "DELETE FROM main.table_folders WHERE id = ?".to_owned(),
        binds: vec![Bind::Text(id.to_string())],
    });
    let items = items.iter().map(|table| CopyDelete {
        table: "table_folder_items",
        sql: "DELETE FROM main.table_folder_items WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?"
            .to_owned(),
        binds: vec![
            Bind::Text(table.connection_id.to_string()),
            Bind::Text(table.database.clone()),
            Bind::Text(table.schema.clone()),
            Bind::Text(table.name.clone()),
        ],
    });
    folders.chain(items).collect()
}

async fn read_contents(database: &mut SqliteConnection) -> Result<TableFolderContents, StorageError> {
    let folders = sqlx::query(
        "SELECT id, connection_id, database, schema, name, created_at, updated_at FROM table_folders ORDER BY id",
    )
    .fetch_all(&mut *database)
    .await?
    .into_iter()
    .map(folder_from_row)
    .collect::<Result<Vec<_>, _>>()?;
    let items = sqlx::query(
        "SELECT connection_id, database, schema, name, folder_id FROM table_folder_items \
         ORDER BY connection_id, database, schema, name",
    )
    .fetch_all(&mut *database)
    .await?
    .into_iter()
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
    .collect::<Result<Vec<_>, StorageError>>()?;
    let digest = digest(&folders, &items)?;
    Ok(TableFolderContents { folders, items, digest })
}

fn digest(folders: &[TableFolder], items: &[TableFolderItem]) -> Result<String, StorageError> {
    let folders: Vec<_> = folders
        .iter()
        .map(|folder| {
            (
                folder.id,
                folder.scope.connection_id,
                &folder.scope.database,
                &folder.scope.schema,
                &folder.name,
                folder.created_at_ms,
                folder.updated_at_ms,
            )
        })
        .collect();
    let items: Vec<_> = items
        .iter()
        .map(|item| {
            (
                item.table.connection_id,
                &item.table.database,
                &item.table.schema,
                &item.table.name,
                item.folder_id,
            )
        })
        .collect();
    let bytes = serde_json::to_vec(&(folders, items))?;
    Ok(hex::encode(Sha256::digest(&bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{QueryHistory, StoragePaths, TableScope};

    async fn folders(root: &tempfile::TempDir) -> TableFolders {
        QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
            .await
            .expect("open")
            .table_folders()
    }

    fn folder(connection_id: Uuid, name: &str) -> TableFolder {
        TableFolder {
            id: Uuid::new_v4(),
            scope: TableScope {
                connection_id,
                database: "shop".to_owned(),
                schema: String::new(),
            },
            name: name.to_owned(),
            created_at_ms: 1_700_000_000_123,
            updated_at_ms: 1_700_000_000_456,
        }
    }

    fn filed(folder: &TableFolder, name: &str) -> TableFolderItem {
        TableFolderItem {
            table: TableRef {
                connection_id: folder.scope.connection_id,
                database: folder.scope.database.clone(),
                schema: folder.scope.schema.clone(),
                name: name.to_owned(),
            },
            folder_id: folder.id,
        }
    }

    #[tokio::test]
    async fn a_write_keeps_ids_and_times_and_removing_a_folder_leaves_its_items_to_the_write() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = folders(&root).await;
        let shelf = folder(Uuid::new_v4(), "Billing");
        let item = filed(&shelf, "invoices");
        store
            .write(&TableFolderWrite {
                folders: vec![shelf.clone()],
                items: vec![item.clone()],
                ..TableFolderWrite::default()
            })
            .await
            .expect("write");
        assert_eq!(store.contents().await.expect("contents").folders, vec![shelf.clone()]);

        let digest = store
            .write(&TableFolderWrite {
                removed_folders: vec![shelf.id],
                ..TableFolderWrite::default()
            })
            .await
            .expect("remove");

        let contents = store.contents().await.expect("contents");
        assert!(contents.folders.is_empty());
        assert_eq!(contents.items, vec![item]);
        assert_eq!(contents.digest, digest);
    }

    #[tokio::test]
    async fn a_replace_on_an_older_read_writes_nothing() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = folders(&root).await;
        let connection = Uuid::new_v4();
        let first = folder(connection, "First");
        let read = store.contents().await.expect("contents");
        store
            .write(&TableFolderWrite {
                folders: vec![first.clone()],
                ..TableFolderWrite::default()
            })
            .await
            .expect("write");

        let refused = store.replace(Some(&read.digest), &[], &[]).await;
        let current = store.contents().await.expect("contents").digest;
        store.replace(Some(&current), &[], &[]).await.expect("replace");

        assert!(matches!(refused, Err(StorageError::ImportOutdated)));
        assert!(store.contents().await.expect("contents").folders.is_empty());
    }
}
