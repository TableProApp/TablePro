use super::*;
use crate::unix_time::from_unix;

async fn old_database(root: &tempfile::TempDir, migrations: usize) -> (StoragePaths, SqlitePool) {
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    crate::fs::create_private_file_if_missing(&paths.history_database()).expect("file");
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(paths.history_database())
                .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal),
        )
        .await
        .expect("pool");
    sqlx::migrate::Migrator::with_migrations(schema::MIGRATOR.iter().take(migrations).cloned().collect())
        .run(&pool)
        .await
        .expect("old migrations");
    (paths, pool)
}

async fn insert_queries(pool: &SqlitePool, connection: Uuid, other: Uuid) {
    for (id, owner, name) in [(42, connection, "z"), (9, connection, "A"), (51, other, "other")] {
        sqlx::query(
            "INSERT INTO saved_queries (id, name, query, connection_id, connection_name, created_at, updated_at) \
             VALUES (?, ?, 'SELECT 42', ?, 'Original connection', 11, 12)",
        )
        .bind(id)
        .bind(name)
        .bind(owner.to_string())
        .execute(pool)
        .await
        .expect("saved query fixture");
    }
}

async fn assert_copy_kept(paths: &StoragePaths, migrations: i64) -> sqlx::SqliteConnection {
    let copies = crate::upgrade_copies::copies_blocking(&paths.history_database()).expect("copies");
    assert_eq!(copies.len(), 1);
    let mut copy = SqliteConnectOptions::new()
        .filename(&copies[0].path)
        .read_only(true)
        .connect()
        .await
        .expect("open copy");
    let applied: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations")
        .fetch_one(&mut copy)
        .await
        .expect("copy migration count");
    assert_eq!(applied, migrations);
    let ids: Vec<i64> = sqlx::query_scalar("SELECT id FROM saved_queries ORDER BY id")
        .fetch_all(&mut copy)
        .await
        .expect("copy queries");
    assert_eq!(ids, [9, 42, 51]);
    copy
}

#[tokio::test]
async fn original_schema_upgrade_preserves_queries_and_assigns_connection_scoped_order() {
    let root = tempfile::tempdir().expect("tempdir");
    let (paths, pool) = old_database(&root, 1).await;
    let connection = Uuid::new_v4();
    let other = Uuid::new_v4();
    insert_queries(&pool, connection, other).await;
    pool.close().await;

    let history = QueryHistory::open(&paths).await.expect("upgrade");
    let queries = history.saved_queries().list(Some(connection)).await.expect("queries");
    assert_eq!(
        queries.iter().map(|query| (query.id, query.order)).collect::<Vec<_>>(),
        [(9, 0), (42, 1)]
    );
    for query in &queries {
        assert_eq!(query.query, "SELECT 42");
        assert_eq!(query.connection_name, "Original connection");
        assert_eq!(query.created_at, from_unix(11));
        assert_eq!(query.updated_at, from_unix(12));
        assert_eq!(query.keyword, None);
        assert_eq!(query.folder_id, None);
    }
    let other = history
        .saved_queries()
        .list(Some(other))
        .await
        .expect("other connection");
    assert_eq!(other.len(), 1);
    assert_eq!((other[0].id, other[0].order), (51, 0));
    assert_copy_kept(&paths, 1).await.close().await.expect("close copy");
}

async fn insert_favorites(pool: &SqlitePool, connection: Uuid, other: Uuid) {
    for (id, owner, name, parent, order) in [
        (1, connection, "Reports", None, 8),
        (2, connection, "Archive", None, 2),
        (3, connection, "Monthly", Some(1), 8),
        (4, other, "Other", None, 8),
    ] {
        sqlx::query(
            "INSERT INTO saved_query_folders (id, connection_id, name, parent_id, sort_order, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, 21, 22)",
        )
        .bind(id)
        .bind(owner.to_string())
        .bind(name)
        .bind(parent)
        .bind(order)
        .execute(pool)
        .await
        .expect("folder fixture");
    }
    sqlx::query("UPDATE saved_queries SET folder_id = 3, keyword = 'daily', sort_order = 9 WHERE id = 42")
        .execute(pool)
        .await
        .expect("file query");
    sqlx::query("UPDATE saved_queries SET sort_order = 4 WHERE id <> 42")
        .execute(pool)
        .await
        .expect("root query orders");
    sqlx::query("INSERT INTO favourite_tables (connection_id, database, schema, name, created_at) VALUES (?, 'shop', 'public', 'orders', 31)")
        .bind(connection.to_string()).execute(pool).await.expect("table fixture");
    sqlx::query("INSERT INTO favourite_databases (connection_id, database, environment, created_at) VALUES (?, 'shop', 'production', 32)")
        .bind(connection.to_string()).execute(pool).await.expect("database fixture");
}

#[tokio::test]
async fn favorites_schema_upgrade_preserves_filing_and_metadata_and_normalizes_positions() {
    let root = tempfile::tempdir().expect("tempdir");
    let (paths, pool) = old_database(&root, 2).await;
    let connection = Uuid::new_v4();
    let other = Uuid::new_v4();
    insert_queries(&pool, connection, other).await;
    insert_favorites(&pool, connection, other).await;
    pool.close().await;

    let history = QueryHistory::open(&paths).await.expect("upgrade");
    let snapshot = history.saved_queries().snapshot(connection).await.expect("snapshot");
    let filed = snapshot
        .queries
        .iter()
        .find(|query| query.id == 42)
        .expect("filed query");
    assert_eq!(
        (filed.folder_id, filed.keyword.as_deref(), filed.order),
        (Some(3), Some("daily"), 0)
    );
    assert_eq!(filed.query, "SELECT 42");
    assert_eq!(filed.connection_name, "Original connection");
    assert_eq!(filed.created_at, from_unix(11));
    assert_eq!(filed.updated_at, from_unix(12));
    let root_query = snapshot.queries.iter().find(|query| query.id == 9).expect("root query");
    assert_eq!((root_query.folder_id, root_query.order), (None, 0));
    for (id, parent, order) in [(1, None, 1), (2, None, 0), (3, Some(1), 0)] {
        let folder = snapshot.folders.iter().find(|folder| folder.id == id).expect("folder");
        assert_eq!((folder.parent_id, folder.order), (parent, order));
        assert_eq!(folder.created_at, from_unix(21));
        assert_eq!(folder.updated_at, from_unix(22));
    }
    let other = history.saved_queries().snapshot(other).await.expect("other connection");
    assert_eq!((other.queries[0].id, other.queries[0].order), (51, 0));
    assert_eq!((other.folders[0].id, other.folders[0].order), (4, 0));
    assert_eq!(
        history.favourites().tables(connection).await.expect("tables")[0].name,
        "orders"
    );
    assert_eq!(
        history.favourites().databases(connection).await.expect("databases")[0].environment,
        crate::DatabaseEnvironment::Production
    );

    let mut copy = assert_copy_kept(&paths, 2).await;
    let original: (Option<i64>, Option<String>, i64) =
        sqlx::query_as("SELECT folder_id, keyword, sort_order FROM saved_queries WHERE id = 42")
            .fetch_one(&mut copy)
            .await
            .expect("original query metadata");
    assert_eq!(original, (Some(3), Some("daily".to_owned()), 9));
    let original_order: i64 = sqlx::query_scalar("SELECT sort_order FROM saved_query_folders WHERE id = 1")
        .fetch_one(&mut copy)
        .await
        .expect("original folder order");
    assert_eq!(original_order, 8);
    copy.close().await.expect("close copy");
}
