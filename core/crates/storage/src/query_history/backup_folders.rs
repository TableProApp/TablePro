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
    // A copy with record ids has no foreign keys, so deleting by rowid leaves the rest of it whole.
    let integer_parents: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM pragma_table_info('saved_query_folders', 'main') WHERE name = 'parent_id'")
            .fetch_one(&mut *database)
            .await?;
    if integer_parents == 0 {
        return Ok(false);
    }

    // A stale parent can otherwise delete a folder that moved out, or retain one that moved in.
    // Replacing the graph also avoids transient sibling-name collisions and deep FK cascades. The copy's
    // format names a parent by its rowid, keeps seconds and has no folder in every connection.
    sqlx::query(
        "CREATE TEMP TABLE recovery_folders AS \
         WITH RECURSIVE kept(id) AS ( \
             SELECT old.id FROM main.saved_query_folders old \
             JOIN live.saved_query_folders live_folder ON live_folder.id = old.id \
             WHERE live_folder.connection_id IS NOT NULL \
             UNION \
             SELECT parent.id FROM live.saved_query_folders live_folder \
             JOIN kept ON live_folder.id = kept.id \
             JOIN live.saved_query_folders parent ON parent.record_id = live_folder.parent_record_id \
             WHERE parent.connection_id IS NOT NULL \
         ) \
         SELECT live_folder.id, live_folder.connection_id, live_folder.name, \
             (SELECT parent.id FROM live.saved_query_folders parent JOIN kept ON kept.id = parent.id \
              WHERE parent.record_id = live_folder.parent_record_id) AS parent_id, \
             live_folder.sort_order, live_folder.created_at / 1000 AS created_at, \
             live_folder.updated_at / 1000 AS updated_at \
         FROM live.saved_query_folders live_folder JOIN kept ON kept.id = live_folder.id",
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
    use sqlx::{AssertSqlSafe, ConnectOptions, Connection, SqliteConnection, SqlitePool};
    use uuid::Uuid;

    use crate::paths::StoragePaths;
    use crate::query_history::fixtures::{BETA_5, old_database};
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

    async fn save(history: &QueryHistory, name: &str, folder: Option<Uuid>) -> Uuid {
        let store = history.saved_queries();
        let id = store
            .save(NewSavedQuery {
                name: name.to_owned(),
                query: format!("SELECT '{name}'"),
                connection_id: Some(Uuid::nil()),
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

    async fn rowid(history: &QueryHistory, table: &str, id: Uuid) -> i64 {
        sqlx::query_scalar(AssertSqlSafe(format!("SELECT id FROM {table} WHERE record_id = ?")))
            .bind(id.to_string())
            .fetch_one(&history.pool)
            .await
            .expect("rowid")
    }

    async fn record_id(history: &QueryHistory, table: &str, rowid: i64) -> Uuid {
        let id: String = sqlx::query_scalar(AssertSqlSafe(format!("SELECT record_id FROM {table} WHERE id = ?")))
            .bind(rowid)
            .fetch_one(&history.pool)
            .await
            .expect("record id");
        Uuid::parse_str(&id).expect("a UUID")
    }

    async fn beta_folders(pool: &SqlitePool, folders: &[(i64, &str, Option<i64>)]) {
        for (id, name, parent) in folders {
            sqlx::query(
                "INSERT INTO saved_query_folders (id, connection_id, name, parent_id, sort_order, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, 0, 21, 22)",
            )
            .bind(id)
            .bind(Uuid::nil().to_string())
            .bind(name)
            .bind(parent)
            .execute(pool)
            .await
            .expect("folder fixture");
        }
    }

    async fn beta_queries(pool: &SqlitePool, queries: &[(i64, &str, Option<i64>, i64)]) {
        for (id, name, folder, order) in queries {
            sqlx::query(
                "INSERT INTO saved_queries (id, name, query, connection_id, connection_name, folder_id, sort_order, \
                 created_at, updated_at) VALUES (?, ?, ?, ?, 'local', ?, ?, 11, 12)",
            )
            .bind(id)
            .bind(name)
            .bind(format!("SELECT '{name}'"))
            .bind(Uuid::nil().to_string())
            .bind(folder)
            .bind(order)
            .execute(pool)
            .await
            .expect("query fixture");
        }
    }

    // The copy the upgrade keeps of a database a Linux beta wrote, in that beta's format.
    async fn upgraded_beta(
        root: &tempfile::TempDir,
        folders: &[(i64, &str, Option<i64>)],
        queries: &[(i64, &str, Option<i64>, i64)],
    ) -> (QueryHistory, std::path::PathBuf) {
        let (paths, pool) = old_database(root, BETA_5).await;
        beta_folders(&pool, folders).await;
        beta_queries(&pool, queries).await;
        pool.close().await;
        let history = QueryHistory::open(&paths).await.expect("upgrade");
        let copies = crate::upgrade_copies::copies_blocking(&history.path).expect("copies");
        assert_eq!(copies.len(), 1, "the upgrade kept no copy");
        let copy = copies[0].path.clone();
        (history, copy)
    }

    #[tokio::test]
    async fn a_beta_copy_deletes_the_live_subtree_and_keeps_folders_that_moved_out() {
        let root = tempfile::tempdir().expect("tempdir");
        let (history, copy) = upgraded_beta(
            &root,
            &[(1, "Reports", None), (2, "P", None), (3, "Reports", Some(2)), (4, "Into", None)],
            &[(10, "root", None, 0), (11, "kept", Some(3), 0), (12, "promoted", Some(4), 0)],
        )
        .await;
        let folders = history.saved_query_folders();
        let (parent, moved_out, moved_in) = (
            record_id(&history, "saved_query_folders", 2).await,
            record_id(&history, "saved_query_folders", 3).await,
            record_id(&history, "saved_query_folders", 4).await,
        );

        let archive = folders
            .create(Some(Uuid::nil()), "Archive", None)
            .await
            .expect("new ancestor");
        folders.move_to(moved_out, Some(archive)).await.expect("move out");
        folders.move_to(moved_in, Some(parent)).await.expect("move in");
        folders.delete(parent).await.expect("delete the live subtree");

        let archive = rowid(&history, "saved_query_folders", archive).await;
        let mut database = copy_database(&copy).await;
        let stored: Vec<(i64, String, Option<i64>)> =
            sqlx::query_as("SELECT id, name, parent_id FROM saved_query_folders ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("folders in copy");
        assert_eq!(
            stored,
            vec![
                (1, "Reports".to_owned(), None),
                (3, "Reports".to_owned(), Some(archive)),
                (archive, "Archive".to_owned(), None),
            ]
        );
        let times: (i64, i64) = sqlx::query_as("SELECT created_at, updated_at FROM saved_query_folders WHERE id = 1")
            .fetch_one(&mut database)
            .await
            .expect("times in copy");
        assert_eq!(times, (21, 22), "the copy's format keeps seconds");
        let queries: Vec<(i64, String, Option<i64>, i64)> =
            sqlx::query_as("SELECT id, query, folder_id, sort_order FROM saved_queries ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("queries in copy");
        assert_eq!(
            queries,
            vec![
                (10, "SELECT 'root'".to_owned(), None, 0),
                (11, "SELECT 'kept'".to_owned(), Some(3), 0),
                (12, "SELECT 'promoted'".to_owned(), None, 1),
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
    async fn a_generic_sweep_of_a_beta_copy_keeps_a_moved_child_and_uses_its_current_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let (history, copy) = upgraded_beta(
            &root,
            &[(1, "Reports", None), (2, "P", None), (3, "Reports", Some(2))],
            &[(10, "kept", Some(3), 0)],
        )
        .await;
        let folders = history.saved_query_folders();
        let (root_folder, child) = (
            record_id(&history, "saved_query_folders", 1).await,
            record_id(&history, "saved_query_folders", 3).await,
        );
        folders.rename(root_folder, "Renamed").await.expect("rename root");
        folders.move_to(child, None).await.expect("reuse the former root name");
        sqlx::query("DELETE FROM saved_query_folders WHERE id = 2")
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
            vec![(1, "Renamed".to_owned(), None), (3, "Reports".to_owned(), None)]
        );
        let held: Option<i64> = sqlx::query_scalar("SELECT folder_id FROM saved_queries WHERE id = 10")
            .fetch_one(&mut database)
            .await
            .expect("query folder");
        assert_eq!(held, Some(3));
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_beta_copy_leaves_out_a_folder_in_every_connection_its_format_cannot_hold() {
        let root = tempfile::tempdir().expect("tempdir");
        let (history, copy) = upgraded_beta(&root, &[(1, "Reports", None)], &[(10, "kept", Some(1), 0)]).await;
        let reports = record_id(&history, "saved_query_folders", 1).await;
        let everywhere = Uuid::new_v4();
        history
            .saved_query_folders()
            .put(&[crate::saved_queries::SavedQueryFolder {
                id: everywhere,
                connection_id: None,
                name: "Shared".to_owned(),
                parent_id: None,
                order: 0,
                created_at: std::time::SystemTime::UNIX_EPOCH,
                updated_at: std::time::SystemTime::UNIX_EPOCH,
            }])
            .await
            .expect("a pulled folder");
        sqlx::query("UPDATE saved_query_folders SET parent_record_id = ? WHERE record_id = ?")
            .bind(everywhere.to_string())
            .bind(reports.to_string())
            .execute(&history.pool)
            .await
            .expect("file it under the shared folder");

        trim_copy(&copy, history.path.to_str().expect("UTF-8 path"), &[])
            .await
            .expect("trim copy");

        let mut database = copy_database(&copy).await;
        let stored: Vec<(i64, String, Option<i64>)> =
            sqlx::query_as("SELECT id, name, parent_id FROM saved_query_folders ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("folders");
        assert_eq!(stored, vec![(1, "Reports".to_owned(), None)]);
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_beta_copy_can_remove_more_folders_than_the_sqlite_cascade_limit() {
        let root = tempfile::tempdir().expect("tempdir");
        let nested: Vec<(i64, String, Option<i64>)> = (1..=1_100)
            .map(|id| (id, "Nested".to_owned(), (id > 1).then(|| id - 1)))
            .collect();
        let folders: Vec<(i64, &str, Option<i64>)> = nested
            .iter()
            .map(|(id, name, parent)| (*id, name.as_str(), *parent))
            .collect();
        let (history, copy) = upgraded_beta(&root, &folders, &[(10, "deep", Some(1_100), 0)]).await;
        let first = record_id(&history, "saved_query_folders", 1).await;

        history
            .saved_query_folders()
            .delete(first)
            .await
            .expect("delete deep subtree");

        let mut database = copy_database(&copy).await;
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM saved_query_folders")
            .fetch_one(&mut database)
            .await
            .expect("folder count");
        assert_eq!(count, 0);
        let stored: (String, Option<i64>, i64) =
            sqlx::query_as("SELECT query, folder_id, sort_order FROM saved_queries WHERE id = 10")
                .fetch_one(&mut database)
                .await
                .expect("recoverable query");
        assert_eq!(stored, ("SELECT 'deep'".to_owned(), None, 0));
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_copy_with_record_ids_loses_the_deleted_subtree_by_rowid_and_keeps_what_moved_out() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let folders = history.saved_query_folders();
        let parent = folders.create(Some(Uuid::nil()), "P", None).await.expect("parent");
        let child = folders
            .create(Some(Uuid::nil()), "Child", Some(parent))
            .await
            .expect("child");
        let moved_out = folders
            .create(Some(Uuid::nil()), "Moved", Some(parent))
            .await
            .expect("moving folder");
        let kept = save(&history, "kept", Some(moved_out)).await;
        let filed = save(&history, "filed", Some(child)).await;
        let copy = crate::upgrade_copies::keep_database(&history.pool, &history.path, 4)
            .await
            .expect("keep copy");

        folders.move_to(moved_out, None).await.expect("move out");
        folders.delete(parent).await.expect("delete the subtree");

        let mut database = copy_database(&copy).await;
        let stored: Vec<String> = sqlx::query_scalar("SELECT record_id FROM saved_query_folders ORDER BY id")
            .fetch_all(&mut database)
            .await
            .expect("folders in copy");
        assert_eq!(stored, [moved_out.to_string()]);
        let queries: Vec<(String, Option<String>)> =
            sqlx::query_as("SELECT record_id, folder_record_id FROM saved_queries ORDER BY id")
                .fetch_all(&mut database)
                .await
                .expect("queries in copy");
        assert_eq!(
            queries,
            [
                (kept.to_string(), Some(moved_out.to_string())),
                (filed.to_string(), Some(child.to_string()))
            ],
            "the copy keeps its queries as they were when it was made"
        );
        database.close().await.expect("close copy");
    }

    #[tokio::test]
    async fn a_copy_from_before_folders_still_trims_saved_queries() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let kept = save(&history, "kept", None).await;
        let kept = rowid(&history, "saved_queries", kept).await;
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
