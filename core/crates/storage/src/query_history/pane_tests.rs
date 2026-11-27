// The History pane's columns, filters and deletions over the core's history.

use std::time::{Duration, SystemTime};

use uuid::Uuid;

use super::*;

fn paths(root: &tempfile::TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
}

fn run(query: &str, connection: Uuid, source: RunSource) -> NewEntry {
    NewEntry {
        record_id: Uuid::new_v4(),
        query: query.to_owned(),
        driver_id: "postgresql".to_owned(),
        connection_id: connection,
        connection_name: "shop".to_owned(),
        executed_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000),
        duration_ms: Some(40),
        rows_affected: Some(3),
        outcome: Outcome::Success,
        details: RunDetails {
            database: Some("shop".to_owned()),
            schema: Some("public".to_owned()),
            source: Some(source),
            statement_type: Some(StatementType::Select),
            first_row_ms: Some(12),
            server_ms: Some(9),
            fingerprint: Some(-42),
        },
    }
}

async fn found(history: &QueryHistory, query: &HistoryQuery) -> Vec<String> {
    let mut queries: Vec<String> = history
        .search_page(query, HistoryPageRequest::first(MAX_PAGE_SIZE))
        .await
        .expect("search")
        .entries
        .into_iter()
        .map(|entry| entry.query)
        .collect();
    queries.sort();
    queries
}

#[tokio::test]
async fn an_entry_keeps_every_detail_of_its_run() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let recorded = run("SELECT 1", Uuid::new_v4(), RunSource::Explain);

    history.record(recorded.clone()).await.expect("record");
    let put = run("SELECT 2", Uuid::new_v4(), RunSource::Mcp);
    history.put(std::slice::from_ref(&put)).await.expect("put");

    let entries = history.entries().await.expect("entries");
    assert_eq!(entries[0].details, recorded.details);
    assert_eq!(entries[1].details, put.details);
}

#[tokio::test]
async fn an_undone_delete_puts_back_every_detail() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let id = history
        .record(run("SELECT 1", Uuid::new_v4(), RunSource::RowEdit))
        .await
        .expect("record");
    let before = history.entries().await.expect("entries");

    let deleted = history.delete_returning(&[id]).await.expect("delete");
    history.restore(&deleted).await.expect("restore");

    assert_eq!(history.entries().await.expect("entries"), before);
}

#[tokio::test]
async fn an_older_entry_reads_with_no_details() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let mut older = run("SELECT 1", Uuid::new_v4(), RunSource::Editor);
    older.details = RunDetails::default();

    history.record(older).await.expect("record");

    assert_eq!(
        history.entries().await.expect("entries")[0].details,
        RunDetails::default()
    );
}

#[tokio::test]
async fn the_pane_filters_by_connections_sources_and_a_time_window() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let (mine, theirs, other) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let start = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000);
    for (query, connection, source, offset) in [
        ("SELECT editor", mine, RunSource::Editor, 0),
        ("SELECT browse", mine, RunSource::TableBrowse, 60),
        ("SELECT theirs", theirs, RunSource::Editor, 120),
        ("SELECT other", other, RunSource::Import, 180),
    ] {
        let mut entry = run(query, connection, source);
        entry.executed_at = start + Duration::from_secs(offset);
        history.record(entry).await.expect("record");
    }
    let mut unnamed = run("SELECT unnamed", mine, RunSource::Editor);
    unnamed.details.source = None;
    history.record(unnamed).await.expect("record");

    let mut query = HistoryQuery::default();
    query.connections = Some(vec![mine, theirs]);
    query.sources = Some(vec![RunSource::Editor]);
    assert_eq!(found(&history, &query).await, ["SELECT editor", "SELECT theirs"]);

    let mut query = HistoryQuery::default();
    query.executed_after = Some(start + Duration::from_secs(60));
    query.executed_before = Some(start + Duration::from_secs(120));
    assert_eq!(found(&history, &query).await, ["SELECT browse", "SELECT theirs"]);

    let mut query = HistoryQuery::default();
    query.connections = Some(Vec::new());
    assert!(found(&history, &query).await.is_empty());
    query.connections = None;
    query.sources = Some(Vec::new());
    assert!(found(&history, &query).await.is_empty());
}

#[tokio::test]
async fn deleting_by_record_id_leaves_a_tombstone_for_each_entry_there() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let connection = Uuid::new_v4();
    let (going, staying) = (
        run("SELECT going", connection, RunSource::Editor),
        run("SELECT staying", connection, RunSource::Editor),
    );
    history.put(&[going.clone(), staying.clone()]).await.expect("put");

    let removed = history
        .delete_records(&[going.record_id, Uuid::new_v4()])
        .await
        .expect("delete");

    assert_eq!(removed, 1);
    assert_eq!(history.record_ids().await.expect("ids"), [staying.record_id]);
    assert_eq!(
        history.tombstones().await.expect("tombstones"),
        [HistoryTombstone {
            record_id: going.record_id,
            connection_id: connection,
        }]
    );
    assert_eq!(
        history.put(&[going]).await.expect("put again"),
        0,
        "a deleted entry came back"
    );
}

