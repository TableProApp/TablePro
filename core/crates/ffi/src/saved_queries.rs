use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_storage::saved_queries::{NewSavedQuery, SavedQuery};
use tablepro_storage::{SavedQueries, SavedQueriesSnapshot, SavedQueryFolder, SavedQueryFolders};

use crate::error::CoreError;
use crate::history::millis;
use crate::library::parse_id;
use crate::runtime::on_runtime;

// A connection's saved queries and their folders, in the query history's database (core ADR 0017).
#[derive(uniffi::Object)]
pub struct SavedQueryStore {
    queries: SavedQueries,
    folders: SavedQueryFolders,
    tasks: Tasks,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryInfo {
    pub id: i64,
    pub name: String,
    pub sql: String,
    pub keyword: Option<String>,
    // None at the top, outside every folder.
    pub folder_id: Option<i64>,
    // Dense from 0 within its folder.
    pub order: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryFolderInfo {
    pub id: i64,
    pub name: String,
    pub parent_id: Option<i64>,
    pub order: i64,
}

// Read in one transaction, each list in its place's order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueriesInfo {
    pub queries: Vec<SavedQueryInfo>,
    pub folders: Vec<SavedQueryFolderInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryDraft {
    pub connection_id: String,
    pub connection_name: String,
    pub name: String,
    pub sql: String,
}

impl SavedQueryStore {
    pub(crate) fn new(queries: SavedQueries, folders: SavedQueryFolders, tasks: Tasks) -> Arc<Self> {
        Arc::new(Self {
            queries,
            folders,
            tasks,
        })
    }
}

#[uniffi::export]
impl SavedQueryStore {
    pub async fn snapshot(&self, connection_id: String) -> Result<SavedQueriesInfo, CoreError> {
        let connection = parse_id(&connection_id)?;
        let queries = self.queries.clone();
        on_runtime(
            &self.tasks,
            async move { Ok(queries.snapshot(connection).await?.into()) },
        )
        .await
    }

    // A name the connection already uses is replaced only when `replace` says so, keeping the query's keyword and
    // place; otherwise None comes back and nothing is written.
    pub async fn save(&self, draft: SavedQueryDraft, replace: bool) -> Result<Option<i64>, CoreError> {
        let query = NewSavedQuery {
            connection_id: parse_id(&draft.connection_id)?,
            connection_name: draft.connection_name,
            name: draft.name,
            query: draft.sql,
        };
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            match replace {
                true => Ok(Some(queries.save(query).await?.id)),
                false => Ok(queries.save_if_new(query).await?),
            }
        })
        .await
    }

    pub async fn rename(&self, id: i64, name: String) -> Result<(), CoreError> {
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.rename(id, &name).await?) }).await
    }

    // By id, so an edit from a list read before a rename elsewhere still changes the query it showed.
    pub async fn set_sql(&self, id: i64, sql: String) -> Result<(), CoreError> {
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.set_query(id, &sql).await?) }).await
    }

    // None or blank clears it. One word of at most 64 characters, unique among the connection's queries in any case.
    pub async fn set_keyword(&self, id: i64, keyword: Option<String>) -> Result<(), CoreError> {
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            Ok(queries.set_keyword(id, keyword.as_deref()).await?)
        })
        .await
    }

    // Into `folder_id`, None for the top, before the query `before` names there, or at the end.
    pub async fn move_query(&self, id: i64, folder_id: Option<i64>, before: Option<i64>) -> Result<(), CoreError> {
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            Ok(queries.move_to_folder(id, folder_id, before).await?)
        })
        .await
    }

    pub async fn delete(&self, id: i64) -> Result<(), CoreError> {
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.delete(id).await?) }).await
    }

    pub async fn create_folder(
        &self,
        connection_id: String,
        name: String,
        parent_id: Option<i64>,
    ) -> Result<i64, CoreError> {
        let connection = parse_id(&connection_id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            Ok(folders.create(connection, &name, parent_id).await?)
        })
        .await
    }

    pub async fn rename_folder(&self, id: i64, name: String) -> Result<(), CoreError> {
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.rename(id, &name).await?) }).await
    }

    pub async fn move_folder(&self, id: i64, parent_id: Option<i64>) -> Result<(), CoreError> {
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.move_to(id, parent_id).await?) }).await
    }

    // The folders inside go too; their queries move to the top.
    pub async fn delete_folder(&self, id: i64) -> Result<(), CoreError> {
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.delete(id).await?) }).await
    }

    // The connection's queries, folders and favourite tables and databases, for a connection deleted.
    pub async fn delete_for_connection(&self, connection_id: String) -> Result<u64, CoreError> {
        let connection = parse_id(&connection_id)?;
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            let removed = queries.delete_for_connection(connection).await?;
            Ok(u64::try_from(removed).unwrap_or(u64::MAX))
        })
        .await
    }
}

impl From<SavedQueriesSnapshot> for SavedQueriesInfo {
    fn from(snapshot: SavedQueriesSnapshot) -> Self {
        Self {
            queries: snapshot.queries.into_iter().map(SavedQueryInfo::from).collect(),
            folders: snapshot.folders.into_iter().map(SavedQueryFolderInfo::from).collect(),
        }
    }
}

impl From<SavedQuery> for SavedQueryInfo {
    fn from(query: SavedQuery) -> Self {
        Self {
            id: query.id,
            name: query.name,
            sql: query.query,
            keyword: query.keyword,
            folder_id: query.folder_id,
            order: query.order,
            updated_at_ms: millis(query.updated_at),
        }
    }
}

impl From<SavedQueryFolder> for SavedQueryFolderInfo {
    fn from(folder: SavedQueryFolder) -> Self {
        Self {
            id: folder.id,
            name: folder.name,
            parent_id: folder.parent_id,
            order: folder.order,
        }
    }
}

impl std::fmt::Debug for SavedQueryStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SavedQueryStore").finish_non_exhaustive()
    }
}
