use sqlx::SqliteConnection;

use crate::StorageError;

pub(super) async fn reconcile(database: &mut SqliteConnection) -> Result<bool, StorageError> {
    let present: i64 = sqlx::query_scalar(
        "SELECT (SELECT COUNT(*) FROM main.sqlite_master WHERE type = 'table' AND name = 'saved_query_folders') \
         * (SELECT COUNT(*) FROM live.sqlite_master WHERE type = 'table' AND name = 'saved_query_folders')",
    )
    .fetch_one(&mut *database)
    .await?;
    if present == 0 {
        return Ok(false);
    }

    // A stale parent can otherwise delete a folder that moved out, or retain one that moved in.
    // Replacing the graph also avoids transient sibling-name collisions and deep FK cascades.
    sqlx::query(
        "CREATE TEMP TABLE recovery_folders AS \
         WITH RECURSIVE kept(id) AS ( \
             SELECT old.id FROM main.saved_query_folders old \
             JOIN live.saved_query_folders live_folder ON live_folder.id = old.id \
             UNION \
             SELECT live_folder.parent_id FROM live.saved_query_folders live_folder \
             JOIN kept ON live_folder.id = kept.id WHERE live_folder.parent_id IS NOT NULL \
         ) \
         SELECT live_folder.* FROM live.saved_query_folders live_folder JOIN kept ON kept.id = live_folder.id",
    )
    .execute(&mut *database)
    .await?;
    sqlx::query("DELETE FROM main.saved_query_folders")
        .execute(&mut *database)
        .await?;
    sqlx::query(
        "INSERT INTO main.saved_query_folders (id, connection_id, name, parent_id, sort_order, created_at, updated_at) \
         SELECT id, connection_id, name, parent_id, sort_order, created_at, updated_at FROM temp.recovery_folders",
    )
    .execute(&mut *database)
    .await?;
    sqlx::query("DROP TABLE temp.recovery_folders")
        .execute(&mut *database)
        .await?;
    Ok(true)
}

