use super::*;
use crate::paths::StoragePaths;
use crate::query_history::QueryHistory;

async fn history(root: &tempfile::TempDir) -> QueryHistory {
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    QueryHistory::open(&paths).await.expect("open history")
}

fn places(folders: &[SavedQueryFolder], parent: Option<i64>) -> Vec<(i64, i64)> {
    folders
        .iter()
        .filter(|folder| folder.parent_id == parent)
        .map(|folder| (folder.id, folder.order))
        .collect()
}

#[tokio::test]
async fn folder_names_are_visible_normalized_and_unique_within_their_parent() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let folders = history.saved_query_folders();
    let connection = Uuid::new_v4();
    let reports = folders
        .create(connection, "  E\u{301}tat\u{200b}  ", None)
        .await
        .expect("normalized folder");
    assert_eq!(folders.list(connection).await.expect("list")[0].name, "État");
    assert!(matches!(
        folders.create(connection, "état", None).await,
        Err(StorageError::FolderNameTaken)
    ));
    folders
        .create(connection, "état", Some(reports))
        .await
        .expect("same name in another parent");
    folders
        .create(Uuid::new_v4(), "état", None)
        .await
        .expect("same name on another connection");
    for name in ["", " \t ", "\u{200b}"] {
        assert!(matches!(
            folders.create(connection, name, None).await,
            Err(StorageError::EmptyName)
        ));
    }
    assert!(matches!(
        folders.create(connection, "bad\nname", None).await,
        Err(StorageError::FolderNameInvalid)
    ));
    assert!(matches!(
        folders.create(connection, &"é".repeat(201), None).await,
        Err(StorageError::TooLarge { got: 201, limit: 200 })
    ));
    folders
        .create(connection, &"e\u{301}".repeat(200), None)
        .await
        .expect("length applies to the normalized name");
}

#[tokio::test]
async fn independent_handles_cannot_create_unicode_name_duplicates() {
    let root = tempfile::tempdir().expect("tempdir");
    let first_history = history(&root).await;
    let second_history = history(&root).await;
    let first = first_history.saved_query_folders();
    let second = second_history.saved_query_folders();
    let connection = Uuid::new_v4();
    let results = tokio::join!(
        first.create(connection, "État", None),
        second.create(connection, "e\u{301}tat", None)
    );
    assert!(matches!(
        results,
        (Ok(_), Err(StorageError::FolderNameTaken)) | (Err(StorageError::FolderNameTaken), Ok(_))
    ));
    let saved = first.list(connection).await.expect("list");
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].order, 0);
}

#[tokio::test]
async fn independent_renames_cannot_claim_the_same_unicode_name() {
    let root = tempfile::tempdir().expect("tempdir");
    let first_history = history(&root).await;
    let second_history = history(&root).await;
    let first = first_history.saved_query_folders();
    let second = second_history.saved_query_folders();
    let connection = Uuid::new_v4();
    let a = first.create(connection, "A", None).await.expect("A");
    let b = first.create(connection, "B", None).await.expect("B");
    let results = tokio::join!(first.rename(a, "État"), second.rename(b, "état"));
    assert!(matches!(
        results,
        (Ok(()), Err(StorageError::FolderNameTaken)) | (Err(StorageError::FolderNameTaken), Ok(()))
    ));
    assert_eq!(first.list(connection).await.expect("list").len(), 2);
}

#[tokio::test]
async fn moving_a_folder_compacts_its_source_and_appends_to_its_destination() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let folders = history.saved_query_folders();
    let connection = Uuid::new_v4();
    let source = folders.create(connection, "Source", None).await.expect("source");
    let target = folders.create(connection, "Target", None).await.expect("target");
    let a = folders.create(connection, "A", Some(source)).await.expect("A");
    let b = folders.create(connection, "B", Some(source)).await.expect("B");
    let c = folders.create(connection, "C", Some(source)).await.expect("C");
    let x = folders.create(connection, "X", Some(target)).await.expect("X");
    let other = Uuid::new_v4();
    folders.create(other, "Other", None).await.expect("other");
    let elsewhere = folders.list(other).await.expect("other folders");

    folders.move_to(b, Some(target)).await.expect("move");
    let saved = folders.list(connection).await.expect("list");
    assert_eq!(places(&saved, Some(source)), vec![(a, 0), (c, 1)]);
    assert_eq!(places(&saved, Some(target)), vec![(x, 0), (b, 1)]);
    assert_eq!(folders.list(other).await.expect("other folders"), elsewhere);
    folders.move_to(a, None).await.expect("move to root");
    let saved = folders.list(connection).await.expect("list");
    assert_eq!(places(&saved, None), vec![(source, 0), (target, 1), (a, 2)]);
    assert_eq!(places(&saved, Some(source)), vec![(c, 0)]);
}

