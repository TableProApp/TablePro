mod new_saved_query;
mod saved_query;

use std::time::SystemTime;

use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;
use crate::unix_time::{from_unix, to_unix};

pub use new_saved_query::NewSavedQuery;
pub use saved_query::SavedQuery;

/// What a save did, so the caller can say which.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SaveOutcome {
    pub id: i64,
    /// The name was already in use on this connection and its query
    /// was overwritten.
    pub replaced: bool,
}

/// The cap the query history puts on one entry, applied here too: a
/// saved query is the same kind of text and the same reasons apply.
const MAX_QUERY_BYTES: usize = 1024 * 1024;

/// A name long enough to be unreadable in the list is a name nobody
/// meant to type.
const MAX_NAME_CHARS: usize = 200;

/// The user's named queries. Cloning shares the pool with the query
/// history it lives beside.
#[derive(Debug, Clone)]
pub struct SavedQueries {
    pool: SqlitePool,
}

impl SavedQueries {
    pub(crate) fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Keep `query` under its name, replacing whatever that name held
    /// for this connection.
    ///
    /// Saving under a name already in use overwrites it, because that
    /// is what the user is asking for: the same report, fixed. The
    /// caller is expected to have confirmed the overwrite, which it
    /// can see coming from `list`.
    pub async fn save(&self, query: NewSavedQuery) -> Result<SaveOutcome, StorageError> {
        let name = query.name.trim();
        if name.is_empty() {
            return Err(StorageError::EmptyName);
        }
        if name.chars().count() > MAX_NAME_CHARS {
            return Err(StorageError::TooLarge {
                got: name.chars().count(),
                limit: MAX_NAME_CHARS,
            });
        }
        if query.query.len() > MAX_QUERY_BYTES {
            return Err(StorageError::TooLarge {
                got: query.query.len(),
                limit: MAX_QUERY_BYTES,
            });
        }
        let now = to_unix(SystemTime::now());
        // Asked before the write, because afterwards there is no way to
        // tell an insert from an overwrite: only one connection is ever
        // open on this pool, so nothing can slip in between.
        let replaced: bool =
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM saved_queries WHERE connection_id = ? AND name = ?")
                .bind(query.connection_id.to_string())
                .bind(name)
                .fetch_one(&self.pool)
                .await?
                > 0;
        let id = sqlx::query(
            r#"
            INSERT INTO saved_queries (name, query, connection_id, connection_name, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (connection_id, name) DO UPDATE SET
                query = excluded.query,
                connection_name = excluded.connection_name,
                updated_at = excluded.updated_at
            RETURNING id
            "#,
        )
        .bind(name)
        .bind(&query.query)
        .bind(query.connection_id.to_string())
        .bind(&query.connection_name)
        .bind(now)
        .bind(now)
        .fetch_one(&self.pool)
        .await?
        .try_get("id")?;
        Ok(SaveOutcome { id, replaced })
    }

    /// Everything saved against `connection`, or everything at all when
    /// no connection is given. Ordered by name, because the user
    /// looking for one knows what they called it.
    pub async fn list(&self, connection: Option<Uuid>) -> Result<Vec<SavedQuery>, StorageError> {
        let rows = match connection {
            Some(id) => {
                sqlx::query(
                    "SELECT id, name, query, connection_id, connection_name, created_at, updated_at \
                     FROM saved_queries WHERE connection_id = ? ORDER BY name COLLATE NOCASE, id",
                )
                .bind(id.to_string())
                .fetch_all(&self.pool)
                .await?
            }
            None => {
                sqlx::query(
                    "SELECT id, name, query, connection_id, connection_name, created_at, updated_at \
                     FROM saved_queries ORDER BY connection_name COLLATE NOCASE, name COLLATE NOCASE, id",
                )
                .fetch_all(&self.pool)
                .await?
            }
        };
        rows.into_iter().map(row_to_saved_query).collect()
    }

    pub async fn get(&self, id: i64) -> Result<Option<SavedQuery>, StorageError> {
        let row = sqlx::query(
            "SELECT id, name, query, connection_id, connection_name, created_at, updated_at \
             FROM saved_queries WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        row.map(row_to_saved_query).transpose()
    }

    /// Give a saved query a different name. Fails when the connection
    /// already has one under that name, which is the caller's cue to
    /// say so rather than silently merge two queries into one.
    pub async fn rename(&self, id: i64, name: &str) -> Result<(), StorageError> {
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
        let affected = sqlx::query("UPDATE saved_queries SET name = ?, updated_at = ? WHERE id = ?")
            .bind(name)
            .bind(to_unix(SystemTime::now()))
            .bind(id)
            .execute(&self.pool)
            .await?
            .rows_affected();
        match affected {
            0 => Err(StorageError::NotFound),
            _ => Ok(()),
        }
    }

    pub async fn delete(&self, id: i64) -> Result<(), StorageError> {
        let affected = sqlx::query("DELETE FROM saved_queries WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?
            .rows_affected();
        match affected {
            0 => Err(StorageError::NotFound),
            _ => Ok(()),
        }
    }

    /// Drop everything saved against a connection, for when the
    /// connection itself is removed. Its queries name tables only that
    /// database has.
    pub async fn delete_for_connection(&self, connection: Uuid) -> Result<usize, StorageError> {
        let affected = sqlx::query("DELETE FROM saved_queries WHERE connection_id = ?")
            .bind(connection.to_string())
            .execute(&self.pool)
            .await?
            .rows_affected();
        Ok(affected as usize)
    }
}

fn row_to_saved_query(row: sqlx::sqlite::SqliteRow) -> Result<SavedQuery, StorageError> {
    let connection_id: String = row.try_get("connection_id")?;
    Ok(SavedQuery {
        id: row.try_get("id")?,
        name: row.try_get("name")?,
        query: row.try_get("query")?,
        connection_id: Uuid::parse_str(&connection_id).unwrap_or_default(),
        connection_name: row.try_get("connection_name")?,
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

        assert!(matches!(error, StorageError::Database(_)), "{error:?}");
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
