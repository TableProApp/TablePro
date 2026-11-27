use std::sync::Arc;
use std::time::{Duration, SystemTime};

use uuid::Uuid;

use super::super::{
    HistoryPageRequest, HistoryQuery, NewEntry, Outcome, QueryHistory, RunDetails, RunSource, StatementType,
};
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
        duration_us: Some(12),
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

fn details() -> RunDetails {
    RunDetails {
        database: Some("shop".to_owned()),
        schema: Some("public".to_owned()),
        source: Some(RunSource::Editor),
        statement_type: Some(StatementType::Select),
        first_row_us: Some(12),
        server_us: Some(9),
        fingerprint: Some(-42),
    }
}

async fn stored(history: &QueryHistory, record_id: Uuid) -> RunDetails {
    history
        .entries_by_record_id(&[record_id])
        .await
        .expect("entries")
        .pop()
        .expect("the entry")
        .details
}

// Runs a host mirrored before it kept details get them afterwards: each field the row lacks is filled, none it has
// changes, and only rows that changed are counted and journaled.
#[tokio::test]
async fn fill_details_sets_only_the_fields_a_run_lacks() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let bare = entry("SELECT bare", 1_700_000_000);
    let mut partial = entry("SELECT partial", 1_700_000_100);
    partial.details.database = Some("kept".to_owned());
    partial.details.source = Some(RunSource::Import);
    let mut whole = entry("SELECT whole", 1_700_000_200);
    whole.details = details();
    history
        .put(&[bare.clone(), partial.clone(), whole.clone()])
        .await
        .expect("put");
    let journal = Arc::new(Recording::default());
    history.set_journal(Some(journal.clone()));

    let changed = history
        .fill_details(&[
            (bare.record_id, details()),
            (partial.record_id, details()),
            (
                whole.record_id,
                RunDetails {
                    database: Some("other".to_owned()),
                    ..details()
                },
            ),
        ])
        .await
        .expect("fill");

    assert_eq!(changed, 2);
    assert_eq!(stored(&history, bare.record_id).await, details());
    assert_eq!(
        stored(&history, partial.record_id).await,
        RunDetails {
            database: Some("kept".to_owned()),
            source: Some(RunSource::Import),
            ..details()
        }
    );
    assert_eq!(stored(&history, whole.record_id).await, details());
    let entries = journal.take_entries().concat();
    let written: Vec<RecordRef> = entries.iter().flat_map(|entry| entry.written.clone()).collect();
    assert_eq!(written.len(), 2);
    assert!(written.contains(&RecordRef::Id(bare.record_id)));
    assert!(written.contains(&RecordRef::Id(partial.record_id)));
    assert_eq!(
        history
            .fill_details(&[(bare.record_id, details())])
            .await
            .expect("fill again"),
        0
    );
}

// A run the store does not hold, or one the person deleted, gets no row from its details.
#[tokio::test]
async fn fill_details_never_adds_or_revives_a_run() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let deleted = entry("SELECT deleted", 1_700_000_000);
    history.put(std::slice::from_ref(&deleted)).await.expect("put");
    history.delete_records(&[deleted.record_id]).await.expect("delete");

    let changed = history
        .fill_details(&[(deleted.record_id, details()), (Uuid::new_v4(), details())])
        .await
        .expect("fill");

    assert_eq!(changed, 0);
    assert!(history.record_ids().await.expect("ids").is_empty());
    assert_eq!(history.tombstones().await.expect("tombstones").len(), 1);
}

// A source a newer build wrote reads as none here, and stays as it was.
#[tokio::test]
async fn fill_details_keeps_a_value_this_build_cannot_read() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let run = entry("SELECT newer", 1_700_000_000);
    history.put(std::slice::from_ref(&run)).await.expect("put");
    sqlx::query("UPDATE history SET source = 'a_newer_source' WHERE record_id = ?")
        .bind(run.record_id.to_string())
        .execute(&history.pool)
        .await
        .expect("a newer build's source");

    history.fill_details(&[(run.record_id, details())]).await.expect("fill");

    let source: Option<String> = sqlx::query_scalar("SELECT source FROM history WHERE record_id = ?")
        .bind(run.record_id.to_string())
        .fetch_one(&history.pool)
        .await
        .expect("source");
    assert_eq!(source.as_deref(), Some("a_newer_source"));
}

// Runs by record id in rowid order, each once; an id the store does not hold, or one the person deleted, is left out.
#[tokio::test]
async fn entries_by_record_id_returns_only_the_runs_the_store_holds() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let first = entry("SELECT first", 1_700_000_000);
    let second = entry("SELECT second", 1_700_000_100);
    let deleted = entry("SELECT deleted", 1_700_000_200);
    history
        .put(&[first.clone(), second.clone(), deleted.clone()])
        .await
        .expect("put");
    history.delete_records(&[deleted.record_id]).await.expect("delete");

    let found = history
        .entries_by_record_id(&[
            second.record_id,
            Uuid::new_v4(),
            deleted.record_id,
            first.record_id,
            second.record_id,
        ])
        .await
        .expect("entries");

    let ids: Vec<Uuid> = found.iter().map(|entry| entry.record_id).collect();
    assert_eq!(ids, [first.record_id, second.record_id]);
    assert_eq!(found[1].query, "SELECT second");
    assert!(history.entries_by_record_id(&[]).await.expect("none").is_empty());
}