#[tokio::test]
async fn invalid_moves_leave_names_hierarchy_and_positions_unchanged() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let folders = history.saved_query_folders();
    let connection = Uuid::new_v4();
    let parent = folders.create(connection, "Parent", None).await.expect("parent");
    let child = folders.create(connection, "État", Some(parent)).await.expect("child");
    folders
        .create(connection, "état", None)
        .await
        .expect("same name at root");
    let foreign = folders.create(Uuid::new_v4(), "Foreign", None).await.expect("foreign");
    let before = folders.list(connection).await.expect("before");

    assert!(matches!(
        folders.move_to(child, None).await,
        Err(StorageError::FolderNameTaken)
    ));
    assert!(matches!(
        folders.move_to(child, Some(foreign)).await,
        Err(StorageError::NotFound)
    ));
    assert!(
        matches!(folders.move_to(parent, Some(child)).await, Err(StorageError::FolderCycle { id }) if id == parent)
    );
    assert!(
        matches!(folders.move_to(parent, Some(parent)).await, Err(StorageError::FolderCycle { id }) if id == parent)
    );
    assert!(matches!(
        folders.move_to(parent, Some(i64::MAX)).await,
        Err(StorageError::NotFound)
    ));
    assert!(matches!(
        folders.move_to(i64::MAX, None).await,
        Err(StorageError::NotFound)
    ));
    assert_eq!(folders.list(connection).await.expect("after"), before);
}

#[tokio::test]
async fn a_corrupt_ancestor_cycle_is_rejected_instead_of_walked_forever() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let folders = history.saved_query_folders();
    let connection = Uuid::new_v4();
    let a = folders.create(connection, "A", None).await.expect("A");
    let b = folders.create(connection, "B", Some(a)).await.expect("B");
    let c = folders.create(connection, "C", None).await.expect("C");
    sqlx::query("UPDATE saved_query_folders SET parent_id = ? WHERE id = ?")
        .bind(b)
        .bind(a)
        .execute(&folders.pool)
        .await
        .expect("corrupt cycle");

    assert!(matches!(folders.move_to(c, Some(a)).await, Err(StorageError::FolderCycle { id }) if id == c));
    assert!(matches!(
        folders.create(connection, "D", Some(a)).await,
        Err(StorageError::FolderCycle { .. })
    ));
}

#[tokio::test]
async fn folder_notifications_follow_committed_changes_only() {
    let root = tempfile::tempdir().expect("tempdir");
    let first_history = history(&root).await;
    let second_history = history(&root).await;
    let folders = first_history.saved_query_folders();
    let queries = first_history.saved_queries();
    let mut changes = queries.changes();
    let mut folder_changes = folders.changes();
    let connection = Uuid::new_v4();
    let a = folders.create(connection, "A", None).await.expect("A");
    assert_eq!(*changes.borrow_and_update(), 1);
    assert_eq!(*folder_changes.borrow_and_update(), 1);
    assert_eq!(
        second_history
            .saved_query_folders()
            .list(connection)
            .await
            .expect("committed")[0]
            .id,
        a
    );

    folders.rename(a, "B").await.expect("rename");
    assert_eq!(*changes.borrow_and_update(), 2);
    assert_eq!(
        second_history
            .saved_query_folders()
            .list(connection)
            .await
            .expect("committed")[0]
            .name,
        "B"
    );
    folders.rename(a, " B ").await.expect("same normalized name");
    folders.move_to(a, None).await.expect("same parent");
    assert!(!changes.has_changed().expect("open sender"));
    assert!(matches!(folders.rename(a, "").await, Err(StorageError::EmptyName)));
    assert!(matches!(
        folders.rename(i64::MAX, "C").await,
        Err(StorageError::NotFound)
    ));
    assert!(!changes.has_changed().expect("open sender"));

    let parent = folders.create(connection, "Parent", None).await.expect("parent");
    changes.borrow_and_update();
    folders.move_to(a, Some(parent)).await.expect("move");
    assert_eq!(*changes.borrow_and_update(), 4);
    assert_eq!(
        second_history
            .saved_query_folders()
            .list(connection)
            .await
            .expect("committed")
            .iter()
            .find(|folder| folder.id == a)
            .expect("A")
            .parent_id,
        Some(parent)
    );
}

#[tokio::test]
async fn a_failed_database_write_emits_no_revision() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let folders = history.saved_query_folders();
    let changes = folders.changes();
    let connection = Uuid::new_v4();
    sqlx::query(
        "CREATE TRIGGER reject_folder BEFORE INSERT ON saved_query_folders \
         BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    )
    .execute(&folders.pool)
    .await
    .expect("failure trigger");

    assert!(matches!(
        folders.create(connection, "A", None).await,
        Err(StorageError::Database(_))
    ));
    assert!(!changes.has_changed().expect("open sender"));
    assert!(folders.list(connection).await.expect("list").is_empty());
}
