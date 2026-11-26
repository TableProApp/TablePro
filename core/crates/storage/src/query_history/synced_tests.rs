use std::time::{Duration, SystemTime};

use uuid::Uuid;

use super::super::fixtures::old_database;
use super::super::{HistoryPageRequest, HistoryQuery, MAX_UNPINNED_ENTRIES, NewEntry, Outcome, QueryHistory};
use crate::StoragePaths;

async fn history(root: &tempfile::TempDir) -> QueryHistory {
    QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open")
}

fn entry(query: &str, connection: Uuid, seconds: u64) -> NewEntry {
    NewEntry {
        record_id: Uuid::new_v4(),
        query: query.to_owned(),
        driver_id: "PostgreSQL".to_owned(),
        connection_id: connection,
        connection_name: "shop".to_owned(),
        executed_at: SystemTime::UNIX_EPOCH + Duration::from_secs(seconds),
        duration_ms: Some(5),
        rows_affected: None,
        outcome: Outcome::Success,
    }
}

async fn rowids(history: &QueryHistory) -> Vec<i64> {
    history
        .search_page(&HistoryQuery::from_input(""), HistoryPageRequest::first(100))
        .await
        .expect("page")
        .entries
        .iter()
        .map(|entry| entry.id)
        .collect()
}

#[tokio::test]
async fn the_person_s_deletions_leave_tombstones_and_a_prune_or_a_removal_leaves_none() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let (shop, blog) = (Uuid::new_v4(), Uuid::new_v4());
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .expect("after 1970")
        .as_secs();
    let picked = entry("SELECT picked", shop, now);
    let of_blog = entry("SELECT blog", blog, now);
    let old = entry("SELECT old", shop, 1_000);
    let removed = entry("SELECT removed", shop, now);
    history
        .put(&[picked.clone(), of_blog.clone(), old.clone(), removed.clone()])
        .await
        .expect("put");
    let picked_row = history
        .search_page(&HistoryQuery::from_input("picked"), HistoryPageRequest::first(1))
        .await
        .expect("search")
        .entries[0]
        .id;

    history.delete_returning(&[picked_row]).await.expect("delete");
    history.prune(30).await.expect("prune");
    history.remove(&[removed.record_id]).await.expect("remove");
    history
        .delete_for_connection(blog)
        .await
        .expect("delete the connection's");

    assert_eq!(
        history.tombstones().await.expect("tombstones"),
        vec![picked.record_id, of_blog.record_id]
    );
    assert!(history.entries().await.expect("entries").is_empty());
}

#[tokio::test]
async fn clearing_tombstones_every_entry_and_an_undo_takes_its_tombstone_back() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let shop = Uuid::new_v4();
    let (first, second) = (entry("SELECT 1", shop, 1_000), entry("SELECT 2", shop, 2_000));
    history.put(&[first.clone(), second.clone()]).await.expect("put");
    let rows = rowids(&history).await;
    let deleted = history.delete_returning(&rows[..1]).await.expect("delete");

    history.restore(&deleted).await.expect("undo");
    assert!(history.tombstones().await.expect("after the undo").is_empty());
    history.clear_all().await.expect("clear");

    let mut tombstones = history.tombstones().await.expect("tombstones");
    tombstones.sort();
    let mut expected = vec![first.record_id, second.record_id];
    expected.sort();
    assert_eq!(tombstones, expected);
}

#[tokio::test]
async fn an_entry_the_person_deleted_is_not_put_back_until_its_tombstone_goes() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let ran = entry("SELECT ran", Uuid::new_v4(), 1_000);
    history.put(std::slice::from_ref(&ran)).await.expect("put");
    history.clear_all().await.expect("clear");

    let while_deleted = history.put(std::slice::from_ref(&ran)).await.expect("put again");
    history.drop_tombstones(&[ran.record_id]).await.expect("drop");
    let after = history.put(std::slice::from_ref(&ran)).await.expect("put after");

    assert_eq!((while_deleted, after), (0, 1));
    assert!(history.tombstones().await.expect("tombstones").is_empty());
    let entries = history.entries().await.expect("entries");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].record_id, ran.record_id);
}

#[tokio::test]
async fn a_tombstone_stays_however_many_wait_until_sync_drops_it() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) \
         INSERT INTO history_tombstones (record_id) SELECT printf('00000000-0000-4000-8000-%012d', i) FROM n",
    )
    .bind(MAX_UNPINNED_ENTRIES)
    .execute(history.pool())
    .await
    .expect("as many tombstones as the history keeps entries");
    let ran = entry("SELECT newest", Uuid::new_v4(), 1_000);
    history.put(std::slice::from_ref(&ran)).await.expect("put");

    history.clear_all().await.expect("clear");

    let tombstones = history.tombstones().await.expect("tombstones");
    assert_eq!(
        tombstones.len(),
        usize::try_from(MAX_UNPINNED_ENTRIES).expect("fits") + 1
    );
    assert_eq!(
        tombstones.first().map(Uuid::to_string).as_deref(),
        Some("00000000-0000-4000-8000-000000000001")
    );
    assert_eq!(tombstones.last(), Some(&ran.record_id));
}

#[tokio::test]
async fn a_database_from_before_the_tombstones_gains_an_empty_table_and_keeps_its_entries() {
    let root = tempfile::tempdir().expect("tempdir");
    let before = super::super::schema::MIGRATOR.iter().count() - 1;
    let (paths, pool) = old_database(&root, before).await;
    sqlx::query(
        "INSERT INTO history (record_id, query, query_folded, driver_id, connection_id, connection_name, \
         executed_at, success) VALUES ('9b2e6a3c-1f0d-4e8a-b7c5-2d4f6a8b0c1e', 'SELECT 1', 'select 1', 'MySQL', \
         '7d3f1e9a-5b2c-4d6e-8f0a-1b3c5d7e9f20', 'shop', 1000, 1)",
    )
    .execute(&pool)
    .await
    .expect("an entry");
    pool.close().await;

    let history = QueryHistory::open(&paths).await.expect("upgrade");

    assert!(history.tombstones().await.expect("tombstones").is_empty());
    let entries = history.entries().await.expect("entries");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].record_id.to_string(), "9b2e6a3c-1f0d-4e8a-b7c5-2d4f6a8b0c1e");
}
