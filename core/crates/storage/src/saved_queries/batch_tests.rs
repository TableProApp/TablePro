use std::sync::Arc;
use std::time::Duration;

use super::*;
use crate::journal::recording::Recording;
use crate::journal::{RecordKind, RecordRef};
use crate::{QueryHistory, StoragePaths};

async fn history(root: &tempfile::TempDir) -> QueryHistory {
    QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open")
}

fn at(millis: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_millis(millis)
}

fn query(name: &str, connection: Option<Uuid>, folder: Option<Uuid>, created_at: SystemTime) -> SavedQuery {
    SavedQuery {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        query: format!("SELECT '{name}'"),
        connection_id: connection,
        connection_name: "local".to_owned(),
        keyword: None,
        folder_id: folder,
        order: 3,
        created_at,
        updated_at: created_at + Duration::from_millis(5),
    }
}

fn folder(name: &str, parent: Option<Uuid>, created_at: SystemTime) -> SavedQueryFolder {
    SavedQueryFolder {
        id: Uuid::new_v4(),
        connection_id: None,
        name: name.to_owned(),
        parent_id: parent,
        order: 2,
        created_at,
        updated_at: created_at,
    }
}

#[tokio::test]
async fn a_write_keeps_every_id_and_value_and_two_reads_give_one_digest() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let shelf = folder("Reports", None, at(1_700_000_000_001));
    let mut daily = query("Daily", Some(Uuid::new_v4()), Some(shelf.id), at(1_700_000_000_123));
    daily.keyword = Some("dl".to_owned());

    let settled = store
        .write(&SavedQueryWrite {
            queries: vec![daily.clone()],
            folders: vec![shelf.clone()],
            ..SavedQueryWrite::default()
        })
        .await
        .expect("write");

    let contents = store.contents().await.expect("contents");
    assert!(settled.queries.is_empty() && settled.folders.is_empty());
    assert_eq!(contents.queries, vec![daily]);
    assert_eq!(contents.folders, vec![shelf]);
    assert_eq!(settled.digest, contents.digest);
    assert_eq!(store.contents().await.expect("contents").digest, contents.digest);
}

#[tokio::test]
async fn removing_a_folder_changes_no_other_row() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let outer = folder("Outer", None, at(1_000));
    let inner = folder("Inner", Some(outer.id), at(2_000));
    let filed = query("Filed", None, Some(outer.id), at(3_000));
    store
        .write(&SavedQueryWrite {
            queries: vec![filed.clone()],
            folders: vec![outer.clone(), inner.clone()],
            ..SavedQueryWrite::default()
        })
        .await
        .expect("write");

    store
        .write(&SavedQueryWrite {
            removed_folders: vec![outer.id],
            ..SavedQueryWrite::default()
        })
        .await
        .expect("remove");

    let contents = store.contents().await.expect("contents");
    assert_eq!(contents.folders, vec![inner]);
    assert_eq!(contents.queries, vec![filed]);
}

#[tokio::test]
async fn a_replace_leaves_only_what_it_names_and_the_journal_hears_each_id() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let store = history.saved_queries();
    let kept = query("Kept", None, None, at(1_000));
    let dropped = query("Dropped", None, None, at(2_000));
    let old_folder = folder("Old", None, at(3_000));
    store
        .write(&SavedQueryWrite {
            queries: vec![kept.clone(), dropped.clone()],
            folders: vec![old_folder.clone()],
            ..SavedQueryWrite::default()
        })
        .await
        .expect("write");
    let journal = Arc::new(Recording::default());
    history.set_journal(Some(journal.clone()));
    let read = store.contents().await.expect("contents");

    store
        .replace(Some(&read.digest), std::slice::from_ref(&kept), &[])
        .await
        .expect("replace");

    let contents = store.contents().await.expect("contents");
    assert_eq!(contents.queries, vec![kept.clone()]);
    assert!(contents.folders.is_empty());
    let entries = journal.take_entries().concat();
    let query_entry = entries
        .iter()
        .find(|entry| entry.kind == RecordKind::SavedQuery)
        .expect("queries");
    assert_eq!(query_entry.written, vec![RecordRef::Id(kept.id)]);
    assert_eq!(query_entry.deleted, vec![RecordRef::Id(dropped.id)]);
    let folder_entry = entries
        .iter()
        .find(|entry| entry.kind == RecordKind::SavedQueryFolder)
        .expect("folders");
    assert_eq!(folder_entry.deleted, vec![RecordRef::Id(old_folder.id)]);
}

#[tokio::test]
async fn a_replace_based_on_an_older_read_writes_nothing() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let first = query("First", None, None, at(1_000));
    store
        .write(&SavedQueryWrite {
            queries: vec![first.clone()],
            ..SavedQueryWrite::default()
        })
        .await
        .expect("write");
    let read = store.contents().await.expect("contents");
    let later = query("Later", None, None, at(2_000));
    store
        .write(&SavedQueryWrite {
            queries: vec![later.clone()],
            ..SavedQueryWrite::default()
        })
        .await
        .expect("write");

    let refused = store
        .replace(Some(&read.digest), std::slice::from_ref(&first), &[])
        .await;

    assert!(matches!(refused, Err(StorageError::ImportOutdated)));
    let mut names: Vec<String> = store
        .contents()
        .await
        .expect("contents")
        .queries
        .into_iter()
        .map(|query| query.name)
        .collect();
    names.sort();
    assert_eq!(names, ["First", "Later"]);
}

#[tokio::test]
async fn two_queries_of_one_name_settle_on_the_later_one_and_report_it() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let connection = Some(Uuid::new_v4());
    let older = query("Report", connection, None, at(1_000));
    let newer = query("Report", connection, None, at(2_000));

    let settled = store
        .replace(None, &[older.clone(), newer.clone()], &[])
        .await
        .expect("replace");

    assert_eq!(settled.queries, vec![newer.id]);
    let contents = store.contents().await.expect("contents");
    let name_of = |id: Uuid| {
        contents
            .queries
            .iter()
            .find(|query| query.id == id)
            .map(|query| query.name.clone())
    };
    assert_eq!(name_of(older.id).as_deref(), Some("Report"));
    assert_eq!(name_of(newer.id).as_deref(), Some("Report (2)"));
}
