use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_storage::saved_queries::{NewSavedQuery, SavedQuery};
use tablepro_storage::{SavedQueries, SavedQueriesSnapshot, SavedQueryFolder, SavedQueryFolders};

use crate::error::CoreError;
use crate::history::millis;
use crate::library::parse_id;
use crate::runtime::on_runtime;

// A connection's saved queries and their folders, in the query history's database (core ADRs 0017 and 0052). Each is
// named by its record id, UUID text.
#[derive(uniffi::Object)]
pub struct SavedQueryStore {
    pub(crate) queries: SavedQueries,
    pub(crate) folders: SavedQueryFolders,
    pub(crate) tasks: Tasks,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryInfo {
    pub id: String,
    pub name: String,
    pub sql: String,
    pub keyword: Option<String>,
    // None for a query in every connection.
    pub connection_id: Option<String>,
    // None at the top, outside every folder; a folder the snapshot does not hold reads as the top too.
    pub folder_id: Option<String>,
    // Its place in its folder, lowest first; a query with no connection shares the numbers of every connection's.
    pub order: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedQueryFolderInfo {
    pub id: String,
    pub name: String,
    // None for a folder in every connection.
    pub connection_id: Option<String>,
    pub parent_id: Option<String>,
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
    // None keeps the query in every connection.
    pub connection_id: Option<String>,
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
    pub async fn save(&self, draft: SavedQueryDraft, replace: bool) -> Result<Option<String>, CoreError> {
        let query = NewSavedQuery {
            connection_id: draft.connection_id.as_deref().map(parse_id).transpose()?,
            connection_name: draft.connection_name,
            name: draft.name,
            query: draft.sql,
        };
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            let id = match replace {
                true => Some(queries.save(query).await?.id),
                false => queries.save_if_new(query).await?,
            };
            Ok(id.map(|id| id.to_string()))
        })
        .await
    }

    pub async fn rename(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.rename(id, &name).await?) }).await
    }

    // By id, so an edit from a list read before a rename elsewhere still changes the query it showed.
    pub async fn set_sql(&self, id: String, sql: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.set_query(id, &sql).await?) }).await
    }

    // None or blank clears it. One word of at most 64 characters, in any case unique among the queries of every
    // connection the query shows in.
    pub async fn set_keyword(&self, id: String, keyword: Option<String>) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            Ok(queries.set_keyword(id, keyword.as_deref()).await?)
        })
        .await
    }

    // Into `folder_id`, None for the top, before the query `before` names there, or at the end.
    pub async fn move_query(
        &self,
        id: String,
        folder_id: Option<String>,
        before: Option<String>,
    ) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let folder_id = folder_id.as_deref().map(parse_id).transpose()?;
        let before = before.as_deref().map(parse_id).transpose()?;
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move {
            Ok(queries.move_to_folder(id, folder_id, before).await?)
        })
        .await
    }

    pub async fn delete(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let queries = self.queries.clone();
        on_runtime(&self.tasks, async move { Ok(queries.delete(id).await?) }).await
    }

    // None for a folder in every connection.
    pub async fn create_folder(
        &self,
        connection_id: Option<String>,
        name: String,
        parent_id: Option<String>,
    ) -> Result<String, CoreError> {
        let connection = connection_id.as_deref().map(parse_id).transpose()?;
        let parent_id = parent_id.as_deref().map(parse_id).transpose()?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move {
            Ok(folders.create(connection, &name, parent_id).await?.to_string())
        })
        .await
    }

    pub async fn rename_folder(&self, id: String, name: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.rename(id, &name).await?) }).await
    }

    pub async fn move_folder(&self, id: String, parent_id: Option<String>) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let parent_id = parent_id.as_deref().map(parse_id).transpose()?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.move_to(id, parent_id).await?) }).await
    }

    // The folders inside go too; their queries move to the top.
    pub async fn delete_folder(&self, id: String) -> Result<(), CoreError> {
        let id = parse_id(&id)?;
        let folders = self.folders.clone();
        on_runtime(&self.tasks, async move { Ok(folders.delete(id).await?) }).await
    }

    // The connection's queries, folders and favourite tables and databases, for a connection deleted. Those with no
    // connection stay.
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
            id: query.id.to_string(),
            name: query.name,
            sql: query.query,
            keyword: query.keyword,
            connection_id: query.connection_id.map(|id| id.to_string()),
            folder_id: query.folder_id.map(|id| id.to_string()),
            order: query.order,
            updated_at_ms: millis(query.updated_at),
        }
    }
}

impl From<SavedQueryFolder> for SavedQueryFolderInfo {
    fn from(folder: SavedQueryFolder) -> Self {
        Self {
            id: folder.id.to_string(),
            name: folder.name,
            connection_id: folder.connection_id.map(|id| id.to_string()),
            parent_id: folder.parent_id.map(|id| id.to_string()),
            order: folder.order,
        }
    }
}

impl std::fmt::Debug for SavedQueryStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SavedQueryStore").finish_non_exhaustive()
    }
}
