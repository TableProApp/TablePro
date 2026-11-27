// Whole-store reads and writes for an app that keeps these records itself, or moves them in from a store of its own:
// the Mac and iOS apps, each record under its own id (core ADR 0010, slices 3 and 9). A write names the digest it was
// based on where it replaces a whole store, so a change the app never read is refused rather than lost.

use tablepro_storage::query_history::{NewEntry, Outcome, RunDetails};
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{
    DatabaseEnvironment, FavouriteDatabase, FavouriteDigests, FavouriteTable, FavouriteWrite, SavedQueryFolder,
    SavedQuerySettlement, SavedQueryWrite, TableFolder, TableFolderItem, TableFolderWrite, TableRef,
};

use crate::error::CoreError;
use crate::favourites::{DatabaseEnvironmentTag, FavouriteStore};
use crate::history::{HistoryEntryInfo, HistoryOutcomeTag, HistoryRunDetails, QueryHistoryStore, from_millis, millis};
use crate::library::{parse_id, parse_ids};
use crate::runtime::on_runtime;
use crate::saved_queries::SavedQueryStore;
use crate::table_folders::{TableFolderRecord, TableFolderStore, TableRefRecord};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryRecord {
    pub id: String,
    pub name: String,
    pub sql: String,
    pub keyword: Option<String>,
    // None for a query in every connection.
    pub connection_id: Option<String>,
    pub connection_name: String,
    pub folder_id: Option<String>,
    pub order: i64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryFolderRecord {
    pub id: String,
    pub name: String,
    pub connection_id: Option<String>,
    pub parent_id: Option<String>,
    pub order: i64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryStoreContents {
    pub queries: Vec<SavedQueryRecord>,
    pub folders: Vec<SavedQueryFolderRecord>,
    pub digest: String,
}

// Removing a folder changes no other record; the write carries the queries and folders it moved.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryRecordWrite {
    pub queries: Vec<SavedQueryRecord>,
    pub folders: Vec<SavedQueryFolderRecord>,
    pub removed_queries: Vec<String>,
    pub removed_folders: Vec<String>,
}

// The ids whose name or keyword the store changed to settle a collision (core ADR 0052): edits of this device's own.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryWriteOutcome {
    pub settled_queries: Vec<String>,
    pub settled_folders: Vec<String>,
    pub digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteTableRecord {
    pub connection_id: String,
    pub database: Option<String>,
    pub schema: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteDatabaseRecord {
    pub connection_id: String,
    pub database: String,
    pub environment: DatabaseEnvironmentTag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteDatabaseKey {
    pub connection_id: String,
    pub database: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteStoreContents {
    pub tables: Vec<FavouriteTableRecord>,
    pub databases: Vec<FavouriteDatabaseRecord>,
    pub digests: FavouriteDigestsRecord,
}

// One per kind, since a host may keep the tables and the databases in two stores.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteDigestsRecord {
    pub tables: String,
    pub databases: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteRecordWrite {
    pub tables: Vec<FavouriteTableRecord>,
    pub databases: Vec<FavouriteDatabaseRecord>,
    pub removed_tables: Vec<FavouriteTableRecord>,
    pub removed_databases: Vec<FavouriteDatabaseKey>,
}

// A table of any connection. An empty database or schema for an engine that has none.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableKeyRecord {
    pub connection_id: String,
    pub table: TableRefRecord,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TablePlacementRecord {
    pub connection_id: String,
    pub table: TableRefRecord,
    pub folder_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableFolderStoreContents {
    pub folders: Vec<TableFolderRecord>,
    pub items: Vec<TablePlacementRecord>,
    pub digest: String,
}

// Removing a folder changes no item; the write names the items it takes out.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableFolderRecordWrite {
    pub folders: Vec<TableFolderRecord>,
    pub items: Vec<TablePlacementRecord>,
    pub removed_folders: Vec<String>,
    pub removed_items: Vec<TableKeyRecord>,
}

// A run another store kept, under its own record id. Times are milliseconds from the Unix epoch; the store keeps
// whole seconds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryEntryRecord {
    pub record_id: String,
    pub sql: String,
    pub driver_id: String,
    pub connection_id: String,
    pub connection_name: String,
    pub executed_at_ms: i64,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: HistoryOutcomeTag,
    pub details: HistoryRunDetails,
}

// Details the app learned for a run it already mirrored, under the run's record id.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryDetailsRecord {
    pub record_id: String,
    pub details: HistoryRunDetails,
}

#[uniffi::export]
impl SavedQueryStore {
    // Every connection's queries and folders, in record id order.
    pub async fn contents(&self) -> Result<SavedQueryStoreContents, CoreError> {
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            let contents = queries.contents().await?;
            Ok(SavedQueryStoreContents {
                queries: contents.queries.into_iter().map(SavedQueryRecord::from).collect(),
                folders: contents.folders.into_iter().map(SavedQueryFolderRecord::from).collect(),
                digest: contents.digest,
            })
        })
        .await
    }

    // In one commit; each record keeps its id, times and place as given.
    pub async fn write_records(&self, write: SavedQueryRecordWrite) -> Result<SavedQueryWriteOutcome, CoreError> {
        let write = SavedQueryWrite {
            queries: write
                .queries
                .into_iter()
                .map(SavedQuery::try_from)
                .collect::<Result<_, _>>()?,
            folders: write
                .folders
                .into_iter()
                .map(SavedQueryFolder::try_from)
                .collect::<Result<_, _>>()?,
            removed_queries: parse_ids(&write.removed_queries)?,
            removed_folders: parse_ids(&write.removed_folders)?,
        };
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.write(&write).await?.into()) }).await
    }

    // The store comes to hold exactly these. Refused with storage.import_outdated, writing nothing, when
    // `expected_digest` is not the digest of what the store holds; None replaces whatever it holds.
    pub async fn replace_records(
        &self,
        expected_digest: Option<String>,
        queries: Vec<SavedQueryRecord>,
        folders: Vec<SavedQueryFolderRecord>,
    ) -> Result<SavedQueryWriteOutcome, CoreError> {
        let queries: Vec<SavedQuery> = queries
            .into_iter()
            .map(SavedQuery::try_from)
            .collect::<Result<_, _>>()?;
        let folders: Vec<SavedQueryFolder> = folders
            .into_iter()
            .map(SavedQueryFolder::try_from)
            .collect::<Result<_, _>>()?;
        let store = self.queries.clone();
        on_runtime(&self.tasks, async move {
            Ok(store
                .replace(expected_digest.as_deref(), &queries, &folders)
                .await?
                .into())
        })
        .await
    }
}

