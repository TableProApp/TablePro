mod deletion;
mod folders;
mod new_saved_query;
mod ordering;
#[cfg(test)]
mod ordering_tests;
mod saved_query;

use std::sync::Arc;
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqlitePool};
use tokio::sync::watch;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::error::StorageError;
use crate::unix_time::{from_unix, to_unix};

pub use folders::{SavedQueryFolder, SavedQueryFolders};
pub use new_saved_query::NewSavedQuery;
pub use saved_query::SavedQuery;

macro_rules! columns {
    () => {
        "id, name, query, connection_id, connection_name, keyword, folder_id, sort_order, created_at, updated_at"
    };
}

const MAX_KEYWORD_CHARS: usize = 64;
const MAX_QUERY_BYTES: usize = 1024 * 1024;
const MAX_NAME_CHARS: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SaveOutcome {
    pub id: i64,
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
    changes: Arc<watch::Sender<u64>>,
}

impl SavedQueries {
    pub(crate) fn new(pool: SqlitePool, path: std::path::PathBuf, changes: Arc<watch::Sender<u64>>) -> Self {
        Self { pool, path, changes }
    }

    pub fn changes(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    fn changed(&self) {
        self.changes
            .send_modify(|revision| *revision = revision.wrapping_add(1));
    }

    pub async fn save(&self, query: NewSavedQuery) -> Result<SaveOutcome, StorageError> {
        let name = checked_query(&query)?;
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let replaced: bool =
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM saved_queries WHERE connection_id = ? AND name = ?")
                .bind(query.connection_id.to_string())
                .bind(name)
                .fetch_one(&mut *transaction)
                .await?
                > 0;
        let now = to_unix(SystemTime::now());
        let id = sqlx::query_scalar(
            "INSERT INTO saved_queries (name, query, connection_id, connection_name, sort_order, created_at, updated_at) \
             VALUES (?1, ?2, ?3, ?4, \
                 (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_queries WHERE connection_id = ?3 AND folder_id IS NULL), ?5, ?5) \
             ON CONFLICT (connection_id, name) DO UPDATE SET query = excluded.query, \
                 connection_name = excluded.connection_name, updated_at = excluded.updated_at RETURNING id",
        )
        .bind(name).bind(&query.query).bind(query.connection_id.to_string())
        .bind(&query.connection_name).bind(now)
        .fetch_one(&mut *transaction).await?;
        transaction.commit().await?;
        self.changed();
        Ok(SaveOutcome { id, replaced })
    }

    pub async fn save_if_new(&self, query: NewSavedQuery) -> Result<Option<i64>, StorageError> {
        let name = checked_query(&query)?;
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let id = sqlx::query_scalar(
            "INSERT INTO saved_queries (name, query, connection_id, connection_name, sort_order, created_at, updated_at) \
             VALUES (?1, ?2, ?3, ?4, \
                 (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_queries WHERE connection_id = ?3 AND folder_id IS NULL), ?5, ?5) \
             ON CONFLICT (connection_id, name) DO NOTHING RETURNING id",
        )
        .bind(name).bind(&query.query).bind(query.connection_id.to_string())
        .bind(&query.connection_name).bind(to_unix(SystemTime::now()))
        .fetch_optional(&mut *transaction).await?;
        transaction.commit().await?;
        if id.is_some() {
            self.changed();
        }
        Ok(id)
    }

    pub async fn list(&self, connection: Option<Uuid>) -> Result<Vec<SavedQuery>, StorageError> {
        let rows = match connection {
            Some(id) => {
                sqlx::query(concat!(
                    "SELECT ",
                    columns!(),
                    " FROM saved_queries WHERE connection_id = ? ORDER BY name COLLATE NOCASE, id"
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
        rows.into_iter().map(row_to_saved_query).collect()
    }

    pub async fn snapshot(&self, connection: Uuid) -> Result<SavedQueriesSnapshot, StorageError> {
        let mut transaction = self.pool.begin().await?;
        let queries = sqlx::query(concat!(
            "SELECT ",
            columns!(),
            " FROM saved_queries WHERE connection_id = ? ORDER BY sort_order, name COLLATE NOCASE, id"
        ))
        .bind(connection.to_string())
        .fetch_all(&mut *transaction)
        .await?
        .into_iter()
        .map(row_to_saved_query)
        .collect::<Result<Vec<_>, _>>()?;
        let folders = sqlx::query(
            "SELECT id, connection_id, name, parent_id, sort_order, created_at, updated_at \
             FROM saved_query_folders WHERE connection_id = ? ORDER BY sort_order, name COLLATE NOCASE, id",
        )
        .bind(connection.to_string())
        .fetch_all(&mut *transaction)
        .await?
        .into_iter()
        .map(folders::row_to_folder)
        .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(SavedQueriesSnapshot { queries, folders })
    }

    pub async fn get(&self, id: i64) -> Result<Option<SavedQuery>, StorageError> {
        sqlx::query(concat!("SELECT ", columns!(), " FROM saved_queries WHERE id = ?"))
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
            .map(row_to_saved_query)
            .transpose()
    }

    pub async fn rename(&self, id: i64, name: &str) -> Result<(), StorageError> {
        let name = checked_name(name)?;
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let previous: Option<String> = sqlx::query_scalar("SELECT name FROM saved_queries WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *transaction)
            .await?;
        let previous = previous.ok_or(StorageError::NotFound)?;
        if previous == name {
            return Ok(());
        }
        sqlx::query("UPDATE saved_queries SET name = ?, updated_at = ? WHERE id = ?")
            .bind(name)
            .bind(to_unix(SystemTime::now()))
            .bind(id)
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

    pub async fn set_keyword(&self, id: i64, keyword: Option<&str>) -> Result<(), StorageError> {
        let keyword: Option<String> = keyword
            .map(str::trim)
            .filter(|word| !word.is_empty())
            .map(|word| word.nfc().collect());
        if let Some(word) = &keyword
            && (word.chars().count() > MAX_KEYWORD_CHARS
                || word.chars().any(|c| {
                    c.is_whitespace() || c.is_control() || tablepro_core::unicode_blank::is_default_ignorable(c)
                }))
        {
            return Err(StorageError::KeywordInvalid { max: MAX_KEYWORD_CHARS });
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let row = sqlx::query("SELECT connection_id, keyword FROM saved_queries WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(StorageError::NotFound)?;
        let owner: String = row.try_get("connection_id")?;
        if row.try_get::<Option<String>, _>("keyword")? == keyword {
            return Ok(());
        }
        if let Some(word) = &keyword {
            let held: Vec<String> = sqlx::query_scalar(
                "SELECT keyword FROM saved_queries WHERE connection_id = ? AND id <> ? AND keyword IS NOT NULL",
            )
            .bind(owner)
            .bind(id)
            .fetch_all(&mut *transaction)
            .await?;
            let key = word.to_lowercase();
            if held
                .iter()
                .any(|held| held.nfc().collect::<String>().to_lowercase() == key)
            {
                return Err(StorageError::KeywordTaken);
            }
        }
        sqlx::query("UPDATE saved_queries SET keyword = ?, updated_at = ? WHERE id = ?")
            .bind(keyword)
            .bind(to_unix(SystemTime::now()))
            .bind(id)
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

    pub async fn move_to_folder(&self, id: i64, folder: Option<i64>, before: Option<i64>) -> Result<(), StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let row = sqlx::query("SELECT connection_id, folder_id FROM saved_queries WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(StorageError::NotFound)?;
        let owner: String = row.try_get("connection_id")?;
        let old_folder: Option<i64> = row.try_get("folder_id")?;
        if let Some(folder) = folder {
            let target: Option<String> =
                sqlx::query_scalar("SELECT connection_id FROM saved_query_folders WHERE id = ?")
                    .bind(folder)
                    .fetch_optional(&mut *transaction)
                    .await?;
            if target.as_deref() != Some(owner.as_str()) {
                return Err(StorageError::NotFound);
            }
        }
        if before == Some(id) {
            return if old_folder == folder {
                Ok(())
            } else {
                Err(StorageError::NotFound)
            };
        }
        let mut place: Vec<i64> = sqlx::query_scalar(
            "SELECT id FROM saved_queries WHERE connection_id = ? AND folder_id IS ? \
             ORDER BY sort_order, name COLLATE NOCASE, id",
        )
        .bind(&owner)
        .bind(folder)
        .fetch_all(&mut *transaction)
        .await?;
        let original = place.clone();
        place.retain(|held| *held != id);
        let at = match before {
            Some(before) => place
                .iter()
                .position(|held| *held == before)
                .ok_or(StorageError::NotFound)?,
            None => place.len(),
        };
        place.insert(at, id);
        if old_folder == folder && place == original {
            return Ok(());
        }
        sqlx::query("UPDATE saved_queries SET folder_id = ?, updated_at = ? WHERE id = ?")
            .bind(folder)
            .bind(to_unix(SystemTime::now()))
            .bind(id)
            .execute(&mut *transaction)
            .await?;
        ordering::set_query_order(&mut transaction, &place).await?;
        if old_folder != folder {
            ordering::compact_queries(&mut transaction, &owner, old_folder).await?;
        }
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn delete(&self, id: i64) -> Result<(), StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let row = sqlx::query("SELECT connection_id, folder_id FROM saved_queries WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(StorageError::NotFound)?;
        crate::query_history::trim_upgrade_copies(
            &self.path,
            &[crate::query_history::CopyDelete {
                table: "saved_queries",
                sql: "DELETE FROM main.saved_queries WHERE id = ?".to_owned(),
                binds: vec![crate::query_history::Bind::Integer(id)],
            }],
        )
        .await?;
        sqlx::query("DELETE FROM saved_queries WHERE id = ?")
            .bind(id)
            .execute(&mut *transaction)
            .await?;
        ordering::compact_queries(
            &mut transaction,
            &row.try_get::<String, _>("connection_id")?,
            row.try_get("folder_id")?,
        )
        .await?;
        transaction.commit().await?;
        self.changed();
        Ok(())
    }

    pub async fn delete_for_connection(&self, connection: Uuid) -> Result<usize, StorageError> {
        let (queries, changed) = deletion::delete_connection(&self.pool, &self.path, connection).await?;
        if changed {
            self.changed();
        }
        Ok(queries)
    }
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

fn row_to_saved_query(row: sqlx::sqlite::SqliteRow) -> Result<SavedQuery, StorageError> {
    let connection_id: String = row.try_get("connection_id")?;
    Ok(SavedQuery {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        query: row.try_get("query")?,
        connection_id: Uuid::parse_str(&connection_id).map_err(|error| StorageError::Schema(error.to_string()))?,
        connection_name: row.try_get("connection_name")?,
        keyword: row.try_get("keyword")?,
        folder_id: row.try_get("folder_id")?,
        order: row.try_get("sort_order")?,
        created_at: from_unix(row.try_get::<i64, _>("created_at")?),
        updated_at: from_unix(row.try_get::<i64, _>("updated_at")?),
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
            connection_id: connection,
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
        assert_eq!(saved.connection_id, connection);
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
        let reports = folders.create(connection, "Reports", None).await.expect("a folder");
        let monthly = folders
            .create(connection, "Monthly", Some(reports))
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
        async fn placed(store: &SavedQueries, id: i64) -> (Option<i64>, i64) {
            let query = store.get(id).await.expect("get").expect("the query");
            (query.folder_id, query.order)
        }
        assert_eq!(placed(&store, b).await, (Some(monthly), 0));
        assert_eq!(placed(&store, a).await, (Some(monthly), 1));

        assert!(matches!(
            folders.create(connection, "REPORTS", None).await,
            Err(StorageError::FolderNameTaken)
        ));
        assert!(matches!(
            folders.move_to(reports, Some(monthly)).await,
            Err(StorageError::FolderCycle { .. })
        ));
        let other = folders
            .create(Uuid::new_v4(), "Elsewhere", None)
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

        let error = store.rename(404, "new").await.expect_err("no such query");

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
                connection_id: connection,
                connection_name: "renamed".to_owned(),
            })
            .await
            .expect("save");

        assert_eq!(
            store.get(saved.id).await.expect("get").expect("saved").connection_name,
            "renamed"
        );
    }
}
