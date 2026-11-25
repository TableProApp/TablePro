use std::sync::Arc;

use uuid::Uuid;

use super::*;
use crate::journal::recording::Recording;
use crate::{QueryHistory, StoragePaths};

async fn open() -> (tempfile::TempDir, QueryHistory) {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open");
    (root, history)
}

fn scope(connection: Uuid) -> TableScope {
    TableScope {
        connection_id: connection,
        database: "shop".to_owned(),
        schema: "public".to_owned(),
    }
}

fn table(connection: Uuid, name: &str) -> TableRef {
    TableRef {
        connection_id: connection,
        database: "shop".to_owned(),
        schema: "public".to_owned(),
        name: name.to_owned(),
    }
}

#[tokio::test]
async fn a_table_sits_in_one_folder_and_leaves_with_it() {
    let (_root, history) = open().await;
    let folders = history.table_folders();
    let connection = Uuid::new_v4();
    let sales = folders.create(scope(connection), "Sales").await.expect("create");
    let audit = folders.create(scope(connection), "Audit").await.expect("create");

    folders
        .file(&[table(connection, "orders"), table(connection, "refunds")], sales.id)
        .await
        .expect("file");
    folders
        .file(&[table(connection, "refunds")], audit.id)
        .await
        .expect("refile");
    let filed = folders.items(connection).await.expect("items");
    assert_eq!(
        filed,
        vec![
            TableFolderItem {
                table: table(connection, "orders"),
                folder_id: sales.id,
            },
            TableFolderItem {
                table: table(connection, "refunds"),
                folder_id: audit.id,
            },
        ]
    );

    assert!(folders.delete(sales.id).await.expect("delete"));
    assert_eq!(folders.folders(connection).await.expect("folders"), vec![audit.clone()]);
    assert_eq!(folders.items(connection).await.expect("items").len(), 1);
    folders.unfile(&[table(connection, "refunds")]).await.expect("unfile");
    assert!(folders.items(connection).await.expect("items").is_empty());
}

#[tokio::test]
async fn a_folder_brought_in_keeps_its_id_and_times() {
    let (_root, history) = open().await;
    let folders = history.table_folders();
    let folder = TableFolder {
        id: Uuid::new_v4(),
        scope: scope(Uuid::new_v4()),
        name: "Pulled".to_owned(),
        created_at_ms: 1_700_000_000_123,
        updated_at_ms: 1_700_000_000_456,
    };

    folders.put(&folder).await.expect("put");
    folders.rename(folder.id, "Pulled").await.expect("same name");

    assert_eq!(
        folders.folders(folder.scope.connection_id).await.expect("folders"),
        vec![folder]
    );
    assert!(matches!(
        folders.rename(Uuid::new_v4(), "x").await,
        Err(StorageError::NotFound)
    ));
    assert!(matches!(
        folders.create(scope(Uuid::new_v4()), " ").await,
        Err(StorageError::EmptyName)
    ));
}

#[tokio::test]
async fn an_item_whose_folder_is_missing_is_kept() {
    let (_root, history) = open().await;
    let folders = history.table_folders();
    let connection = Uuid::new_v4();
    let not_yet = Uuid::new_v4();

    folders
        .file(&[table(connection, "orders")], not_yet)
        .await
        .expect("file");

    assert_eq!(folders.items(connection).await.expect("items")[0].folder_id, not_yet);
}

#[tokio::test]
async fn deleting_a_connections_data_takes_its_table_folders_and_tells_the_journal() {
    let (_root, history) = open().await;
    let folders = history.table_folders();
    let connection = Uuid::new_v4();
    let other = Uuid::new_v4();
    let audit = folders.create(scope(connection), "Audit").await.expect("create");
    folders
        .file(&[table(connection, "orders")], audit.id)
        .await
        .expect("file");
    let kept = folders.create(scope(other), "Kept").await.expect("create");
    let journal = Arc::new(Recording::default());
    history.set_journal(Some(journal.clone()));

    history
        .saved_queries()
        .delete_for_connection(connection)
        .await
        .expect("connection gone");
    folders.delete(audit.id).await.expect("already gone");

    assert!(folders.folders(connection).await.expect("folders").is_empty());
    assert!(folders.items(connection).await.expect("items").is_empty());
    assert_eq!(folders.folders(other).await.expect("folders"), vec![kept]);
    assert_eq!(
        journal.take(),
        vec![vec![RecordKind::TableFolder, RecordKind::TableFolderItem]]
    );
}

#[tokio::test]
async fn table_folder_kinds_reach_the_journal_in_order() {
    let (_root, history) = open().await;
    let journal = Arc::new(Recording::default());
    history.set_journal(Some(journal.clone()));
    let folders = history.table_folders();
    let connection = Uuid::new_v4();

    let sales = folders.create(scope(connection), "Sales").await.expect("create");
    folders.rename(sales.id, "Revenue").await.expect("rename");
    folders
        .file(&[table(connection, "orders")], sales.id)
        .await
        .expect("file");
    folders.unfile(&[table(connection, "orders")]).await.expect("unfile");
    folders
        .file(&[table(connection, "orders")], sales.id)
        .await
        .expect("file again");
    folders.delete(sales.id).await.expect("delete");

    assert_eq!(
        journal.take(),
        vec![
            vec![RecordKind::TableFolder],
            vec![RecordKind::TableFolder],
            vec![RecordKind::TableFolderItem],
            vec![RecordKind::TableFolderItem],
            vec![RecordKind::TableFolderItem],
            vec![RecordKind::TableFolder, RecordKind::TableFolderItem],
        ]
    );
}