#[uniffi::export]
impl FavouriteStore {
    pub async fn contents(&self) -> Result<FavouriteStoreContents, CoreError> {
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            let contents = favourites.contents().await?;
            Ok(FavouriteStoreContents {
                tables: contents.tables.into_iter().map(FavouriteTableRecord::from).collect(),
                databases: contents
                    .databases
                    .into_iter()
                    .map(FavouriteDatabaseRecord::from)
                    .collect(),
                digests: contents.digests.into(),
            })
        })
        .await
    }

    // In one commit. Returns the digests after it.
    pub async fn write_records(&self, write: FavouriteRecordWrite) -> Result<FavouriteDigestsRecord, CoreError> {
        let write = FavouriteWrite {
            tables: tables(write.tables)?,
            databases: databases(write.databases)?,
            removed_tables: tables(write.removed_tables)?,
            removed_databases: write
                .removed_databases
                .into_iter()
                .map(|key| Ok((parse_id(&key.connection_id)?, key.database)))
                .collect::<Result<_, CoreError>>()?,
        };
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move { Ok(favourites.write(&write).await?.into()) }).await
    }

    // The store comes to hold exactly these tables; its databases stay. As `SavedQueryStore::replace_records`, against
    // the tables' digest.
    pub async fn replace_tables(
        &self,
        expected_digest: Option<String>,
        held: Vec<FavouriteTableRecord>,
    ) -> Result<FavouriteDigestsRecord, CoreError> {
        let held = tables(held)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            Ok(favourites
                .replace_tables(expected_digest.as_deref(), &held)
                .await?
                .into())
        })
        .await
    }

    // As `replace_tables`, for the databases.
    pub async fn replace_databases(
        &self,
        expected_digest: Option<String>,
        held: Vec<FavouriteDatabaseRecord>,
    ) -> Result<FavouriteDigestsRecord, CoreError> {
        let held = databases(held)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            Ok(favourites
                .replace_databases(expected_digest.as_deref(), &held)
                .await?
                .into())
        })
        .await
    }
}

