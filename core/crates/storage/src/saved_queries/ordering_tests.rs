use super::*;
use crate::{DatabaseEnvironment, FavouriteTable, QueryHistory, StoragePaths};

fn paths(root: &tempfile::TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
}

fn query(connection: Uuid, name: &str) -> NewSavedQuery {
    NewSavedQuery {
        name: name.to_owned(),
        query: format!("SELECT '{name}'"),
        connection_id: connection,
        connection_name: "local".to_owned(),
    }
}

async fn save(store: &SavedQueries, connection: Uuid, name: &str) -> i64 {
    store.save(query(connection, name)).await.expect("save").id
}

async fn order(store: &SavedQueries, connection: Uuid, folder: Option<i64>) -> Vec<i64> {
    let mut rows = store.list(Some(connection)).await.expect("list");
    rows.retain(|row| row.folder_id == folder);
    rows.sort_by_key(|row| row.order);
    assert_eq!(
        rows.iter().map(|row| row.order).collect::<Vec<_>>(),
        (0..i64::try_from(rows.len()).expect("row count")).collect::<Vec<_>>()
    );
    rows.into_iter().map(|row| row.id).collect()
}

#[tokio::test]
async fn new_saves_append_and_replacement_keeps_identity_and_filing() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let store = history.saved_queries();
    let connection = Uuid::new_v4();
    let z = save(&store, connection, "z").await;
    let a = store
        .save_if_new(query(connection, "a"))
        .await
        .expect("import")
        .expect("inserted");
    let m = save(&store, connection, "m").await;
    assert_eq!(order(&store, connection, None).await, [z, a, m]);
    assert_eq!(
        store.save_if_new(query(connection, "a")).await.expect("repeat import"),
        None
    );
    let folder = history
        .saved_query_folders()
        .create(connection, "Reports", None)
        .await
        .expect("folder");
    store.move_to_folder(a, Some(folder), None).await.expect("file");
    store.set_keyword(a, Some("daily")).await.expect("keyword");
    let before = store.get(a).await.expect("get").expect("query");
    let mut replacement = query(connection, "a");
    replacement.query = "SELECT 42".to_owned();
    replacement.connection_name = "renamed connection".to_owned();
    let replaced = store.save(replacement).await.expect("replace");
    assert_eq!(replaced, SaveOutcome { id: a, replaced: true });
    let after = store.get(a).await.expect("get").expect("query");
    assert_eq!(
        (after.id, after.keyword, after.folder_id, after.order, after.created_at),
        (
            before.id,
            before.keyword,
            before.folder_id,
            before.order,
            before.created_at
        )
    );
    assert_eq!(after.query, "SELECT 42");
    assert_eq!(after.connection_name, "renamed connection");
    let b = save(&store, connection, "b").await;
    assert_eq!(order(&store, connection, None).await, [z, m, b]);
    assert_eq!(order(&store, connection, Some(folder)).await, [a]);
}

#[tokio::test]
async fn moving_and_deleting_queries_compacts_only_their_connection_and_place() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let store = history.saved_queries();
    let connection = Uuid::new_v4();
    let other = Uuid::new_v4();
    let other_z = save(&store, other, "z").await;
    let other_a = save(&store, other, "a").await;
    let a = save(&store, connection, "a").await;
    let b = save(&store, connection, "b").await;
    let c = save(&store, connection, "c").await;
    let folder = history
        .saved_query_folders()
        .create(connection, "Reports", None)
        .await
        .expect("folder");
    store.move_to_folder(b, Some(folder), None).await.expect("file b");
    assert_eq!(order(&store, connection, None).await, [a, c]);
    store
        .move_to_folder(c, Some(folder), Some(b))
        .await
        .expect("file c before b");
    assert_eq!(order(&store, connection, Some(folder)).await, [c, b]);
    store.move_to_folder(c, None, Some(a)).await.expect("move c to root");
    assert_eq!(order(&store, connection, None).await, [c, a]);
    assert_eq!(order(&store, connection, Some(folder)).await, [b]);
    assert_eq!(order(&store, other, None).await, [other_z, other_a]);
    store.delete(c).await.expect("delete c");
    assert_eq!(order(&store, connection, None).await, [a]);
    assert_eq!(order(&store, other, None).await, [other_z, other_a]);
}

