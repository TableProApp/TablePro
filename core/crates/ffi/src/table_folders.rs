use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_storage::{TableFolder, TableFolderItem, TableFolders, TableRef, TableScope};

use crate::error::CoreError;
use crate::library::parse_id;
use crate::runtime::on_runtime;

// The folders a person files a connection's tables in, per database and schema, in the query
// history's database. A table sits in at most one folder.
#[derive(uniffi::Object)]
pub struct TableFolderStore {
    folders: TableFolders,
    tasks: Tasks,
}

// An empty database or schema for an engine that has none.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableFolderRecord {
    pub id: String,
    pub connection_id: String,
    pub database: String,
    pub schema: String,
    pub name: String,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableRefRecord {
    pub database: String,
    pub schema: String,
    pub name: String,
}

// An item whose folder this device does not hold yet reads as unfiled.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableFolderItemRecord {
    pub table: TableRefRecord,
    pub folder_id: String,
}

impl TableFolderStore {
    pub(crate) fn new(folders: TableFolders, tasks: Tasks) -> Arc<Self> {
        Arc::new(Self { folders, tasks })
    }
}

#[uniffi::export]
impl TableFolderStore {
    pub async fn folders(&self, connection_id: String) -> Result<Vec<TableFolderRecord>, CoreError> {
        let connection = parse_id(&connection_id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            Ok(folders
                .folders(connection)
                .await?
                .iter()
                .map(TableFolderRecord::from)
                .collect())
        })
        .await
    }

    pub async fn items(&self, connection_id: String) -> Result<Vec<TableFolderItemRecord>, CoreError> {
        let connection = parse_id(&connection_id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            Ok(folders
                .items(connection)
                .await?
                .into_iter()
                .map(TableFolderItemRecord::from)
                .collect())
        })
        .await
    }

    pub async fn create(
        &self,
        connection_id: String,
        database: String,
        schema: String,
        name: String,
    ) -> Result<TableFolderRecord, CoreError> {
        let scope = TableScope {
            connection_id: parse_id(&connection_id)?,
            database,
            schema,
        };
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            Ok(TableFolderRecord::from(&folders.create(scope, &name).await?))
        })
        .await
    }

    // Keeps the folder's own id and times, as a move into the core brings them.
    pub async fn put(&self, folder: TableFolderRecord) -> Result<(), CoreError> {
        let folder = TableFolder::try_from(folder)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.put(&folder).await?) }).await
    }

    pub async fn rename(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.rename(id, &name).await?) }).await
    }

    // Its tables go back to the schema's list. Returns whether the folder was there.
    pub async fn delete(&self, id: String) -> Result<bool, CoreError> {
        let id = parse_id(&id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.delete(id).await?) }).await
    }

    pub async fn file(
        &self,
        connection_id: String,
        tables: Vec<TableRefRecord>,
        folder_id: String,
    ) -> Result<(), CoreError> {
        let tables = stored_tables(&connection_id, tables)?;
        let folder = parse_id(&folder_id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.file(&tables, folder).await?) }).await
    }

    pub async fn unfile(&self, connection_id: String, tables: Vec<TableRefRecord>) -> Result<(), CoreError> {
        let tables = stored_tables(&connection_id, tables)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.unfile(&tables).await?) }).await
    }
}

fn stored_tables(connection_id: &str, tables: Vec<TableRefRecord>) -> Result<Vec<TableRef>, CoreError> {
    let connection = parse_id(connection_id)?;
    Ok(tables
        .into_iter()
        .map(|table| TableRef {
            connection_id: connection,
            database: table.database,
            schema: table.schema,
            name: table.name,
        })
        .collect())
}

impl From<&TableFolder> for TableFolderRecord {
    fn from(folder: &TableFolder) -> Self {
        Self {
            id: folder.id.to_string(),
            connection_id: folder.scope.connection_id.to_string(),
            database: folder.scope.database.clone(),
            schema: folder.scope.schema.clone(),
            name: folder.name.clone(),
            created_at_ms: folder.created_at_ms,
            updated_at_ms: folder.updated_at_ms,
        }
    }
}

impl TryFrom<TableFolderRecord> for TableFolder {
    type Error = CoreError;

    fn try_from(record: TableFolderRecord) -> Result<Self, CoreError> {
        Ok(Self {
            id: parse_id(&record.id)?,
            scope: TableScope {
                connection_id: parse_id(&record.connection_id)?,
                database: record.database,
                schema: record.schema,
            },
            name: record.name,
            created_at_ms: record.created_at_ms,
            updated_at_ms: record.updated_at_ms,
        })
    }
}

impl From<TableFolderItem> for TableFolderItemRecord {
    fn from(item: TableFolderItem) -> Self {
        Self {
            table: TableRefRecord {
                database: item.table.database,
                schema: item.table.schema,
                name: item.table.name,
            },
            folder_id: item.folder_id.to_string(),
        }
    }
}