#[uniffi::export]
impl TableFolderStore {
    pub async fn contents(&self) -> Result<TableFolderStoreContents, CoreError> {
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            let contents = folders.contents().await?;
            Ok(TableFolderStoreContents {
                folders: contents.folders.iter().map(TableFolderRecord::from).collect(),
                items: contents.items.into_iter().map(TablePlacementRecord::from).collect(),
                digest: contents.digest,
            })
        })
        .await
    }

    // In one commit. Returns the digest after it.
    pub async fn write_records(&self, write: TableFolderRecordWrite) -> Result<String, CoreError> {
        let write = TableFolderWrite {
            folders: table_folders(write.folders)?,
            items: placements(write.items)?,
            removed_folders: parse_ids(&write.removed_folders)?,
            removed_items: write
                .removed_items
                .into_iter()
                .map(|key| table_ref(&key.connection_id, key.table))
                .collect::<Result<_, _>>()?,
        };
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.write(&write).await?) }).await
    }

    // As `SavedQueryStore::replace_records`.
    pub async fn replace_records(
        &self,
        expected_digest: Option<String>,
        folders_held: Vec<TableFolderRecord>,
        items_held: Vec<TablePlacementRecord>,
    ) -> Result<String, CoreError> {
        let held_folders = table_folders(folders_held)?;
        let held_items = placements(items_held)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            Ok(folders
                .replace(expected_digest.as_deref(), &held_folders, &held_items)
                .await?)
        })
        .await
    }
}

#[uniffi::export]
impl QueryHistoryStore {
    // Runs the app recorded itself, with their outcome and error text, or moved in from its own store, in one commit.
    // An entry the store already holds keeps its row. The engines' rules for statements that carry a secret live in
    // their drivers, which an Apple build does not link, so the app passes only runs it keeps. Returns how many were
    // new.
    pub async fn put_entries(&self, entries: Vec<HistoryEntryRecord>) -> Result<u64, CoreError> {
        let entries: Vec<NewEntry> = entries.into_iter().map(NewEntry::try_from).collect::<Result<_, _>>()?;
        let history = self.history.clone();
        on_runtime(&self.tasks, async move { Ok(history.put(&entries).await?) }).await
    }

    // In one commit, for runs mirrored before the app kept details: each field a run has none of takes the value given,
    // and none it has changes. A run the store does not hold, a deleted one among them, is passed over. Returns how
    // many runs changed.
    pub async fn fill_details(&self, entries: Vec<HistoryDetailsRecord>) -> Result<u64, CoreError> {
        let details: Vec<(Uuid, RunDetails)> = entries
            .into_iter()
            .map(|entry| Ok((parse_id(&entry.record_id)?, entry.details.into())))
            .collect::<Result<_, CoreError>>()?;
        let history = self.history.clone();
        on_runtime(&self.tasks, async move { Ok(history.fill_details(&details).await?) }).await
    }

