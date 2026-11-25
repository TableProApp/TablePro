macro_rules! columns {
    () => {
        "record_id, name, query, connection_id, connection_name, keyword, folder_record_id, sort_order, created_at, \
         updated_at"
    };
}

macro_rules! folder_columns {
    () => {
        "record_id, connection_id, name, parent_record_id, sort_order, created_at, updated_at"
    };
}

mod deletion;
mod folders;
mod new_saved_query;
mod ordering;
#[cfg(test)]
mod ordering_tests;
mod put;
#[cfg(test)]
mod put_tests;
mod saved_query;

use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqlitePool};
use tokio::sync::watch;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::error::StorageError;
use crate::journal::{RecordKind, Signals};
use crate::stored_id::{optional_uuid_column, uuid_column};
use crate::unix_time::{from_unix_millis, to_unix_millis};

pub use folders::{SavedQueryFolder, SavedQueryFolders};
pub(crate) use put::free_name;
pub use new_saved_query::NewSavedQuery;
pub use saved_query::SavedQuery;

const MAX_KEYWORD_CHARS: usize = 64;
const MAX_QUERY_BYTES: usize = 1024 * 1024;
const MAX_NAME_CHARS: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SaveOutcome {
    pub id: Uuid,
    pub replaced: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQueriesSnapshot {
    pub queries: Vec<SavedQuery>,
    pub folders: Vec<SavedQueryFolder>,
}

#[derive(Debug, Clone)]
pub struct SavedQueries {
    pool: SqlitePool,
    path: std::path::PathBuf,
    signals: Signals,
}

// The row a record id names, with what its writes need.
struct Held {
    rowid: i64,
    owner: Option<String>,
    folder: Option<String>,
}

impl SavedQueries {
    pub(crate) fn new(pool: SqlitePool, path: std::path::PathBuf, signals: Signals) -> Self {
        Self { pool, path, signals }
    }

    pub fn changes(&self) -> watch::Receiver<u64> {
        self.signals.subscribe()
    }

    fn changed(&self) {
        self.signals.changed(&[RecordKind::SavedQuery]);
    }

    pub async fn save(&self, query: NewSavedQuery) -> Result<SaveOutcome, StorageError> {
        let name = checked_query(&query)?;
        let owner = query.connection_id.map(|id| id.to_string());
        // Hold the write lock across both statements, so concurrent saves agree on which inserted.
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let now = to_unix_millis(SystemTime::now());
        let held = sqlx::query("SELECT id, record_id FROM saved_queries WHERE connection_id IS ? AND name = ?")
            .bind(&owner)
            .bind(name)
            .fetch_optional(&mut *transaction)
            .await?;
        let outcome = match held {
            Some(row) => {
                sqlx::query("UPDATE saved_queries SET query = ?, connection_name = ?, updated_at = ? WHERE id = ?")
                    .bind(&query.query)
                    .bind(&query.connection_name)
                    .bind(now)
                    .bind(row.try_get::<i64, _>("id")?)
                    .execute(&mut *transaction)
                    .await?;
                SaveOutcome {
                    id: uuid_column(&row, "record_id")?,
                    replaced: true,
                }
            }
            None => SaveOutcome {
                id: insert(&mut transaction, &query, name, owner.as_deref(), now).await?,
                replaced: false,
            },
        };
        transaction.commit().await?;
        self.changed();
        Ok(outcome)
    }

    pub async fn save_if_new(&self, query: NewSavedQuery) -> Result<Option<Uuid>, StorageError> {
        let name = checked_query(&query)?;
        let owner = query.connection_id.map(|id| id.to_string());
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let taken: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM saved_queries WHERE connection_id IS ? AND name = ?")
            .bind(&owner)
            .bind(name)
            .fetch_one(&mut *transaction)
            .await?;
        if taken > 0 {
            return Ok(None);
        }
        let id = insert(
            &mut transaction,
            &query,
            name,
            owner.as_deref(),
            to_unix_millis(SystemTime::now()),
        )
        .await?;
        transaction.commit().await?;
        self.changed();
        Ok(Some(id))
    }

    // A connection's list holds the queries with no connection too; None lists every query.
    pub async fn list(&self, connection: Option<Uuid>) -> Result<Vec<SavedQuery>, StorageError> {
        let rows = match connection {
            Some(id) => {
                sqlx::query(concat!(
                    "SELECT ",
                    columns!(),
                    " FROM saved_queries WHERE connection_id = ? OR connection_id IS NULL \
                     ORDER BY name COLLATE NOCASE, id"
                ))
                .bind(id.to_string())
                .fetch_all(&self.pool)
                .await?
            }
            None => {
                sqlx::query(concat!(
                    "SELECT ",
                    columns!(),
                    " FROM saved_queries ORDER BY connection_name COLLATE NOCASE, name COLLATE NOCASE, id"
                ))
                .fetch_all(&self.pool)
                .await?
            }
        };
        rows.iter().map(row_to_saved_query).collect()
    }

    // What one connection shows: its own queries and folders and those with no connection.
    pub async fn snapshot(&self, connection: Uuid) -> Result<SavedQueriesSnapshot, StorageError> {
        let mut transaction = self.pool.begin().await?;
        let queries = sqlx::query(concat!(
            "SELECT ",
            columns!(),
            " FROM saved_queries WHERE connection_id = ? OR connection_id IS NULL \
             ORDER BY sort_order, name COLLATE NOCASE, id"
        ))
        .bind(connection.to_string())
        .fetch_all(&mut *transaction)
        .await?
        .iter()
        .map(row_to_saved_query)
        .collect::<Result<Vec<_>, _>>()?;
        let folders = sqlx::query(concat!(
            "SELECT ",
            folder_columns!(),
            " FROM saved_query_folders WHERE connection_id = ? OR connection_id IS NULL \
             ORDER BY sort_order, name COLLATE NOCASE, id"
        ))
        .bind(connection.to_string())
        .fetch_all(&mut *transaction)
        .await?
        .iter()
        .map(folders::row_to_folder)
        .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(SavedQueriesSnapshot { queries, folders })
    }

    pub async fn get(&self, id: Uuid) -> Result<Option<SavedQuery>, StorageError> {
        sqlx::query(concat!("SELECT ", columns!(), " FROM saved_queries WHERE record_id = ?"))
            .bind(id.to_string())
            .fetch_optional(&self.pool)
            .await?
            .as_ref()
            .map(row_to_saved_query)
            .transpose()
    }

    pub async fn rename(&self, id: Uuid, name: &str) -> Result<(), StorageError> {
        let name = checked_name(name)?;
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let row = sqlx::query("SELECT id, name FROM saved_queries WHERE record_id = ?")
            .bind(id.to_string())
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(StorageError::NotFound)?;
        if row.try_get::<String, _>("name")? == name {
            return Ok(());
        }
        sqlx::query("UPDATE saved_queries SET name = ?, updated_at = ? WHERE id = ?")
            .bind(name)
            .bind(to_unix_millis(SystemTime::now()))
            .bind(row.try_get::<i64, _>("id")?)
            .execute(&mut *transaction)
            .await
            .map_err(|error| match &error {
                sqlx::Error::Database(database) if database.is_unique_violation() => StorageError::NameTaken,
                _ => StorageError::Database(error),
            })?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    // By id, so an edit made from a list read before a rename still reaches the query it showed.
    pub async fn set_query(&self, id: Uuid, query: &str) -> Result<(), StorageError> {
        if query.len() > MAX_QUERY_BYTES {
            return Err(StorageError::TooLarge {
                got: query.len(),
                limit: MAX_QUERY_BYTES,
            });
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let row = sqlx::query("SELECT id, query FROM saved_queries WHERE record_id = ?")
            .bind(id.to_string())
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(StorageError::NotFound)?;
        if row.try_get::<String, _>("query")? == query {
            return Ok(());
        }
        sqlx::query("UPDATE saved_queries SET query = ?, updated_at = ? WHERE id = ?")
            .bind(query)
            .bind(to_unix_millis(SystemTime::now()))
            .bind(row.try_get::<i64, _>("id")?)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn set_keyword(&self, id: Uuid, keyword: Option<&str>) -> Result<(), StorageError> {
        let keyword = match keyword {
            Some(word) => keyword_form(word)?,
            None => None,
        };
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let row = sqlx::query("SELECT id, connection_id, keyword FROM saved_queries WHERE record_id = ?")
            .bind(id.to_string())
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(StorageError::NotFound)?;
        let rowid: i64 = row.try_get("id")?;
        let owner: Option<String> = row.try_get("connection_id")?;
        if row.try_get::<Option<String>, _>("keyword")? == keyword {
            return Ok(());
        }
        if let Some(word) = &keyword {
            // A keyword expands in every connection its query shows in, so none of those may hold it.
            let held: Vec<String> = sqlx::query_scalar(
                "SELECT keyword FROM saved_queries WHERE id <> ?1 AND keyword IS NOT NULL \
                 AND (?2 IS NULL OR connection_id = ?2 OR connection_id IS NULL)",
            )
            .bind(rowid)
            .bind(&owner)
            .fetch_all(&mut *transaction)
            .await?;
            let key = keyword_key(word);
            if held.iter().any(|held| keyword_key(held) == key) {
                return Err(StorageError::KeywordTaken);
            }
        }
        sqlx::query("UPDATE saved_queries SET keyword = ?, updated_at = ? WHERE id = ?")
            .bind(keyword)
            .bind(to_unix_millis(SystemTime::now()))
            .bind(rowid)
            .execute(&mut *transaction)
            .await
            .map_err(|error| match &error {
                sqlx::Error::Database(database) if database.is_unique_violation() => StorageError::KeywordTaken,
                _ => StorageError::Database(error),
            })?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn set_folder(&self, id: Uuid, folder: Option<Uuid>) -> Result<(), StorageError> {
        self.move_query(id, folder, None, true).await
    }

    pub async fn move_to_folder(
        &self,
        id: Uuid,
        folder: Option<Uuid>,
        before: Option<Uuid>,
    ) -> Result<(), StorageError> {
        self.move_query(id, folder, before, false).await
    }

    async fn move_query(
        &self,
        id: Uuid,
        folder: Option<Uuid>,
        before: Option<Uuid>,
        keep_position: bool,
    ) -> Result<(), StorageError> {
        let folder = folder.map(|folder| folder.to_string());
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let Held {
            rowid,
            owner,
            folder: old_folder,
        } = held(&mut transaction, id).await?;
        if let Some(folder) = &folder {
            let target: Option<Option<String>> =
                sqlx::query_scalar("SELECT connection_id FROM saved_query_folders WHERE record_id = ?")
                    .bind(folder)
                    .fetch_optional(&mut *transaction)
                    .await?;
            // The folder has to show wherever the query does.
            match target {
                Some(None) => {}
                Some(Some(target)) if owner.as_deref() == Some(target.as_str()) => {}
                _ => return Err(StorageError::NotFound),
            }
        }
        if keep_position && old_folder == folder {
            transaction.commit().await?;
            return Ok(());
        }
        let before = match before {
            Some(before) if before == id => {
                return if old_folder == folder {
                    Ok(())
                } else {
                    Err(StorageError::NotFound)
                };
            }
            Some(before) => Some(
                sqlx::query_scalar::<_, i64>("SELECT id FROM saved_queries WHERE record_id = ?")
                    .bind(before.to_string())
                    .fetch_optional(&mut *transaction)
                    .await?
                    .ok_or(StorageError::NotFound)?,
            ),
            None => None,
        };
        let mut place = ordering::query_place(&mut transaction, owner.as_deref(), folder.as_deref()).await?;
        let original = place.clone();
        place.retain(|held| *held != rowid);
        let at = match before {
            Some(before) => place
                .iter()
                .position(|held| *held == before)
                .ok_or(StorageError::NotFound)?,
            None => place.len(),
        };
        place.insert(at, rowid);
        if old_folder == folder && place == original {
            return Ok(());
        }
        sqlx::query("UPDATE saved_queries SET folder_record_id = ?, updated_at = ? WHERE id = ?")
            .bind(&folder)
            .bind(to_unix_millis(SystemTime::now()))
            .bind(rowid)
            .execute(&mut *transaction)
            .await?;
        ordering::set_query_order(&mut transaction, &place).await?;
        if old_folder != folder {
            ordering::compact_queries(&mut transaction, owner.as_deref(), old_folder.as_deref()).await?;
        }
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn delete(&self, id: Uuid) -> Result<(), StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let Held { rowid, owner, folder } = held(&mut transaction, id).await?;
        crate::query_history::trim_upgrade_copies(
            &self.path,
            &[crate::query_history::CopyDelete {
                table: "saved_queries",
                sql: "DELETE FROM main.saved_queries WHERE id = ?".to_owned(),
                binds: vec![crate::query_history::Bind::Integer(rowid)],
            }],
        )
        .await?;
        sqlx::query("DELETE FROM saved_queries WHERE id = ?")
            .bind(rowid)
            .execute(&mut *transaction)
            .await?;
        ordering::compact_queries(&mut transaction, owner.as_deref(), folder.as_deref()).await?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    // The connection's own queries, folders and favourites; those with no connection stay for the others.
    pub async fn delete_for_connection(&self, connection: Uuid) -> Result<usize, StorageError> {
        let (queries, changed) = deletion::delete_connection(&self.pool, &self.path, connection).await?;
        if !changed.is_empty() {
            self.signals.changed(&changed);
        }
        Ok(queries)
    }

    // Queries a pull or another store brings, each under its own id, written over any this store holds
    // under that id. Returns the ids whose name or keyword the store changed to settle a collision,
    // the edits that go up as this device's own (core ADR 0052, Collisions).
    pub async fn put(&self, queries: &[SavedQuery]) -> Result<Vec<Uuid>, StorageError> {
        if queries.is_empty() {
            return Ok(Vec::new());
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let settled = put::put_queries(&mut transaction, queries, SystemTime::now()).await?;
        transaction.commit().await?;
        self.changed();
        Ok(settled)
    }
}

async fn held(database: &mut sqlx::SqliteConnection, id: Uuid) -> Result<Held, StorageError> {
    let row = sqlx::query("SELECT id, connection_id, folder_record_id FROM saved_queries WHERE record_id = ?")
        .bind(id.to_string())
        .fetch_optional(&mut *database)
        .await?
        .ok_or(StorageError::NotFound)?;
    Ok(Held {
        rowid: row.try_get("id")?,
        owner: row.try_get("connection_id")?,
        folder: row.try_get("folder_record_id")?,
    })
}

// A new query goes at the end of the top level of the list it shows in.
async fn insert(
    database: &mut sqlx::SqliteConnection,
    query: &NewSavedQuery,
    name: &str,
    owner: Option<&str>,
    now: i64,
) -> Result<Uuid, StorageError> {
    let id = Uuid::new_v4();
    let order = ordering::next_query_order(database, owner, None).await?;
    sqlx::query(
        "INSERT INTO saved_queries \
         (record_id, name, query, connection_id, connection_name, sort_order, created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id.to_string())
    .bind(name)
    .bind(&query.query)
    .bind(owner)
    .bind(&query.connection_name)
    .bind(order)
    .bind(now)
    .bind(now)
    .execute(&mut *database)
    .await?;
    Ok(id)
}

// Two keywords are one when they read the same in any case.
pub(crate) fn keyword_key(word: &str) -> String {
    word.nfc().collect::<String>().to_lowercase()
}

// Trimmed and composed, one word of at most 64 characters; None for a blank one.
fn keyword_form(word: &str) -> Result<Option<String>, StorageError> {
    let word: String = word.trim().nfc().collect();
    if word.is_empty() {
        return Ok(None);
    }
    if word.chars().count() > MAX_KEYWORD_CHARS
        || word
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || tablepro_core::unicode_blank::is_default_ignorable(c))
    {
        return Err(StorageError::KeywordInvalid { max: MAX_KEYWORD_CHARS });
    }
    Ok(Some(word))
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

fn checked_query(query: &NewSavedQuery) -> Result<&str, StorageError> {
    let name = checked_name(&query.name)?;
    if query.query.len() > MAX_QUERY_BYTES {
        return Err(StorageError::TooLarge {
            got: query.query.len(),
            limit: MAX_QUERY_BYTES,
        });
    }
    Ok(name)
}

fn row_to_saved_query(row: &sqlx::sqlite::SqliteRow) -> Result<SavedQuery, StorageError> {
    Ok(SavedQuery {
        id: uuid_column(row, "record_id")?,
        name: row.try_get("name")?,
        query: row.try_get("query")?,
        connection_id: optional_uuid_column(row, "connection_id")?,
        connection_name: row.try_get("connection_name")?,
        keyword: row.try_get("keyword")?,
        folder_id: optional_uuid_column(row, "folder_record_id")?,
        order: row.try_get("sort_order")?,
        created_at: from_unix_millis(row.try_get::<i64, _>("created_at")?),
        updated_at: from_unix_millis(row.try_get::<i64, _>("updated_at")?),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::StoragePaths;
    use crate::query_history::QueryHistory;

    async fn store(root: &tempfile::TempDir) -> SavedQueries {
        let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
        QueryHistory::open(&paths).await.expect("open").saved_queries()
    }

    fn new_query(name: &str, sql: &str, connection: Uuid) -> NewSavedQuery {
        NewSavedQuery {
            name: name.to_owned(),
            query: sql.to_owned(),
            connection_id: Some(connection),
            connection_name: "local".to_owned(),
        }
    }

    #[tokio::test]
    async fn a_saved_query_comes_back() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();

        let saved = store
            .save(new_query("daily report", "SELECT 1", connection))
            .await
            .expect("save");

        assert!(!saved.replaced);
        let saved = store.get(saved.id).await.expect("get").expect("the saved query");
        assert_eq!(saved.name, "daily report");
        assert_eq!(saved.query, "SELECT 1");
        assert_eq!(saved.connection_id, Some(connection));
        assert_eq!(saved.connection_name, "local");
    }

    #[tokio::test]
    async fn a_keyword_is_one_word_unique_to_the_connection_in_any_case() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        let first = store
            .save(new_query("a", "SELECT 1", connection))
            .await
            .expect("save")
            .id;
        let second = store
            .save(new_query("b", "SELECT 2", connection))
            .await
            .expect("save")
            .id;
        let elsewhere = store
            .save(new_query("c", "SELECT 3", Uuid::new_v4()))
            .await
            .expect("save")
            .id;

        store.set_keyword(first, Some("  Daily ")).await.expect("a keyword");
        assert_eq!(
            store
                .get(first)
                .await
                .expect("get")
                .expect("the query")
                .keyword
                .as_deref(),
            Some("Daily")
        );
        assert!(matches!(
            store.set_keyword(second, Some("daily")).await,
            Err(StorageError::KeywordTaken)
        ));
        assert!(matches!(
            store.set_keyword(second, Some("two words")).await,
            Err(StorageError::KeywordInvalid { .. })
        ));
        store
            .set_keyword(elsewhere, Some("daily"))
            .await
            .expect("another connection may reuse it");

        store
            .set_keyword(first, Some("  "))
            .await
            .expect("a blank keyword clears");
        assert_eq!(store.get(first).await.expect("get").expect("the query").keyword, None);
        store
            .set_keyword(second, Some("daily"))
            .await
            .expect("the keyword is free again");
    }

    #[tokio::test]
    async fn queries_are_filed_in_folders_that_nest_and_go_with_their_parent() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
            .await
            .expect("open");
        let (store, folders) = (history.saved_queries(), history.saved_query_folders());
        let connection = Uuid::new_v4();
        let reports = folders.create(Some(connection), "Reports", None).await.expect("a folder");
        let monthly = folders
            .create(Some(connection), "Monthly", Some(reports))
            .await
            .expect("a subfolder");
        let a = store
            .save(new_query("a", "SELECT 1", connection))
            .await
            .expect("save")
            .id;
        let b = store
            .save(new_query("b", "SELECT 2", connection))
            .await
            .expect("save")
            .id;

        store.move_to_folder(a, Some(monthly), None).await.expect("file a");
        store
            .move_to_folder(b, Some(monthly), Some(a))
            .await
            .expect("file b before a");
        async fn placed(store: &SavedQueries, id: Uuid) -> (Option<Uuid>, i64) {
            let query = store.get(id).await.expect("get").expect("the query");
            (query.folder_id, query.order)
        }
        assert_eq!(placed(&store, b).await, (Some(monthly), 0));
        assert_eq!(placed(&store, a).await, (Some(monthly), 1));

        assert!(matches!(
            folders.create(Some(connection), "REPORTS", None).await,
            Err(StorageError::FolderNameTaken)
        ));
        assert!(matches!(
            folders.move_to(reports, Some(monthly)).await,
            Err(StorageError::FolderCycle { .. })
        ));
        let other = folders
            .create(Some(Uuid::new_v4()), "Elsewhere", None)
            .await
            .expect("another connection's");
        assert!(matches!(
            store.move_to_folder(a, Some(other), None).await,
            Err(StorageError::NotFound)
        ));

        folders.delete(reports).await.expect("delete the folder");
        assert!(
            folders.list(connection).await.expect("list").is_empty(),
            "a subfolder outlived its parent"
        );
        assert_eq!(placed(&store, a).await.0, None, "a query went with its folder");
    }

    #[tokio::test]
    async fn favourite_tables_and_databases_are_kept_per_connection_and_go_with_it() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
            .await
            .expect("open");
        let favourites = history.favourites();
        let connection = Uuid::new_v4();
        let orders = crate::favourites::FavouriteTable {
            connection_id: connection,
            database: None,
            schema: Some("public".to_owned()),
            name: "orders".to_owned(),
        };

        favourites.add_table(&orders).await.expect("mark a table");
        favourites
            .add_table(&orders)
            .await
            .expect("marking it again changes nothing");
        favourites
            .set_database(connection, "shop", crate::favourites::DatabaseEnvironment::Testing)
            .await
            .expect("mark a database");
        favourites
            .set_database(connection, "shop", crate::favourites::DatabaseEnvironment::Production)
            .await
            .expect("change its environment");

        assert_eq!(
            favourites.tables(connection).await.expect("tables"),
            std::slice::from_ref(&orders)
        );
        let databases = favourites.databases(connection).await.expect("databases");
        assert_eq!(databases.len(), 1);
        assert_eq!(
            databases[0].environment,
            crate::favourites::DatabaseEnvironment::Production
        );

        store(&root)
            .await
            .delete_for_connection(connection)
            .await
            .expect("remove the connection's data");
        assert!(favourites.tables(connection).await.expect("tables").is_empty());
        assert!(favourites.databases(connection).await.expect("databases").is_empty());
    }

    #[tokio::test]
    async fn saving_if_new_leaves_a_held_name_alone() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();

        let first = store
            .save_if_new(new_query("daily report", "SELECT 1", connection))
            .await
            .expect("save");
        let second = store
            .save_if_new(new_query("daily report", "SELECT 2", connection))
            .await
            .expect("save again");
        let elsewhere = store
            .save_if_new(new_query("daily report", "SELECT 3", Uuid::new_v4()))
            .await
            .expect("save on another connection");

        assert!(first.is_some());
        assert_eq!(second, None, "the held name was overwritten");
        assert!(elsewhere.is_some());
        let all = store.list(Some(connection)).await.expect("list");
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].query, "SELECT 1");
    }

    #[tokio::test]
    async fn saving_over_a_name_replaces_that_query_rather_than_adding_one() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();

        let first = store
            .save(new_query("daily report", "SELECT 1", connection))
            .await
            .expect("save");
        let second = store
            .save(new_query("daily report", "SELECT 2", connection))
            .await
            .expect("save again");

        assert!(!first.replaced);
        assert!(second.replaced, "the second save overwrote the first");
        assert_eq!(first.id, second.id, "the row was replaced, so its id is the same");
        let all = store.list(Some(connection)).await.expect("list");
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].query, "SELECT 2");
    }

    #[tokio::test]
    async fn concurrent_new_saves_never_overwrite_the_winner() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        let (first, second) = tokio::join!(
            store.save_if_new(new_query("daily", "SELECT 1", connection)),
            store.save_if_new(new_query("daily", "SELECT 2", connection)),
        );
        let first = first.expect("first save");
        let second = second.expect("second save");
        assert_ne!(first.is_some(), second.is_some());
        let saved = store.list(Some(connection)).await.expect("list");
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].query, if first.is_some() { "SELECT 1" } else { "SELECT 2" });
    }

    #[tokio::test]
    async fn concurrent_saves_report_exactly_one_replacement_and_keep_the_id() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        let (first, second) = tokio::join!(
            store.save(new_query("daily", "SELECT 1", connection)),
            store.save(new_query("daily", "SELECT 2", connection)),
        );
        let first = first.expect("first save");
        let second = second.expect("second save");
        assert_ne!(first.replaced, second.replaced);
        assert_eq!(first.id, second.id);
        assert_eq!(store.list(Some(connection)).await.expect("list").len(), 1);
    }

    #[tokio::test]
    async fn the_same_name_on_another_connection_is_another_query() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let (first, second) = (Uuid::new_v4(), Uuid::new_v4());

        store.save(new_query("daily", "SELECT 1", first)).await.expect("save");
        store.save(new_query("daily", "SELECT 2", second)).await.expect("save");

        assert_eq!(store.list(Some(first)).await.expect("list")[0].query, "SELECT 1");
        assert_eq!(store.list(Some(second)).await.expect("list")[0].query, "SELECT 2");
        assert_eq!(store.list(None).await.expect("list all").len(), 2);
    }

    #[tokio::test]
    async fn a_connections_list_holds_only_its_own() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let (mine, theirs) = (Uuid::new_v4(), Uuid::new_v4());

        store.save(new_query("mine", "SELECT 1", mine)).await.expect("save");
        store.save(new_query("theirs", "SELECT 2", theirs)).await.expect("save");

        let listed = store.list(Some(mine)).await.expect("list");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "mine");
    }

    #[tokio::test]
    async fn the_list_is_ordered_by_name_whatever_the_case() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();

        for name in ["zeta", "Alpha", "beta"] {
            store.save(new_query(name, "SELECT 1", connection)).await.expect("save");
        }

        let names: Vec<String> = store
            .list(Some(connection))
            .await
            .expect("list")
            .into_iter()
            .map(|saved| saved.name)
            .collect();
        assert_eq!(names, vec!["Alpha", "beta", "zeta"]);
    }

    #[tokio::test]
    async fn a_name_that_is_only_spaces_is_refused() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;

        let error = store
            .save(new_query("   ", "SELECT 1", Uuid::new_v4()))
            .await
            .expect_err("an empty name is not a name");

        assert!(matches!(error, StorageError::EmptyName), "{error:?}");
    }

    #[tokio::test]
    async fn a_name_is_stored_trimmed() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();

        store
            .save(new_query("  daily  ", "SELECT 1", connection))
            .await
            .expect("save");
        // The trimmed name is what the unique index sees, so this is
        // the same query rather than a second one.
        store
            .save(new_query("daily", "SELECT 2", connection))
            .await
            .expect("save");

        let all = store.list(Some(connection)).await.expect("list");
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].name, "daily");
    }

    #[tokio::test]
    async fn a_query_past_the_size_cap_is_refused() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;

        let error = store
            .save(new_query("big", &"x".repeat(MAX_QUERY_BYTES + 1), Uuid::new_v4()))
            .await
            .expect_err("over the cap");

        assert!(matches!(error, StorageError::TooLarge { .. }), "{error:?}");
    }

    #[tokio::test]
    async fn renaming_moves_the_query_under_its_new_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        let saved = store
            .save(new_query("old", "SELECT 1", connection))
            .await
            .expect("save");

        store.rename(saved.id, "  new  ").await.expect("rename");

        assert_eq!(store.get(saved.id).await.expect("get").expect("saved").name, "new");
    }

    #[tokio::test]
    async fn renaming_onto_a_name_the_connection_already_has_fails() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        store
            .save(new_query("taken", "SELECT 1", connection))
            .await
            .expect("save");
        let saved = store
            .save(new_query("mine", "SELECT 2", connection))
            .await
            .expect("save");

        let error = store.rename(saved.id, "taken").await.expect_err("the name is taken");

        assert!(matches!(error, StorageError::NameTaken), "{error:?}");
        // The failed rename left both queries as they were.
        assert_eq!(store.list(Some(connection)).await.expect("list").len(), 2);
    }

    #[tokio::test]
    async fn renaming_something_that_is_gone_says_so() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;

        let error = store.rename(Uuid::new_v4(), "new").await.expect_err("no such query");

        assert!(matches!(error, StorageError::NotFound), "{error:?}");
    }

    #[tokio::test]
    async fn deleting_removes_it_from_the_list() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        let saved = store
            .save(new_query("daily", "SELECT 1", connection))
            .await
            .expect("save");

        store.delete(saved.id).await.expect("delete");

        assert!(store.list(Some(connection)).await.expect("list").is_empty());
        assert!(store.get(saved.id).await.expect("get").is_none());
        assert!(matches!(
            store.delete(saved.id).await.expect_err("already gone"),
            StorageError::NotFound
        ));
    }

    #[tokio::test]
    async fn removing_a_connection_takes_its_queries_and_leaves_the_rest() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let (going, staying) = (Uuid::new_v4(), Uuid::new_v4());
        store.save(new_query("a", "SELECT 1", going)).await.expect("save");
        store.save(new_query("b", "SELECT 2", going)).await.expect("save");
        store.save(new_query("c", "SELECT 3", staying)).await.expect("save");

        let removed = store.delete_for_connection(going).await.expect("delete");

        assert_eq!(removed, 2);
        assert!(store.list(Some(going)).await.expect("list").is_empty());
        assert_eq!(store.list(Some(staying)).await.expect("list").len(), 1);
    }

    #[tokio::test]
    async fn every_write_moves_the_revision_every_handle_follows() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
        let history = QueryHistory::open(&paths).await.expect("open");
        let (writer, follower) = (history.saved_queries(), history.saved_queries());
        let mut changes = follower.changes();
        let connection = Uuid::new_v4();
        let mut moved = || {
            let moved = changes.has_changed().expect("the sender lives");
            changes.mark_unchanged();
            moved
        };

        let saved = writer
            .save(new_query("daily", "SELECT 1", connection))
            .await
            .expect("save");
        assert!(moved(), "a save");
        writer
            .save_if_new(new_query("weekly", "SELECT 2", connection))
            .await
            .expect("save if new");
        assert!(moved(), "a save of a new name");
        writer.rename(saved.id, "nightly").await.expect("rename");
        assert!(moved(), "a rename");
        writer.delete(saved.id).await.expect("delete");
        assert!(moved(), "a delete");
        writer
            .delete_for_connection(connection)
            .await
            .expect("delete for connection");
        assert!(moved(), "a connection's queries removed");
    }

    #[tokio::test]
    async fn a_read_or_a_write_that_changed_nothing_leaves_the_revision() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        store
            .save(new_query("daily", "SELECT 1", connection))
            .await
            .expect("save");
        let changes = store.changes();

        store.list(Some(connection)).await.expect("list");
        store
            .save_if_new(new_query("daily", "SELECT 2", connection))
            .await
            .expect("save if new");
        store.rename(Uuid::new_v4(), "gone").await.expect_err("no such query");
        store.delete(Uuid::new_v4()).await.expect_err("no such query");
        store
            .delete_for_connection(Uuid::new_v4())
            .await
            .expect("delete for a connection with none");

        assert!(!changes.has_changed().expect("the sender lives"));
    }

    #[tokio::test]
    async fn a_save_carries_the_connections_current_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root).await;
        let connection = Uuid::new_v4();
        store
            .save(new_query("daily", "SELECT 1", connection))
            .await
            .expect("save");

        let saved = store
            .save(NewSavedQuery {
                name: "daily".to_owned(),
                query: "SELECT 2".to_owned(),
                connection_id: Some(connection),
                connection_name: "renamed".to_owned(),
            })
            .await
            .expect("save");

        assert_eq!(
            store.get(saved.id).await.expect("get").expect("saved").connection_name,
            "renamed"
        );
    }

    #[tokio::test]
    async fn set_query_changes_the_text_by_id_and_keeps_its_name_and_place() {
        let root = tempfile::tempdir().expect("tempdir");
        let queries = store(&root).await;
        let connection = Uuid::new_v4();
        let id = queries
            .save(new_query("Daily", "SELECT 1", connection))
            .await
            .expect("save")
            .id;
        queries.rename(id, "Weekly").await.expect("rename");

        queries.set_query(id, "SELECT 7").await.expect("set the query");
        let missing = queries
            .set_query(Uuid::new_v4(), "SELECT 2")
            .await
            .expect_err("an unknown id");
        let large = queries
            .set_query(id, &"x".repeat(MAX_QUERY_BYTES + 1))
            .await
            .expect_err("past the cap");

        let saved = queries.get(id).await.expect("get").expect("the query");
        assert_eq!((saved.name.as_str(), saved.query.as_str()), ("Weekly", "SELECT 7"));
        assert_eq!(queries.list(Some(connection)).await.expect("list").len(), 1);
        assert!(matches!(missing, StorageError::NotFound), "{missing:?}");
        assert!(matches!(large, StorageError::TooLarge { .. }), "{large:?}");
    }
}