#[tokio::test]
async fn a_host_removal_leaves_no_tombstone() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let entry = run("SELECT 1", Uuid::new_v4(), RunSource::Editor);
    history.put(std::slice::from_ref(&entry)).await.expect("put");

    assert_eq!(history.remove(&[entry.record_id]).await.expect("remove"), 1);

    assert!(history.tombstones().await.expect("tombstones").is_empty());
}

#[tokio::test]
async fn clearing_what_the_pane_shows_deletes_only_that_and_leaves_tombstones() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let connection = Uuid::new_v4();
    for (query, source) in [
        ("SELECT widgets", RunSource::Editor),
        ("SELECT widgets imported", RunSource::Import),
        ("SELECT gadgets", RunSource::Editor),
    ] {
        history.record(run(query, connection, source)).await.expect("record");
    }
    let mut shown = HistoryQuery::from_input("widgets");
    shown.sources = Some(vec![RunSource::Editor]);

    let all = history
        .search_page(&HistoryQuery::default(), HistoryPageRequest::first(MAX_PAGE_SIZE))
        .await
        .expect("search")
        .entries;
    let widgets = all
        .iter()
        .find(|entry| entry.query == "SELECT widgets")
        .expect("the run shown")
        .record_id;

    assert_eq!(history.delete_matching(&shown).await.expect("clear"), [widgets]);

    assert_eq!(
        found(&history, &HistoryQuery::default()).await,
        ["SELECT gadgets", "SELECT widgets imported"]
    );
    assert_eq!(history.tombstones().await.expect("tombstones").len(), 1);
    assert!(found(&history, &HistoryQuery::from_input("widgets")).await.len() == 1);
}

#[tokio::test]
async fn an_entry_a_pull_brought_gets_its_fingerprint_from_the_app() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let mut pulled = run("SELECT 1", Uuid::new_v4(), RunSource::Editor);
    pulled.details.fingerprint = None;
    history
        .put(&[pulled, run("SELECT 2", Uuid::new_v4(), RunSource::Editor)])
        .await
        .expect("put");
    let identity = history.identity().await.expect("identity");

    let missing = history.without_fingerprint(10).await.expect("missing");
    assert_eq!(missing.len(), 1);
    history.set_fingerprints(&[(missing[0].id, 77)]).await.expect("set");

    assert!(history.without_fingerprint(10).await.expect("missing").is_empty());
    assert_eq!(
        history.entries().await.expect("entries")[0].details.fingerprint,
        Some(77)
    );
    assert_eq!(
        history.identity().await.expect("identity").generation,
        identity.generation
    );
}

#[test]
fn every_source_and_statement_type_reads_back_from_its_name() {
    for source in RunSource::ALL {
        assert_eq!(RunSource::parse(source.as_str()), Some(source));
    }
    for kind in StatementType::ALL {
        assert_eq!(StatementType::parse(kind.as_str()), Some(kind));
    }
    assert_eq!(RunSource::parse("telepathy"), None);
}

// The macOS pane's Failed: every run that did not succeed, a cancelled one included.
#[tokio::test]
async fn unsuccessful_runs_are_the_failed_and_the_cancelled_ones() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    for (query, outcome) in [
        ("SELECT ok", Outcome::Success),
        ("SELECT bad", Outcome::Error("boom".to_owned())),
        ("SELECT stopped", Outcome::Cancelled),
    ] {
        let mut entry = run(query, Uuid::new_v4(), RunSource::Editor);
        entry.outcome = outcome;
        history.record(entry).await.expect("record");
    }
    let mut query = HistoryQuery::default();
    query.status = StatusFilter::Unsuccessful;

    assert_eq!(found(&history, &query).await, ["SELECT bad", "SELECT stopped"]);
}

// Every run the filter matches goes, and the ids come back in rowid order, so a host can drop the same runs from its
// own store.
#[tokio::test]
async fn clearing_what_the_pane_shows_returns_the_ids_in_rowid_order() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&paths(&root)).await.expect("open");
    let connection = Uuid::new_v4();
    let mut recorded = Vec::new();
    for query in [
        "SELECT widgets 1",
        "SELECT gadgets",
        "SELECT widgets 2",
        "SELECT widgets 3",
    ] {
        let entry = run(query, connection, RunSource::Editor);
        recorded.push((query, entry.record_id));
        history.record(entry).await.expect("record");
    }

    let gone = history
        .delete_matching(&HistoryQuery::from_input("widgets"))
        .await
        .expect("clear");

    let widgets: Vec<Uuid> = recorded
        .iter()
        .filter(|(query, _)| query.contains("widgets"))
        .map(|(_, id)| *id)
        .collect();
    assert_eq!(gone, widgets);
    assert!(
        history
            .delete_matching(&HistoryQuery::from_input("widgets"))
            .await
            .expect("clear again")
            .is_empty()
    );
}