#[tokio::test]
async fn invalid_destinations_and_self_before_leave_rows_and_revisions_alone() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let store = history.saved_queries();
    let connection = Uuid::new_v4();
    let a = save(&store, connection, "a").await;
    let b = save(&store, connection, "b").await;
    let other = save(&store, Uuid::new_v4(), "other").await;
    let folder = history
        .saved_query_folders()
        .create(connection, "Reports", None)
        .await
        .expect("folder");
    let before = store.snapshot(connection).await.expect("snapshot");
    let changes = store.changes();
    store.move_to_folder(a, None, Some(a)).await.expect("self-before no-op");
    store.move_to_folder(b, None, None).await.expect("already last");
    for (destination, before) in [(None, other), (Some(folder), a), (None, i64::MAX)] {
        assert!(matches!(
            store.move_to_folder(a, destination, Some(before)).await,
            Err(StorageError::NotFound)
        ));
    }
    assert!(!changes.has_changed().expect("no revision"));
    assert_eq!(store.snapshot(connection).await.expect("snapshot"), before);
}

#[tokio::test]
async fn unicode_keywords_share_one_key_even_when_separate_handles_write_together() {
    let root = tempfile::tempdir().expect("tempdir");
    let first = QueryHistory::open(&paths(&root)).await.expect("first handle");
    let second = QueryHistory::open(&paths(&root)).await.expect("second handle");
    let first = first.saved_queries();
    let second = second.saved_queries();
    let connection = Uuid::new_v4();
    let a = save(&first, connection, "a").await;
    let b = save(&first, connection, "b").await;
    let (left, right) = tokio::join!(
        first.set_keyword(a, Some("État")),
        second.set_keyword(b, Some("e\u{301}tat"))
    );
    assert!(matches!(
        (&left, &right),
        (Ok(()), Err(StorageError::KeywordTaken)) | (Err(StorageError::KeywordTaken), Ok(()))
    ));
    let held = first.list(Some(connection)).await.expect("list");
    assert_eq!(held.iter().filter(|row| row.keyword.is_some()).count(), 1);
    first.set_keyword(a, None).await.expect("clear");
    second.set_keyword(b, None).await.expect("clear");
    first.set_keyword(a, Some("e\u{301}tat")).await.expect("canonicalize");
    assert_eq!(
        first.get(a).await.expect("get").expect("query").keyword.as_deref(),
        Some("état")
    );
    assert!(matches!(
        second.set_keyword(b, Some("ÉTAT")).await,
        Err(StorageError::KeywordTaken)
    ));
    let other = save(&second, Uuid::new_v4(), "other").await;
    second.set_keyword(other, Some("ÉTAT")).await.expect("other connection");
}

#[tokio::test]
async fn snapshots_never_return_a_query_whose_folder_was_read_from_another_generation() {
    let root = tempfile::tempdir().expect("tempdir");
    let writer = QueryHistory::open(&paths(&root)).await.expect("writer");
    let reader = QueryHistory::open(&paths(&root)).await.expect("reader");
    let connection = Uuid::new_v4();
    let id = save(&writer.saved_queries(), connection, "report").await;
    let change = async {
        for index in 0..40 {
            let folder = writer
                .saved_query_folders()
                .create(connection, &format!("Folder {index}"), None)
                .await
                .expect("create");
            writer
                .saved_queries()
                .move_to_folder(id, Some(folder), None)
                .await
                .expect("file");
            writer.saved_query_folders().delete(folder).await.expect("delete");
        }
    };
    let read = async {
        for _ in 0..160 {
            let snapshot = reader.saved_queries().snapshot(connection).await.expect("snapshot");
            assert_eq!(snapshot.queries.len(), 1);
            for query in snapshot.queries {
                assert!(
                    query
                        .folder_id
                        .is_none_or(|id| snapshot.folders.iter().any(|folder| folder.id == id))
                );
            }
        }
    };
    tokio::join!(change, read);
}

