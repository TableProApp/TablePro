// Table folders and the tables filed in them (`SyncRecordMapper`, Table Folder), in the history database. A folder is
// named by its id, an item by the digest of the table it files (0052, Derived ids). A folder or item of a connection
// that does not sync stays on the device.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::record_id::{parse_uuid, table_folder_item, uuid_id};
use tablepro_storage::table_folders::{TableFolderContents, TableFolderWrite};
use tablepro_storage::{
    ConnectionStore, QueryHistory, StorageError, TableFolder, TableFolderItem, TableFolders, TableRef, TableScope,
};
use uuid::Uuid;

use super::HISTORY_STORE;
use super::values::{Object, integer, text, uuid_at, uuid_value};
use crate::adapters::blocking;
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

pub struct TableFolderAdapter {
    history: QueryHistory,
    folders: TableFolders,
    connections: ConnectionStore,
    kind: Kind,
}

impl TableFolderAdapter {
    // `connections` says which connections sync, so a folder of one kept off sync stays here.
    pub fn all(history: &QueryHistory, connections: &ConnectionStore) -> Vec<Arc<dyn RecordAdapter>> {
        [Kind::TableFolder, Kind::TableFolderItem]
            .into_iter()
            .map(|kind| {
                Arc::new(Self {
                    history: history.clone(),
                    folders: history.table_folders(),
                    connections: connections.clone(),
                    kind,
                }) as Arc<dyn RecordAdapter>
            })
            .collect()
    }
}

fn store_error(error: StorageError) -> AdapterError {
    AdapterError::Store {
        store: HISTORY_STORE.to_owned(),
        detail: error.to_string(),
    }
}

pub(super) fn item_id(table: &TableRef) -> String {
    table_folder_item(table.connection_id, &table.database, Some(&table.schema), &table.name)
}

// The Mac's `DatabaseScope` holds no empty schema, so a folder without one names none.
fn non_empty(schema: &str) -> Option<&str> {
    (!schema.is_empty()).then_some(schema)
}

pub(super) fn folder_to_wire(folder: &TableFolder) -> Value {
    Object::default()
        .put("connection_id", uuid_value(folder.scope.connection_id))
        .put("database", folder.scope.database.as_str())
        .put_some("schema", non_empty(&folder.scope.schema))
        .put("name", folder.name.as_str())
        .put("created_at", folder.created_at_ms)
        .put("updated_at", folder.updated_at_ms)
        .done()
}

pub(super) fn item_to_wire(item: &TableFolderItem) -> Value {
    Object::default()
        .put("connection_id", uuid_value(item.table.connection_id))
        .put("database", item.table.database.as_str())
        .put_some("schema", non_empty(&item.table.schema))
        .put("name", item.table.name.as_str())
        .put("folder_id", uuid_value(item.folder_id))
        .done()
}

// None for a copy the Mac would not read: one with no connection, name or folder. One with no creation date was made
// now, as the Mac reads it.
pub(super) fn folder_from_wire(id: Uuid, fields: &Value) -> Option<TableFolder> {
    let created_at_ms = integer(fields, "created_at").unwrap_or_else(now_ms);
    Some(TableFolder {
        id,
        scope: TableScope {
            connection_id: uuid_at(fields, "connection_id")?,
            database: text(fields, "database").unwrap_or_default().to_owned(),
            schema: text(fields, "schema").unwrap_or_default().to_owned(),
        },
        name: text(fields, "name")?.to_owned(),
        created_at_ms,
        updated_at_ms: integer(fields, "updated_at").unwrap_or(created_at_ms),
    })
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| i64::try_from(since.as_millis()).unwrap_or(i64::MAX))
}

pub(super) fn item_from_wire(fields: &Value) -> Option<TableFolderItem> {
    Some(TableFolderItem {
        table: TableRef {
            connection_id: uuid_at(fields, "connection_id")?,
            database: text(fields, "database").unwrap_or_default().to_owned(),
            schema: text(fields, "schema").unwrap_or_default().to_owned(),
            name: text(fields, "name").filter(|name| !name.is_empty())?.to_owned(),
        },
        folder_id: uuid_at(fields, "folder_id")?,
    })
}

impl TableFolderAdapter {
    fn read(&self, contents: &TableFolderContents, standing: &HashMap<Uuid, Standing>) -> LocalRecords {
        let standing = |connection: Uuid| standing.get(&connection).copied().unwrap_or(Standing::Unknown);
        let records = match self.kind {
            Kind::TableFolder => contents
                .folders
                .iter()
                .map(|folder| LocalRecord {
                    record_id: uuid_id(folder.id),
                    fields: folder_to_wire(folder),
                    standing: standing(folder.scope.connection_id),
                })
                .collect(),
            _ => contents
                .items
                .iter()
                .map(|item| LocalRecord {
                    record_id: item_id(&item.table),
                    fields: item_to_wire(item),
                    standing: standing(item.table.connection_id),
                })
                .collect(),
        };
        LocalRecords {
            records,
            unreadable: Vec::new(),
            tombstones: Vec::new(),
        }
    }

    // A copy the store cannot hold is left out with a note; the base keeps it, and the diff, finding no store copy,
    // would delete it, so such a copy never reaches here from a pull this build can read.
    fn write(&self, contents: &TableFolderContents, changes: Vec<LocalChange>) -> TableFolderWrite {
        let mut write = TableFolderWrite::default();
        for change in changes {
            match (self.kind, change) {
                (Kind::TableFolder, LocalChange::Put { record_id, fields }) => {
                    match parse_uuid(&record_id).and_then(|id| folder_from_wire(id, &fields)) {
                        Some(folder) => write.folders.push(folder),
                        None => tracing::warn!("a table folder this build cannot hold was left out"),
                    }
                }
                (Kind::TableFolder, LocalChange::Delete { record_id }) => {
                    write.removed_folders.extend(parse_uuid(&record_id));
                }
                (_, LocalChange::Put { fields, .. }) => match item_from_wire(&fields) {
                    Some(item) => write.items.push(item),
                    None => tracing::warn!("a filed table this build cannot hold was left out"),
                },
                (_, LocalChange::Delete { record_id }) => write.removed_items.extend(
                    contents
                        .items
                        .iter()
                        .filter(|item| item_id(&item.table) == record_id)
                        .map(|item| item.table.clone()),
                ),
            }
        }
        write
    }
}

#[async_trait]
impl RecordAdapter for TableFolderAdapter {
    fn kind(&self) -> Kind {
        self.kind
    }

    fn store(&self) -> &str {
        HISTORY_STORE
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        let identity = self.history.identity().await.map_err(store_error)?;
        Ok(StoreStamp {
            generation: identity.generation,
            sequence: identity.sequence,
        })
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope != ScopeName::Personal {
            return Ok(LocalRecords::default());
        }
        let contents = self.folders.contents().await.map_err(store_error)?;
        let connections = self.connections.clone();
        let list = blocking(move || connections.list_blocking())
            .await?
            .map_err(|error| AdapterError::Store {
                store: super::STORE.to_owned(),
                detail: error.to_string(),
            })?;
        let standing = list
            .connections
            .iter()
            .map(|saved| (saved.id, super::connection_standing(saved)))
            .collect();
        Ok(self.read(&contents, &standing))
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope == ScopeName::Personal && !changes.is_empty() {
            let contents = self.folders.contents().await.map_err(store_error)?;
            let write = self.write(&contents, changes);
            self.folders.write(&write).await.map_err(store_error)?;
        }
        self.identity().await
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}