pub(super) async fn repair_queries(database: &mut SqliteConnection) -> Result<(), StorageError> {
    // Deleted folders leave recoverable query text after the existing root queries.
    sqlx::query(
        "WITH promoted AS MATERIALIZED ( \
             SELECT item.id, \
                 COALESCE((SELECT MAX(root.sort_order) + 1 FROM main.saved_queries root \
                           WHERE root.connection_id = item.connection_id AND root.folder_id IS NULL), 0) \
                 + ROW_NUMBER() OVER (PARTITION BY item.connection_id ORDER BY item.folder_id, item.sort_order, item.id) - 1 \
                 AS position \
             FROM main.saved_queries item \
             WHERE item.folder_id IS NOT NULL \
               AND NOT EXISTS (SELECT 1 FROM main.saved_query_folders folder WHERE folder.id = item.folder_id) \
         ) \
         UPDATE main.saved_queries SET folder_id = NULL, sort_order = (SELECT position FROM promoted WHERE id = saved_queries.id) \
         WHERE id IN (SELECT id FROM promoted)",
    )
    .execute(&mut *database)
    .await?;
    sqlx::query(
        "WITH positions AS MATERIALIZED ( \
             SELECT id, ROW_NUMBER() OVER (PARTITION BY connection_id, folder_id ORDER BY sort_order, name COLLATE NOCASE, id) - 1 AS position \
             FROM main.saved_queries \
         ) \
         UPDATE main.saved_queries SET sort_order = (SELECT position FROM positions WHERE id = saved_queries.id)",
    )
    .execute(&mut *database)
    .await?;
    sqlx::query(
        "WITH positions AS MATERIALIZED ( \
             SELECT id, ROW_NUMBER() OVER (PARTITION BY connection_id, parent_id ORDER BY sort_order, name COLLATE NOCASE, id) - 1 AS position \
             FROM main.saved_query_folders \
         ) \
         UPDATE main.saved_query_folders SET sort_order = (SELECT position FROM positions WHERE id = saved_query_folders.id)",
    )
    .execute(&mut *database)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use sqlx::sqlite::SqliteConnectOptions;
    use sqlx::{AssertSqlSafe, ConnectOptions, Connection, SqliteConnection};
    use uuid::Uuid;

    use crate::paths::StoragePaths;
    use crate::query_history::{QueryHistory, trim_copy};
    use crate::saved_queries::NewSavedQuery;

    async fn history(root: &tempfile::TempDir) -> QueryHistory {
        QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
            .await
            .expect("open history")
    }

    async fn copy_database(path: &Path) -> SqliteConnection {
        SqliteConnectOptions::new()
            .filename(path)
            .read_only(true)
            .connect()
            .await
            .expect("open copy")
    }

    async fn save(history: &QueryHistory, name: &str, folder: Option<i64>) -> i64 {
        let store = history.saved_queries();
        let id = store
            .save(NewSavedQuery {
                name: name.to_owned(),
                query: format!("SELECT '{name}'"),
                connection_id: Uuid::nil(),
                connection_name: "local".to_owned(),
            })
            .await
            .expect("save query")
            .id;
        if folder.is_some() {
            store.move_to_folder(id, folder, None).await.expect("file query");
        }
        id
    }

    #[tokio::test]
    async fn a_copy_deletes_the_live_subtree_and_keeps_folders_that_moved_out() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let folders = history.saved_query_folders();
        let reports = folders.create(Uuid::nil(), "Reports", None).await.expect("root folder");
        let parent = folders.create(Uuid::nil(), "P", None).await.expect("parent");
        let moved_out = folders
            .create(Uuid::nil(), "Reports", Some(parent))
            .await
            .expect("nested folder with the same name");
        let moved_in = folders.create(Uuid::nil(), "Into", None).await.expect("moving folder");
        let root_query = save(&history, "root", None).await;
        let kept_query = save(&history, "kept", Some(moved_out)).await;
        let promoted_query = save(&history, "promoted", Some(moved_in)).await;
        let copy = crate::upgrade_copies::keep_database(&history.pool, &history.path, 1)
            .await
            .expect("keep copy");

        let archive = folders
            .create(Uuid::nil(), "Archive", None)
            .await
            .expect("new ancestor");
        folders.move_to(moved_out, Some(archive)).await.expect("move out");
        folders.move_to(moved_in, Some(parent)).await.expect("move in");
        folders.delete(parent).await.expect("delete the live subtree");

        let mut database = copy_database(&copy).await;
        let stored: Vec<(i64, String, Option<i64>)> =
            sqlx::query_as("SELECT id, name, parent_id FROM saved_query_folders ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("folders in copy");
        assert_eq!(
            stored,
            vec![
                (reports, "Reports".to_owned(), None),
                (moved_out, "Reports".to_owned(), Some(archive)),
                (archive, "Archive".to_owned(), None),
            ]
        );
        let queries: Vec<(i64, String, Option<i64>, i64)> =
            sqlx::query_as("SELECT id, query, folder_id, sort_order FROM saved_queries ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("queries in copy");
        assert_eq!(
            queries,
            vec![
                (root_query, "SELECT 'root'".to_owned(), None, 0),
                (kept_query, "SELECT 'kept'".to_owned(), Some(moved_out), 0),
                (promoted_query, "SELECT 'promoted'".to_owned(), None, 1),
            ]
        );
        assert!(
            sqlx::query("PRAGMA foreign_key_check")
                .fetch_optional(&mut database)
                .await
                .expect("foreign keys")
                .is_none()
        );
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_generic_sweep_keeps_a_moved_child_and_uses_its_current_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let folders = history.saved_query_folders();
        let root_folder = folders.create(Uuid::nil(), "Reports", None).await.expect("root folder");
        let parent = folders.create(Uuid::nil(), "P", None).await.expect("parent");
        let child = folders
            .create(Uuid::nil(), "Reports", Some(parent))
            .await
            .expect("child");
        let query = save(&history, "kept", Some(child)).await;
        let copy = crate::upgrade_copies::keep_database(&history.pool, &history.path, 1)
            .await
            .expect("keep copy");
        folders.rename(root_folder, "Renamed").await.expect("rename root");
        folders.move_to(child, None).await.expect("reuse the former root name");
        sqlx::query("DELETE FROM saved_query_folders WHERE id = ?")
            .bind(parent)
            .execute(&history.pool)
            .await
            .expect("simulate a prior committed deletion");

        let mut live = history.pool.acquire().await.expect("live connection");
        let transaction = live
            .begin_with(AssertSqlSafe("BEGIN IMMEDIATE"))
            .await
            .expect("hold the live graph");
        trim_copy(&copy, history.path.to_str().expect("UTF-8 path"), &[])
            .await
            .expect("trim copy");
        transaction.commit().await.expect("release live graph");

        let mut database = copy_database(&copy).await;
        let stored: Vec<(i64, String, Option<i64>)> =
            sqlx::query_as("SELECT id, name, parent_id FROM saved_query_folders ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("folders");
        assert_eq!(
            stored,
            vec![
                (root_folder, "Renamed".to_owned(), None),
                (child, "Reports".to_owned(), None)
            ]
        );
        let held: Option<i64> = sqlx::query_scalar("SELECT folder_id FROM saved_queries WHERE id = ?")
            .bind(query)
            .fetch_one(&mut database)
            .await
            .expect("query folder");
        assert_eq!(held, Some(child));
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_copy_can_remove_more_folders_than_the_sqlite_cascade_limit() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let mut transaction = history.pool.begin().await.expect("begin fixture");
        let mut parent = None;
        let mut first = None;
        for _ in 0..1_100 {
            let id = sqlx::query(
                "INSERT INTO saved_query_folders (connection_id, name, parent_id, sort_order, created_at, updated_at) \
                 VALUES (?, 'Nested', ?, 0, 1, 1)",
            )
            .bind(Uuid::nil().to_string())
            .bind(parent)
            .execute(&mut *transaction)
            .await
            .expect("insert folder")
            .last_insert_rowid();
            first.get_or_insert(id);
            parent = Some(id);
        }
        transaction.commit().await.expect("commit fixture");
        let query = save(&history, "deep", parent).await;
        let copy = crate::upgrade_copies::keep_database(&history.pool, &history.path, 1)
            .await
            .expect("keep copy");
        history
            .saved_query_folders()
            .delete(first.expect("first folder"))
            .await
            .expect("delete deep subtree");

        let mut database = copy_database(&copy).await;
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM saved_query_folders")
            .fetch_one(&mut database)
            .await
            .expect("folder count");
        assert_eq!(count, 0);
        let stored: (String, Option<i64>, i64) =
            sqlx::query_as("SELECT query, folder_id, sort_order FROM saved_queries WHERE id = ?")
                .bind(query)
                .fetch_one(&mut database)
                .await
                .expect("recoverable query");
        assert_eq!(stored, ("SELECT 'deep'".to_owned(), None, 0));
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_copy_from_before_folders_still_trims_saved_queries() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let kept = save(&history, "kept", None).await;
        let copy = root.path().join("legacy.sqlite3");
        let mut database = SqliteConnectOptions::new()
            .filename(&copy)
            .create_if_missing(true)
            .connect()
            .await
            .expect("create legacy copy");
        sqlx::raw_sql(include_str!("../../migrations/20260914000000_create_history.sql"))
            .execute(&mut database)
            .await
            .expect("legacy schema");
        for (id, name) in [(kept, "kept"), (kept + 1, "deleted")] {
            sqlx::query(
                "INSERT INTO saved_queries (id, name, query, connection_id, connection_name, created_at, updated_at) \
                 VALUES (?, ?, 'SELECT 1', ?, 'local', 1, 1)",
            )
            .bind(id)
            .bind(name)
            .bind(Uuid::nil().to_string())
            .execute(&mut database)
            .await
            .expect("legacy query");
        }
        database.close().await.expect("close fixture");
        trim_copy(&copy, history.path.to_str().expect("UTF-8 path"), &[])
            .await
            .expect("trim legacy copy");
        let mut database = copy_database(&copy).await;
        let names: Vec<String> = sqlx::query_scalar("SELECT name FROM saved_queries")
            .fetch_all(&mut database)
            .await
            .expect("remaining queries");
        assert_eq!(names, ["kept"]);
        database.close().await.expect("close copy");
    }
}