#[tokio::test]
async fn mutation_notifications_are_shared_and_follow_successful_changes() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let store = history.saved_queries();
    let connection = Uuid::new_v4();
    let id = save(&store, connection, "report").await;
    let mut changes = store.changes();
    let mut folders_changed = history.saved_query_folders().changes();
    let mut catalog_changed = history.favourites().changes();
    store.set_keyword(id, Some("daily")).await.expect("keyword");
    assert!(changes.has_changed().expect("revision"));
    assert!(folders_changed.has_changed().expect("shared revision"));
    assert!(catalog_changed.has_changed().expect("shared revision"));
    changes.borrow_and_update();
    folders_changed.borrow_and_update();
    catalog_changed.borrow_and_update();
    store.set_keyword(id, Some("daily")).await.expect("same keyword");
    store.rename(id, "report").await.expect("same name");
    assert_eq!(
        store
            .save_if_new(query(connection, "report"))
            .await
            .expect("same import"),
        None
    );
    assert!(matches!(
        store.set_keyword(id, Some("two words")).await,
        Err(StorageError::KeywordInvalid { .. })
    ));
    assert!(!changes.has_changed().expect("no revision"));
    assert!(!folders_changed.has_changed().expect("no shared revision"));
    assert!(!catalog_changed.has_changed().expect("no shared revision"));
}

#[tokio::test]
async fn a_failed_connection_purge_preserves_every_kind_of_favorite_and_its_revision() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let store = history.saved_queries();
    let folders = history.saved_query_folders();
    let favourites = history.favourites();
    let connection = Uuid::new_v4();
    let id = save(&store, connection, "report").await;
    let folder = folders.create(connection, "Reports", None).await.expect("folder");
    store.move_to_folder(id, Some(folder), None).await.expect("file");
    let table = FavouriteTable {
        connection_id: connection,
        database: None,
        schema: None,
        name: "orders".to_owned(),
    };
    favourites.add_table(&table).await.expect("table");
    favourites
        .set_database(connection, "shop", DatabaseEnvironment::Production)
        .await
        .expect("database");
    let before = store.snapshot(connection).await.expect("snapshot");
    sqlx::query(
        "CREATE TRIGGER reject_purge BEFORE DELETE ON favourite_databases BEGIN SELECT RAISE(ABORT, 'denied'); END",
    )
    .execute(&store.pool)
    .await
    .expect("install failure");
    let changes = store.changes();
    assert!(store.delete_for_connection(connection).await.is_err());
    assert_eq!(store.snapshot(connection).await.expect("snapshot"), before);
    assert_eq!(favourites.tables(connection).await.expect("tables"), vec![table]);
    assert_eq!(favourites.databases(connection).await.expect("databases").len(), 1);
    assert!(!changes.has_changed().expect("no revision"));
    sqlx::query("DROP TRIGGER reject_purge")
        .execute(&store.pool)
        .await
        .expect("remove failure");
    assert_eq!(store.delete_for_connection(connection).await.expect("purge"), 1);
    assert!(changes.has_changed().expect("revision"));
    let after = store.snapshot(connection).await.expect("snapshot");
    assert!(after.queries.is_empty());
    assert!(after.folders.is_empty());
    assert!(favourites.tables(connection).await.expect("tables").is_empty());
    assert!(favourites.databases(connection).await.expect("databases").is_empty());
}

#[tokio::test]
async fn assigning_the_same_folder_preserves_position_and_revision() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let store = history.saved_queries();
    let connection = Uuid::new_v4();
    let a = save(&store, connection, "a").await;
    let b = save(&store, connection, "b").await;
    let folder = history
        .saved_query_folders()
        .create(connection, "Reports", None)
        .await
        .expect("folder");
    store.set_folder(a, Some(folder)).await.expect("file a");
    store.set_folder(b, Some(folder)).await.expect("file b");
    let changes = store.changes();
    store.set_folder(a, Some(folder)).await.expect("same folder");
    assert_eq!(order(&store, connection, Some(folder)).await, [a, b]);
    assert!(!changes.has_changed().expect("no revision"));
    store.set_folder(a, None).await.expect("move to root");
    assert_eq!(order(&store, connection, None).await, [a]);
    assert_eq!(order(&store, connection, Some(folder)).await, [b]);
    assert!(changes.has_changed().expect("revision"));
}