    // Runs by record id, oldest row first. An id the store does not hold, a deleted one among them, is left out.
    pub async fn entries(&self, record_ids: Vec<String>) -> Result<Vec<HistoryEntryInfo>, CoreError> {
        let ids = parse_ids(&record_ids)?;
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            Ok(history
                .entries_by_record_id(&ids)
                .await?
                .into_iter()
                .map(HistoryEntryInfo::from)
                .collect())
        })
        .await
    }

    // Every entry's record id, oldest row first.
    pub async fn record_ids(&self) -> Result<Vec<String>, CoreError> {
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            Ok(history
                .record_ids()
                .await?
                .into_iter()
                .map(|id| id.to_string())
                .collect())
        })
        .await
    }

    // Every run of the connection, pinned ones included, for a connection deleted with its history.
    pub async fn delete_for_connection(&self, connection_id: String) -> Result<u64, CoreError> {
        let connection = parse_id(&connection_id)?;
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            Ok(history.delete_for_connection(connection).await?)
        })
        .await
    }

    // The person's own deletion, by record id: each entry leaves a tombstone until sync has pushed it, so the
    // deletion reaches the other devices. Returns how many were there.
    pub async fn delete_entries(&self, record_ids: Vec<String>) -> Result<u64, CoreError> {
        let ids = parse_ids(&record_ids)?;
        let history = self.history.clone();
        on_runtime(&self.tasks, async move { Ok(history.delete_records(&ids).await?) }).await
    }

    // By record id, with no tombstone, so nothing reaches another device: for entries the app's own store let go
    // without the person asking, as its retention does. Returns how many were there.
    pub async fn remove_entries(&self, record_ids: Vec<String>) -> Result<u64, CoreError> {
        let ids = parse_ids(&record_ids)?;
        let history = self.history.clone();
        on_runtime(&self.tasks, async move { Ok(history.remove(&ids).await?) }).await
    }
}

impl From<SavedQuery> for SavedQueryRecord {
    fn from(query: SavedQuery) -> Self {
        Self {
            id: query.id.to_string(),
            name: query.name,
            sql: query.query,
            keyword: query.keyword,
            connection_id: query.connection_id.map(|id| id.to_string()),
            connection_name: query.connection_name,
            folder_id: query.folder_id.map(|id| id.to_string()),
            order: query.order,
            created_at_ms: millis(query.created_at),
            updated_at_ms: millis(query.updated_at),
        }
    }
}

impl TryFrom<SavedQueryRecord> for SavedQuery {
    type Error = CoreError;

    fn try_from(record: SavedQueryRecord) -> Result<Self, CoreError> {
        Ok(Self {
            id: parse_id(&record.id)?,
            name: record.name,
            query: record.sql,
            keyword: record.keyword,
            connection_id: record.connection_id.as_deref().map(parse_id).transpose()?,
            connection_name: record.connection_name,
            folder_id: record.folder_id.as_deref().map(parse_id).transpose()?,
            order: record.order,
            created_at: from_millis(record.created_at_ms),
            updated_at: from_millis(record.updated_at_ms),
        })
    }
}

impl From<SavedQueryFolder> for SavedQueryFolderRecord {
    fn from(folder: SavedQueryFolder) -> Self {
        Self {
            id: folder.id.to_string(),
            name: folder.name,
            connection_id: folder.connection_id.map(|id| id.to_string()),
            parent_id: folder.parent_id.map(|id| id.to_string()),
            order: folder.order,
            created_at_ms: millis(folder.created_at),
            updated_at_ms: millis(folder.updated_at),
        }
    }
}

impl TryFrom<SavedQueryFolderRecord> for SavedQueryFolder {
    type Error = CoreError;

    fn try_from(record: SavedQueryFolderRecord) -> Result<Self, CoreError> {
        Ok(Self {
            id: parse_id(&record.id)?,
            connection_id: record.connection_id.as_deref().map(parse_id).transpose()?,
            name: record.name,
            parent_id: record.parent_id.as_deref().map(parse_id).transpose()?,
            order: record.order,
            created_at: from_millis(record.created_at_ms),
            updated_at: from_millis(record.updated_at_ms),
        })
    }
}

