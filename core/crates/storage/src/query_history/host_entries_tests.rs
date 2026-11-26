use std::sync::Arc;
use std::time::{Duration, SystemTime};

use uuid::Uuid;

use super::super::{HistoryPageRequest, HistoryQuery, NewEntry, Outcome, QueryHistory, RunDetails};
use crate::StoragePaths;
use crate::journal::recording::Recording;
use crate::journal::{RecordKind, RecordRef};

async fn history(root: &tempfile::TempDir) -> QueryHistory {
    QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open")
}

fn entry(query: &str, seconds: u64) -> NewEntry {
    NewEntry {
        record_id: Uuid::new_v4(),
        query: query.to_owned(),
        driver_id: "MySQL".to_owned(),
        connection_id: Uuid::new_v4(),
        connection_name: "shop".to_owned(),
        executed_at: SystemTime::UNIX_EPOCH + Duration::from_secs(seconds),
        duration_ms: Some(12),
        rows_affected: Some(3),
        outcome: Outcome::Error("syntax".to_owned()),
        details: RunDetails::default(),
    }
}

#[tokio::test]
async fn put_keeps_each_entrys_id_and_an_entry_put_again_keeps_its_row() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let first = entry("SELECT 1", 1_700_000_000);
    let second = entry("SELECT 2", 1_700_000_100);

    let added = history.put(&[first.clone(), second.clone()]).await.expect("put");
    let again = history.put(std::slice::from_ref(&first)).await.expect("put again");

    assert_eq!((added, again), (2, 0));
    let mut ids = history.record_ids().await.expect("ids");
    ids.sort();
    let mut expected = vec![first.record_id, second.record_id];
    expected.sort();
    assert_eq!(ids, expected);
    let page = history
        .search_page(&HistoryQuery::from_input("select 1"), HistoryPageRequest::first(10))
        .await
        .expect("search");
    let found = page.entries.first().expect("an entry");
    assert_eq!(found.record_id, first.record_id);
    assert_eq!(found.connection_name, "shop");
    assert_eq!(found.error.as_deref(), Some("syntax"));
    assert!(!found.success);
}

#[tokio::test]
async fn remove_takes_entries_by_record_id_and_the_journal_hears_them() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let kept = entry("SELECT kept", 1_700_000_000);
    let gone = entry("SELECT gone", 1_700_000_100);
    history.put(&[kept.clone(), gone.clone()]).await.expect("put");
    let journal = Arc::new(Recording::default());
    history.set_journal(Some(journal.clone()));

    let removed = history.remove(&[gone.record_id, Uuid::new_v4()]).await.expect("remove");

    assert_eq!(removed, 1);
    assert_eq!(history.record_ids().await.expect("ids"), vec![kept.record_id]);
    let entries = journal.take_entries().concat();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].kind, RecordKind::HistoryEntry);
    assert_eq!(entries[0].deleted, vec![RecordRef::Id(gone.record_id)]);
}