impl From<SavedQuerySettlement> for SavedQueryWriteOutcome {
    fn from(settlement: SavedQuerySettlement) -> Self {
        Self {
            settled_queries: settlement.queries.iter().map(ToString::to_string).collect(),
            settled_folders: settlement.folders.iter().map(ToString::to_string).collect(),
            digest: settlement.digest,
        }
    }
}

impl From<FavouriteDigests> for FavouriteDigestsRecord {
    fn from(digests: FavouriteDigests) -> Self {
        Self {
            tables: digests.tables,
            databases: digests.databases,
        }
    }
}

impl From<FavouriteTable> for FavouriteTableRecord {
    fn from(table: FavouriteTable) -> Self {
        Self {
            connection_id: table.connection_id.to_string(),
            database: table.database,
            schema: table.schema,
            name: table.name,
        }
    }
}

impl From<FavouriteDatabase> for FavouriteDatabaseRecord {
    fn from(database: FavouriteDatabase) -> Self {
        Self {
            connection_id: database.connection_id.to_string(),
            database: database.database,
            environment: database.environment.into(),
        }
    }
}

fn tables(records: Vec<FavouriteTableRecord>) -> Result<Vec<FavouriteTable>, CoreError> {
    records
        .into_iter()
        .map(|record| {
            Ok(FavouriteTable {
                connection_id: parse_id(&record.connection_id)?,
                database: record.database.filter(|database| !database.is_empty()),
                schema: record.schema.filter(|schema| !schema.is_empty()),
                name: record.name,
            })
        })
        .collect()
}

fn databases(records: Vec<FavouriteDatabaseRecord>) -> Result<Vec<FavouriteDatabase>, CoreError> {
    records
        .into_iter()
        .map(|record| {
            Ok(FavouriteDatabase {
                connection_id: parse_id(&record.connection_id)?,
                database: record.database,
                environment: DatabaseEnvironment::from(record.environment),
            })
        })
        .collect()
}

impl From<TableFolderItem> for TablePlacementRecord {
    fn from(item: TableFolderItem) -> Self {
        Self {
            connection_id: item.table.connection_id.to_string(),
            table: TableRefRecord {
                database: item.table.database,
                schema: item.table.schema,
                name: item.table.name,
            },
            folder_id: item.folder_id.to_string(),
        }
    }
}

fn table_ref(connection_id: &str, table: TableRefRecord) -> Result<TableRef, CoreError> {
    Ok(TableRef {
        connection_id: parse_id(connection_id)?,
        database: table.database,
        schema: table.schema,
        name: table.name,
    })
}

fn table_folders(records: Vec<TableFolderRecord>) -> Result<Vec<TableFolder>, CoreError> {
    records.into_iter().map(TableFolder::try_from).collect()
}

fn placements(records: Vec<TablePlacementRecord>) -> Result<Vec<TableFolderItem>, CoreError> {
    records
        .into_iter()
        .map(|record| {
            Ok(TableFolderItem {
                table: table_ref(&record.connection_id, record.table)?,
                folder_id: parse_id(&record.folder_id)?,
            })
        })
        .collect()
}

impl TryFrom<HistoryEntryRecord> for NewEntry {
    type Error = CoreError;

    fn try_from(record: HistoryEntryRecord) -> Result<Self, CoreError> {
        Ok(Self {
            record_id: parse_id(&record.record_id)?,
            query: record.sql,
            driver_id: record.driver_id,
            connection_id: parse_id(&record.connection_id)?,
            connection_name: record.connection_name,
            executed_at: from_millis(record.executed_at_ms),
            duration_ms: record.duration_ms,
            rows_affected: record.rows_affected,
            outcome: Outcome::from(record.outcome),
            details: record.details.into(),
        })
    }
}
